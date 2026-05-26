import Fluent
import Vapor

struct ConversationGovernanceCommandSupport {
    let db: any Database

    private var userLookup: ConversationUserLookupSupport { ConversationUserLookupSupport(db: db) }
    private var membershipService: ConversationMembershipService { ConversationMembershipService(db: db) }
    private var governanceService: ConversationGovernanceService { ConversationGovernanceService() }
    private var summaryProjectionService: IMConversationSummaryProjectionService { IMConversationSummaryProjectionService(db: db) }
    private var readSupport: ConversationReadSupport { ConversationReadSupport(db: db) }
    private var summaryReadSupport: ConversationSummaryReadSupport { ConversationSummaryReadSupport(db: db) }
    private var refreshPublisher: ConversationSummaryRefreshPublisher { ConversationSummaryRefreshPublisher(db: db) }

    func updateConversationTitle(
        in conversationID: UUID,
        title: String,
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireGroup(
            conversation,
            reason: "私聊会话不支持修改标题。"
        )
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
            return try await readSupport.conversationSummary(
                conversationID: conversationID,
                for: requesterUserID
            )
        }

        let response = try await db.transaction { database in
            guard let persistedConversation = try await Conversation.find(conversationID, on: database) else {
                throw Abort(.notFound, reason: "会话不存在。")
            }

            persistedConversation.title = normalizedTitle
            try await persistedConversation.update(on: database)

            return try await ConversationSummaryReadSupport(db: database).conversationSummary(
                conversationID: conversationID,
                for: requesterUserID
            )
        }

        try await refreshPublisher.publish(
            .metadataUpdated,
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
        muteAll: Bool?,
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireGroup(
            conversation,
            reason: "私聊会话不支持修改群资料。"
        )
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

        let response = try await db.transaction { database in
            guard let persistedConversation = try await Conversation.find(conversationID, on: database) else {
                throw Abort(.notFound, reason: "会话不存在。")
            }

            let didUpdate = governanceService.apply(changeSet, to: persistedConversation)
            if !didUpdate {
                return try await ConversationSummaryReadSupport(db: database).conversationSummary(
                    conversationID: conversationID,
                    for: requesterUserID
                )
            }

            try await persistedConversation.update(on: database)

            return try await ConversationSummaryReadSupport(db: database).conversationSummary(
                conversationID: conversationID,
                for: requesterUserID
            )
        }

        try await refreshPublisher.publish(
            .metadataUpdated,
            conversationID: conversationID,
            recipientUserIDs: response.memberUserIDs
        )
        return response
    }

    func updateMemberNickname(
        in conversationID: UUID,
        requesterUserID: UUID,
        memberNickname: String?
    ) async throws -> IMConversationResponse {
        _ = try await requireConversationAndMembership(conversationID: conversationID, userID: requesterUserID)
        let normalized = memberNickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedNickname = normalized?.isEmpty == false ? normalized : nil

        let response = try await db.transaction { database in
            let membership = try await ConversationMembershipService(db: database).requireMembershipRecord(
                conversationID: conversationID,
                userID: requesterUserID,
                on: database
            )
            membership.memberNickname = storedNickname
            try await membership.update(on: database)
            return try await ConversationSummaryReadSupport(db: database).conversationSummary(
                conversationID: conversationID,
                for: requesterUserID
            )
        }

        try await refreshPublisher.publish(
            .metadataUpdated,
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

        let summary: ConversationUserSummary
        if let existingSummary = try await ConversationUserSummary.find(recordID, on: db) {
            summary = existingSummary
        } else {
            try await summaryProjectionService.refreshConversationSummaries(
                conversationID: conversationID,
                recipientUserIDs: [requesterUserID]
            )
            guard let refreshedSummary = try await ConversationUserSummary.find(recordID, on: db) else {
                throw Abort(.notFound, reason: "会话不存在。")
            }
            summary = refreshedSummary
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

        return try await readSupport.conversationSummary(
            conversationID: conversationID,
            for: requesterUserID
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
}
