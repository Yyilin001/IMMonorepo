import Foundation
import NIOCore
@preconcurrency import RediStack
import Valkey
import Vapor

struct IMHotConversationConfiguration: Sendable {
    enum LimiterMode: String, Sendable {
        case local
        case redis
    }

    let messagesPerSecondLimit: Int
    let limiterMode: LimiterMode
    let redisURL: String?
    let redisMaximumConnectionCount: Int

    var isEnabled: Bool {
        messagesPerSecondLimit > 0
    }

    static func load(from environment: Environment) -> IMHotConversationConfiguration {
        IMHotConversationConfiguration(
            messagesPerSecondLimit: max(0, Environment.get("IM_HOT_CONVERSATION_MSG_PER_SECOND_LIMIT").flatMap(Int.init(_:)) ?? 0),
            limiterMode: Environment.get("IM_HOT_CONVERSATION_LIMITER_MODE")
                .flatMap(LimiterMode.init(rawValue:))
                ?? (environment == .production ? .redis : .local),
            redisURL: nonBlankEnvironmentValue("IM_HOT_CONVERSATION_LIMITER_REDIS_URL")
                ?? nonBlankEnvironmentValue("REDIS_URL"),
            redisMaximumConnectionCount: max(
                1,
                Environment.get("IM_HOT_CONVERSATION_LIMITER_REDIS_MAX_CONNECTIONS").flatMap(Int.init(_:)) ?? 4
            )
        )
    }

