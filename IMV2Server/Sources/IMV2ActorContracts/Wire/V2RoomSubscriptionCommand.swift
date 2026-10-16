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
    /// Present when the Gateway retired the returned session locally. The
    /// Host must supersede only this exact generation, never a newer one.
    public let replacingDeliverySession: V2RoomDeliverySession?
    public init(roomID: RoomID, actorUserID: UserID, gatewayDescriptor: V2GatewayRealtimeDescriptor,
                expectedFence: V2RoomSubscriptionFence, replacingDeliverySession: V2RoomDeliverySession? = nil) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.gatewayDescriptor = gatewayDescriptor
        self.expectedFence = expectedFence; self.replacingDeliverySession = replacingDeliverySession
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

public enum V2RoomSubscriptionCommand: Codable, Equatable, Sendable {
    case subscribe(V2RoomSubscriptionSubscribeCommand)
    case activate(V2RoomSubscriptionActivateCommand)
    case reset(V2RoomSubscriptionResetCommand)
    case unsubscribe(V2RoomSubscriptionUnsubscribeCommand)
    public var roomID: RoomID {
        switch self { case .subscribe(let value): value.roomID; case .activate(let value): value.roomID; case .reset(let value): value.roomID; case .unsubscribe(let value): value.roomID }
    }
    public var actorUserID: UserID {
        switch self { case .subscribe(let value): value.actorUserID; case .activate(let value): value.actorUserID; case .reset(let value): value.actorUserID; case .unsubscribe(let value): value.actorUserID }
    }
    public var gatewayDescriptor: V2GatewayRealtimeDescriptor {
        switch self { case .subscribe(let value): value.gatewayDescriptor; case .activate(let value): value.gatewayDescriptor; case .reset(let value): value.gatewayDescriptor; case .unsubscribe(let value): value.gatewayDescriptor }
    }
    public func validate() throws {
        try gatewayDescriptor.validate()
        guard roomID.uuidValue != nil, actorUserID.uuidValue != nil else {
            throw V2ActorContractError.invalidConfiguration("room subscription identifiers")
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
            if let session = value.replacingDeliverySession {
                try session.validate()
                guard session.host == value.expectedFence.activation.host,
                      session.gateway == gatewayDescriptor.identity else {
                    throw V2ActorContractError.invalidConfiguration("room subscription reset session")
                }
            }
        }
        if case .unsubscribe(let value) = self,
           value.memberRevision > UInt64(Int64.max) {
            throw V2ActorContractError.invalidConfiguration("room subscription member revision")
        }
    }
}

/// Authorization is bound to an authenticated delivery-session generation.
public struct V2RoomSubscriptionGrant: Codable, Equatable, Sendable {
    public let fence: V2RoomSubscriptionFence
    public let memberRevision: UInt64
    public let userBaselineSequence: UInt64
    public let deliverySession: V2RoomDeliverySession
    public init(fence: V2RoomSubscriptionFence, memberRevision: UInt64,
                userBaselineSequence: UInt64, deliverySession: V2RoomDeliverySession) {
        self.fence = fence; self.memberRevision = memberRevision
        self.userBaselineSequence = userBaselineSequence; self.deliverySession = deliverySession
    }
}

public enum V2RoomSubscriptionFailure: String, Codable, Equatable, Sendable {
    case unauthorized, stale, overloaded, unavailable, invalidRequest
}

public enum V2RoomSubscriptionResult: Codable, Equatable, Sendable {
    case granted(V2RoomSubscriptionGrant)
    case activated
    case unsubscribed
    case failure(V2RoomSubscriptionFailure)
}
