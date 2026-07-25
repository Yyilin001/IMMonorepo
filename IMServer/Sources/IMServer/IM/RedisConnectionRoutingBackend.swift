import Foundation
import NIOCore
import NIOPosix
import RediStack
import Vapor

final class RedisConnectionRoutingBackend: ConnectionRoutingBackend, @unchecked Sendable {
    let presenceStore: any PresenceStore
    let dispatchService: any NodeMessageDispatchService

    private let pool: RedisConnectionPool
    private let logger: Logger

    init(
        configuration: IMRedisRoutingConfiguration,
        nodeDispatchConfiguration: IMNodeDispatchConfiguration = .init(
            mode: .redis,
            endpointsByNodeID: [:],
            sharedSecret: nil
        ),
        nodeID: String,
        cellID: String = IMRealtimeCellConfiguration.defaultCellID,
        logger: Logger,
        eventLoop: any EventLoop
    ) throws {
        self.logger = logger

        let url = try configuration.requireURL()
        let redisURL = try URL(string: url).unwrap(or: RedisRoutingError.invalidURL(url))
        let host = try redisURL.host.unwrap(or: RedisRoutingError.invalidURL(url))
        let address = try SocketAddress.makeAddressResolvingHost(host, port: redisURL.port ?? RedisConnection.Configuration.defaultPort)
        let factoryConfiguration = RedisConnectionPool.ConnectionFactoryConfiguration(
            connectionInitialDatabase: Int(redisURL.lastPathComponent),
            connectionUsername: redisURL.user,
            connectionPassword: redisURL.password,
            connectionDefaultLogger: logger
        )
        let pool = RedisConnectionPool(
            configuration: .init(
                initialServerConnectionAddresses: [address],
                maximumConnectionCount: .maximumActiveConnections(configuration.maximumConnectionCount),
                connectionFactoryConfiguration: factoryConfiguration,
                minimumConnectionCount: 1,
                poolDefaultLogger: logger
            ),
            boundEventLoop: eventLoop
        )
        self.pool = pool
        self.presenceStore = RedisPresenceStore(
            pool: pool,
            nodeID: nodeID,
            cellID: cellID,
            logger: logger,
            heartbeatTimeoutSeconds: configuration.presenceHeartbeatTimeoutSeconds,
            activeConversationRouteTTLSeconds: configuration.activeConversationRouteTTLSeconds,
            activeConversationRouteCacheTTLSeconds: configuration.activeConversationRouteCacheTTLSeconds
        )
        switch nodeDispatchConfiguration.mode {
        case .redis:
            self.dispatchService = RedisNodeMessageDispatchService(
                pool: pool,
                nodeID: nodeID,
                cellID: cellID,
                logger: logger
            )
        case .valkeyStream:
            throw RedisRoutingError.valkeyStreamDispatchRequiresCluster
        case .http:
            self.dispatchService = HTTPNodeMessageDispatchService(
                configuration: nodeDispatchConfiguration
            )
        }
    }

    var backendName: String { "redis" }

    func start(app: Application) async throws {
        pool.activate(logger: logger)
        _ = try await pool.leaseConnection { $0.ping() }.get()
        try await presenceStore.start(app: app)
        try await dispatchService.start(app: app)
    }

    func shutdown() async {
        await dispatchService.shutdown()
        await presenceStore.shutdown()
        let promise = pool.eventLoop.makePromise(of: Void.self)
        pool.close(promise: promise, logger: logger)
        try? await promise.futureResult.get()
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> any Error) throws -> Wrapped {
        guard let value = self else {
            throw error()
        }
        return value
    }
}
