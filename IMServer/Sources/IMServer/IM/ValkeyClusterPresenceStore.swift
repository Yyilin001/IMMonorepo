import Foundation
import NIOCore
import Valkey
import Vapor

/// Redis Cluster-compatible Presence Store.
///
/// Route ownership determines the hash tag: direct routes use the user or
/// session ID, active-conversation routes use the conversation ID. Node liveness
/// is always checked through a short TTL lease before a stored route is used.
final class ValkeyClusterPresenceStore: PresenceStore, @unchecked Sendable {
    private let client: ValkeyClusterClient
    private let nodeID: String
    private let cellID: String
    private let keyspace: IMRealtimeRedisKeyspace
    private let logger: Logger
    private let heartbeatTimeoutSeconds: Int
    private let activeConversationRouteTTLSeconds: Int
    private let heartbeatThrottle = ValkeyClusterPresenceHeartbeatThrottle(minimumInterval: 1)
    private let activeNodeCache = ValkeyClusterPresenceActiveNodeCache(ttl: 2)
    private var metrics: RoutingMetrics?

    init(
        client: ValkeyClusterClient,
        nodeID: String,
        cellID: String,
        logger: Logger,
        heartbeatTimeoutSeconds: Int,
        activeConversationRouteTTLSeconds: Int
    ) {
        self.client = client
        self.nodeID = nodeID
        self.cellID = cellID
        self.keyspace = IMRealtimeRedisKeyspace(cellID: cellID)
        self.logger = logger
        self.heartbeatTimeoutSeconds = max(1, heartbeatTimeoutSeconds)
        self.activeConversationRouteTTLSeconds = max(
            heartbeatTimeoutSeconds,
            activeConversationRouteTTLSeconds
        )
    }

    var backendName: String { "valkey-cluster" }

    func start(app: Application) async throws {
        metrics = app.routingMetrics
        _ = try await client.sadd(activeNodesKey, members: [nodeID])
        try await refreshHeartbeat(force: true)
    }

    func shutdown() async {
        _ = try? await client.srem(activeNodesKey, members: [nodeID])
        _ = try? await client.del(keys: [nodeHeartbeatKey(for: nodeID)])
    }

    func activatePresence(forUserID userID: UUID) async throws {
        try await refreshHeartbeat()
        let nodeIDsKey = userRouteKey(for: userID)
        _ = try await client.sadd(nodeIDsKey, members: [nodeID])
        try await writePresenceLease(presenceLeaseKey(forUserID: userID))
        try await refreshGlobalCellPresenceLease(forUserID: userID)
        await activeNodeCache.invalidate()
    }

    func deactivatePresence(forUserID userID: UUID) async throws {
        try await refreshHeartbeat()
        _ = try await client.srem(userRouteKey(for: userID), members: [nodeID])
        _ = try await client.del(keys: [presenceLeaseKey(forUserID: userID)])
    }

    func refreshPresence(forUserID userID: UUID) async throws {
        try await refreshHeartbeat()
        try await writePresenceLease(presenceLeaseKey(forUserID: userID))
        try await refreshGlobalCellPresenceLease(forUserID: userID)
    }

    func activatePresence(forSessionID sessionID: UUID, userID: UUID) async throws {
        try await refreshHeartbeat()
        _ = try await client.sadd(sessionRouteKey(for: sessionID), members: [nodeID])
        try await writePresenceLease(presenceLeaseKey(forSessionID: sessionID))
        try await refreshGlobalCellPresenceLease(forSessionID: sessionID)
        await activeNodeCache.invalidate()
    }

    func deactivatePresence(forSessionID sessionID: UUID, userID: UUID) async throws {
        try await refreshHeartbeat()
        _ = try await client.srem(sessionRouteKey(for: sessionID), members: [nodeID])
        _ = try await client.del(keys: [presenceLeaseKey(forSessionID: sessionID)])
    }

    func refreshPresence(forSessionID sessionID: UUID, userID: UUID) async throws {
        try await refreshHeartbeat()
        try await writePresenceLease(presenceLeaseKey(forSessionID: sessionID))
        try await refreshGlobalCellPresenceLease(forSessionID: sessionID)
    }

