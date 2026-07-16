import Fluent
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Vapor

struct AdminController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("admin", use: adminConsole)

        let api = routes.grouped("admin", "api")
        api.get("me", use: currentAdmin)
        api.get("overview", use: overview)
        api.get("users", use: users)
        api.get("users", ":userID", "security", use: userSecurityOverview)
        api.patch("users", ":userID", "status", use: updateUserStatus)
        api.patch("users", ":userID", "admin-role", use: updateUserAdminRole)
        api.get("conversations", ":conversationID", use: conversationInspection)
        api.get("conversations", ":conversationID", "messages", use: conversationMessages)
        api.post("conversations", ":conversationID", "governance-commands", use: createConversationGovernanceCommand)
        api.get("conversations", ":conversationID", "governance-commands", ":commandID", use: conversationGovernanceCommand)
        api.get("reports", use: reports)
        api.get("reports", "queue", use: reportQueue)
        api.patch("reports", ":reportID", use: updateReport)
        api.patch("reports", ":reportID", "reviewer", use: assignReportReviewer)
        api.get("reports", ":reportID", "decisions", use: reportDecisions)
        api.get("reports", ":reportID", "evidence", use: reportEvidence)
        api.post("reports", ":reportID", "evidence", use: addReportEvidence)
        api.get("audit-events", use: auditEvents)
    }

    func adminConsole(req: Request) throws -> Response {
        guard req.application.adminConfiguration.isEnabled else {
            throw Abort(.notFound)
        }
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "text/html; charset=utf-8")]),
            body: .init(string: AdminConsoleHTML.page)
        )
    }

    func overview(req: Request) async throws -> AdminOverviewResponse {
        let access = try await requireAdminAccess(req)
        try access.requires(.overviewRead)

        async let totalUsers = User.query(on: req.db).count()
        async let activeUsers = User.query(on: req.db).filter(\.$status == UserStatus.active.rawValue).count()
        async let disabledUsers = User.query(on: req.db).filter(\.$status == UserStatus.disabled.rawValue).count()
        async let activeSessions = AuthSession.query(on: req.db).filter(\.$revokedAt == nil).count()
        async let pendingReports = UserReport.query(on: req.db).filter(\.$status == "pending").count()
        async let reviewingReports = UserReport.query(on: req.db).filter(\.$status == "reviewing").count()

        let userCounts = AdminOverviewResponse.UserCounts(
            total: try await totalUsers,
            active: try await activeUsers,
            disabled: try await disabledUsers
        )
        let reportCounts = AdminOverviewResponse.ReportCounts(
            pending: try await pendingReports,
            reviewing: try await reviewingReports
        )
        let activeSessionCount = try await activeSessions

        return AdminOverviewResponse(
            users: userCounts,
            activeSessions: activeSessionCount,
            reports: reportCounts
        )
    }

    func users(req: Request) async throws -> AdminUserPageResponse {
        let access = try await requireAdminAccess(req)
        try access.requires(.usersRead)
        let query = try req.query.decode(AdminUserPageQuery.self)
        let limit = max(1, min(query.limit ?? 50, 100))
        let offset = max(0, query.cursor.flatMap(Int.init) ?? 0)
        let status = query.status?.trimmedNonEmpty
        let searchTerm = query.query?.trimmedNonEmpty?.lowercased()

        let builder = User.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
        if let status {
            builder.filter(\.$status == status)
        }

        if let searchTerm {
            let allRows = try await builder.all()
            let filteredRows = allRows.filter { user in
                user.email.lowercased().contains(searchTerm)
                    || (user.displayName?.lowercased().contains(searchTerm) ?? false)
                    || (user.id?.uuidString.lowercased().contains(searchTerm) ?? false)
            }
            let page = Array(filteredRows.dropFirst(offset).prefix(limit))
            let nextOffset = offset + page.count
            return try AdminUserPageResponse(
                items: page.map(AdminUserResponse.init(user:)),
                nextCursor: nextOffset < filteredRows.count ? "\(nextOffset)" : nil,
                hasMore: nextOffset < filteredRows.count
            )
        }

        let rows = try await builder.range(offset..<(offset + limit + 1)).all()
        let page = Array(rows.prefix(limit))
        let nextOffset = offset + page.count
        return try AdminUserPageResponse(
            items: page.map(AdminUserResponse.init(user:)),
            nextCursor: rows.count > limit ? "\(nextOffset)" : nil,
            hasMore: rows.count > limit
        )
    }

    func updateUserStatus(req: Request) async throws -> AdminUserResponse {
        let access = try await requireAdminAccess(req)
        try access.requires(.usersWriteStatus)
        guard let rawID = req.parameters.get("userID"), let userID = UUID(uuidString: rawID) else {
            throw Abort(.badRequest, reason: "用户 ID 无效。")
        }

        let body = try req.content.decode(AdminUserStatusUpdateRequest.self)
        let status = body.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let statusEnum = UserStatus(rawValue: status) else {
            throw Abort(.badRequest, reason: "用户状态无效。")
        }
        guard let user = try await User.find(userID, on: req.db) else {
            throw Abort(.notFound, reason: "用户不存在。")
        }

        let note = body.note?.trimmedNonEmpty
        let idempotencyKey = try Self.requiredIdempotencyKey(from: req)
        let scope = "user.status.update"
        let digest = Self.adminWriteDigest(
            scope: scope,
            targetID: userID.uuidString,
            values: ["status": statusEnum.rawValue, "note": note ?? ""]
        )
        if try await Self.existingAdminWrite(
            on: req.db,
            scope: scope,
            actor: access.actor,
            idempotencyKey: idempotencyKey,
            targetID: userID.uuidString,
            requestDigest: digest
        ) {
            return try AdminUserResponse(user: user)
        }

        do {
            try await req.db.transaction { database in
                let previousStatus = user.status
                user.status = statusEnum.rawValue
                try await user.update(on: database)

                var revokedSessions = 0
                if statusEnum == .disabled {
                    let activeSessions = try await AuthSession.query(on: database)
                        .filter(\.$user.$id == userID)
                        .filter(\.$revokedAt == nil)
                        .all()
                    revokedSessions = activeSessions.count
                    if revokedSessions > 0 {
                        try await AuthSession.query(on: database)
                            .filter(\.$user.$id == userID)
                            .filter(\.$revokedAt == nil)
                            .set(\.$revokedAt, to: Date())
                            .set(\.$revokedReason, to: AuthSessionRevocationReason.logoutAll.rawValue)
                            .update()
                    }
                }
                try await Self.recordAdminWrite(
                    on: database,
                    scope: scope,
                    actor: access.actor,
                    idempotencyKey: idempotencyKey,
                    targetID: userID.uuidString,
                    requestDigest: digest
                )
                try await recordAudit(
                    req,
                    access: access,
                    action: scope,
                    targetType: "user",
                    targetID: userID.uuidString,
                    metadata: [
                        "previousStatus": previousStatus,
                        "status": statusEnum.rawValue,
                        "revokedSessions": "\(revokedSessions)",
                        "note": note ?? ""
                    ],
                    on: database
                )
            }
        } catch {
            guard try await Self.existingAdminWrite(
                on: req.db,
                scope: scope,
                actor: access.actor,
                idempotencyKey: idempotencyKey,
                targetID: userID.uuidString,
                requestDigest: digest
            ), let persisted = try await User.find(userID, on: req.db) else {
                throw error
            }
            return try AdminUserResponse(user: persisted)
        }
        if statusEnum == .disabled {
            await req.application.authSessionValidationCache.invalidate(userID: userID)
            await req.application.gatewaySessionService.kickConnections(
                forUserID: userID,
                reason: .logoutAll,
                message: "You have signed out from all devices."
            )
        }

        return try AdminUserResponse(user: user)
    }

    func userSecurityOverview(req: Request) async throws -> AdminUserSecurityOverviewResponse {
        let access = try await requireAdminAccess(req)
        try access.requires(.usersInspectSecurity)
        guard let rawID = req.parameters.get("userID"), let userID = UUID(uuidString: rawID) else {
            throw Abort(.badRequest, reason: "用户 ID 无效。")
        }
        guard let user = try await User.find(userID, on: req.db) else {
            throw Abort(.notFound, reason: "用户不存在。")
        }

        async let sessions = AuthSession.query(on: req.db)
            .filter(\.$user.$id == userID)
            .sort(\.$lastSeenAt, .descending)
            .sort(\.$createdAt, .descending)
            .all()
        async let devices = PushDeviceToken.query(on: req.db)
            .filter(\.$ownerUserID == userID)
            .sort(\.$updatedAt, .descending)
            .all()

        let sessionRows = try await sessions
        let deviceRows = try await devices
        try await recordAudit(
            req,
            access: access,
            action: "user.security.inspect",
            targetType: "user",
            targetID: userID.uuidString,
            metadata: [
                "sessionCount": "\(sessionRows.count)",
                "activePushDeviceCount": "\(deviceRows.filter(\.isActive).count)"
            ],
            on: req.db
        )
        return try AdminUserSecurityOverviewResponse(
            user: AdminUserResponse(user: user),
            sessions: try sessionRows.map(AdminAuthSessionResponse.init(session:)),
            pushDevices: deviceRows.map(AdminPushDeviceResponse.init(device:))
        )
    }

    func updateUserAdminRole(req: Request) async throws -> AdminUserResponse {
        let access = try await requireAdminAccess(req)
        try access.requires(.usersWriteRole)
        guard let rawID = req.parameters.get("userID"), let userID = UUID(uuidString: rawID) else {
            throw Abort(.badRequest, reason: "用户 ID 无效。")
        }
        guard access.userID != userID else {
            throw Abort(.badRequest, reason: "不能通过当前会话修改自己的管理员角色。")
        }

        let body = try req.content.decode(AdminUserRoleUpdateRequest.self)
        let requestedRole = body.adminRole?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let requestedRole, requestedRole.isEmpty {
            throw Abort(.badRequest, reason: "管理员角色无效。")
        }
        let role = requestedRole.flatMap(AdminRole.init(rawValue:))
        if requestedRole != nil, role == nil {
            throw Abort(.badRequest, reason: "管理员角色无效。")
        }
        guard let user = try await User.find(userID, on: req.db) else {
            throw Abort(.notFound, reason: "用户不存在。")
        }

        let note = body.note?.trimmedNonEmpty
        let idempotencyKey = try Self.requiredIdempotencyKey(from: req)
        let scope = "user.admin_role.update"
        let digest = Self.adminWriteDigest(
            scope: scope,
            targetID: userID.uuidString,
            values: ["adminRole": role?.rawValue ?? "", "note": note ?? ""]
        )
        if try await Self.existingAdminWrite(
            on: req.db,
            scope: scope,
            actor: access.actor,
            idempotencyKey: idempotencyKey,
            targetID: userID.uuidString,
            requestDigest: digest
        ) {
            return try AdminUserResponse(user: user)
        }

        do {
            try await req.db.transaction { database in
                let previousRole = user.adminRole
                user.adminRole = role?.rawValue
                try await user.update(on: database)
                try await Self.recordAdminWrite(
                    on: database,
                    scope: scope,
                    actor: access.actor,
                    idempotencyKey: idempotencyKey,
                    targetID: userID.uuidString,
                    requestDigest: digest
                )
                try await recordAudit(
                    req,
                    access: access,
                    action: scope,
                    targetType: "user",
                    targetID: userID.uuidString,
                    metadata: [
                        "previousAdminRole": previousRole ?? "",
                        "adminRole": role?.rawValue ?? "",
                        "note": note ?? ""
                    ],
                    on: database
                )
            }
        } catch {
            guard try await Self.existingAdminWrite(
                on: req.db,
                scope: scope,
                actor: access.actor,
                idempotencyKey: idempotencyKey,
                targetID: userID.uuidString,
                requestDigest: digest
            ), let persisted = try await User.find(userID, on: req.db) else {
                throw error
            }
            return try AdminUserResponse(user: persisted)
        }
        await req.application.authSessionValidationCache.invalidate(userID: userID)

        return try AdminUserResponse(user: user)
    }

    func conversationInspection(req: Request) async throws -> AdminConversationInspectionResponse {
        let access = try await requireAdminAccess(req)
        try access.requires(.conversationsInspect)
        let conversationID = try Self.conversationID(from: req)
        let query = try req.query.decode(AdminConversationInspectionQuery.self)
        let limit = max(1, min(query.limit ?? 50, 100))
        let offset = max(0, query.cursor.flatMap(Int.init) ?? 0)
        let database = try await req.application.conversationShardRouter.strongReadDatabase(
            forConversationID: conversationID
        )
        guard let conversation = try await Conversation.find(conversationID, on: database) else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        async let totalMemberCount = ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .count()
        async let latestMessage = ConversationMessage.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .sort(\.$serverSequence, .descending)
            .first()
        let memberRows = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .sort(\.$role, .ascending)
            .sort(\.$joinedAt, .ascending)
            .range(offset..<(offset + limit + 1))
            .all()
        let memberPage = Array(memberRows.prefix(limit))
        let usersByID = try await ConversationUserDirectory(db: req.db)
            .usersByID(memberPage.map(\.$user.id))
        let memberResponses = try memberPage.map { member in
            guard let user = usersByID[member.$user.id] else {
                throw Abort(.internalServerError, reason: "会话成员缺少主库用户目录记录。")
            }
            return try AdminConversationMemberResponse(member: member, user: user)
        }
        let total = try await totalMemberCount
        let latest = try await latestMessage
        try await recordAudit(
            req,
            access: access,
            action: "conversation.inspect",
            targetType: "conversation",
            targetID: conversationID.uuidString,
            metadata: [
                "memberPageCount": "\(memberResponses.count)",
                "memberTotal": "\(total)",
                "lastMessageSequence": "\(latest?.timelineSequence ?? 0)"
            ],
            on: req.db
        )
        return try AdminConversationInspectionResponse(
            conversation: AdminConversationResponse(conversation: conversation),
            members: memberResponses,
            memberTotal: total,
            nextMemberCursor: memberRows.count > limit ? "\(offset + memberResponses.count)" : nil,
            hasMoreMembers: memberRows.count > limit,
            latestMessage: latest.map(AdminConversationMessageMetadataResponse.init(message:))
        )
    }

    func conversationMessages(req: Request) async throws -> AdminConversationMessagePageResponse {
        let access = try await requireAdminAccess(req)
        try access.requires(.messagesInspect)
        let conversationID = try Self.conversationID(from: req)
        let query = try req.query.decode(AdminConversationMessagePageQuery.self)
        let limit = max(1, min(query.limit ?? 50, 100))
        let database = try await req.application.conversationShardRouter.strongReadDatabase(
            forConversationID: conversationID
        )
        guard try await Conversation.find(conversationID, on: database) != nil else {
            throw Abort(.notFound, reason: "会话不存在。")
        }
        let upperBound = query.beforeSequence ?? Int.max
        guard upperBound > 0 else {
            throw Abort(.badRequest, reason: "消息分页游标无效。")
        }
        let rows = try await ConversationMessage.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$timelineSequence < upperBound)
            .sort(\.$timelineSequence, .descending)
            .range(0..<limit + 1)
            .all()
        let page = Array(rows.prefix(limit))
        let usersByID = try await ConversationUserDirectory(db: req.db)
            .usersByID(page.map(\.$sender.id))
        let messages = try page.map { message in
            guard let sender = usersByID[message.$sender.id] else {
                throw Abort(.internalServerError, reason: "消息发送者缺少主库用户目录记录。")
            }
            return try AdminConversationMessageResponse(message: message, sender: sender)
        }
        try await recordAudit(
            req,
            access: access,
            action: "conversation.messages.inspect",
            targetType: "conversation",
            targetID: conversationID.uuidString,
            metadata: [
                "messagePageCount": "\(messages.count)",
                "beforeSequence": query.beforeSequence.map(String.init) ?? ""
            ],
            on: req.db
        )
        return AdminConversationMessagePageResponse(
            items: messages,
            nextBeforeSequence: rows.count > limit ? page.last.map { $0.timelineSequence } : nil,
            hasMore: rows.count > limit
        )
    }

    func createConversationGovernanceCommand(req: Request) async throws -> Response {
        let access = try await requireAdminAccess(req)
        try access.requires(.conversationsWriteGovernance)
        let conversationID = try Self.conversationID(from: req)
        let body = try req.content.decode(AdminConversationGovernanceCommandRequest.self)
        guard let action = AdminConversationGovernanceAction(rawValue: body.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            throw Abort(.badRequest, reason: "不支持的后台群治理操作。")
        }
        let reason = try Self.normalizedGovernanceReason(body.reason)
        let idempotencyKey = try Self.requiredIdempotencyKey(from: req)
        let requestedMuteAll: Bool
        let requestedGroupLifecycleState: IMGroupLifecycleState
        let targetMemberUserID: UUID?
        let destructiveConfirmed: Bool
        var digestValues = ["reason": reason]
        switch action {
        case .groupMuteAllSet:
            guard let muteAll = body.muteAll else {
                throw Abort(.badRequest, reason: "全员禁言操作必须提供 muteAll。")
            }
            requestedMuteAll = muteAll
            requestedGroupLifecycleState = .active
            targetMemberUserID = nil
            destructiveConfirmed = false
            digestValues["muteAll"] = muteAll ? "true" : "false"
        case .groupLifecycleSet:
            guard let rawLifecycleState = body.groupLifecycleState?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  let lifecycleState = IMGroupLifecycleState(rawValue: rawLifecycleState)
            else {
                throw Abort(.badRequest, reason: "群生命周期操作必须提供有效的 groupLifecycleState。")
            }
            requestedMuteAll = false
            requestedGroupLifecycleState = lifecycleState
            targetMemberUserID = nil
            destructiveConfirmed = lifecycleState == .frozen || lifecycleState == .dissolved
            guard !destructiveConfirmed || body.confirmed == true else {
                throw Abort(
                    .badRequest,
                    reason: lifecycleState == .dissolved ? "解散群必须显式确认。" : "冻结群必须显式确认。"
                )
            }
            digestValues["groupLifecycleState"] = lifecycleState.rawValue
            digestValues["confirmed"] = destructiveConfirmed ? "true" : "false"
        case .groupMemberRemove:
            guard let memberUserID = body.memberUserID else {
                throw Abort(.badRequest, reason: "移除群成员操作必须提供 memberUserID。")
            }
            guard body.confirmed == true else {
                throw Abort(.badRequest, reason: "移除群成员操作必须显式确认。")
            }
            requestedMuteAll = false
            requestedGroupLifecycleState = .active
            targetMemberUserID = memberUserID
            destructiveConfirmed = true
            digestValues["memberUserID"] = memberUserID.uuidString.lowercased()
            digestValues["confirmed"] = "true"
        }
        let digest = Self.adminWriteDigest(
            scope: action.rawValue,
            targetID: conversationID.uuidString,
            values: digestValues
        )

        if let existing = try await AdminConversationGovernanceCommand.query(on: req.db)
            .filter(\.$actor == access.actor)
            .filter(\.$action == action.rawValue)
            .filter(\.$idempotencyKey == idempotencyKey)
            .first() {
            try Self.validateDuplicateGovernanceCommand(
                existing,
                conversationID: conversationID,
                requestDigest: digest
            )
            return try Self.acceptedResponse(AdminConversationGovernanceCommandResponse(command: existing))
        }

        let router = req.application.conversationShardRouter
        let route: ConversationRoute
        if router.routerName == "single-shard" {
            route = ConversationRoute(
                cellID: req.application.imRealtimeCellID,
                shardID: SingleShardConversationShardRouter.defaultShardID
            )
        } else {
            route = try await req.application.conversationDirectory.route(for: conversationID)
        }
        guard route.cellID == req.application.imRealtimeCellID else {
            throw Abort(
                .serviceUnavailable,
                reason: "会话属于 realtime cell \(route.cellID)，当前 cell \(req.application.imRealtimeCellID) 不可执行后台治理命令。"
            )
        }
        guard router.shardIDs.contains(route.shardID) else {
            throw Abort(.internalServerError, reason: "会话目录引用了未配置的 shard \(route.shardID)。")
        }
        let shardID = route.shardID
        let commandDatabase = router.commandDatabase(forShardID: shardID)
        guard let conversation = try await Conversation.find(conversationID, on: commandDatabase) else {
            throw Abort(.notFound, reason: "会话不存在。")
        }
        try ConversationMembershipGuard.requireGroup(conversation, reason: "后台群治理命令只支持群聊。")
        if conversation.groupLifecycleStateEnum == .dissolved {
            switch action {
            case .groupLifecycleSet where requestedGroupLifecycleState == .dissolved:
                break
            case .groupLifecycleSet:
                throw Abort(.conflict, reason: "群聊已解散，不能恢复为活跃或冻结状态。")
            case .groupMuteAllSet, .groupMemberRemove:
                throw Abort(.conflict, reason: "群聊已解散，成员关系和群资料已归档。")
            }
        }
        if let targetMemberUserID {
            guard let targetMembership = try await ConversationMember.query(on: commandDatabase)
                .filter(\.$conversation.$id == conversationID)
                .filter(\.$user.$id == targetMemberUserID)
                .first()
            else {
                throw Abort(.notFound, reason: "目标群成员不存在。")
            }
            guard targetMembership.memberRoleEnum != .owner else {
                throw Abort(.badRequest, reason: "后台治理不能直接移除群主。")
            }
            let memberCount = try await ConversationMember.query(on: commandDatabase)
                .filter(\.$conversation.$id == conversationID)
                .count()
            guard memberCount - 1 >= 2 else {
                throw Abort(.badRequest, reason: "移除后群成员不能少于 2 人。")
            }
        }

        let command = AdminConversationGovernanceCommand(
            action: action,
            conversationID: conversationID,
            targetShardID: shardID,
            targetCellID: route.cellID,
            targetRouteVersion: route.version,
            actor: access.actor,
            actorUserID: access.userID,
            actorRole: access.role,
            authenticationMethod: access.authenticationMethod,
            idempotencyKey: idempotencyKey,
            requestDigest: digest,
            requestedMuteAll: requestedMuteAll,
            requestedGroupLifecycleState: requestedGroupLifecycleState,
            targetMemberUserID: targetMemberUserID,
            destructiveConfirmed: destructiveConfirmed,
            reason: reason
        )
        var acceptedAuditMetadata = [
            "governanceAction": action.rawValue,
            "targetShardID": shardID,
            "targetCellID": route.cellID,
            "targetRouteVersion": "\(route.version)",
            "reasonPresent": "true",
            "reasonLength": "\(reason.count)"
        ]
        if action == .groupMuteAllSet {
            acceptedAuditMetadata["muteAll"] = requestedMuteAll ? "true" : "false"
        } else if action == .groupLifecycleSet {
            acceptedAuditMetadata["groupLifecycleState"] = requestedGroupLifecycleState.rawValue
            acceptedAuditMetadata["confirmed"] = destructiveConfirmed ? "true" : "false"
        } else if let targetMemberUserID {
            acceptedAuditMetadata["targetMemberUserID"] = targetMemberUserID.uuidString
            acceptedAuditMetadata["confirmed"] = destructiveConfirmed ? "true" : "false"
        }
        let immutableAcceptedAuditMetadata = acceptedAuditMetadata
        do {
            try await req.db.transaction { database in
                try await command.create(on: database)
                try await recordAudit(
                    req,
                    access: access,
                    action: "conversation.governance.command.accepted",
                    targetType: "conversation",
                    targetID: conversationID.uuidString,
                    metadata: immutableAcceptedAuditMetadata,
                    on: database
                )
            }
        } catch {
            guard let existing = try await AdminConversationGovernanceCommand.query(on: req.db)
                .filter(\.$actor == access.actor)
                .filter(\.$action == action.rawValue)
                .filter(\.$idempotencyKey == idempotencyKey)
                .first()
            else {
                throw error
            }
            try Self.validateDuplicateGovernanceCommand(
                existing,
                conversationID: conversationID,
                requestDigest: digest
            )
            return try Self.acceptedResponse(AdminConversationGovernanceCommandResponse(command: existing))
        }
        return try Self.acceptedResponse(AdminConversationGovernanceCommandResponse(command: command))
    }

    func conversationGovernanceCommand(req: Request) async throws -> AdminConversationGovernanceCommandResponse {
        let access = try await requireAdminAccess(req)
        try access.requires(.conversationsWriteGovernance)
        let conversationID = try Self.conversationID(from: req)
        guard let rawCommandID = req.parameters.get("commandID"), let commandID = UUID(uuidString: rawCommandID) else {
            throw Abort(.badRequest, reason: "后台群治理命令 ID 无效。")
        }
        guard let command = try await AdminConversationGovernanceCommand.find(commandID, on: req.db), command.conversationID == conversationID else {
            throw Abort(.notFound, reason: "后台群治理命令不存在。")
        }
        return try AdminConversationGovernanceCommandResponse(command: command)
    }

    func reports(req: Request) async throws -> ReportPageResponse {
        let access = try await requireAdminAccess(req)
        try access.requires(.reportsRead)
        let query = try req.query.decode(ReportPageQuery.self)
        let limit = max(1, min(query.limit ?? 50, 100))
        let offset = max(0, query.cursor.flatMap(Int.init) ?? 0)
        let builder = UserReport.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
        if let status = query.status?.trimmedNonEmpty {
            builder.filter(\.$status == status.lowercased())
        }
        if let targetType = query.targetType?.trimmedNonEmpty {
            builder.filter(\.$targetType == targetType.lowercased())
        }

        let rows = try await builder.range(offset..<(offset + limit + 1)).all()
        let page = Array(rows.prefix(limit))
        let nextOffset = offset + page.count
        return ReportPageResponse(
            items: try page.map(Self.response(from:)),
            nextCursor: rows.count > limit ? "\(nextOffset)" : nil,
            hasMore: rows.count > limit
        )
    }

    func reportQueue(req: Request) async throws -> AdminReportQueueResponse {
        let access = try await requireAdminAccess(req)
        try access.requires(.reportsRead)
        let query = try req.query.decode(AdminReportQueueQuery.self)
        let limit = max(1, min(query.limit ?? 50, 100))
        let offset = max(0, query.cursor.flatMap(Int.init) ?? 0)
        let scope = try AdminReportQueueScope(validating: query.scope?.trimmedNonEmpty?.lowercased() ?? "unassigned")
        let statuses = try Self.queueStatuses(requested: query.status)

        let builder = UserReport.query(on: req.db)
            .sort(\.$createdAt, .ascending)
            .sort(\.$id, .ascending)
        Self.filter(builder, statuses: statuses)
        switch scope {
        case .all:
            break
        case .unassigned:
            builder.filter(\.$assignedReviewerUserID == nil)
        case .mine:
            guard let userID = access.userID else {
                throw Abort(.badRequest, reason: "共享密钥身份不能使用 mine 举报队列。")
            }
            builder.filter(\.$assignedReviewerUserID == userID)
        }

        async let pendingCount = UserReport.query(on: req.db).filter(\.$status == "pending").count()
        async let reviewingCount = UserReport.query(on: req.db).filter(\.$status == "reviewing").count()
        async let unassignedCount = UserReport.query(on: req.db)
            .filter(\.$assignedReviewerUserID == nil)
            .group(.or) { group in
                group.filter(\.$status == "pending")
                group.filter(\.$status == "reviewing")
            }
            .count()
        async let oldestPending = UserReport.query(on: req.db)
            .filter(\.$status == "pending")
            .sort(\.$createdAt, .ascending)
            .first()
        async let oldestReviewing = UserReport.query(on: req.db)
            .filter(\.$status == "reviewing")
            .sort(\.$createdAt, .ascending)
            .first()

        let rows = try await builder.range(offset..<(offset + limit + 1)).all()
        let page = Array(rows.prefix(limit))
        let now = Date()
        return AdminReportQueueResponse(
            scope: scope.rawValue,
            summary: AdminReportQueueSummary(
                pendingCount: try await pendingCount,
                reviewingCount: try await reviewingCount,
                unassignedActiveCount: try await unassignedCount,
                oldestPendingAgeSeconds: try await oldestPending.map { Self.ageSeconds(since: $0.createdAt, now: now) },
                oldestReviewingAgeSeconds: try await oldestReviewing.map { Self.ageSeconds(since: $0.createdAt, now: now) }
            ),
            items: try page.map { report in
                AdminReportQueueItem(
                    report: try Self.response(from: report),
                    ageSeconds: Self.ageSeconds(since: report.createdAt, now: now)
                )
            },
            nextCursor: rows.count > limit ? "\(offset + page.count)" : nil,
            hasMore: rows.count > limit
        )
    }

    func updateReport(req: Request) async throws -> ReportResponse {
        let access = try await requireAdminAccess(req)
        try access.requires(.reportsWrite)
        guard let rawID = req.parameters.get("reportID"), let reportID = UUID(uuidString: rawID) else {
            throw Abort(.badRequest, reason: "举报 ID 无效。")
        }
        let body = try req.content.decode(ReportUpdateRequest.self)
        guard let report = try await UserReport.find(reportID, on: req.db) else {
            throw Abort(.notFound, reason: "举报记录不存在。")
        }
        let idempotencyKey = try Self.requiredIdempotencyKey(from: req)
        if let existing = try await ReportModerationDecision.query(on: req.db)
            .filter(\.$report.$id == reportID)
            .filter(\.$idempotencyKey == idempotencyKey)
            .first() {
            try Self.validateDuplicateDecision(existing, matches: body)
            return try Self.response(from: report)
        }

        let transition = try ReportModerationWorkflow.transition(
            from: report.status,
            requestedStatus: body.status,
            resolutionCategory: body.resolutionCategory,
            handledNote: body.handledNote
        )
        do {
            try await req.db.transaction { database in
                report.status = transition.status
                report.handledNote = transition.handledNote
                try await report.update(on: database)

                let decision = ReportModerationDecision(
                    reportID: reportID,
                    reviewerActor: access.actor,
                    reviewerUserID: access.userID,
                    reviewerRole: access.role.rawValue,
                    authenticationMethod: access.authenticationMethod.rawValue,
                    previousStatus: transition.previousStatus,
                    status: transition.status,
                    resolutionCategory: transition.resolutionCategory,
                    handledNote: transition.handledNote,
                    requestID: req.headers.first(name: "X-Request-ID"),
                    idempotencyKey: idempotencyKey
                )
                try await decision.create(on: database)

                try await recordAudit(
                    req,
                    access: access,
                    action: "report.status.update",
                    targetType: "report",
                    targetID: reportID.uuidString,
                    metadata: [
                        "previousStatus": transition.previousStatus,
                        "status": transition.status,
                        "resolutionCategory": transition.resolutionCategory ?? "",
                        "handledNotePresent": transition.handledNote == nil ? "false" : "true",
                        "handledNoteLength": "\(transition.handledNote?.count ?? 0)"
                    ],
                    on: database
                )
            }
        } catch {
            guard let existing = try await ReportModerationDecision.query(on: req.db)
                .filter(\.$report.$id == reportID)
                .filter(\.$idempotencyKey == idempotencyKey)
                .first()
            else {
                throw error
            }
            try Self.validateDuplicateDecision(existing, matches: body)
            guard let persisted = try await UserReport.find(reportID, on: req.db) else {
                throw Abort(.notFound, reason: "举报记录不存在。")
            }
            return try Self.response(from: persisted)
        }

        return try Self.response(from: report)
    }

    func reportDecisions(req: Request) async throws -> AdminReportDecisionPageResponse {
        let access = try await requireAdminAccess(req)
        try access.requires(.reportsRead)
        guard let rawID = req.parameters.get("reportID"), let reportID = UUID(uuidString: rawID) else {
            throw Abort(.badRequest, reason: "举报 ID 无效。")
        }
        guard try await UserReport.find(reportID, on: req.db) != nil else {
            throw Abort(.notFound, reason: "举报记录不存在。")
        }

        let query = try req.query.decode(AdminReportDecisionPageQuery.self)
        let limit = max(1, min(query.limit ?? 50, 100))
        let offset = max(0, query.cursor.flatMap(Int.init) ?? 0)
        let rows = try await ReportModerationDecision.query(on: req.db)
            .filter(\.$report.$id == reportID)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
            .range(offset..<(offset + limit + 1))
            .all()
        let page = Array(rows.prefix(limit))
        let nextOffset = offset + page.count
        return try AdminReportDecisionPageResponse(
            items: page.map(AdminReportDecisionResponse.init(decision:)),
            nextCursor: rows.count > limit ? "\(nextOffset)" : nil,
            hasMore: rows.count > limit
        )
    }

    func assignReportReviewer(req: Request) async throws -> ReportResponse {
        let access = try await requireAdminAccess(req)
        try access.requires(.reportsWrite)
        guard let rawID = req.parameters.get("reportID"), let reportID = UUID(uuidString: rawID) else {
            throw Abort(.badRequest, reason: "举报 ID 无效。")
        }
        guard let report = try await UserReport.find(reportID, on: req.db) else {
            throw Abort(.notFound, reason: "举报记录不存在。")
        }
        let body = try req.content.decode(AdminReportReviewerAssignmentRequest.self)
        let reviewerID = body.reviewerUserID
        let idempotencyKey = try Self.requiredIdempotencyKey(from: req)
        let scope = "report.reviewer.assign"
        let digest = Self.adminWriteDigest(
            scope: scope,
            targetID: reportID.uuidString,
            values: ["reviewerUserID": reviewerID?.uuidString ?? ""]
        )
        if try await Self.existingAdminWrite(
            on: req.db,
            scope: scope,
            actor: access.actor,
            idempotencyKey: idempotencyKey,
            targetID: reportID.uuidString,
            requestDigest: digest
        ) {
            return try Self.response(from: report)
        }
        guard !["resolved", "rejected"].contains(report.status) else {
            throw Abort(.conflict, reason: "已完成的举报不能改派审核人。")
        }

        if access.role != .superAdmin {
            guard let currentUserID = access.userID, reviewerID == currentUserID else {
                throw Abort(.forbidden, reason: "审核员只能领取自己的待处理举报。")
            }
            guard report.assignedReviewerUserID == nil || report.assignedReviewerUserID == currentUserID else {
                throw Abort(.conflict, reason: "举报已分配给其他审核员。")
            }
        }

        let reviewer: User?
        if let reviewerID {
            guard let user = try await User.find(reviewerID, on: req.db) else {
                throw Abort(.notFound, reason: "审核员账号不存在。")
            }
            guard user.status == UserStatus.active.rawValue,
                  let role = user.adminRole.flatMap(AdminRole.init(rawValue:)),
                  [.moderator, .superAdmin].contains(role)
            else {
                throw Abort(.badRequest, reason: "目标账号不是可用审核员。")
            }
            reviewer = user
        } else {
            guard access.role == .superAdmin else {
                throw Abort(.forbidden, reason: "只有超级管理员可以取消分配。")
            }
            reviewer = nil
        }

        let previousReviewerID = report.assignedReviewerUserID
        let previousReviewerActor = report.assignedReviewerActor
        let didChange = previousReviewerID != reviewerID
        do {
            try await req.db.transaction { database in
                if didChange {
                    report.assignedReviewerUserID = reviewerID
                    report.assignedReviewerActor = reviewer?.email
                    report.assignedAt = reviewerID == nil ? nil : Date()
                    try await report.update(on: database)
                }
                try await Self.recordAdminWrite(
                    on: database,
                    scope: scope,
                    actor: access.actor,
                    idempotencyKey: idempotencyKey,
                    targetID: reportID.uuidString,
                    requestDigest: digest
                )
                try await recordAudit(
                    req,
                    access: access,
                    action: scope,
                    targetType: "report",
                    targetID: reportID.uuidString,
                    metadata: [
                        "previousReviewerUserID": previousReviewerID?.uuidString ?? "",
                        "previousReviewerActor": previousReviewerActor ?? "",
                        "reviewerUserID": reviewerID?.uuidString ?? "",
                        "reviewerActor": reviewer?.email ?? "",
                        "operation": reviewerID == nil ? "unassigned" : "assigned",
                        "changed": didChange ? "true" : "false"
                    ],
                    on: database
                )
            }
        } catch {
            guard try await Self.existingAdminWrite(
                on: req.db,
                scope: scope,
                actor: access.actor,
                idempotencyKey: idempotencyKey,
                targetID: reportID.uuidString,
                requestDigest: digest
            ), let persisted = try await UserReport.find(reportID, on: req.db) else {
                throw error
            }
            return try Self.response(from: persisted)
        }

        return try Self.response(from: report)
    }

    func reportEvidence(req: Request) async throws -> AdminReportEvidencePageResponse {
        let access = try await requireAdminAccess(req)
        try access.requires(.reportsRead)
        guard let rawID = req.parameters.get("reportID"), let reportID = UUID(uuidString: rawID) else {
            throw Abort(.badRequest, reason: "举报 ID 无效。")
        }
        guard try await UserReport.find(reportID, on: req.db) != nil else {
            throw Abort(.notFound, reason: "举报记录不存在。")
        }

        let query = try req.query.decode(AdminReportEvidencePageQuery.self)
        let limit = max(1, min(query.limit ?? 50, 100))
        let offset = max(0, query.cursor.flatMap(Int.init) ?? 0)
        let rows = try await ReportModerationEvidence.query(on: req.db)
            .filter(\.$report.$id == reportID)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
            .range(offset..<(offset + limit + 1))
            .all()
        let page = Array(rows.prefix(limit))
        let nextOffset = offset + page.count
        return try AdminReportEvidencePageResponse(
            items: page.map(AdminReportEvidenceResponse.init(evidence:)),
            nextCursor: rows.count > limit ? "\(nextOffset)" : nil,
            hasMore: rows.count > limit
        )
    }

    func addReportEvidence(req: Request) async throws -> AdminReportEvidenceResponse {
        let access = try await requireAdminAccess(req)
        try access.requires(.reportsWrite)
        guard let rawID = req.parameters.get("reportID"), let reportID = UUID(uuidString: rawID) else {
            throw Abort(.badRequest, reason: "举报 ID 无效。")
        }
        guard try await UserReport.find(reportID, on: req.db) != nil else {
            throw Abort(.notFound, reason: "举报记录不存在。")
        }
        let body = try req.content.decode(AdminReportEvidenceCreateRequest.self)
        let (evidenceURL, host) = try Self.normalizedEvidenceURL(body.url)
        let label = try Self.normalizedEvidenceLabel(body.label)
        let idempotencyKey = try Self.requiredIdempotencyKey(from: req)
        if let existing = try await ReportModerationEvidence.query(on: req.db)
            .filter(\.$report.$id == reportID)
            .filter(\.$idempotencyKey == idempotencyKey)
            .first() {
            try Self.validateDuplicateEvidence(existing, url: evidenceURL, label: label)
            return try AdminReportEvidenceResponse(evidence: existing)
        }
        let evidence = ReportModerationEvidence(
            reportID: reportID,
            evidenceURL: evidenceURL,
            label: label,
            submittedByActor: access.actor,
            submittedByUserID: access.userID,
            submitterRole: access.role.rawValue,
            authenticationMethod: access.authenticationMethod.rawValue,
            requestID: req.headers.first(name: "X-Request-ID"),
            idempotencyKey: idempotencyKey
        )
        do {
            try await req.db.transaction { database in
                try await evidence.create(on: database)
                try await recordAudit(
                    req,
                    access: access,
                    action: "report.evidence.add",
                    targetType: "report",
                    targetID: reportID.uuidString,
                    metadata: [
                        "evidenceHost": host,
                        "labelPresent": label == nil ? "false" : "true",
                        "labelLength": "\(label?.count ?? 0)"
                    ],
                    on: database
                )
            }
        } catch {
            guard let existing = try await ReportModerationEvidence.query(on: req.db)
                .filter(\.$report.$id == reportID)
                .filter(\.$idempotencyKey == idempotencyKey)
                .first()
            else {
                throw error
            }
            try Self.validateDuplicateEvidence(existing, url: evidenceURL, label: label)
            return try AdminReportEvidenceResponse(evidence: existing)
        }
        return try AdminReportEvidenceResponse(evidence: evidence)
    }

    func auditEvents(req: Request) async throws -> AdminAuditEventPageResponse {
        let access = try await requireAdminAccess(req)
        try access.requires(.auditRead)
        let query = try req.query.decode(AdminAuditEventPageQuery.self)
        let limit = max(1, min(query.limit ?? 50, 100))
        let offset = max(0, query.cursor.flatMap(Int.init) ?? 0)
        let builder = AdminAuditEvent.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
        if let action = query.action?.trimmedNonEmpty {
            builder.filter(\.$action == action)
        }
        if let actor = query.actor?.trimmedNonEmpty {
            builder.filter(\.$actor == actor)
        }
        if let targetType = query.targetType?.trimmedNonEmpty {
            builder.filter(\.$targetType == targetType)
        }
        if let targetID = query.targetID?.trimmedNonEmpty {
            builder.filter(\.$targetID == targetID)
        }
        if let requestID = query.requestID?.trimmedNonEmpty {
            builder.filter(\.$requestID == requestID)
        }
        let from = try Self.parseAuditDate(query.from, field: "from")
        let to = try Self.parseAuditDate(query.to, field: "to")
        if let from, let to, from > to {
            throw Abort(.badRequest, reason: "审计时间范围无效。")
        }
        if let from {
            builder.filter(\.$createdAt >= from)
        }
        if let to {
            builder.filter(\.$createdAt <= to)
        }

        let rows = try await builder.range(offset..<(offset + limit + 1)).all()
        let page = Array(rows.prefix(limit))
        let nextOffset = offset + page.count
        return try AdminAuditEventPageResponse(
            items: page.map(AdminAuditEventResponse.init(event:)),
            nextCursor: rows.count > limit ? "\(nextOffset)" : nil,
            hasMore: rows.count > limit
        )
    }

    func currentAdmin(req: Request) async throws -> AdminCurrentUserResponse {
        let access = try await requireAdminAccess(req)
        return AdminCurrentUserResponse(
            actor: access.actor,
            userID: access.userID,
            role: access.role.rawValue,
            permissions: access.role.permissions.map(\.rawValue).sorted(),
            authenticationMethod: access.authenticationMethod.rawValue
        )
    }

    private func requireAdminAccess(_ req: Request) async throws -> AdminAccessContext {
        let configuration = req.application.adminConfiguration
        guard configuration.isEnabled else {
            throw Abort(.notFound)
        }

        let declaredActor = req.headers.first(name: "X-IM-Admin-Actor")?.trimmedNonEmpty ?? "admin"
        if let expectedSecret = configuration.sharedSecret?.trimmedNonEmpty {
            let headerSecret = req.headers.first(name: "X-IM-Admin-Secret")
            let bearer = bearerToken(from: req.headers.first(name: .authorization))
            if headerSecret == expectedSecret || bearer == expectedSecret {
                return AdminAccessContext(
                    actor: declaredActor,
                    role: .superAdmin,
                    userID: nil,
                    authenticationMethod: .sharedSecret
                )
            }
        }

        guard let token = bearerToken(from: req.headers.first(name: .authorization)) else {
            if configuration.sharedSecret?.trimmedNonEmpty != nil {
                throw Abort(.unauthorized, reason: "管理员凭据无效。")
            }
            guard req.application.environment != .production else {
                throw Abort(.internalServerError, reason: "IM_ADMIN_SHARED_SECRET is required when admin API is enabled in production.")
            }
            return AdminAccessContext(
                actor: declaredActor,
                role: .superAdmin,
                userID: nil,
                authenticationMethod: .sharedSecret
            )
        }

        let (user, _) = try await AuthService(app: req.application, db: req.db).authenticateAccessToken(token)
        guard let role = user.adminRole.flatMap(AdminRole.init(rawValue:)) else {
            throw Abort(.forbidden, reason: "当前账号没有后台管理权限。")
        }
        return AdminAccessContext(
            actor: user.email,
            role: role,
            userID: try user.requireID(),
            authenticationMethod: .accessToken
        )
    }

    private func recordAudit(
        _ req: Request,
        access: AdminAccessContext,
        action: String,
        targetType: String?,
        targetID: String?,
        metadata: [String: String] = [:],
        on database: any Database
    ) async throws {
        let event = AdminAuditEvent(
            actor: access.actor,
            action: action,
            targetType: targetType,
            targetID: targetID,
            requestID: req.headers.first(name: "X-Request-ID"),
            ipAddress: req.remoteAddress?.ipAddress,
            metadataJSON: try Self.encodeMetadata(
                metadata.merging([
                    "adminRole": access.role.rawValue,
                    "authenticationMethod": access.authenticationMethod.rawValue
                ], uniquingKeysWith: { current, _ in current })
            )
        )
        try await event.save(on: database)
    }

    private static func encodeMetadata(_ metadata: [String: String]) throws -> String {
        let data = try JSONEncoder().encode(metadata)
        return String(decoding: data, as: UTF8.self)
    }

    private static func normalizedEvidenceURL(_ value: String) throws -> (String, String) {
        let url = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.count <= 2_048,
              let components = URLComponents(string: url),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil
        else {
            throw Abort(.badRequest, reason: "证据链接必须是有效的 HTTPS URL。")
        }
        return (url, host)
    }

    private static func conversationID(from req: Request) throws -> UUID {
        guard let rawID = req.parameters.get("conversationID"), let conversationID = UUID(uuidString: rawID) else {
            throw Abort(.badRequest, reason: "会话 ID 无效。")
        }
        return conversationID
    }

    private static func filter(_ builder: QueryBuilder<UserReport>, statuses: [String]) {
        builder.group(.or) { group in
            for status in statuses {
                group.filter(\.$status == status)
            }
        }
    }

    private static func queueStatuses(requested: String?) throws -> [String] {
        guard let requested = requested?.trimmedNonEmpty?.lowercased() else {
            return ["pending", "reviewing"]
        }
        guard requested == "pending" || requested == "reviewing" else {
            throw Abort(.badRequest, reason: "举报队列只支持 pending 或 reviewing 状态。")
        }
        return [requested]
    }

    private static func ageSeconds(since date: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(date)))
    }

    private static func parseAuditDate(_ value: String?, field: String) throws -> Date? {
        guard let value = value?.trimmedNonEmpty else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        guard let date = fractional.date(from: value) ?? standard.date(from: value) else {
            throw Abort(.badRequest, reason: "审计参数 \(field) 必须是 ISO-8601 时间。")
        }
        return date
    }

    private static func normalizedEvidenceLabel(_ value: String?) throws -> String? {
        guard let label = value?.trimmedNonEmpty else {
            return nil
        }
        guard label.count <= 120 else {
            throw Abort(.badRequest, reason: "证据标签不能超过 120 个字符。")
        }
        return label
    }

    private static func normalizedGovernanceReason(_ value: String) throws -> String {
        let reason = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty, reason.count <= 500 else {
            throw Abort(.badRequest, reason: "后台群治理原因必须为 1 到 500 个字符。")
        }
        return reason
    }

    private static func validateDuplicateGovernanceCommand(
        _ existing: AdminConversationGovernanceCommand,
        conversationID: UUID,
        requestDigest: String
    ) throws {
        guard existing.conversationID == conversationID, existing.requestDigest == requestDigest else {
            throw Abort(.conflict, reason: "Idempotency-Key 已用于不同的后台群治理命令。")
        }
    }

    private static func acceptedResponse<T: Content>(_ content: T) throws -> Response {
        let response = Response(status: .accepted)
        try response.content.encode(content)
        return response
    }

    private static func requiredIdempotencyKey(from req: Request) throws -> String {
        guard let value = req.headers.first(name: "Idempotency-Key")?.trimmedNonEmpty,
              value.count <= 128,
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.value == 45 || scalar.value == 46 || scalar.value == 58 || scalar.value == 95
                      || (scalar.value >= 48 && scalar.value <= 57)
                      || (scalar.value >= 65 && scalar.value <= 90)
                      || (scalar.value >= 97 && scalar.value <= 122)
              })
        else {
            throw Abort(.badRequest, reason: "管理写操作必须提供有效的 Idempotency-Key。")
        }
        return value
    }

    private static func adminWriteDigest(scope: String, targetID: String, values: [String: String]) -> String {
        let fields = values.map { "\($0.key)=\($0.value)" }.sorted()
        let payload = (["scope=\(scope)", "targetID=\(targetID)"] + fields).joined(separator: "\n")
        return Data(SHA256.hash(data: Data(payload.utf8))).map { String(format: "%02x", $0) }.joined()
    }

    private static func existingAdminWrite(
        on database: any Database,
        scope: String,
        actor: String,
        idempotencyKey: String,
        targetID: String,
        requestDigest: String
    ) async throws -> Bool {
        guard let existing = try await AdminWriteIdempotencyRecord.query(on: database)
            .filter(\.$scope == scope)
            .filter(\.$actor == actor)
            .filter(\.$idempotencyKey == idempotencyKey)
            .first()
        else {
            return false
        }
        guard existing.targetID == targetID, existing.requestDigest == requestDigest else {
            throw Abort(.conflict, reason: "Idempotency-Key 已用于不同的管理写操作。")
        }
        return true
    }

    private static func recordAdminWrite(
        on database: any Database,
        scope: String,
        actor: String,
        idempotencyKey: String,
        targetID: String,
        requestDigest: String
    ) async throws {
        try await AdminWriteIdempotencyRecord(
            scope: scope,
            actor: actor,
            idempotencyKey: idempotencyKey,
            targetID: targetID,
            requestDigest: requestDigest
        ).create(on: database)
    }

    private static func validateDuplicateDecision(
        _ existing: ReportModerationDecision,
        matches request: ReportUpdateRequest
    ) throws {
        guard existing.status == request.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              existing.resolutionCategory == request.resolutionCategory?.trimmedNonEmpty?.lowercased(),
              existing.handledNote == request.handledNote?.trimmedNonEmpty
        else {
            throw Abort(.conflict, reason: "Idempotency-Key 已用于不同的举报处理请求。")
        }
    }

    private static func validateDuplicateEvidence(
        _ existing: ReportModerationEvidence,
        url: String,
        label: String?
    ) throws {
        guard existing.evidenceURL == url, existing.label == label else {
            throw Abort(.conflict, reason: "Idempotency-Key 已用于不同的证据请求。")
        }
    }

    private func bearerToken(from authorization: String?) -> String? {
        guard let authorization else {
            return nil
        }
        let prefix = "Bearer "
        guard authorization.hasPrefix(prefix) else {
            return nil
        }
        return String(authorization.dropFirst(prefix.count))
    }

    private static func response(from report: UserReport) throws -> ReportResponse {
        ReportResponse(
            id: try report.requireID(),
            targetType: report.targetType,
            targetID: report.targetID,
            reporterUserID: report.reporterUserID,
            conversationID: report.conversationID,
            messageID: report.messageID,
            reason: report.reason,
            detail: report.detail,
            status: report.status,
            handledNote: report.handledNote,
            messageSnapshotJSON: report.messageSnapshotJSON,
            assignedReviewerUserID: report.assignedReviewerUserID,
            assignedReviewerActor: report.assignedReviewerActor,
            assignedAt: report.assignedAt,
            createdAt: report.createdAt
        )
    }
}

