import Foundation
import IMV2ActorContracts
import IMV2Core

extension V2ActorMembershipChangeResultWire {
    public init(_ value: V2RoomMembershipChange) {
        self.init(roomID: value.roomID, targetUserID: value.targetUserID,
                  action: value.action, membershipRevision: value.membershipRevision,
                  roomSequence: value.roomSequence, eventID: value.eventID,
                  createdAt: value.createdAt)
    }
    public func domain() throws -> V2RoomMembershipChange {
        try v2ActorValidateDate(createdAt)
        return try .init(roomID: roomID, targetUserID: targetUserID, action: action,
                         membershipRevision: membershipRevision, roomSequence: roomSequence,
                         eventID: eventID, createdAt: createdAt)
    }
}

extension V2ActorMembershipOutcomeWire {
    public init(_ outcome: V2RoomMembershipChangeOutcome) {
        switch outcome {
        case .changed(let value): self = .changed(.init(value))
        case .idempotent(let value): self = .idempotent(.init(value))
        case .idempotencyConflict: self = .idempotencyConflict
        case .revisionConflict(let current): self = .revisionConflict(current: current)
        case .targetAlreadyMember: self = .targetAlreadyMember
        case .targetNotMember: self = .targetNotMember
        case .memberLimitReached: self = .memberLimitReached
        case .rateLimited(let seconds): self = .rateLimited(retryAfterSeconds: seconds)
        case .unavailable(let reason): self = .unavailable(.init(reason))
        }
    }
    public func domain() throws -> V2RoomMembershipChangeOutcome {
        switch self {
        case .changed(let value): return .changed(try value.domain())
        case .idempotent(let value): return .idempotent(try value.domain())
        case .idempotencyConflict: return .idempotencyConflict
        case .revisionConflict(let current):
            guard current <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
            return .revisionConflict(current: current)
        case .targetAlreadyMember: return .targetAlreadyMember
        case .targetNotMember: return .targetNotMember
        case .memberLimitReached: return .memberLimitReached
        case .rateLimited(let seconds):
            guard seconds >= 0 else { throw V2ActorAdministrationWireError.invalidRetryAfter }
            return .rateLimited(retryAfterSeconds: seconds)
        case .unavailable(let reason): return .unavailable(reason.toDomain())
        }
    }
}

extension V2ActorPinnedMessageResultWire {
    public init(_ value: V2PinnedMessage) {
        self.init(roomID: value.roomID, messageID: value.messageID,
                  isPinned: value.isPinned, roomSequence: value.roomSequence,
                  updatedAt: value.updatedAt)
    }
    public func domain() throws -> V2PinnedMessage {
        try v2ActorValidateDate(updatedAt)
        return try .init(roomID: roomID, messageID: messageID, isPinned: isPinned,
                         roomSequence: roomSequence, updatedAt: updatedAt)
    }
}

extension V2ActorGroupAnnouncementResultWire {
    public init(_ value: V2GroupAnnouncement) {
        self.init(roomID: value.roomID, body: value.body, revision: value.revision,
                  roomSequence: value.roomSequence, updatedAt: value.updatedAt)
    }
    public func domain() throws -> V2GroupAnnouncement {
        try v2ActorValidateDate(updatedAt)
        return try .init(roomID: roomID, body: body, revision: revision,
                         roomSequence: roomSequence, updatedAt: updatedAt)
    }
}

extension V2ActorRolePermissionsResultWire {
    public init(_ value: V2GroupRolePermissionsChange) {
        self.init(roomID: value.roomID, role: value.role,
                  permissions: v2ActorSortedPermissions(value.permissions),
                  revision: value.revision, roomSequence: value.roomSequence)
    }
    public func domain() throws -> V2GroupRolePermissionsChange {
        let set = Set(permissions)
        guard set.count == permissions.count, permissions.count <= V2GroupPermission.allCases.count else {
            throw V2ActorAdministrationWireError.invalidPermissionList
        }
        return try .init(roomID: roomID, role: role, permissions: set,
                         revision: revision, roomSequence: roomSequence)
    }
}

