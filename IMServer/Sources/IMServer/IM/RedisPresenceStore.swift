import Foundation
import NIOCore
import RediStack
import Vapor

final class RedisPresenceStore: PresenceStore, @unchecked Sendable {
    private let pool: RedisConnectionPool
    private let nodeID: String
    private let logger: Logger
    private let heartbeatTimeoutSeconds: Int
    private let routeCache = RedisPresenceRouteCache(ttl: 2)
    private let activeNodeCache = RedisPresenceActiveNodeCache(ttl: 2)
    private let heartbeatThrottle = RedisPresenceHeartbeatThrottle(minimumInterval: 1)
    private var metrics: RoutingMetrics?

    init(pool: RedisConnectionPool, nodeID: String, logger: Logger, heartbeatTimeoutSeconds: Int = 90) {
        self.pool = pool
        self.nodeID = nodeID
        self.logger = logger
        self.heartbeatTimeoutSeconds = heartbeatTimeoutSeconds
    }

    var backendName: String { "redis" }

    func start(app: Application) async throws {
        metrics = app.routingMetrics
        _ = try await pool.sadd(nodeID, to: RedisKey("im:route:active_nodes")).get()
        try await refreshHeartbeat(force: true)
        try await clearStaleNodePresence(for: nodeID)
    }

    func shutdown() async {
        _ = try? await pool.srem(nodeID, from: RedisKey("im:route:active_nodes")).get()
        _ = try? await pool.delete(heartbeatKey(for: nodeID)).get()
        try? await clearStaleNodePresence(for: nodeID)
    }

    func activatePresence(forUserID userID: UUID) async throws {
        try await refreshHeartbeat()
        _ = try await pool.sadd(nodeID, to: userRouteKey(for: userID)).get()
        _ = try await pool.sadd(userID.uuidString.lowercased(), to: nodeUsersKey(for: nodeID)).get()
        await routeCache.store([nodeID], for: userID)
        await activeNodeCache.invalidate()
    }

    func deactivatePresence(forUserID userID: UUID) async throws {
        try await refreshHeartbeat()
        _ = try await pool.srem(nodeID, from: userRouteKey(for: userID)).get()
        _ = try await pool.srem(userID.uuidString.lowercased(), from: nodeUsersKey(for: nodeID)).get()
        await routeCache.invalidate(userID)
    }

    func routeNodeIDs(forUserIDs userIDs: [UUID]) async throws -> [UUID: Set<String>] {
        try await refreshHeartbeat()
        let requestedUserIDs = Set(userIDs)
        let activeNodeIDs = Set(try await cachedActiveNodeIDs())
        var result: [UUID: Set<String>] = [:]

        var uncachedUserIDs: [UUID] = []
        for userID in requestedUserIDs {
            if let cached = await routeCache.nodes(for: userID) {
                await metrics?.recordRedisPresenceRouteCacheHit()
                let activeRoutes = cached.intersection(activeNodeIDs)
                if !activeRoutes.isEmpty {
                    result[userID] = activeRoutes
                }
            } else {
                await metrics?.recordRedisPresenceRouteCacheMiss()
                uncachedUserIDs.append(userID)
            }
        }

        guard !uncachedUserIDs.isEmpty else {
            return result
        }

        let fetchedRoutes = try await fetchRouteNodeIDsByUser(userIDs: uncachedUserIDs)
        for (userID, nodeIDs) in fetchedRoutes {
            let activeRoutes = nodeIDs.intersection(activeNodeIDs)
            await routeCache.store(activeRoutes, for: userID)
            if !activeRoutes.isEmpty {
                result[userID] = activeRoutes
            }
        }
        return result
    }

    func activeNodeIDs() async throws -> Set<String> {
        try await refreshHeartbeat()
        let nodeIDs = try await pool.smembers(of: RedisKey("im:route:active_nodes"), as: String.self).get()
            .compactMap { $0 }
        return Set(try await filterActiveNodeIDs(nodeIDs))
    }

    private func userRouteKey(for userID: UUID) -> RedisKey {
        RedisKey("im:route:user:\(userID.uuidString.lowercased()):nodes")
    }

    private func nodeUsersKey(for nodeID: String) -> RedisKey {
        RedisKey("im:route:node:\(nodeID):users")
    }

    private func heartbeatKey(for nodeID: String) -> RedisKey {
        RedisKey("im:route:node:\(nodeID):heartbeat")
    }

    private func refreshHeartbeat(force: Bool = false) async throws {
        if !force {
            guard await heartbeatThrottle.shouldRefresh() else {
                return
            }
        }
        let timestamp = String(Int(Date().timeIntervalSince1970))
        _ = try await pool.set(heartbeatKey(for: nodeID), to: timestamp).get()
    }

    private func cachedActiveNodeIDs() async throws -> [String] {
        if let cached = await activeNodeCache.nodes() {
            return cached
        }

        let activeNodeIDs = try await filterActiveNodeIDs(
            try await pool.smembers(of: RedisKey("im:route:active_nodes"), as: String.self).get()
                .compactMap { $0 }
        )
        await activeNodeCache.store(activeNodeIDs)
        return activeNodeIDs
    }

