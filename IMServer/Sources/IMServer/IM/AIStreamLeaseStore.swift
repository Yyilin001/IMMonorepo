import Foundation
import NIOCore
import NIOPosix
@preconcurrency import RediStack
import Vapor

struct AIStreamLeaseCounts: Sendable, Equatable {
    let userCount: Int
    let conversationCount: Int
}

protocol AIStreamLeaseStore: Sendable {
    func start(app: Application) async throws
    func shutdown() async
    func reserve(streamID: String, conversationID: UUID, userID: UUID) async throws
    func attach(streamID: String) async throws
    func requestCancel(streamID: String) async throws
    func cancelRequested(streamID: String) async throws -> Bool
    func finish(streamID: String, conversationID: UUID, userID: UUID) async throws
    func heartbeat(streamID: String, conversationID: UUID, userID: UUID) async throws -> Bool
    func isActive(streamID: String) async throws -> Bool
    func activeCounts(conversationID: UUID, userID: UUID) async throws -> AIStreamLeaseCounts
}

actor LocalAIStreamLeaseStore: AIStreamLeaseStore {
    private struct Entry: Sendable {
        let conversationID: UUID
        let userID: UUID
        var cancelRequested: Bool
    }

    private var entries: [String: Entry] = [:]

    func start(app: Application) async throws {}
    func shutdown() async { entries.removeAll() }

    func reserve(streamID: String, conversationID: UUID, userID: UUID) async throws {
        let userCount = entries.values.filter { $0.userID == userID }.count
        guard userCount < 2 else {
            throw Abort(.tooManyRequests, reason: "AI stream concurrency limit reached.")
        }

        let conversationCount = entries.values.filter { $0.conversationID == conversationID }.count
        guard conversationCount < 5 else {
            throw Abort(.tooManyRequests, reason: "Conversation AI stream concurrency limit reached.")
        }

        entries[streamID] = Entry(conversationID: conversationID, userID: userID, cancelRequested: false)
    }

    func attach(streamID: String) async throws {}

    func requestCancel(streamID: String) async throws {
        guard var entry = entries[streamID] else {
            return
        }
        entry.cancelRequested = true
        entries[streamID] = entry
    }

    func cancelRequested(streamID: String) async throws -> Bool {
        entries[streamID]?.cancelRequested ?? false
    }

    func finish(streamID: String, conversationID: UUID, userID: UUID) async throws {
        entries.removeValue(forKey: streamID)
    }

    func heartbeat(streamID: String, conversationID: UUID, userID: UUID) async throws -> Bool {
        entries[streamID] != nil
    }

    func isActive(streamID: String) async throws -> Bool {
        entries[streamID] != nil
    }

    func activeCounts(conversationID: UUID, userID: UUID) async throws -> AIStreamLeaseCounts {
        AIStreamLeaseCounts(
            userCount: entries.values.filter { $0.userID == userID }.count,
            conversationCount: entries.values.filter { $0.conversationID == conversationID }.count
        )
    }
}

final class RedisAIStreamLeaseStore: AIStreamLeaseStore, @unchecked Sendable {
    private static let ttlSeconds = 180
    private static let userLimit = 2
    private static let conversationLimit = 5

    private let pool: RedisConnectionPool
    private let nodeID: String
    private let logger: Logger

    init(configuration: IMRedisRoutingConfiguration, nodeID: String, logger: Logger, eventLoop: any EventLoop) throws {
        self.nodeID = nodeID
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
        pool = RedisConnectionPool(
            configuration: .init(
                initialServerConnectionAddresses: [address],
                maximumConnectionCount: .maximumActiveConnections(configuration.maximumConnectionCount),
                connectionFactoryConfiguration: factoryConfiguration,
                minimumConnectionCount: 1,
                poolDefaultLogger: logger
            ),
            boundEventLoop: eventLoop
        )
    }

    func start(app: Application) async throws {
        pool.activate(logger: logger)
        _ = try await pool.leaseConnection { $0.ping() }.get()
    }

