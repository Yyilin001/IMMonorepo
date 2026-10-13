import Foundation
import IMV2Core
import IMV2ActorContracts

public enum V2RoomSubscriptionSourceError: Error, Equatable, Sendable {
    case invalidInput, wrongOwner, roomNotFound, snapshotRequired, corruptPersistence
}

public struct V2RoomSubscriptionSourceMember: Equatable, Codable, Sendable {
    public let userID: UserID
    public let memberRevision: UInt64
    public let authorized: Bool
    public init(userID: UserID, memberRevision: UInt64, authorized: Bool) {
        self.userID = userID; self.memberRevision = memberRevision; self.authorized = authorized
    }
}

public struct V2RoomSubscriptionSourceSnapshot: Equatable, Sendable {
    public let roomID: RoomID
    public let owner: V2RoomDataOwner
    public let highWatermark: UInt64
    public let membershipRevision: UInt64
    public let roomControlVersion: Int64
    public let members: [V2RoomSubscriptionSourceMember]
    public init(roomID: RoomID, owner: V2RoomDataOwner, highWatermark: UInt64, membershipRevision: UInt64 = 0, roomControlVersion: Int64 = 0,
                members: [V2RoomSubscriptionSourceMember]) {
        self.roomID = roomID; self.owner = owner; self.highWatermark = highWatermark
        self.roomControlVersion = roomControlVersion; self.membershipRevision = membershipRevision; self.members = members
    }
}

/// Includes every committed sequence, including controls and compact message
/// rows. hasOnlineBody=false means head-only delivery, never an omitted record.
public struct V2RoomSubscriptionSourceRecord: Equatable, Sendable {
    public enum RecipientPolicy: Equatable, Sendable {
        /// Permissions come from the snapshot plus preceding ordered controls.
        case currentAuthorized
        /// Explicit empty means nobody, never a group broadcast.
        case explicit(Set<UserID>)
    }
    public struct MembershipControl: Equatable, Sendable {
        public let revisionBefore: UInt64
        public let revisionAfter: UInt64
        public let members: [V2RoomSubscriptionSourceMember]
        public init(revisionBefore: UInt64, revisionAfter: UInt64, members: [V2RoomSubscriptionSourceMember]) {
            self.revisionBefore = revisionBefore; self.revisionAfter = revisionAfter; self.members = members
        }
    }
    public let event: V2RealtimeRoomEvent
    public let hasOnlineBody: Bool
    public let membershipControl: MembershipControl?
    public let recipientPolicy: RecipientPolicy
    public init(event: V2RealtimeRoomEvent, hasOnlineBody: Bool,
                membershipControl: MembershipControl? = nil, recipientPolicy: RecipientPolicy = .currentAuthorized) {
        self.event = event; self.hasOnlineBody = hasOnlineBody
        self.membershipControl = membershipControl; self.recipientPolicy = recipientPolicy
    }
}

public struct V2RoomSubscriptionSourcePage: Equatable, Sendable {
    public let roomID: RoomID
    public let owner: V2RoomDataOwner
    public let afterRoomSequence: UInt64
    public let highWatermark: UInt64
    public let records: [V2RoomSubscriptionSourceRecord]
    public init(roomID: RoomID, owner: V2RoomDataOwner, afterRoomSequence: UInt64,
                highWatermark: UInt64, records: [V2RoomSubscriptionSourceRecord]) {
        self.roomID = roomID; self.owner = owner; self.afterRoomSequence = afterRoomSequence
        self.highWatermark = highWatermark; self.records = records
    }
}

/// Internal owner-only source. The caller authenticates owner identity; the
/// store checks its persisted fence. tracked users are the bounded online set,
/// never the complete large-group roster. Each call uses one MVCC SQL snapshot.
public protocol V2RoomSubscriptionSource: Sendable {
    func snapshot(roomID: RoomID, owner: V2RoomDataOwner,
                  trackedUserIDs: Set<UserID>) async throws -> V2RoomSubscriptionSourceSnapshot
    func read(roomID: RoomID, owner: V2RoomDataOwner, afterRoomSequence: UInt64,
              trackedUserIDs: Set<UserID>, limit: Int) async throws -> V2RoomSubscriptionSourcePage
}


/// Obtained only after a room mutation commits, under the same execution turn.
/// This complete cut can advance several durable versions in one transaction.
public struct V2RoomCommittedPermissionEffect: Sendable {
    public let activation: V2RoomActivationToken
    public let snapshot: V2RoomSubscriptionSourceSnapshot
    public let requiresReceiveReset: Bool
    public init(activation: V2RoomActivationToken, snapshot: V2RoomSubscriptionSourceSnapshot,
                requiresReceiveReset: Bool = true) {
        self.activation = activation; self.snapshot = snapshot; self.requiresReceiveReset = requiresReceiveReset
    }
}

/// A room command returns its committed cut together with the business result.
/// Rejections or commands that make no permission change have no new cut.
public struct V2RoomPermissionMutationResult<Result: Sendable>: Sendable {
    public let result: Result
    public let effect: V2RoomCommittedPermissionEffect?
    public init(result: Result, effect: V2RoomCommittedPermissionEffect?) {
        self.result = result; self.effect = effect
    }
}
