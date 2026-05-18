import Vapor

struct GatewayRelayController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let relayRoutes = routes.grouped("internal", "gateway", "realtime")
            .grouped(InternalGatewayRelaySecretMiddleware())

        relayRoutes.post("message", use: relayMessage)
        relayRoutes.post("conversation-event", use: relayConversationEvent)
        relayRoutes.post("contact-event", use: relayContactEvent)
        relayRoutes.post("kick-session", use: relayKickSession)
        relayRoutes.post("kick-user", use: relayKickUser)
        relayRoutes.post("session-counts", use: relaySessionCounts)
    }

    func relayMessage(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(GatewayRelayMessageRequest.self)
        await req.application.gatewaySessionService.sendMessage(
            body.payload,
            toUserIDs: body.recipientUserIDs,
            requestID: body.requestID
        )
        return .ok
    }

    func relayConversationEvent(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(GatewayRelayConversationEventRequest.self)
        await req.application.gatewaySessionService.sendConversationEvent(
            body.payload,
            toUserID: body.recipientUserID,
            requestID: body.requestID
        )
        return .ok
    }

    func relayContactEvent(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(GatewayRelayContactEventRequest.self)
        await req.application.gatewaySessionService.sendContactEvent(
            body.payload,
            toUserID: body.recipientUserID,
            requestID: body.requestID
        )
        return .ok
    }

    func relayKickSession(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(GatewayRelayKickSessionRequest.self)
        await req.application.gatewaySessionService.kickConnections(
            forSessionID: body.sessionID,
            reason: body.reason,
            message: body.message
        )
        return .ok
    }

    func relayKickUser(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(GatewayRelayKickUserRequest.self)
        await req.application.gatewaySessionService.kickConnections(
            forUserID: body.userID,
            reason: body.reason,
            message: body.message
        )
        return .ok
    }

    func relaySessionCounts(req: Request) async throws -> GatewayRelaySessionCountsResponse {
        let body = try req.content.decode(GatewayRelaySessionCountsRequest.self)
        let counts = await req.application.gatewaySessionService.activeConnectionCounts(forSessionIDs: body.sessionIDs)
        return GatewayRelaySessionCountsResponse(counts: counts)
    }
}

struct InternalGatewayRelaySecretMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let configuration = request.application.gatewayRelayConfiguration
        if let sharedSecret = configuration.sharedSecret, !sharedSecret.isEmpty {
            let actualSecret = request.headers.first(name: "X-IM-Internal-Secret")
            guard actualSecret == sharedSecret else {
                throw Abort(.unauthorized, reason: "Invalid internal relay secret.")
            }
        } else if request.application.environment == .production {
            throw Abort(.internalServerError, reason: "IM_INTERNAL_SHARED_SECRET is required for gateway relay in production.")
        }
        return try await next.respond(to: request)
    }
}
