import Fluent
import Vapor

struct AIMessageStreamReadStore {
    let app: Application

    func snapshot(
        conversationID: UUID,
        messageID: UUID,
        userID: UUID
    ) async throws -> IMMessageStreamResponse {
        let db = try await app.conversationShardRouter.commandDatabase(forConversationID: conversationID)
        _ = try await ConversationMembershipService(db: db).requireMembershipRecord(
            conversationID: conversationID,
            userID: userID
        )
        guard let message = try await ConversationMessage.find(messageID, on: db),
              message.$conversation.id == conversationID
        else {
            throw Abort(.notFound, reason: "Message not found.")
        }

        let response = try ConversationMessageService(db: db).messageResponse(
            from: message,
            conversationID: conversationID
        )
        guard let streamState = response.derivedState.streamState else {
            throw Abort(.notFound, reason: "Message stream not found.")
        }
        return AIMessageStreamMutationBuilder.streamResponse(
            message: response,
            streamID: streamState.streamID,
            messageID: messageID,
            conversationID: conversationID,
            chunkIndex: streamState.lastChunkIndex,
            partialTextLength: streamState.partialText.count,
            state: streamState.state
        )
    }
}
