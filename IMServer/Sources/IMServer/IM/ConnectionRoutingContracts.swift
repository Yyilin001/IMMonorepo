import Foundation
import Vapor

struct NodeMessageDispatchEnvelope: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        case domainEvent
        case domainEventPacket
        case activeConversationDomainEventPacket
        case streamSignal
        case kickSession
        case kickUser
    }

    let requestID: UUID?
    let payload: Payload

    enum Payload: Codable, Sendable {
        case domainEvent(ownerUserID: UUID, eventID: UUID)
        case domainEventPacket(
            packetBase64: String,
            targetUserIDs: [UUID],
            fanoutIntent: IMGatewayDomainEventFanoutIntent? = nil
        )
        case activeConversationDomainEventPacket(
            packetBase64: String,
            conversationID: UUID,
            allowedUserIDs: [UUID],
            fanoutIntent: IMGatewayDomainEventFanoutIntent? = nil
        )
        case streamSignal(packetBase64: String, targetUserIDs: [UUID])
        case kickSession(sessionID: UUID, reason: IMTCPKickReason, message: String)
        case kickUser(userID: UUID, reason: IMTCPKickReason, message: String)
    }

    var action: Action {
        switch payload {
        case .domainEvent:
            return .domainEvent
        case .domainEventPacket:
            return .domainEventPacket
        case .activeConversationDomainEventPacket:
            return .activeConversationDomainEventPacket
        case .streamSignal:
            return .streamSignal
        case .kickSession:
            return .kickSession
        case .kickUser:
            return .kickUser
        }
    }

    var targetUserIDs: [UUID] {
        switch payload {
        case .domainEvent(let ownerUserID, _):
            return [ownerUserID]
        case .domainEventPacket(_, let targetUserIDs, _):
            return targetUserIDs
        case .activeConversationDomainEventPacket(_, _, let allowedUserIDs, _):
            return allowedUserIDs
        case .streamSignal(_, let targetUserIDs):
            return targetUserIDs
        case .kickSession:
            return []
        case .kickUser(let userID, _, _):
            return [userID]
        }
    }

    var sessionID: UUID? {
        if case .kickSession(let sessionID, _, _) = payload {
            return sessionID
        }
        return nil
    }
}

extension NodeMessageDispatchEnvelope {
    func withTargetUserIDs(_ targetUserIDs: [UUID]) -> NodeMessageDispatchEnvelope {
        switch payload {
        case .domainEventPacket(let packetBase64, _, let fanoutIntent):
            return NodeMessageDispatchEnvelope(
                requestID: requestID,
                payload: .domainEventPacket(
                    packetBase64: packetBase64,
                    targetUserIDs: targetUserIDs,
                    fanoutIntent: fanoutIntent
                )
            )
        case .activeConversationDomainEventPacket(let packetBase64, let conversationID, _, let fanoutIntent):
            return NodeMessageDispatchEnvelope(
                requestID: requestID,
                payload: .activeConversationDomainEventPacket(
                    packetBase64: packetBase64,
                    conversationID: conversationID,
                    allowedUserIDs: targetUserIDs,
                    fanoutIntent: fanoutIntent
                )
            )
        case .streamSignal(let packetBase64, _):
            return NodeMessageDispatchEnvelope(
                requestID: requestID,
                payload: .streamSignal(packetBase64: packetBase64, targetUserIDs: targetUserIDs)
            )
        case .kickUser(_, let reason, let message):
            guard let userID = targetUserIDs.first else { return self }
            return NodeMessageDispatchEnvelope(
                requestID: requestID,
                payload: .kickUser(userID: userID, reason: reason, message: message)
            )
        case .domainEvent,
             .kickSession:
            return self
        }
    }

    func withSessionID(_ sessionID: UUID) -> NodeMessageDispatchEnvelope {
        guard case .kickSession(_, let reason, let message) = payload else {
            return self
        }
        return NodeMessageDispatchEnvelope(
            requestID: requestID,
            payload: .kickSession(sessionID: sessionID, reason: reason, message: message)
        )
    }
}

