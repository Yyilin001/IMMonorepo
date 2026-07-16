import Foundation
import NIOCore
import RediStack
import Vapor

final class RedisPresenceStore: PresenceStore, @unchecked Sendable {
    private let pool: RedisConnectionPool
    private let nodeID: String
    private let cellID: String
    private let keyspace: IMRealtimeRedisKeyspace
    private let logger: Logger
    private let heartbeatTimeoutSeconds: Int
    private let activeConversationRouteTTLSeconds: Int
    private let routeCache = RedisPresenceRouteCache(ttl: 2)
    private let sessionRouteCache = RedisPresenceRouteCache(ttl: 2)
    private let activeConversationRouteCache: RedisActiveConversationRouteCache
    private let activeNodeCache = RedisPresenceActiveNodeCache(ttl: 2)
    private let heartbeatThrottle = RedisPresenceHeartbeatThrottle(minimumInterval: 1)
    private let globalCellLeaseRefreshThrottle: RedisPresenceHeartbeatThrottle
    private var metrics: RoutingMetrics?

    init(
        pool: RedisConnectionPool,
        nodeID: String,
        cellID: String = IMRealtimeCellConfiguration.defaultCellID,
        logger: Logger,
        heartbeatTimeoutSeconds: Int = 90,
        activeConversationRouteTTLSeconds: Int = 900,
        activeConversationRouteCacheTTLSeconds: Int = 2
    ) {
        self.pool = pool
        self.nodeID = nodeID
        self.cellID = cellID
        self.keyspace = IMRealtimeRedisKeyspace(cellID: cellID)
        self.logger = logger
        self.heartbeatTimeoutSeconds = heartbeatTimeoutSeconds
        self.activeConversationRouteTTLSeconds = max(heartbeatTimeoutSeconds, activeConversationRouteTTLSeconds)
        self.activeConversationRouteCache = RedisActiveConversationRouteCache(
            ttl: TimeInterval(max(0, activeConversationRouteCacheTTLSeconds))
        )
        self.globalCellLeaseRefreshThrottle = RedisPresenceHeartbeatThrottle(
            minimumInterval: TimeInterval(max(5, heartbeatTimeoutSeconds / 3))
        )
    }

    var backendName: String { "redis" }

    func start(app: Application) async throws {
        metrics = app.routingMetrics
        _ = try await pool.sadd(nodeID, to: activeNodesKey).get()
        try await refreshHeartbeat(force: true)
        try await clearStaleNodePresence(for: nodeID)
    }

    func shutdown() async {
        _ = try? await pool.srem(nodeID, from: activeNodesKey).get()
        _ = try? await pool.delete(heartbeatKey(for: nodeID)).get()
        try? await clearStaleNodePresence(for: nodeID)
    }

    func activatePresence(forUserID userID: UUID) async throws {
        try await refreshHeartbeat()
        _ = try await pool.sadd(nodeID, to: userRouteKey(for: userID)).get()
        _ = try await pool.sadd(userID.uuidString.lowercased(), to: nodeUsersKey(for: nodeID)).get()
        try await refreshGlobalCellPresenceLease(forUserID: userID)
        await routeCache.store([nodeID], for: userID)
        await activeNodeCache.invalidate()
    }

    func deactivatePresence(forUserID userID: UUID) async throws {
        try await refreshHeartbeat()
        _ = try await pool.srem(nodeID, from: userRouteKey(for: userID)).get()
        _ = try await pool.srem(userID.uuidString.lowercased(), from: nodeUsersKey(for: nodeID)).get()
        await routeCache.invalidate(userID)
    }

    func refreshPresence(forUserID userID: UUID) async throws {
        try await refreshHeartbeat()
        try await refreshGlobalCellPresenceLease(forUserID: userID)
    }

    func activatePresence(forSessionID sessionID: UUID, userID: UUID) async throws {
        try await refreshHeartbeat()
        _ = try await pool.sadd(nodeID, to: sessionRouteKey(for: sessionID)).get()
        _ = try await pool.sadd(sessionID.uuidString.lowercased(), to: nodeSessionsKey(for: nodeID)).get()
        try await refreshGlobalCellPresenceLease(forSessionID: sessionID)
        await sessionRouteCache.store([nodeID], for: sessionID)
        await activeNodeCache.invalidate()
    }

