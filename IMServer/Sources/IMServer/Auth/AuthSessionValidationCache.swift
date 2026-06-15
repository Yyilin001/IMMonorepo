import Fluent
import Foundation
import NIOCore
import NIOPosix
@preconcurrency import RediStack
import Vapor

enum AuthSessionCacheMode: String, Sendable {
    case disabled
    case local
    case redis
}

struct AuthSessionCacheConfiguration: Sendable {
    let mode: AuthSessionCacheMode
    let ttlSeconds: Int
    let maxEntries: Int
    let redisMaxConnections: Int
    let redisURL: String?

    static func load(from environment: Environment) -> AuthSessionCacheConfiguration {
        let configuredMode = Environment.get("AUTH_SESSION_CACHE_MODE")
            .flatMap(AuthSessionCacheMode.init(rawValue:))
        let mode = configuredMode ?? (environment == .testing ? .disabled : .redis)
        let maxTTLSeconds = max(
            30,
            Environment.get("AUTH_SESSION_CACHE_MAX_TTL_SECONDS").flatMap(Int.init(_:)) ?? 300
        )
        let ttlSeconds = min(
            max(1, Environment.get("AUTH_SESSION_CACHE_TTL_SECONDS").flatMap(Int.init(_:)) ?? 5),
            maxTTLSeconds
        )
        let maxEntries = max(1, Environment.get("AUTH_SESSION_CACHE_MAX_ENTRIES").flatMap(Int.init(_:)) ?? 100_000)
        let redisMaxConnections = max(
            2,
            Environment.get("AUTH_SESSION_CACHE_REDIS_MAX_CONNECTIONS").flatMap(Int.init(_:)) ?? 2
        )
        let redisURL = Environment.get("AUTH_SESSION_CACHE_REDIS_URL")?.nilIfBlank
            ?? Environment.get("REDIS_URL")?.nilIfBlank

        return AuthSessionCacheConfiguration(
            mode: mode,
            ttlSeconds: ttlSeconds,
            maxEntries: maxEntries,
            redisMaxConnections: redisMaxConnections,
            redisURL: redisURL
        )
    }
}

struct AuthenticatedPrincipal: Codable, Equatable, Sendable {
    let userID: UUID
    let sessionID: UUID
    let deviceID: String?
    let email: String
    let displayName: String?
    let avatarPreset: UserAvatarPreset?
    let refreshExpiresAt: Date

    init(user: User, session: AuthSession) throws {
        self.userID = try user.requireID()
        self.sessionID = try session.requireID()
        self.deviceID = session.deviceID
        self.email = user.email
        self.displayName = user.displayName
        self.avatarPreset = user.avatarPresetEnum
        self.refreshExpiresAt = session.refreshExpiresAt
    }

    func makeUserSnapshot() -> User {
        User(
            id: userID,
            email: email,
            passwordHash: "",
            status: .active,
            displayName: displayName,
            avatarPreset: avatarPreset,
            emailVerifiedAt: nil
        )
    }

    var sessionContext: SessionContext {
        SessionContext(userID: userID, sessionID: sessionID, deviceID: deviceID)
    }
}

protocol AuthSessionValidationCaching: Sendable {
    func principal(
        sessionID: UUID,
        userID: UUID,
        loadFromDatabase: @Sendable () async throws -> AuthenticatedPrincipal
    ) async throws -> AuthenticatedPrincipal
    func store(_ principal: AuthenticatedPrincipal) async
    func invalidate(sessionID: UUID) async
    func invalidate(userID: UUID) async
    func invalidateAll() async
    func shutdown() async
}

actor AuthSessionCacheMetrics {
    struct Snapshot: Sendable {
        var hits: Int = 0
        var misses: Int = 0
        var stores: Int = 0
        var invalidations: Int = 0
        var redisErrors: Int = 0
        var databaseFallbacks: Int = 0
    }

    private var snapshot = Snapshot()

    func recordHit() { snapshot.hits += 1 }
    func recordMiss() { snapshot.misses += 1 }
    func recordStore() { snapshot.stores += 1 }
    func recordInvalidation() { snapshot.invalidations += 1 }
    func recordRedisError() { snapshot.redisErrors += 1 }
    func recordDatabaseFallback() { snapshot.databaseFallbacks += 1 }
    func currentSnapshot() -> Snapshot { snapshot }
}

