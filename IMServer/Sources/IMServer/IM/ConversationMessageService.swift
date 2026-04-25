import Fluent
import Vapor

struct ConversationMessageService {
    private enum RecallPolicy {
        static let window: TimeInterval = 2 * 60
    }

    let db: any Database

    func recallMessage(
        in conversationID: UUID,
        messageID: UUID,
        requesterUserID: UUID,
        on database: any Database
    ) async throws -> ConversationMessage {
        guard let message = try await ConversationMessage.query(on: database)
            .filter(\.$id == messageID)
            .filter(\.$conversation.$id == conversationID)
            .first()
        else {
            throw Abort(.notFound, reason: "消息不存在。")
        }

        guard message.$sender.id == requesterUserID else {
            throw Abort(.forbidden, reason: "只能撤回自己发送的消息。")
        }

        let messageCreatedAt = message.createdAt ?? .distantPast
        guard Date().timeIntervalSince(messageCreatedAt) <= RecallPolicy.window else {
            throw Abort(.badRequest, reason: "消息发送超过 2 分钟后不能撤回。")
        }

        switch try message.decodedContent() {
        case .text, .reply, .image, .audio, .file:
            try message.replaceContent(.recalled)
            try await message.update(on: database)
            return message
        case .recalled:
            throw Abort(.badRequest, reason: "该消息已经撤回。")
        case .system:
            throw Abort(.badRequest, reason: "当前消息不支持撤回。")
        }
    }

    func makePreview(from message: ConversationMessage) throws -> IMMessagePreviewResponse {
        IMMessagePreviewResponse(
            id: try message.requireID(),
            senderUserID: message.$sender.id,
            serverSequence: message.serverSequence,
            content: try message.decodedContent(),
            createdAt: message.createdAt
        )
    }

    func messageResponse(
        from message: ConversationMessage,
        conversationID: UUID
    ) throws -> IMMessageResponse {
        IMMessageResponse(
            id: try message.requireID(),
            conversationID: conversationID,
            senderUserID: message.$sender.id,
            clientMessageID: message.clientMessageID,
            serverSequence: message.serverSequence,
            content: try message.decodedContent(),
            createdAt: message.createdAt
        )
    }
}
