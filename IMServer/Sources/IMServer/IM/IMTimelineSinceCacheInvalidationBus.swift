import Foundation
import NIOCore
@preconcurrency import RediStack
import Vapor

enum IMTimelineSinceCacheInvalidationBusError: Error {
    case missingRedisURL
}

final class IMTimelineSinceCacheInvalidationBus: @unchecked Sendable {
    private struct InvalidationMessage: Codable, Sendable {
        let sourceNodeID: String
        let conversationID: UUID
    }

    private let pool: RedisConnectionPool
    private let nodeID: String
    private let logger: Logger
    private let metrics: IMTimelineReadMetrics
    private let channel = RedisChannelName("im:timeline-since-cache:invalidate")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private weak var app: Application?

    init(
        configuration: IMTimelineSinceCacheInvalidationConfiguration,
        nodeID: String,
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
            let message = InvalidationMessage(
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
        let message: InvalidationMessage
        do {
            message = try decoder.decode(InvalidationMessage.self, from: data)
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
    private let bus: IMTimelineSinceCacheInvalidationBus

    init(bus: IMTimelineSinceCacheInvalidationBus) {
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
                let bus = try IMTimelineSinceCacheInvalidationBus(
                    configuration: configuration,
                    nodeID: imNodeID,
                    logger: logger,
                    metrics: timelineReadMetrics,
                    eventLoop: eventLoopGroup.next()
                )
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