    func shutdown() async {
        let promise = pool.eventLoop.makePromise(of: Void.self)
        pool.close(promise: promise, logger: logger)
        try? await promise.futureResult.get()
    }

    func reserve(streamID: String, conversationID: UUID, userID: UUID) async throws {
        let result = try await evalReserve(streamID: streamID, conversationID: conversationID, userID: userID)
        switch result {
        case "ok":
            return
        case "user_limit":
            throw Abort(.tooManyRequests, reason: "AI stream concurrency limit reached.")
        case "conversation_limit":
            throw Abort(.tooManyRequests, reason: "Conversation AI stream concurrency limit reached.")
        default:
            throw Abort(.internalServerError, reason: "AI stream lease reservation failed.")
        }
    }

    func attach(streamID: String) async throws {}

    func requestCancel(streamID: String) async throws {
        try await pool.setex(cancelKey(streamID), to: "1", expirationInSeconds: Self.ttlSeconds).get()
    }

    func cancelRequested(streamID: String) async throws -> Bool {
        try await pool.exists(cancelKey(streamID)).get() > 0
    }

    func finish(streamID: String, conversationID: UUID, userID: UUID) async throws {
        _ = try await pool.delete([
            leaseKey(streamID),
            cancelKey(streamID)
        ]).get()
        _ = try await pool.srem(streamID, from: userKey(userID)).get()
        _ = try await pool.srem(streamID, from: conversationKey(conversationID)).get()
    }

    func heartbeat(streamID: String, conversationID: UUID, userID: UUID) async throws -> Bool {
        guard try await isActive(streamID: streamID) else {
            return false
        }
        _ = try await pool.expire(leaseKey(streamID), after: .seconds(Int64(Self.ttlSeconds))).get()
        _ = try await pool.expire(userKey(userID), after: .seconds(Int64(Self.ttlSeconds))).get()
        _ = try await pool.expire(conversationKey(conversationID), after: .seconds(Int64(Self.ttlSeconds))).get()
        return true
    }

    func isActive(streamID: String) async throws -> Bool {
        try await pool.exists(leaseKey(streamID)).get() > 0
    }

    func activeCounts(conversationID: UUID, userID: UUID) async throws -> AIStreamLeaseCounts {
        try await cleanupExpiredMembers(conversationID: conversationID, userID: userID)
        let userCount = try await pool.scard(of: userKey(userID)).get()
        let conversationCount = try await pool.scard(of: conversationKey(conversationID)).get()
        return AIStreamLeaseCounts(userCount: userCount, conversationCount: conversationCount)
    }

    private func evalReserve(streamID: String, conversationID: UUID, userID: UUID) async throws -> String {
        let script = """
        local streamKey = KEYS[1]
        local userKey = KEYS[2]
        local conversationKey = KEYS[3]
        local streamID = ARGV[1]
        local nodeID = ARGV[2]
        local ttl = tonumber(ARGV[3])
        local userLimit = tonumber(ARGV[4])
        local conversationLimit = tonumber(ARGV[5])
        for _, sid in ipairs(redis.call('SMEMBERS', userKey)) do
          if redis.call('EXISTS', 'im:ai_stream:lease:' .. sid) == 0 then
            redis.call('SREM', userKey, sid)
          end
        end
        for _, sid in ipairs(redis.call('SMEMBERS', conversationKey)) do
          if redis.call('EXISTS', 'im:ai_stream:lease:' .. sid) == 0 then
            redis.call('SREM', conversationKey, sid)
          end
        end
        if redis.call('SCARD', userKey) >= userLimit then
          return 'user_limit'
        end
        if redis.call('SCARD', conversationKey) >= conversationLimit then
          return 'conversation_limit'
        end
        redis.call('SET', streamKey, nodeID, 'EX', ttl)
        redis.call('SADD', userKey, streamID)
        redis.call('EXPIRE', userKey, ttl)
        redis.call('SADD', conversationKey, streamID)
        redis.call('EXPIRE', conversationKey, ttl)
        return 'ok'
        """
        let response = try await pool.leaseConnection { connection in
            connection.send(
                command: "EVAL",
                with: [
                    .init(from: script),
                    .init(from: 3),
                    .init(from: self.leaseKey(streamID)),
                    .init(from: self.userKey(userID)),
                    .init(from: self.conversationKey(conversationID)),
                    .init(from: streamID),
                    .init(from: self.nodeID),
                    .init(from: Self.ttlSeconds),
                    .init(from: Self.userLimit),
                    .init(from: Self.conversationLimit)
                ]
            )
        }.get()
        return response.string ?? ""
    }

