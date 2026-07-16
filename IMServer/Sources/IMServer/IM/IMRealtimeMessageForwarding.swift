import Vapor

extension IMRealtimeMessageService {
    func forwardToRemoteCellIfNeeded(
        _ payload: IMTCPMessagePayload,
        senderUserID: UUID,
        conversationID: UUID
    ) async throws -> IMRealtimeMessagePersistenceResult? {
        guard let app else { return nil }
        let route = try await app.conversationDirectory.route(for: conversationID)
        guard route.cellID != app.imRealtimeCellID else {
            return nil
        }
        guard let baseURL = try await app.cellIngressEndpointResolver.endpoint(for: route.cellID, purpose: .command) else {
            await app.conversationShardRoutingMetrics.recordRemoteCellForwardFailure()
            throw Abort(
                .serviceUnavailable,
                reason: "Conversation \(conversationID.uuidString) belongs to realtime cell \(route.cellID), but no command Cell ingress endpoint is configured."
            )
        }
        guard let sharedSecret = app.cellIngressConfiguration.sharedSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sharedSecret.isEmpty
        else {
            await app.conversationShardRoutingMetrics.recordRemoteCellForwardFailure()
            throw Abort(.serviceUnavailable, reason: "Remote Cell ingress requires IM_CELL_INGRESS_SHARED_SECRET or IM_INTERNAL_SHARED_SECRET.")
        }

        await app.conversationShardRoutingMetrics.recordRemoteCellForwardAttempt()
        let forwardStartedAt = Date()
        do {
            let target = URI(string: "\(baseURL)/internal/im/messages/send")
            var headers = internalHeaders(sharedSecret: sharedSecret)
            headers.replaceOrAdd(name: "X-IM-Internal-Response", value: "full")
            headers.replaceOrAdd(name: "X-IM-Cell-Forwarded-By", value: app.imRealtimeCellID)
            headers.replaceOrAdd(name: "X-IM-Cell-Forward-Target", value: route.cellID)
            headers.replaceOrAdd(name: "X-IM-Cell-Forward-Hop", value: "1")
            headers.replaceOrAdd(name: "X-IM-Conversation-Route-Version", value: String(route.version))
            let response = try await app.client.post(target, headers: headers) { request in
                try request.content.encode(
                    IMInternalMessageSendRequest(
                        payload: payload,
                        senderUserID: senderUserID,
                        cellRoute: IMInternalMessageCellRoute(
                            originCellID: app.imRealtimeCellID,
                            targetCellID: route.cellID,
                            routeVersion: route.version
                        )
                    )
                )
            }
            guard response.status == .ok else {
                throw Abort(.serviceUnavailable, reason: "Remote Cell \(route.cellID) rejected message write with \(response.status.code).")
            }
            await app.conversationShardRoutingMetrics.recordRemoteCellForwardSuccess(
                elapsedMilliseconds: max(0, Int(Date().timeIntervalSince(forwardStartedAt) * 1_000))
            )
            return try response.content.decode(IMRealtimeMessagePersistenceResult.self)
        } catch {
            await app.conversationShardRoutingMetrics.recordRemoteCellForwardFailure(
                elapsedMilliseconds: max(0, Int(Date().timeIntervalSince(forwardStartedAt) * 1_000))
            )
            throw error
        }
    }

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
