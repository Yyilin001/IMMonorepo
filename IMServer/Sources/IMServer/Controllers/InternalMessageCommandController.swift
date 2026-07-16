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
            let decodeStartedAt = Date()
            let body = try req.content.decode(IMInternalMessageSendRequest.self)
            decodeMillis = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: decodeStartedAt)
            try requireInternalSecret(req, acceptsCellIngress: body.cellRoute != nil)

            let persistStartedAt = Date()
            let result = try await IMRealtimeMessageService(app: req.application)
                .persistIncomingMessage(
                    body.payload,
                    senderUserID: body.senderUserID,
                    expectedCellRoute: body.cellRoute
                )
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

    private func requireInternalSecret(_ req: Request, acceptsCellIngress: Bool = false) throws {
        let commandOwnerSecret = req.application.commandOwnerRoutingConfiguration.sharedSecret?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cellIngressSecret = acceptsCellIngress
            ? req.application.cellIngressConfiguration.sharedSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let expectedSecrets = Set<String>([commandOwnerSecret, cellIngressSecret].compactMap { secret in
            guard let secret, !secret.isEmpty else { return nil }
            return secret
        })
        guard !expectedSecrets.isEmpty else {
            if req.application.environment == .production {
                throw Abort(.internalServerError, reason: "IM_COMMAND_INTERNAL_SHARED_SECRET is required in production.")
            }
            return
        }

        guard let actualSecret = req.headers.first(name: "X-IM-Internal-Secret"),
              expectedSecrets.contains(actualSecret)
        else {
            throw Abort(.unauthorized, reason: "Invalid internal command secret.")
        }
    }
}