    private func cleanupExpiredMembers(conversationID: UUID, userID: UUID) async throws {
        let userStreams = try await pool.smembers(of: userKey(userID), as: String.self).get().compactMap { $0 }
        for streamID in userStreams where try await !isActive(streamID: streamID) {
            _ = try await pool.srem(streamID, from: userKey(userID)).get()
        }
        let conversationStreams = try await pool.smembers(of: conversationKey(conversationID), as: String.self).get().compactMap { $0 }
        for streamID in conversationStreams where try await !isActive(streamID: streamID) {
            _ = try await pool.srem(streamID, from: conversationKey(conversationID)).get()
        }
    }

    private func leaseKey(_ streamID: String) -> RedisKey {
        RedisKey("im:ai_stream:lease:\(streamID)")
    }

    private func cancelKey(_ streamID: String) -> RedisKey {
        RedisKey("im:ai_stream:cancel:\(streamID)")
    }

    private func userKey(_ userID: UUID) -> RedisKey {
        RedisKey("im:ai_stream:user:\(userID.uuidString.lowercased())")
    }

    private func conversationKey(_ conversationID: UUID) -> RedisKey {
        RedisKey("im:ai_stream:conversation:\(conversationID.uuidString.lowercased())")
    }
}

final class AIStreamLeaseStoreLifecycle: LifecycleHandler, @unchecked Sendable {
    func shutdownAsync(_ application: Application) async {
        await application.aiStreamLeaseStore.shutdown()
    }
}

private struct AIStreamLeaseStoreStorageKey: StorageKey {
    typealias Value = any AIStreamLeaseStore
}

extension Application {
    var aiStreamLeaseStore: any AIStreamLeaseStore {
        get {
            if let store = storage[AIStreamLeaseStoreStorageKey.self] {
                return store
            }
            let store = LocalAIStreamLeaseStore()
            storage[AIStreamLeaseStoreStorageKey.self] = store
            return store
        }
        set { storage[AIStreamLeaseStoreStorageKey.self] = newValue }
    }

    func configureAIStreamLeaseStoreIfNeeded() async throws {
        if storage[AIStreamLeaseStoreStorageKey.self] != nil {
            try await aiStreamLeaseStore.start(app: self)
            lifecycle.use(AIStreamLeaseStoreLifecycle())
            return
        }

        let routingConfiguration = imRedisRoutingConfigurationOverride ?? IMRedisRoutingConfiguration.load(from: environment)
        let store: any AIStreamLeaseStore
        if routingConfiguration.deploymentTopology == .cluster {
            store = DatabaseAIStreamLeaseStore(database: db, nodeID: imNodeID)
        } else if environment == .production {
            guard routingConfiguration.mode == .redis else {
                throw RedisRoutingError.redisRequiredInProduction
            }
            store = try RedisAIStreamLeaseStore(
                configuration: routingConfiguration,
                nodeID: imNodeID,
                logger: logger,
                eventLoop: eventLoopGroup.next()
            )
        } else if routingConfiguration.mode == .redis, routingConfiguration.url != nil {
            do {
                store = try RedisAIStreamLeaseStore(
                    configuration: routingConfiguration,
                    nodeID: imNodeID,
                    logger: logger,
                    eventLoop: eventLoopGroup.next()
                )
            } catch {
                logger.warning("Redis AI stream lease store unavailable; falling back to local lease store")
                store = LocalAIStreamLeaseStore()
            }
        } else {
            store = LocalAIStreamLeaseStore()
        }

        aiStreamLeaseStore = store
        try await store.start(app: self)
        lifecycle.use(AIStreamLeaseStoreLifecycle())
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
