import IMV2ActorContracts
import IMV2Core

extension V2ActorAdministrationFailureWire {
/// 返回 nil 表示这不是 D2 业务或领域错误，应交由外层房间运行时分类。
    public init?(domainError error: any Error) {
        if let value = error as? V2RoomMembershipStoreError {
            switch value {
            case .ownerChanged: self = .membership(.ownerChanged)
            case .roomNotFound: self = .membership(.roomNotFound)
            case .actorNotOwner: self = .membership(.actorNotOwner)
            case .targetUnavailable: self = .membership(.targetUnavailable)
            case .corruptPersistenceState: self = .membership(.corruptPersistenceState)
            }
        } else if let value = error as? V2GroupCapabilitiesStoreError {
            switch value {
            case .resourceUnavailable: self = .groupCapability(.resourceUnavailable)
            case .operationClosed: self = .groupCapability(.operationClosed)
            case .roomNotFound: self = .groupCapability(.roomNotFound)
            case .messageNotFound: self = .groupCapability(.messageNotFound)
            case .actorNotMember: self = .groupCapability(.actorNotMember)
            case .actorNotAuthorized: self = .groupCapability(.actorNotAuthorized)
            case .targetNotMember: self = .groupCapability(.targetNotMember)
            case .notGroupRoom: self = .groupCapability(.notGroupRoom)
            case .messageWithdrawn: self = .groupCapability(.messageWithdrawn)
            case .corruptPersistenceState: self = .groupCapability(.corruptPersistenceState)
            }
        } else if let value = error as? V2ModerationStoreError {
            switch value {
            case .roomNotFound: self = .moderation(.roomNotFound)
            case .messageNotFound: self = .moderation(.messageNotFound)
            case .actorNotAuthorized: self = .moderation(.actorNotAuthorized)
            case .unsupportedAction: self = .moderation(.unsupportedAction)
            case .corruptPersistenceState: self = .moderation(.corruptPersistenceState)
            }
        } else if let value = error as? V2ProfilePresentationError {
            switch value {
            case .unavailable: self = .profile(.unavailable)
            case .forbidden: self = .profile(.forbidden)
            case .revisionConflict(let revision): self = .profile(.revisionConflict(current: revision?.rawValue))
            case .operationPayloadMismatch: self = .profile(.operationPayloadMismatch)
            case .invalidPresentation: self = .profile(.invalidPresentation)
            case .corruptPersistenceState: self = .profile(.corruptPersistenceState)
            }
        } else if let value = error as? V2ActorAdministrationWireError {
            switch value {
            case .invalidPermissionList: self = .input(.invalidPermissionList)
            case .invalidDate: self = .input(.invalidDate)
            case .invalidPageLimit: self = .input(.invalidPageLimit)
            case .invalidRetryAfter: self = .input(.invalidRetryAfter)
            case .trustedActionOnUserLane: self = .input(.trustedActionOnUserLane)
            case .unsupportedAuthenticatedRevision: self = .input(.unsupportedAuthenticatedRevision)
            }
        } else if let value = error as? V2CoreError {
            switch value {
            case .invalidIdentifier: self = .input(.invalidIdentifier)
            case .invalidNonNegativeValue: self = .input(.invalidNonNegativeValue)
            case .invalidPositiveValue: self = .input(.invalidPositiveValue)
            case .invalidGeneration: self = .input(.invalidGeneration)
            }
        } else if error is V2RevisionValidationError {
            self = .input(.revisionOutOfRange)
        } else if error is V2RoomMembershipValidationError {
            self = .input(.selfTargetingNotAllowed)
        } else if let value = error as? V2GroupPermissionValidationError {
            switch value {
            case .ownerPolicyIsImmutable: self = .input(.ownerPolicyIsImmutable)
            case .memberRoleCannotBeOwner: self = .input(.memberRoleCannotBeOwner)
            case .emptyAnnouncement: self = .input(.emptyAnnouncement)
            case .announcementTooLarge: self = .input(.announcementTooLarge)
            }
        } else if let value = error as? V2ModerationValidationError {
            switch value {
            case .invalidReasonCode: self = .input(.invalidReasonCode)
            case .invalidActionShape: self = .input(.invalidActionShape)
            case .invalidMuteExpiry: self = .input(.invalidMuteExpiry)
            }
        } else if error is V2ModerationAuthorizationError {
            self = .input(.moderationNotAuthorized)
        } else if let value = error as? V2ProfilePresentationValidationError {
            switch value {
            case .invalidProfileView: self = .input(.invalidProfileView)
            case .invalidDisplayName: self = .input(.invalidDisplayName)
            }
        } else {
            return nil
        }
    }