struct DisabledAuthSessionValidationCache: AuthSessionValidationCaching {
    let metrics: AuthSessionCacheMetrics

    func principal(
        sessionID _: UUID,
        userID _: UUID,
        loadFromDatabase: @Sendable () async throws -> AuthenticatedPrincipal
    ) async throws -> AuthenticatedPrincipal {
        await metrics.recordMiss()
        await metrics.recordDatabaseFallback()
        return try await loadFromDatabase()
    }

    func store(_: AuthenticatedPrincipal) async {}

    func invalidate(sessionID _: UUID) async {}
    func invalidate(userID _: UUID) async {}
    func invalidateAll() async {}
    func shutdown() async {}
}

struct LocalAuthSessionValidationCache: AuthSessionValidationCaching {
    private let store: LocalAuthSessionPrincipalStore
    private let ttlSeconds: Int
    private let metrics: AuthSessionCacheMetrics

    init(ttlSeconds: Int, maxEntries: Int, metrics: AuthSessionCacheMetrics) {
        self.store = LocalAuthSessionPrincipalStore(maxEntries: maxEntries)
        self.ttlSeconds = ttlSeconds
        self.metrics = metrics
    }

    func principal(
        sessionID: UUID,
        userID: UUID,
        loadFromDatabase: @Sendable () async throws -> AuthenticatedPrincipal
    ) async throws -> AuthenticatedPrincipal {
        if let cached = await store.value(sessionID: sessionID, userID: userID) {
            await metrics.recordHit()
            return cached
        }

        await metrics.recordMiss()
        await metrics.recordDatabaseFallback()
        let principal = try await loadFromDatabase()
        await store.store(principal, ttlSeconds: ttlSeconds)
        await metrics.recordStore()
        return principal
    }

    func store(_ principal: AuthenticatedPrincipal) async {
        await store.store(principal, ttlSeconds: ttlSeconds)
        await metrics.recordStore()
    }

    func invalidate(sessionID: UUID) async {
        await store.invalidate(sessionID: sessionID)
        await metrics.recordInvalidation()
    }

    func invalidate(userID: UUID) async {
        await store.invalidate(userID: userID)
        await metrics.recordInvalidation()
    }

    func invalidateAll() async {
        await store.invalidateAll()
        await metrics.recordInvalidation()
    }

    func shutdown() async {}
}

actor LocalAuthSessionPrincipalStore {
    private struct CacheKey: Hashable, Sendable {
        let sessionID: UUID
        let userID: UUID
    }

    private struct Entry: Sendable {
        let principal: AuthenticatedPrincipal
        let expiresAt: Date
        let storedAt: Date
    }

    private let maxEntries: Int
    private var entries: [CacheKey: Entry] = [:]
    private var keysBySessionID: [UUID: Set<CacheKey>] = [:]
    private var keysByUserID: [UUID: Set<CacheKey>] = [:]

    init(maxEntries: Int) {
        self.maxEntries = maxEntries
    }

    func value(sessionID: UUID, userID: UUID, now: Date = Date()) -> AuthenticatedPrincipal? {
        let key = CacheKey(sessionID: sessionID, userID: userID)
        guard let entry = entries[key] else {
            return nil
        }
        guard entry.expiresAt > now, entry.principal.refreshExpiresAt > now else {
            remove(key)
            return nil
        }
        return entry.principal
    }

    func store(_ principal: AuthenticatedPrincipal, ttlSeconds: Int, now: Date = Date()) {
        guard principal.refreshExpiresAt > now else {
            return
        }
        removeExpired(now: now)
        let ttlExpiry = now.addingTimeInterval(TimeInterval(ttlSeconds))
        let key = CacheKey(sessionID: principal.sessionID, userID: principal.userID)
        entries[key] = Entry(
            principal: principal,
            expiresAt: min(ttlExpiry, principal.refreshExpiresAt),
            storedAt: now
        )
        keysBySessionID[principal.sessionID, default: []].insert(key)
        keysByUserID[principal.userID, default: []].insert(key)
        trimIfNeeded()
    }

    func invalidate(sessionID: UUID) {
        for key in keysBySessionID[sessionID] ?? [] {
            remove(key)
        }
    }

    func invalidate(userID: UUID) {
        for key in keysByUserID[userID] ?? [] {
            remove(key)
        }
    }

    func invalidateAll() {
        entries.removeAll()
        keysBySessionID.removeAll()
        keysByUserID.removeAll()
    }

    private func removeExpired(now: Date) {
        for (key, entry) in entries where entry.expiresAt <= now || entry.principal.refreshExpiresAt <= now {
            remove(key)
        }
    }

    private func trimIfNeeded() {
        guard entries.count > maxEntries else {
            return
        }

        let overflow = entries.count - maxEntries
        let keysToRemove = entries
            .sorted { lhs, rhs in lhs.value.storedAt < rhs.value.storedAt }
            .prefix(overflow)
            .map(\.key)
        for key in keysToRemove {
            remove(key)
        }
    }

    private func remove(_ key: CacheKey) {
        entries.removeValue(forKey: key)
        keysBySessionID[key.sessionID]?.remove(key)
        if keysBySessionID[key.sessionID]?.isEmpty == true {
            keysBySessionID.removeValue(forKey: key.sessionID)
        }
        keysByUserID[key.userID]?.remove(key)
        if keysByUserID[key.userID]?.isEmpty == true {
            keysByUserID.removeValue(forKey: key.userID)
        }
    }
}

