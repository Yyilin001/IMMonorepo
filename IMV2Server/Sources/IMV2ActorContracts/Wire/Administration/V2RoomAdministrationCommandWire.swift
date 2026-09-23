import Foundation
import IMV2Core

/// Stable identities are deliberately distinct even though each uses a textual ID.
public enum V2ActorAdministrationOperationIdentity: Equatable, Sendable {
    case membership(MembershipOperationID)
    case pinned(PinnedMessageOperationID)
    case announcement(GroupAnnouncementOperationID)
    case rolePermissions(GroupPermissionOperationID)
    case memberRole(GroupRoleOperationID)
    case moderation(ModerationOperationID)
    case groupNickname(GroupNicknameOperationID)
}

public struct V2ActorMembershipChangeWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: MembershipOperationID
    public let targetUserID: UserID
    public let action: V2RoomMembershipAction
    public let expectedMembershipRevision: UInt64

    public init(roomID: RoomID, actorUserID: UserID, operationID: MembershipOperationID,
                targetUserID: UserID, action: V2RoomMembershipAction, expectedMembershipRevision: UInt64) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.operationID = operationID
        self.targetUserID = targetUserID; self.action = action
        self.expectedMembershipRevision = expectedMembershipRevision
    }
}

public struct V2ActorPinnedMessageWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: PinnedMessageOperationID
    public let messageID: MessageID
    public let isPinned: Bool

    public init(roomID: RoomID, actorUserID: UserID, operationID: PinnedMessageOperationID,
                messageID: MessageID, isPinned: Bool) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.operationID = operationID
        self.messageID = messageID; self.isPinned = isPinned
    }
}

public struct V2ActorGroupAnnouncementWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: GroupAnnouncementOperationID
    public let body: String
    public let expectedRevision: UInt64

    public init(roomID: RoomID, actorUserID: UserID, operationID: GroupAnnouncementOperationID,
                body: String, expectedRevision: UInt64) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.operationID = operationID
        self.body = body; self.expectedRevision = expectedRevision
    }
}

public struct V2ActorRolePermissionsWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: GroupPermissionOperationID
    public let role: V2RoomMembershipRole
    /// Canonical writers sort by raw value; readers reject duplicates before domain mapping.
    public let permissions: [V2GroupPermission]
    public let expectedRevision: UInt64

    public init(roomID: RoomID, actorUserID: UserID, operationID: GroupPermissionOperationID,
                role: V2RoomMembershipRole, permissions: [V2GroupPermission], expectedRevision: UInt64) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.operationID = operationID
        self.role = role; self.permissions = permissions; self.expectedRevision = expectedRevision
    }
}

public struct V2ActorMemberRoleWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: GroupRoleOperationID
    public let targetUserID: UserID
    public let role: V2RoomMembershipRole
    public let expectedMembershipRevision: UInt64

    public init(roomID: RoomID, actorUserID: UserID, operationID: GroupRoleOperationID,
                targetUserID: UserID, role: V2RoomMembershipRole, expectedMembershipRevision: UInt64) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.operationID = operationID
        self.targetUserID = targetUserID; self.role = role
        self.expectedMembershipRevision = expectedMembershipRevision
    }
}

public struct V2ActorModerationWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: ModerationOperationID
    public let action: V2ModerationAction
    public let targetUserID: UserID?
    public let messageID: MessageID?
    public let expectedMessageRevision: UInt64?
    public let muteUntil: Date?
    /// A string mirror is required: Core's synthesized reason-code decoder skips validation.
    public let reasonCode: String

    public init(roomID: RoomID, actorUserID: UserID, operationID: ModerationOperationID,
                action: V2ModerationAction, targetUserID: UserID?, messageID: MessageID?,
                expectedMessageRevision: UInt64?, muteUntil: Date?, reasonCode: String) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.operationID = operationID
        self.action = action; self.targetUserID = targetUserID; self.messageID = messageID
        self.expectedMessageRevision = expectedMessageRevision; self.muteUntil = muteUntil
        self.reasonCode = reasonCode
    }
}

