import Fluent
import Vapor

struct ConversationMembershipCommandSupport {
    let db: any Database
    let userDirectoryDB: any Database
    let usesLocalConversationDirectoryTables: Bool

    init(
        db: any Database,
        userDirectoryDB: (any Database)? = nil,
        usesLocalConversationDirectoryTables: Bool = true
    ) {
        self.db = db
        self.userDirectoryDB = userDirectoryDB ?? db
        self.usesLocalConversationDirectoryTables = usesLocalConversationDirectoryTables
    }

    private var userLookup: ConversationUserLookupSupport { ConversationUserLookupSupport(db: userDirectoryDB) }
    private var membershipService: ConversationMembershipService {
        ConversationMembershipService(db: db, userDirectoryDB: userDirectoryDB)
    }
    private var governanceService: ConversationGovernanceService { ConversationGovernanceService() }
    private var refreshPublisher: ConversationSummaryRefreshPublisher { ConversationSummaryRefreshPublisher(db: db) }

    func createConversation(
        conversationID: UUID,
        assignedShardID: String,
        kind: String?,
        title: String?,
        memberEmails: [String],
        creatorUserID: UUID
    ) async throws -> ConversationCreateCommandResult {
        let normalizedTitle = ConversationCommandNormalizationSupport.normalizedConversationTitle(title)
        let normalizedEmails = Array(
            Set(memberEmails.map(User.normalize).filter { !$0.isEmpty })
        ).sorted()

        guard !normalizedEmails.isEmpty else {
            throw Abort(.badRequest, reason: "至少需要提供一个其他会话成员。")
        }

        let creator = try await userLookup.requireUser(id: creatorUserID)
        let allRequestedEmails = Array(Set(normalizedEmails + [creator.email])).sorted()
        let users = try await User.query(on: userDirectoryDB)
            .filter(\.$email ~~ allRequestedEmails)
            .all()

        let usersByEmail = Dictionary(uniqueKeysWithValues: users.map { ($0.email, $0) })
        let missingEmails = normalizedEmails.filter { usersByEmail[$0] == nil }
        guard missingEmails.isEmpty else {
            throw Abort(.badRequest, reason: "以下成员不存在：\(missingEmails.joined(separator: "、"))。")
        }

        let memberUserIDs = try allRequestedEmails.compactMap { email in
            try usersByEmail[email]?.requireID()
        }

        let conversationKind = try ConversationCommandNormalizationSupport.normalizedConversationKind(
            kind,
            normalizedTitle: normalizedTitle,
            memberUserIDs: memberUserIDs
        )
        if conversationKind == .group {
            try IMGroupMemberLimitGuard.validateGroupMemberCount(memberUserIDs.count)
        }
        let persistedTitle = conversationKind == .direct ? nil : normalizedTitle

        let response = try await db.transaction { database in
            try await ConversationWriteFenceService.requireWritesAllowed(conversationID: conversationID, on: database)
            if usesLocalConversationDirectoryTables,
               conversationKind == .direct,
               let existingConversationID = try await ConversationDirectReuseSupport(db: database)
                .existingDirectConversationID(for: memberUserIDs) {
                try await ConversationDirectReuseSupport(db: database)
                    .normalizeExistingDirectConversation(conversationID: existingConversationID)
                return ConversationCreateCommandResult(
                    receipt: ConversationCommandReceipt(
                        conversationID: existingConversationID,
                        eventID: nil,
                        eventType: .membershipAdded,
                        acceptedAt: Date(),
                        membershipRevision: nil,
                        didMutate: false
                    ),
                    kind: .direct,
                    memberUserIDs: memberUserIDs
                )
            }

            let conversation = Conversation(
                id: conversationID,
                title: persistedTitle,
                kind: conversationKind,
                updatedAt: Date()
            )
            try await conversation.create(on: database)
            if usesLocalConversationDirectoryTables {
                try await DatabaseConversationDirectory(db: database).registerConversation(
                    conversationID: conversationID,
                    shardID: assignedShardID
                )
            }

            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: conversationKind == .group && userID == creatorUserID ? .owner : .member
                ).create(on: database)
            }

            if usesLocalConversationDirectoryTables,
               conversationKind == .direct {
                try await DatabaseDirectConversationIndex(db: database).registerDirectConversation(
                    conversationID: conversationID,
                    memberUserIDs: memberUserIDs,
                    shardID: assignedShardID
                )
                if memberUserIDs.count == 2 {
                    try await DirectConversationPairDirectoryService(db: database).upsert(
                        lhs: memberUserIDs[0],
                        rhs: memberUserIDs[1],
                        conversationID: conversationID,
                        directMessagingState: .active
                    )
                }
            }

