import Foundation

/// Moderation commands are intentionally distinct from ordinary withdrawal and
/// membership changes. Their operation ID and immutable audit metadata make a
/// lost gateway response safe to retry without quietly changing an action.
public enum V2ModerationAction: String, Codable, CaseIterable, Equatable, Sendable {
    case redactMessage
    case removeMember
    case muteMember
    case freezeRoom
    case unfreezeRoom
}

/// A non-free-form code gives the audit trail useful, privacy-safe context
/// without putting a report, message body, token, or display name in the room
/// event or operational telemetry.
public struct V2ModerationReasonCode: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 64,
              normalized.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { throw V2ModerationValidationError.invalidReasonCode }
        self.rawValue = normalized
    }
}

/// All action-dependent fields are made explicit so the durable idempotency
/// record can compare a retry exactly. `muteUntil` is exclusive and is never
/// allowed for an action that does not create a temporary mute state.
public struct V2ModerationCommand: Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: ModerationOperationID
    public let action: V2ModerationAction
    public let targetUserID: UserID?
    public let messageID: MessageID?
    public let muteUntil: Date?
    public let reasonCode: V2ModerationReasonCode

    public init(roomID: RoomID, actorUserID: UserID, operationID: ModerationOperationID, action: V2ModerationAction, targetUserID: UserID? = nil, messageID: MessageID? = nil, muteUntil: Date? = nil, reasonCode: V2ModerationReasonCode) throws {
        switch action {
        case .redactMessage:
            guard targetUserID == nil, messageID != nil, muteUntil == nil else { throw V2ModerationValidationError.invalidActionShape }
        case .removeMember:
            guard let targetUserID, targetUserID != actorUserID, messageID == nil, muteUntil == nil else { throw V2ModerationValidationError.invalidActionShape }
        case .muteMember:
            guard let targetUserID, targetUserID != actorUserID, messageID == nil, muteUntil != nil else { throw V2ModerationValidationError.invalidActionShape }
        case .freezeRoom, .unfreezeRoom:
            guard targetUserID == nil, messageID == nil, muteUntil == nil else { throw V2ModerationValidationError.invalidActionShape }
        }
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.action = action
        self.targetUserID = targetUserID
        self.messageID = messageID
        self.muteUntil = muteUntil
        self.reasonCode = reasonCode
    }
}

/// Current authenticated clients only represent room owner/admin authority.
/// The trusted safety service and human-reviewer paths remain separately
/// authenticated server-to-server/admin APIs and cannot be impersonated by a
/// gateway connection.
public enum V2ModerationAuthorization {
    public static func authorize(actorRole: V2RoomMembershipRole, configuredPermissions: Set<V2GroupPermission>? = nil, action: V2ModerationAction, now: Date, command: V2ModerationCommand) throws {
        // A member-authenticated gateway connection never represents the
        // separately authenticated safety-service authority. Freeze/unfreeze
        // therefore cannot accidentally be granted to an owner or admin by
        // reusing this policy boundary.
        guard action != .freezeRoom, action != .unfreezeRoom else {
            throw V2ModerationAuthorizationError.notAuthorized
        }
        let required: V2GroupPermission = switch action {
        case .redactMessage: .moderateMessages
        case .removeMember: .removeMembers
        case .muteMember: .muteMembers
        case .freezeRoom, .unfreezeRoom: preconditionFailure("trusted actions are rejected above")
        }
        guard V2GroupPermissionDefaults.allows(role: actorRole, permission: required, configured: configuredPermissions) else {
            throw V2ModerationAuthorizationError.notAuthorized
        }
        if action == .muteMember {
            guard let muteUntil = command.muteUntil, muteUntil > now else { throw V2ModerationValidationError.invalidMuteExpiry }
        }
    }
}

public enum V2ModerationValidationError: Error, Equatable, Sendable {
    case invalidReasonCode
    case invalidActionShape
    case invalidMuteExpiry
}

public enum V2ModerationAuthorizationError: Error, Equatable, Sendable {
    case notAuthorized
}
