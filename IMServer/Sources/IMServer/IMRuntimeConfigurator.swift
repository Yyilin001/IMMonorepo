import JWTKit
import Vapor

enum IMRuntimeConfigurator {
    static func configureRole(_ app: Application) async throws {
        switch app.imRuntimeRole {
        case .gateway:
            try await configureGatewayRuntime(app)
        case .commandAPI:
            try await configureCommandAPIRuntime(app)
        case .queryAPI:
            try await configureQueryAPIRuntime(app)
        case .outboxRelay:
            try await configureOutboxRelayRuntime(app)
        case .streamConsumer:
            try await configureStreamConsumerRuntime(app)
        case .projectionWorker:
            try await configureProjectionWorkerRuntime(app)
        case .combined:
            try await configureGatewayRuntime(app)
            try await configureCommandAPIRuntime(app)
            try await configureQueryAPIRuntime(app)
            try await configureProjectionWorkerRuntime(app)
        case .ops:
            try await configureOpsRuntime(app)
        }
    }

    private static func configureHTTPRuntimeBase(_ app: Application) async throws {
        app.middleware.use(IMHTTPMetricsMiddleware())
        app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
        for secret in app.authConfiguration.jwtSecrets {
            await app.jwtKeys.add(
                hmac: HMACKey(from: secret.secret),
                digestAlgorithm: .sha256,
                kid: secret.keyID.map { JWKIdentifier(string: $0) }
            )
        }
    }

    private static func configureGatewayRuntime(_ app: Application) async throws {
        try await configureHTTPRuntimeBase(app)
        if !app.hasConnectionRoutingServiceConfigured {
            _ = app.imConnectionRegistry
            try await app.configureConnectionRoutingServiceIfNeeded()
            app.lifecycle.use(IMTCPServerLifecycle())
            app.lifecycle.use(ConnectionRoutingLifecycle())
        }
        app.lifecycle.use(CrossCellRealtimeDispatchOutboxLifecycle())
        try await IMDevelopmentSeed.seedUserIfNeeded(in: app)
    }

    private static func configureCommandAPIRuntime(_ app: Application) async throws {
        try await configureHTTPRuntimeBase(app)
        try await app.configureTimelineSinceCacheInvalidationBusIfNeeded()
        if !app.imRuntimeRole.servesGateway {
            switch app.gatewayRelayConfiguration.mode {
            case .local:
                if app.environment == .production {
                    throw GatewayRelayConfigurationError.productionCommandAPIRequiresHTTPMode
                }
            case .http:
                guard let baseURL = app.gatewayRelayConfiguration.baseURL, !baseURL.isEmpty else {
                    throw GatewayRelayConfigurationError.httpModeRequiresBaseURL
                }
            }
        }
        try await MediaStorageService(app: app).prepareStorage()
        try FileStorageService(app: app).prepareStorage()
    }

    private static func configureQueryAPIRuntime(_ app: Application) async throws {
        try await configureHTTPRuntimeBase(app)
        try await app.configureTimelineSinceCacheInvalidationBusIfNeeded()
    }

    private static func configureProjectionWorkerRuntime(_ app: Application) async throws {
        guard app.environment != .production else {
            throw Abort(.internalServerError, reason: "projection-worker is a development/testing fallback only; use stream-consumer in production.")
        }
        app.lifecycle.use(ConversationProjectionWorkerLifecycle())
    }

    private static func configureOutboxRelayRuntime(_ app: Application) async throws {
        guard app.eventStreamConfiguration.driver == .kafka || app.environment != .production else {
            throw Abort(.internalServerError, reason: "outbox-relay requires IM_EVENT_STREAM_DRIVER=kafka in production.")
        }
    }

    private static func configureStreamConsumerRuntime(_ app: Application) async throws {
        guard app.eventStreamConfiguration.driver == .kafka || app.environment != .production else {
            throw Abort(.internalServerError, reason: "stream-consumer requires IM_EVENT_STREAM_DRIVER=kafka in production.")
        }
        try await app.configureTimelineSinceCacheInvalidationBusIfNeeded()
        if app.streamConsumerConfiguration.isEnabled("realtime-delivery-consumer"),
           !app.hasConnectionRoutingServiceConfigured {
            try await app.configureConnectionRoutingServiceIfNeeded()
            app.lifecycle.use(ConnectionRoutingLifecycle())
        }
        if app.streamConsumerConfiguration.isEnabled("realtime-delivery-consumer") {
            app.lifecycle.use(CrossCellRealtimeDispatchOutboxLifecycle())
        }
    }

    private static func configureOpsRuntime(_ app: Application) async throws {
    }
}
