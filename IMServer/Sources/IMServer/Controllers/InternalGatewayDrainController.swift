import Vapor

/// Private Gateway control plane used by deployment automation. Draining stops
/// new TCP admissions while existing channels remain live until the load
/// balancer and clients have had time to reconnect elsewhere.
struct InternalGatewayDrainController: RouteCollection {
    private static let internalSecretHeader = "X-IM-Internal-Secret"

    func boot(routes: any RoutesBuilder) throws {
        let drain = routes.grouped("internal", "gateway", "drain")
        drain.get(use: status)
        drain.put(use: setDrainState)
    }

    private func status(req: Request) async throws -> GatewayDrainStatusResponse {
        try requireControlSecret(req)
        return await response(for: req.application, disconnectedConnectionCount: 0)
    }

    private func setDrainState(req: Request) async throws -> GatewayDrainStatusResponse {
        try requireControlSecret(req)
        let request = try req.content.decode(GatewayDrainRequest.self)
        guard request.draining || !request.disconnectExisting else {
            throw Abort(.badRequest, reason: "disconnectExisting requires draining=true.")
        }

        let admissionStatus = req.application.imTCPAdmissionController.setDraining(request.draining)
        var disconnectedConnectionCount = 0
        if request.draining, request.disconnectExisting {
            disconnectedConnectionCount = await req.application.connectionRoutingService
                .disconnectAllLocalConnectionsForGatewayDrain()
        }
        req.application.logger.notice(
            "Gateway drain state changed",
            metadata: [
                "draining": .stringConvertible(admissionStatus.isDraining),
                "disconnect_existing": .stringConvertible(request.disconnectExisting),
                "disconnected_connection_count": .stringConvertible(disconnectedConnectionCount)
            ]
        )
        return await response(for: req.application, disconnectedConnectionCount: disconnectedConnectionCount)
    }

    private func response(
        for application: Application,
        disconnectedConnectionCount: Int
    ) async -> GatewayDrainStatusResponse {
        let admissionStatus = application.imTCPAdmissionController.status()
        return GatewayDrainStatusResponse(
            draining: admissionStatus.isDraining,
            activeTCPChannelCount: admissionStatus.activeConnectionCount,
            authenticatedConnectionCount: await application.imConnectionRegistry.totalConnectionCount(),
            configuredConnectionLimit: admissionStatus.maximumConnectionCount,
            disconnectedConnectionCount: disconnectedConnectionCount
        )
    }

    private func requireControlSecret(_ req: Request) throws {
        let expected = Environment.get("IM_GATEWAY_CONTROL_SHARED_SECRET")
            ?? Environment.get("IM_INTERNAL_SHARED_SECRET")
        guard let expected, expected.count >= 32 else {
            if req.application.environment == .production {
                throw Abort(.internalServerError, reason: "Gateway drain control requires IM_GATEWAY_CONTROL_SHARED_SECRET or IM_INTERNAL_SHARED_SECRET.")
            }
            return
        }
        guard req.headers.first(name: Self.internalSecretHeader) == expected else {
            throw Abort(.unauthorized, reason: "Invalid Gateway drain control credential.")
        }
    }
}

private struct GatewayDrainRequest: Content {
    let draining: Bool
    let disconnectExisting: Bool
}

private struct GatewayDrainStatusResponse: Content {
    let draining: Bool
    let activeTCPChannelCount: Int
    let authenticatedConnectionCount: Int
    let configuredConnectionLimit: Int
    let disconnectedConnectionCount: Int
}