protocol PresenceStore: Sendable {
    var backendName: String { get }
    func start(app: Application) async throws
    func shutdown() async
    func activatePresence(forUserID userID: UUID) async throws
    func deactivatePresence(forUserID userID: UUID) async throws
    func activatePresence(forSessionID sessionID: UUID, userID: UUID) async throws
    func deactivatePresence(forSessionID sessionID: UUID, userID: UUID) async throws
    func activateConversationPresence(conversationID: UUID, userID: UUID) async throws
    func deactivateConversationPresence(conversationID: UUID, userID: UUID) async throws
    func routeNodeIDs(
        forActiveConversationID conversationID: UUID,
        amongUserIDs userIDs: [UUID]
    ) async throws -> [UUID: Set<String>]
    func routeNodeIDs(forActiveConversationID conversationID: UUID) async throws -> [UUID: Set<String>]
    func routeNodeIDs(forUserIDs userIDs: [UUID]) async throws -> [UUID: Set<String>]
    func routeNodeIDs(forSessionIDs sessionIDs: [UUID]) async throws -> [UUID: Set<String>]
    /// Returns the realtime Cells that currently hold a renewable presence
    /// lease for each user. Node routes remain Cell-local; callers use this
    /// index before handing a packet to another Cell's Gateway ingress.
    func routeCellIDs(forUserIDs userIDs: [UUID]) async throws -> [UUID: Set<String>]
    func routeCellIDs(forSessionIDs sessionIDs: [UUID]) async throws -> [UUID: Set<String>]
    func refreshPresence(forUserID userID: UUID) async throws
    func refreshPresence(forSessionID sessionID: UUID, userID: UUID) async throws
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

enum RedisRoutingError: Error {
    case invalidURL(String)
    case invalidRedisClusterSeed(String)
    case unsupportedRedisScheme(String)
    case invalidDispatchPayload
    case redisRequiredInProduction
    case redisClusterTopologyUnsupported
    case redisClusterTopologyUnsupportedByComponents([String])
    case invalidRedisDeploymentTopology(String)
    case valkeyStreamDispatchRequiresCluster
}

enum IMRoutingMode: String, Sendable {
    case local
    case redis
}

/// Chooses the routing transport. Standalone keeps the legacy RediStack backend;
/// Cluster selects the Valkey-aware route backend and durable Valkey Stream
/// node dispatch.
enum IMRedisDeploymentTopology: Sendable, Equatable {
    case standalone
    case cluster
    case unsupported(String)

    init(environmentValue: String?) {
        let normalized = environmentValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case nil, "", "standalone":
            self = .standalone
        case "cluster":
            self = .cluster
        case let value?:
            self = .unsupported(value)
        }
    }
}

struct IMRedisRoutingConfiguration: Sendable {
    let url: String?
    let mode: IMRoutingMode
    let deploymentTopology: IMRedisDeploymentTopology
    let maximumConnectionCount: Int
    let presenceHeartbeatTimeoutSeconds: Int
    let activeConversationRouteTTLSeconds: Int
    let activeConversationRouteCacheTTLSeconds: Int
    let clusterSeedEndpoints: [IMRedisClusterSeedEndpoint]

    init(
        url: String?,
        mode: IMRoutingMode,
        deploymentTopology: IMRedisDeploymentTopology = .standalone,
        maximumConnectionCount: Int,
        presenceHeartbeatTimeoutSeconds: Int = 90,
        activeConversationRouteTTLSeconds: Int = 900,
        activeConversationRouteCacheTTLSeconds: Int = 2,
        clusterSeedEndpoints: [IMRedisClusterSeedEndpoint] = []
    ) {
        self.url = url
        self.mode = mode
        self.deploymentTopology = deploymentTopology
        self.maximumConnectionCount = maximumConnectionCount
        self.presenceHeartbeatTimeoutSeconds = max(1, presenceHeartbeatTimeoutSeconds)
        self.activeConversationRouteTTLSeconds = max(
            self.presenceHeartbeatTimeoutSeconds,
            activeConversationRouteTTLSeconds
        )
        self.activeConversationRouteCacheTTLSeconds = max(0, activeConversationRouteCacheTTLSeconds)
        self.clusterSeedEndpoints = clusterSeedEndpoints
    }

