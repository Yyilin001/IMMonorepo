import Vapor

struct InternalMessageCommandController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let internalRoutes = routes.grouped("internal", "im")
        internalRoutes.grouped("messages")
            .post("send", use: sendMessage)
        internalRoutes.grouped("conversations", ":conversationID", "member-cache")
            .post("invalidate", use: invalidateMemberCache)
    }

    func sendMessage(req: Request) async throws -> Response {
        let startedAt = Date()
        var decodeMillis = 0
        var persistMillis = 0
        var responseEncodeMillis = 0
        let fullResponse = req.headers.first(name: "X-IM-Internal-Response") == "full"

        do {
            try requireInternalSecret(req)
            let decodeStartedAt = Date()
            let body = try req.content.decode(IMInternalMessageSendRequest.self)
            decodeMillis = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: decodeStartedAt)

            let persistStartedAt = Date()
            let result = try await IMRealtimeMessageService(app: req.application)
                .persistIncomingMessage(body.payload, senderUserID: body.senderUserID)
            persistMillis = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: persistStartedAt)

            let response = Response(status: .ok)
            let encodeStartedAt = Date()
            if fullResponse {
                try response.content.encode(result)
            } else {
                try response.content.encode(IMInternalMessageSendResponse(result: result))
            }
            responseEncodeMillis = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: encodeStartedAt)
            await req.application.messageWriteMetrics.recordCommandSend(
                durationMillis: IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt),
                decodeMillis: decodeMillis,
                persistMillis: persistMillis,
                responseEncodeMillis: responseEncodeMillis,
                fullResponse: fullResponse,
                didFail: false
            )
            return response
        } catch {
            await req.application.messageWriteMetrics.recordCommandSend(
                durationMillis: IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt),
                decodeMillis: decodeMillis,
                persistMillis: persistMillis,
                responseEncodeMillis: responseEncodeMillis,
                fullResponse: fullResponse,
                didFail: true
            )
            throw error
        }
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
        await req.application.directConversationPairCache.invalidate(conversationID: conversationID)
        await req.application.conversationMediaAccessCache.invalidate(conversationID: conversationID)
        await ConversationRecipientSetExistenceCache.shared.invalidateConversation(conversationID)
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