extension V2ActorMemberRoleResultWire {
    public init(_ value: V2GroupMemberRoleChange) {
        self.init(roomID: value.roomID, targetUserID: value.targetUserID, role: value.role,
                  membershipRevision: value.membershipRevision, roomSequence: value.roomSequence)
    }
    public func domain() throws -> V2GroupMemberRoleChange {
        try .init(roomID: roomID, targetUserID: targetUserID, role: role,
                  membershipRevision: membershipRevision, roomSequence: roomSequence)
    }
}

private func v2ActorCapabilityWire<Domain: Equatable & Sendable,
                                   Wire: Codable & Equatable & Sendable>(
    _ outcome: V2GroupCapabilitiesOutcome<Domain>,
    transform: (Domain) -> Wire
) -> V2ActorGroupCapabilityOutcomeWire<Wire> {
    switch outcome {
    case .applied(let value): .applied(transform(value))
    case .idempotent(let value): .idempotent(transform(value))
    case .idempotencyConflict: .idempotencyConflict
    case .alreadyInDesiredState: .alreadyInDesiredState
    case .revisionConflict: .revisionConflict
    case .rateLimited(let seconds): .rateLimited(retryAfterSeconds: seconds)
    case .unavailable(let reason): .unavailable(.init(reason))
    }
}

private func v2ActorCapabilityDomain<Wire: Codable & Equatable & Sendable,
                                     Domain: Equatable & Sendable>(
    _ outcome: V2ActorGroupCapabilityOutcomeWire<Wire>,
    transform: (Wire) throws -> Domain
) throws -> V2GroupCapabilitiesOutcome<Domain> {
    switch outcome {
    case .applied(let value): return .applied(try transform(value))
    case .idempotent(let value): return .idempotent(try transform(value))
    case .idempotencyConflict: return .idempotencyConflict
    case .alreadyInDesiredState: return .alreadyInDesiredState
    case .revisionConflict: return .revisionConflict
    case .rateLimited(let seconds):
        guard seconds >= 0 else { throw V2ActorAdministrationWireError.invalidRetryAfter }
        return .rateLimited(retryAfterSeconds: seconds)
    case .unavailable(let reason): return .unavailable(reason.toDomain())
    }
}

extension V2ActorGroupCapabilityOutcomeWire where Value == V2ActorPinnedMessageResultWire {
    public init(_ outcome: V2GroupCapabilitiesOutcome<V2PinnedMessage>) {
        self = v2ActorCapabilityWire(outcome, transform: V2ActorPinnedMessageResultWire.init)
    }
    public func domain() throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage> {
        try v2ActorCapabilityDomain(self) { try $0.domain() }
    }
}

extension V2ActorGroupCapabilityOutcomeWire where Value == V2GroupAvatarChange {
    public init(_ outcome: V2GroupCapabilitiesOutcome<V2GroupAvatarChange>) {
        self = v2ActorCapabilityWire(outcome, transform: { $0 })
    }
    public func domain() throws -> V2GroupCapabilitiesOutcome<V2GroupAvatarChange> {
        try v2ActorCapabilityDomain(self) { $0 }
    }
}

extension V2ActorGroupCapabilityOutcomeWire where Value == V2ActorGroupAnnouncementResultWire {
    public init(_ outcome: V2GroupCapabilitiesOutcome<V2GroupAnnouncement>) {
        self = v2ActorCapabilityWire(outcome, transform: V2ActorGroupAnnouncementResultWire.init)
    }
    public func domain() throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement> {
        try v2ActorCapabilityDomain(self) { try $0.domain() }
    }
}

extension V2ActorGroupCapabilityOutcomeWire where Value == V2ActorRolePermissionsResultWire {
    public init(_ outcome: V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange>) {
        self = v2ActorCapabilityWire(outcome, transform: V2ActorRolePermissionsResultWire.init)
    }
    public func domain() throws -> V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange> {
        try v2ActorCapabilityDomain(self) { try $0.domain() }
    }
}

