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
        let recordID = ConversationUserSummary.recordID(ownerUserID: userID, conversationID: conversationID)
        if let summary = try await ConversationUserSummary.find(recordID, on: db) {
            guard !summary.isRemoved else {
                throw Abort(.notFound, reason: "会话不存在。")
            }
            if let conversation = try await Conversation.find(conversationID, on: db),
               let conversationRevision = conversation.membershipRevision,
               let summaryRevision = summary.membershipRevision,
               conversationRevision == summaryRevision,
               summary.memberUserIDs.contains(userID)
            {
                return makeConversationResponse(from: summary)
            }
        }

        let response = try await conversationResponse(
            conversationID: conversationID,
            for: userID,
            on: db
        )
        try await summaryProjectionService.refreshConversationSummaries(
            conversationID: conversationID,
            recipientUserIDs: [userID],
            on: db,
            writeChangeLog: true
        )
        return response
    }

    func listConversations(
        for userID: UUID,
        cursor: String?,
        limit: Int?,
        kind: String? = nil
    ) async throws -> IMConversationPageResponse {
        try await summaryProjectionService.listConversations(
            for: userID,
            cursor: cursor,
            limit: limit,
            kind: kind
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

    func listMemberPage(
        in conversationID: UUID,
        for userID: UUID,
        cursor: String?,
        limit: Int?,
        query: String?
    ) async throws -> IMConversationMemberPageResponse {
        try await membershipService.listMemberPageResponses(
            in: conversationID,
            for: userID,
            cursor: cursor,
            limit: limit,
            query: query
        )
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

        let lastMessageRows = try await ConversationMessage.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$serverSequence >= membership.visibleFromSequence)
            .sort(\.$serverSequence, .descending)
            .limit(50)
            .all()
        let visibleLastMessageRows = try await IMCommonFeatureService(db: database)
            .filterVisible(lastMessageRows, for: userID)
        let lastVisibleMessage = visibleLastMessageRows.first
        let lastMessage = try lastVisibleMessage.map(messageService.makePreview)
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
            muteAll: conversation.muteAll,
            memberCount: memberUserIDs.count,
            memberUserIDs: memberUserIDs,
            lastMessage: lastMessage,
            lastReadSequence: UInt64(readState.lastReadSequence),
            unreadCount: readState.unreadCount,
            isPinned: preferences.isPinned,
            pinnedAt: preferences.pinnedAt,
            isMuted: preferences.isMuted,
            createdAt: conversation.createdAt,
            updatedAt: lastMessage?.createdAt ?? conversation.updatedAt
        )
    }

    private func makeConversationResponse(from row: ConversationUserSummary) -> IMConversationResponse {
        IMConversationResponse(
            id: row.conversationID,
            title: row.title,
            kind: row.kind,
            directMessagingState: row.directMessagingState,
            directPeer: row.directPeerUserID.map { directPeerUserID in
                IMDirectPeerResponse(
                    id: directPeerUserID,
                    email: row.directPeerEmail ?? "",
                    displayName: row.directPeerDisplayName,
                    avatarPreset: row.directPeerAvatarPresetEnum
                )
            },
            notice: row.notice,
            avatarPreset: row.avatarPresetEnum,
            muteAll: row.muteAll,
            memberCount: row.memberCount,
            memberUserIDs: row.memberUserIDs.sorted { $0.uuidString < $1.uuidString },
            lastMessage: row.lastMessage,
            lastReadSequence: UInt64(row.lastReadSequence),
            unreadCount: row.unreadCount,
            isPinned: row.isPinned,
            pinnedAt: row.pinnedAt,
            isMuted: row.isMuted,
            createdAt: nil,
            updatedAt: row.lastActivityAt
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

    func listTimeline(
        in conversationID: UUID,
        for userID: UUID,
        beforeSequence: Int? = nil,
        limit requestedLimit: Int? = nil
    ) async throws -> IMTimelinePageResponse {
        let membership = try await membershipService.requireMembershipRecord(
            conversationID: conversationID,
            userID: userID
        )
        let limit = try ConversationReadPaginationSupport.normalizedHistoryLimit(requestedLimit)
        let upperBound = beforeSequence ?? Int.max
        if upperBound <= 0 {
            throw Abort(.badRequest, reason: "分页游标无效。")
        }

        let messages = try await ConversationMessage.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$serverSequence >= membership.visibleFromSequence)
            .filter(\.$timelineSequence < upperBound)
            .sort(\.$timelineSequence, .descending)
            .limit(limit + 1)
            .all()
        let visibleMessages = try await IMCommonFeatureService(db: db).filterVisible(messages, for: userID)
        let notices = try visibleNotices(
            try await ConversationTimelineNotice.query(on: db)
            .filter(\.$conversationID == conversationID)
            .filter(\.$timelineSequence < upperBound)
            .sort(\.$timelineSequence, .descending)
            .limit(limit + 1)
            .all(),
            for: userID
        )

        var items = try makeTimelineItems(messages: visibleMessages, notices: notices, conversationID: conversationID)
            .sorted { lhs, rhs in
                if lhs.timelineSequence == rhs.timelineSequence {
                    return lhs.type.rawValue < rhs.type.rawValue
                }
                return lhs.timelineSequence > rhs.timelineSequence
            }
        let hasMore = items.count > limit
        if hasMore {
            items = Array(items.prefix(limit))
        }
        items.reverse()
        return IMTimelinePageResponse(
            items: items,
            hasMore: hasMore,
            nextAfterSequence: items.last?.timelineSequence
        )
    }

    func listTimelineSince(
        in conversationID: UUID,
        for userID: UUID,
        afterSequence: Int,
        limit requestedLimit: Int? = nil
    ) async throws -> IMTimelinePageResponse {
        let membership = try await membershipService.requireMembershipRecord(
            conversationID: conversationID,
            userID: userID
        )
        guard afterSequence >= 0 else {
            throw Abort(.badRequest, reason: "增量游标无效。")
        }
        let limit = try ConversationReadPaginationSupport.normalizedIncrementalLimit(requestedLimit)
        let messages = try await ConversationMessage.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$serverSequence >= membership.visibleFromSequence)
            .filter(\.$timelineSequence > afterSequence)
            .sort(\.$timelineSequence, .ascending)
            .limit(limit + 1)
            .all()
        let visibleMessages = try await IMCommonFeatureService(db: db).filterVisible(messages, for: userID)
        let notices = try visibleNotices(
            try await ConversationTimelineNotice.query(on: db)
            .filter(\.$conversationID == conversationID)
            .filter(\.$timelineSequence > afterSequence)
            .sort(\.$timelineSequence, .ascending)
            .limit(limit + 1)
            .all(),
            for: userID
        )

        var items = try makeTimelineItems(messages: visibleMessages, notices: notices, conversationID: conversationID)
            .sorted { lhs, rhs in
                if lhs.timelineSequence == rhs.timelineSequence {
                    return lhs.type.rawValue < rhs.type.rawValue
                }
                return lhs.timelineSequence < rhs.timelineSequence
            }
        let hasMore = items.count > limit
        if hasMore {
            items = Array(items.prefix(limit))
        }
        let nextAfterSequence: UInt64
        if let lastItem = items.last {
            nextAfterSequence = lastItem.timelineSequence
        } else {
            nextAfterSequence = UInt64(afterSequence)
        }
        return IMTimelinePageResponse(
            items: items,
            hasMore: hasMore,
            nextAfterSequence: nextAfterSequence
        )
    }

    private func makeTimelineItems(
        messages: [ConversationMessage],
        notices: [ConversationTimelineNotice],
        conversationID: UUID
    ) throws -> [IMTimelineItemResponse] {
        let messageItems = try messages.map { message in
            let response = try messageService.messageResponse(from: message, conversationID: conversationID)
            return IMTimelineItemResponse(
                type: .message,
                timelineSequence: response.timelineSequence,
                message: response,
                notice: nil
            )
        }
        let noticeItems = try notices.map { notice -> IMTimelineItemResponse in
            guard let eventID = notice.eventID else {
                throw Abort(.internalServerError, reason: "Timeline notice 缺少 event_id。")
            }
            return IMTimelineItemResponse(
                type: .notice,
                timelineSequence: try imPositiveUInt64Sequence(notice.timelineSequence, field: "timeline_sequence"),
                message: nil,
                notice: IMTimelineNoticeResponse(
                    id: eventID,
                    conversationID: notice.conversationID,
                    timelineSequence: try imPositiveUInt64Sequence(notice.timelineSequence, field: "timeline_sequence"),
                    eventType: notice.eventType,
                    actorUserID: notice.actorUserID,
                    targetUserIDs: try notice.targetUserIDs,
                    noticeKind: notice.noticeKind,
                    params: try notice.params,
                    fallbackText: notice.fallbackText,
                    createdAt: notice.createdAt
                )
            )
        }
        return messageItems + noticeItems
    }

    private func visibleNotices(
        _ notices: [ConversationTimelineNotice],
        for userID: UUID
    ) throws -> [ConversationTimelineNotice] {
        try notices.filter { notice in
            try notice.targetUserIDs.contains(userID)
        }
    }
}

