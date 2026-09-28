import Foundation

/// Stable domain registration key. Unknown kinds are rejected by Codable.
public enum V2OperationKind: String, CaseIterable, Codable, Sendable {
    case sendMessage
    case withdrawMessage
    case editMessage
    case reaction
    case readReceipt
    case directRoom
    case groupRoom
    case membership
    case moderation
    case memberMute
    case moderatedMemberRemoval
    case strangerMessagePreference
    case userAddPreference
    case readReceiptPreference
    case liveActivityPreference
    case relationship
    case userBlock
    case conversationPreference
    case messageFavorite
    case pinnedMessage
    case groupAnnouncement
    case groupPermission
    case groupRole
    case forwardMessage
    case profileUpdate
    case contactAlias
    case groupNickname
    case groupInvite
    case groupJoinRequest
    case groupJoinDecision
    case mediaUpload
    case groupAvatar
}

/// Preserves the original domain identity; a retry never manufactures a new ID.
public enum V2OperationReference: Equatable, Codable, Sendable {
    case sendMessage(ClientMessageID)
    case withdrawMessage(MessageWithdrawalOperationID)
    case editMessage(MessageEditOperationID)
    case reaction(MessageReactionOperationID)
    case readReceipt(ReadReceiptOperationID)
    case directRoom(DirectRoomOperationID)
    case groupRoom(GroupRoomOperationID)
    case membership(MembershipOperationID)
    case moderation(ModerationOperationID)
    case memberMute(ModerationOperationID)
    case moderatedMemberRemoval(ModerationOperationID)
    case strangerMessagePreference(StrangerMessagePreferenceOperationID)
    case userAddPreference(UserAddPreferenceOperationID)
    case readReceiptPreference(ReadReceiptPreferenceOperationID)
    case liveActivityPreference(LiveActivityPreferenceOperationID)
    case relationship(RelationshipOperationID)
    case userBlock(UserBlockOperationID)
    case conversationPreference(ConversationPreferenceOperationID)
    case messageFavorite(MessageFavoriteOperationID)
    case pinnedMessage(PinnedMessageOperationID)
    case groupAnnouncement(GroupAnnouncementOperationID)
    case groupPermission(GroupPermissionOperationID)
    case groupRole(GroupRoleOperationID)
    case forwardMessage(MessageForwardOperationID)
    case profileUpdate(ProfileUpdateOperationID)
    case contactAlias(ContactAliasOperationID)
    case groupNickname(GroupNicknameOperationID)
    case groupInvite(GroupInviteOperationID)
    case groupJoinRequest(GroupJoinRequestOperationID)
    case groupJoinDecision(GroupJoinDecisionOperationID)
    case mediaUpload(MediaUploadOperationID)
    case groupAvatar(GroupAvatarOperationID)
    public var kind: V2OperationKind {
        switch self {
        case .sendMessage: .sendMessage
        case .withdrawMessage: .withdrawMessage
        case .editMessage: .editMessage
        case .reaction: .reaction
        case .readReceipt: .readReceipt
        case .directRoom: .directRoom
        case .groupRoom: .groupRoom
        case .membership: .membership
        case .moderation: .moderation
        case .memberMute: .memberMute
        case .moderatedMemberRemoval: .moderatedMemberRemoval
        case .strangerMessagePreference: .strangerMessagePreference
        case .userAddPreference: .userAddPreference
        case .readReceiptPreference: .readReceiptPreference
        case .liveActivityPreference: .liveActivityPreference
        case .relationship: .relationship
        case .userBlock: .userBlock
        case .conversationPreference: .conversationPreference
        case .messageFavorite: .messageFavorite
        case .pinnedMessage: .pinnedMessage
        case .groupAnnouncement: .groupAnnouncement
        case .groupPermission: .groupPermission
        case .groupRole: .groupRole
        case .forwardMessage: .forwardMessage
        case .profileUpdate: .profileUpdate
        case .contactAlias: .contactAlias
        case .groupNickname: .groupNickname
        case .groupInvite: .groupInvite
        case .groupJoinRequest: .groupJoinRequest
        case .groupJoinDecision: .groupJoinDecision
        case .groupAvatar: .groupAvatar
        case .mediaUpload: .mediaUpload
        }
    }
    public var rawOperationID: String { rawValue }
    public var rawValue: String {
        switch self {
        case .sendMessage(let id): id.rawValue
        case .withdrawMessage(let id): id.rawValue
        case .editMessage(let id): id.rawValue
        case .reaction(let id): id.rawValue
        case .readReceipt(let id): id.rawValue
        case .directRoom(let id): id.rawValue
        case .groupRoom(let id): id.rawValue
        case .membership(let id): id.rawValue
        case .moderation(let id): id.rawValue
        case .memberMute(let id): id.rawValue
        case .moderatedMemberRemoval(let id): id.rawValue
        case .strangerMessagePreference(let id): id.rawValue
        case .userAddPreference(let id): id.rawValue
        case .readReceiptPreference(let id): id.rawValue
        case .liveActivityPreference(let id): id.rawValue
        case .relationship(let id): id.rawValue
        case .userBlock(let id): id.rawValue
        case .conversationPreference(let id): id.rawValue
        case .messageFavorite(let id): id.rawValue
        case .pinnedMessage(let id): id.rawValue
        case .groupAnnouncement(let id): id.rawValue
        case .groupPermission(let id): id.rawValue
        case .groupRole(let id): id.rawValue
        case .forwardMessage(let id): id.rawValue
        case .profileUpdate(let id): id.rawValue
        case .contactAlias(let id): id.rawValue
        case .groupNickname(let id): id.rawValue
        case .groupInvite(let id): id.rawValue
        case .groupJoinRequest(let id): id.rawValue
        case .groupJoinDecision(let id): id.rawValue
        case .groupAvatar(let id): id.rawValue
        case .mediaUpload(let id): id.rawValue
        }
    }
}