struct AdminOverviewResponse: Content, Equatable, Sendable {
    struct UserCounts: Content, Equatable, Sendable {
        let total: Int
        let active: Int
        let disabled: Int
    }

    struct ReportCounts: Content, Equatable, Sendable {
        let pending: Int
        let reviewing: Int
    }

    let users: UserCounts
    let activeSessions: Int
    let reports: ReportCounts
}

struct AdminUserPageQuery: Content {
    let query: String?
    let status: String?
    let cursor: String?
    let limit: Int?
}

struct AdminUserResponse: Content, Equatable, Sendable {
    let id: UUID
    let email: String
    let status: String
    let displayName: String?
    let avatarPreset: String?
    let adminRole: String?
    let createdAt: Date?
    let updatedAt: Date?

    init(user: User) throws {
        id = try user.requireID()
        email = user.email
        status = user.status
        displayName = user.displayName
        avatarPreset = user.avatarPreset
        adminRole = user.adminRole
        createdAt = user.createdAt
        updatedAt = user.updatedAt
    }
}

struct AdminUserPageResponse: Content, Equatable, Sendable {
    let items: [AdminUserResponse]
    let nextCursor: String?
    let hasMore: Bool
}

struct AdminAuthSessionResponse: Content, Equatable, Sendable {
    let id: UUID
    let deviceID: String?
    let deviceName: String?
    let platform: String?
    let appVersion: String?
    let lastSeenAt: Date?
    let refreshExpiresAt: Date
    let revokedAt: Date?
    let revokedReason: String?
    let createdAt: Date?

