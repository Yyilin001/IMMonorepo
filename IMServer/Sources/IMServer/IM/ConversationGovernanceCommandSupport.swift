import Fluent
import Vapor

struct ConversationGovernanceCommandSupport {
    let db: any Database
    let userDirectoryDB: any Database

    init(db: any Database, userDirectoryDB: (any Database)? = nil) {
        self.db = db
        self.userDirectoryDB = userDirectoryDB ?? db
    }

    private var userLookup: ConversationUserLookupSupport { ConversationUserLookupSupport(db: userDirectoryDB) }
    private var membershipService: ConversationMembershipService {
        ConversationMembershipService(db: db, userDirectoryDB: userDirectoryDB)
    }
    private var governanceService: ConversationGovernanceService { ConversationGovernanceService() }
    func updateConversationTitle(
        in conversationID: UUID,
        title: String,
        requesterUserID: UUID
    ) async throws -> ConversationCommandReceipt {
        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireGroup(
            conversation,
            reason: "私聊会话不支持修改标题。"
        )
        try governanceService.requireUserMutationAllowed(in: conversation)
        let requesterMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireOwnerOrAdmin(
            requesterMembership.memberRoleEnum,
            reason: "只有群主或管理员可以修改群名称。"
        )

        guard let normalizedTitle = ConversationCommandNormalizationSupport.normalizedConversationTitle(title) else {
            throw Abort(.badRequest, reason: "群聊名称不能为空。")
        }
        if conversation.title == normalizedTitle {
            return noChangeReceipt(
                conversationID: conversationID,
                eventType: .metadataUpdated,
                membershipRevision: conversation.membershipRevision
            )
        }

        return try await db.transaction { database in
            try await ConversationWriteFenceService.requireWritesAllowed(conversationID: conversationID, on: database)
            guard let persistedConversation = try await Conversation.find(conversationID, on: database) else {
                throw Abort(.notFound, reason: "会话不存在。")
            }

            persistedConversation.title = normalizedTitle
            try await persistedConversation.update(on: database)

            let event = try await ConversationSummaryRefreshPublisher(db: database).publish(
                .metadataUpdated,
                conversationID: conversationID,
                actorUserID: requesterUserID,
                recipientUserIDs: try await memberUserIDs(in: conversationID, on: database),
                on: database
            )
            return commandReceipt(
                conversationID: conversationID,
                event: event,
                eventType: .metadataUpdated,
                membershipRevision: persistedConversation.membershipRevision
            )
        }
    }

    func updateConversationMetadata(
        in conversationID: UUID,
        title: String?,
        notice: String?,
        avatarPreset: IMConversationAvatarPreset?,
        muteAll: Bool?,
        requesterUserID: UUID
    ) async throws -> ConversationCommandReceipt {
        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireGroup(
            conversation,
            reason: "私聊会话不支持修改群资料。"
        )
        try governanceService.requireUserMutationAllowed(in: conversation)
        let requesterMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireOwnerOrAdmin(
            requesterMembership.memberRoleEnum,
            reason: "只有群主或管理员可以修改群资料。"
        )

        let changeSet = try governanceService.makeMetadataChangeSet(
            title: title,
            notice: notice,
            avatarPreset: avatarPreset,
            muteAll: muteAll
        )

        return try await db.transaction { database in
            try await ConversationWriteFenceService.requireWritesAllowed(conversationID: conversationID, on: database)
            guard let persistedConversation = try await Conversation.find(conversationID, on: database) else {
                throw Abort(.notFound, reason: "会话不存在。")
            }

            let didUpdate = governanceService.apply(changeSet, to: persistedConversation)
            if !didUpdate {
                return noChangeReceipt(
                    conversationID: conversationID,
                    eventType: .metadataUpdated,
                    membershipRevision: persistedConversation.membershipRevision
                )
            }

            try await persistedConversation.update(on: database)

            let event = try await ConversationSummaryRefreshPublisher(db: database).publish(
                .metadataUpdated,
                conversationID: conversationID,
                actorUserID: requesterUserID,
                recipientUserIDs: try await memberUserIDs(in: conversationID, on: database),
                on: database
            )
            return commandReceipt(
                conversationID: conversationID,
                event: event,
                eventType: .metadataUpdated,
                membershipRevision: persistedConversation.membershipRevision
            )
        }
    }

    func updateMemberNickname(
        in conversationID: UUID,
        requesterUserID: UUID,
        memberNickname: String?
    ) async throws -> ConversationCommandReceipt {
        let conversation = try await requireConversationAndMembership(conversationID: conversationID, userID: requesterUserID)
        try governanceService.requireUserMutationAllowed(in: conversation)
        let normalized = memberNickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedNickname = normalized?.isEmpty == false ? normalized : nil

        return try await db.transaction { database in
            try await ConversationWriteFenceService.requireWritesAllowed(conversationID: conversationID, on: database)
            let membership = try await ConversationMembershipService(
                db: database,
                userDirectoryDB: userDirectoryDB
            ).requireMembershipRecord(
                conversationID: conversationID,
                userID: requesterUserID,
                on: database
            )
            membership.memberNickname = storedNickname
            try await membership.update(on: database)
            let event = try await ConversationSummaryRefreshPublisher(db: database).publish(
                .metadataUpdated,
                conversationID: conversationID,
                actorUserID: requesterUserID,
                recipientUserIDs: try await memberUserIDs(in: conversationID, on: database),
                on: database
            )
            return commandReceipt(
                conversationID: conversationID,
                event: event,
                eventType: .metadataUpdated,
                membershipRevision: nil
            )
        }
    }

    func updateConversationPreferences(
        in conversationID: UUID,
        isPinned: Bool?,
        isMuted: Bool?,
        requesterUserID: UUID
    ) async throws -> ConversationCommandReceipt {
        _ = try await requireConversationAndMembership(conversationID: conversationID, userID: requesterUserID)

        return try await db.transaction { database in
            try await ConversationWriteFenceService.requireWritesAllowed(conversationID: conversationID, on: database)
            let membership = try await ConversationMembershipService(
                db: database,
                userDirectoryDB: userDirectoryDB
            ).requireMembershipRecord(
                conversationID: conversationID,
                userID: requesterUserID,
                on: database
            )

            var didUpdate = false
            if let isPinned, membership.isPinned != isPinned {
                membership.isPinned = isPinned
                membership.pinnedAt = isPinned ? Date() : nil
                didUpdate = true
            }
            if let isMuted, membership.isMuted != isMuted {
                membership.isMuted = isMuted
                didUpdate = true
            }

            guard didUpdate else {
                return noChangeReceipt(
                    conversationID: conversationID,
                    eventType: .conversationSettingsChanged,
                    membershipRevision: nil
                )
            }

            try await membership.update(on: database)
            let event = try await ConversationSummaryRefreshPublisher(db: database).publish(
                .conversationSettingsChanged,
                conversationID: conversationID,
                actorUserID: requesterUserID,
                recipientUserIDs: [requesterUserID],
                on: database
            )
            return commandReceipt(
                conversationID: conversationID,
                event: event,
                eventType: .conversationSettingsChanged,
                membershipRevision: nil
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