final class RedisAuthSessionValidationCache: AuthSessionValidationCaching, @unchecked Sendable {
    private struct InvalidationMessage: Codable, Sendable {
        enum Kind: String, Codable, Sendable {
            case session
            case user
            case all
        }

        let sourceNodeID: String
        let kind: Kind
        let id: UUID?
    }

    private let localStore: LocalAuthSessionPrincipalStore
    private let pool: RedisConnectionPool
    private let nodeID: String
    private let ttlSeconds: Int
    private let metrics: AuthSessionCacheMetrics
    private let logger: Logger
    private let channel = RedisChannelName("im:auth:session-cache:invalidate")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(configuration: AuthSessionCacheConfiguration, nodeID: String, logger: Logger, eventLoop: any EventLoop) throws {
        let url = try configuration.redisURL.unwrap(or: AuthSessionValidationCacheError.missingRedisURL)
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
                maximumConnectionCount: .maximumActiveConnections(configuration.redisMaxConnections),
                connectionFactoryConfiguration: factoryConfiguration,
                minimumConnectionCount: 1,
                poolDefaultLogger: logger
            ),
            boundEventLoop: eventLoop
        )
        self.localStore = LocalAuthSessionPrincipalStore(maxEntries: configuration.maxEntries)
        self.nodeID = nodeID
        self.ttlSeconds = configuration.ttlSeconds
        self.metrics = AuthSessionCacheMetrics()
        self.logger = logger
    }

    convenience init(
        configuration: AuthSessionCacheConfiguration,
        nodeID: String,
        logger: Logger,
        eventLoop: any EventLoop,
        metrics: AuthSessionCacheMetrics
    ) throws {
        try self.init(configuration: configuration, nodeID: nodeID, logger: logger, eventLoop: eventLoop)
        self.metricsMirror = metrics
    }

    private var metricsMirror: AuthSessionCacheMetrics?

    func start(app: Application) async throws {
        pool.activate(logger: logger)
        _ = try await pool.leaseConnection { $0.ping() }.get()
        let cache = self
        try await pool.subscribe(
            to: [channel],
            messageReceiver: { _, message in
                guard let rawMessage = message.string else {
                    return
                }
                Task {
                    await cache.applyRemoteInvalidation(rawMessage)
                }
            }
        ).get()
    }

    func principal(
        sessionID: UUID,
        userID: UUID,
        loadFromDatabase: @Sendable () async throws -> AuthenticatedPrincipal
    ) async throws -> AuthenticatedPrincipal {
        if let cached = await localStore.value(sessionID: sessionID, userID: userID) {
            await recordHit()
            return cached
        }

        if let redisCached = await redisValue(sessionID: sessionID, userID: userID) {
            await localStore.store(redisCached, ttlSeconds: ttlSeconds)
            await recordHit()
            return redisCached
        }

        await recordMiss()
        await recordDatabaseFallback()
        let principal = try await loadFromDatabase()
        await localStore.store(principal, ttlSeconds: ttlSeconds)
        await storeInRedis(principal)
        await recordStore()
        return principal
    }

    func store(_ principal: AuthenticatedPrincipal) async {
        await localStore.store(principal, ttlSeconds: ttlSeconds)
        await storeInRedis(principal)
        await recordStore()
    }

    func invalidate(sessionID: UUID) async {
        await localStore.invalidate(sessionID: sessionID)
        await deleteRedisSession(sessionID: sessionID)
        await publish(.init(sourceNodeID: nodeID, kind: .session, id: sessionID))
        await recordInvalidation()
    }

    func invalidate(userID: UUID) async {
        await localStore.invalidate(userID: userID)
        await deleteRedisUser(userID: userID)
        await publish(.init(sourceNodeID: nodeID, kind: .user, id: userID))
        await recordInvalidation()
    }

    func invalidateAll() async {
        await localStore.invalidateAll()
        await publish(.init(sourceNodeID: nodeID, kind: .all, id: nil))
        await recordInvalidation()
    }

    func shutdown() async {
        let promise = pool.eventLoop.makePromise(of: Void.self)
        pool.close(promise: promise, logger: logger)
        try? await promise.futureResult.get()
    }

    fileprivate func applyRemoteInvalidation(_ rawMessage: String) async {
        guard let data = rawMessage.data(using: .utf8),
              let message = try? decoder.decode(InvalidationMessage.self, from: data),
              message.sourceNodeID != nodeID
        else {
            return
        }

        switch message.kind {
        case .session:
            if let sessionID = message.id {
                await localStore.invalidate(sessionID: sessionID)
            }
        case .user:
            if let userID = message.id {
                await localStore.invalidate(userID: userID)
            }
        case .all:
            await localStore.invalidateAll()
        }
    }

    private func redisValue(sessionID: UUID, userID: UUID) async -> AuthenticatedPrincipal? {
        do {
            guard let value = try await pool.get(sessionKey(sessionID: sessionID, userID: userID), as: String.self).get(),
                  let data = value.data(using: .utf8)
            else {
                return nil
            }
            let principal = try decoder.decode(AuthenticatedPrincipal.self, from: data)
            guard principal.sessionID == sessionID,
                  principal.userID == userID,
                  principal.refreshExpiresAt > Date()
            else {
                return nil
            }
            return principal
        } catch {
            await recordRedisError()
            return nil
        }
    }

    private func storeInRedis(_ principal: AuthenticatedPrincipal) async {
        do {
            let data = try encoder.encode(principal)
            guard let value = String(data: data, encoding: .utf8) else {
                return
            }
            let key = sessionKey(sessionID: principal.sessionID, userID: principal.userID)
            _ = try await pool.set(
                key,
                to: value,
                onCondition: .none,
                expiration: .seconds(ttlSeconds)
            ).get()
            _ = try await pool.set(
                sessionIndexKey(sessionID: principal.sessionID),
                to: key.rawValue,
                onCondition: .none,
                expiration: .seconds(ttlSeconds)
            ).get()
            _ = try await pool.sadd(key.rawValue, to: userIndexKey(userID: principal.userID)).get()
            _ = try await pool.expire(userIndexKey(userID: principal.userID), after: .seconds(Int64(ttlSeconds))).get()
        } catch {
            await recordRedisError()
        }
    }

    private func deleteRedisSession(sessionID: UUID) async {
        do {
            let indexKey = sessionIndexKey(sessionID: sessionID)
            if let rawSessionKey = try await pool.get(indexKey, as: String.self).get() {
                _ = try await pool.delete([RedisKey(rawSessionKey), indexKey]).get()
            } else {
                _ = try await pool.delete([indexKey]).get()
            }
        } catch {
            await recordRedisError()
        }
    }

    private func deleteRedisUser(userID: UUID) async {
        do {
            let userKey = userIndexKey(userID: userID)
            let rawKeys = try await pool.smembers(of: userKey, as: String.self).get()
            let keys = rawKeys.compactMap { rawKey -> RedisKey? in
                rawKey.map { RedisKey($0) }
            } + [userKey]
            if !keys.isEmpty {
                _ = try await pool.delete(keys).get()
            }
        } catch {
            await recordRedisError()
        }
    }

    private func publish(_ message: InvalidationMessage) async {
        do {
            let data = try encoder.encode(message)
            guard let value = String(data: data, encoding: .utf8) else {
                return
            }
            _ = try await pool.publish(value, to: channel).get()
        } catch {
            await recordRedisError()
        }
    }

    private func sessionKey(sessionID: UUID, userID: UUID) -> RedisKey {
        RedisKey("im:auth:session:\(userID.uuidString.lowercased()):\(sessionID.uuidString.lowercased())")
    }

    private func sessionIndexKey(sessionID: UUID) -> RedisKey {
        RedisKey("im:auth:session-index:\(sessionID.uuidString.lowercased())")
    }

    private func userIndexKey(userID: UUID) -> RedisKey {
        RedisKey("im:auth:user:\(userID.uuidString.lowercased()):sessions")
    }

    private func recordHit() async {
        await metrics.recordHit()
        await metricsMirror?.recordHit()
    }

    private func recordMiss() async {
        await metrics.recordMiss()
        await metricsMirror?.recordMiss()
    }

    private func recordStore() async {
        await metrics.recordStore()
        await metricsMirror?.recordStore()
    }

    private func recordInvalidation() async {
        await metrics.recordInvalidation()
        await metricsMirror?.recordInvalidation()
    }

    private func recordRedisError() async {
        await metrics.recordRedisError()
        await metricsMirror?.recordRedisError()
    }

    private func recordDatabaseFallback() async {
        await metrics.recordDatabaseFallback()
        await metricsMirror?.recordDatabaseFallback()
    }
}

