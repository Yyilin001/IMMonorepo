import Fluent
import SQLKit
import Vapor

struct IMConversationService {
    private enum CreationError: LocalizedError {
        case emptyParticipants
        case invalidKind
        case invalidDirectParticipants
        case membersNotFound([String])

        var errorDescription: String? {
            switch self {
            case .emptyParticipants:
                return "至少需要提供一个其他会话成员。"
            case .invalidKind:
                return "会话类型无效。"
            case .invalidDirectParticipants:
                return "私聊只能选择 1 个其他成员。"
            case .membersNotFound(let emails):
                return "以下成员不存在：\(emails.joined(separator: "、"))。"
            }
        }
    }

    private enum MembershipUpdateError: LocalizedError {
        case emptyParticipants
        case directConversationImmutable
        case noNewMembers
        case insufficientPrivilegeToAddMembers
        case insufficientPrivilegeToRemoveMembers
        case cannotRemoveSelf
        case cannotRemoveOwner
        case cannotRemoveAdministrator
        case cannotLeaveDirectConversation
        case minimumGroupSizeViolation
        case ownerMustTransferBeforeLeaving

        var errorDescription: String? {
            switch self {
            case .emptyParticipants:
                return "至少需要提供一个成员邮箱。"
            case .directConversationImmutable:
                return "私聊会话不支持新增成员。"
            case .noNewMembers:
                return "没有可新增的成员。"
            case .insufficientPrivilegeToAddMembers:
                return "只有群主或管理员可以添加成员。"
            case .insufficientPrivilegeToRemoveMembers:
                return "当前角色没有移除该成员的权限。"
            case .cannotRemoveSelf:
                return "不能通过移除成员操作移除自己，请使用退出会话。"
            case .cannotRemoveOwner:
                return "不能移除群主。"
            case .cannotRemoveAdministrator:
                return "管理员不能移除其他管理员。"
            case .cannotLeaveDirectConversation:
                return "私聊会话不支持主动退出。"
            case .minimumGroupSizeViolation:
                return "退出后会话成员不能少于 2 人。"
            case .ownerMustTransferBeforeLeaving:
                return "群主退出前请先转让群主。"
            }
        }
    }

    private enum GroupRoleUpdateError: LocalizedError {
        case directConversationImmutable
        case insufficientPrivilege
        case memberNotFound
        case cannotUpdateSelf

        var errorDescription: String? {
            switch self {
            case .directConversationImmutable:
                return "私聊会话不支持成员角色管理。"
            case .insufficientPrivilege:
                return "只有群主可以调整成员角色。"
            case .memberNotFound:
                return "群成员不存在。"
            case .cannotUpdateSelf:
                return "不能直接修改自己的群角色。"
            }
        }
    }

    private enum GroupTitleUpdateError: LocalizedError {
        case directConversationImmutable
        case emptyTitle
        case insufficientPrivilege

        var errorDescription: String? {
            switch self {
            case .directConversationImmutable:
                return "私聊会话不支持修改标题。"
            case .emptyTitle:
                return "群聊名称不能为空。"
            case .insufficientPrivilege:
                return "只有群主或管理员可以修改群名称。"
            }
        }
    }

    private enum GroupMetadataUpdateError: LocalizedError {
        case directConversationImmutable
        case insufficientPrivilege
        case emptyUpdate
        case emptyTitle
        case invalidNotice

        var errorDescription: String? {
            switch self {
            case .directConversationImmutable:
                return "私聊会话不支持修改群资料。"
            case .insufficientPrivilege:
                return "只有群主或管理员可以修改群资料。"
            case .emptyUpdate:
                return "至少需要更新一项群资料。"
            case .emptyTitle:
                return "群聊名称不能为空。"
            case .invalidNotice:
                return "群公告不能为空。"
            }
        }
    }

    private enum RecallError: LocalizedError {
        case messageNotFound
        case notMessageSender
        case recallWindowExpired
        case unsupportedMessageKind
        case alreadyRecalled

        var errorDescription: String? {
            switch self {
            case .messageNotFound:
                return "消息不存在。"
            case .notMessageSender:
                return "只能撤回自己发送的消息。"
            case .recallWindowExpired:
                return "消息发送超过 2 分钟后不能撤回。"
            case .unsupportedMessageKind:
                return "当前消息不支持撤回。"
            case .alreadyRecalled:
                return "该消息已经撤回。"
            }
        }
    }

    private enum HistoryPage {
        static let defaultLimit = 50
        static let maxLimit = 100
    }

    private enum IncrementalPage {
        static let defaultLimit = 100
        static let maxLimit = 500
    }

    let db: any Database

    private var membershipService: ConversationMembershipService {
        ConversationMembershipService(db: db)
    }

    private var readStateService: ConversationReadStateService {
        ConversationReadStateService(db: db)
    }

    private var messageService: ConversationMessageService {
        ConversationMessageService(db: db)
    }

    private var searchService: ConversationSearchService {
        ConversationSearchService(db: db)
    }

    private var governanceService: ConversationGovernanceService {
        ConversationGovernanceService()
    }

    struct MemberRemovalResult {
        let requesterConversation: IMConversationResponse
        let removedConversation: IMConversationResponse
        let remainingUserIDs: [UUID]
    }

