import Foundation
import IMV2Core

/// 虽然都使用文本 ID，稳定身份仍有意保持不同类型。
public enum V2ActorAdministrationOperationIdentity: Equatable, Sendable {
    case conversationState(ConversationPreferenceOperationID)
    case messageFavorite(MessageFavoriteOperationID)
    case personalPreferenceRecovery(V2OperationIdentity, V2OperationRecoveryRequest.Action)
    case groupInvitation(V2OperationIdentity)
    case groupCapability(V2OperationIdentity)
    case memberAdministration(ModerationOperationID)
    case membership(MembershipOperationID)
    case pinned(PinnedMessageOperationID)
    case announcement(GroupAnnouncementOperationID)
    case rolePermissions(GroupPermissionOperationID)
    case memberRole(GroupRoleOperationID)
    case moderation(ModerationOperationID)
    case groupNickname(GroupNicknameOperationID)
    case groupNicknameRecovery(GroupNicknameOperationID,V2OperationRecoveryRequest.Action)
    case groupAvatar(GroupAvatarOperationID)
    case groupAvatarRecovery(GroupAvatarOperationID, V2GroupAvatarRecoveryRequest.Action)
}

public struct V2ActorConversationStateWire: Codable, Equatable, Sendable {
    public let actorUserID: UserID
    public let command: V2ConversationStateCommand
    public var roomID: RoomID { command.roomID }
    public init(actorUserID:UserID,command:V2ConversationStateCommand) { self.actorUserID=actorUserID;self.command=command }
}
public struct V2ActorMessageFavoriteWire: Codable, Equatable, Sendable {
    public let actorUserID: UserID
    public let command: V2MessageFavoriteCommand
    public var roomID: RoomID { command.roomID }
    public init(actorUserID:UserID,command:V2MessageFavoriteCommand) { self.actorUserID=actorUserID;self.command=command }
}
public struct V2ActorPersonalPreferenceRecoveryWire: Codable, Equatable, Sendable {
    public let request: V2PersonalPreferenceRecoveryRequest
    public var actorUserID: UserID { request.identity.accountID }
    public var roomID: RoomID { request.roomID }
    public init(request:V2PersonalPreferenceRecoveryRequest) { self.request=request }
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

public struct V2ActorGroupNicknameUpdateWire: Codable,Equatable,Sendable {
    public let command:V2GroupNicknameUpdateCommand
    public var roomID:RoomID { command.roomID }
    public var actorUserID:UserID { command.actorUserID }
    public var operationID:GroupNicknameOperationID { command.operationID }
    public var expectedRevision:V2ProfileRevision? { command.expectedRevision }
    public var nickname:String? { command.nickname }
    public init(command:V2GroupNicknameUpdateCommand) { self.command=command }
}
public struct V2ActorOwnGroupNicknameQueryWire: Codable,Equatable,Sendable {
    public let roomID:RoomID
    public let actorUserID:UserID
    public init(roomID:RoomID,actorUserID:UserID) { self.roomID=roomID;self.actorUserID=actorUserID }
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
    case membershipAdmission(V2MembershipIntent)
    case membershipSubmit(V2MembershipOperationCommand)
    case membershipRecovery(V2MembershipRecoveryRequest)
    case groupInvitationAdmit(V2GroupInvitationOperationIntent)
    case groupInvitationSubmit(V2GroupInvitationExecutionRequest)
    case groupInvitationRecover(V2GroupInvitationRecoveryRequest)
    case groupCapabilityAdmit(V2GroupCapabilityIntent)
    case groupCapabilitySubmit(V2GroupCapabilityCommand)
    case groupCapabilityRecover(V2GroupCapabilityRecoveryRequest)
    case messageModerationAdmission(V2MessageModerationIntent)
    case messageModerationSubmit(V2MessageModerationCommand)
    case messageModerationRecovery(V2MessageModerationRecoveryRequest)
    case memberAdministrationAdmission(V2MemberAdministrationIntent)
    case memberAdministrationSubmit(V2MemberAdministrationCommand)
    case memberAdministrationRecovery(V2MemberAdministrationRecoveryRequest)
    case trustedSafety(V2ActorTrustedSafetyWire)
    case groupNickname(V2ActorGroupNicknameUpdateWire)
    case groupNicknameRecovery(V2GroupNicknameRecoveryRequest)
    case conversationState(V2ActorConversationStateWire)
    case messageFavorite(V2ActorMessageFavoriteWire)
    case personalPreferenceRecovery(V2ActorPersonalPreferenceRecoveryWire)
    case groupAvatar(V2ActorGroupAvatarWire)
    case groupAvatarRecovery(V2ActorGroupAvatarRecoveryWire)

    public var roomID: RoomID {
        switch self {
        case .membershipAdmission(let value): value.roomID
        case .membershipSubmit(let value): value.intent.roomID
        case .membershipRecovery(let value): if case .room(let room)=value.identity.scope { room } else { preconditionFailure("Validated room scope") }
        case .groupInvitationAdmit(let value): value.roomID
        case .groupInvitationSubmit(let value): value.command.intent.roomID
        case .groupInvitationRecover(let value): value.intent.roomID
        case .groupCapabilityAdmit(let value): value.roomID
        case .groupCapabilitySubmit(let value): value.intent.roomID
        case .groupCapabilityRecover(let value): switch value.identity.scope { case .room(let room), .message(let room,_): room; default: preconditionFailure("Validated room scope") }
        case .messageModerationAdmission(let value): value.roomID
        case .messageModerationSubmit(let value): value.intent.roomID
        case .messageModerationRecovery(let value): value.intent.roomID
        case .memberAdministrationAdmission(let value): value.roomID
        case .memberAdministrationSubmit(let value): value.intent.roomID
        case .memberAdministrationRecovery(let value): if case .room(let room)=value.identity.scope { room } else { preconditionFailure("Validated room scope") }
        case .trustedSafety(let value): value.roomID
        case .groupNickname(let value): value.roomID
        case .groupNicknameRecovery(let value): value.roomID
        case .conversationState(let value): value.roomID
        case .messageFavorite(let value): value.roomID
        case .personalPreferenceRecovery(let value): value.roomID
        case .groupAvatar(let value): value.roomID
        case .groupAvatarRecovery(let value): value.roomID
        }
    }