    init(session: AuthSession) throws {
        id = try session.requireID()
        deviceID = session.deviceID
        deviceName = session.deviceName
        platform = session.platform
        appVersion = session.appVersion
        lastSeenAt = session.lastSeenAt
        refreshExpiresAt = session.refreshExpiresAt
        revokedAt = session.revokedAt
        revokedReason = session.revokedReason
        createdAt = session.createdAt
    }
}

struct AdminPushDeviceResponse: Content, Equatable, Sendable {
    let platform: String
    let isActive: Bool
    let tokenSuffix: String
    let sessionID: UUID?
    let createdAt: Date
    let updatedAt: Date

    init(device: PushDeviceToken) {
        platform = device.platform
        isActive = device.isActive
        tokenSuffix = String(device.token.suffix(8))
        sessionID = device.sessionID
        createdAt = device.createdAt
        updatedAt = device.updatedAt
    }
}

struct AdminUserSecurityOverviewResponse: Content, Equatable, Sendable {
    let user: AdminUserResponse
    let sessions: [AdminAuthSessionResponse]
    let pushDevices: [AdminPushDeviceResponse]
}

struct AdminUserStatusUpdateRequest: Content {
    let status: String
    let note: String?
}

struct AdminUserRoleUpdateRequest: Content {
    let adminRole: String?
    let note: String?
}