/// The trusted lane has no caller-supplied user identity. Service-role authorization
/// must be checked by the future transport/executor before invoking its store.
public struct V2ActorTrustedSafetyWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let operationID: ModerationOperationID
    public let action: V2ModerationAction
    public let messageID: MessageID?
    public let expectedMessageRevision: UInt64?
    public let reasonCode: String

    public init(roomID: RoomID, operationID: ModerationOperationID, action: V2ModerationAction,
                messageID: MessageID?, expectedMessageRevision: UInt64?, reasonCode: String) {
        self.roomID = roomID; self.operationID = operationID; self.action = action
        self.messageID = messageID; self.expectedMessageRevision = expectedMessageRevision
        self.reasonCode = reasonCode
    }
}

public struct V2ActorGroupNicknameUpdateWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: GroupNicknameOperationID
    public let expectedRevision: V2ProfileRevision?
    public let nickname: String?

    public init(roomID: RoomID, actorUserID: UserID, operationID: GroupNicknameOperationID,
                expectedRevision: V2ProfileRevision?, nickname: String?) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.operationID = operationID
        self.expectedRevision = expectedRevision; self.nickname = nickname
    }
}

public struct V2ActorGroupNicknamesQueryWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let afterUserID: UserID?
    public let limit: Int

    public init(roomID: RoomID, actorUserID: UserID, afterUserID: UserID?, limit: Int) {
        self.roomID = roomID; self.actorUserID = actorUserID
        self.afterUserID = afterUserID; self.limit = limit
    }
}

/// Event IDs, clock values and capacity profile are deliberately executor-owned.
public enum V2RoomAdministrationCommand: Codable, Equatable, Sendable {
    case membership(V2ActorMembershipChangeWire)
    case pinned(V2ActorPinnedMessageWire)
    case announcement(V2ActorGroupAnnouncementWire)
    case rolePermissions(V2ActorRolePermissionsWire)
    case memberRole(V2ActorMemberRoleWire)
    case moderation(V2ActorModerationWire)
    case trustedSafety(V2ActorTrustedSafetyWire)
    case groupNickname(V2ActorGroupNicknameUpdateWire)

    public var roomID: RoomID {
        switch self {
        case .membership(let value): value.roomID
        case .pinned(let value): value.roomID
        case .announcement(let value): value.roomID
        case .rolePermissions(let value): value.roomID
        case .memberRole(let value): value.roomID
        case .moderation(let value): value.roomID
        case .trustedSafety(let value): value.roomID
        case .groupNickname(let value): value.roomID
        }
    }

    /// Nil is reserved for the separately authorized trusted service lane.
    public var actorUserID: UserID? {
        switch self {
        case .membership(let value): value.actorUserID
        case .pinned(let value): value.actorUserID
        case .announcement(let value): value.actorUserID
        case .rolePermissions(let value): value.actorUserID
        case .memberRole(let value): value.actorUserID
        case .moderation(let value): value.actorUserID
        case .trustedSafety: nil
        case .groupNickname(let value): value.actorUserID
        }
    }

    public var stableOperationIdentity: V2ActorAdministrationOperationIdentity {
        switch self {
        case .membership(let value): .membership(value.operationID)
        case .pinned(let value): .pinned(value.operationID)
        case .announcement(let value): .announcement(value.operationID)
        case .rolePermissions(let value): .rolePermissions(value.operationID)
        case .memberRole(let value): .memberRole(value.operationID)
        case .moderation(let value): .moderation(value.operationID)
        case .trustedSafety(let value): .moderation(value.operationID)
        case .groupNickname(let value): .groupNickname(value.operationID)
        }
    }

    public var retryPolicy: V2RoomReplayPolicy { .durableIdempotent }
}

public enum V2RoomAdministrationQuery: Codable, Equatable, Sendable {
    case groupNicknames(V2ActorGroupNicknamesQueryWire)

    public var roomID: RoomID { switch self { case .groupNicknames(let value): value.roomID } }
    public var actorUserID: UserID { switch self { case .groupNicknames(let value): value.actorUserID } }
    public var retryPolicy: V2RoomReplayPolicy { .readOnly }
}
