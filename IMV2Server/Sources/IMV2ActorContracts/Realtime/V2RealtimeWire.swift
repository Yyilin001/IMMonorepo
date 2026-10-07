import Foundation
import IMV2Core

public struct V2GatewayRealtimeIdentity: Hashable, Codable, Sendable {
    public let nodeID: String
    public let serviceID: String
    public let incarnationID: UUID
    public init(nodeID: String, serviceID: String, incarnationID: UUID) {
        self.nodeID = nodeID; self.serviceID = serviceID; self.incarnationID = incarnationID
    }
}

public struct V2GatewayRealtimeDescriptor: Hashable, Codable, Sendable {
    public let identity: V2GatewayRealtimeIdentity
    public let endpointReference: Data
    public let address: String
    public let port: Int
    public init(identity: V2GatewayRealtimeIdentity, endpointReference: Data, address: String, port: Int) {
        self.identity = identity; self.endpointReference = endpointReference; self.address = address; self.port = port
    }
    public func validate() throws {
        guard !identity.nodeID.isEmpty, identity.nodeID.utf8.count <= 128,
              !identity.serviceID.isEmpty, identity.serviceID.utf8.count <= 128,
              !endpointReference.isEmpty, endpointReference.count <= 16_384,
              !address.isEmpty, address.utf8.count <= 253, address != "0.0.0.0", address != "::",
              (1...65_535).contains(port) else { throw V2ActorContractError.invalidConfiguration("realtime descriptor") }
    }
}