    func deactivatePresence(forSessionID sessionID: UUID, userID: UUID) async throws {
        try await refreshHeartbeat()
        _ = try await pool.srem(nodeID, from: sessionRouteKey(for: sessionID)).get()
        _ = try await pool.srem(sessionID.uuidString.lowercased(), from: nodeSessionsKey(for: nodeID)).get()
        await sessionRouteCache.invalidate(sessionID)
    }

    func refreshPresence(forSessionID sessionID: UUID, userID: UUID) async throws {
        try await refreshHeartbeat()
        try await refreshGlobalCellPresenceLease(forSessionID: sessionID)
    }

    func activateConversationPresence(conversationID: UUID, userID: UUID) async throws {
        try await refreshHeartbeat()
        let routeKey = activeConversationRouteKey(conversationID: conversationID, userID: userID)
        let nodeIndexKey = nodeActiveConversationUsersKey(for: nodeID)
        let conversationIndexKey = activeConversationUsersKey(conversationID: conversationID)
        let nodeConversationUsersKey = activeConversationNodeUsersKey(
            conversationID: conversationID,
            nodeID: nodeID
        )
        let userIDString = userID.uuidString.lowercased()
        _ = try await pool.sadd(nodeID, to: routeKey).get()
        _ = try await pool.sadd(
            activeConversationRouteEntry(conversationID: conversationID, userID: userID),
            to: nodeIndexKey
        ).get()
        _ = try await pool.sadd(userIDString, to: conversationIndexKey).get()
        _ = try await pool.sadd(userIDString, to: nodeConversationUsersKey).get()
        try await refreshActiveConversationRouteTTL(
            routeKey: routeKey,
            nodeIndexKey: nodeIndexKey,
            conversationIndexKey: conversationIndexKey,
            nodeConversationUsersKey: nodeConversationUsersKey
        )
        await activeConversationRouteCache.store([nodeID], conversationID: conversationID, userID: userID)
        await activeNodeCache.invalidate()
    }

    func deactivateConversationPresence(conversationID: UUID, userID: UUID) async throws {
        try await refreshHeartbeat()
        _ = try await pool.srem(nodeID, from: activeConversationRouteKey(conversationID: conversationID, userID: userID)).get()
        _ = try await pool.srem(
            activeConversationRouteEntry(conversationID: conversationID, userID: userID),
            from: nodeActiveConversationUsersKey(for: nodeID)
        ).get()
        _ = try await pool.srem(userID.uuidString.lowercased(), from: activeConversationUsersKey(conversationID: conversationID)).get()
        let nodeConversationUsersKey = activeConversationNodeUsersKey(
            conversationID: conversationID,
            nodeID: nodeID
        )
        _ = try await pool.srem(userID.uuidString.lowercased(), from: nodeConversationUsersKey).get()
        if try await pool.scard(of: nodeConversationUsersKey).get() == 0 {
            _ = try await pool.delete(nodeConversationUsersKey).get()
        }
        await activeConversationRouteCache.invalidate(conversationID: conversationID, userID: userID)
    }