struct AdminConversationInspectionQuery: Content {
    let cursor: String?
    let limit: Int?
}

struct AdminConversationMessagePageQuery: Content {
    let beforeSequence: Int?
    let limit: Int?
}

struct AdminConversationGovernanceCommandRequest: Content {
    let action: String
    let muteAll: Bool?
    let groupLifecycleState: String?
    let memberUserID: UUID?
    let confirmed: Bool?
    let reason: String

    init(
        action: String,
        muteAll: Bool? = nil,
        groupLifecycleState: String? = nil,
        memberUserID: UUID? = nil,
        confirmed: Bool? = nil,
        reason: String
    ) {
        self.action = action
        self.muteAll = muteAll
        self.groupLifecycleState = groupLifecycleState
        self.memberUserID = memberUserID
        self.confirmed = confirmed
        self.reason = reason
    }
}

struct AdminConversationGovernanceCommandResponse: Content, Equatable, Sendable {
    let id: UUID
    let action: String
    let conversationID: UUID
    let targetShardID: String
    let targetCellID: String
    let targetRouteVersion: Int
    let requestedMuteAll: Bool
    let requestedGroupLifecycleState: String
    let targetMemberUserID: UUID?
    let destructiveConfirmed: Bool
    let status: String
    let attemptCount: Int
    let lastErrorCode: String?
    let acceptedAt: Date
    let appliedAt: Date?