    func createConversation(
        kind: String?,
        title: String?,
        memberEmails: [String],
        creatorUserID: UUID
    ) async throws -> IMConversationResponse {
        let normalizedTitle = normalizedConversationTitle(title)
        let normalizedEmails = Array(
            Set(memberEmails.map(User.normalize).filter { !$0.isEmpty })
        ).sorted()

        guard !normalizedEmails.isEmpty else {
            throw Abort(.badRequest, reason: CreationError.emptyParticipants.localizedDescription)
        }

        let creator = try await requireUser(id: creatorUserID)
        let allRequestedEmails = Array(Set(normalizedEmails + [creator.email])).sorted()
        let users = try await User.query(on: db)
            .filter(\.$email ~~ allRequestedEmails)
            .all()

        let usersByEmail = Dictionary(uniqueKeysWithValues: users.map { ($0.email, $0) })
        let missingEmails = normalizedEmails.filter { usersByEmail[$0] == nil }
        guard missingEmails.isEmpty else {
            throw Abort(.badRequest, reason: CreationError.membersNotFound(missingEmails).localizedDescription)
        }

        let memberUserIDs = try allRequestedEmails.compactMap { email in
            try usersByEmail[email]?.requireID()
        }

        let conversationKind = try normalizedConversationKind(
            kind,
            normalizedTitle: normalizedTitle,
            memberUserIDs: memberUserIDs
        )
        let persistedTitle = conversationKind == .direct ? nil : normalizedTitle

        let response = try await db.transaction { database in
            if conversationKind == .direct,
               let existingConversationID = try await existingDirectConversationID(
                for: memberUserIDs,
                on: database
               ) {
                try await normalizeExistingDirectConversation(
                    conversationID: existingConversationID,
                    on: database
                )
                return try await conversationResponse(
                    conversationID: existingConversationID,
                    for: creatorUserID,
                    on: database
                )
            }

            let conversation = Conversation(
                title: persistedTitle,
                kind: conversationKind,
                updatedAt: Date()
            )
            try await conversation.create(on: database)
            let conversationID = try conversation.requireID()

            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: conversationKind == .group && userID == creatorUserID ? .owner : .member
                ).create(on: database)
            }