    func routeNodeIDs(
        forActiveConversationID conversationID: UUID,
        amongUserIDs userIDs: [UUID]
    ) async throws -> [UUID: Set<String>] {
        try await refreshHeartbeat()
        let requestedUserIDs = Set(userIDs)
        let activeNodeIDs = Set(try await cachedActiveNodeIDs())
        guard !requestedUserIDs.isEmpty, !activeNodeIDs.isEmpty else {
            return [:]
        }

        let cachedLookup = await activeConversationRouteCache.nodes(
            conversationID: conversationID,
            userIDs: requestedUserIDs
        )
        if !cachedLookup.cached.isEmpty {
            await metrics?.recordRedisPresenceRouteCacheHit(count: cachedLookup.cached.count)
        }
        if !cachedLookup.missing.isEmpty {
            await metrics?.recordRedisPresenceRouteCacheMiss(count: cachedLookup.missing.count)
        }

        var result: [UUID: Set<String>] = [:]
        for (userID, cachedRoutes) in cachedLookup.cached {
            let activeRoutes = cachedRoutes.intersection(activeNodeIDs)
            if !activeRoutes.isEmpty {
                result[userID] = activeRoutes
            }
        }
        guard !cachedLookup.missing.isEmpty else {
            return result
        }

        let fetchedRoutes = try await activeConversationNodeRoutes(
            conversationID: conversationID,
            requestedUserIDs: cachedLookup.missing,
            activeNodeIDs: activeNodeIDs
        )
        let inactiveUserIDs = cachedLookup.missing.subtracting(fetchedRoutes.keys)
        if !inactiveUserIDs.isEmpty {
            await activeConversationRouteCache.store(
                Dictionary(uniqueKeysWithValues: inactiveUserIDs.map { ($0, Set<String>()) }),
                conversationID: conversationID
            )
        }
        guard !fetchedRoutes.isEmpty else {
            return result
        }

        var routesToCache: [UUID: Set<String>] = [:]
        routesToCache.reserveCapacity(fetchedRoutes.count)
        for (userID, activeRoutes) in fetchedRoutes {
            routesToCache[userID] = activeRoutes
            if !activeRoutes.isEmpty {
                result[userID] = activeRoutes
            }
        }
        await activeConversationRouteCache.store(routesToCache, conversationID: conversationID)
        return result
    }

