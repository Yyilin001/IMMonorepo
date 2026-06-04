import Foundation
import Vapor

struct NodeMessageDispatchEnvelope: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        case domainEvent
        case domainEventPacket
        case streamSignal
        case kickSession
        case kickUser
    }

    let requestID: UUID?
    let payload: Payload

    enum Payload: Codable, Sendable {
        case domainEvent(ownerUserID: UUID, eventID: UUID)
        case domainEventPacket(packetBase64: String, targetUserIDs: [UUID])
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
        case .domainEventPacket(_, let targetUserIDs):
            return targetUserIDs
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
        case .domainEventPacket(let packetBase64, _):
            return NodeMessageDispatchEnvelope(
                requestID: requestID,
                payload: .domainEventPacket(packetBase64: packetBase64, targetUserIDs: targetUserIDs)
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
