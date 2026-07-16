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

        let readState = try await db.transaction { database in
            try await ConversationWriteFenceService.requireWritesAllowed(conversationID: conversationID, on: database)
            try await ConversationReadStateService(db: database).advanceConversationRead(
                conversationID: conversationID,
                userID: userID,
                requestedReadSequence: requestedReadSequence,
                on: database
            )
            let readState = try await ConversationReadStateService(db: database).conversationReadState(
                conversationID: conversationID,
                userID: userID,
                on: database
            )
            try await ConversationSummaryRefreshPublisher(db: database).publish(
                .readAdvanced,
                conversationID: conversationID,
                actorUserID: userID,
                recipientUserIDs: [userID],
                on: database
            )
            return readState
        }
        return IMConversationReadResponse(
            conversationID: conversationID,
            lastReadSequence: UInt64(readState.lastReadSequence),
            unreadCount: readState.unreadCount
        )
    }
}