enum AuthSessionValidationCacheError: Error {
    case missingRedisURL
}

enum AuthSessionValidationCacheFactory {
    static func make(app: Application, configuration: AuthSessionCacheConfiguration) async -> any AuthSessionValidationCaching {
        let metrics = app.authSessionCacheMetrics
        switch configuration.mode {
        case .disabled:
            return DisabledAuthSessionValidationCache(metrics: metrics)
        case .local:
            return LocalAuthSessionValidationCache(
                ttlSeconds: configuration.ttlSeconds,
                maxEntries: configuration.maxEntries,
                metrics: metrics
            )
        case .redis:
            do {
                let cache = try RedisAuthSessionValidationCache(
                    configuration: configuration,
                    nodeID: app.imNodeID,
                    logger: app.logger,
                    eventLoop: app.eventLoopGroup.next(),
                    metrics: metrics
                )
                try await cache.start(app: app)
                app.lifecycle.use(AuthSessionValidationCacheLifecycle(cache: cache))
                return cache
            } catch {
                await metrics.recordRedisError()
                app.logger.warning(
                    "Auth session Redis cache unavailable; falling back to local cache.",
                    metadata: ["error": .string(String(describing: error))]
                )
                return LocalAuthSessionValidationCache(
                    ttlSeconds: configuration.ttlSeconds,
                    maxEntries: configuration.maxEntries,
                    metrics: metrics
                )
            }
        }
    }
}

