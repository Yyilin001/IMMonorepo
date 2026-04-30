import Fluent
import Vapor

struct ConversationReadStateCommandSupport {
    let db: any Database

    private var readAdvanceSupport: ConversationReadAdvanceSupport {
        ConversationReadAdvanceSupport(db: db)
    }

    private var refreshPublisher: ConversationSummaryRefreshPublisher {
        ConversationSummaryRefreshPublisher(db: db)
    }

    func markConversationRead(
        in conversationID: UUID,
        for userID: UUID,
        readSequence requestedReadSequence: Int
    ) async throws -> IMConversationReadResponse {
        guard requestedReadSequence >= 0 else {
            throw Abort(.badRequest, reason: "已读游标无效。")
        }

        try await readAdvanceSupport.advanceConversationRead(
            conversationID: conversationID,
            userID: userID,
            requestedReadSequence: requestedReadSequence
        )

        let readState = try await readAdvanceSupport.conversationReadState(
            conversationID: conversationID,
            userID: userID
        )
        try await refreshPublisher.publish(
            .readAdvanced,
            conversationID: conversationID,
            recipientUserIDs: [userID]
        )
        return IMConversationReadResponse(
            conversationID: conversationID,
            lastReadSequence: readState.lastReadSequence,
            unreadCount: readState.unreadCount
        )
    }
}
