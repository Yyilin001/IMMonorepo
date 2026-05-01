import Foundation
import NIOCore
import NIOPosix
import RediStack
import Vapor

struct NodeMessageDispatchEnvelope: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        case message
        case conversationEvent
        case contactEvent
        case kickSession
        case kickUser
    }

    let action: Action
    let packetType: IMTCPPacketType?
    let requestID: UUID?
    let payloadJSON: String?
    let targetUserIDs: [UUID]
    let sessionID: UUID?
    let kickReason: IMTCPKickReason?
    let kickMessage: String?
}

protocol PresenceStore: Sendable {
    var backendName: String { get }
    func start(app: Application) async throws
    func shutdown() async
    func activatePresence(forUserID userID: UUID) async throws
    func deactivatePresence(forUserID userID: UUID) async throws
    func routeNodeIDs(forUserIDs userIDs: [UUID]) async throws -> [UUID: Set<String>]
    func activeNodeIDs() async throws -> Set<String>
}

protocol NodeMessageDispatchService: Sendable {
    func start(app: Application) async throws
    func shutdown() async
    func dispatch(_ envelope: NodeMessageDispatchEnvelope, toNodeID nodeID: String) async throws
}

protocol ConnectionRoutingBackend: Sendable {
    var backendName: String { get }
    var presenceStore: any PresenceStore { get }
    var dispatchService: any NodeMessageDispatchService { get }
    func start(app: Application) async throws
    func shutdown() async
}

struct LocalPresenceStore: PresenceStore {
    let nodeID: String

    var backendName: String { "local" }

    func start(app: Application) async throws {}
    func shutdown() async {}
    func activatePresence(forUserID userID: UUID) async throws {}
    func deactivatePresence(forUserID userID: UUID) async throws {}
    func routeNodeIDs(forUserIDs userIDs: [UUID]) async throws -> [UUID: Set<String>] { [:] }
    func activeNodeIDs() async throws -> Set<String> { [] }
}

struct LocalNodeMessageDispatchService: NodeMessageDispatchService {
    func start(app: Application) async throws {}
    func shutdown() async {}
    func dispatch(_ envelope: NodeMessageDispatchEnvelope, toNodeID nodeID: String) async throws {}
}

final class RedisPresenceStore: PresenceStore, @unchecked Sendable {
    private let pool: RedisConnectionPool
    private let nodeID: String
    private let logger: Logger
    private let heartbeatTimeoutSeconds: Int

    init(pool: RedisConnectionPool, nodeID: String, logger: Logger, heartbeatTimeoutSeconds: Int = 90) {
        self.pool = pool
        self.nodeID = nodeID
        self.logger = logger
        self.heartbeatTimeoutSeconds = heartbeatTimeoutSeconds
    }

    var backendName: String { "redis" }

    func start(app: Application) async throws {
        _ = try await pool.sadd(nodeID, to: RedisKey("im:route:active_nodes")).get()
        try await refreshHeartbeat()
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
    }

    func deactivatePresence(forUserID userID: UUID) async throws {
        try await refreshHeartbeat()
        _ = try await pool.srem(nodeID, from: userRouteKey(for: userID)).get()
        _ = try await pool.srem(userID.uuidString.lowercased(), from: nodeUsersKey(for: nodeID)).get()
    }

