import Foundation
import Vapor

struct NodeMessageDispatchEnvelope: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        case domainEvent
        case message
        case conversationEvent
        case contactEvent
        case kickSession
        case kickUser
    }

    let action: Action
    let packetType: IMTCPPacketType?
    let requestID: UUID?
    let packetBase64: String?
    let targetUserIDs: [UUID]
    let sessionID: UUID?
    let kickReason: IMTCPKickReason?
    let kickMessage: String?
}

extension NodeMessageDispatchEnvelope {
    func withTargetUserIDs(_ targetUserIDs: [UUID]) -> NodeMessageDispatchEnvelope {
        NodeMessageDispatchEnvelope(
            action: action,
            packetType: packetType,
            requestID: requestID,
            packetBase64: packetBase64,
            targetUserIDs: targetUserIDs,
            sessionID: sessionID,
            kickReason: kickReason,
            kickMessage: kickMessage
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
    func routeNodeIDs(forUserIDs userIDs: [UUID]) async throws -> [UUID: Set<String>]
    func routeNodeIDs(forSessionIDs sessionIDs: [UUID]) async throws -> [UUID: Set<String>]
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
    case invalidDispatchPayload
    case redisRequiredInProduction
}

enum IMRoutingMode: String, Sendable {
    case local
    case redis
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