    private static func nonBlankEnvironmentValue(_ key: String) -> String? {
        let value = Environment.get(key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

protocol HotConversationLimiting: Sendable {
    func reserve(conversationID: UUID, limit: Int, now: Date) async throws
    func trackedWindowCount() async -> Int
}

actor HotConversationLimiter: HotConversationLimiting {
    private struct Window {
        var second: Int
        var count: Int
    }

    private var windows: [UUID: Window] = [:]

    func reserve(conversationID: UUID, limit: Int, now: Date = Date()) throws {
        guard limit > 0 else {
            return
        }

        let second = Int(now.timeIntervalSince1970)
        var window = windows[conversationID] ?? Window(second: second, count: 0)
        if window.second != second {
            window = Window(second: second, count: 0)
            prune(before: second - 1)
        }

        guard window.count < limit else {
            windows[conversationID] = window
            throw HotConversationLimiterError.rateLimited
        }

        window.count += 1
        windows[conversationID] = window
    }

    func currentWindowCount(for conversationID: UUID, now: Date = Date()) -> Int {
        let second = Int(now.timeIntervalSince1970)
        guard let window = windows[conversationID], window.second == second else {
            return 0
        }
        return window.count
    }

    func trackedWindowCount() -> Int {
        windows.count
    }

    private func prune(before second: Int) {
        windows = windows.filter { $0.value.second >= second }
    }
}

enum HotConversationLimiterError: Error {
    case rateLimited
}

enum HotConversationLimiterConfigurationError: Error {
    case missingRedisURL
}

final class RedisHotConversationLimiter: HotConversationLimiting, @unchecked Sendable {
    private let pool: RedisConnectionPool
    private let keyspace: IMRealtimeRedisKeyspace
    private let trackedWindows = HotConversationLimiter()
    private let logger: Logger

    init(
        redisURL: String,
        cellID: String,
        maximumConnectionCount: Int,
        logger: Logger,
        eventLoop: any EventLoop
    ) throws {
        guard let url = URL(string: redisURL),
              let host = url.host
        else {
            throw RedisRoutingError.invalidURL(redisURL)
        }
        let address = try SocketAddress.makeAddressResolvingHost(
            host,
            port: url.port ?? RedisConnection.Configuration.defaultPort
        )
        let factoryConfiguration = RedisConnectionPool.ConnectionFactoryConfiguration(
            connectionInitialDatabase: Int(url.lastPathComponent),
            connectionUsername: url.user,
            connectionPassword: url.password,
            connectionDefaultLogger: logger
        )
        self.pool = RedisConnectionPool(
            configuration: .init(
                initialServerConnectionAddresses: [address],
                maximumConnectionCount: .maximumActiveConnections(maximumConnectionCount),
                connectionFactoryConfiguration: factoryConfiguration,
                minimumConnectionCount: 1,
                poolDefaultLogger: logger
            ),
            boundEventLoop: eventLoop
        )
        self.keyspace = IMRealtimeRedisKeyspace(cellID: cellID)
        self.logger = logger
    }

    func start() async throws {
        pool.activate(logger: logger)
        _ = try await pool.leaseConnection { $0.ping() }.get()
    }

    func reserve(conversationID: UUID, limit: Int, now: Date = Date()) async throws {
        guard limit > 0 else {
            return
        }

        let result = try await pool.leaseConnection { connection in
            connection.send(command: "EVAL", with: [
                .init(from: Self.reserveScript),
                .init(from: 1),
                .init(from: RedisKey(self.quotaKey(conversationID: conversationID, now: now))),
                .init(from: limit)
            ])
        }.get()
        guard case .integer(1) = result else {
            throw HotConversationLimiterError.rateLimited
        }
        try await trackedWindows.reserve(conversationID: conversationID, limit: Int.max, now: now)
    }

    func trackedWindowCount() async -> Int {
        await trackedWindows.trackedWindowCount()
    }

    func shutdown() async {
        let promise = pool.eventLoop.makePromise(of: Void.self)
        pool.close(promise: promise, logger: logger)
        try? await promise.futureResult.get()
    }

    private func quotaKey(conversationID: UUID, now: Date) -> String {
        let conversationID = conversationID.uuidString.lowercased()
        return keyspace.key(
            hashedBy: conversationID,
            suffix: "hot-conversation:\(conversationID):\(Int(now.timeIntervalSince1970))"
        )
    }

    fileprivate static let reserveScript = """
    local current = tonumber(redis.call('GET', KEYS[1]) or '0')
    local limit = tonumber(ARGV[1])
    if current >= limit then
      return 0
    end
    current = redis.call('INCR', KEYS[1])
    if current == 1 then
      redis.call('PEXPIRE', KEYS[1], 1100)
    end
    return 1
    """
}

/// Redis Cluster implementation of the fixed-window conversation quota. The
/// quota key is pinned by conversation ID, so the Lua read/increment/expiry
/// transaction is always confined to one hash slot.
final class ValkeyClusterHotConversationLimiter: HotConversationLimiting, @unchecked Sendable {
    private let client: ValkeyClusterClient
    private let keyspace: IMRealtimeRedisKeyspace
    private let trackedWindows = HotConversationLimiter()
    private let logger: Logger
    private var runTask: Task<Void, Never>?

    init(
        redisURL: String,
        clusterSeedEndpoints: [IMRedisClusterSeedEndpoint],
        cellID: String,
        maximumConnectionCount: Int,
        logger: Logger
    ) throws {
        guard let url = URL(string: redisURL),
              let scheme = url.scheme?.lowercased()
        else {
            throw RedisRoutingError.invalidURL(redisURL)
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
        if let password = url.password {
            clientConfiguration.authentication = .init(username: url.user ?? "default", password: password)
        }
        let maximumConnections = max(2, maximumConnectionCount)
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
        self.keyspace = IMRealtimeRedisKeyspace(cellID: cellID)
        self.logger = logger
    }

    func start() async throws {
        runTask = Task { [client] in
            await client.run()
        }
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
        logger.error("Valkey Cluster client did not become ready for hot conversation limiting")
        throw RedisRoutingError.invalidRedisClusterSeed("Unable to connect to any configured Redis Cluster seed.")
    }

    func reserve(conversationID: UUID, limit: Int, now: Date = Date()) async throws {
        guard limit > 0 else {
            return
        }
        let result = try await client.eval(
            script: RedisHotConversationLimiter.reserveScript,
            keys: [quotaKey(conversationID: conversationID, now: now)],
            args: [String(limit)]
        )
        guard case .number(1) = result.value else {
            throw HotConversationLimiterError.rateLimited
        }
        try await trackedWindows.reserve(conversationID: conversationID, limit: Int.max, now: now)
    }

    func trackedWindowCount() async -> Int {
        await trackedWindows.trackedWindowCount()
    }

    func shutdown() async {
        runTask?.cancel()
        runTask = nil
    }

    private func quotaKey(conversationID: UUID, now: Date) -> ValkeyKey {
        let rawConversationID = conversationID.uuidString.lowercased()
        return ValkeyKey(keyspace.key(
            hashedBy: rawConversationID,
            suffix: "hot-conversation:\(rawConversationID):\(Int(now.timeIntervalSince1970))"
        ))
    }
}

final class RedisHotConversationLimiterLifecycle: LifecycleHandler, @unchecked Sendable {
    private let limiter: RedisHotConversationLimiter

    init(limiter: RedisHotConversationLimiter) {
        self.limiter = limiter
    }

    func shutdownAsync(_ application: Application) async {
        await limiter.shutdown()
    }
}

final class ValkeyClusterHotConversationLimiterLifecycle: LifecycleHandler, @unchecked Sendable {
    private let limiter: ValkeyClusterHotConversationLimiter

    init(limiter: ValkeyClusterHotConversationLimiter) {
        self.limiter = limiter
    }

    func shutdownAsync(_ application: Application) async {
        await limiter.shutdown()
    }
}

enum HotConversationLimiterFactory {
    static func make(
        app: Application,
        configuration: IMHotConversationConfiguration
    ) async throws -> any HotConversationLimiting {
        switch configuration.limiterMode {
        case .local:
            return HotConversationLimiter()
        case .redis:
            guard let redisURL = configuration.redisURL else {
                throw HotConversationLimiterConfigurationError.missingRedisURL
            }
            let routingConfiguration = app.imRedisRoutingConfigurationOverride
                ?? IMRedisRoutingConfiguration.load(from: app.environment)
            if routingConfiguration.deploymentTopology == .cluster {
                let limiter = try ValkeyClusterHotConversationLimiter(
                    redisURL: redisURL,
                    clusterSeedEndpoints: try routingConfiguration.requireClusterSeedEndpoints(),
                    cellID: app.imRealtimeCellID,
                    maximumConnectionCount: configuration.redisMaximumConnectionCount,
                    logger: app.logger
                )
                try await limiter.start()
                app.lifecycle.use(ValkeyClusterHotConversationLimiterLifecycle(limiter: limiter))
                return limiter
            }
            let limiter = try RedisHotConversationLimiter(
                redisURL: redisURL,
                cellID: app.imRealtimeCellID,
                maximumConnectionCount: configuration.redisMaximumConnectionCount,
                logger: app.logger,
                eventLoop: app.eventLoopGroup.next()
            )
            try await limiter.start()
            app.lifecycle.use(RedisHotConversationLimiterLifecycle(limiter: limiter))
            return limiter
        }
    }
}

actor HotConversationMetrics {
    struct Snapshot: Sendable {
        var rejectedMessages: Int = 0
        var backendErrors: Int = 0
        var trackedWindows: Int = 0
    }

    private var snapshot = Snapshot()

    func recordRejectedMessage() {
        snapshot.rejectedMessages += 1
    }

    func recordBackendError() {
        snapshot.backendErrors += 1
    }

    func recordTrackedWindows(_ count: Int) {
        snapshot.trackedWindows = count
    }

    func currentSnapshot() -> Snapshot {
        snapshot
    }
}

private struct IMHotConversationConfigurationStorageKey: StorageKey {
    typealias Value = IMHotConversationConfiguration
}

private struct HotConversationLimiterStorageKey: StorageKey {
    typealias Value = any HotConversationLimiting
}

private struct HotConversationMetricsStorageKey: StorageKey {
    typealias Value = HotConversationMetrics
}

extension Application {
    var hotConversationConfiguration: IMHotConversationConfiguration {
        get {
            if let configuration = storage[IMHotConversationConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMHotConversationConfiguration.load(from: environment)
            storage[IMHotConversationConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[IMHotConversationConfigurationStorageKey.self] = newValue }
    }

    var hotConversationLimiter: any HotConversationLimiting {
        get {
            if let limiter = storage[HotConversationLimiterStorageKey.self] {
                return limiter
            }
            let limiter: any HotConversationLimiting = HotConversationLimiter()
            storage[HotConversationLimiterStorageKey.self] = limiter
            return limiter
        }
        set { storage[HotConversationLimiterStorageKey.self] = newValue }
    }

    var hotConversationMetrics: HotConversationMetrics {
        get {
            if let metrics = storage[HotConversationMetricsStorageKey.self] {
                return metrics
            }
            let metrics = HotConversationMetrics()
            storage[HotConversationMetricsStorageKey.self] = metrics
            return metrics
        }
        set { storage[HotConversationMetricsStorageKey.self] = newValue }
    }
}