extension V2ActorGroupCapabilityOutcomeWire where Value == V2ActorMemberRoleResultWire {
    public init(_ outcome: V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange>) {
        self = v2ActorCapabilityWire(outcome, transform: V2ActorMemberRoleResultWire.init)
    }
    public func domain() throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange> {
        try v2ActorCapabilityDomain(self) { try $0.domain() }
    }
}

extension V2ActorModerationResultWire {
    public init(_ value: V2ModerationResult) {
        self.init(roomID: value.roomID, operationID: value.operationID, action: value.action,
                  targetUserID: value.targetUserID, messageID: value.messageID,
                  messageRevision: value.messageRevision, membershipRevision: value.membershipRevision,
                  muteUntil: value.muteUntil, roomSequence: value.roomSequence,
                  eventID: value.eventID, createdAt: value.createdAt)
    }
    public func domain() throws -> V2ModerationResult {
        try v2ActorValidateDate(createdAt)
        if let muteUntil { try v2ActorValidateDate(muteUntil) }
        return try .init(roomID: roomID, operationID: operationID, action: action,
                         targetUserID: targetUserID, messageID: messageID,
                         messageRevision: messageRevision, membershipRevision: membershipRevision,
                         muteUntil: muteUntil, roomSequence: roomSequence,
                         eventID: eventID, createdAt: createdAt)
    }
}

extension V2ActorModerationOutcomeWire {
    public init(_ outcome: V2ModerationOutcome) {
        switch outcome {
        case .applied(let value): self = .applied(.init(value))
        case .idempotent(let value): self = .idempotent(.init(value))
        case .idempotencyConflict: self = .idempotencyConflict
        case .targetNotMember: self = .targetNotMember
        case .messageAlreadyRedacted: self = .messageAlreadyRedacted
        case .actionAlreadyInDesiredState: self = .actionAlreadyInDesiredState
        case .rateLimited(let seconds): self = .rateLimited(retryAfterSeconds: seconds)
        case .unavailable(let reason): self = .unavailable(.init(reason))
        }
    }
    public func domain() throws -> V2ModerationOutcome {
        switch self {
        case .applied(let value): return .applied(try value.domain())
        case .idempotent(let value): return .idempotent(try value.domain())
        case .idempotencyConflict: return .idempotencyConflict
        case .targetNotMember: return .targetNotMember
        case .messageAlreadyRedacted: return .messageAlreadyRedacted
        case .actionAlreadyInDesiredState: return .actionAlreadyInDesiredState
        case .rateLimited(let seconds):
            guard seconds >= 0 else { throw V2ActorAdministrationWireError.invalidRetryAfter }
            return .rateLimited(retryAfterSeconds: seconds)
        case .unavailable(let reason): return .unavailable(reason.toDomain())
        }
    }
}

extension V2ActorGroupMemberPresentationWire {
    public init(_ value: V2GroupMemberPresentation) {
        self.init(roomID: value.roomID, userID: value.userID,
                  groupNickname: value.groupNickname, revision: value.revision)
    }
    public func domain() throws -> V2GroupMemberPresentation {
        let value = try V2GroupMemberPresentation(roomID: roomID, userID: userID,
                                                   groupNickname: groupNickname, revision: revision)
        guard value.groupNickname == groupNickname else {
            throw V2ProfilePresentationValidationError.invalidDisplayName
        }
        return value
    }
}

extension V2ActorGroupNicknamePageWire {
    public init(_ value: V2GroupNicknamePage) {
        self.init(values: value.values.map(V2ActorGroupMemberPresentationWire.init),
                  nextCursor: value.nextCursor)
    }
    public func domain() throws -> V2GroupNicknamePage {
        guard values.count <= 500 else { throw V2ActorAdministrationWireError.invalidPageLimit }
        return .init(values: try values.map { try $0.domain() }, nextCursor: nextCursor)
    }
}