struct ConversationSearchReadSupport {
    let db: any Database

    private var membershipService: ConversationMembershipService {
        ConversationMembershipService(db: db)
    }

    private var searchService: ConversationSearchService {
        ConversationSearchService(db: db)
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
        let page = try await searchService.searchMessages(
            in: conversationID,
            membership: membership,
            query: rawQuery,
            cursor: rawCursor,
            limit: requestedLimit
        )
        var visibleItems: [IMConversationMessageSearchHitResponse] = []
        let featureService = IMCommonFeatureService(db: db)
        for item in page.items {
            guard let message = try await ConversationMessage.find(item.messageID, on: db),
                  try await !featureService.isHidden(message: message, for: userID)
            else {
                continue
            }
            visibleItems.append(item)
        }
        return IMConversationMessageSearchPageResponse(
            items: visibleItems,
            nextCursor: page.nextCursor,
            hasMore: page.hasMore
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
        limit: Int?,
        kind: String? = nil
    ) async throws -> IMConversationPageResponse {
        try await summaryReadSupport.listConversations(
            for: userID,
            cursor: cursor,
            limit: limit,
            kind: kind
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

    func listMemberPage(
        in conversationID: UUID,
        for userID: UUID,
        cursor: String?,
        limit: Int?,
        query: String?
    ) async throws -> IMConversationMemberPageResponse {
        try await summaryReadSupport.listMemberPage(
            in: conversationID,
            for: userID,
            cursor: cursor,
            limit: limit,
            query: query
        )
    }

    func listTimeline(
        in conversationID: UUID,
        for userID: UUID,
        beforeSequence: Int? = nil,
        limit requestedLimit: Int? = nil
    ) async throws -> IMTimelinePageResponse {
        try await timelineReadSupport.listTimeline(
            in: conversationID,
            for: userID,
            beforeSequence: beforeSequence,
            limit: requestedLimit
        )
    }

    func listTimelineSince(
        in conversationID: UUID,
        for userID: UUID,
        afterSequence: Int,
        limit requestedLimit: Int? = nil
    ) async throws -> IMTimelinePageResponse {
        try await timelineReadSupport.listTimelineSince(
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
