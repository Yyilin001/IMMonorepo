import Foundation
import IMV2Core

/// 虽然都使用文本 ID，稳定身份仍有意保持不同类型。
public enum V2ActorAdministrationOperationIdentity: Equatable, Sendable {
    case membership(MembershipOperationID)
    case pinned(PinnedMessageOperationID)
    case announcement(GroupAnnouncementOperationID)
    case rolePermissions(GroupPermissionOperationID)
    case memberRole(GroupRoleOperationID)
    case moderation(ModerationOperationID)
    case groupNickname(GroupNicknameOperationID)
    case groupAvatar(GroupAvatarOperationID)
    case groupAvatarRecovery(GroupAvatarOperationID, V2GroupAvatarRecoveryRequest.Action)
}

public struct V2ActorGroupAvatarWire: Codable, Equatable, Sendable {
    public let actorUserID: UserID
    public let command: V2GroupAvatarCommand
    public var roomID: RoomID { command.roomID }
    public init(actorUserID: UserID, command: V2GroupAvatarCommand) {
        self.actorUserID = actorUserID; self.command = command
    }
}
public struct V2ActorGroupAvatarRecoveryWire: Codable, Equatable, Sendable {
    public let actorUserID: UserID
    public let request: V2GroupAvatarRecoveryRequest
    public var roomID: RoomID { request.command.roomID }
    public init(actorUserID: UserID, request: V2GroupAvatarRecoveryRequest) { self.actorUserID = actorUserID; self.request = request }
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
    /// 规范写入方按原始值排序；读取方在映射到领域模型前拒绝重复项。
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
    /// 必须显式定义字符串镜像：Core 自动生成的原因码解码器会跳过校验。
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

/// 可信通道不接收调用方提供的用户身份。
/// 将来的传输或执行器调用存储前，必须检查服务角色授权。
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

/// 事件 ID、时钟值和容量配置有意由执行器负责。
public enum V2RoomAdministrationCommand: Codable, Equatable, Sendable {
    case membership(V2ActorMembershipChangeWire)
    case pinned(V2ActorPinnedMessageWire)
    case announcement(V2ActorGroupAnnouncementWire)
    case rolePermissions(V2ActorRolePermissionsWire)
    case memberRole(V2ActorMemberRoleWire)
    case moderation(V2ActorModerationWire)
    case trustedSafety(V2ActorTrustedSafetyWire)
    case groupNickname(V2ActorGroupNicknameUpdateWire)
    case groupAvatar(V2ActorGroupAvatarWire)
    case groupAvatarRecovery(V2ActorGroupAvatarRecoveryWire)

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
        case .groupAvatar(let value): value.roomID
        case .groupAvatarRecovery(let value): value.roomID
        }
    }

    /// nil 保留给另行授权的可信服务通道。
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
        case .groupAvatar(let value): value.actorUserID
        case .groupAvatarRecovery(let value): value.actorUserID
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
        case .groupAvatar(let value): .groupAvatar(value.command.operationID)
        case .groupAvatarRecovery(let value): .groupAvatarRecovery(value.request.command.operationID, value.request.action)
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