private struct AuthSessionValidationCacheLifecycle: LifecycleHandler {
    let cache: any AuthSessionValidationCaching

    func shutdownAsync(_ application: Application) async {
        await cache.shutdown()
    }
}

private struct AuthSessionValidationCacheStorageKey: StorageKey {
    typealias Value = any AuthSessionValidationCaching
}

private struct AuthSessionCacheConfigurationStorageKey: StorageKey {
    typealias Value = AuthSessionCacheConfiguration
}

private struct AuthSessionCacheMetricsStorageKey: StorageKey {
    typealias Value = AuthSessionCacheMetrics
}

extension Application {
    var authSessionCacheConfiguration: AuthSessionCacheConfiguration {
        get {
            storage[AuthSessionCacheConfigurationStorageKey.self]
                ?? AuthSessionCacheConfiguration.load(from: environment)
        }
        set { storage[AuthSessionCacheConfigurationStorageKey.self] = newValue }
    }

    var authSessionValidationCache: any AuthSessionValidationCaching {
        get {
            if let cache = storage[AuthSessionValidationCacheStorageKey.self] {
                return cache
            }
            let cache = DisabledAuthSessionValidationCache(metrics: authSessionCacheMetrics)
            storage[AuthSessionValidationCacheStorageKey.self] = cache
            return cache
        }
        set { storage[AuthSessionValidationCacheStorageKey.self] = newValue }
    }

    var authSessionCacheMetrics: AuthSessionCacheMetrics {
        if let metrics = storage[AuthSessionCacheMetricsStorageKey.self] {
            return metrics
        }
        let metrics = AuthSessionCacheMetrics()
        storage[AuthSessionCacheMetricsStorageKey.self] = metrics
        return metrics
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

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
