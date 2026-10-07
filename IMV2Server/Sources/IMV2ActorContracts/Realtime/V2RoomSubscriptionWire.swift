import Foundation
import IMV2Core

/// A room subscription has its own generation, independent of partition interests.
public struct V2RoomSubscriptionFence: Hashable, Codable, Sendable {
    /// The actual trusted room activation, including host process incarnation.
    /// Constructing this value never grants or renews an activation lease.
    public let activation: V2RoomActivationToken
    public var roomID: RoomID { activation.roomID }
    public var ownerEpoch: Int64 { activation.owner.epoch }
    public let subscriptionID: UUID
    public let generation: UInt64
    public let baselineSequence: UInt64
    public init(activation: V2RoomActivationToken, subscriptionID: UUID,
                generation: UInt64, baselineSequence: UInt64) {
        self.activation = activation; self.subscriptionID = subscriptionID
        self.generation = generation; self.baselineSequence = baselineSequence
    }
    public func validate() throws {
        guard activation.owner.epoch >= 0, activation.activationEpoch.rawValue > 0,
              !activation.owner.shardID.isEmpty, activation.owner.shardID.utf8.count <= 128,
              !activation.host.hostID.rawValue.isEmpty, activation.host.hostID.rawValue.utf8.count <= 128,
              generation > 0, baselineSequence <= UInt64(Int64.max) else {
            throw V2ActorContractError.invalidConfiguration("room subscription activation fence")
        }
    }
}

public struct V2RoomSubscriptionMember: Hashable, Codable, Sendable {
    public let userID: UserID
    public let memberRevision: UInt64
    public init(userID: UserID, memberRevision: UInt64) {
        self.userID = userID; self.memberRevision = memberRevision
    }
}

public enum V2RoomSubscriptionPayload: Equatable, Codable, Sendable {
    case baseline(members: [V2RoomSubscriptionMember])
    /// Ordered parts of one fence's initial authorization cut. No grants are
    /// usable until every part has arrived; each packet has a bounded array.
    case baselinePage(index: Int, totalMembers: Int, members: [V2RoomSubscriptionMember])
    public static let maximumBaselinePageMembers = 512
    case grant(member: V2RoomSubscriptionMember, baselineSequence: UInt64)
    /// Uses membership already established by this exact ordered control stream.
    case broadcast(V2RealtimeRoomEvent)
    case event(V2RealtimeRoomEvent, members: [V2RoomSubscriptionMember])
    /// Online body was dropped; durable room pull recovers through this head.
    case head(highWatermark: UInt64)
    case authorizationInvalidated
    case revoke(userID: UserID, memberRevision: UInt64)

    public var isAuthorizationControl: Bool {
        switch self {
        case .baseline, .baselinePage, .grant, .revoke, .authorizationInvalidated: true
        case .broadcast, .event, .head: false
        }
    }
}

/// Delivery receipt order and authorization order are independent.
/// Message loss never advances or invalidates the authorization stream.
public struct V2RoomSubscriptionDelivery: Equatable, Codable, Sendable {
    public let fence: V2RoomSubscriptionFence
    public let deliverySequence: UInt64
    public let authorizationSequence: UInt64
    public let payload: V2RoomSubscriptionPayload
    public init(fence: V2RoomSubscriptionFence, deliverySequence: UInt64,
                authorizationSequence: UInt64, payload: V2RoomSubscriptionPayload) {
        self.fence = fence; self.deliverySequence = deliverySequence
        self.authorizationSequence = authorizationSequence; self.payload = payload
    }
    public func validate(maximumMembers: Int = V2GroupCapacityPolicy.largeMaximumMembers, maximumPayloadBytes: Int = 262_144) throws {
        try fence.validate()
        guard deliverySequence > 0, authorizationSequence > 0 else {
            throw V2ActorContractError.invalidConfiguration("room subscription fence")
        }
        let members: [V2RoomSubscriptionMember]
        switch payload {
        case .baseline(let value):
            guard deliverySequence == 1, authorizationSequence == 1,
                  value.count <= V2RoomSubscriptionPayload.maximumBaselinePageMembers else { throw V2ActorContractError.invalidConfiguration("room subscription baseline") }
            members = value
        case .baselinePage(let index, let total, let value):
            let size = V2RoomSubscriptionPayload.maximumBaselinePageMembers
            guard total > size, total <= maximumMembers, total <= V2GroupCapacityPolicy.largeMaximumMembers, index >= 0,
                  index < (total + size - 1) / size,
                  value.count == min(size, total - index * size),
                  deliverySequence == UInt64(index + 1), authorizationSequence == UInt64(index + 1) else {
                throw V2ActorContractError.invalidConfiguration("room subscription baseline page")
            }
            members = value
        case .grant(let member, let sequence):
            guard sequence >= fence.baselineSequence, sequence <= UInt64(Int64.max) else {
                throw V2ActorContractError.invalidConfiguration("room subscription grant")
            }
            members = [member]
        case .broadcast(let event):
            guard event.roomID == fence.roomID, event.roomSequence > fence.baselineSequence,
                  event.highWatermark >= event.roomSequence, event.highWatermark <= UInt64(Int64.max),
                  event.roomSequence <= UInt64(Int64.max), event.recipientUserIDs.isEmpty,
                  event.groupMembershipRevision != nil, event.payload.count <= maximumPayloadBytes,
                  !event.projectionKind.isEmpty, event.projectionKind.utf8.count <= 128 else {
                throw V2ActorContractError.invalidConfiguration("room subscription broadcast")
            }
            members = []
        case .event(let event, let value):
            guard event.roomID == fence.roomID, event.roomSequence > fence.baselineSequence,
                  event.highWatermark >= event.roomSequence,
                  event.highWatermark <= UInt64(Int64.max),
                  event.recipientUserIDs.count <= maximumMembers,
                  event.roomSequence <= UInt64(Int64.max),
                  !event.recipientUserIDs.isEmpty || event.groupMembershipRevision != nil,
                  event.payload.count <= maximumPayloadBytes,
                  !event.projectionKind.isEmpty, event.projectionKind.utf8.count <= 128 else {
                throw V2ActorContractError.invalidConfiguration("room subscription event")
            }
            members = value
        case .authorizationInvalidated:
            guard deliverySequence > 1 else { throw V2ActorContractError.invalidConfiguration("room subscription invalidation") }
            members = []
        case .revoke(_, let revision):
            guard revision <= UInt64(Int64.max) else {
                throw V2ActorContractError.invalidConfiguration("room subscription revoke")
            }
            members = []
        case .head(let highWatermark):
            guard highWatermark >= fence.baselineSequence, highWatermark <= UInt64(Int64.max) else {
                throw V2ActorContractError.invalidConfiguration("room subscription head")
            }
            members = []
        }
        guard members.count <= maximumMembers, Set(members.map(\.userID)).count == members.count,
              members.allSatisfy({ $0.memberRevision <= UInt64(Int64.max) }) else {
            throw V2ActorContractError.invalidConfiguration("room subscription members")
        }
    }
}
