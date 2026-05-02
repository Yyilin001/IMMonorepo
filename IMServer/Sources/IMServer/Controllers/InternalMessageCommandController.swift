import Vapor

struct InternalMessageCommandController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let internalRoutes = routes.grouped("internal", "im")
        internalRoutes.grouped("messages")
            .post("send", use: sendMessage)
        internalRoutes.grouped("conversations", ":conversationID", "member-cache")
            .post("invalidate", use: invalidateMemberCache)
    }

    func sendMessage(req: Request) async throws -> IMRealtimeMessagePersistenceResult {
        try requireInternalSecret(req)
        let body = try req.content.decode(IMInternalMessageSendRequest.self)
        return try await IMRealtimeMessageService(app: req.application)
            .persistIncomingMessage(body.payload, senderUserID: body.senderUserID)
    }

    func invalidateMemberCache(req: Request) async throws -> HTTPStatus {
        try requireInternalSecret(req)
        guard
            let rawConversationID = req.parameters.get("conversationID"),
            let conversationID = UUID(uuidString: rawConversationID)
        else {
            throw Abort(.badRequest, reason: "会话 ID 无效。")
        }

        await req.application.conversationMemberCache.invalidate(conversationID: conversationID)
        return .ok
    }

    private func requireInternalSecret(_ req: Request) throws {
        guard let expected = req.application.commandOwnerRoutingConfiguration.sharedSecret?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !expected.isEmpty
        else {
            if req.application.environment == .production {
                throw Abort(.internalServerError, reason: "IM_COMMAND_INTERNAL_SHARED_SECRET is required in production.")
            }
            return
        }

        guard req.headers.first(name: "X-IM-Internal-Secret") == expected else {
            throw Abort(.unauthorized, reason: "Invalid internal command secret.")
        }
    }
}
