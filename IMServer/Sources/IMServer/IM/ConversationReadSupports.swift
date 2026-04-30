import Fluent
import SQLKit
import Vapor

struct ConversationSummaryReadSupport {
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

    private var summaryProjectionService: IMConversationSummaryProjectionService {
        IMConversationSummaryProjectionService(db: db)
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

    func listConversations(
        for userID: UUID,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationPageResponse {
        try await summaryProjectionService.listConversations(
            for: userID,
            cursor: cursor,
            limit: limit
        )
    }

    func listConversationChanges(
        for userID: UUID,
        afterToken: String,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationChangesResponse {
        try await summaryProjectionService.listConversationChanges(
            for: userID,
            afterToken: afterToken,
            cursor: cursor,
            limit: limit
        )
    }

    func listMembers(
        in conversationID: UUID,
        for userID: UUID
    ) async throws -> [IMConversationMemberResponse] {
        try await membershipService.listMemberResponses(in: conversationID, for: userID)
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
            directMessagingState: ConversationPresentationSupport.directMessagingState(for: conversation),
            directPeer: ConversationPresentationSupport.directPeer(from: memberships, currentUserID: userID),
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
}

struct ConversationTimelineReadSupport {
    let db: any Database

    private var membershipService: ConversationMembershipService {
        ConversationMembershipService(db: db)
    }

    private var messageService: ConversationMessageService {
        ConversationMessageService(db: db)
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
        let limit = try ConversationReadPaginationSupport.normalizedHistoryLimit(requestedLimit)

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

        let limit = try ConversationReadPaginationSupport.normalizedIncrementalLimit(requestedLimit)
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
}

struct ConversationSearchReadSupport {
    let db: any Database

    private var membershipService: ConversationMembershipService {
        ConversationMembershipService(db: db)
    }

    private var searchService: ConversationSearchService {
        let allowLegacyFallback: Bool
        if let sql = db as? any SQLDatabase {
            allowLegacyFallback = sql.dialect.name == "sqlite"
        } else {
            allowLegacyFallback = true
        }
        return ConversationSearchService(db: db, allowLegacyFallback: allowLegacyFallback)
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
}

struct ConversationReadSupport {
    let db: any Database

    private var summaryReadSupport: ConversationSummaryReadSupport {
        ConversationSummaryReadSupport(db: db)
    }

    private var timelineReadSupport: ConversationTimelineReadSupport {
        ConversationTimelineReadSupport(db: db)
    }

    private var searchReadSupport: ConversationSearchReadSupport {
        ConversationSearchReadSupport(db: db)
    }

    func latestMessage(in conversationID: UUID) async throws -> IMMessageResponse? {
        try await timelineReadSupport.latestMessage(in: conversationID)
    }

    func conversationSummary(
        conversationID: UUID,
        for userID: UUID
    ) async throws -> IMConversationResponse {
        try await summaryReadSupport.conversationSummary(
            conversationID: conversationID,
            for: userID
        )
    }

    func listConversations(
        for userID: UUID,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationPageResponse {
        try await summaryReadSupport.listConversations(
            for: userID,
            cursor: cursor,
            limit: limit
        )
    }

    func listConversationChanges(
        for userID: UUID,
        afterToken: String,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationChangesResponse {
        try await summaryReadSupport.listConversationChanges(
            for: userID,
            afterToken: afterToken,
            cursor: cursor,
            limit: limit
        )
    }

    func listMembers(
        in conversationID: UUID,
        for userID: UUID
    ) async throws -> [IMConversationMemberResponse] {
        try await summaryReadSupport.listMembers(in: conversationID, for: userID)
    }

    func listMessages(
        in conversationID: UUID,
        for userID: UUID,
        beforeSequence: Int? = nil,
        limit requestedLimit: Int? = nil
    ) async throws -> [IMMessageResponse] {
        try await timelineReadSupport.listMessages(
            in: conversationID,
            for: userID,
            beforeSequence: beforeSequence,
            limit: requestedLimit
        )
    }

    func listMessagesSince(
        in conversationID: UUID,
        for userID: UUID,
        afterSequence: Int,
        limit requestedLimit: Int? = nil
    ) async throws -> IMMessageSinceResponse {
        try await timelineReadSupport.listMessagesSince(
            in: conversationID,
            for: userID,
            afterSequence: afterSequence,
            limit: requestedLimit
        )
    }

    func searchMessages(
        in conversationID: UUID,
        for userID: UUID,
        query rawQuery: String,
        cursor rawCursor: String?,
        limit requestedLimit: Int? = nil
    ) async throws -> IMConversationMessageSearchPageResponse {
        try await searchReadSupport.searchMessages(
            in: conversationID,
            for: userID,
            query: rawQuery,
            cursor: rawCursor,
            limit: requestedLimit
        )
    }
}
