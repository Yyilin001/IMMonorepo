import Foundation
import Valkey
import Vapor

/// Cluster-specific routing backend. Unlike the legacy RediStack backend, every
/// Presence Store operation is scoped to one Redis Cluster hash slot and
/// cross-node realtime dispatch uses a target-node Valkey Stream.
final class ValkeyClusterConnectionRoutingBackend: ConnectionRoutingBackend, @unchecked Sendable {
    let presenceStore: any PresenceStore
    let dispatchService: any NodeMessageDispatchService

    private let client: ValkeyClusterClient
    private let logger: Logger
    private var runTask: Task<Void, Never>?

    init(
        configuration: IMRedisRoutingConfiguration,
        nodeDispatchConfiguration: IMNodeDispatchConfiguration,
        nodeID: String,
        cellID: String,
        logger: Logger
    ) throws {
        guard nodeDispatchConfiguration.mode == .valkeyStream else {
            throw RedisRoutingError.redisClusterTopologyUnsupported
        }

        let redisURLString = try configuration.requireURL()
        guard let redisURL = URL(string: redisURLString),
              let scheme = redisURL.scheme?.lowercased()
        else {
            throw RedisRoutingError.invalidURL(redisURLString)
        }
        guard scheme == "redis" else {
            throw RedisRoutingError.unsupportedRedisScheme(scheme)
        }

        var clientConfiguration = ValkeyClientConfiguration(commandTimeout: .seconds(5))
        if let password = redisURL.password {
            clientConfiguration.authentication = .init(
                username: redisURL.user ?? "default",
                password: password
            )
        }
        let maximumConnections = max(2, configuration.maximumConnectionCount)
        clientConfiguration.connectionPool = .init(
            minimumConnectionCount: 1,
            maximumConnectionSoftLimit: maximumConnections,
            maximumConnectionHardLimit: maximumConnections * 2,
            maximumConcurrentConnectionRequests: maximumConnections
        )
        let discovery = ValkeyStaticNodeDiscovery(
            try configuration.requireClusterSeedEndpoints().map {
                .init(endpoint: $0.host, port: $0.port)
            }
        )
        self.client = ValkeyClusterClient(
            nodeDiscovery: discovery,
            configuration: .init(
                client: clientConfiguration,
                maximumRedirects: 5,
                clusterRefreshInterval: .seconds(30),
                clusterConsensusCircuitBreaker: .seconds(30)
            ),
            logger: logger
        )
        self.logger = logger
        self.presenceStore = ValkeyClusterPresenceStore(
            client: client,
            nodeID: nodeID,
            cellID: cellID,
            logger: logger,
            heartbeatTimeoutSeconds: configuration.presenceHeartbeatTimeoutSeconds,
            activeConversationRouteTTLSeconds: configuration.activeConversationRouteTTLSeconds
        )
        self.dispatchService = ValkeyStreamNodeMessageDispatchService(
            client: client,
            nodeID: nodeID,
            cellID: cellID,
            logger: logger
        )
    }

    var backendName: String { "valkey-cluster" }

    func start(app: Application) async throws {
        runTask = Task { [client] in
            await client.run()
        }
        try await waitUntilReady()
        try await presenceStore.start(app: app)
        try await dispatchService.start(app: app)
    }

    func shutdown() async {
        await dispatchService.shutdown()
        await presenceStore.shutdown()
        runTask?.cancel()
        runTask = nil
    }

    private func waitUntilReady() async throws {
        for attempt in 0..<30 {
            if (try? await client.ping()) != nil {
                return
            }
            if attempt < 29 {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        logger.error("Valkey Cluster client did not become ready before routing startup")
        throw RedisRoutingError.invalidRedisClusterSeed("Unable to connect to any configured Redis Cluster seed.")
    }
}
