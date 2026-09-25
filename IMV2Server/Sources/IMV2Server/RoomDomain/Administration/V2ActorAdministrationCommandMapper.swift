import Foundation
import IMV2ActorContracts
import IMV2Core

public enum V2ActorAdministrationWireError: Error, Equatable, Sendable {
    case invalidPermissionList
    case invalidDate
    case invalidPageLimit
    case invalidRetryAfter
    case trustedActionOnUserLane
    case unsupportedAuthenticatedRevision
}

private func v2ActorPermissions(_ values: [V2GroupPermission]) throws -> Set<V2GroupPermission> {
    let set = Set(values)
    guard set.count == values.count, values.count <= V2GroupPermission.allCases.count else {
        throw V2ActorAdministrationWireError.invalidPermissionList
    }
    return set
}

func v2ActorSortedPermissions(_ values: Set<V2GroupPermission>) -> [V2GroupPermission] {
    values.sorted { $0.rawValue < $1.rawValue }
}

func v2ActorValidateDate(_ value: Date) throws {
    guard value.timeIntervalSince1970.isFinite else {
        throw V2ActorAdministrationWireError.invalidDate
    }
}

extension V2ActorMembershipChangeWire {
    public init(_ request: V2AuthenticatedMembershipChange) {
        self.init(roomID: request.roomID, actorUserID: request.actorUserID,
                  operationID: request.operationID, targetUserID: request.targetUserID,
                  action: request.action, expectedMembershipRevision: request.expectedMembershipRevision)
    }

    public func domainCommand() throws -> V2ChangeRoomMembershipCommand {
        try .init(roomID: roomID, actorUserID: actorUserID, operationID: operationID,
                  targetUserID: targetUserID, action: action,
                  expectedMembershipRevision: expectedMembershipRevision)
    }

    public func authenticatedRequest() throws -> V2AuthenticatedMembershipChange {
        _ = try domainCommand()
        return .init(roomID: roomID, actorUserID: actorUserID, operationID: operationID,
                     targetUserID: targetUserID, action: action,
                     expectedMembershipRevision: expectedMembershipRevision)
    }
}

extension V2ActorPinnedMessageWire {
    public init(actorUserID: UserID, command: V2PinnedMessageCommand) {
        self.init(roomID: command.roomID, actorUserID: actorUserID,
                  operationID: command.operationID, messageID: command.messageID,
                  isPinned: command.isPinned)
    }
    public func domainCommand() -> V2PinnedMessageCommand {
        .init(operationID: operationID, roomID: roomID, messageID: messageID, isPinned: isPinned)
    }
}

extension V2ActorGroupAnnouncementWire {
    public init(actorUserID: UserID, command: V2GroupAnnouncementCommand) {
        self.init(roomID: command.roomID, actorUserID: actorUserID,
                  operationID: command.operationID, body: command.body,
                  expectedRevision: command.expectedRevision)
    }
    public func domainCommand() throws -> V2GroupAnnouncementCommand {
        try .init(operationID: operationID, roomID: roomID, body: body,
                  expectedRevision: expectedRevision)
    }
}

extension V2ActorRolePermissionsWire {
    public init(actorUserID: UserID, command: V2GroupRolePermissionsCommand) {
        self.init(roomID: command.roomID, actorUserID: actorUserID,
                  operationID: command.operationID, role: command.role,
                  permissions: v2ActorSortedPermissions(command.permissions),
                  expectedRevision: command.expectedRevision)
    }
    public func domainCommand() throws -> V2GroupRolePermissionsCommand {
        try .init(operationID: operationID, roomID: roomID, role: role,
                  permissions: v2ActorPermissions(permissions), expectedRevision: expectedRevision)
    }
}

extension V2ActorMemberRoleWire {
    public init(actorUserID: UserID, command: V2GroupMemberRoleCommand) {
        self.init(roomID: command.roomID, actorUserID: actorUserID,
                  operationID: command.operationID, targetUserID: command.targetUserID,
                  role: command.role, expectedMembershipRevision: command.expectedMembershipRevision)
    }
    public func domainCommand() throws -> V2GroupMemberRoleCommand {
        try .init(operationID: operationID, roomID: roomID, targetUserID: targetUserID,
                  role: role, expectedMembershipRevision: expectedMembershipRevision)
    }
}

