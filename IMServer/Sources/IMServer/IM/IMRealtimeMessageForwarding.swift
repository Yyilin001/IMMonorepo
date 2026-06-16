import Vapor

extension IMRealtimeMessageService {
    func forwardToOwnerIfNeeded(
        _ payload: IMTCPMessagePayload,
        senderUserID: UUID,
        conversationID: UUID
    ) async throws -> IMRealtimeMessagePersistenceResult? {
        guard let app else { return nil }
        let configuration = app.commandOwnerRoutingConfiguration
        guard let owner = configuration.owner(for: conversationID),
              !(app.imRuntimeRole.servesCommandAPI && owner.id == configuration.nodeID)
        else {
            return nil
        }

        do {
            let target = URI(string: "\(owner.baseURL)/internal/im/messages/send")
            var headers = internalHeaders(sharedSecret: configuration.sharedSecret)
            headers.replaceOrAdd(name: "X-IM-Internal-Response", value: "full")
            let response = try await app.client.post(target, headers: headers) { req in
                try req.content.encode(
                    IMInternalMessageSendRequest(
                        payload: payload,
                        senderUserID: senderUserID
                    )
                )
            }
            guard response.status == .ok else {
                await app.messageWriteMetrics.recordOwnerForwardFailed()
                throw Abort(.serviceUnavailable, reason: "Conversation owner \(owner.id) rejected message write with \(response.status.code).")
            }
            await app.messageWriteMetrics.recordOwnerForwarded()
            return try response.content.decode(IMRealtimeMessagePersistenceResult.self)
        } catch {
            await app.messageWriteMetrics.recordOwnerForwardFailed()
            throw error
        }
    }

    func internalHeaders(sharedSecret: String?) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.contentType = .json
        if let sharedSecret, !sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: sharedSecret)
        }
        return headers
    }
}