public enum V2OperationScope: Equatable, Codable, Sendable {
    case account(UserID)
    case room(RoomID)
    /// Directed (owner, target); reversing it is a different actor and is rejected by identity validation.
    case userPair(UserID, UserID)
    case message(RoomID, MessageID)
    case device(UserID, DeviceID)
    public var storageKey: String {
        switch self {
        case .account(let id): "account/\(id.rawValue)"
        case .room(let id): "room/\(id.rawValue)"
        case .userPair(let a, let b): "pair/\(a.rawValue)/\(b.rawValue)"
        case .message(let room, let message): "message/\(room.rawValue)/\(message.rawValue)"
        case .device(let user, let device): "device/\(user.rawValue)/\(device.rawValue)"
        }
    }
}

public enum V2OperationIdentityError: Error, Equatable, Sendable { case invalidScope }

public struct V2OperationIdentity: Equatable, Codable, Sendable {
    public let accountID: UserID
    public let scope: V2OperationScope
    public let operation: V2OperationReference
    public var kind: V2OperationKind { operation.kind }
    public var storageKey: String { "\(accountID.rawValue)/\(scope.storageKey)/\(kind.rawValue)/\(operation.rawValue)" }
    public init(accountID: UserID, scope: V2OperationScope, operation: V2OperationReference) throws {
        let valid: Bool
        switch operation.kind {
        case .profileUpdate, .strangerMessagePreference, .userAddPreference, .readReceiptPreference, .liveActivityPreference, .groupRoom, .mediaUpload:
            if case .account(let user) = scope { valid = user == accountID } else { valid = false }
        case .relationship, .userBlock, .contactAlias, .directRoom:
            if case .userPair(let user, let target) = scope { valid = user == accountID && target != user } else { valid = false }
        case .withdrawMessage, .editMessage, .reaction, .messageFavorite, .pinnedMessage:
            if case .message = scope { valid = true } else { valid = false }
        case .forwardMessage:
            if case .account(let user) = scope { valid = user == accountID }
            else if case .room = scope { valid = true } else { valid = false }
        case .sendMessage, .readReceipt, .membership, .moderation, .memberMute, .moderatedMemberRemoval, .conversationPreference, .groupAnnouncement, .groupPermission, .groupRole, .groupNickname, .groupInvite, .groupJoinRequest, .groupJoinDecision, .groupAvatar:
            if case .room = scope { valid = true } else { valid = false }
        }
        guard valid else { throw V2OperationIdentityError.invalidScope }
        self.accountID = accountID; self.scope = scope; self.operation = operation
    }
    private enum CodingKeys: String, CodingKey { case accountID, scope, operation }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(accountID: values.decode(UserID.self, forKey: .accountID), scope: values.decode(V2OperationScope.self, forKey: .scope), operation: values.decode(V2OperationReference.self, forKey: .operation))
    }
}

