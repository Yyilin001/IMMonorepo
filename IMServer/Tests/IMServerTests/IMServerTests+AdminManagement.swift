@testable import IMServer
import Fluent
import FluentSQLiteDriver
import SQLKit
import Vapor
import VaporTesting
import Testing

extension IMServerTests {
    private var adminSecret: String {
        "admin-secret-0123456789abcdef"
    }

    @Test("Admin API requires configured admin secret")
    func adminAPIRequiresConfiguredSecret() async throws {
        let originalSecret = Environment.get("IM_ADMIN_SHARED_SECRET")
        defer { restoreEnvironment("IM_ADMIN_SHARED_SECRET", to: originalSecret) }
        setenv("IM_ADMIN_SHARED_SECRET", adminSecret, 1)

        try await withApp(configure: configure) { app in
            try await app.testing().test(.GET, "admin/api/overview", afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })

            try await app.testing().test(.GET, "admin/api/overview", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "tester")
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(AdminOverviewResponse.self)
                #expect(payload.users.total >= 1)
            })
        }
    }

    @Test("Admin can disable user, revoke sessions, and audit action")
    func adminCanDisableUserAndAuditAction() async throws {
        let originalSecret = Environment.get("IM_ADMIN_SHARED_SECRET")
        defer { restoreEnvironment("IM_ADMIN_SHARED_SECRET", to: originalSecret) }
        setenv("IM_ADMIN_SHARED_SECRET", adminSecret, 1)

        try await withApp(configure: configure) { app in
            var accessToken = ""
            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                accessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            let existingUser = try await user(email: loginRequest.email, on: app)
            let userID = try existingUser.requireID()

            try await app.testing().test(.PATCH, "admin/api/users/\(userID.uuidString)/status", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                try req.content.encode(AdminUserStatusUpdateRequest(status: "disabled", note: "missing key"))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            try await app.testing().test(.PATCH, "admin/api/users/\(userID.uuidString)/status", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "tester")
                req.headers.add(name: "Idempotency-Key", value: "disable-user")
                try req.content.encode(AdminUserStatusUpdateRequest(status: "disabled", note: "test disable"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(AdminUserResponse.self)
                #expect(payload.status == UserStatus.disabled.rawValue)
            })

            let updatedUser = try await user(email: loginRequest.email, on: app)
            #expect(updatedUser.status == UserStatus.disabled.rawValue)

            try await app.testing().test(.PATCH, "admin/api/users/\(userID.uuidString)/status", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "tester")
                req.headers.add(name: "Idempotency-Key", value: "disable-user")
                try req.content.encode(AdminUserStatusUpdateRequest(status: "disabled", note: "test disable"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.PATCH, "admin/api/users/\(userID.uuidString)/status", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "tester")
                req.headers.add(name: "Idempotency-Key", value: "disable-user")
                try req.content.encode(AdminUserStatusUpdateRequest(status: "active", note: "different request"))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })

            let activeSessionCount = try await AuthSession.query(on: app.db)
                .filter(\.$user.$id == userID)
                .filter(\.$revokedAt == nil)
                .count()
            #expect(activeSessionCount == 0)

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })

            let statusAuditCount = try await AdminAuditEvent.query(on: app.db)
                .filter(\.$action == "user.status.update")
                .filter(\.$targetID == userID.uuidString)
                .count()
            #expect(statusAuditCount == 1)

            try await app.testing().test(.GET, "admin/api/audit-events", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(AdminAuditEventPageResponse.self)
                #expect(payload.items.contains(where: { $0.action == "user.status.update" && $0.targetID == userID.uuidString }))
            })
        }
    }

    @Test("Admin can process reports and audit action")
    func adminCanProcessReportsAndAuditAction() async throws {
        let originalSecret = Environment.get("IM_ADMIN_SHARED_SECRET")
        defer { restoreEnvironment("IM_ADMIN_SHARED_SECRET", to: originalSecret) }
        setenv("IM_ADMIN_SHARED_SECRET", adminSecret, 1)

        try await withApp(configure: configure) { app in
            var accessToken = ""
            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                accessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            var reportID: UUID?
            try await app.testing().test(.POST, "api/reports", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(ReportCreateRequest(
                    targetType: "user",
                    targetID: UUID().uuidString,
                    conversationID: nil,
                    messageID: nil,
                    reason: "spam",
                    detail: "test report"
                ))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                reportID = try res.content.decode(ReportResponse.self).id
            })

            let id = try #require(reportID)
            try await app.testing().test(.PATCH, "admin/api/reports/\(id.uuidString)", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "tester")
                req.headers.add(name: "Idempotency-Key", value: "admin-process-report")
                try req.content.encode(ReportUpdateRequest(status: "resolved", handledNote: "handled", resolutionCategory: "action_taken"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(ReportResponse.self)
                #expect(payload.status == "resolved")
                #expect(payload.handledNote == "handled")
            })

            try await app.testing().test(.GET, "admin/api/reports?status=resolved", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(ReportPageResponse.self)
                #expect(payload.items.contains(where: { $0.id == id }))
            })

            let auditCount = try await AdminAuditEvent.query(on: app.db)
                .filter(\.$action == "report.status.update")
                .count()
            #expect(auditCount >= 1)
        }
    }

    @Test("Conversation inspection is role-scoped, shard-routed, and audited without logging message content")
    func conversationInspectionIsRoleScopedAndAudited() async throws {
        let originalSecret = Environment.get("IM_ADMIN_SHARED_SECRET")
        defer { restoreEnvironment("IM_ADMIN_SHARED_SECRET", to: originalSecret) }
        setenv("IM_ADMIN_SHARED_SECRET", adminSecret, 1)

        try await withApp(configure: configure) { app in
            let owner = try await makeUser(email: "admin-conversation-owner@example.com", on: app)
            let member = try await makeUser(email: "admin-conversation-member@example.com", on: app)
            let conversation = Conversation(
                title: "Admin inspection group",
                notice: "Support-visible metadata",
                avatarPreset: .ocean,
                kind: .group,
                muteAll: true,
                lastMessageSequence: 4
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            try await ConversationMember(
                conversationID: conversationID,
                userID: try owner.requireID(),
                role: .owner,
                lastReadSequence: 4,
                visibleFromSequence: 1
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try member.requireID(),
                role: .member,
                lastReadSequence: 2,
                visibleFromSequence: 1
            ).create(on: app.db)
            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: try owner.requireID(),
                serverSequence: 4,
                timelineSequence: 4,
                clientMessageID: "admin-inspection-message",
                content: .richText(.plain("private message body"))
            )
            try await message.create(on: app.db)

            try await app.testing().test(.GET, "admin/api/conversations/\(conversationID.uuidString)", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "conversation-auditor")
                req.headers.add(name: "X-Request-ID", value: "conversation-inspect-request")
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(AdminConversationInspectionResponse.self)
                #expect(payload.conversation.id == conversationID)
                #expect(payload.conversation.title == "Admin inspection group")
                #expect(payload.memberTotal == 2)
                #expect(payload.members.map(\.email).sorted() == [owner.email, member.email].sorted())
                #expect(payload.latestMessage?.timelineSequence == 4)
                #expect(payload.latestMessage?.kind == IMMessageContentType.richText.rawValue)
                #expect(String(describing: payload).contains("private message body") == false)
            })

            try await app.testing().test(.GET, "admin/api/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(AdminConversationMessagePageResponse.self)
                #expect(payload.items.count == 1)
                #expect(payload.items.first?.content.previewText == "private message body")
                #expect(payload.items.first?.senderEmail == owner.email)
            })

            let support = try await makeUser(email: "admin-conversation-support@example.com", on: app)
            support.adminRole = AdminRole.support.rawValue
            try await support.update(on: app.db)
            let supportToken = try await loginAccessToken(
                email: support.email,
                password: "password1234",
                deviceID: "admin-conversation-support-device",
                on: app
            )
            try await app.testing().test(.GET, "admin/api/conversations/\(conversationID.uuidString)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: supportToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            try await app.testing().test(.GET, "admin/api/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: supportToken)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            let conversationAudit = try #require(
                try await AdminAuditEvent.query(on: app.db)
                    .filter(\.$action == "conversation.inspect")
                    .filter(\.$targetID == conversationID.uuidString)
                    .filter(\.$requestID == "conversation-inspect-request")
                    .first()
            )
            #expect(conversationAudit.metadataJSON?.contains("private message body") == false)
            let messageAuditCount = try await AdminAuditEvent.query(on: app.db)
                .filter(\.$action == "conversation.messages.inspect")
                .filter(\.$targetID == conversationID.uuidString)
                .count()
            #expect(messageAuditCount == 1)
        }
    }

    @Test("Admin conversation inspection resolves identities from the primary user directory")
    func adminConversationInspectionUsesPrimaryUserDirectoryAcrossShards() async throws {
        let originalSecret = Environment.get("IM_ADMIN_SHARED_SECRET")
        defer { restoreEnvironment("IM_ADMIN_SHARED_SECRET", to: originalSecret) }
        setenv("IM_ADMIN_SHARED_SECRET", adminSecret, 1)

        try await withApp(configure: configure) { app in
            let primaryUser = try await makeUser(email: "primary-directory-user@example.com", on: app)
            let primaryUserID = try primaryUser.requireID()
            let shardID = "admin-inspection-shard"
            let shardDatabaseID = DatabaseID(string: "test-admin-inspection-shard")
            app.databases.use(.sqlite(.memory), as: shardDatabaseID)
            app.migrations.add(governanceConversationShardMigrations(), to: shardDatabaseID)
            try await app.autoMigrate()

            let shardDatabase = app.db(shardDatabaseID)
            let conversation = Conversation(title: "Cross shard inspection", kind: .group)
            try await conversation.create(on: shardDatabase)
            let conversationID = try conversation.requireID()
            try await ConversationMember(
                conversationID: conversationID,
                userID: primaryUserID,
                role: .owner,
                visibleFromSequence: 1
            ).create(on: shardDatabase)
            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: primaryUserID,
                serverSequence: 1,
                timelineSequence: 1,
                clientMessageID: "cross-shard-admin-inspection-message",
                content: .richText(.plain("central directory sender"))
            )
            try await message.create(on: shardDatabase)

            app.conversationShardRouter = DirectoryBackedConversationShardRouter(
                app: app,
                shardIDs: [shardID],
                shardDatabaseIDs: [shardID: shardDatabaseID],
                shardReplicaDatabaseIDs: [:],
                directory: GovernanceTestConversationDirectory(
                    shardIDsByConversationID: [conversationID: shardID]
                )
            )

            try await app.testing().test(.GET, "admin/api/conversations/\(conversationID.uuidString)", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(AdminConversationInspectionResponse.self)
                #expect(payload.members.map(\.email) == [primaryUser.email])
                #expect(payload.members.map(\.userStatus) == [UserStatus.active.rawValue])
            })
            try await app.testing().test(.GET, "admin/api/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(AdminConversationMessagePageResponse.self)
                #expect(payload.items.map(\.senderEmail) == [primaryUser.email])
            })
        }
    }

    @Test("User conversation member listing resolves profiles from the primary user directory")
    func userMemberListingUsesPrimaryUserDirectoryAcrossShards() async throws {
        try await withApp(configure: configure) { app in
            let primaryUser = try await makeUser(email: "primary-member-directory@example.com", on: app)
            let primaryUserID = try primaryUser.requireID()
            let shardID = "member-directory-shard"
            let shardDatabaseID = DatabaseID(string: "test-member-directory-shard")
            app.databases.use(.sqlite(.memory), as: shardDatabaseID)
            app.migrations.add(governanceConversationShardMigrations(), to: shardDatabaseID)
            try await app.autoMigrate()

            let shardDatabase = app.db(shardDatabaseID)
            let conversation = Conversation(title: "Cross shard members", kind: .group)
            try await conversation.create(on: shardDatabase)
            let conversationID = try conversation.requireID()
            try await ConversationMember(
                conversationID: conversationID,
                userID: primaryUserID,
                role: .owner,
                visibleFromSequence: 1
            ).create(on: shardDatabase)

            app.conversationShardRouter = DirectoryBackedConversationShardRouter(
                app: app,
                shardIDs: [shardID],
                shardDatabaseIDs: [shardID: shardDatabaseID],
                shardReplicaDatabaseIDs: [:],
                directory: GovernanceTestConversationDirectory(
                    shardIDsByConversationID: [conversationID: shardID]
                )
            )

            let response = try await ConversationEventualReadService(app: app).listMemberPage(
                in: conversationID,
                for: primaryUserID,
                cursor: nil,
                limit: 50,
                query: nil
            )
            #expect(response.items.map(\.email) == [primaryUser.email])
            #expect(response.items.map(\.displayTitle) == [primaryUser.email])
        }
    }

    @Test("User conversation summary resolves a direct peer from the primary user directory")
    func userConversationSummaryUsesPrimaryUserDirectoryAcrossShards() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await makeUser(email: "primary-direct-owner@example.com", on: app)
            let peer = try await makeUser(email: "primary-direct-peer@example.com", on: app)
            let ownerID = try owner.requireID()
            let peerID = try peer.requireID()
            let shardID = "summary-directory-shard"
            let shardDatabaseID = DatabaseID(string: "test-summary-directory-shard")
            app.databases.use(.sqlite(.memory), as: shardDatabaseID)
            app.migrations.add(governanceConversationShardMigrations(), to: shardDatabaseID)
            try await app.autoMigrate()

            let shardDatabase = app.db(shardDatabaseID)
            let conversation = Conversation(title: nil, kind: .direct)
            try await conversation.create(on: shardDatabase)
            let conversationID = try conversation.requireID()
            try await ConversationMember(
                conversationID: conversationID,
                userID: ownerID,
                role: .member,
                visibleFromSequence: 1
            ).create(on: shardDatabase)
            try await ConversationMember(
                conversationID: conversationID,
                userID: peerID,
                role: .member,
                visibleFromSequence: 1
            ).create(on: shardDatabase)

            app.conversationShardRouter = DirectoryBackedConversationShardRouter(
                app: app,
                shardIDs: [shardID],
                shardDatabaseIDs: [shardID: shardDatabaseID],
                shardReplicaDatabaseIDs: [:],
                directory: GovernanceTestConversationDirectory(
                    shardIDsByConversationID: [conversationID: shardID]
                )
            )

            let response = try await ConversationStrongReadService(app: app).conversationSummary(
                conversationID: conversationID,
                for: ownerID
            )
            #expect(response.directPeer?.id == peerID)
            #expect(response.directPeer?.email == peer.email)

            let summaryID = ConversationUserSummary.recordID(
                ownerUserID: ownerID,
                conversationID: conversationID
            )
            let summary = try #require(try await ConversationUserSummary.find(summaryID, on: shardDatabase))
            #expect(summary.directPeerEmail == peer.email)
        }
    }

    @Test("Admin group governance command is accepted centrally and applied idempotently through shard outbox")
    func adminGroupGovernanceCommandIsAppliedThroughShardOutbox() async throws {
        let originalSecret = Environment.get("IM_ADMIN_SHARED_SECRET")
        defer { restoreEnvironment("IM_ADMIN_SHARED_SECRET", to: originalSecret) }
        setenv("IM_ADMIN_SHARED_SECRET", adminSecret, 1)

        try await withApp(configure: configure) { app in
            let owner = try await makeUser(email: "admin-governance-owner@example.com", on: app)
            let member = try await makeUser(email: "admin-governance-member@example.com", on: app)
            let conversation = Conversation(title: "Governance Group", kind: .group)
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            try await ConversationMember(
                conversationID: conversationID,
                userID: try owner.requireID(),
                role: .owner,
                visibleFromSequence: 1
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try member.requireID(),
                visibleFromSequence: 1
            ).create(on: app.db)

            var commandID: UUID?
            try await app.testing().test(.POST, "admin/api/conversations/\(conversationID.uuidString)/governance-commands", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "governance-auditor")
                req.headers.add(name: "X-Request-ID", value: "governance-accepted-request")
                req.headers.add(name: "Idempotency-Key", value: "mute-governance-group")
                try req.content.encode(AdminConversationGovernanceCommandRequest(
                    action: AdminConversationGovernanceAction.groupMuteAllSet.rawValue,
                    muteAll: true,
                    reason: "contain abuse"
                ))
            }, afterResponse: { res async throws in
                #expect(res.status == .accepted)
                let payload = try res.content.decode(AdminConversationGovernanceCommandResponse.self)
                commandID = payload.id
                #expect(payload.status == AdminConversationGovernanceCommandStatus.pending.rawValue)
                #expect(payload.requestedMuteAll)
                #expect(payload.targetShardID == SingleShardConversationShardRouter.defaultShardID)
            })

            let id = try #require(commandID)
            try await app.testing().test(.POST, "admin/api/conversations/\(conversationID.uuidString)/governance-commands", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "governance-auditor")
                req.headers.add(name: "Idempotency-Key", value: "mute-governance-group")
                try req.content.encode(AdminConversationGovernanceCommandRequest(
                    action: AdminConversationGovernanceAction.groupMuteAllSet.rawValue,
                    muteAll: true,
                    reason: "contain abuse"
                ))
            }, afterResponse: { res async throws in
                #expect(res.status == .accepted)
                #expect(try res.content.decode(AdminConversationGovernanceCommandResponse.self).id == id)
            })
            try await app.testing().test(.POST, "admin/api/conversations/\(conversationID.uuidString)/governance-commands", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "governance-auditor")
                req.headers.add(name: "Idempotency-Key", value: "mute-governance-group")
                try req.content.encode(AdminConversationGovernanceCommandRequest(
                    action: AdminConversationGovernanceAction.groupMuteAllSet.rawValue,
                    muteAll: false,
                    reason: "different request"
                ))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })

            let processor = AdminConversationGovernanceCommandProcessor(app: app)
            let applied = try await processor.process(commandID: id)
            #expect(applied.statusEnum == .applied)

            // Reconstruct the recoverable interval after the shard transaction commits but before
            // the primary applied-state transaction persists. The shard side-effect record is the
            // durable fact, so retrying must only repair central state and must not enqueue again.
            try await AdminAuditEvent.query(on: app.db)
                .filter(\.$action == "conversation.governance.command.applied")
                .filter(\.$targetID == conversationID.uuidString)
                .delete()
            let recoverableCommand = try #require(
                try await AdminConversationGovernanceCommand.find(id, on: app.db)
            )
            recoverableCommand.statusEnum = .applying
            recoverableCommand.appliedAt = nil
            recoverableCommand.processingToken = "active-governance-worker"
            recoverableCommand.processingStartedAt = Date()
            recoverableCommand.updatedAt = Date()
            try await recoverableCommand.update(on: app.db)
            let skipped = try await processor.processPending(limit: 10)
            #expect(skipped.isEmpty)

            recoverableCommand.processingStartedAt = Date().addingTimeInterval(-301)
            recoverableCommand.updatedAt = Date().addingTimeInterval(-301)
            try await recoverableCommand.update(on: app.db)
            let recovered = try #require(try await processor.processPending(limit: 10).first)
            #expect(recovered.statusEnum == .applied)

            let persistedConversation = try #require(try await Conversation.find(conversationID, on: app.db))
            #expect(persistedConversation.muteAll)
            let sideEffectKey = "admin-governance:\(id.uuidString.lowercased())"
            let sideEffectCount = try await ConversationDomainEventSideEffect.query(on: app.db)
                .filter(\.$id == sideEffectKey)
                .count()
            #expect(sideEffectCount == 1)
            let eventCount = try await ConversationDomainEvent.query(on: app.db)
                .filter(\.$sideEffectKey == sideEffectKey)
                .filter(\.$eventType == ConversationDomainEventType.metadataUpdated.rawValue)
                .count()
            #expect(eventCount == 1)

            try await app.testing().test(.GET, "admin/api/conversations/\(conversationID.uuidString)/governance-commands/\(id.uuidString)", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(AdminConversationGovernanceCommandResponse.self)
                #expect(payload.status == AdminConversationGovernanceCommandStatus.applied.rawValue)
                #expect(payload.appliedAt != nil)
            })

            let acceptedAudit = try #require(
                try await AdminAuditEvent.query(on: app.db)
                    .filter(\.$action == "conversation.governance.command.accepted")
                    .filter(\.$targetID == conversationID.uuidString)
                    .first()
            )
            #expect(acceptedAudit.metadataJSON?.contains("contain abuse") == false)
            let appliedAuditCount = try await AdminAuditEvent.query(on: app.db)
                .filter(\.$action == "conversation.governance.command.applied")
                .filter(\.$targetID == conversationID.uuidString)
                .count()
            #expect(appliedAuditCount == 1)
        }
    }

    @Test("Admin group governance removes a member only after destructive confirmation")
    func adminGroupGovernanceRemovesMemberAfterConfirmation() async throws {
        let originalSecret = Environment.get("IM_ADMIN_SHARED_SECRET")
        defer { restoreEnvironment("IM_ADMIN_SHARED_SECRET", to: originalSecret) }
        setenv("IM_ADMIN_SHARED_SECRET", adminSecret, 1)

        try await withApp(configure: configure) { app in
            let owner = try await makeUser(email: "admin-remove-owner@example.com", on: app)
            let target = try await makeUser(email: "admin-remove-target@example.com", on: app)
            let remaining = try await makeUser(email: "admin-remove-remaining@example.com", on: app)
            let conversation = Conversation(title: "Governance Removal Group", kind: .group)
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            let ownerID = try owner.requireID()
            let targetID = try target.requireID()
            let remainingID = try remaining.requireID()
            try await ConversationMember(
                conversationID: conversationID,
                userID: ownerID,
                role: .owner,
                visibleFromSequence: 1
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: targetID,
                visibleFromSequence: 1
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: remainingID,
                visibleFromSequence: 1
            ).create(on: app.db)

            try await app.testing().test(.POST, "admin/api/conversations/\(conversationID.uuidString)/governance-commands", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "governance-removal-auditor")
                req.headers.add(name: "Idempotency-Key", value: "remove-target-without-confirmation")
                try req.content.encode(AdminConversationGovernanceCommandRequest(
                    action: AdminConversationGovernanceAction.groupMemberRemove.rawValue,
                    memberUserID: targetID,
                    reason: "remove abusive member"
                ))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            var commandID: UUID?
            try await app.testing().test(.POST, "admin/api/conversations/\(conversationID.uuidString)/governance-commands", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "governance-removal-auditor")
                req.headers.add(name: "Idempotency-Key", value: "remove-governance-target")
                try req.content.encode(AdminConversationGovernanceCommandRequest(
                    action: AdminConversationGovernanceAction.groupMemberRemove.rawValue,
                    memberUserID: targetID,
                    confirmed: true,
                    reason: "remove abusive member"
                ))
            }, afterResponse: { res async throws in
                #expect(res.status == .accepted)
                let payload = try res.content.decode(AdminConversationGovernanceCommandResponse.self)
                #expect(payload.action == AdminConversationGovernanceAction.groupMemberRemove.rawValue)
                #expect(payload.targetMemberUserID == targetID)
                #expect(payload.destructiveConfirmed)
                commandID = payload.id
            })

            let id = try #require(commandID)
            let processor = AdminConversationGovernanceCommandProcessor(app: app)
            let applied = try await processor.process(commandID: id)
            #expect(applied.statusEnum == .applied)
            #expect(try await processor.process(commandID: id).statusEnum == .applied)

            #expect(
                try await ConversationMember.query(on: app.db)
                    .filter(\.$conversation.$id == conversationID)
                    .filter(\.$user.$id == targetID)
                    .first() == nil
            )
            #expect(
                try await ConversationMember.query(on: app.db)
                    .filter(\.$conversation.$id == conversationID)
                    .count() == 2
            )
            let sideEffectKey = "admin-governance:\(id.uuidString.lowercased())"
            #expect(
                try await ConversationDomainEvent.query(on: app.db)
                    .filter(\.$sideEffectKey == sideEffectKey)
                    .filter(\.$eventType == ConversationDomainEventType.membershipRemoved.rawValue)
                    .count() == 1
            )
            #expect(
                try await ConversationDomainEvent.query(on: app.db)
                    .filter(\.$conversationID == conversationID)
                    .filter(\.$eventType == ConversationDomainEventType.conversationRemovedForUser.rawValue)
                    .count() == 1
            )
            let appliedAudit = try #require(
                try await AdminAuditEvent.query(on: app.db)
                    .filter(\.$action == "conversation.governance.command.applied")
                    .filter(\.$targetID == conversationID.uuidString)
                    .first()
            )
            #expect(appliedAudit.metadataJSON?.contains(targetID.uuidString) == true)
            #expect(appliedAudit.metadataJSON?.contains("remove abusive member") == false)
        }
    }

    @Test("Admin group lifecycle freeze is confirmed, projected, and blocks member writes")
    func adminGroupLifecycleFreezeProjectsAndBlocksMemberWrites() async throws {
        let originalSecret = Environment.get("IM_ADMIN_SHARED_SECRET")
        defer { restoreEnvironment("IM_ADMIN_SHARED_SECRET", to: originalSecret) }
        setenv("IM_ADMIN_SHARED_SECRET", adminSecret, 1)

        try await withApp(configure: configure) { app in
            let owner = try await makeUser(email: "admin-freeze-owner@example.com", on: app)
            let member = try await makeUser(email: "admin-freeze-member@example.com", on: app)
            let conversation = Conversation(title: "Governance Freeze Group", kind: .group)
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            let ownerID = try owner.requireID()
            let memberID = try member.requireID()
            try await ConversationMember(conversationID: conversationID, userID: ownerID, role: .owner).create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: memberID).create(on: app.db)

            try await app.testing().test(.POST, "admin/api/conversations/\(conversationID.uuidString)/governance-commands", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "governance-freeze-auditor")
                req.headers.add(name: "Idempotency-Key", value: "freeze-without-confirmation")
                try req.content.encode(AdminConversationGovernanceCommandRequest(
                    action: AdminConversationGovernanceAction.groupLifecycleSet.rawValue,
                    groupLifecycleState: IMGroupLifecycleState.frozen.rawValue,
                    reason: "contain an active incident"
                ))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            var commandID: UUID?
            try await app.testing().test(.POST, "admin/api/conversations/\(conversationID.uuidString)/governance-commands", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "governance-freeze-auditor")
                req.headers.add(name: "Idempotency-Key", value: "freeze-group")
                try req.content.encode(AdminConversationGovernanceCommandRequest(
                    action: AdminConversationGovernanceAction.groupLifecycleSet.rawValue,
                    groupLifecycleState: IMGroupLifecycleState.frozen.rawValue,
                    confirmed: true,
                    reason: "contain an active incident"
                ))
            }, afterResponse: { res async throws in
                #expect(res.status == .accepted)
                let payload = try res.content.decode(AdminConversationGovernanceCommandResponse.self)
                #expect(payload.requestedGroupLifecycleState == IMGroupLifecycleState.frozen.rawValue)
                #expect(payload.destructiveConfirmed)
                commandID = payload.id
            })

            let id = try #require(commandID)
            let processor = AdminConversationGovernanceCommandProcessor(app: app)
            #expect(try await processor.process(commandID: id).statusEnum == .applied)
            #expect(try await processor.process(commandID: id).statusEnum == .applied)

            let persistedConversation = try #require(try await Conversation.find(conversationID, on: app.db))
            #expect(persistedConversation.groupLifecycleStateEnum == .frozen)
            let summary = try await ConversationSummaryReadSupport(db: app.db)
                .conversationSummary(conversationID: conversationID, for: memberID)
            #expect(summary.groupLifecycleState == IMGroupLifecycleState.frozen.rawValue)

            do {
                try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db)
                    .rejectInactiveGroupMessageIfNeeded(conversationID: conversationID)
                Issue.record("Expected frozen group message rejection")
            } catch let abort as any AbortError {
                #expect(abort.status == .forbidden)
            }

            let sourceMessage = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: ownerID,
                serverSequence: 1,
                timelineSequence: 1,
                content: .richText(.plain("message created before freeze"))
            )
            try await sourceMessage.create(on: app.db)
            let sourceMessageID = try sourceMessage.requireID()
            do {
                _ = try await ConversationCommonFeatureCommandService(app: app).forwardMessages(
                    userID: memberID,
                    sourceConversationID: conversationID,
                    messageIDs: [sourceMessageID],
                    targetConversationIDs: [conversationID]
                )
                Issue.record("Expected frozen group forward rejection")
            } catch let abort as any AbortError {
                #expect(abort.status == .forbidden)
            }
            #expect(
                try await ConversationMessage.query(on: app.db)
                    .filter(\.$conversation.$id == conversationID)
                    .count() == 1
            )

            do {
                _ = try await AIMessageStreamWriteStore(app: app).createInitialStreamingMessage(
                    streamID: UUID().uuidString,
                    conversationID: conversationID,
                    userID: memberID
                )
                Issue.record("Expected frozen group AI stream rejection")
            } catch let abort as any AbortError {
                #expect(abort.status == .forbidden)
            }
            #expect(
                try await AIMessageStreamIndex.query(on: app.db)
                    .filter(\.$conversationID == conversationID)
                    .count() == 0
            )

            let sideEffectKey = "admin-governance:\(id.uuidString.lowercased())"
            #expect(
                try await ConversationDomainEvent.query(on: app.db)
                    .filter(\.$sideEffectKey == sideEffectKey)
                    .filter(\.$eventType == ConversationDomainEventType.metadataUpdated.rawValue)
                    .count() == 1
            )
            let appliedAudit = try #require(
                try await AdminAuditEvent.query(on: app.db)
                    .filter(\.$action == "conversation.governance.command.applied")
                    .filter(\.$targetID == conversationID.uuidString)
                    .first()
            )
            #expect(appliedAudit.metadataJSON?.contains(IMGroupLifecycleState.frozen.rawValue) == true)
            #expect(appliedAudit.metadataJSON?.contains("contain an active incident") == false)

            try await app.testing().test(.POST, "admin/api/conversations/\(conversationID.uuidString)/governance-commands", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "governance-freeze-auditor")
                req.headers.add(name: "Idempotency-Key", value: "dissolve-without-confirmation")
                try req.content.encode(AdminConversationGovernanceCommandRequest(
                    action: AdminConversationGovernanceAction.groupLifecycleSet.rawValue,
                    groupLifecycleState: IMGroupLifecycleState.dissolved.rawValue,
                    reason: "close the group permanently"
                ))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            var dissolutionCommandID: UUID?
            try await app.testing().test(.POST, "admin/api/conversations/\(conversationID.uuidString)/governance-commands", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "governance-freeze-auditor")
                req.headers.add(name: "Idempotency-Key", value: "dissolve-group")
                try req.content.encode(AdminConversationGovernanceCommandRequest(
                    action: AdminConversationGovernanceAction.groupLifecycleSet.rawValue,
                    groupLifecycleState: IMGroupLifecycleState.dissolved.rawValue,
                    confirmed: true,
                    reason: "close the group permanently"
                ))
            }, afterResponse: { res async throws in
                #expect(res.status == .accepted)
                dissolutionCommandID = try res.content.decode(AdminConversationGovernanceCommandResponse.self).id
            })

            #expect(try await processor.process(commandID: try #require(dissolutionCommandID)).statusEnum == .applied)
            #expect(try await Conversation.find(conversationID, on: app.db)?.groupLifecycleStateEnum == .dissolved)
            let dissolvedSummary = try await ConversationSummaryReadSupport(db: app.db)
                .conversationSummary(conversationID: conversationID, for: memberID)
            #expect(dissolvedSummary.groupLifecycleState == IMGroupLifecycleState.dissolved.rawValue)

            do {
                _ = try await ConversationMembershipCommandSupport(db: app.db).leaveConversation(
                    in: conversationID,
                    requesterUserID: memberID
                )
                Issue.record("Expected dissolved group leave rejection")
            } catch let abort as any AbortError {
                #expect(abort.status == .forbidden)
            }
            #expect(
                try await ConversationMember.query(on: app.db)
                    .filter(\.$conversation.$id == conversationID)
                    .filter(\.$user.$id == memberID)
                    .count() == 1
            )

            try await app.testing().test(.POST, "admin/api/conversations/\(conversationID.uuidString)/governance-commands", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "governance-freeze-auditor")
                req.headers.add(name: "Idempotency-Key", value: "restore-dissolved-group")
                try req.content.encode(AdminConversationGovernanceCommandRequest(
                    action: AdminConversationGovernanceAction.groupLifecycleSet.rawValue,
                    groupLifecycleState: IMGroupLifecycleState.active.rawValue,
                    reason: "attempt to restore"
                ))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })
        }
    }

    @Test("Admin governance command routes to an independent local conversation shard")
    func adminGovernanceCommandRoutesToIndependentLocalConversationShard() async throws {
        let originalSecret = Environment.get("IM_ADMIN_SHARED_SECRET")
        defer { restoreEnvironment("IM_ADMIN_SHARED_SECRET", to: originalSecret) }
        setenv("IM_ADMIN_SHARED_SECRET", adminSecret, 1)

        try await withApp(configure: configure) { app in
            let shardID = "governance-shard-b"
            let shardDatabaseID = DatabaseID(string: "test-governance-shard-b")
            app.databases.use(.sqlite(.memory), as: shardDatabaseID)
            app.migrations.add(governanceConversationShardMigrations(), to: shardDatabaseID)
            try await app.autoMigrate()

            let shardDatabase = app.db(shardDatabaseID)
            let memberUserID = UUID()
            let conversation = Conversation(title: "Independent Governance Group", kind: .group)
            try await conversation.create(on: shardDatabase)
            let conversationID = try conversation.requireID()
            try await ConversationMember(
                conversationID: conversationID,
                userID: memberUserID,
                role: .owner,
                visibleFromSequence: 1
            ).create(on: shardDatabase)

            let directory = DatabaseConversationDirectory(
                db: app.db,
                localCellID: app.imRealtimeCellID
            )
            app.conversationDirectory = directory
            try await directory.registerConversation(
                conversationID: conversationID,
                shardID: shardID,
                cellID: app.imRealtimeCellID
            )
            app.conversationShardRouter = DirectoryBackedConversationShardRouter(
                app: app,
                shardIDs: [shardID],
                shardDatabaseIDs: [shardID: shardDatabaseID],
                shardReplicaDatabaseIDs: [:],
                directory: directory
            )

            var commandID: UUID?
            try await app.testing().test(.POST, "admin/api/conversations/\(conversationID.uuidString)/governance-commands", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "governance-shard-auditor")
                req.headers.add(name: "Idempotency-Key", value: "independent-shard-mute")
                try req.content.encode(AdminConversationGovernanceCommandRequest(
                    action: AdminConversationGovernanceAction.groupMuteAllSet.rawValue,
                    muteAll: true,
                    reason: "local shard routing verification"
                ))
            }, afterResponse: { res async throws in
                #expect(res.status == .accepted)
                let payload = try res.content.decode(AdminConversationGovernanceCommandResponse.self)
                commandID = payload.id
                #expect(payload.targetShardID == shardID)
                #expect(payload.targetCellID == app.imRealtimeCellID)
                #expect(payload.targetRouteVersion == 1)
            })

            let id = try #require(commandID)
            let processed = try await AdminConversationGovernanceCommandProcessor(app: app).processPending(limit: 10)
            #expect(processed.count == 1)
            #expect(processed.first?.statusEnum == .applied)

            #expect(try await Conversation.find(conversationID, on: app.db) == nil)
            let persistedConversation = try #require(try await Conversation.find(conversationID, on: shardDatabase))
            #expect(persistedConversation.muteAll)

            let sideEffectKey = "admin-governance:\(id.uuidString.lowercased())"
            #expect(try await ConversationDomainEventSideEffect.find(sideEffectKey, on: app.db) == nil)
            #expect(try await ConversationDomainEventSideEffect.find(sideEffectKey, on: shardDatabase) != nil)
            #expect(
                try await ConversationDomainEvent.query(on: shardDatabase)
                    .filter(\.$sideEffectKey == sideEffectKey)
                    .filter(\.$eventType == ConversationDomainEventType.metadataUpdated.rawValue)
                    .count() == 1
            )

            let appliedAuditCount = try await AdminAuditEvent.query(on: app.db)
                .filter(\.$action == "conversation.governance.command.applied")
                .filter(\.$targetID == conversationID.uuidString)
                .count()
            #expect(appliedAuditCount == 1)
        }
    }

    @Test("Admin governance command fails closed when its accepted route version changes")
    func adminGovernanceCommandFailsWhenAcceptedRouteVersionChanges() async throws {
        let originalSecret = Environment.get("IM_ADMIN_SHARED_SECRET")
        defer { restoreEnvironment("IM_ADMIN_SHARED_SECRET", to: originalSecret) }
        setenv("IM_ADMIN_SHARED_SECRET", adminSecret, 1)

        try await withApp(configure: configure) { app in
            let shardID = "governance-route-version-shard"
            let shardDatabaseID = DatabaseID(string: "test-governance-route-version-shard")
            app.databases.use(.sqlite(.memory), as: shardDatabaseID)
            app.migrations.add(governanceConversationShardMigrations(), to: shardDatabaseID)
            try await app.autoMigrate()

            let shardDatabase = app.db(shardDatabaseID)
            let conversation = Conversation(title: "Route Version Group", kind: .group)
            try await conversation.create(on: shardDatabase)
            let conversationID = try conversation.requireID()
            try await ConversationMember(
                conversationID: conversationID,
                userID: UUID(),
                role: .owner,
                visibleFromSequence: 1
            ).create(on: shardDatabase)

            let directory = DatabaseConversationDirectory(
                db: app.db,
                localCellID: app.imRealtimeCellID
            )
            app.conversationDirectory = directory
            try await directory.registerConversation(
                conversationID: conversationID,
                shardID: shardID,
                cellID: app.imRealtimeCellID
            )
            app.conversationShardRouter = DirectoryBackedConversationShardRouter(
                app: app,
                shardIDs: [shardID],
                shardDatabaseIDs: [shardID: shardDatabaseID],
                shardReplicaDatabaseIDs: [:],
                directory: directory
            )

            var commandID: UUID?
            try await app.testing().test(.POST, "admin/api/conversations/\(conversationID.uuidString)/governance-commands", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "route-version-auditor")
                req.headers.add(name: "Idempotency-Key", value: "route-version-mute")
                try req.content.encode(AdminConversationGovernanceCommandRequest(
                    action: AdminConversationGovernanceAction.groupMuteAllSet.rawValue,
                    muteAll: true,
                    reason: "verify route version binding"
                ))
            }, afterResponse: { res async throws in
                #expect(res.status == .accepted)
                let payload = try res.content.decode(AdminConversationGovernanceCommandResponse.self)
                commandID = payload.id
                #expect(payload.targetRouteVersion == 1)
            })

            let entry = try #require(
                try await ConversationDirectoryEntry.find(conversationID, on: app.db)
            )
            entry.routeVersion = 2
            try await entry.update(on: app.db)

            let id = try #require(commandID)
            let result = try await AdminConversationGovernanceCommandProcessor(app: app)
                .process(commandID: id)
            #expect(result.statusEnum == .failed)
            #expect(result.lastErrorCode == "route_changed")

            let persistedConversation = try #require(
                try await Conversation.find(conversationID, on: shardDatabase)
            )
            #expect(!persistedConversation.muteAll)
            let sideEffectKey = "admin-governance:\(id.uuidString.lowercased())"
            #expect(try await ConversationDomainEventSideEffect.find(sideEffectKey, on: shardDatabase) == nil)
            let failedAudit = try #require(
                try await AdminAuditEvent.query(on: app.db)
                    .filter(\.$action == "conversation.governance.command.failed")
                    .filter(\.$targetID == conversationID.uuidString)
                    .first()
            )
            #expect(failedAudit.metadataJSON?.contains("route_changed") == true)
            #expect(failedAudit.metadataJSON?.contains("verify route version binding") == false)
        }
    }

    @Test("Admin report queue and audit search enforce bounded operational filters")
    func adminReportQueueAndAuditSearchEnforceBoundedOperationalFilters() async throws {
        let originalSecret = Environment.get("IM_ADMIN_SHARED_SECRET")
        defer { restoreEnvironment("IM_ADMIN_SHARED_SECRET", to: originalSecret) }
        setenv("IM_ADMIN_SHARED_SECRET", adminSecret, 1)

        try await withApp(configure: configure) { app in
            let moderator = try await makeUser(email: "queue-moderator@example.com", on: app)
            let moderatorID = try moderator.requireID()
            moderator.adminRole = AdminRole.moderator.rawValue
            try await moderator.update(on: app.db)
            let moderatorToken = try await loginAccessToken(
                email: moderator.email,
                password: "password1234",
                deviceID: "queue-moderator-device",
                on: app
            )
            let oldestPending = UserReport(
                reporterUserID: moderatorID,
                targetType: "user",
                targetID: UUID().uuidString,
                conversationID: nil,
                messageID: nil,
                reason: "queue-unassigned",
                detail: nil,
                createdAt: Date().addingTimeInterval(-7_200)
            )
            try await oldestPending.create(on: app.db)
            let assignedReview = UserReport(
                reporterUserID: moderatorID,
                targetType: "message",
                targetID: UUID().uuidString,
                conversationID: nil,
                messageID: nil,
                reason: "queue-mine",
                detail: nil,
                status: "reviewing",
                assignedReviewerUserID: moderatorID,
                assignedReviewerActor: moderator.email,
                assignedAt: Date().addingTimeInterval(-1_800),
                createdAt: Date().addingTimeInterval(-3_600)
            )
            try await assignedReview.create(on: app.db)
            let assignedReviewID = try assignedReview.requireID()
            let audit = AdminAuditEvent(
                actor: "queue-auditor",
                action: "report.status.update",
                targetType: "report",
                targetID: assignedReviewID.uuidString,
                requestID: "queue-request"
            )
            try await audit.create(on: app.db)
            let auditID = try audit.requireID()

            try await app.testing().test(.GET, "admin/api/reports/queue?scope=unassigned", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(AdminReportQueueResponse.self)
                #expect(payload.scope == "unassigned")
                #expect(payload.summary.pendingCount >= 1)
                #expect(payload.summary.reviewingCount >= 1)
                #expect(payload.summary.unassignedActiveCount >= 1)
                #expect(payload.summary.oldestPendingAgeSeconds ?? 0 >= 7_100)
                #expect(payload.items.contains(where: { $0.report.reason == "queue-unassigned" && $0.ageSeconds >= 7_100 }))
                #expect(!payload.items.contains(where: { $0.report.id == assignedReviewID }))
            })

            try await app.testing().test(.GET, "admin/api/reports/queue?scope=mine", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: moderatorToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(AdminReportQueueResponse.self)
                #expect(payload.scope == "mine")
                #expect(payload.items.contains(where: { $0.report.id == assignedReviewID }))
            })

            try await app.testing().test(.GET, "admin/api/reports/queue?scope=mine", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            try await app.testing().test(.GET, "admin/api/reports/queue?scope=all&status=resolved", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            let from = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
            try await app.testing().test(.GET, "admin/api/audit-events?action=report.status.update&actor=queue-auditor&targetType=report&targetID=\(assignedReviewID.uuidString)&requestID=queue-request&from=\(from)", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(AdminAuditEventPageResponse.self)
                #expect(payload.items.contains(where: { $0.id == auditID }))
            })

            try await app.testing().test(.GET, "admin/api/audit-events?from=not-a-date", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("User security overview is super-admin only and redacts credentials")
    func userSecurityOverviewIsSuperAdminOnlyAndRedactsCredentials() async throws {
        let originalSecret = Environment.get("IM_ADMIN_SHARED_SECRET")
        defer { restoreEnvironment("IM_ADMIN_SHARED_SECRET", to: originalSecret) }
        setenv("IM_ADMIN_SHARED_SECRET", adminSecret, 1)

        try await withApp(configure: configure) { app in
            let target = try await makeUser(email: "security-target@example.com", on: app)
            let targetID = try target.requireID()
            _ = try await loginAccessToken(
                email: target.email,
                password: "password1234",
                deviceID: "security-target-device",
                on: app
            )
            let pushToken = "private-push-token-abcdefgh"
            let device = PushDeviceToken(
                ownerUserID: targetID,
                sessionID: nil,
                platform: "ios",
                token: pushToken
            )
            try await device.create(on: app.db)

            let support = try await makeUser(email: "security-support@example.com", on: app)
            support.adminRole = AdminRole.support.rawValue
            try await support.update(on: app.db)
            let supportToken = try await loginAccessToken(
                email: support.email,
                password: "password1234",
                deviceID: "security-support-device",
                on: app
            )

            try await app.testing().test(.GET, "admin/api/users/\(targetID.uuidString)/security", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(AdminUserSecurityOverviewResponse.self)
                #expect(payload.user.id == targetID)
                #expect(payload.sessions.contains(where: { $0.deviceID == "security-target-device" }))
                #expect(payload.pushDevices.contains(where: { $0.tokenSuffix == "abcdefgh" && $0.isActive }))
                let encoded = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
                #expect(!encoded.contains(pushToken))
                #expect(!encoded.contains("current_nonce"))
                #expect(!encoded.contains("previous_nonce"))
            })

            try await app.testing().test(.GET, "admin/api/users/\(targetID.uuidString)/security", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: supportToken)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            let audit = try #require(
                try await AdminAuditEvent.query(on: app.db)
                    .filter(\.$action == "user.security.inspect")
                    .filter(\.$targetID == targetID.uuidString)
                    .first()
            )
            #expect(audit.metadataJSON?.contains(pushToken) == false)
            #expect(audit.metadataJSON?.contains("current_nonce") == false)
        }
    }

    @Test("Admin report workflow records decision history and rejects invalid transitions")
    func adminReportWorkflowRecordsDecisionHistoryAndRejectsInvalidTransitions() async throws {
        let originalSecret = Environment.get("IM_ADMIN_SHARED_SECRET")
        defer { restoreEnvironment("IM_ADMIN_SHARED_SECRET", to: originalSecret) }
        setenv("IM_ADMIN_SHARED_SECRET", adminSecret, 1)

        try await withApp(configure: configure) { app in
            let moderator = try await makeUser(email: "decision-moderator@example.com", on: app)
            let moderatorID = try moderator.requireID()
            moderator.adminRole = AdminRole.moderator.rawValue
            try await moderator.update(on: app.db)
            let moderatorToken = try await loginAccessToken(
                email: moderator.email,
                password: "password1234",
                deviceID: "decision-moderator-device",
                on: app
            )
            let report = UserReport(
                reporterUserID: moderatorID,
                targetType: "user",
                targetID: UUID().uuidString,
                conversationID: nil,
                messageID: nil,
                reason: "abuse",
                detail: "workflow history"
            )
            try await report.create(on: app.db)
            let reportID = try report.requireID()

            try await app.testing().test(.PATCH, "admin/api/reports/\(reportID.uuidString)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: moderatorToken)
                try req.content.encode(ReportUpdateRequest(status: "reviewing", handledNote: "missing key", resolutionCategory: nil))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            try await app.testing().test(.PATCH, "admin/api/reports/\(reportID.uuidString)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: moderatorToken)
                req.headers.add(name: "Idempotency-Key", value: "decision-reviewing")
                try req.content.encode(ReportUpdateRequest(status: "reviewing", handledNote: "reviewing evidence", resolutionCategory: nil))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.PATCH, "admin/api/reports/\(reportID.uuidString)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: moderatorToken)
                req.headers.add(name: "X-Request-ID", value: "decision-workflow-request")
                req.headers.add(name: "Idempotency-Key", value: "decision-resolved")
                try req.content.encode(ReportUpdateRequest(status: "resolved", handledNote: "removed violating content", resolutionCategory: "action_taken"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "admin/api/reports/\(reportID.uuidString)/decisions", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: moderatorToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(AdminReportDecisionPageResponse.self)
                #expect(payload.items.count == 2)
                #expect(payload.items[0].previousStatus == "reviewing")
                #expect(payload.items[0].status == "resolved")
                #expect(payload.items[0].resolutionCategory == "action_taken")
                #expect(payload.items[0].reviewerActor == moderator.email)
                #expect(payload.items[0].reviewerRole == AdminRole.moderator.rawValue)
                #expect(payload.items[0].authenticationMethod == AdminAccessContext.AuthenticationMethod.accessToken.rawValue)
                #expect(payload.items[0].requestID == "decision-workflow-request")
            })

            try await app.testing().test(.PATCH, "admin/api/reports/\(reportID.uuidString)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: moderatorToken)
                req.headers.add(name: "Idempotency-Key", value: "decision-resolved")
                try req.content.encode(ReportUpdateRequest(status: "resolved", handledNote: "removed violating content", resolutionCategory: "action_taken"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.PATCH, "admin/api/reports/\(reportID.uuidString)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: moderatorToken)
                req.headers.add(name: "Idempotency-Key", value: "decision-resolved")
                try req.content.encode(ReportUpdateRequest(status: "resolved", handledNote: "different note", resolutionCategory: "action_taken"))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })

            try await app.testing().test(.PATCH, "admin/api/reports/\(reportID.uuidString)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: moderatorToken)
                req.headers.add(name: "Idempotency-Key", value: "decision-invalid-reopen")
                try req.content.encode(ReportUpdateRequest(status: "reviewing", handledNote: "reopen", resolutionCategory: nil))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })

            let decisions = try await ReportModerationDecision.query(on: app.db)
                .filter(\.$report.$id == reportID)
                .all()
            #expect(decisions.count == 2)
            let auditEvents = try await AdminAuditEvent.query(on: app.db)
                .filter(\.$action == "report.status.update")
                .filter(\.$targetID == reportID.uuidString)
                .all()
            #expect(auditEvents.count == 2)
            #expect(auditEvents.allSatisfy { $0.metadataJSON?.contains("removed violating content") != true })
        }
    }

    @Test("Internal report updates use the shared moderation workflow")
    func internalReportUpdatesUseSharedModerationWorkflow() async throws {
        let originalSecret = Environment.get("IM_COMMAND_INTERNAL_SHARED_SECRET")
        defer { restoreEnvironment("IM_COMMAND_INTERNAL_SHARED_SECRET", to: originalSecret) }
        setenv("IM_COMMAND_INTERNAL_SHARED_SECRET", "internal-report-secret", 1)

        try await withApp(configure: configure) { app in
            let reporter = try await makeUser(email: "internal-report-reporter@example.com", on: app)
            let report = UserReport(
                reporterUserID: try reporter.requireID(),
                targetType: "user",
                targetID: UUID().uuidString,
                conversationID: nil,
                messageID: nil,
                reason: "spam",
                detail: "internal moderation"
            )
            try await report.create(on: app.db)
            let reportID = try report.requireID()

            for update in [
                ReportUpdateRequest(status: "reviewing", handledNote: "triage", resolutionCategory: nil),
                ReportUpdateRequest(status: "rejected", handledNote: "no policy violation", resolutionCategory: "no_violation")
            ] {
                try await app.testing().test(.PATCH, "internal/reports/\(reportID.uuidString)", beforeRequest: { req in
                    req.headers.add(name: "X-IM-Internal-Secret", value: "internal-report-secret")
                    try req.content.encode(update)
                }, afterResponse: { res async in
                    #expect(res.status == .ok)
                })
            }

            let decisions = try await ReportModerationDecision.query(on: app.db)
                .filter(\.$report.$id == reportID)
                .sort(\.$createdAt, .ascending)
                .all()
            #expect(decisions.count == 2)
            #expect(decisions.map(\.previousStatus) == ["pending", "reviewing"])
            #expect(decisions.map(\.status) == ["reviewing", "rejected"])
            #expect(decisions.allSatisfy { $0.reviewerRole == "system" })
            #expect(decisions.allSatisfy { $0.authenticationMethod == "internal_secret" })
        }
    }

    @Test("Moderators can claim reports while super admins control reassignment")
    func moderatorsCanClaimReportsWhileSuperAdminsControlReassignment() async throws {
        let originalSecret = Environment.get("IM_ADMIN_SHARED_SECRET")
        defer { restoreEnvironment("IM_ADMIN_SHARED_SECRET", to: originalSecret) }
        setenv("IM_ADMIN_SHARED_SECRET", adminSecret, 1)

        try await withApp(configure: configure) { app in
            let firstModerator = try await makeUser(email: "assignment-first-moderator@example.com", on: app)
            let firstModeratorID = try firstModerator.requireID()
            firstModerator.adminRole = AdminRole.moderator.rawValue
            try await firstModerator.update(on: app.db)
            let firstToken = try await loginAccessToken(
                email: firstModerator.email,
                password: "password1234",
                deviceID: "assignment-first-device",
                on: app
            )

            let secondModerator = try await makeUser(email: "assignment-second-moderator@example.com", on: app)
            let secondModeratorID = try secondModerator.requireID()
            secondModerator.adminRole = AdminRole.moderator.rawValue
            try await secondModerator.update(on: app.db)
            let secondToken = try await loginAccessToken(
                email: secondModerator.email,
                password: "password1234",
                deviceID: "assignment-second-device",
                on: app
            )

            let report = UserReport(
                reporterUserID: firstModeratorID,
                targetType: "user",
                targetID: UUID().uuidString,
                conversationID: nil,
                messageID: nil,
                reason: "assignment",
                detail: "assignment contract"
            )
            try await report.create(on: app.db)
            let reportID = try report.requireID()

            try await app.testing().test(.PATCH, "admin/api/reports/\(reportID.uuidString)/reviewer", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: firstToken)
                req.headers.add(name: "Idempotency-Key", value: "claim-first")
                try req.content.encode(AdminReportReviewerAssignmentRequest(reviewerUserID: firstModeratorID))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(ReportResponse.self)
                #expect(payload.assignedReviewerUserID == firstModeratorID)
                #expect(payload.assignedReviewerActor == firstModerator.email)
            })

            try await app.testing().test(.PATCH, "admin/api/reports/\(reportID.uuidString)/reviewer", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: firstToken)
                req.headers.add(name: "Idempotency-Key", value: "claim-first")
                try req.content.encode(AdminReportReviewerAssignmentRequest(reviewerUserID: firstModeratorID))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.PATCH, "admin/api/reports/\(reportID.uuidString)/reviewer", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: firstToken)
                req.headers.add(name: "Idempotency-Key", value: "claim-first")
                try req.content.encode(AdminReportReviewerAssignmentRequest(reviewerUserID: secondModeratorID))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })

            try await app.testing().test(.PATCH, "admin/api/reports/\(reportID.uuidString)/reviewer", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: secondToken)
                req.headers.add(name: "Idempotency-Key", value: "claim-second")
                try req.content.encode(AdminReportReviewerAssignmentRequest(reviewerUserID: secondModeratorID))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })

            try await app.testing().test(.PATCH, "admin/api/reports/\(reportID.uuidString)/reviewer", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: firstToken)
                req.headers.add(name: "Idempotency-Key", value: "claim-other")
                try req.content.encode(AdminReportReviewerAssignmentRequest(reviewerUserID: secondModeratorID))
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            try await app.testing().test(.PATCH, "admin/api/reports/\(reportID.uuidString)/reviewer", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "supervisor")
                req.headers.add(name: "Idempotency-Key", value: "reassign-second")
                try req.content.encode(AdminReportReviewerAssignmentRequest(reviewerUserID: secondModeratorID))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(ReportResponse.self)
                #expect(payload.assignedReviewerUserID == secondModeratorID)
                #expect(payload.assignedReviewerActor == secondModerator.email)
            })

            let terminalReport = try #require(try await UserReport.find(reportID, on: app.db))
            terminalReport.status = "resolved"
            try await terminalReport.update(on: app.db)
            try await app.testing().test(.PATCH, "admin/api/reports/\(reportID.uuidString)/reviewer", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "Idempotency-Key", value: "terminal-reassign")
                try req.content.encode(AdminReportReviewerAssignmentRequest(reviewerUserID: firstModeratorID))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })

            let assignments = try await AdminAuditEvent.query(on: app.db)
                .filter(\.$action == "report.reviewer.assign")
                .filter(\.$targetID == reportID.uuidString)
                .all()
            #expect(assignments.count == 2)
        }
    }

    @Test("Moderators can attach controlled report evidence without leaking URLs to audit metadata")
    func moderatorsCanAttachControlledReportEvidenceWithoutLeakingURLsToAuditMetadata() async throws {
        let originalSecret = Environment.get("IM_ADMIN_SHARED_SECRET")
        defer { restoreEnvironment("IM_ADMIN_SHARED_SECRET", to: originalSecret) }
        setenv("IM_ADMIN_SHARED_SECRET", adminSecret, 1)

        try await withApp(configure: configure) { app in
            let moderator = try await makeUser(email: "evidence-moderator@example.com", on: app)
            let moderatorID = try moderator.requireID()
            moderator.adminRole = AdminRole.moderator.rawValue
            try await moderator.update(on: app.db)
            let token = try await loginAccessToken(
                email: moderator.email,
                password: "password1234",
                deviceID: "evidence-moderator-device",
                on: app
            )
            let report = UserReport(
                reporterUserID: moderatorID,
                targetType: "user",
                targetID: UUID().uuidString,
                conversationID: nil,
                messageID: nil,
                reason: "evidence",
                detail: "evidence contract"
            )
            try await report.create(on: app.db)
            let reportID = try report.requireID()
            let evidenceURL = "https://evidence.example.com/case/42?temporaryToken=secret-value"

            try await app.testing().test(.POST, "admin/api/reports/\(reportID.uuidString)/evidence", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.add(name: "X-Request-ID", value: "evidence-request")
                req.headers.add(name: "Idempotency-Key", value: "evidence-create")
                try req.content.encode(AdminReportEvidenceCreateRequest(url: evidenceURL, label: "case capture"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(AdminReportEvidenceResponse.self)
                #expect(payload.url == evidenceURL)
                #expect(payload.label == "case capture")
                #expect(payload.submittedByActor == moderator.email)
                #expect(payload.requestID == "evidence-request")
            })

            try await app.testing().test(.POST, "admin/api/reports/\(reportID.uuidString)/evidence", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.add(name: "Idempotency-Key", value: "evidence-create")
                try req.content.encode(AdminReportEvidenceCreateRequest(url: evidenceURL, label: "case capture"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.POST, "admin/api/reports/\(reportID.uuidString)/evidence", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.add(name: "Idempotency-Key", value: "evidence-create")
                try req.content.encode(AdminReportEvidenceCreateRequest(url: "https://evidence.example.com/case/43", label: "different"))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })

            try await app.testing().test(.GET, "admin/api/reports/\(reportID.uuidString)/evidence", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(AdminReportEvidencePageResponse.self)
                #expect(payload.items.count == 1)
                #expect(payload.items[0].url == evidenceURL)
            })

            try await app.testing().test(.POST, "admin/api/reports/\(reportID.uuidString)/evidence", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.add(name: "Idempotency-Key", value: "evidence-invalid-url")
                try req.content.encode(AdminReportEvidenceCreateRequest(url: "http://evidence.example.com/insecure", label: nil))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            let audit = try #require(
                try await AdminAuditEvent.query(on: app.db)
                    .filter(\.$action == "report.evidence.add")
                    .filter(\.$targetID == reportID.uuidString)
                    .first()
            )
            #expect(audit.metadataJSON?.contains("evidence.example.com") == true)
            #expect(audit.metadataJSON?.contains("temporaryToken") == false)
            #expect(audit.metadataJSON?.contains("secret-value") == false)
            let evidenceCount = try await ReportModerationEvidence.query(on: app.db)
                .filter(\.$report.$id == reportID)
                .count()
            #expect(evidenceCount == 1)
        }
    }

    @Test("Admin access token enforces role permissions and role revocation")
    func adminAccessTokenEnforcesRolePermissionsAndRoleRevocation() async throws {
        let originalSecret = Environment.get("IM_ADMIN_SHARED_SECRET")
        defer { restoreEnvironment("IM_ADMIN_SHARED_SECRET", to: originalSecret) }
        setenv("IM_ADMIN_SHARED_SECRET", adminSecret, 1)

        try await withApp(configure: configure) { app in
            let moderator = try await makeUser(email: "admin-moderator@example.com", on: app)
            let moderatorID = try moderator.requireID()
            moderator.adminRole = AdminRole.moderator.rawValue
            try await moderator.update(on: app.db)
            let moderatorToken = try await loginAccessToken(
                email: moderator.email,
                password: "password1234",
                deviceID: "admin-moderator-device",
                on: app
            )

            try await app.testing().test(.GET, "admin/api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: moderatorToken)
                req.headers.add(name: "X-IM-Admin-Actor", value: "spoofed-actor")
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(AdminCurrentUserResponse.self)
                #expect(payload.actor == moderator.email)
                #expect(payload.userID == moderatorID)
                #expect(payload.role == AdminRole.moderator.rawValue)
                #expect(payload.authenticationMethod == AdminAccessContext.AuthenticationMethod.accessToken.rawValue)
                #expect(payload.permissions == [AdminPermission.reportsRead.rawValue, AdminPermission.reportsWrite.rawValue])
            })

            try await app.testing().test(.GET, "admin/api/reports", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: moderatorToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "admin/api/overview", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: moderatorToken)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            let report = UserReport(
                reporterUserID: moderatorID,
                targetType: "user",
                targetID: UUID().uuidString,
                conversationID: nil,
                messageID: nil,
                reason: "spam",
                detail: "moderator audit contract"
            )
            try await report.create(on: app.db)
            let reportID = try report.requireID()
            try await app.testing().test(.PATCH, "admin/api/reports/\(reportID.uuidString)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: moderatorToken)
                req.headers.add(name: "Idempotency-Key", value: "moderator-reviewing")
                try req.content.encode(ReportUpdateRequest(status: "reviewing", handledNote: "assigned", resolutionCategory: nil))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(ReportResponse.self)
                #expect(payload.status == "reviewing")
            })

            let reportAudit = try #require(
                try await AdminAuditEvent.query(on: app.db)
                    .filter(\.$action == "report.status.update")
                    .filter(\.$targetID == reportID.uuidString)
                    .first()
            )
            #expect(reportAudit.actor == moderator.email)
            #expect(reportAudit.metadataJSON?.contains("\"adminRole\":\"moderator\"") == true)
            #expect(reportAudit.metadataJSON?.contains("\"authenticationMethod\":\"access_token\"") == true)

            try await app.testing().test(.PATCH, "admin/api/users/\(moderatorID.uuidString)/admin-role", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "Idempotency-Key", value: "remove-moderator-role")
                try req.content.encode(AdminUserRoleUpdateRequest(adminRole: nil, note: "remove moderator role"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(AdminUserResponse.self)
                #expect(payload.adminRole == nil)
            })

            try await app.testing().test(.GET, "admin/api/reports", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: moderatorToken)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            let events = try await AdminAuditEvent.query(on: app.db)
                .filter(\.$action == "user.admin_role.update")
                .all()
            #expect(events.contains(where: { $0.targetID == moderatorID.uuidString }))
        }
    }

    @Test("Only super admins can assign management roles")
    func onlySuperAdminsCanAssignManagementRoles() async throws {
        let originalSecret = Environment.get("IM_ADMIN_SHARED_SECRET")
        defer { restoreEnvironment("IM_ADMIN_SHARED_SECRET", to: originalSecret) }
        setenv("IM_ADMIN_SHARED_SECRET", adminSecret, 1)

        try await withApp(configure: configure) { app in
            let support = try await makeUser(email: "admin-support@example.com", on: app)
            support.adminRole = AdminRole.support.rawValue
            try await support.update(on: app.db)
            let supportToken = try await loginAccessToken(
                email: support.email,
                password: "password1234",
                deviceID: "admin-support-device",
                on: app
            )
            let target = try await makeUser(email: "admin-role-target@example.com", on: app)

            try await app.testing().test(.PATCH, "admin/api/users/\(target.requireID().uuidString)/admin-role", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: supportToken)
                try req.content.encode(AdminUserRoleUpdateRequest(adminRole: AdminRole.moderator.rawValue, note: nil))
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            try await app.testing().test(.PATCH, "admin/api/users/\(target.requireID().uuidString)/admin-role", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "Idempotency-Key", value: "grant-moderation-role")
                try req.content.encode(AdminUserRoleUpdateRequest(adminRole: AdminRole.moderator.rawValue, note: "grant moderation"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(AdminUserResponse.self)
                #expect(payload.adminRole == AdminRole.moderator.rawValue)
            })

            try await app.testing().test(.PATCH, "admin/api/users/\(target.requireID().uuidString)/admin-role", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "Idempotency-Key", value: "grant-moderation-role")
                try req.content.encode(AdminUserRoleUpdateRequest(adminRole: AdminRole.moderator.rawValue, note: "grant moderation"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }
}

private actor GovernanceTestConversationDirectory: ConversationDirectory {
    private let shardIDsByConversationID: [UUID: String]

    init(shardIDsByConversationID: [UUID: String]) {
        self.shardIDsByConversationID = shardIDsByConversationID
    }

    func shardID(for conversationID: UUID) async throws -> String {
        guard let shardID = shardIDsByConversationID[conversationID] else {
            throw Abort(.notFound, reason: "Conversation shard directory entry does not exist.")
        }
        return shardID
    }

    func registerConversation(conversationID: UUID, shardID: String) async throws {
        throw Abort(.forbidden, reason: "The test conversation directory is immutable.")
    }
}

private func governanceConversationShardMigrations() -> [any Migration] {
    [
        CreateConversation(),
        AddConversationMembershipRevision(),
        AddConversationLastMessageSequence(),
        CreateConversationMember(),
        AddConversationMemberLastReadSequence(),
        AddConversationKind(),
        AddConversationDirectMessagingState(),
        AddConversationGroupLifecycleState(),
        AddConversationMemberRole(),
        AddConversationMetadataAndPreferences(),
        AddConversationMuteAndMemberNickname(),
        CreateConversationMessage(),
        RemoveConversationUserForeignKeys(),
        AddConversationMessageDerivedState(),
        AddConversationMessageClientMessageID(),
        AddConversationMessageClientMessageIDUniqueIndex(),
        AddConversationMessageTimelineIndexes(),
        CreateConversationDomainEvent(),
        AddConversationDomainEventRetryCount(),
        AddConversationDomainEventStreamPublicationFields(),
        AddConversationDomainEventStreamClaimFields(),
        AddConversationDomainEventIndexes(),
        AddConversationDomainEventActor(),
        AddConversationDomainEventSideEffectKey(),
        CreateDomainEventSequencesAndTimelineNotices(),
        CreateConversationUserSummary(),
        AddConversationUserSummaryGroupLifecycleState(),
        AddConversationUserSummaryMembershipRevision(),
        AddConversationUserSummaryDirectPeerProfileFields(),
        AddConversationUserSummaryIndexes(),
        AddConversationUserSummaryListOrderIndex(),
        CreateConversationSummaryReadModelTables(),
        AddConversationSummaryReadModelIndexes(),
        CreateConversationActivitySummaryReadModel()
    ]
}