extension V2ActorModerationWire {
    public init(_ request: V2AuthenticatedModeration) {
        self.init(roomID: request.roomID, actorUserID: request.actorUserID,
                  operationID: request.operationID, action: request.action,
                  targetUserID: request.targetUserID, messageID: request.messageID,
                  expectedMessageRevision: nil, muteUntil: request.muteUntil,
                  reasonCode: request.reasonCode.rawValue)
    }

    public init(_ command: V2ModerationCommand) {
        self.init(roomID: command.roomID, actorUserID: command.actorUserID,
                  operationID: command.operationID, action: command.action,
                  targetUserID: command.targetUserID, messageID: command.messageID,
                  expectedMessageRevision: command.expectedMessageRevision,
                  muteUntil: command.muteUntil, reasonCode: command.reasonCode.rawValue)
    }

    public func domainCommand() throws -> V2ModerationCommand {
        guard action != .freezeRoom, action != .unfreezeRoom else {
            throw V2ActorAdministrationWireError.trustedActionOnUserLane
        }
        if let muteUntil { try v2ActorValidateDate(muteUntil) }
        return try .init(roomID: roomID, actorUserID: actorUserID, operationID: operationID,
                         action: action, targetUserID: targetUserID, messageID: messageID,
                         expectedMessageRevision: expectedMessageRevision, muteUntil: muteUntil,
                         reasonCode: V2ModerationReasonCode(reasonCode))
    }

    public func authenticatedRequest() throws -> V2AuthenticatedModeration {
        guard expectedMessageRevision == nil else {
            throw V2ActorAdministrationWireError.unsupportedAuthenticatedRevision
        }
        _ = try domainCommand()
        return .init(roomID: roomID, actorUserID: actorUserID, operationID: operationID,
                     action: action, targetUserID: targetUserID, messageID: messageID,
                     muteUntil: muteUntil, reasonCode: try V2ModerationReasonCode(reasonCode))
    }
}

extension V2ActorTrustedSafetyWire {
    public init(_ request: V2TrustedSafetyRoomControl) {
        self.init(roomID: request.roomID, operationID: request.operationID,
                  action: request.action, messageID: nil, expectedMessageRevision: nil,
                  reasonCode: request.reasonCode.rawValue)
    }

    public init(_ request: V2TrustedSafetyModeration) {
        self.init(roomID: request.roomID, operationID: request.operationID,
                  action: request.action, messageID: request.messageID,
                  expectedMessageRevision: request.expectedMessageRevision,
                  reasonCode: request.reasonCode.rawValue)
    }

    public func trustedModeration() throws -> V2TrustedSafetyModeration {
        if let revision = expectedMessageRevision {
            guard revision > 0, revision <= UInt64(Int64.max) else {
                throw V2RevisionValidationError.outOfRange
            }
        }
        return try .init(roomID: roomID, operationID: operationID, action: action,
                         messageID: messageID, expectedMessageRevision: expectedMessageRevision,
                         reasonCode: V2ModerationReasonCode(reasonCode))
    }

    public func trustedRoomControl() throws -> V2TrustedSafetyRoomControl {
        guard messageID == nil, expectedMessageRevision == nil else {
            throw V2ModerationValidationError.invalidActionShape
        }
        return try .init(roomID: roomID, operationID: operationID, action: action,
                         reasonCode: V2ModerationReasonCode(reasonCode))
    }
}

extension V2ActorGroupNicknameUpdateWire {
    /// 在把既有的参数式 API 调用传给远程执行器前，先校验输入。
    public func validateForDomain() throws {
        guard let initialRevision = V2ProfileRevision(rawValue: 1) else {
            throw V2RevisionValidationError.outOfRange
        }
        _ = try V2GroupMemberPresentation(roomID: roomID, userID: actorUserID,
                                           groupNickname: nickname, revision: initialRevision)
    }
}

extension V2ActorGroupNicknamesQueryWire {
    public func validateForDomain() throws {
        guard (1...500).contains(limit) else { throw V2ActorAdministrationWireError.invalidPageLimit }
    }
}