    private func fetchRouteNodeIDsByUser(userIDs: [UUID]) async throws -> [UUID: Set<String>] {
        await metrics?.recordRedisPresencePipelineLookup(size: userIDs.count)
        return try await RedisPresenceRouteBatchReader(pool: pool).read(
            userIDs: userIDs,
            keyForUserID: userRouteKey
        )
    }

    private func filterActiveNodeIDs(_ nodeIDs: [String]) async throws -> [String] {
        var activeNodeIDs: [String] = []
        var staleNodeIDs: [String] = []
        let uniqueNodeIDs = Array(Set(nodeIDs)).sorted()
        let heartbeatKeys = uniqueNodeIDs.map(heartbeatKey)
        let rawHeartbeats = try await pool.mget(heartbeatKeys, as: String.self).get()

        for (nodeID, rawHeartbeat) in zip(uniqueNodeIDs, rawHeartbeats) {
            guard let rawHeartbeat,
                  let heartbeatSeconds = Int(rawHeartbeat),
                  Int(Date().timeIntervalSince1970) - heartbeatSeconds <= heartbeatTimeoutSeconds
            else {
                staleNodeIDs.append(nodeID)
                continue
            }
            activeNodeIDs.append(nodeID)
        }

        if !staleNodeIDs.isEmpty {
            await metrics?.recordRedisPresenceStaleCleanup(count: staleNodeIDs.count)
            Task {
                for staleNodeID in staleNodeIDs {
                    try? await self.clearStaleNodePresence(for: staleNodeID)
                    _ = try? await self.pool.srem(staleNodeID, from: RedisKey("im:route:active_nodes")).get()
                    _ = try? await self.pool.delete(self.heartbeatKey(for: staleNodeID)).get()
                }
            }
        }

        return activeNodeIDs
    }

    private func clearStaleNodePresence(for staleNodeID: String) async throws {
        let users = try await pool.smembers(of: nodeUsersKey(for: staleNodeID), as: String.self).get()
            .compactMap { $0 }
        for rawUserID in users {
            _ = try await pool.srem(staleNodeID, from: RedisKey("im:route:user:\(rawUserID):nodes")).get()
            if let userID = UUID(uuidString: rawUserID) {
                await routeCache.invalidate(userID)
            }
        }
        _ = try await pool.delete(nodeUsersKey(for: staleNodeID)).get()
        await activeNodeCache.invalidate()
    }
}

private struct RedisPresenceRouteBatchReader {
    let pool: RedisConnectionPool

    func read(
        userIDs: [UUID],
        keyForUserID: @escaping @Sendable (UUID) -> RedisKey
    ) async throws -> [UUID: Set<String>] {
        guard !userIDs.isEmpty else {
            return [:]
        }

        return try await pool.leaseConnection { connection in
            let futures = userIDs.map { userID in
                connection.smembers(of: keyForUserID(userID), as: String.self)
                    .map { values in
                        (userID, Set(values.compactMap { $0 }))
                    }
            }
            return EventLoopFuture.whenAllSucceed(futures, on: connection.eventLoop)
                .map { pairs in
                    Dictionary(uniqueKeysWithValues: pairs)
                }
        }.get()
    }
}

private actor RedisPresenceHeartbeatThrottle {
    private let minimumInterval: TimeInterval
    private var lastRefreshAt: Date = .distantPast

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    func shouldRefresh(now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(lastRefreshAt) >= minimumInterval else {
            return false
        }
        lastRefreshAt = now
        return true
    }
}

private actor RedisPresenceRouteCache {
    private struct Entry {
        let nodes: Set<String>
        let expiresAt: Date
    }

    private let ttl: TimeInterval
    private var entries: [UUID: Entry] = [:]

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    func nodes(for userID: UUID) -> Set<String>? {
        guard let entry = entries[userID], entry.expiresAt > Date() else {
            entries[userID] = nil
            return nil
        }
        return entry.nodes
    }

    func store(_ nodes: Set<String>, for userID: UUID) {
        entries[userID] = Entry(nodes: nodes, expiresAt: Date().addingTimeInterval(ttl))
    }

    func invalidate(_ userID: UUID) {
        entries[userID] = nil
    }
}

private actor RedisPresenceActiveNodeCache {
    private let ttl: TimeInterval
    private var cachedNodes: [String]?
    private var expiresAt: Date = .distantPast

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    func nodes() -> [String]? {
        guard let cachedNodes, expiresAt > Date() else {
            self.cachedNodes = nil
            return nil
        }
        return cachedNodes
    }

    func store(_ nodes: [String]) {
        cachedNodes = nodes
        expiresAt = Date().addingTimeInterval(ttl)
    }

    func invalidate() {
        cachedNodes = nil
        expiresAt = .distantPast
    }
}
