import Foundation
import Vapor

/// Routes conversation-scoped public API requests to the Cell recorded in the
/// authoritative conversation directory. The receiving Cell revalidates the
/// route before executing the request, so a stale directory lookup cannot
/// silently apply a command to a moved conversation.
struct ConversationCellForwardingMiddleware: AsyncMiddleware {
    private static let forwardedByHeader = "X-IM-Cell-Forwarded-By"
    private static let targetCellHeader = "X-IM-Cell-Forward-Target"
    private static let hopHeader = "X-IM-Cell-Forward-Hop"
    private static let routeVersionHeader = "X-IM-Conversation-Route-Version"
    private static let internalSecretHeader = "X-IM-Internal-Secret"

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let conversationID = try await conversationID(for: request) else {
            return try await next.respond(to: request)
        }

        let route: ConversationRoute
        do {
            route = try await request.application.conversationDirectory.route(for: conversationID)
        } catch let error as Abort
            where error.status == .notFound && request.application.conversationShardRouter.shardIDs.count == 1 {
            // A single-shard deployment has no alternate shard that could own an
            // unregistered legacy conversation. Keep those conversations usable
            // while new writes continue to register authoritative routes.
            request.application.logger.warning(
                "Serving unregistered legacy conversation on the only local shard",
                metadata: ["conversation_id": .string(conversationID.uuidString)]
            )
            return try await next.respond(to: request)
        }
        if request.headers.first(name: Self.forwardedByHeader) != nil {
            try validateForwardedRequest(request, route: route)
            return try await next.respond(to: request)
        }

        guard route.cellID != request.application.imRealtimeCellID else {
            return try await next.respond(to: request)
        }
        return try await forward(request, conversationID: conversationID, route: route)
    }

    private func conversationID(for request: Request) async throws -> UUID? {
        if let rawConversationID = request.parameters.get("conversationID") {
            guard let conversationID = UUID(uuidString: rawConversationID) else {
                throw Abort(.badRequest, reason: "会话 ID 无效。")
            }
            return conversationID
        }

        if request.url.path == "/api/im/favorites",
           let query = request.url.query,
           let components = URLComponents(string: "https://cell.invalid/?\(query)"),
           let rawConversationID = components.queryItems?.first(where: { $0.name == "conversationID" })?.value {
            guard let conversationID = UUID(uuidString: rawConversationID) else {
                throw Abort(.badRequest, reason: "会话 ID 无效。")
            }
            return conversationID
        }

        guard request.url.path.hasSuffix("/join"),
              let token = request.parameters.get("token")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            return nil
        }
        return try await GroupInvite.find(token, on: request.application.db)?.conversationID
    }

    private func validateForwardedRequest(_ request: Request, route: ConversationRoute) throws {
        let configuration = request.application.cellIngressConfiguration
        guard let expectedSecret = configuration.sharedSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expectedSecret.isEmpty,
              request.headers.first(name: Self.internalSecretHeader) == expectedSecret
        else {
            throw Abort(.unauthorized, reason: "Invalid remote Cell ingress credential.")
        }
        guard request.headers.first(name: Self.targetCellHeader) == request.application.imRealtimeCellID,
              request.headers.first(name: Self.forwardedByHeader) != request.application.imRealtimeCellID,
              request.headers.first(name: Self.hopHeader) == "1"
        else {
            throw Abort(.badGateway, reason: "Invalid remote Cell forwarding headers.")
        }
        guard route.cellID == request.application.imRealtimeCellID else {
            throw Abort(.conflict, reason: "Conversation route changed before the target Cell accepted the request.")
        }
        guard request.headers.first(name: Self.routeVersionHeader) == String(route.version) else {
            throw Abort(.conflict, reason: "Conversation route version changed before the target Cell accepted the request.")
        }
    }

    private func forward(
        _ request: Request,
        conversationID: UUID,
        route: ConversationRoute
    ) async throws -> Response {
        let app = request.application
        let purpose: IMCellIngressEndpointPurpose = request.method == .GET || request.method == .HEAD
            ? .query
            : .command
        guard let baseURL = try await app.cellIngressEndpointResolver.endpoint(for: route.cellID, purpose: purpose) else {
            await app.conversationShardRoutingMetrics.recordRemoteCellForwardFailure()
            throw Abort(
                .serviceUnavailable,
                reason: "Conversation \(conversationID.uuidString) belongs to realtime cell \(route.cellID), but no \(purpose.rawValue) Cell ingress endpoint is configured."
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
        let querySuffix = request.url.query.map { "?\($0)" } ?? ""
        let target = URI(string: "\(baseURL)\(request.url.path)\(querySuffix)")
        do {
            let proxied = try await app.client.send(
                request.method,
                headers: forwardedHeaders(
                    from: request,
                    targetCellID: route.cellID,
                    routeVersion: route.version,
                    sharedSecret: sharedSecret
                ),
                to: target
            ) { outgoing in
                if let bodyData = request.body.data {
                    outgoing.body = .init(buffer: bodyData)
                }
            }
            await app.conversationShardRoutingMetrics.recordRemoteCellForwardSuccess(
                elapsedMilliseconds: max(0, Int(Date().timeIntervalSince(forwardStartedAt) * 1_000))
            )
            return Response(
                status: proxied.status,
                headers: proxied.headers,
                body: proxied.body.map { Response.Body(data: Data(buffer: $0)) } ?? .empty
            )
        } catch {
            await app.conversationShardRoutingMetrics.recordRemoteCellForwardFailure(
                elapsedMilliseconds: max(0, Int(Date().timeIntervalSince(forwardStartedAt) * 1_000))
            )
            throw error
        }
    }

    private func forwardedHeaders(
        from request: Request,
        targetCellID: String,
        routeVersion: Int,
        sharedSecret: String
    ) -> HTTPHeaders {
        var headers = HTTPHeaders()
        for name in ["Authorization", "Accept", "Content-Type", "Idempotency-Key", "X-Request-ID"] {
            if let value = request.headers.first(name: name) {
                headers.replaceOrAdd(name: name, value: value)
            }
        }
        headers.replaceOrAdd(name: Self.internalSecretHeader, value: sharedSecret)
        headers.replaceOrAdd(name: Self.forwardedByHeader, value: request.application.imRealtimeCellID)
        headers.replaceOrAdd(name: Self.targetCellHeader, value: targetCellID)
        headers.replaceOrAdd(name: Self.hopHeader, value: "1")
        headers.replaceOrAdd(name: Self.routeVersionHeader, value: String(routeVersion))
        return headers
    }
}