/// Business certainty is independent of whether the scheduler may currently run it.
public enum V2OperationExecutionState: String, CaseIterable, Codable, Sendable {
    case prepared, submitting, processing, awaitingConfirmation
    case committed, rejected, conflicted, closed, cancelledLocally, expiredUnsubmitted
    public var isTerminal: Bool {
        switch self {
        case .committed, .rejected, .conflicted, .closed, .cancelledLocally, .expiredUnsubmitted: true
        default: false
        }
    }
}
public enum V2OperationSchedulingState: String, CaseIterable, Codable, Sendable {
    case ready, claimed, waitingForDependency, waitingForAuthentication, waitingForNetwork
    case backingOff, needsAttention, suspended, finished
}

public struct V2OperationRecoveryRequest: Equatable, Codable, Sendable {
    public enum Action: String, Codable, Sendable { case query, closeIfAbsent }
    public let identity: V2OperationIdentity
    public let fingerprint: V2OperationFingerprint
    public let action: Action
    public init(identity: V2OperationIdentity, fingerprint: V2OperationFingerprint, action: Action) {
        self.identity = identity; self.fingerprint = fingerprint; self.action = action
    }
}

/// Only an authoritative terminal receipt can prove closure or rejection.
/// Receipt is a typed domain payload, not automatic authority: adapters must validate
/// its identity, fingerprint, terminal outcome and revision against the request.
/// A transport error or an unresolved query cannot construct that evidence.
public enum V2OperationRecoveryResult<Receipt: Equatable & Codable & Sendable>: Equatable, Codable, Sendable {
    case committed(Receipt)
    case processing(Receipt, nextQueryAfterMilliseconds: UInt64)
    case rejected(Receipt)
    case conflicted(Receipt)
    case closed(Receipt)
    case unresolved
    case fingerprintConflict
}

/// Domain-authoritative result after the adapter has checked the receipt binding.
/// This is separate from recovery uncertainty and local execution/scheduling state.
public enum V2OperationOutcome<Receipt: Equatable & Codable & Sendable>: Equatable, Codable, Sendable {
    case committed(Receipt)
    case processing(Receipt, nextQueryAfterMilliseconds: UInt64)
    case rejected(Receipt)
    case conflicted(Receipt)
    case closed(Receipt)
}

extension V2OperationRecoveryResult {
    /// Neither absence nor an identity mismatch is authority to replace the operation.
    public var authoritativeOutcome: V2OperationOutcome<Receipt>? {
        switch self {
        case .committed(let receipt): .committed(receipt)
        case .processing(let receipt, let delay): .processing(receipt, nextQueryAfterMilliseconds: delay)
        case .rejected(let receipt): .rejected(receipt)
        case .conflicted(let receipt): .conflicted(receipt)
        case .closed(let receipt): .closed(receipt)
        case .unresolved, .fingerprintConflict: nil
        }
    }
}