    static func load(from environment: Environment) -> IMRedisRoutingConfiguration {
        let explicitMode = Environment.get("IM_ROUTING_MODE").flatMap(IMRoutingMode.init(rawValue:))
        let url = Environment.get("REDIS_URL")
        let mode = explicitMode ?? (url == nil ? .local : .redis)
        let deploymentTopology = IMRedisDeploymentTopology(
            environmentValue: Environment.get("IM_REDIS_DEPLOYMENT_TOPOLOGY")
        )
        let maximumConnectionCount = max(2, Environment.get("IM_REDIS_MAX_CONNECTIONS").flatMap(Int.init(_:)) ?? 8)
        let heartbeatTimeoutSeconds = max(
            1,
            Environment.get("IM_REDIS_PRESENCE_HEARTBEAT_TIMEOUT_SECONDS").flatMap(Int.init(_:)) ?? 90
        )
        let activeConversationRouteTTLSeconds = max(
            heartbeatTimeoutSeconds,
            Environment.get("IM_REDIS_ACTIVE_CONVERSATION_ROUTE_TTL_SECONDS").flatMap(Int.init(_:)) ?? 900
        )
        let activeConversationRouteCacheTTLSeconds = max(
            0,
            Environment.get("IM_REDIS_ACTIVE_CONVERSATION_ROUTE_CACHE_TTL_SECONDS").flatMap(Int.init(_:)) ?? 2
        )
        let clusterSeedEndpoints = (Environment.get("IM_REDIS_CLUSTER_NODES") ?? "")
            .split(separator: ",")
            .map(String.init)
            .compactMap(IMRedisClusterSeedEndpoint.init(environmentValue:))
        return IMRedisRoutingConfiguration(
            url: url,
            mode: mode,
            deploymentTopology: deploymentTopology,
            maximumConnectionCount: maximumConnectionCount,
            presenceHeartbeatTimeoutSeconds: heartbeatTimeoutSeconds,
            activeConversationRouteTTLSeconds: activeConversationRouteTTLSeconds,
            activeConversationRouteCacheTTLSeconds: activeConversationRouteCacheTTLSeconds,
            clusterSeedEndpoints: clusterSeedEndpoints
        )
    }

    func requireURL() throws -> String {
        guard let url, !url.isEmpty else {
            throw RedisRoutingError.redisRequiredInProduction
        }
        return url
    }

    func requireClusterSeedEndpoints() throws -> [IMRedisClusterSeedEndpoint] {
        guard !clusterSeedEndpoints.isEmpty else {
            throw RedisRoutingError.invalidRedisClusterSeed(
                "IM_REDIS_CLUSTER_NODES must contain at least one host:port endpoint."
            )
        }
        return clusterSeedEndpoints
    }

    func validateTopologySupport() throws {
        guard mode == .redis else {
            return
        }

        switch deploymentTopology {
        case .standalone:
            return
        case .cluster:
            return
        case .unsupported(let value):
            throw RedisRoutingError.invalidRedisDeploymentTopology(value)
        }
    }
}

struct IMRedisClusterSeedEndpoint: Sendable, Equatable {
    let host: String
    let port: Int

    init?(environmentValue: String) {
        let rawValue = environmentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else {
            return nil
        }
        let valueWithScheme = rawValue.contains("://") ? rawValue : "redis://\(rawValue)"
        guard let url = URL(string: valueWithScheme),
              let host = url.host
        else {
            return nil
        }
        let port = url.port ?? 6379
        guard (1...65_535).contains(port) else {
            return nil
        }
        self.host = host
        self.port = port
    }
}
