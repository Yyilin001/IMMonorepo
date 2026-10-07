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
    public let remainingLeaseMilliseconds: Int64
    public let members: [V2RoomSubscriptionSourceMember]
    public init(roomID: RoomID, owner: V2RoomDataOwner, highWatermark: UInt64, membershipRevision: UInt64 = 0, roomControlVersion: Int64 = 0, remainingLeaseMilliseconds: Int64 = 0,
                members: [V2RoomSubscriptionSourceMember]) {
        self.roomID = roomID; self.owner = owner; self.highWatermark = highWatermark
        self.roomControlVersion = roomControlVersion; self.membershipRevision = membershipRevision; self.remainingLeaseMilliseconds = remainingLeaseMilliseconds; self.members = members
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
    public let remainingLeaseMilliseconds: Int64
    public init(roomID: RoomID, owner: V2RoomDataOwner, afterRoomSequence: UInt64,
                highWatermark: UInt64, records: [V2RoomSubscriptionSourceRecord], remainingLeaseMilliseconds: Int64 = 0) {
        self.roomID = roomID; self.owner = owner; self.afterRoomSequence = afterRoomSequence
        self.highWatermark = highWatermark; self.records = records; self.remainingLeaseMilliseconds = remainingLeaseMilliseconds
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

/// Trusted local Host observation, never caller-supplied authority. Combines
/// its confirmed activation safety deadline with a fresh ordered control cut.
/// Renewal performs no credential, membership or activation database lookup.
public struct V2RoomSubscriptionLeaseProof: Equatable, Sendable {
    public let activation: V2RoomActivationToken
    public let committedRoomSequence: UInt64
    public let roomControlVersion: Int64
    public let remainingLeaseMilliseconds: Int64
    public init(activation: V2RoomActivationToken, committedRoomSequence: UInt64, roomControlVersion: Int64 = 0, remainingLeaseMilliseconds: Int64) {
        self.activation = activation; self.committedRoomSequence = committedRoomSequence
        self.roomControlVersion = roomControlVersion; self.remainingLeaseMilliseconds = remainingLeaseMilliseconds
    }
}