            if conversationKind == .group {
                let sequence = try await allocateNextServerSequence(
                    conversationID: conversationID,
                    updatedAt: Date(),
                    on: database
                )
                let systemMessage = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: creatorUserID,
                    serverSequence: sequence,
                    content: .system(
                        IMSystemEvent(
                            type: .groupCreated,
                            actorUserID: creatorUserID,
                            actorEmail: creator.email
                        )
                    )
                )
                try await systemMessage.create(on: database)
                try await readStateService.advanceReadSequenceIfMember(
                    conversationID: conversationID,
                    userID: creatorUserID,
                    readSequence: sequence,
                    on: database
                )
            }

            return try await conversationResponse(conversationID: conversationID, for: creatorUserID, on: database)
        }

        try await IMConversationSummaryProjectionService(db: db).refreshConversationSummaries(
            conversationID: response.id,
            recipientUserIDs: response.memberUserIDs
        )

        return response
    }

    private func normalizedConversationKind(
        _ kind: String?,
        normalizedTitle: String?,
        memberUserIDs: [UUID]
    ) throws -> IMConversationKind {
        let normalizedKind = kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let requestedKind: IMConversationKind
        if let normalizedKind, !normalizedKind.isEmpty {
            guard let parsedKind = IMConversationKind(rawValue: normalizedKind) else {
                throw Abort(.badRequest, reason: CreationError.invalidKind.localizedDescription)
            }
            requestedKind = parsedKind
        } else {
            requestedKind = (normalizedTitle == nil && memberUserIDs.count == 2) ? .direct : .group
        }

        if requestedKind == .direct && memberUserIDs.count != 2 {
            throw Abort(.badRequest, reason: CreationError.invalidDirectParticipants.localizedDescription)
        }

        return requestedKind
    }

    private func existingDirectConversationID(
        for memberUserIDs: [UUID],
        on database: any Database
    ) async throws -> UUID? {
        let expectedMemberIDs = Set(memberUserIDs)
        guard expectedMemberIDs.count == 2 else {
            return nil
        }

        let sharedMemberships = try await ConversationMember.query(on: database)
            .filter(\.$user.$id ~~ Array(expectedMemberIDs))
            .all()
        let sharedConversationIDs = Dictionary(grouping: sharedMemberships, by: \.$conversation.id)
            .compactMap { conversationID, memberships -> UUID? in
                let actualMemberIDs = Set(memberships.map(\.$user.id))
                return actualMemberIDs == expectedMemberIDs ? conversationID : nil
            }

        guard !sharedConversationIDs.isEmpty else {
            return nil
        }

        let allMemberships = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id ~~ sharedConversationIDs)
            .all()
        let exactOneToOneConversationIDs = Dictionary(grouping: allMemberships, by: \.$conversation.id)
            .compactMap { conversationID, memberships -> UUID? in
                let actualMemberIDs = Set(memberships.map(\.$user.id))
                return actualMemberIDs == expectedMemberIDs ? conversationID : nil
            }

        guard !exactOneToOneConversationIDs.isEmpty else {
            return nil
        }

        let conversations = try await Conversation.query(on: database)
            .filter(\.$id ~~ exactOneToOneConversationIDs)
            .filter(\.$kind == IMConversationKind.direct.rawValue)
            .all()
        return try conversations.sorted { lhs, rhs in
            let lhsDate = lhs.createdAt ?? .distantPast
            let rhsDate = rhs.createdAt ?? .distantPast
            if lhsDate == rhsDate {
                let lhsID = (try? lhs.requireID().uuidString) ?? ""
                let rhsID = (try? rhs.requireID().uuidString) ?? ""
                return lhsID < rhsID
            }
            return lhsDate < rhsDate
        }.first?.requireID()
    }

    private func normalizeExistingDirectConversation(
        conversationID: UUID,
        on database: any Database
    ) async throws {
        guard let conversation = try await Conversation.find(conversationID, on: database) else {
            return
        }

        var shouldUpdate = false
        if conversation.title != nil {
            conversation.title = nil
            shouldUpdate = true
        }

        if shouldUpdate {
            conversation.updatedAt = Date()
            try await conversation.update(on: database)
        }
    }

    func addMembers(
        in conversationID: UUID,
        memberEmails: [String],
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        let normalizedEmails = Array(
            Set(memberEmails.map(User.normalize).filter { !$0.isEmpty })
        ).sorted()
        guard !normalizedEmails.isEmpty else {
            throw Abort(.badRequest, reason: MembershipUpdateError.emptyParticipants.localizedDescription)
        }

        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        guard conversation.conversationKind == .group else {
            throw Abort(.badRequest, reason: MembershipUpdateError.directConversationImmutable.localizedDescription)
        }
        let requesterMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: requesterUserID
        )
        guard requesterMembership.memberRoleEnum.canAddMembers else {
            throw Abort(.forbidden, reason: MembershipUpdateError.insufficientPrivilegeToAddMembers.localizedDescription)
        }
        let requester = try await requireUser(id: requesterUserID)

        let users = try await User.query(on: db)
            .filter(\.$email ~~ normalizedEmails)
            .all()
        let usersByEmail = Dictionary(uniqueKeysWithValues: users.map { ($0.email, $0) })
        let missingEmails = normalizedEmails.filter { usersByEmail[$0] == nil }
        guard missingEmails.isEmpty else {
            throw Abort(.badRequest, reason: CreationError.membersNotFound(missingEmails).localizedDescription)
        }

        let existingMemberships = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .all()
        let existingUserIDs = Set(existingMemberships.map(\.$user.id))
        let newUsers = try users.filter { user in
            let userID = try user.requireID()
            return !existingUserIDs.contains(userID)
        }
        guard !newUsers.isEmpty else {
            throw Abort(.badRequest, reason: MembershipUpdateError.noNewMembers.localizedDescription)
        }

        let response = try await db.transaction { database in
            let sequence = try await allocateNextServerSequence(
                conversationID: conversationID,
                updatedAt: Date(),
                on: database
            )
            for user in newUsers {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: try user.requireID(),
                    visibleFromSequence: sequence
                ).create(on: database)
            }

            let systemMessage = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: requesterUserID,
                serverSequence: sequence,
                content: .system(
                    IMSystemEvent(
                        type: .membersAdded,
                        actorUserID: requesterUserID,
                        actorEmail: requester.email,
                        memberEmails: newUsers.map(\.email).sorted()
                    )
                )
            )
            try await systemMessage.create(on: database)
            try await readStateService.advanceReadSequenceIfMember(
                conversationID: conversationID,
                userID: requesterUserID,
                readSequence: sequence,
                on: database
            )

            return try await conversationResponse(
                conversationID: conversationID,
                for: requesterUserID,
                on: database
            )
        }

        try await IMConversationSummaryProjectionService(db: db).refreshConversationSummaries(
            conversationID: conversationID,
            recipientUserIDs: response.memberUserIDs
        )

        return response
    }

    func leaveConversation(
        in conversationID: UUID,
        requesterUserID: UUID
    ) async throws {
        let requester = try await requireUser(id: requesterUserID)
        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        guard conversation.conversationKind == .group else {
            throw Abort(.badRequest, reason: MembershipUpdateError.cannotLeaveDirectConversation.localizedDescription)
        }
        let requesterMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: requesterUserID
        )
        guard requesterMembership.memberRoleEnum != .owner else {
            throw Abort(.badRequest, reason: MembershipUpdateError.ownerMustTransferBeforeLeaving.localizedDescription)
        }

        let memberships = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .all()
        guard memberships.count - 1 >= 2 else {
            throw Abort(.badRequest, reason: MembershipUpdateError.minimumGroupSizeViolation.localizedDescription)
        }

        guard let membership = memberships.first(where: { $0.$user.id == requesterUserID }) else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        let remainingUserIDs = memberships
            .map(\.$user.id)
            .filter { $0 != requesterUserID }
        try await db.transaction { database in
            try await membership.delete(on: database)
            let sequence = try await allocateNextServerSequence(
                conversationID: conversationID,
                updatedAt: Date(),
                on: database
            )
            let systemMessage = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: requesterUserID,
                serverSequence: sequence,
                content: .system(
                    IMSystemEvent(
                        type: .memberLeft,
                        actorUserID: requesterUserID,
                        actorEmail: requester.email
                    )
                )
            )
            try await systemMessage.create(on: database)
        }

        let projectionService = IMConversationSummaryProjectionService(db: db)
        try await projectionService.markConversationRemoved(
            conversationID: conversationID,
            recipientUserID: requesterUserID
        )
        try await projectionService.refreshConversationSummaries(
            conversationID: conversationID,
            recipientUserIDs: remainingUserIDs
        )
    }

    func removeMember(
        in conversationID: UUID,
        memberUserID: UUID,
        requesterUserID: UUID
    ) async throws -> MemberRemovalResult {
        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        guard conversation.conversationKind == .group else {
            throw Abort(.badRequest, reason: MembershipUpdateError.directConversationImmutable.localizedDescription)
        }
        guard memberUserID != requesterUserID else {
            throw Abort(.badRequest, reason: MembershipUpdateError.cannotRemoveSelf.localizedDescription)
        }

        let requesterMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: requesterUserID
        )
        let targetMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: memberUserID
        )
        try governanceService.validateMemberRemovalPrivilege(
            requesterRole: requesterMembership.memberRoleEnum,
            targetRole: targetMembership.memberRoleEnum
        )

        let memberships = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .all()
        guard memberships.count - 1 >= 2 else {
            throw Abort(.badRequest, reason: MembershipUpdateError.minimumGroupSizeViolation.localizedDescription)
        }

        let requester = try await requireUser(id: requesterUserID)
        let targetUser = try await requireUser(id: memberUserID)
        let removedConversation = try await conversationResponse(
            conversationID: conversationID,
            for: memberUserID,
            on: db
        )

        let requesterConversation = try await db.transaction { database in
            try await targetMembership.delete(on: database)

            let sequence = try await allocateNextServerSequence(
                conversationID: conversationID,
                updatedAt: Date(),
                on: database
            )
            let systemMessage = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: requesterUserID,
                serverSequence: sequence,
                content: .system(
                    IMSystemEvent(
                        type: .memberRemoved,
                        actorUserID: requesterUserID,
                        actorEmail: requester.email,
                        targetUserID: memberUserID,
                        targetEmail: targetUser.email
                    )
                )
            )
            try await systemMessage.create(on: database)
            try await readStateService.advanceReadSequenceIfMember(
                conversationID: conversationID,
                userID: requesterUserID,
                readSequence: sequence,
                on: database
            )

            return try await conversationResponse(
                conversationID: conversationID,
                for: requesterUserID,
                on: database
            )
        }

        let remainingUserIDs = requesterConversation.memberUserIDs
        let projectionService = IMConversationSummaryProjectionService(db: db)
        try await projectionService.markConversationRemoved(
            conversationID: conversationID,
            recipientUserID: memberUserID
        )
        try await projectionService.refreshConversationSummaries(
            conversationID: conversationID,
            recipientUserIDs: remainingUserIDs
        )

        return MemberRemovalResult(
            requesterConversation: requesterConversation,
            removedConversation: removedConversation,
            remainingUserIDs: remainingUserIDs
        )
    }

    func updateMemberRole(
        in conversationID: UUID,
        memberUserID: UUID,
        role: IMConversationMemberRole,
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        guard conversation.conversationKind == .group else {
            throw Abort(.badRequest, reason: GroupRoleUpdateError.directConversationImmutable.localizedDescription)
        }
        guard memberUserID != requesterUserID else {
            throw Abort(.badRequest, reason: GroupRoleUpdateError.cannotUpdateSelf.localizedDescription)
        }

        let requesterMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: requesterUserID
        )
        guard requesterMembership.memberRoleEnum == .owner else {
            throw Abort(.forbidden, reason: GroupRoleUpdateError.insufficientPrivilege.localizedDescription)
        }

        let targetMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: memberUserID
        )
        let requester = try await requireUser(id: requesterUserID)
        let targetUser = try await requireUser(id: memberUserID)
        let previousRole = targetMembership.memberRoleEnum

        guard previousRole != role else {
            return try await conversationResponse(
                conversationID: conversationID,
                for: requesterUserID,
                on: db
            )
        }

        let response = try await db.transaction { database in
            switch role {
            case .owner:
                requesterMembership.memberRoleEnum = .admin
                targetMembership.memberRoleEnum = .owner
                try await requesterMembership.update(on: database)
                try await targetMembership.update(on: database)
            case .admin, .member:
                targetMembership.memberRoleEnum = role
                try await targetMembership.update(on: database)
            }

            let sequence = try await allocateNextServerSequence(
                conversationID: conversationID,
                updatedAt: Date(),
                on: database
            )
            let systemMessage = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: requesterUserID,
                serverSequence: sequence,
                content: .system(
                    IMSystemEvent(
                        type: role == .owner ? .ownershipTransferred : .roleUpdated,
                        actorUserID: requesterUserID,
                        actorEmail: requester.email,
                        targetUserID: memberUserID,
                        targetEmail: targetUser.email,
                        previousRole: previousRole,
                        newRole: role
                    )
                )
            )
            try await systemMessage.create(on: database)
            try await readStateService.advanceReadSequenceIfMember(
                conversationID: conversationID,
                userID: requesterUserID,
                readSequence: sequence,
                on: database
            )

            return try await conversationResponse(
                conversationID: conversationID,
                for: requesterUserID,
                on: database
            )
        }

        try await IMConversationSummaryProjectionService(db: db).refreshConversationSummaries(
            conversationID: conversationID,
            recipientUserIDs: response.memberUserIDs
        )
        return response
    }

    func updateConversationTitle(
        in conversationID: UUID,
        title: String,
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        guard conversation.conversationKind == .group else {
            throw Abort(.badRequest, reason: GroupTitleUpdateError.directConversationImmutable.localizedDescription)
        }
        let requesterMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: requesterUserID
        )
        guard requesterMembership.memberRoleEnum.canRenameConversation else {
            throw Abort(.forbidden, reason: GroupTitleUpdateError.insufficientPrivilege.localizedDescription)
        }

        guard let normalizedTitle = normalizedConversationTitle(title) else {
            throw Abort(.badRequest, reason: GroupTitleUpdateError.emptyTitle.localizedDescription)
        }
        let requester = try await requireUser(id: requesterUserID)

        if conversation.title == normalizedTitle {
            return try await conversationResponse(
                conversationID: conversationID,
                for: requesterUserID,
                on: db
            )
        }

        let response = try await db.transaction { database in
            guard let persistedConversation = try await Conversation.find(conversationID, on: database) else {
                throw Abort(.notFound, reason: "会话不存在。")
            }

            persistedConversation.title = normalizedTitle
            try await persistedConversation.update(on: database)

            let sequence = try await allocateNextServerSequence(
                conversationID: conversationID,
                updatedAt: Date(),
                on: database
            )
            let systemMessage = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: requesterUserID,
                serverSequence: sequence,
                content: .system(
                    IMSystemEvent(
                        type: .metadataUpdated,
                        actorUserID: requesterUserID,
                        actorEmail: requester.email,
                        updatedFields: [.title],
                        title: normalizedTitle
                    )
                )
            )
            try await systemMessage.create(on: database)
            try await readStateService.advanceReadSequenceIfMember(
                conversationID: conversationID,
                userID: requesterUserID,
                readSequence: sequence,
                on: database
            )

            return try await conversationResponse(
                conversationID: conversationID,
                for: requesterUserID,
                on: database
            )
        }

        try await IMConversationSummaryProjectionService(db: db).refreshConversationSummaries(
            conversationID: conversationID,
            recipientUserIDs: response.memberUserIDs
        )
        return response
    }

    func updateConversationMetadata(
        in conversationID: UUID,
        title: String?,
        notice: String?,
        avatarPreset: IMConversationAvatarPreset?,
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        guard conversation.conversationKind == .group else {
            throw Abort(.badRequest, reason: GroupMetadataUpdateError.directConversationImmutable.localizedDescription)
        }
        let requesterMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: requesterUserID
        )
        guard requesterMembership.memberRoleEnum.canRenameConversation else {
            throw Abort(.forbidden, reason: GroupMetadataUpdateError.insufficientPrivilege.localizedDescription)
        }

        let changeSet = try governanceService.makeMetadataChangeSet(
            title: title,
            notice: notice,
            avatarPreset: avatarPreset
        )

        let requester = try await requireUser(id: requesterUserID)
        let response = try await db.transaction { database in
            guard let persistedConversation = try await Conversation.find(conversationID, on: database) else {
                throw Abort(.notFound, reason: "会话不存在。")
            }

            let updatedFields = governanceService.apply(changeSet, to: persistedConversation)

            if updatedFields.isEmpty {
                return try await conversationResponse(
                    conversationID: conversationID,
                    for: requesterUserID,
                    on: database
                )
            }

            try await persistedConversation.update(on: database)
            let sequence = try await allocateNextServerSequence(
                conversationID: conversationID,
                updatedAt: Date(),
                on: database
            )
            let systemMessage = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: requesterUserID,
                serverSequence: sequence,
                content: .system(
                    IMSystemEvent(
                        type: .metadataUpdated,
                        actorUserID: requesterUserID,
                        actorEmail: requester.email,
                        updatedFields: updatedFields,
                        title: persistedConversation.title,
                        notice: persistedConversation.notice,
                        avatarPreset: persistedConversation.avatarPresetEnum
                    )
                )
            )
            try await systemMessage.create(on: database)
            try await readStateService.advanceReadSequenceIfMember(
                conversationID: conversationID,
                userID: requesterUserID,
                readSequence: sequence,
                on: database
            )

            return try await conversationResponse(
                conversationID: conversationID,
                for: requesterUserID,
                on: database
            )
        }

        try await IMConversationSummaryProjectionService(db: db).refreshConversationSummaries(
            conversationID: conversationID,
            recipientUserIDs: response.memberUserIDs
        )
        return response
    }

    func updateConversationPreferences(
        in conversationID: UUID,
        isPinned: Bool?,
        isMuted: Bool?,
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        _ = try await requireConversationAndMembership(conversationID: conversationID, userID: requesterUserID)
        let recordID = ConversationUserSummary.recordID(ownerUserID: requesterUserID, conversationID: conversationID)

        try await IMConversationSummaryProjectionService(db: db).refreshConversationSummaries(
            conversationID: conversationID,
            recipientUserIDs: [requesterUserID]
        )

        guard let summary = try await ConversationUserSummary.find(recordID, on: db) else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        if let isPinned {
            summary.isPinned = isPinned
            summary.pinnedAt = isPinned ? Date() : nil
        }
        if let isMuted {
            summary.isMuted = isMuted
        }
        summary.updatedAt = Date()
        try await summary.update(on: db)

        return try await conversationResponse(
            conversationID: conversationID,
            for: requesterUserID,
            on: db
        )
    }

    func recallMessage(
        in conversationID: UUID,
        messageID: UUID,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        _ = try await requireConversationAndMembership(conversationID: conversationID, userID: requesterUserID)

        let recalledMessage = try await db.transaction { database in
            try await messageService.recallMessage(
                in: conversationID,
                messageID: messageID,
                requesterUserID: requesterUserID,
                on: database
            )
        }

        let recipientUserIDs = try await listMembers(in: conversationID, for: requesterUserID).map(\.id)
        try await IMConversationSummaryProjectionService(db: db).refreshConversationSummaries(
            conversationID: conversationID,
            recipientUserIDs: recipientUserIDs
        )
        return try messageResponse(from: recalledMessage, conversationID: conversationID)
    }

    func latestMessage(in conversationID: UUID) async throws -> IMMessageResponse? {
        guard let message = try await ConversationMessage.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .sort(\.$serverSequence, .descending)
            .first()
        else {
            return nil
        }

        return try messageService.messageResponse(from: message, conversationID: conversationID)
    }

    func listConversations(
        for userID: UUID,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationPageResponse {
        try await IMConversationSummaryProjectionService(db: db)
            .listConversations(for: userID, cursor: cursor, limit: limit)
    }

    func listConversationChanges(
        for userID: UUID,
        afterToken: String,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationChangesResponse {
        try await IMConversationSummaryProjectionService(db: db)
            .listConversationChanges(
                for: userID,
                afterToken: afterToken,
                cursor: cursor,
                limit: limit
            )
    }

    func listMembers(in conversationID: UUID, for userID: UUID) async throws -> [IMConversationMemberResponse] {
        try await membershipService.listMemberResponses(in: conversationID, for: userID)
    }

    func listMessages(
        in conversationID: UUID,
        for userID: UUID,
        beforeSequence: Int? = nil,
        limit requestedLimit: Int? = nil
    ) async throws -> [IMMessageResponse] {
        let membership = try await membershipService.requireMembershipRecord(
            conversationID: conversationID,
            userID: userID
        )
        let limit = try normalizedHistoryLimit(requestedLimit)

        let builder = ConversationMessage.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$serverSequence >= membership.visibleFromSequence)
        if let beforeSequence {
            guard beforeSequence > 0 else {
                throw Abort(.badRequest, reason: "分页游标无效。")
            }
            builder.filter(\.$serverSequence < beforeSequence)
        }

        let messages = try await builder
            .sort(\.$serverSequence, .descending)
            .limit(limit)
            .all()
            .reversed()

        return try messages.map { try messageService.messageResponse(from: $0, conversationID: conversationID) }
    }

    func listMessagesSince(
        in conversationID: UUID,
        for userID: UUID,
        afterSequence: Int,
        limit requestedLimit: Int? = nil
    ) async throws -> IMMessageSinceResponse {
        let membership = try await membershipService.requireMembershipRecord(
            conversationID: conversationID,
            userID: userID
        )

        guard afterSequence >= 0 else {
            throw Abort(.badRequest, reason: "增量游标无效。")
        }

        let limit = try normalizedIncrementalLimit(requestedLimit)
        var rows = try await ConversationMessage.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$serverSequence > max(afterSequence, membership.visibleFromSequence - 1))
            .sort(\.$serverSequence, .ascending)
            .limit(limit + 1)
            .all()
        let hasMore = rows.count > limit
        if hasMore {
            rows.removeLast()
        }

        let messages = try rows.map { try messageService.messageResponse(from: $0, conversationID: conversationID) }
        return IMMessageSinceResponse(
            messages: messages,
            hasMore: hasMore,
            nextAfterSequence: messages.last?.serverSequence
        )
    }

    func searchMessages(
        in conversationID: UUID,
        for userID: UUID,
        query rawQuery: String,
        cursor rawCursor: String?,
        limit requestedLimit: Int? = nil
    ) async throws -> IMConversationMessageSearchPageResponse {
        let membership = try await membershipService.requireMembershipRecord(
            conversationID: conversationID,
            userID: userID
        )
        return try await searchService.searchMessages(
            in: conversationID,
            membership: membership,
            query: rawQuery,
            cursor: rawCursor,
            limit: requestedLimit
        )
    }

    func markConversationRead(
        in conversationID: UUID,
        for userID: UUID,
        readSequence requestedReadSequence: Int
    ) async throws -> IMConversationReadResponse {
        guard requestedReadSequence >= 0 else {
            throw Abort(.badRequest, reason: "已读游标无效。")
        }

        try await readStateService.advanceConversationRead(
            conversationID: conversationID,
            userID: userID,
            requestedReadSequence: requestedReadSequence,
            on: db
        )

        let readState = try await readStateService.conversationReadState(
            conversationID: conversationID,
            userID: userID,
            on: db
        )
        try await IMConversationSummaryProjectionService(db: db).refreshConversationSummaries(
            conversationID: conversationID,
            recipientUserIDs: [userID]
        )
        return IMConversationReadResponse(
            conversationID: conversationID,
            lastReadSequence: readState.lastReadSequence,
            unreadCount: readState.unreadCount
        )
    }

    func conversationSummary(
        conversationID: UUID,
        for userID: UUID
    ) async throws -> IMConversationResponse {
        try await conversationResponse(
            conversationID: conversationID,
            for: userID,
            on: db
        )
    }

    private func requireMembership(conversationID: UUID, userID: UUID) async throws {
        _ = try await membershipService.requireConversationAndMembership(
            conversationID: conversationID,
            userID: userID
        )
    }

    private func requireMembershipRecord(
        conversationID: UUID,
        userID: UUID,
        on database: (any Database)? = nil
    ) async throws -> ConversationMember {
        try await membershipService.requireMembershipRecord(
            conversationID: conversationID,
            userID: userID,
            on: database
        )
    }

    private func requireConversationAndMembership(
        conversationID: UUID,
        userID: UUID
    ) async throws -> Conversation {
        try await membershipService.requireConversationAndMembership(
            conversationID: conversationID,
            userID: userID
        )
    }

    private func advanceConversationRead(
        conversationID: UUID,
        userID: UUID,
        requestedReadSequence: Int,
        on database: any Database
    ) async throws {
        try await readStateService.advanceConversationRead(
            conversationID: conversationID,
            userID: userID,
            requestedReadSequence: requestedReadSequence,
            on: database
        )
    }

    private func requireUser(id userID: UUID) async throws -> User {
        guard let user = try await User.find(userID, on: db) else {
            throw Abort(.notFound, reason: "用户不存在。")
        }
        return user
    }

    private func conversationResponse(
        conversationID: UUID,
        for userID: UUID,
        on database: any Database
    ) async throws -> IMConversationResponse {
        guard let conversation = try await Conversation.find(conversationID, on: database) else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        let memberships = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .with(\.$user)
            .all()
        let memberUserIDs = memberships.map(\.$user.id).sorted { $0.uuidString < $1.uuidString }
        guard memberUserIDs.contains(userID) else {
            throw Abort(.notFound, reason: "会话不存在。")
        }
        guard let membership = memberships.first(where: { $0.$user.id == userID }) else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        let lastMessage = try await ConversationMessage.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$serverSequence >= membership.visibleFromSequence)
            .sort(\.$serverSequence, .descending)
            .first()
            .map(messageService.makePreview)
        let readState = try await readStateService.conversationReadState(
            conversationID: conversationID,
            userID: userID,
            on: database
        )
        let preferences = try await readStateService.membershipSummaryPreferences(
            conversationID: conversationID,
            userID: userID,
            on: database
        )

        return IMConversationResponse(
            id: conversationID,
            title: conversation.title,
            kind: conversation.kind,
            directMessagingState: directMessagingState(for: conversation),
            directPeer: directPeer(from: memberships, currentUserID: userID),
            notice: conversation.notice,
            avatarPreset: conversation.avatarPresetEnum,
            memberCount: memberUserIDs.count,
            memberUserIDs: memberUserIDs,
            lastMessage: lastMessage,
            lastReadSequence: readState.lastReadSequence,
            unreadCount: readState.unreadCount,
            isPinned: preferences.isPinned,
            pinnedAt: preferences.pinnedAt,
            isMuted: preferences.isMuted,
            createdAt: conversation.createdAt,
            updatedAt: lastMessage?.createdAt ?? conversation.updatedAt
        )
    }

    private func conversationReadState(
        conversationID: UUID,
        userID: UUID,
        on database: any Database
    ) async throws -> ConversationReadState {
        try await readStateService.conversationReadState(
            conversationID: conversationID,
            userID: userID,
            on: database
        )
    }

    private func latestVisibleConversationSequence(
        conversationID: UUID,
        visibleFromSequence: Int,
        on database: any Database
    ) async throws -> Int {
        try await readStateService.latestVisibleConversationSequence(
            conversationID: conversationID,
            visibleFromSequence: visibleFromSequence,
            on: database
        )
    }

    private func allocateNextServerSequence(
        conversationID: UUID,
        updatedAt: Date,
        on database: any Database
    ) async throws -> Int {
        if let sql = database as? any SQLDatabase,
           let nextSequence = try await sql.update(Conversation.schema)
            .set(
                "last_message_sequence",
                to: SQLQueryString(
                    "MAX(\(ident: "last_message_sequence"), COALESCE((SELECT MAX(\(ident: "server_sequence")) FROM \(ident: ConversationMessage.schema) WHERE \(ident: "conversation_id") = \(bind: conversationID)), 0)) + 1"
                )
            )
            .set("updated_at", to: updatedAt)
            .where("id", .equal, conversationID)
            .returning("last_message_sequence")
            .first(decodingColumn: "last_message_sequence", as: Int.self)
        {
            return nextSequence
        }

        guard let conversation = try await Conversation.find(conversationID, on: database) else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        let latestPersistedMessageSequence = try await ConversationMessage.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .sort(\.$serverSequence, .descending)
            .first()?
            .serverSequence ?? 0
        conversation.lastMessageSequence = max(
            conversation.lastMessageSequence,
            latestPersistedMessageSequence
        ) + 1
        conversation.updatedAt = updatedAt
        try await conversation.update(on: database)
        return conversation.lastMessageSequence
    }

    private func advanceReadSequenceIfMember(
        conversationID: UUID,
        userID: UUID,
        readSequence: Int,
        on database: any Database
    ) async throws {
        try await readStateService.advanceReadSequenceIfMember(
            conversationID: conversationID,
            userID: userID,
            readSequence: readSequence,
            on: database
        )
    }

    private func makePreview(from message: ConversationMessage) throws -> IMMessagePreviewResponse {
        try messageService.makePreview(from: message)
    }

    private func membershipSummaryPreferences(
        conversationID: UUID,
        userID: UUID,
        on database: any Database
    ) async throws -> ConversationSummaryPreferences {
        try await readStateService.membershipSummaryPreferences(
            conversationID: conversationID,
            userID: userID,
            on: database
        )
    }

    private func messageResponse(
        from message: ConversationMessage,
        conversationID: UUID
    ) throws -> IMMessageResponse {
        try messageService.messageResponse(from: message, conversationID: conversationID)
    }

    private func normalizedHistoryLimit(_ requestedLimit: Int?) throws -> Int {
        guard let requestedLimit else {
            return HistoryPage.defaultLimit
        }

        guard requestedLimit > 0 else {
            throw Abort(.badRequest, reason: "分页条数无效。")
        }

        return min(requestedLimit, HistoryPage.maxLimit)
    }

    private func normalizedIncrementalLimit(_ requestedLimit: Int?) throws -> Int {
        guard let requestedLimit else {
            return IncrementalPage.defaultLimit
        }

        guard requestedLimit > 0 else {
            throw Abort(.badRequest, reason: "分页条数无效。")
        }

        return min(requestedLimit, IncrementalPage.maxLimit)
    }

    private func searchSnippet(
        for rawQuery: String,
        content: IMMessageContent
    ) -> String? {
        searchService.searchSnippet(for: rawQuery, content: content)
    }

    private func searchableTexts(for content: IMMessageContent) -> [String] {
        content.presentation.searchableTexts
    }

    private func normalizedConversationTitle(_ title: String?) -> String? {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedTitle.isEmpty ? nil : trimmedTitle
    }

    private func validateMemberRemovalPrivilege(
        requesterRole: IMConversationMemberRole,
        targetRole: IMConversationMemberRole
    ) throws {
        try governanceService.validateMemberRemovalPrivilege(
            requesterRole: requesterRole,
            targetRole: targetRole
        )
    }

    private func memberRoleUpdateSystemMessage(
        requesterEmail: String,
        targetEmail: String,
        previousRole: IMConversationMemberRole,
        newRole: IMConversationMemberRole
    ) -> String {
        switch newRole {
        case .owner:
            return "\(requesterEmail) 已将群主转让给 \(targetEmail)"
        case .admin:
            return "\(requesterEmail) 将 \(targetEmail) 设为管理员"
        case .member:
            if previousRole == .admin {
                return "\(requesterEmail) 取消了 \(targetEmail) 的管理员身份"
            }
            return "\(requesterEmail) 更新了 \(targetEmail) 的群角色"
        }
    }

    private func sortConversationMembers(
        lhs: IMConversationMemberResponse,
        rhs: IMConversationMemberResponse
    ) -> Bool {
        let lhsRole = IMConversationMemberRole(rawValue: lhs.role) ?? .member
        let rhsRole = IMConversationMemberRole(rawValue: rhs.role) ?? .member
        let lhsPriority = memberRolePriority(lhsRole)
        let rhsPriority = memberRolePriority(rhsRole)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        return lhs.email < rhs.email
    }

    private func memberRolePriority(_ role: IMConversationMemberRole) -> Int {
        switch role {
        case .owner:
            return 0
        case .admin:
            return 1
        case .member:
            return 2
        }
    }

    private func directMessagingState(for conversation: Conversation) -> String? {
        guard conversation.conversationKind == .direct else {
            return nil
        }

        return conversation.directMessagingState
    }

    private func directPeer(
        from memberships: [ConversationMember],
        currentUserID: UUID
    ) -> IMDirectPeerResponse? {
        guard let peerMembership = memberships.first(where: { $0.$user.id != currentUserID }),
              let peerUser = peerMembership.$user.value
        else {
            return nil
        }

        return IMDirectPeerResponse(
            id: peerMembership.$user.id,
            email: peerUser.email,
            displayName: peerUser.displayName,
            avatarPreset: peerUser.avatarPresetEnum
        )
    }
}

private extension IMConversationMemberRole {
    var canAddMembers: Bool {
        self == .owner || self == .admin
    }

    var canRenameConversation: Bool {
        self == .owner || self == .admin
    }
}
