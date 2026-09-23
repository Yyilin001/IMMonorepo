import Foundation
import IMV2Core

public struct V2ActorMembershipChangeResultWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let targetUserID: UserID
    public let action: V2RoomMembershipAction
    public let membershipRevision: UInt64
    public let roomSequence: UInt64
    public let eventID: EventID
    public let createdAt: Date

    public init(roomID: RoomID, targetUserID: UserID, action: V2RoomMembershipAction,
                membershipRevision: UInt64, roomSequence: UInt64, eventID: EventID, createdAt: Date) {
        self.roomID = roomID; self.targetUserID = targetUserID; self.action = action
        self.membershipRevision = membershipRevision; self.roomSequence = roomSequence
        self.eventID = eventID; self.createdAt = createdAt
    }
}

public enum V2ActorMembershipOutcomeWire: Codable, Equatable, Sendable {
    case changed(V2ActorMembershipChangeResultWire)
    case idempotent(V2ActorMembershipChangeResultWire)
    case idempotencyConflict
    case revisionConflict(current: UInt64)
    case targetAlreadyMember
    case targetNotMember
    case memberLimitReached
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(V2ActorAdmissionUnavailableWire)
}

public struct V2ActorPinnedMessageResultWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let isPinned: Bool
    public let roomSequence: UInt64
    public let updatedAt: Date

    public init(roomID: RoomID, messageID: MessageID, isPinned: Bool, roomSequence: UInt64,
                updatedAt: Date) {
        self.roomID = roomID; self.messageID = messageID; self.isPinned = isPinned
        self.roomSequence = roomSequence; self.updatedAt = updatedAt
    }
}

public struct V2ActorGroupAnnouncementResultWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let body: String
    public let revision: UInt64
    public let roomSequence: UInt64
    public let updatedAt: Date

    public init(roomID: RoomID, body: String, revision: UInt64, roomSequence: UInt64,
                updatedAt: Date) {
        self.roomID = roomID; self.body = body; self.revision = revision
        self.roomSequence = roomSequence; self.updatedAt = updatedAt
    }
}

public struct V2ActorRolePermissionsResultWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let role: V2RoomMembershipRole
    public let permissions: [V2GroupPermission]
    public let revision: UInt64
    public let roomSequence: UInt64

    public init(roomID: RoomID, role: V2RoomMembershipRole, permissions: [V2GroupPermission],
                revision: UInt64, roomSequence: UInt64) {
        self.roomID = roomID; self.role = role; self.permissions = permissions
        self.revision = revision; self.roomSequence = roomSequence
    }
}

public struct V2ActorMemberRoleResultWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let targetUserID: UserID
    public let role: V2RoomMembershipRole
    public let membershipRevision: UInt64
    public let roomSequence: UInt64

    public init(roomID: RoomID, targetUserID: UserID, role: V2RoomMembershipRole,
                membershipRevision: UInt64, roomSequence: UInt64) {
        self.roomID = roomID; self.targetUserID = targetUserID; self.role = role
        self.membershipRevision = membershipRevision; self.roomSequence = roomSequence
    }
}

public enum V2ActorGroupCapabilityOutcomeWire<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    case applied(Value)
    case idempotent(Value)
    case idempotencyConflict
    case alreadyInDesiredState
    case revisionConflict
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(V2ActorAdmissionUnavailableWire)
}

public struct V2ActorModerationResultWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let operationID: ModerationOperationID
    public let action: V2ModerationAction
    public let targetUserID: UserID?
    public let messageID: MessageID?
    public let messageRevision: UInt64?
    public let membershipRevision: UInt64?
    public let muteUntil: Date?
    public let roomSequence: UInt64
    public let eventID: EventID
    public let createdAt: Date

    public init(roomID: RoomID, operationID: ModerationOperationID, action: V2ModerationAction,
                targetUserID: UserID?, messageID: MessageID?, messageRevision: UInt64?,
                membershipRevision: UInt64?, muteUntil: Date?, roomSequence: UInt64,
                eventID: EventID, createdAt: Date) {
        self.roomID = roomID; self.operationID = operationID; self.action = action
        self.targetUserID = targetUserID; self.messageID = messageID
        self.messageRevision = messageRevision; self.membershipRevision = membershipRevision
        self.muteUntil = muteUntil; self.roomSequence = roomSequence
        self.eventID = eventID; self.createdAt = createdAt
    }
}

public enum V2ActorModerationOutcomeWire: Codable, Equatable, Sendable {
    case applied(V2ActorModerationResultWire)
    case idempotent(V2ActorModerationResultWire)
    case idempotencyConflict
    case targetNotMember
    case messageAlreadyRedacted
    case actionAlreadyInDesiredState
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(V2ActorAdmissionUnavailableWire)
}

/// Explicit mirror: Core's synthesized presentation decoder bypasses nickname validation.
public struct V2ActorGroupMemberPresentationWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let userID: UserID
    public let groupNickname: String?
    public let revision: V2ProfileRevision

    public init(roomID: RoomID, userID: UserID, groupNickname: String?, revision: V2ProfileRevision) {
        self.roomID = roomID; self.userID = userID
        self.groupNickname = groupNickname; self.revision = revision
    }
}

public struct V2ActorGroupNicknamePageWire: Codable, Equatable, Sendable {
    public let values: [V2ActorGroupMemberPresentationWire]
    public let nextCursor: UserID?

    public init(values: [V2ActorGroupMemberPresentationWire], nextCursor: UserID?) {
        self.values = values; self.nextCursor = nextCursor
    }
}

public enum V2RoomAdministrationResult: Codable, Equatable, Sendable {
    case failure(V2ActorAdministrationFailureWire)
    case membership(V2ActorMembershipOutcomeWire)
    case pinned(V2ActorGroupCapabilityOutcomeWire<V2ActorPinnedMessageResultWire>)
    case announcement(V2ActorGroupCapabilityOutcomeWire<V2ActorGroupAnnouncementResultWire>)
    case rolePermissions(V2ActorGroupCapabilityOutcomeWire<V2ActorRolePermissionsResultWire>)
    case memberRole(V2ActorGroupCapabilityOutcomeWire<V2ActorMemberRoleResultWire>)
    case moderation(V2ActorModerationOutcomeWire)
    case trustedSafety(V2ActorModerationOutcomeWire)
    case groupNickname(V2ActorGroupMemberPresentationWire)
    case groupNicknames(V2ActorGroupNicknamePageWire)
}
