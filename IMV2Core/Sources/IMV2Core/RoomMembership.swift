import Foundation

/// V2 deliberately starts with a small, explicit room authority model. Role
/// changes themselves are a future operation; no membership command silently
/// upgrades a member or infers administrative authority.
public enum V2RoomMembershipRole: String, Codable, Equatable, Sendable {
    case owner
    case admin
    case member
}

public enum V2RoomMembershipAction: String, Codable, Equatable, Sendable {
    case add
    case remove
}

/// The operation ID is durable client intent, not a transport request ID. The
/// same actor may retry it after a lost response and must receive its original
/// result; changing any immutable field is an idempotency conflict.
public struct V2ChangeRoomMembershipCommand: Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: MembershipOperationID
    public let targetUserID: UserID
    public let action: V2RoomMembershipAction
    public let expectedRevision: V2MembershipRevision
    public var expectedMembershipRevision: UInt64 { expectedRevision.rawValue }

    public init(
        roomID: RoomID,
        actorUserID: UserID,
        operationID: MembershipOperationID,
        targetUserID: UserID,
        action: V2RoomMembershipAction,
        expectedMembershipRevision: UInt64
    ) throws {
        guard actorUserID != targetUserID else { throw V2RoomMembershipValidationError.selfTargetingNotAllowed }
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.targetUserID = targetUserID
        self.action = action
        self.expectedRevision = try .init(expectedMembershipRevision)
    }
}

public struct V2RoomMembershipChange: Equatable, Sendable {
    public let roomID: RoomID
    public let targetUserID: UserID
    public let action: V2RoomMembershipAction
    public let membershipRevision: UInt64
    public let roomSequence: UInt64
    public let eventID: EventID
    public let fanoutPlanID: FanoutPlanID
    public let createdAt: Date

    public init(roomID: RoomID, targetUserID: UserID, action: V2RoomMembershipAction, membershipRevision: UInt64, roomSequence: UInt64, eventID: EventID, fanoutPlanID: FanoutPlanID, createdAt: Date) throws {
        guard membershipRevision > 0, membershipRevision <= UInt64(Int64.max),
              roomSequence > 0, roomSequence <= UInt64(Int64.max)
        else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID
        self.targetUserID = targetUserID
        self.action = action
        self.membershipRevision = membershipRevision
        self.roomSequence = roomSequence
        self.eventID = eventID
        self.fanoutPlanID = fanoutPlanID
        self.createdAt = createdAt
    }
}

public enum V2RoomMembershipValidationError: Error, Equatable, Sendable {
    case selfTargetingNotAllowed
}