            let event = try await ConversationSummaryRefreshPublisher(db: database).publish(
                .membershipAdded,
                conversationID: conversationID,
                actorUserID: creatorUserID,
                recipientUserIDs: memberUserIDs,
                on: database
            )
            return ConversationCreateCommandResult(
                receipt: ConversationCommandReceipt(
                    conversationID: conversationID,
                    eventID: try event.requireID(),
                    eventType: .membershipAdded,
                    acceptedAt: event.createdAt,
                    membershipRevision: conversation.membershipRevision,
                    didMutate: true
                ),
                kind: conversationKind,
                memberUserIDs: memberUserIDs
            )
        }

        return response
    }

    func addMembers(
        in conversationID: UUID,
        memberEmails: [String],
        requesterUserID: UUID
    ) async throws -> ConversationCommandReceipt {
        let normalizedEmails = Array(
            Set(memberEmails.map(User.normalize).filter { !$0.isEmpty })
        ).sorted()
        guard !normalizedEmails.isEmpty else {
            throw Abort(.badRequest, reason: "至少需要提供一个成员邮箱。")
        }

        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireGroup(
            conversation,
            reason: "私聊会话不支持新增成员。"
        )
        try governanceService.requireUserMutationAllowed(in: conversation)
        let requesterMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireOwnerOrAdmin(
            requesterMembership.memberRoleEnum,
            reason: "只有群主或管理员可以添加成员。"
        )
        let users = try await User.query(on: userDirectoryDB)
            .filter(\.$email ~~ normalizedEmails)
            .all()
        let usersByEmail = Dictionary(uniqueKeysWithValues: users.map { ($0.email, $0) })
        let missingEmails = normalizedEmails.filter { usersByEmail[$0] == nil }
        guard missingEmails.isEmpty else {
            throw Abort(.badRequest, reason: "以下成员不存在：\(missingEmails.joined(separator: "、"))。")
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
            throw Abort(.badRequest, reason: "没有可新增的成员。")
        }
        try IMGroupMemberLimitGuard.validateGroupMemberCount(existingMemberships.count + newUsers.count)

        return try await db.transaction { database in
            try await ConversationWriteFenceService.requireWritesAllowed(conversationID: conversationID, on: database)
            let revision = Date()
            let sequence = try await ConversationSequenceAllocator(db: database)
                .allocateNextServerSequence(conversationID: conversationID, updatedAt: revision)
            if let persistedConversation = try await Conversation.find(conversationID, on: database) {
                persistedConversation.membershipRevision = revision
                try await persistedConversation.update(on: database)
            }
            for user in newUsers {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: try user.requireID(),
                    visibleFromSequence: sequence
                ).create(on: database)
            }

            let addedUserIDs = try newUsers.map { try $0.requireID() }
            let recipientUserIDs = existingMemberships.map(\.$user.id) + addedUserIDs
            let event = try await ConversationSummaryRefreshPublisher(db: database).publish(
                .membershipAdded,
                conversationID: conversationID,
                actorUserID: requesterUserID,
                recipientUserIDs: recipientUserIDs,
                memberUserIDs: addedUserIDs,
                on: database
            )
            return commandReceipt(
                conversationID: conversationID,
                event: event,
                eventType: .membershipAdded,
                membershipRevision: revision
            )
        }
    }

    func removeMember(
        in conversationID: UUID,
        memberUserID: UUID,
        requesterUserID: UUID
    ) async throws -> ConversationMemberRemovalResult {
        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireGroup(
            conversation,
            reason: "私聊会话不支持新增成员。"
        )
        try governanceService.requireUserMutationAllowed(in: conversation)
        try ConversationMembershipGuard.requireNotSelf(
            targetUserID: memberUserID,
            requesterUserID: requesterUserID,
            reason: "不能通过移除成员操作移除自己，请使用退出会话。"
        )

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
            throw Abort(.badRequest, reason: "退出后会话成员不能少于 2 人。")
        }

        let remainingUserIDs = memberships.map(\.$user.id).filter { $0 != memberUserID }
        let receipt = try await db.transaction { database in
            try await ConversationWriteFenceService.requireWritesAllowed(conversationID: conversationID, on: database)
            let revision = Date()
            try await targetMembership.delete(on: database)

            if let persistedConversation = try await Conversation.find(conversationID, on: database) {
                persistedConversation.membershipRevision = revision
                try await persistedConversation.update(on: database)
            }

            let publisher = ConversationSummaryRefreshPublisher(db: database)
            try await publisher.publishConversationRemoved(
                conversationID: conversationID,
                actorUserID: requesterUserID,
                affectedUserID: memberUserID,
                on: database
            )
            let event = try await publisher.publish(
                .membershipRemoved,
                conversationID: conversationID,
                actorUserID: requesterUserID,
                recipientUserIDs: remainingUserIDs,
                memberUserIDs: [memberUserID],
                on: database
            )
            return commandReceipt(
                conversationID: conversationID,
                event: event,
                eventType: .membershipRemoved,
                membershipRevision: revision
            )
        }
        return ConversationMemberRemovalResult(receipt: receipt)
    }

    func updateMemberRole(
        in conversationID: UUID,
        memberUserID: UUID,
        role: IMConversationMemberRole,
        requesterUserID: UUID
    ) async throws -> ConversationCommandReceipt {
        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireGroup(
            conversation,
            reason: "私聊会话不支持成员角色管理。"
        )
        try governanceService.requireUserMutationAllowed(in: conversation)
        try ConversationMembershipGuard.requireNotSelf(
            targetUserID: memberUserID,
            requesterUserID: requesterUserID,
            reason: "不能直接修改自己的群角色。"
        )

        let requesterMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireOwner(
            requesterMembership.memberRoleEnum,
            reason: "只有群主可以调整成员角色。"
        )

        let targetMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: memberUserID
        )
        let previousRole = targetMembership.memberRoleEnum

        guard previousRole != role else {
            return noChangeReceipt(
                conversationID: conversationID,
                eventType: .membershipRoleUpdated,
                membershipRevision: conversation.membershipRevision
            )
        }

        return try await db.transaction { database in
            try await ConversationWriteFenceService.requireWritesAllowed(conversationID: conversationID, on: database)
            let revision = Date()
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

            if let persistedConversation = try await Conversation.find(conversationID, on: database) {
                persistedConversation.membershipRevision = revision
                try await persistedConversation.update(on: database)
            }

            let recipientUserIDs = try await memberUserIDs(in: conversationID, on: database)
            let event = try await ConversationSummaryRefreshPublisher(db: database).publish(
                .membershipRoleUpdated,
                conversationID: conversationID,
                actorUserID: requesterUserID,
                recipientUserIDs: recipientUserIDs,
                on: database
            )
            return commandReceipt(
                conversationID: conversationID,
                event: event,
                eventType: .membershipRoleUpdated,
                membershipRevision: revision
            )
        }
    }

    func leaveConversation(
        in conversationID: UUID,
        requesterUserID: UUID
    ) async throws -> ConversationCommandReceipt {
        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireGroup(
            conversation,
            reason: "私聊会话不支持主动退出。"
        )
        try governanceService.requireMembershipArchivalMutationAllowed(in: conversation)
        let requesterMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireNonOwner(
            requesterMembership.memberRoleEnum,
            reason: "群主退出前请先转让群主。"
        )

        let memberships = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .all()
        guard memberships.count - 1 >= 2 else {
            throw Abort(.badRequest, reason: "退出后会话成员不能少于 2 人。")
        }

        guard let membership = memberships.first(where: { $0.$user.id == requesterUserID }) else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        let remainingUserIDs = memberships.map(\.$user.id).filter { $0 != requesterUserID }
        return try await db.transaction { database in
            try await ConversationWriteFenceService.requireWritesAllowed(conversationID: conversationID, on: database)
            let revision = Date()
            try await membership.delete(on: database)
            if let persistedConversation = try await Conversation.find(conversationID, on: database) {
                persistedConversation.membershipRevision = revision
                try await persistedConversation.update(on: database)
            }
            let publisher = ConversationSummaryRefreshPublisher(db: database)
            try await publisher.publishConversationRemoved(
                conversationID: conversationID,
                actorUserID: requesterUserID,
                affectedUserID: requesterUserID,
                on: database
            )
            let event = try await publisher.publish(
                .membershipRemoved,
                conversationID: conversationID,
                actorUserID: requesterUserID,
                recipientUserIDs: remainingUserIDs,
                memberUserIDs: [requesterUserID],
                on: database
            )
            return commandReceipt(
                conversationID: conversationID,
                event: event,
                eventType: .membershipRemoved,
                membershipRevision: revision
            )
        }
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

    private func memberUserIDs(
        in conversationID: UUID,
        on database: any Database
    ) async throws -> [UUID] {
        try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .all()
            .map(\.$user.id)
    }

    private func commandReceipt(
        conversationID: UUID,
        event: ConversationDomainEvent,
        eventType: ConversationDomainEventType,
        membershipRevision: Date?
    ) -> ConversationCommandReceipt {
        ConversationCommandReceipt(
            conversationID: conversationID,
            eventID: event.id,
            eventType: eventType,
            acceptedAt: event.createdAt,
            membershipRevision: membershipRevision,
            didMutate: true
        )
    }

    private func noChangeReceipt(
        conversationID: UUID,
        eventType: ConversationDomainEventType,
        membershipRevision: Date?
    ) -> ConversationCommandReceipt {
        ConversationCommandReceipt(
            conversationID: conversationID,
            eventID: nil,
            eventType: eventType,
            acceptedAt: Date(),
            membershipRevision: membershipRevision,
            didMutate: false
        )
    }
}