    func routeNodeIDs(forUserIDs userIDs: [UUID]) async throws -> [UUID: Set<String>] {
        try await refreshHeartbeat()
        let activeNodeIDs = try await filterActiveNodeIDs(
            try await pool.smembers(of: RedisKey("im:route:active_nodes"), as: String.self).get()
                .compactMap { $0 }
        )
        let requestedUserIDs = Set(userIDs)
        var result: [UUID: Set<String>] = [:]
        for activeNodeID in activeNodeIDs {
            let nodeUserIDs = try await pool.smembers(of: nodeUsersKey(for: activeNodeID), as: String.self).get()
                .compactMap { $0 }
                .compactMap(UUID.init(uuidString:))
            for userID in nodeUserIDs where requestedUserIDs.contains(userID) {
                result[userID, default: []].insert(activeNodeID)
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

    private func refreshHeartbeat() async throws {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        _ = try await pool.set(heartbeatKey(for: nodeID), to: timestamp).get()
    }

    private func filterActiveNodeIDs(_ nodeIDs: [String]) async throws -> [String] {
        var activeNodeIDs: [String] = []
        var staleNodeIDs: [String] = []

        for nodeID in Set(nodeIDs) {
            let rawHeartbeat = try await pool.get(heartbeatKey(for: nodeID), as: String.self).get()
            guard let rawHeartbeat,
                  let heartbeatSeconds = Int(rawHeartbeat),
                  Int(Date().timeIntervalSince1970) - heartbeatSeconds <= heartbeatTimeoutSeconds
            else {
                staleNodeIDs.append(nodeID)
                continue
            }
            activeNodeIDs.append(nodeID)
        }

        for staleNodeID in staleNodeIDs {
            try await clearStaleNodePresence(for: staleNodeID)
            _ = try await pool.srem(staleNodeID, from: RedisKey("im:route:active_nodes")).get()
            _ = try await pool.delete(heartbeatKey(for: staleNodeID)).get()
        }

        return activeNodeIDs
    }

    private func clearStaleNodePresence(for staleNodeID: String) async throws {
        let users = try await pool.smembers(of: nodeUsersKey(for: staleNodeID), as: String.self).get()
            .compactMap { $0 }
        for rawUserID in users {
            _ = try await pool.srem(staleNodeID, from: RedisKey("im:route:user:\(rawUserID):nodes")).get()
        }
        _ = try await pool.delete(nodeUsersKey(for: staleNodeID)).get()
    }
}

final class RedisNodeMessageDispatchService: NodeMessageDispatchService, @unchecked Sendable {
    private let pool: RedisConnectionPool
    private let nodeID: String
    private let dispatchChannel: RedisChannelName
    private let logger: Logger

    init(pool: RedisConnectionPool, nodeID: String, logger: Logger) {
        self.pool = pool
        self.nodeID = nodeID
        self.dispatchChannel = RedisChannelName("im:dispatch:node:\(nodeID)")
        self.logger = logger
    }

    func start(app: Application) async throws {
        try await pool.subscribe(
            to: [dispatchChannel],
            messageReceiver: { [weak app] _, message in
                guard let app, let rawEnvelope = message.string else {
                    return
                }
                Task {
                    do {
                        let envelope = try JSONDecoder().decode(NodeMessageDispatchEnvelope.self, from: Data(rawEnvelope.utf8))
                        await app.connectionRoutingService.handleRemoteDispatch(envelope)
                    } catch {
                        app.logger.warning(
                            "Failed to decode remote IM dispatch envelope",
                            metadata: [
                                "node_id": .string(app.imNodeID),
                                "route_backend": .string("redis"),
                                "error": .string(String(describing: error))
                            ]
                        )
                    }
                }
            }
        ).get()
    }

    func shutdown() async {}

    func dispatch(_ envelope: NodeMessageDispatchEnvelope, toNodeID nodeID: String) async throws {
        let payload = try JSONEncoder().encode(envelope)
        guard let encoded = String(data: payload, encoding: .utf8) else {
            throw RedisRoutingError.invalidDispatchPayload
        }
        _ = try await pool.publish(encoded, to: RedisChannelName("im:dispatch:node:\(nodeID)")).get()
    }
}

struct LocalConnectionRoutingBackend: ConnectionRoutingBackend {
    let nodeID: String
    let presenceStore: any PresenceStore
    let dispatchService: any NodeMessageDispatchService

    init(nodeID: String) {
        self.nodeID = nodeID
        self.presenceStore = LocalPresenceStore(nodeID: nodeID)
        self.dispatchService = LocalNodeMessageDispatchService()
    }

    var backendName: String { "local" }

    func start(app: Application) async throws {
        try await presenceStore.start(app: app)
        try await dispatchService.start(app: app)
    }

    func shutdown() async {
        await dispatchService.shutdown()
        await presenceStore.shutdown()
    }
}

final class RedisConnectionRoutingBackend: ConnectionRoutingBackend, @unchecked Sendable {
    let presenceStore: any PresenceStore
    let dispatchService: any NodeMessageDispatchService

    private let pool: RedisConnectionPool
    private let logger: Logger

    init(configuration: IMRedisRoutingConfiguration, nodeID: String, logger: Logger, eventLoop: any EventLoop) throws {
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
        let pool = RedisConnectionPool(
            configuration: .init(
                initialServerConnectionAddresses: [address],
                maximumConnectionCount: .maximumActiveConnections(configuration.maximumConnectionCount),
                connectionFactoryConfiguration: factoryConfiguration,
                minimumConnectionCount: 1,
                poolDefaultLogger: logger
            ),
            boundEventLoop: eventLoop
        )
        self.pool = pool
        self.presenceStore = RedisPresenceStore(pool: pool, nodeID: nodeID, logger: logger)
        self.dispatchService = RedisNodeMessageDispatchService(pool: pool, nodeID: nodeID, logger: logger)
    }

    var backendName: String { "redis" }

    func start(app: Application) async throws {
        pool.activate(logger: logger)
        _ = try await pool.leaseConnection { $0.ping() }.get()
        try await presenceStore.start(app: app)
        try await dispatchService.start(app: app)
    }

    func shutdown() async {
        await dispatchService.shutdown()
        await presenceStore.shutdown()
        let promise = pool.eventLoop.makePromise(of: Void.self)
        pool.close(promise: promise, logger: logger)
        try? await promise.futureResult.get()
    }
}

enum RedisRoutingError: Error {
    case invalidURL(String)
    case invalidDispatchPayload
    case redisRequiredInProduction
}

struct IMRedisRoutingConfiguration: Sendable {
    let url: String?
    let mode: IMRoutingMode
    let maximumConnectionCount: Int

    static func load(from environment: Environment) -> IMRedisRoutingConfiguration {
        let explicitMode = Environment.get("IM_ROUTING_MODE").flatMap(IMRoutingMode.init(rawValue:))
        let url = Environment.get("REDIS_URL")
        let mode = explicitMode ?? (url == nil ? .local : .redis)
        let maximumConnectionCount = max(2, Environment.get("IM_REDIS_MAX_CONNECTIONS").flatMap(Int.init(_:)) ?? 8)
        return IMRedisRoutingConfiguration(url: url, mode: mode, maximumConnectionCount: maximumConnectionCount)
    }

    func requireURL() throws -> String {
        guard let url, !url.isEmpty else {
            throw RedisRoutingError.redisRequiredInProduction
        }
        return url
    }
}

enum IMRoutingMode: String, Sendable {
    case local
    case redis
}

actor RoutingMetrics {
    struct Snapshot: Sendable {
        var currentTCPConnectionCount: Int = 0
        var redisRouteRegistrations: Int = 0
        var crossNodeDispatchCount: Int = 0
        var crossNodeDispatchFailureCount: Int = 0
    }

    private var snapshot = Snapshot()

    func recordPresenceRegistration() {
        snapshot.redisRouteRegistrations += 1
    }

    func recordCurrentTCPConnectionCount(_ count: Int) {
        snapshot.currentTCPConnectionCount = count
    }

    func recordCrossNodeDispatchSucceeded() {
        snapshot.crossNodeDispatchCount += 1
    }

    func recordCrossNodeDispatchFailed() {
        snapshot.crossNodeDispatchFailureCount += 1
    }

    func currentSnapshot() -> Snapshot {
        snapshot
    }
}

struct ConnectionRoutingService {
    let app: Application
    let nodeID: String
    let backend: any ConnectionRoutingBackend

    init(app: Application, backend: any ConnectionRoutingBackend) {
        self.app = app
        self.nodeID = app.imNodeID
        self.backend = backend
    }

    var routeBackendName: String { backend.backendName }

    func bind(_ connection: IMAuthenticatedConnection, control: IMConnectionControl) async throws {
        await app.imConnectionRegistry.bind(connection, control: control)
        await app.routingMetrics.recordCurrentTCPConnectionCount(await app.imConnectionRegistry.totalConnectionCount())
        if await app.imConnectionRegistry.localConnectionCount(forUserID: connection.userID) == 1 {
            try await backend.presenceStore.activatePresence(forUserID: connection.userID)
            await app.routingMetrics.recordPresenceRegistration()
        }
    }

    func remove(connectionID: UUID) async {
        guard let removed = await app.imConnectionRegistry.remove(connectionID: connectionID) else {
            return
        }

        await app.routingMetrics.recordCurrentTCPConnectionCount(await app.imConnectionRegistry.totalConnectionCount())
        if await app.imConnectionRegistry.localConnectionCount(forUserID: removed.userID) == 0 {
            try? await backend.presenceStore.deactivatePresence(forUserID: removed.userID)
        }
    }

    func sendMessage(
        _ payload: IMTCPMessagePayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID? = UUID()
    ) async {
        await app.imConnectionRegistry.sendMessage(payload, toUserIDs: userIDs, requestID: requestID)
        let envelope = try? encodePacketEnvelope(
            action: .message,
            packetType: .message,
            requestID: requestID,
            payload: payload,
            targetUserIDs: userIDs
        )
        await dispatchRemoteEnvelopeIfNeeded(envelope, forUserIDs: userIDs)
    }

    func sendConversationEvent(
        _ payload: IMTCPConversationEventPayload,
        toUserID userID: UUID,
        requestID: UUID? = UUID()
    ) async {
        await app.imConnectionRegistry.sendConversationEvent(payload, toUserID: userID, requestID: requestID)
        let envelope = try? encodePacketEnvelope(
            action: .conversationEvent,
            packetType: .conversationEvent,
            requestID: requestID,
            payload: payload,
            targetUserIDs: [userID]
        )
        await dispatchRemoteEnvelopeIfNeeded(envelope, forUserIDs: [userID])
    }

    func sendContactEvent(
        _ payload: IMTCPContactEventPayload,
        toUserID userID: UUID,
        requestID: UUID? = UUID()
    ) async {
        await app.imConnectionRegistry.sendContactEvent(payload, toUserID: userID, requestID: requestID)
        let envelope = try? encodePacketEnvelope(
            action: .contactEvent,
            packetType: .contactEvent,
            requestID: requestID,
            payload: payload,
            targetUserIDs: [userID]
        )
        await dispatchRemoteEnvelopeIfNeeded(envelope, forUserIDs: [userID])
    }

    func kickConnections(
        forSessionID sessionID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        await app.imConnectionRegistry.kickConnections(forSessionID: sessionID, reason: reason, message: message)
        let envelope = NodeMessageDispatchEnvelope(
            action: .kickSession,
            packetType: nil,
            requestID: nil,
            payloadJSON: nil,
            targetUserIDs: [],
            sessionID: sessionID,
            kickReason: reason,
            kickMessage: message
        )
        await broadcastToAllNodes(envelope)
    }

    func kickConnections(
        forUserID userID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        await app.imConnectionRegistry.kickConnections(forUserID: userID, reason: reason, message: message)
        let envelope = NodeMessageDispatchEnvelope(
            action: .kickUser,
            packetType: nil,
            requestID: nil,
            payloadJSON: nil,
            targetUserIDs: [userID],
            sessionID: nil,
            kickReason: reason,
            kickMessage: message
        )
        await dispatchRemoteEnvelopeIfNeeded(envelope, forUserIDs: [userID], includeLocalNode: false)
    }

    func handleRemoteDispatch(_ envelope: NodeMessageDispatchEnvelope) async {
        switch envelope.action {
        case .message:
            guard let payload: IMTCPMessagePayload = decodePayload(from: envelope) else { return }
            await app.imConnectionRegistry.sendMessage(
                payload,
                toUserIDs: envelope.targetUserIDs,
                requestID: envelope.requestID
            )
        case .conversationEvent:
            guard let userID = envelope.targetUserIDs.first,
                  let payload: IMTCPConversationEventPayload = decodePayload(from: envelope)
            else { return }
            await app.imConnectionRegistry.sendConversationEvent(payload, toUserID: userID, requestID: envelope.requestID)
        case .contactEvent:
            guard let userID = envelope.targetUserIDs.first,
                  let payload: IMTCPContactEventPayload = decodePayload(from: envelope)
            else { return }
            await app.imConnectionRegistry.sendContactEvent(payload, toUserID: userID, requestID: envelope.requestID)
        case .kickSession:
            guard let sessionID = envelope.sessionID,
                  let reason = envelope.kickReason,
                  let message = envelope.kickMessage
            else { return }
            await app.imConnectionRegistry.kickConnections(forSessionID: sessionID, reason: reason, message: message)
        case .kickUser:
            guard let userID = envelope.targetUserIDs.first,
                  let reason = envelope.kickReason,
                  let message = envelope.kickMessage
            else { return }
            await app.imConnectionRegistry.kickConnections(forUserID: userID, reason: reason, message: message)
        }
    }

    private func broadcastToAllNodes(_ envelope: NodeMessageDispatchEnvelope) async {
        let nodeIDs = (try? await backend.presenceStore.activeNodeIDs())?.filter { $0 != nodeID } ?? []
        for remoteNodeID in nodeIDs {
            do {
                try await backend.dispatchService.dispatch(envelope, toNodeID: remoteNodeID)
                await app.routingMetrics.recordCrossNodeDispatchSucceeded()
            } catch {
                await app.routingMetrics.recordCrossNodeDispatchFailed()
                app.logger.warning(
                    "Cross-node IM kick dispatch failed",
                    metadata: [
                        "node_id": .string(nodeID),
                        "route_backend": .string(routeBackendName),
                        "target_node_id": .string(remoteNodeID),
                        "error": .string(String(describing: error))
                    ]
                )
            }
        }
    }

    private func dispatchRemoteEnvelopeIfNeeded(
        _ envelope: NodeMessageDispatchEnvelope?,
        forUserIDs userIDs: [UUID],
        includeLocalNode: Bool = false
    ) async {
        guard let envelope else { return }
        do {
            let routes = try await backend.presenceStore.routeNodeIDs(forUserIDs: userIDs)
            var targetUserIDsByNodeID: [String: Set<UUID>] = [:]
            for (userID, nodeIDs) in routes {
                for remoteNodeID in nodeIDs where includeLocalNode || remoteNodeID != nodeID {
                    targetUserIDsByNodeID[remoteNodeID, default: []].insert(userID)
                }
            }

            for (remoteNodeID, targetUserIDs) in targetUserIDsByNodeID {
                do {
                    let routedEnvelope = envelope.withTargetUserIDs(
                        targetUserIDs.sorted { $0.uuidString < $1.uuidString }
                    )
                    try await backend.dispatchService.dispatch(routedEnvelope, toNodeID: remoteNodeID)
                    await app.routingMetrics.recordCrossNodeDispatchSucceeded()
                } catch {
                    await app.routingMetrics.recordCrossNodeDispatchFailed()
                    app.logger.warning(
                        "Cross-node IM dispatch failed",
                        metadata: [
                            "node_id": .string(nodeID),
                            "route_backend": .string(routeBackendName),
                            "target_node_id": .string(remoteNodeID),
                            "target_user_count": .stringConvertible(targetUserIDs.count),
                            "error": .string(String(describing: error))
                        ]
                    )
                }
            }
        } catch {
            await app.routingMetrics.recordCrossNodeDispatchFailed()
            app.logger.warning(
                "Cross-node IM dispatch failed",
                metadata: [
                    "node_id": .string(nodeID),
                    "route_backend": .string(routeBackendName),
                    "target_user_count": .stringConvertible(Set(userIDs).count),
                    "error": .string(String(describing: error))
                ]
            )
        }
    }

    private func encodePacketEnvelope<Payload: Codable & Sendable>(
        action: NodeMessageDispatchEnvelope.Action,
        packetType: IMTCPPacketType,
        requestID: UUID?,
        payload: Payload,
        targetUserIDs: [UUID]
    ) throws -> NodeMessageDispatchEnvelope {
        let data = try JSONEncoder().encode(payload)
        guard let payloadJSON = String(data: data, encoding: .utf8) else {
            throw RedisRoutingError.invalidDispatchPayload
        }
        return NodeMessageDispatchEnvelope(
            action: action,
            packetType: packetType,
            requestID: requestID,
            payloadJSON: payloadJSON,
            targetUserIDs: targetUserIDs,
            sessionID: nil,
            kickReason: nil,
            kickMessage: nil
        )
    }

    private func decodePayload<Payload: Decodable>(from envelope: NodeMessageDispatchEnvelope) -> Payload? {
        guard let payloadJSON = envelope.payloadJSON else {
            return nil
        }
        return try? JSONDecoder().decode(Payload.self, from: Data(payloadJSON.utf8))
    }
}

private extension NodeMessageDispatchEnvelope {
    func withTargetUserIDs(_ targetUserIDs: [UUID]) -> NodeMessageDispatchEnvelope {
        NodeMessageDispatchEnvelope(
            action: action,
            packetType: packetType,
            requestID: requestID,
            payloadJSON: payloadJSON,
            targetUserIDs: targetUserIDs,
            sessionID: sessionID,
            kickReason: kickReason,
            kickMessage: kickMessage
        )
    }
}

final class ConnectionRoutingLifecycle: LifecycleHandler, @unchecked Sendable {
    func shutdownAsync(_ application: Application) async {
        await application.connectionRoutingService.backend.shutdown()
    }
}

private struct IMNodeIDStorageKey: StorageKey {
    typealias Value = String
}

private struct ConnectionRoutingServiceStorageKey: StorageKey {
    typealias Value = ConnectionRoutingService
}

private struct RoutingMetricsStorageKey: StorageKey {
    typealias Value = RoutingMetrics
}

private struct IMRedisRoutingConfigurationStorageKey: StorageKey {
    typealias Value = IMRedisRoutingConfiguration
}

extension Application {
    var hasConnectionRoutingServiceConfigured: Bool {
        storage[ConnectionRoutingServiceStorageKey.self] != nil
    }

    var imNodeID: String {
        get {
            if let nodeID = storage[IMNodeIDStorageKey.self] {
                return nodeID
            }

            let nodeID = Environment.get("IM_NODE_ID") ?? UUID().uuidString.lowercased()
            storage[IMNodeIDStorageKey.self] = nodeID
            return nodeID
        }
        set {
            storage[IMNodeIDStorageKey.self] = newValue
        }
    }

    var routingMetrics: RoutingMetrics {
        get {
            if let metrics = storage[RoutingMetricsStorageKey.self] {
                return metrics
            }

            let metrics = RoutingMetrics()
            storage[RoutingMetricsStorageKey.self] = metrics
            return metrics
        }
        set {
            storage[RoutingMetricsStorageKey.self] = newValue
        }
    }

    var connectionRoutingService: ConnectionRoutingService {
        get {
            guard let service = storage[ConnectionRoutingServiceStorageKey.self] else {
                fatalError("ConnectionRoutingService accessed before configureConnectionRoutingServiceIfNeeded()")
            }
            return service
        }
        set {
            storage[ConnectionRoutingServiceStorageKey.self] = newValue
        }
    }

    var imRedisRoutingConfigurationOverride: IMRedisRoutingConfiguration? {
        get { storage[IMRedisRoutingConfigurationStorageKey.self] }
        set { storage[IMRedisRoutingConfigurationStorageKey.self] = newValue }
    }

    func configureConnectionRoutingServiceIfNeeded() async throws {
        if hasConnectionRoutingServiceConfigured {
            return
        }

        let configuration = imRedisRoutingConfigurationOverride ?? IMRedisRoutingConfiguration.load(from: environment)
        let logger = self.logger

        if environment == .production, configuration.mode != .redis {
            throw RedisRoutingError.redisRequiredInProduction
        }

        let backend: any ConnectionRoutingBackend
        switch configuration.mode {
        case .local:
            backend = LocalConnectionRoutingBackend(nodeID: imNodeID)
        case .redis:
            if environment == .production {
                let redisBackend = try RedisConnectionRoutingBackend(
                    configuration: configuration,
                    nodeID: imNodeID,
                    logger: logger,
                    eventLoop: eventLoopGroup.next()
                )
                try await redisBackend.start(app: self)
                connectionRoutingService = ConnectionRoutingService(app: self, backend: redisBackend)
                return
            }

            do {
                let redisBackend = try RedisConnectionRoutingBackend(
                    configuration: configuration,
                    nodeID: imNodeID,
                    logger: logger,
                    eventLoop: eventLoopGroup.next()
                )
                try await redisBackend.start(app: self)
                connectionRoutingService = ConnectionRoutingService(app: self, backend: redisBackend)
                return
            } catch {
                logger.warning(
                    "Redis routing backend unavailable; falling back to local routing",
                    metadata: [
                        "node_id": .string(imNodeID),
                        "error": .string(String(describing: error))
                    ]
                )
                backend = LocalConnectionRoutingBackend(nodeID: imNodeID)
            }
        }

        connectionRoutingService = ConnectionRoutingService(app: self, backend: backend)
        try await backend.start(app: self)
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
