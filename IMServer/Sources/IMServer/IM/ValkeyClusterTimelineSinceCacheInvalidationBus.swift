import Foundation
import Valkey
import Vapor

/// Redis Cluster-compatible timeline cache invalidation transport.
///
/// Each node consumes a single hash-tagged Stream independently. Unlike ordinary
/// Pub/Sub, a temporary connection failure resumes from the last processed ID;
/// the bounded stream retention and the short local-cache TTL bound stale reads
/// if a node is offline longer than the retained event window.
final class ValkeyClusterTimelineSinceCacheInvalidationBus: IMTimelineSinceCacheInvalidating, @unchecked Sendable {
    private static let streamMaxLength = 10_000
    private static let streamReadBlockMilliseconds = 1_000
    private static let streamReadCount = 100

    private let client: ValkeyClusterClient
    private let nodeID: String
    private let logger: Logger
    private let metrics: IMTimelineReadMetrics
    private let streamKey: ValkeyKey
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private weak var app: Application?
    private var runTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?

    init(
        configuration: IMTimelineSinceCacheInvalidationConfiguration,
        clusterSeedEndpoints: [IMRedisClusterSeedEndpoint],
        nodeID: String,
        cellID: String,
        logger: Logger,
        metrics: IMTimelineReadMetrics
    ) throws {
        guard let redisURLString = configuration.redisURL else {
            throw IMTimelineSinceCacheInvalidationBusError.missingRedisURL
        }
        guard let redisURL = URL(string: redisURLString),
              let scheme = redisURL.scheme?.lowercased()
        else {
            throw RedisRoutingError.invalidURL(redisURLString)
        }
        guard scheme == "redis" else {
            throw RedisRoutingError.unsupportedRedisScheme(scheme)
        }
        guard !clusterSeedEndpoints.isEmpty else {
            throw RedisRoutingError.invalidRedisClusterSeed(
                "IM_REDIS_CLUSTER_NODES must contain at least one host:port endpoint."
            )
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
        self.client = ValkeyClusterClient(
            nodeDiscovery: ValkeyStaticNodeDiscovery(clusterSeedEndpoints.map {
                .init(endpoint: $0.host, port: $0.port)
            }),
            configuration: .init(
                client: clientConfiguration,
                maximumRedirects: 5,
                clusterRefreshInterval: .seconds(30),
                clusterConsensusCircuitBreaker: .seconds(30)
            ),
            logger: logger
        )
        self.nodeID = nodeID
        self.logger = logger
        self.metrics = metrics
        self.streamKey = ValkeyKey(
            IMRealtimeRedisKeyspace(cellID: cellID).key(
                hashedBy: "timeline-since-invalidation",
                suffix: "timeline-since-cache:invalidations"
            )
        )
    }

    func start(app: Application) async throws {
        self.app = app
        runTask = Task { [client] in
            await client.run()
        }
        try await waitUntilReady()
        readTask = Task { [weak self] in
            await self?.consumeInvalidations()
        }
        logger.info("Timeline since cache invalidation Stream started.", metadata: [
            "node_id": .string(nodeID),
            "transport": .string("valkey-cluster-stream")
        ])
    }

    func publish(conversationID: UUID) async {
        do {
            let message = IMTimelineSinceCacheInvalidationMessage(
                sourceNodeID: nodeID,
                conversationID: conversationID
            )
            let data = try encoder.encode(message)
            guard let value = String(data: data, encoding: .utf8) else {
                await metrics.recordSinceDistributedInvalidationError()
                return
            }
            _ = try await client.xadd(
                streamKey,
                trim: .init(
                    strategy: .maxlen,
                    operator: .approximately,
                    threshold: String(Self.streamMaxLength)
                ),
                idSelector: .autoId,
                data: [.init(field: "message", value: value)]
            )
            await metrics.recordSinceDistributedInvalidationPublished()
        } catch {
            await metrics.recordSinceDistributedInvalidationError()
            logger.warning("Timeline since cache invalidation Stream publish failed.", metadata: [
                "node_id": .string(nodeID),
                "error": .string(String(describing: error))
            ])
        }
    }

    func shutdown() async {
        readTask?.cancel()
        readTask = nil
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
        runTask?.cancel()
        runTask = nil
        throw RedisRoutingError.invalidRedisClusterSeed("Unable to connect to any configured Redis Cluster seed.")
    }

    private func consumeInvalidations() async {
        var lastStreamID = "$"
        while !Task.isCancelled {
            do {
                let response = try await client.xread(
                    count: Self.streamReadCount,
                    milliseconds: Self.streamReadBlockMilliseconds,
                    streams: .init(keys: [streamKey], ids: [lastStreamID])
                )
                guard let messages = response?.streams.first?.messages else {
                    continue
                }
                for entry in messages {
                    lastStreamID = entry.id
                    await apply(entry)
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                await metrics.recordSinceDistributedInvalidationError()
                logger.warning("Timeline since cache invalidation Stream read failed; retrying.", metadata: [
                    "node_id": .string(nodeID),
                    "error": .string(String(describing: error))
                ])
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func apply(_ entry: XMessage) async {
        guard let field = entry[field: "message"] else {
            await metrics.recordSinceDistributedInvalidationError()
            return
        }
        let message: IMTimelineSinceCacheInvalidationMessage
        do {
            message = try decoder.decode(
                IMTimelineSinceCacheInvalidationMessage.self,
                from: Data(String(decoding: field, as: UTF8.self).utf8)
            )
        } catch {
            await metrics.recordSinceDistributedInvalidationError()
            logger.warning("Timeline since cache invalidation Stream decode failed.", metadata: [
                "node_id": .string(nodeID),
                "error": .string(String(describing: error))
            ])
            return
        }
        guard message.sourceNodeID != nodeID else {
            return
        }
        app?.invalidateTimelineSinceHotCacheLocally(conversationID: message.conversationID)
        await metrics.recordSinceDistributedInvalidationReceived()
    }
}
