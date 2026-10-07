import Foundation
import IMV2Core

public struct V2RoomSubscriptionSubscribeCommand: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let gatewayDescriptor: V2GatewayRealtimeDescriptor
    public init(roomID: RoomID, actorUserID: UserID, gatewayDescriptor: V2GatewayRealtimeDescriptor) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.gatewayDescriptor = gatewayDescriptor
    }
}

public struct V2RoomSubscriptionActivateCommand: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let gatewayDescriptor: V2GatewayRealtimeDescriptor
    public let fence: V2RoomSubscriptionFence
    public init(roomID: RoomID, actorUserID: UserID, gatewayDescriptor: V2GatewayRealtimeDescriptor,
                fence: V2RoomSubscriptionFence) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.gatewayDescriptor = gatewayDescriptor
        self.fence = fence
    }
}

/// Explicitly rebuilds the entire Gateway/room shared subscription. The
/// expected fence prevents a late recovery request from replacing a newer cut.
public struct V2RoomSubscriptionResetCommand: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let gatewayDescriptor: V2GatewayRealtimeDescriptor
    public let expectedFence: V2RoomSubscriptionFence
    public init(roomID: RoomID, actorUserID: UserID, gatewayDescriptor: V2GatewayRealtimeDescriptor,
                expectedFence: V2RoomSubscriptionFence) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.gatewayDescriptor = gatewayDescriptor
        self.expectedFence = expectedFence
    }
}

public struct V2RoomSubscriptionUnsubscribeCommand: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let gatewayDescriptor: V2GatewayRealtimeDescriptor
    public let memberRevision: UInt64
    public init(roomID: RoomID, actorUserID: UserID, gatewayDescriptor: V2GatewayRealtimeDescriptor,
                memberRevision: UInt64) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.gatewayDescriptor = gatewayDescriptor
        self.memberRevision = memberRevision
    }
}

/// Renews the shared Gateway/room authority without installing a new baseline.
/// The receiver never accepts an RPC-provided lease deadline.
public struct V2RoomSubscriptionRenewCommand: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let gatewayDescriptor: V2GatewayRealtimeDescriptor
    public let expectedFence: V2RoomSubscriptionFence
    public let appliedControlSequence: UInt64
    public init(roomID: RoomID, actorUserID: UserID, gatewayDescriptor: V2GatewayRealtimeDescriptor,
                expectedFence: V2RoomSubscriptionFence, appliedControlSequence: UInt64) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.gatewayDescriptor = gatewayDescriptor
        self.expectedFence = expectedFence; self.appliedControlSequence = appliedControlSequence
    }
}
public struct V2RoomSubscriptionRenewal: Codable, Equatable, Sendable {
    public let fence: V2RoomSubscriptionFence
    public let appliedControlSequence: UInt64
    /// Advisory committed head from the same fresh exact-activation lease proof.
    /// It grants no membership or body authority.
    public let committedRoomSequence: UInt64
    public let remainingLeaseMilliseconds: Int64
    public init(fence: V2RoomSubscriptionFence, appliedControlSequence: UInt64, committedRoomSequence: UInt64, remainingLeaseMilliseconds: Int64) {
        self.fence = fence; self.appliedControlSequence = appliedControlSequence
        self.committedRoomSequence = committedRoomSequence
        self.remainingLeaseMilliseconds = remainingLeaseMilliseconds
    }
}

public enum V2RoomSubscriptionCommand: Codable, Equatable, Sendable {
    case renew(V2RoomSubscriptionRenewCommand)
    case subscribe(V2RoomSubscriptionSubscribeCommand)
    case activate(V2RoomSubscriptionActivateCommand)
    case reset(V2RoomSubscriptionResetCommand)
    case unsubscribe(V2RoomSubscriptionUnsubscribeCommand)
    public var roomID: RoomID {
        switch self { case .renew(let value): value.roomID; case .subscribe(let value): value.roomID; case .activate(let value): value.roomID; case .reset(let value): value.roomID; case .unsubscribe(let value): value.roomID }
    }
    public var actorUserID: UserID {
        switch self { case .renew(let value): value.actorUserID; case .subscribe(let value): value.actorUserID; case .activate(let value): value.actorUserID; case .reset(let value): value.actorUserID; case .unsubscribe(let value): value.actorUserID }
    }
    public var gatewayDescriptor: V2GatewayRealtimeDescriptor {
        switch self { case .renew(let value): value.gatewayDescriptor; case .subscribe(let value): value.gatewayDescriptor; case .activate(let value): value.gatewayDescriptor; case .reset(let value): value.gatewayDescriptor; case .unsubscribe(let value): value.gatewayDescriptor }
    }
    public func validate() throws {
        try gatewayDescriptor.validate()
        guard roomID.uuidValue != nil, actorUserID.uuidValue != nil else {
            throw V2ActorContractError.invalidConfiguration("room subscription identifiers")
        }
        if case .renew(let value) = self {
            try value.expectedFence.validate()
            guard value.expectedFence.roomID == roomID, value.appliedControlSequence > 0 else {
                throw V2ActorContractError.invalidConfiguration("room subscription renewal")
            }
        }
        if case .activate(let value) = self {
            guard value.fence.roomID == roomID, value.fence.generation > 0,
                  value.fence.baselineSequence <= UInt64(Int64.max) else {
                throw V2ActorContractError.invalidConfiguration("room subscription activation")
            }
        }
        if case .reset(let value) = self {
            guard value.expectedFence.roomID == roomID, value.expectedFence.generation > 0,
                  value.expectedFence.baselineSequence <= UInt64(Int64.max) else {
                throw V2ActorContractError.invalidConfiguration("room subscription reset fence")
            }
        }
        if case .unsubscribe(let value) = self,
           value.memberRevision > UInt64(Int64.max) {
            throw V2ActorContractError.invalidConfiguration("room subscription member revision")
        }
    }
}

/// Returned only by the currently fenced room activation. The caller cannot
/// supply a lease deadline; the receiver derives one from this bounded budget.
public struct V2RoomSubscriptionGrant: Codable, Equatable, Sendable {
    public let fence: V2RoomSubscriptionFence
    public let memberRevision: UInt64
    public let userBaselineSequence: UInt64
    public let remainingLeaseMilliseconds: Int64
    public init(fence: V2RoomSubscriptionFence, memberRevision: UInt64,
                userBaselineSequence: UInt64, remainingLeaseMilliseconds: Int64) {
        self.fence = fence; self.memberRevision = memberRevision
        self.userBaselineSequence = userBaselineSequence; self.remainingLeaseMilliseconds = remainingLeaseMilliseconds
    }
}

public enum V2RoomSubscriptionFailure: String, Codable, Equatable, Sendable {
    case unauthorized, stale, overloaded, unavailable, invalidRequest
}

public enum V2RoomSubscriptionResult: Codable, Equatable, Sendable {
    case renewed(V2RoomSubscriptionRenewal)
    case granted(V2RoomSubscriptionGrant)
    case activated
    case unsubscribed
    case failure(V2RoomSubscriptionFailure)
}