    func routeNodeIDs(forActiveConversationID conversationID: UUID) async throws -> [UUID: Set<String>] {
        try await refreshHeartbeat()
        let activeNodeIDs = Set(try await cachedActiveNodeIDs())
        guard !activeNodeIDs.isEmpty else {
            return [:]
        }

        let routes = try await activeConversationNodeRoutes(
            conversationID: conversationID,
            activeNodeIDs: activeNodeIDs
        )
        if !routes.isEmpty {
            await activeConversationRouteCache.store(routes, conversationID: conversationID)
        }
        return routes
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

    func routeNodeIDs(forSessionIDs sessionIDs: [UUID]) async throws -> [UUID: Set<String>] {
        try await refreshHeartbeat()
        let requestedSessionIDs = Set(sessionIDs)
        let activeNodeIDs = Set(try await cachedActiveNodeIDs())
        var result: [UUID: Set<String>] = [:]

        var uncachedSessionIDs: [UUID] = []
        for sessionID in requestedSessionIDs {
            if let cached = await sessionRouteCache.nodes(for: sessionID) {
                await metrics?.recordRedisPresenceRouteCacheHit()
                let activeRoutes = cached.intersection(activeNodeIDs)
                if !activeRoutes.isEmpty {
                    result[sessionID] = activeRoutes
                }
            } else {
                await metrics?.recordRedisPresenceRouteCacheMiss()
                uncachedSessionIDs.append(sessionID)
            }
        }

        guard !uncachedSessionIDs.isEmpty else {
            return result
        }

        let fetchedRoutes = try await RedisPresenceRouteBatchReader(pool: pool).read(
            userIDs: uncachedSessionIDs,
            keyForUserID: sessionRouteKey
        )
        for (sessionID, nodeIDs) in fetchedRoutes {
            let activeRoutes = nodeIDs.intersection(activeNodeIDs)
            await sessionRouteCache.store(activeRoutes, for: sessionID)
            if !activeRoutes.isEmpty {
                result[sessionID] = activeRoutes
            }
        }
        return result
    }

    func routeCellIDs(forUserIDs userIDs: [UUID]) async throws -> [UUID: Set<String>] {
        try await routeCellIDs(
            identities: userIDs,
            keyForIdentity: globalUserCellPresenceKey
        )
    }

    func routeCellIDs(forSessionIDs sessionIDs: [UUID]) async throws -> [UUID: Set<String>] {
        try await routeCellIDs(
            identities: sessionIDs,
            keyForIdentity: globalSessionCellPresenceKey
        )
    }

    func activeNodeIDs() async throws -> Set<String> {
        try await refreshHeartbeat()
        let nodeIDs = try await pool.smembers(of: activeNodesKey, as: String.self).get()
            .compactMap { $0 }
        return Set(try await filterActiveNodeIDs(nodeIDs))
    }

    private func userRouteKey(for userID: UUID) -> RedisKey {
        RedisKey(keyspace.key("route:user:\(userID.uuidString.lowercased()):nodes"))
    }

    private func nodeUsersKey(for nodeID: String) -> RedisKey {
        RedisKey(keyspace.key("route:node:\(nodeID):users"))
    }

    private func globalUserCellPresenceKey(for userID: UUID) -> RedisKey {
        RedisKey("im:global:presence:user:{\(userID.uuidString.lowercased())}:cells")
    }

    private func globalSessionCellPresenceKey(for sessionID: UUID) -> RedisKey {
        RedisKey("im:global:presence:session:{\(sessionID.uuidString.lowercased())}:cells")
    }

    private func sessionRouteKey(for sessionID: UUID) -> RedisKey {
        RedisKey(keyspace.key("route:session:\(sessionID.uuidString.lowercased()):nodes"))
    }

    private func nodeSessionsKey(for nodeID: String) -> RedisKey {
        RedisKey(keyspace.key("route:node:\(nodeID):sessions"))
    }

    private func activeConversationRouteKey(conversationID: UUID, userID: UUID) -> RedisKey {
        RedisKey(keyspace.key(
            "route:conversation:\(conversationID.uuidString.lowercased()):user:\(userID.uuidString.lowercased()):nodes"
        ))
    }

    private func nodeActiveConversationUsersKey(for nodeID: String) -> RedisKey {
        RedisKey(keyspace.key("route:node:\(nodeID):active_conversation_users"))
    }

    private func activeConversationUsersKey(conversationID: UUID) -> RedisKey {
        RedisKey(keyspace.key("route:conversation:\(conversationID.uuidString.lowercased()):active_users"))
    }

    private func activeConversationNodeUsersKey(conversationID: UUID, nodeID: String) -> RedisKey {
        RedisKey(keyspace.key(
            "route:conversation:\(conversationID.uuidString.lowercased()):node:\(nodeID):active_users"
        ))
    }

    private func activeConversationRouteEntry(conversationID: UUID, userID: UUID) -> String {
        "\(conversationID.uuidString.lowercased()):\(userID.uuidString.lowercased())"
    }

    private func refreshActiveConversationRouteTTL(
        routeKey: RedisKey,
        nodeIndexKey: RedisKey,
        conversationIndexKey: RedisKey,
        nodeConversationUsersKey: RedisKey
    ) async throws {
        let ttl = Int64(activeConversationRouteTTLSeconds)
        _ = try await pool.expire(routeKey, after: .seconds(ttl)).get()
        _ = try await pool.expire(nodeIndexKey, after: .seconds(ttl)).get()
        _ = try await pool.expire(conversationIndexKey, after: .seconds(ttl)).get()
        _ = try await pool.expire(nodeConversationUsersKey, after: .seconds(ttl)).get()
    }

    private func activeConversationNodeRoutes(
        conversationID: UUID,
        requestedUserIDs: Set<UUID>,
        activeNodeIDs: Set<String>
    ) async throws -> [UUID: Set<String>] {
        guard !requestedUserIDs.isEmpty, !activeNodeIDs.isEmpty else {
            return [:]
        }

        await metrics?.recordRedisPresenceActiveConversationNodeIndexLookup(nodeCount: activeNodeIDs.count)
        let nodeIDs = activeNodeIDs.sorted()
        let requestedUserIDStrings = requestedUserIDs
            .map { $0.uuidString.lowercased() }
            .sorted()
        let script = """
        local nodeCount = tonumber(ARGV[1])
        local result = {}
        for userIndex = 2 + nodeCount, #ARGV do
          local userID = ARGV[userIndex]
          local nodeHits = {}
          for nodeIndex = 1, nodeCount do
            if redis.call('SISMEMBER', KEYS[nodeIndex], userID) == 1 then
              table.insert(nodeHits, ARGV[1 + nodeIndex])
            end
          end
          if #nodeHits > 0 then
            table.insert(result, userID)
            table.insert(result, table.concat(nodeHits, ','))
          end
        end
        return result
        """
        var arguments: [RESPValue] = [
            .init(from: script),
            .init(from: nodeIDs.count)
        ]
        arguments.append(
            contentsOf: nodeIDs.map {
                .init(from: activeConversationNodeUsersKey(conversationID: conversationID, nodeID: $0))
            }
        )
        arguments.append(.init(from: nodeIDs.count))
        arguments.append(contentsOf: nodeIDs.map { .init(from: $0) })
        arguments.append(contentsOf: requestedUserIDStrings.map { .init(from: $0) })

        let values = try await pool.leaseConnection { connection in
            connection.send(command: "EVAL", with: arguments)
                .map { response in
                    response.array?.compactMap(\.string) ?? []
                }
        }.get()
        var routes: [UUID: Set<String>] = [:]
        var index = values.startIndex
        while index < values.endIndex {
            let userIDValue = values[index]
            let nextIndex = values.index(after: index)
            guard nextIndex < values.endIndex else {
                break
            }
            let nodeIDsValue = values[nextIndex]
            if let userID = UUID(uuidString: userIDValue) {
                let routeNodeIDs = nodeIDsValue
                    .split(separator: ",")
                    .map(String.init)
                if !routeNodeIDs.isEmpty {
                    routes[userID] = Set(routeNodeIDs)
                }
            }
            index = values.index(after: nextIndex)
        }
        return routes
    }

    private func activeConversationNodeRoutes(
        conversationID: UUID,
        activeNodeIDs: Set<String>
    ) async throws -> [UUID: Set<String>] {
        guard !activeNodeIDs.isEmpty else {
            return [:]
        }

        await metrics?.recordRedisPresenceActiveConversationNodeIndexLookup(nodeCount: activeNodeIDs.count)
        let nodeIDs = activeNodeIDs.sorted()
        let script = """
        local nodeCount = tonumber(ARGV[1])
        local routesByUser = {}
        local userIDs = {}
        for nodeIndex = 1, nodeCount do
          local nodeID = ARGV[1 + nodeIndex]
          local users = redis.call('SMEMBERS', KEYS[nodeIndex])
          for _, userID in ipairs(users) do
            if routesByUser[userID] == nil then
              routesByUser[userID] = {}
              table.insert(userIDs, userID)
            end
            table.insert(routesByUser[userID], nodeID)
          end
        end
        table.sort(userIDs)
        local result = {}
        for _, userID in ipairs(userIDs) do
          table.insert(result, userID)
          table.insert(result, table.concat(routesByUser[userID], ','))
        end
        return result
        """
        var arguments: [RESPValue] = [
            .init(from: script),
            .init(from: nodeIDs.count)
        ]
        arguments.append(
            contentsOf: nodeIDs.map {
                .init(from: activeConversationNodeUsersKey(conversationID: conversationID, nodeID: $0))
            }
        )
        arguments.append(.init(from: nodeIDs.count))
        arguments.append(contentsOf: nodeIDs.map { .init(from: $0) })

        let values = try await pool.leaseConnection { connection in
            connection.send(command: "EVAL", with: arguments)
                .map { response in
                    response.array?.compactMap(\.string) ?? []
                }
        }.get()
        return activeConversationRoutes(from: values)
    }

    private func activeConversationRoutes(from values: [String]) -> [UUID: Set<String>] {
        var routes: [UUID: Set<String>] = [:]
        var index = values.startIndex
        while index < values.endIndex {
            let userIDValue = values[index]
            let nextIndex = values.index(after: index)
            guard nextIndex < values.endIndex else {
                break
            }
            let nodeIDsValue = values[nextIndex]
            if let userID = UUID(uuidString: userIDValue) {
                let routeNodeIDs = nodeIDsValue
                    .split(separator: ",")
                    .map(String.init)
                if !routeNodeIDs.isEmpty {
                    routes[userID] = Set(routeNodeIDs)
                }
            }
            index = values.index(after: nextIndex)
        }
        return routes
    }

    private func heartbeatKey(for nodeID: String) -> RedisKey {
        RedisKey(keyspace.key("route:node:\(nodeID):heartbeat"))
    }

    private func refreshHeartbeat(force: Bool = false) async throws {
        if !force {
            guard await heartbeatThrottle.shouldRefresh() else {
                return
            }
        }
        let timestamp = String(Int(Date().timeIntervalSince1970))
        _ = try await pool.set(heartbeatKey(for: nodeID), to: timestamp).get()
        try await refreshGlobalCellPresenceLeasesIfNeeded()
    }

    private func refreshGlobalCellPresenceLeasesIfNeeded() async throws {
        guard await globalCellLeaseRefreshThrottle.shouldRefresh() else {
            return
        }
        let rawUserIDs = try await pool.smembers(of: nodeUsersKey(for: nodeID), as: String.self).get()
            .compactMap { $0 }
        let rawSessionIDs = try await pool.smembers(of: nodeSessionsKey(for: nodeID), as: String.self).get()
            .compactMap { $0 }
        let userIDs = rawUserIDs.compactMap(UUID.init(uuidString:))
        let sessionIDs = rawSessionIDs.compactMap(UUID.init(uuidString:))
        try await refreshGlobalCellPresenceLeases(
            identities: userIDs,
            keyForIdentity: globalUserCellPresenceKey
        )
        try await refreshGlobalCellPresenceLeases(
            identities: sessionIDs,
            keyForIdentity: globalSessionCellPresenceKey
        )
    }

    private func refreshGlobalCellPresenceLease(forUserID userID: UUID) async throws {
        try await refreshGlobalCellPresenceLeases(
            identities: [userID],
            keyForIdentity: globalUserCellPresenceKey
        )
    }

    private func refreshGlobalCellPresenceLease(forSessionID sessionID: UUID) async throws {
        try await refreshGlobalCellPresenceLeases(
            identities: [sessionID],
            keyForIdentity: globalSessionCellPresenceKey
        )
    }

    private func refreshGlobalCellPresenceLeases(
        identities: [UUID],
        keyForIdentity: @escaping @Sendable (UUID) -> RedisKey
    ) async throws {
        guard !identities.isEmpty else {
            return
        }
        let expiresAt = Int(Date().timeIntervalSince1970) + heartbeatTimeoutSeconds
        let ttl = TimeAmount.seconds(Int64(heartbeatTimeoutSeconds))
        try await pool.leaseConnection { connection in
            let operations = identities.flatMap { identity -> [EventLoopFuture<Void>] in
                let key = keyForIdentity(identity)
                return [
                    connection.hset(self.cellID, to: expiresAt, in: key).map { _ in () },
                    connection.expire(key, after: ttl).map { _ in () }
                ]
            }
            return EventLoopFuture.andAllSucceed(operations, on: connection.eventLoop)
        }.get()
    }

    private func routeCellIDs(
        identities: [UUID],
        keyForIdentity: @escaping @Sendable (UUID) -> RedisKey
    ) async throws -> [UUID: Set<String>] {
        let uniqueIdentities = Array(Set(identities))
        guard !uniqueIdentities.isEmpty else {
            return [:]
        }
        let now = Int(Date().timeIntervalSince1970)
        let records = try await pool.leaseConnection { connection in
            let operations = uniqueIdentities.map { identity in
                connection.hgetall(from: keyForIdentity(identity), as: String.self)
                    .map { values in (identity, values) }
            }
            return EventLoopFuture.whenAllSucceed(operations, on: connection.eventLoop)
        }.get()

        var routes: [UUID: Set<String>] = [:]
        for (identity, leases) in records {
            let liveCells = Set(leases.compactMap { cellID, rawExpiry -> String? in
                guard let rawExpiry, let expiry = Int(rawExpiry), expiry >= now else {
                    return nil
                }
                return IMRealtimeCellConfiguration.isValid(cellID: cellID) ? cellID : nil
            })
            if !liveCells.isEmpty {
                routes[identity] = liveCells
            }
        }
        return routes
    }

    private func cachedActiveNodeIDs() async throws -> [String] {
        if let cached = await activeNodeCache.nodes() {
            return cached
        }

        let activeNodeIDs = try await filterActiveNodeIDs(
            try await pool.smembers(of: activeNodesKey, as: String.self).get()
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
                    _ = try? await self.pool.srem(staleNodeID, from: self.activeNodesKey).get()
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
            _ = try await pool.srem(staleNodeID, from: RedisKey(keyspace.key("route:user:\(rawUserID):nodes"))).get()
            if let userID = UUID(uuidString: rawUserID) {
                await routeCache.invalidate(userID)
            }
        }
        let sessions = try await pool.smembers(of: nodeSessionsKey(for: staleNodeID), as: String.self).get()
            .compactMap { $0 }
        for rawSessionID in sessions {
            _ = try await pool.srem(staleNodeID, from: RedisKey(keyspace.key("route:session:\(rawSessionID):nodes"))).get()
            if let sessionID = UUID(uuidString: rawSessionID) {
                await sessionRouteCache.invalidate(sessionID)
            }
        }
        let activeConversationUsers = try await pool.smembers(
            of: nodeActiveConversationUsersKey(for: staleNodeID),
            as: String.self
        ).get().compactMap { $0 }
        for rawEntry in activeConversationUsers {
            let parts = rawEntry.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let conversationID = UUID(uuidString: parts[0]),
                  let userID = UUID(uuidString: parts[1])
            else {
                continue
            }
            _ = try await pool.srem(
                staleNodeID,
                from: activeConversationRouteKey(conversationID: conversationID, userID: userID)
            ).get()
            _ = try await pool.srem(
                userID.uuidString.lowercased(),
                from: activeConversationUsersKey(conversationID: conversationID)
            ).get()
            _ = try await pool.srem(
                userID.uuidString.lowercased(),
                from: activeConversationNodeUsersKey(conversationID: conversationID, nodeID: staleNodeID)
            ).get()
            await activeConversationRouteCache.invalidate(conversationID: conversationID, userID: userID)
        }
        _ = try await pool.delete(nodeUsersKey(for: staleNodeID)).get()
        _ = try await pool.delete(nodeSessionsKey(for: staleNodeID)).get()
        _ = try await pool.delete(nodeActiveConversationUsersKey(for: staleNodeID)).get()
        await activeNodeCache.invalidate()
    }

    private var activeNodesKey: RedisKey {
        RedisKey(keyspace.key("route:active_nodes"))
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

actor RedisActiveConversationRouteCache {
    private struct Key: Hashable {
        let conversationID: UUID
        let userID: UUID
    }

    private struct Entry {
        let nodes: Set<String>
        let expiresAt: Date
    }

    private let ttl: TimeInterval
    private var entries: [Key: Entry] = [:]

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    func nodes(
        conversationID: UUID,
        userIDs: Set<UUID>
    ) -> (cached: [UUID: Set<String>], missing: Set<UUID>) {
        guard ttl > 0, !userIDs.isEmpty else {
            return ([:], userIDs)
        }

        let now = Date()
        var cached: [UUID: Set<String>] = [:]
        cached.reserveCapacity(userIDs.count)
        var missing: Set<UUID> = []
        missing.reserveCapacity(userIDs.count)
        for userID in userIDs {
            let key = Key(conversationID: conversationID, userID: userID)
            guard let entry = entries[key] else {
                missing.insert(userID)
                continue
            }
            guard entry.expiresAt > now else {
                entries[key] = nil
                missing.insert(userID)
                continue
            }
            cached[userID] = entry.nodes
        }
        return (cached, missing)
    }

    func store(_ nodes: Set<String>, conversationID: UUID, userID: UUID) {
        guard ttl > 0 else {
            return
        }
        entries[Key(conversationID: conversationID, userID: userID)] = Entry(
            nodes: nodes,
            expiresAt: Date().addingTimeInterval(ttl)
        )
    }

    func store(_ routesByUserID: [UUID: Set<String>], conversationID: UUID) {
        guard ttl > 0, !routesByUserID.isEmpty else {
            return
        }
        let expiresAt = Date().addingTimeInterval(ttl)
        for (userID, nodes) in routesByUserID {
            entries[Key(conversationID: conversationID, userID: userID)] = Entry(
                nodes: nodes,
                expiresAt: expiresAt
            )
        }
    }

    func invalidate(conversationID: UUID, userID: UUID) {
        entries[Key(conversationID: conversationID, userID: userID)] = nil
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