public enum V2RealtimeTopicKind: String, Codable, Hashable, Sendable, CaseIterable {
    case roomEvents, roomTyping, userPresence, userSync
}
public struct V2RealtimeTopic: Hashable, Codable, Sendable {
    public let kind: V2RealtimeTopicKind
    public let id: String
    public let owner: V2RoomDataOwner
    public init(kind: V2RealtimeTopicKind, id: String, owner: V2RoomDataOwner) {
        self.kind = kind; self.id = id; self.owner = owner
    }
}
public struct V2RealtimeRoomEvent: Equatable, Codable, Sendable {
    public let roomID: RoomID
    public let highWatermark: UInt64
    public let sourceEventID: EventID
    public let roomSequence: UInt64
    public let projectionKind: String
    public let payload: Data
    public let recipientUserIDs: Set<UserID>
    public let groupMembershipRevision: UInt64?
    public let acceptedMembershipRevision: UInt64?
    public let excludedConnectionID: UUID?
    public init(roomID: RoomID, highWatermark: UInt64, sourceEventID: EventID, roomSequence: UInt64,
                projectionKind: String, payload: Data, recipientUserIDs: Set<UserID>,
                groupMembershipRevision: UInt64? = nil, acceptedMembershipRevision: UInt64? = nil,
                excludedConnectionID: UUID? = nil) {
        self.roomID = roomID; self.highWatermark = highWatermark; self.sourceEventID = sourceEventID
        self.roomSequence = roomSequence; self.projectionKind = projectionKind; self.payload = payload
        self.recipientUserIDs = recipientUserIDs; self.groupMembershipRevision = groupMembershipRevision
        self.acceptedMembershipRevision = acceptedMembershipRevision; self.excludedConnectionID = excludedConnectionID
    }
}
public enum V2RealtimePayload: Equatable, Codable, Sendable {
    case roomWake(roomID: RoomID, highWatermark: UInt64)
    case roomEvents([V2RealtimeRoomEvent])
    case userSync(userID: UserID, highWatermark: UInt64)
    case presence(userID: UserID)
    case typing(roomID: RoomID, userID: UserID, isTyping: Bool, expiresAt: Date, sourceConnectionID: UUID, sequence: UInt64)
}
public struct V2RealtimeDelivery: Equatable, Codable, Sendable {
    public let topic: V2RealtimeTopic
    public let partitionID: Int
    public let partitionEpoch: Int64
    public let sessionID: UUID
    public let interestGeneration: Int64
    public let gatewayIncarnation: UUID
    public let payload: V2RealtimePayload
    public init(topic: V2RealtimeTopic, partitionID: Int, partitionEpoch: Int64,
                sessionID: UUID, interestGeneration: Int64, gatewayIncarnation: UUID,
                payload: V2RealtimePayload) {
        self.topic = topic; self.partitionID = partitionID; self.partitionEpoch = partitionEpoch
        self.sessionID = sessionID; self.interestGeneration = interestGeneration
        self.gatewayIncarnation = gatewayIncarnation; self.payload = payload
    }
}
public struct V2RealtimeBatch: Equatable, Codable, Sendable {
    public let batchID: UUID
    public let recipient: V2GatewayRealtimeIdentity
    public let deliveries: [V2RealtimeDelivery]
    public init(batchID: UUID = UUID(), recipient: V2GatewayRealtimeIdentity, deliveries: [V2RealtimeDelivery]) {
        self.batchID = batchID; self.recipient = recipient; self.deliveries = deliveries
    }
    public func validate(limits: V2RealtimeTransportLimits = .init()) throws {
        guard !deliveries.isEmpty, deliveries.count <= limits.maximumBatchItems,
              !recipient.nodeID.isEmpty, recipient.nodeID.utf8.count <= 128,
              !recipient.serviceID.isEmpty, recipient.serviceID.utf8.count <= 128 else {
            throw V2ActorContractError.invalidConfiguration("realtime batch")
        }
        var totalItems = 0
        var totalPayloadBytes = 0
        for delivery in deliveries {
            if case .roomEvents(let events) = delivery.payload {
                totalItems += events.count
                totalPayloadBytes += events.reduce(0) { $0 + $1.payload.count }
            }
            else { totalItems += 1 }
            guard totalItems <= limits.maximumBatchItems, totalPayloadBytes <= limits.maximumPacketBytes else { throw V2ActorContractError.invalidConfiguration("realtime items") }
            guard delivery.partitionEpoch > 0, delivery.interestGeneration > 0,
                  delivery.gatewayIncarnation == recipient.incarnationID,
                  delivery.partitionID == V2RealtimeTopicKey(delivery.topic).partitionID(),
                  !delivery.topic.id.isEmpty, delivery.topic.id.utf8.count <= 128,
                  delivery.topic.owner.shardID.utf8.count <= 128 else {
                throw V2ActorContractError.invalidConfiguration("realtime fence")
            }
            let kind = delivery.topic.kind; let id = delivery.topic.id
            switch delivery.payload {
            case .roomWake(let room, let watermark):
                guard kind == .roomEvents, id == room.rawValue, watermark > 0 else { throw V2ActorContractError.invalidConfiguration("room wake") }
            case .roomEvents(let events):
                guard kind == .roomEvents, !events.isEmpty, events.count <= limits.maximumBatchItems else { throw V2ActorContractError.invalidConfiguration("room events") }
                for event in events {
                    guard id == event.roomID.rawValue, event.roomSequence > 0, event.highWatermark >= event.roomSequence,
                          !event.projectionKind.isEmpty, event.projectionKind.utf8.count <= 128,
                          event.payload.count <= limits.maximumPacketBytes, event.recipientUserIDs.count <= 2,
                          !event.recipientUserIDs.isEmpty || event.groupMembershipRevision != nil else {
                        throw V2ActorContractError.invalidConfiguration("room event")
                    }
                }
            case .userSync(let user, let watermark):
                guard kind == .userSync, id == user.rawValue, watermark > 0 else { throw V2ActorContractError.invalidConfiguration("user sync") }
            case .presence(let user):
                guard kind == .userPresence, id == user.rawValue else { throw V2ActorContractError.invalidConfiguration("presence") }
            case .typing(let room, _, _, let expiry, _, let sequence):
                guard kind == .roomTyping, id == room.rawValue, sequence > 0, expiry.timeIntervalSince1970.isFinite, expiry <= Date().addingTimeInterval(60) else { throw V2ActorContractError.invalidConfiguration("typing") }
            }
        }
    }
}
public enum V2RealtimeAcceptance: String, Codable, Equatable, Sendable {
    /// All entries were admitted without replacing their payloads.
    case accepted
    /// All entries were admitted; one or more bodies became durable-log watermarks.
    case acceptedAsWatermark
    case overloaded, closed, stale

    public var wasAccepted: Bool { self == .accepted || self == .acceptedAsWatermark }
}
/// Acceptance is synchronous local admission, never SQL, socket delivery, or client ACK.
public protocol V2RealtimeIngress: Sendable {
    func offer(_ batch: V2RealtimeBatch) -> V2RealtimeAcceptance
}
public struct V2RealtimeTransportLimits: Sendable {
    public let maximumPacketBytes: Int
    public let maximumBatchItems: Int
    public let maximumPeers: Int
    public let maximumConcurrentCalls: Int
    public let callTimeout: Duration
    public init(maximumPacketBytes: Int = 262_144, maximumBatchItems: Int = 64,
                maximumPeers: Int = 64, maximumConcurrentCalls: Int = 32, callTimeout: Duration = .seconds(2)) {
        self.maximumPacketBytes = max(1, min(262_144, maximumPacketBytes))
        self.maximumBatchItems = max(1, min(64, maximumBatchItems))
        self.maximumPeers = max(1, min(64, maximumPeers))
        self.maximumConcurrentCalls = max(1, min(32, maximumConcurrentCalls))
        self.callTimeout = max(.milliseconds(50), min(.seconds(10), callTimeout))
    }
}
