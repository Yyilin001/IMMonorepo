import Fluent
import Foundation
import Kafka
import NIOCore
import Vapor

struct QueryReadModelFacade {
    private let strongReadService: ConversationStrongReadService
    private let timelineReadService: ConversationEventualReadService
    private let summaryStore: any SummaryReadModelStore
    private let searchAdapter: any ConversationSearchAdapter

    init(app: Application) {
        self.strongReadService = ConversationStrongReadService(app: app)
        self.timelineReadService = ConversationEventualReadService(app: app)
        self.summaryStore = app.summaryReadModelStore
        self.searchAdapter = app.conversationSearchAdapter
    }

    func latestMessage(in conversationID: UUID) async throws -> IMMessageResponse? {
        try await strongReadService.latestMessage(in: conversationID)
    }

    func conversationSummary(
        conversationID: UUID,
        for userID: UUID
    ) async throws -> IMConversationResponse {
        try await summaryStore.conversationSummary(conversationID: conversationID, for: userID)
    }

    func listConversations(
        for userID: UUID,
        cursor: String?,
        limit: Int?,
        kind: String? = nil
    ) async throws -> IMConversationPageResponse {
        try await summaryStore.listConversations(for: userID, cursor: cursor, limit: limit, kind: kind)
    }

    func listConversationChanges(
        for userID: UUID,
        afterToken: String,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationChangesResponse {
        try await summaryStore.listConversationChanges(
            for: userID,
            afterToken: afterToken,
            cursor: cursor,
            limit: limit
        )
    }

    func listMembers(in conversationID: UUID, for userID: UUID) async throws -> [IMConversationMemberResponse] {
        try await timelineReadService.listMembers(in: conversationID, for: userID)
    }

    func listMemberPage(
        in conversationID: UUID,
        for userID: UUID,
        cursor: String?,
        limit: Int?,
        query: String?
    ) async throws -> IMConversationMemberPageResponse {
        try await timelineReadService.listMemberPage(
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
        beforeSequence: Int?,
        limit: Int?
    ) async throws -> IMTimelinePageResponse {
        try await timelineReadService.listTimeline(
            in: conversationID,
            for: userID,
            beforeSequence: beforeSequence,
            limit: limit
        )
    }

    func listTimelineSince(
        in conversationID: UUID,
        for userID: UUID,
        afterSequence: Int,
        limit: Int?
    ) async throws -> IMTimelinePageResponse {
        try await timelineReadService.listTimelineSince(
            in: conversationID,
            for: userID,
            afterSequence: afterSequence,
            limit: limit
        )
    }

    func searchMessages(
        in conversationID: UUID,
        for userID: UUID,
        query: String,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationMessageSearchPageResponse {
        try await searchAdapter.searchMessages(
            in: conversationID,
            for: userID,
            query: query,
            cursor: cursor,
            limit: limit
        )
    }
}