    func activateConversationPresence(conversationID: UUID, userID: UUID) async throws {
        try await refreshHeartbeat()
        let key = activeConversationRoutesKey(for: conversationID)
        _ = try await client.eval(
            script: Self.addActiveConversationNodeScript,
            keys: [key],
            args: [userID.uuidString.lowercased(), nodeID, String(activeConversationRouteTTLSeconds)]
        )
    }

    func deactivateConversationPresence(conversationID: UUID, userID: UUID) async throws {
        try await refreshHeartbeat()
        let key = activeConversationRoutesKey(for: conversationID)
        _ = try await client.eval(
            script: Self.removeActiveConversationNodeScript,
            keys: [key],
            args: [userID.uuidString.lowercased(), nodeID, String(activeConversationRouteTTLSeconds)]
        )
    }

    func routeNodeIDs(
        forActiveConversationID conversationID: UUID,
        amongUserIDs userIDs: [UUID]
    ) async throws -> [UUID: Set<String>] {
        try await refreshHeartbeat()
        let requestedUserIDs = Array(Set(userIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !requestedUserIDs.isEmpty else {
            return [:]
        }
        await metrics?.recordRedisPresenceActiveConversationNodeIndexLookup(nodeCount: 1)
        let values = try await client.hmget(
            activeConversationRoutesKey(for: conversationID),
            fields: requestedUserIDs.map { $0.uuidString.lowercased() }
        )
        let activeNodes = try await cachedActiveNodeIDs()
        return Self.routes(
            from: zip(requestedUserIDs, values).map { ($0.0, Self.string(from: $0.1)) },
            filteringTo: activeNodes
        )
    }

    func routeNodeIDs(forActiveConversationID conversationID: UUID) async throws -> [UUID: Set<String>] {
        try await refreshHeartbeat()
        await metrics?.recordRedisPresenceActiveConversationNodeIndexLookup(nodeCount: 1)
        let records = try await client.hgetall(activeConversationRoutesKey(for: conversationID))
        let activeNodes = try await cachedActiveNodeIDs()
        let pairs = records.compactMap { record -> (UUID, String?)? in
            guard let userID = UUID(uuidString: Self.string(from: record.key) ?? "") else {
                return nil
            }
            return (userID, Self.string(from: record.value))
        }
        return Self.routes(from: pairs, filteringTo: activeNodes)
    }

    func routeNodeIDs(forUserIDs userIDs: [UUID]) async throws -> [UUID: Set<String>] {
        try await refreshHeartbeat()
        return try await directRoutes(
            identities: userIDs,
            routeKey: userRouteKey,
            presenceLeaseKey: presenceLeaseKey(forUserID:)
        )
    }

    func routeNodeIDs(forSessionIDs sessionIDs: [UUID]) async throws -> [UUID: Set<String>] {
        try await refreshHeartbeat()
        return try await directRoutes(
            identities: sessionIDs,
            routeKey: sessionRouteKey,
            presenceLeaseKey: presenceLeaseKey(forSessionID:)
        )
    }

    func routeCellIDs(forUserIDs userIDs: [UUID]) async throws -> [UUID: Set<String>] {
        try await routeCellIDs(identities: userIDs, keyForIdentity: globalUserCellPresenceKey)
    }

    func routeCellIDs(forSessionIDs sessionIDs: [UUID]) async throws -> [UUID: Set<String>] {
        try await routeCellIDs(identities: sessionIDs, keyForIdentity: globalSessionCellPresenceKey)
    }

    func activeNodeIDs() async throws -> Set<String> {
        try await refreshHeartbeat()
        return try await cachedActiveNodeIDs()
    }

    private func directRoutes(
        identities: [UUID],
        routeKey: (UUID) -> ValkeyKey,
        presenceLeaseKey: (UUID) -> ValkeyKey
    ) async throws -> [UUID: Set<String>] {
        let activeNodes = try await cachedActiveNodeIDs()
        guard !activeNodes.isEmpty else {
            return [:]
        }
        let uniqueIdentities = Array(Set(identities))
        var routes: [UUID: Set<String>] = [:]
        await metrics?.recordRedisPresencePipelineLookup(size: uniqueIdentities.count)
        let routeKeys = uniqueIdentities.map(routeKey)
        let responses = await client.execute(routeKeys.map(SMEMBERS.init))
        for ((identity, routeKey), response) in zip(zip(uniqueIdentities, routeKeys), responses) {
            let nodeIDs = Set(try Self.array(from: response.get()).compactMap(Self.string(from:)))
            let liveNodes = nodeIDs.intersection(activeNodes)
            if !liveNodes.isEmpty {
                routes[identity] = liveNodes
            }
            let staleNodes = nodeIDs.subtracting(activeNodes)
            if !staleNodes.isEmpty {
                _ = try? await client.srem(routeKey, members: Array(staleNodes))
            }
            if liveNodes.isEmpty {
                _ = try? await client.del(keys: [presenceLeaseKey(identity)])
            }
        }
        return routes
    }

    private func routeCellIDs(
        identities: [UUID],
        keyForIdentity: (UUID) -> ValkeyKey
    ) async throws -> [UUID: Set<String>] {
        let now = Int(Date().timeIntervalSince1970)
        var routes: [UUID: Set<String>] = [:]
        for identity in Set(identities) {
            let records = try await client.hgetall(keyForIdentity(identity))
            let cells = Set(records.compactMap { record -> String? in
                guard let cell = Self.string(from: record.key),
                      let rawExpiry = Self.string(from: record.value),
                      let expiry = Int(rawExpiry),
                      expiry >= now,
                      IMRealtimeCellConfiguration.isValid(cellID: cell)
                else {
                    return nil
                }
                return cell
            })
            if !cells.isEmpty {
                routes[identity] = cells
            }
        }
        return routes
    }

    private func cachedActiveNodeIDs() async throws -> Set<String> {
        if let cached = await activeNodeCache.nodes() {
            return cached
        }
        let candidates = Set(try await client.smembers(activeNodesKey).compactMap(Self.string(from:)))
        var activeNodes: Set<String> = []
        var staleNodes: [String] = []
        for candidate in candidates {
            if try await client.get(nodeHeartbeatKey(for: candidate)) != nil {
                activeNodes.insert(candidate)
            } else {
                staleNodes.append(candidate)
            }
        }
        if !staleNodes.isEmpty {
            await metrics?.recordRedisPresenceStaleCleanup(count: staleNodes.count)
            _ = try? await client.srem(activeNodesKey, members: staleNodes)
        }
        await activeNodeCache.store(activeNodes)
        return activeNodes
    }

    private func refreshHeartbeat(force: Bool = false) async throws {
        if !force, !(await heartbeatThrottle.shouldRefresh()) {
            return
        }
        _ = try await client.sadd(activeNodesKey, members: [nodeID])
        try await client.setex(
            nodeHeartbeatKey(for: nodeID),
            seconds: heartbeatTimeoutSeconds,
            value: String(Int(Date().timeIntervalSince1970))
        )
        await activeNodeCache.invalidate()
    }

    private func writePresenceLease(_ key: ValkeyKey) async throws {
        try await client.setex(key, seconds: heartbeatTimeoutSeconds, value: "1")
    }

    private func refreshGlobalCellPresenceLease(forUserID userID: UUID) async throws {
        try await refreshGlobalCellPresenceLease(key: globalUserCellPresenceKey(for: userID))
    }

    private func refreshGlobalCellPresenceLease(forSessionID sessionID: UUID) async throws {
        try await refreshGlobalCellPresenceLease(key: globalSessionCellPresenceKey(for: sessionID))
    }

    private func refreshGlobalCellPresenceLease(key: ValkeyKey) async throws {
        let expiry = Int(Date().timeIntervalSince1970) + heartbeatTimeoutSeconds
        _ = try await client.hset(key, data: [.init(field: cellID, value: String(expiry))])
        _ = try await client.expire(key, seconds: heartbeatTimeoutSeconds)
    }

    private func userRouteKey(for userID: UUID) -> ValkeyKey {
        key(hashedBy: userID.uuidString.lowercased(), suffix: "presence:user:nodes")
    }

    private func sessionRouteKey(for sessionID: UUID) -> ValkeyKey {
        key(hashedBy: sessionID.uuidString.lowercased(), suffix: "presence:session:nodes")
    }

    private func presenceLeaseKey(forUserID userID: UUID) -> ValkeyKey {
        key(hashedBy: userID.uuidString.lowercased(), suffix: "presence:user:node:\(nodeID)")
    }

    private func presenceLeaseKey(forSessionID sessionID: UUID) -> ValkeyKey {
        key(hashedBy: sessionID.uuidString.lowercased(), suffix: "presence:session:node:\(nodeID)")
    }

    private func activeConversationRoutesKey(for conversationID: UUID) -> ValkeyKey {
        key(hashedBy: conversationID.uuidString.lowercased(), suffix: "presence:conversation:active-routes")
    }

    private func globalUserCellPresenceKey(for userID: UUID) -> ValkeyKey {
        ValkeyKey("im:global:presence:user:{\(userID.uuidString.lowercased())}:cells")
    }

    private func globalSessionCellPresenceKey(for sessionID: UUID) -> ValkeyKey {
        ValkeyKey("im:global:presence:session:{\(sessionID.uuidString.lowercased())}:cells")
    }

    private func nodeHeartbeatKey(for nodeID: String) -> ValkeyKey {
        key(hashedBy: nodeID, suffix: "presence:node:heartbeat")
    }

    private var activeNodesKey: ValkeyKey {
        ValkeyKey(keyspace.key("presence:active-nodes"))
    }

    private func key(hashedBy owner: String, suffix: String) -> ValkeyKey {
        ValkeyKey(keyspace.key(hashedBy: owner, suffix: suffix))
    }

    private static func routes(
        from records: [(UUID, String?)],
        filteringTo activeNodes: Set<String>
    ) -> [UUID: Set<String>] {
        var routes: [UUID: Set<String>] = [:]
        for (userID, rawNodeIDs) in records {
            let nodeIDs = Set((rawNodeIDs ?? "").split(separator: ",").map(String.init))
                .intersection(activeNodes)
            if !nodeIDs.isEmpty {
                routes[userID] = nodeIDs
            }
        }
        return routes
    }

    private static func string(from token: RESPToken) -> String? {
        switch token.value {
        case .simpleString(let buffer), .bulkString(let buffer):
            return String(buffer: buffer)
        case .null:
            return nil
        default:
            return nil
        }
    }

    private static func array(from token: RESPToken) throws -> [RESPToken] {
        switch token.value {
        case .array(let values), .set(let values):
            return Array(values)
        case .null:
            return []
        default:
            throw RedisRoutingError.invalidDispatchPayload
        }
    }

    private static let addActiveConversationNodeScript = """
    local current = redis.call('HGET', KEYS[1], ARGV[1])
    local nodes = {}
    for node in string.gmatch(current or '', '([^,]+)') do nodes[node] = true end
    nodes[ARGV[2]] = true
    local result = {}
    for node, _ in pairs(nodes) do table.insert(result, node) end
    table.sort(result)
    redis.call('HSET', KEYS[1], ARGV[1], table.concat(result, ','))
    redis.call('EXPIRE', KEYS[1], tonumber(ARGV[3]))
    return 1
    """

    private static let removeActiveConversationNodeScript = """
    local current = redis.call('HGET', KEYS[1], ARGV[1])
    if not current then return 0 end
    local result = {}
    for node in string.gmatch(current, '([^,]+)') do
      if node ~= ARGV[2] then table.insert(result, node) end
    end
    if #result == 0 then
      redis.call('HDEL', KEYS[1], ARGV[1])
    else
      table.sort(result)
      redis.call('HSET', KEYS[1], ARGV[1], table.concat(result, ','))
      redis.call('EXPIRE', KEYS[1], tonumber(ARGV[3]))
    end
    return 1
    """
}

private actor ValkeyClusterPresenceHeartbeatThrottle {
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

private actor ValkeyClusterPresenceActiveNodeCache {
    private let ttl: TimeInterval
    private var cachedNodes: Set<String>?
    private var expiresAt: Date = .distantPast

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    func nodes() -> Set<String>? {
        guard let cachedNodes, expiresAt > Date() else {
            self.cachedNodes = nil
            return nil
        }
        return cachedNodes
    }

    func store(_ nodes: Set<String>) {
        cachedNodes = nodes
        expiresAt = Date().addingTimeInterval(ttl)
    }

    func invalidate() {
        cachedNodes = nil
        expiresAt = .distantPast
    }
}