    init(command: AdminConversationGovernanceCommand) throws {
        id = try command.requireID()
        action = command.action
        conversationID = command.conversationID
        targetShardID = command.targetShardID
        targetCellID = command.targetCellID
        targetRouteVersion = command.targetRouteVersion
        requestedMuteAll = command.requestedMuteAll
        requestedGroupLifecycleState = command.requestedGroupLifecycleState
        targetMemberUserID = command.targetMemberUserID
        destructiveConfirmed = command.destructiveConfirmed
        status = command.status
        attemptCount = command.attemptCount
        lastErrorCode = command.lastErrorCode
        acceptedAt = command.acceptedAt
        appliedAt = command.appliedAt
    }
}

struct AdminConversationResponse: Content, Equatable, Sendable {
    let id: UUID
    let title: String?
    let notice: String?
    let avatarPreset: String?
    let kind: String
    let directMessagingState: String
    let groupLifecycleState: String
    let muteAll: Bool
    let lastMessageSequence: Int
    let membershipRevision: Date?
    let createdAt: Date?
    let updatedAt: Date

    init(conversation: Conversation) throws {
        id = try conversation.requireID()
        title = conversation.title
        notice = conversation.notice
        avatarPreset = conversation.avatarPreset
        kind = conversation.kind
        directMessagingState = conversation.directMessagingState
        groupLifecycleState = conversation.groupLifecycleState
        muteAll = conversation.muteAll
        lastMessageSequence = conversation.lastMessageSequence
        membershipRevision = conversation.membershipRevision
        createdAt = conversation.createdAt
        updatedAt = conversation.updatedAt
    }
}