    public func domainError() throws -> any Error {
        switch self {
        case .membership(let value):
            switch value {
            case .ownerChanged: return V2RoomMembershipStoreError.ownerChanged
            case .roomNotFound: return V2RoomMembershipStoreError.roomNotFound
            case .actorNotOwner: return V2RoomMembershipStoreError.actorNotOwner
            case .targetUnavailable: return V2RoomMembershipStoreError.targetUnavailable
            case .corruptPersistenceState: return V2RoomMembershipStoreError.corruptPersistenceState
            }
        case .groupCapability(let value):
            switch value {
            case .resourceUnavailable: return V2GroupCapabilitiesStoreError.resourceUnavailable
            case .operationClosed: return V2GroupCapabilitiesStoreError.operationClosed
            case .roomNotFound: return V2GroupCapabilitiesStoreError.roomNotFound
            case .messageNotFound: return V2GroupCapabilitiesStoreError.messageNotFound
            case .actorNotMember: return V2GroupCapabilitiesStoreError.actorNotMember
            case .actorNotAuthorized: return V2GroupCapabilitiesStoreError.actorNotAuthorized
            case .targetNotMember: return V2GroupCapabilitiesStoreError.targetNotMember
            case .notGroupRoom: return V2GroupCapabilitiesStoreError.notGroupRoom
            case .messageWithdrawn: return V2GroupCapabilitiesStoreError.messageWithdrawn
            case .corruptPersistenceState: return V2GroupCapabilitiesStoreError.corruptPersistenceState
            }
        case .moderation(let value):
            switch value {
            case .roomNotFound: return V2ModerationStoreError.roomNotFound
            case .messageNotFound: return V2ModerationStoreError.messageNotFound
            case .actorNotAuthorized: return V2ModerationStoreError.actorNotAuthorized
            case .unsupportedAction: return V2ModerationStoreError.unsupportedAction
            case .corruptPersistenceState: return V2ModerationStoreError.corruptPersistenceState
            }
        case .profile(let value):
            switch value {
            case .unavailable: return V2ProfilePresentationError.unavailable
            case .forbidden: return V2ProfilePresentationError.forbidden
            case .revisionConflict(let current):
                if let current {
                    guard let revision = V2ProfileRevision(rawValue: current) else {
                        throw V2RevisionValidationError.outOfRange
                    }
                    return V2ProfilePresentationError.revisionConflict(revision)
                }
                return V2ProfilePresentationError.revisionConflict(nil)
            case .operationPayloadMismatch: return V2ProfilePresentationError.operationPayloadMismatch
            case .invalidPresentation: return V2ProfilePresentationError.invalidPresentation
            case .corruptPersistenceState: return V2ProfilePresentationError.corruptPersistenceState
            }
        case .input(let value):
            switch value {
            case .invalidIdentifier: return V2CoreError.invalidIdentifier
            case .invalidNonNegativeValue: return V2CoreError.invalidNonNegativeValue
            case .invalidPositiveValue: return V2CoreError.invalidPositiveValue
            case .invalidGeneration: return V2CoreError.invalidGeneration
            case .revisionOutOfRange: return V2RevisionValidationError.outOfRange
            case .selfTargetingNotAllowed: return V2RoomMembershipValidationError.selfTargetingNotAllowed
            case .ownerPolicyIsImmutable: return V2GroupPermissionValidationError.ownerPolicyIsImmutable
            case .memberRoleCannotBeOwner: return V2GroupPermissionValidationError.memberRoleCannotBeOwner
            case .emptyAnnouncement: return V2GroupPermissionValidationError.emptyAnnouncement
            case .announcementTooLarge: return V2GroupPermissionValidationError.announcementTooLarge
            case .invalidReasonCode: return V2ModerationValidationError.invalidReasonCode
            case .invalidActionShape: return V2ModerationValidationError.invalidActionShape
            case .invalidMuteExpiry: return V2ModerationValidationError.invalidMuteExpiry
            case .moderationNotAuthorized: return V2ModerationAuthorizationError.notAuthorized
            case .invalidProfileView: return V2ProfilePresentationValidationError.invalidProfileView
            case .invalidDisplayName: return V2ProfilePresentationValidationError.invalidDisplayName
            case .invalidPermissionList: return V2ActorAdministrationWireError.invalidPermissionList
            case .invalidDate: return V2ActorAdministrationWireError.invalidDate
            case .invalidPageLimit: return V2ActorAdministrationWireError.invalidPageLimit
            case .invalidRetryAfter: return V2ActorAdministrationWireError.invalidRetryAfter
            case .trustedActionOnUserLane: return V2ActorAdministrationWireError.trustedActionOnUserLane
            case .unsupportedAuthenticatedRevision: return V2ActorAdministrationWireError.unsupportedAuthenticatedRevision
            }
        }
    }
}
