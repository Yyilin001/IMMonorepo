import Vapor

extension IMConversationController {
    func startAIMessageStream(req: Request) async throws -> IMMessageStreamResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let body = try req.content.decode(IMAIMessageStreamStartRequest.self)
        return try await IMMessageStreamingService(app: req.application).startAIMessageStream(
            conversationID: conversationID,
            userID: try user.requireID(),
            prompt: body.prompt
        )
    }

    func cancelMessageStream(req: Request) async throws -> IMMessageStreamResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let messageID = try streamMessageID(from: req)
        return try await IMMessageStreamingService(app: req.application).cancelMessageStream(
            conversationID: conversationID,
            messageID: messageID,
            userID: try user.requireID()
        )
    }

    func messageStreamSnapshot(req: Request) async throws -> IMMessageStreamResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let messageID = try streamMessageID(from: req)
        return try await IMMessageStreamingService(app: req.application).snapshot(
            conversationID: conversationID,
            messageID: messageID,
            userID: try user.requireID()
        )
    }

    private func streamMessageID(from req: Request) throws -> UUID {
        guard let rawMessageID = req.parameters.get("messageID"),
              let messageID = UUID(uuidString: rawMessageID)
        else {
            throw Abort(.badRequest, reason: "消息 ID 无效。")
        }
        return messageID
    }
}