struct AdminConversationMemberResponse: Content, Equatable, Sendable {
    let userID: UUID
    let email: String
    let displayName: String?
    let userStatus: String
    let role: String
    let memberNickname: String?
    let lastReadSequence: Int
    let visibleFromSequence: Int
    let joinedAt: Date?

    init(member: ConversationMember, user: User) throws {
        userID = try user.requireID()
        email = user.email
        displayName = user.displayName
        userStatus = user.status
        role = member.role
        memberNickname = member.memberNickname
        lastReadSequence = member.lastReadSequence
        visibleFromSequence = member.visibleFromSequence
        joinedAt = member.joinedAt
    }
}

struct AdminConversationMessageMetadataResponse: Content, Equatable, Sendable {
    let id: UUID
    let senderUserID: UUID
    let serverSequence: Int
    let timelineSequence: Int
    let kind: String
    let createdAt: Date?

    init(message: ConversationMessage) throws {
        id = try message.requireID()
        senderUserID = message.$sender.id
        serverSequence = message.serverSequence
        timelineSequence = message.timelineSequence
        kind = message.kind
        createdAt = message.createdAt
    }
}

struct AdminConversationInspectionResponse: Content, Equatable, Sendable {
    let conversation: AdminConversationResponse
    let members: [AdminConversationMemberResponse]
    let memberTotal: Int
    let nextMemberCursor: String?
    let hasMoreMembers: Bool
    let latestMessage: AdminConversationMessageMetadataResponse?
}

