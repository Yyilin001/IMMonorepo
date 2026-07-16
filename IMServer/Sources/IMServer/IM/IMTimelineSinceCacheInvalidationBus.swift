import Foundation
import NIOCore
@preconcurrency import RediStack
import Vapor

enum IMTimelineSinceCacheInvalidationBusError: Error {
    case missingRedisURL
}

protocol IMTimelineSinceCacheInvalidating: Sendable {
    func start(app: Application) async throws
    func publish(conversationID: UUID) async
    func shutdown() async
}

struct IMTimelineSinceCacheInvalidationMessage: Codable, Sendable {
    let sourceNodeID: String
    let conversationID: UUID
}

final class IMTimelineSinceCacheInvalidationBus: IMTimelineSinceCacheInvalidating, @unchecked Sendable {

    private let pool: RedisConnectionPool
    private let nodeID: String
    private let logger: Logger
    private let metrics: IMTimelineReadMetrics
    private let channel: RedisChannelName
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private weak var app: Application?

    init(
        configuration: IMTimelineSinceCacheInvalidationConfiguration,
        nodeID: String,
        cellID: String = IMRealtimeCellConfiguration.defaultCellID,
        logger: Logger,
        metrics: IMTimelineReadMetrics,
        eventLoop: any EventLoop
    ) throws {
        let url = try configuration.redisURL.unwrap(or: IMTimelineSinceCacheInvalidationBusError.missingRedisURL)
        let redisURL = try URL(string: url).unwrap(or: RedisRoutingError.invalidURL(url))
        let host = try redisURL.host.unwrap(or: RedisRoutingError.invalidURL(url))
        let address = try SocketAddress.makeAddressResolvingHost(
            host,
            port: redisURL.port ?? RedisConnection.Configuration.defaultPort
        )
        let factoryConfiguration = RedisConnectionPool.ConnectionFactoryConfiguration(
            connectionInitialDatabase: Int(redisURL.lastPathComponent),
            connectionUsername: redisURL.user,
            connectionPassword: redisURL.password,
            connectionDefaultLogger: logger
        )
        self.pool = RedisConnectionPool(
            configuration: .init(
                initialServerConnectionAddresses: [address],
                maximumConnectionCount: .maximumActiveConnections(configuration.maximumConnectionCount),
                connectionFactoryConfiguration: factoryConfiguration,
                minimumConnectionCount: 1,
                poolDefaultLogger: logger
            ),
            boundEventLoop: eventLoop
        )
        self.nodeID = nodeID
        self.channel = RedisChannelName(
            IMRealtimeRedisKeyspace(cellID: cellID).key("timeline-since-cache:invalidate")
        )
        self.logger = logger
        self.metrics = metrics
    }

    func start(app: Application) async throws {
        self.app = app
        pool.activate(logger: logger)
        _ = try await pool.leaseConnection { $0.ping() }.get()
        let bus = self
        try await pool.subscribe(
            to: [channel],
            messageReceiver: { _, message in
                guard let rawMessage = message.string else {
                    return
                }
                Task {
                    await bus.applyRemoteInvalidation(rawMessage)
                }
            }
        ).get()
        logger.info("Timeline since cache invalidation bus started.", metadata: [
            "node_id": .string(nodeID)
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
            _ = try await pool.publish(value, to: channel).get()
            await metrics.recordSinceDistributedInvalidationPublished()
        } catch {
            await metrics.recordSinceDistributedInvalidationError()
            logger.warning("Timeline since cache invalidation publish failed.", metadata: [
                "node_id": .string(nodeID),
                "conversation_id": .string(conversationID.uuidString),
                "error": .string(String(describing: error))
            ])
        }
    }

    func shutdown() async {
        let promise = pool.eventLoop.makePromise(of: Void.self)
        pool.close(promise: promise, logger: logger)
        try? await promise.futureResult.get()
    }

    private func applyRemoteInvalidation(_ rawMessage: String) async {
        guard let data = rawMessage.data(using: .utf8) else {
            await metrics.recordSinceDistributedInvalidationError()
            return
        }
        let message: IMTimelineSinceCacheInvalidationMessage
        do {
            message = try decoder.decode(IMTimelineSinceCacheInvalidationMessage.self, from: data)
        } catch {
            await metrics.recordSinceDistributedInvalidationError()
            logger.warning("Timeline since cache invalidation decode failed.", metadata: [
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

final class IMTimelineSinceCacheInvalidationLifecycle: LifecycleHandler, @unchecked Sendable {
    private let bus: any IMTimelineSinceCacheInvalidating

    init(bus: any IMTimelineSinceCacheInvalidating) {
        self.bus = bus
    }

    func shutdownAsync(_ application: Application) async {
        await bus.shutdown()
    }
}

extension Application {
    func configureTimelineSinceCacheInvalidationBusIfNeeded() async throws {
        guard timelineReadConfiguration.requiresSinceCacheInvalidation else {
            return
        }
        guard timelineSinceCacheInvalidationBus == nil else {
            return
        }

        let configuration = timelineSinceCacheInvalidationConfiguration
        switch configuration.mode {
        case .disabled:
            if environment == .production {
                throw Abort(
                    .internalServerError,
                    reason: "Production \(imRuntimeRole.rawValue) requires IM_TIMELINE_SINCE_CACHE_INVALIDATION_MODE=redis when any timeline/since shared cache is enabled."
                )
            }
            return
        case .redis:
            do {
                let routingConfiguration = imRedisRoutingConfigurationOverride
                    ?? IMRedisRoutingConfiguration.load(from: environment)
                let bus: any IMTimelineSinceCacheInvalidating
                if routingConfiguration.deploymentTopology == .cluster {
                    bus = try ValkeyClusterTimelineSinceCacheInvalidationBus(
                        configuration: configuration,
                        clusterSeedEndpoints: try routingConfiguration.requireClusterSeedEndpoints(),
                        nodeID: imNodeID,
                        cellID: imRealtimeCellID,
                        logger: logger,
                        metrics: timelineReadMetrics
                    )
                } else {
                    bus = try IMTimelineSinceCacheInvalidationBus(
                        configuration: configuration,
                        nodeID: imNodeID,
                        cellID: imRealtimeCellID,
                        logger: logger,
                        metrics: timelineReadMetrics,
                        eventLoop: eventLoopGroup.next()
                    )
                }
                try await bus.start(app: self)
                timelineSinceCacheInvalidationBus = bus
                lifecycle.use(IMTimelineSinceCacheInvalidationLifecycle(bus: bus))
            } catch {
                await timelineReadMetrics.recordSinceDistributedInvalidationError()
                if environment == .production {
                    throw error
                }
                logger.warning("Timeline since cache invalidation Redis bus unavailable; using local-only invalidation.", metadata: [
                    "node_id": .string(imNodeID),
                    "error": .string(String(describing: error))
                ])
            }
        }
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