    /// nil 保留给另行授权的可信服务通道。
    public var actorUserID: UserID? {
        switch self {
        case .membershipAdmission(let value): value.actorUserID
        case .membershipSubmit(let value): value.intent.actorUserID
        case .membershipRecovery(let value): value.identity.accountID
        case .groupInvitationAdmit(let value): value.identity.accountID
        case .groupInvitationSubmit(let value): value.command.identity.accountID
        case .groupInvitationRecover(let value): value.intent.identity.accountID
        case .groupCapabilityAdmit(let value): value.identity.accountID
        case .groupCapabilitySubmit(let value): value.identity.accountID
        case .groupCapabilityRecover(let value): value.identity.accountID
        case .messageModerationAdmission(let value): value.actorUserID
        case .messageModerationSubmit(let value): value.intent.actorUserID
        case .messageModerationRecovery(let value): value.intent.actorUserID
        case .memberAdministrationAdmission(let value): value.actorUserID
        case .memberAdministrationSubmit(let value): value.intent.actorUserID
        case .memberAdministrationRecovery(let value): value.identity.accountID
        case .trustedSafety: nil
        case .groupNickname(let value): value.actorUserID
        case .groupNicknameRecovery(let value): value.actorUserID
        case .conversationState(let value): value.actorUserID
        case .messageFavorite(let value): value.actorUserID
        case .personalPreferenceRecovery(let value): value.actorUserID
        case .groupAvatar(let value): value.actorUserID
        case .groupAvatarRecovery(let value): value.actorUserID
        }
    }

    public var stableOperationIdentity: V2ActorAdministrationOperationIdentity {
        switch self {
        case .membershipAdmission(let value): .membership(value.operationID)
        case .membershipSubmit(let value): .membership(value.intent.operationID)
        case .membershipRecovery(let value): .membership(try! MembershipOperationID(value.identity.operation.rawOperationID))
        case .groupInvitationAdmit(let value): .groupInvitation(value.identity)
        case .groupInvitationSubmit(let value): .groupInvitation(value.command.identity)
        case .groupInvitationRecover(let value): .groupInvitation(value.intent.identity)
        case .groupCapabilityAdmit(let value): .groupCapability(value.identity)
        case .groupCapabilitySubmit(let value): .groupCapability(value.identity)
        case .groupCapabilityRecover(let value): .groupCapability(value.identity)
        case .messageModerationAdmission(let value): .moderation(value.operationID)
        case .messageModerationSubmit(let value): .moderation(value.intent.operationID)
        case .messageModerationRecovery(let value): .moderation(value.intent.operationID)
        case .memberAdministrationAdmission(let value): .memberAdministration(value.operationID)
        case .memberAdministrationSubmit(let value): .memberAdministration(value.intent.operationID)
        case .memberAdministrationRecovery(let value): .memberAdministration(try! ModerationOperationID(value.identity.operation.rawOperationID))
        case .trustedSafety(let value): .moderation(value.operationID)
        case .groupNickname(let value): .groupNickname(value.operationID)
        case .groupNicknameRecovery(let value): .groupNicknameRecovery(value.operationID,value.action)
        case .conversationState(let value): .conversationState(value.command.operationID)
        case .messageFavorite(let value): .messageFavorite(value.command.operationID)
        case .personalPreferenceRecovery(let value): .personalPreferenceRecovery(value.request.identity,value.request.action)
        case .groupAvatar(let value): .groupAvatar(value.command.operationID)
        case .groupAvatarRecovery(let value): .groupAvatarRecovery(value.request.command.operationID, value.request.action)
        }
    }

    public var retryPolicy: V2RoomReplayPolicy { .durableIdempotent }
}

public enum V2RoomAdministrationQuery: Codable, Equatable, Sendable {
    case messageModerationBaseline(V2MessageModerationBaselineQuery)
    case groupInvitationBaseline(V2GroupInvitationOperationBaselineQuery)
    case pinnedBaseline(V2PinnedMessageBaselineQuery)
    case groupNicknames(V2ActorGroupNicknamesQueryWire)
    case ownGroupNickname(V2ActorOwnGroupNicknameQueryWire)

    public var roomID: RoomID { switch self { case .messageModerationBaseline(let value):value.roomID;case .groupInvitationBaseline(let value): value.roomID; case .pinnedBaseline(let value): value.roomID; case .groupNicknames(let value): value.roomID;case .ownGroupNickname(let value):value.roomID } }
    public var actorUserID: UserID { switch self { case .messageModerationBaseline(let value):value.actorUserID;case .groupInvitationBaseline(let value): value.actorUserID; case .pinnedBaseline(let value): value.actorUserID; case .groupNicknames(let value): value.actorUserID;case .ownGroupNickname(let value):value.actorUserID } }
    public var retryPolicy: V2RoomReplayPolicy { .readOnly }
}