struct AdminConversationMessageResponse: Content, Equatable, Sendable {
    let id: UUID
    let senderUserID: UUID
    let senderEmail: String
    let serverSequence: Int
    let timelineSequence: Int
    let content: IMMessageContent
    let derivedState: IMMessageDerivedState
    let createdAt: Date?

    init(message: ConversationMessage, sender: User) throws {
        id = try message.requireID()
        senderUserID = try sender.requireID()
        senderEmail = sender.email
        serverSequence = message.serverSequence
        timelineSequence = message.timelineSequence
        content = try message.decodedContent()
        derivedState = try message.decodedDerivedState()
        createdAt = message.createdAt
    }
}

struct AdminConversationMessagePageResponse: Content, Equatable, Sendable {
    let items: [AdminConversationMessageResponse]
    let nextBeforeSequence: Int?
    let hasMore: Bool
}

struct AdminCurrentUserResponse: Content, Equatable, Sendable {
    let actor: String
    let userID: UUID?
    let role: String
    let permissions: [String]
    let authenticationMethod: String
}

struct AdminReportReviewerAssignmentRequest: Content {
    let reviewerUserID: UUID?
}

struct AdminAuditEventPageQuery: Content {
    let action: String?
    let actor: String?
    let targetType: String?
    let targetID: String?
    let requestID: String?
    let from: String?
    let to: String?
    let cursor: String?
    let limit: Int?
}

enum AdminReportQueueScope: String, Sendable {
    case all
    case unassigned
    case mine

    init(validating value: String) throws {
        guard let scope = Self(rawValue: value) else {
            throw Abort(.badRequest, reason: "举报队列范围必须是 all、unassigned 或 mine。")
        }
        self = scope
    }
}

struct AdminReportQueueQuery: Content {
    let scope: String?
    let status: String?
    let cursor: String?
    let limit: Int?
}

struct AdminReportQueueSummary: Content, Equatable, Sendable {
    let pendingCount: Int
    let reviewingCount: Int
    let unassignedActiveCount: Int
    let oldestPendingAgeSeconds: Int?
    let oldestReviewingAgeSeconds: Int?
}

struct AdminReportQueueItem: Content, Equatable, Sendable {
    let report: ReportResponse
    let ageSeconds: Int
}

struct AdminReportQueueResponse: Content, Equatable, Sendable {
    let scope: String
    let summary: AdminReportQueueSummary
    let items: [AdminReportQueueItem]
    let nextCursor: String?
    let hasMore: Bool
}

struct AdminAuditEventResponse: Content, Equatable, Sendable {
    let id: UUID
    let actor: String
    let action: String
    let targetType: String?
    let targetID: String?
    let requestID: String?
    let ipAddress: String?
    let metadataJSON: String?
    let createdAt: Date?

    init(event: AdminAuditEvent) throws {
        id = try event.requireID()
        actor = event.actor
        action = event.action
        targetType = event.targetType
        targetID = event.targetID
        requestID = event.requestID
        ipAddress = event.ipAddress
        metadataJSON = event.metadataJSON
        createdAt = event.createdAt
    }
}

struct AdminAuditEventPageResponse: Content, Equatable, Sendable {
    let items: [AdminAuditEventResponse]
    let nextCursor: String?
    let hasMore: Bool
}

struct AdminReportDecisionPageQuery: Content {
    let cursor: String?
    let limit: Int?
}

struct AdminReportDecisionResponse: Content, Equatable, Sendable {
    let id: UUID
    let reviewerActor: String
    let reviewerUserID: UUID?
    let reviewerRole: String
    let authenticationMethod: String
    let previousStatus: String
    let status: String
    let resolutionCategory: String?
    let handledNote: String?
    let requestID: String?
    let createdAt: Date?

    init(decision: ReportModerationDecision) throws {
        id = try decision.requireID()
        reviewerActor = decision.reviewerActor
        reviewerUserID = decision.reviewerUserID
        reviewerRole = decision.reviewerRole
        authenticationMethod = decision.authenticationMethod
        previousStatus = decision.previousStatus
        status = decision.status
        resolutionCategory = decision.resolutionCategory
        handledNote = decision.handledNote
        requestID = decision.requestID
        createdAt = decision.createdAt
    }
}

struct AdminReportDecisionPageResponse: Content, Equatable, Sendable {
    let items: [AdminReportDecisionResponse]
    let nextCursor: String?
    let hasMore: Bool
}

struct AdminReportEvidenceCreateRequest: Content {
    let url: String
    let label: String?
}

struct AdminReportEvidencePageQuery: Content {
    let cursor: String?
    let limit: Int?
}

struct AdminReportEvidenceResponse: Content, Equatable, Sendable {
    let id: UUID
    let url: String
    let label: String?
    let submittedByActor: String
    let submittedByUserID: UUID?
    let submitterRole: String
    let authenticationMethod: String
    let requestID: String?
    let createdAt: Date?

    init(evidence: ReportModerationEvidence) throws {
        id = try evidence.requireID()
        url = evidence.evidenceURL
        label = evidence.label
        submittedByActor = evidence.submittedByActor
        submittedByUserID = evidence.submittedByUserID
        submitterRole = evidence.submitterRole
        authenticationMethod = evidence.authenticationMethod
        requestID = evidence.requestID
        createdAt = evidence.createdAt
    }
}

struct AdminReportEvidencePageResponse: Content, Equatable, Sendable {
    let items: [AdminReportEvidenceResponse]
    let nextCursor: String?
    let hasMore: Bool
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
