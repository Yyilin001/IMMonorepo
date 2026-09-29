import IMV2ServerContracts
import IMV2ActorContracts
import IMV2Core

public extension V2ActorMessagingErrorWire {
    init?(domainError: any Error) {
        switch domainError {
        case let value as V2RoomWriteStoreError: self = .sendStore(.init(value))
        case let value as V2MessageEditStoreError: self = .editStore(.init(value))
        case let value as V2MessageWithdrawalStoreError: self = .withdrawalStore(.init(value))
        case let value as V2MessageReactionStoreError: self = .reactionStore(.init(value))
        case let value as V2SendMessageValidationError: self = .sendValidation(.init(value))
        case let value as V2MessageEditValidationError: self = .editValidation(.init(value))
        case let value as V2MessageReactionValidationError: self = .reactionValidation(.init(value))
        case let value as V2RevisionValidationError: self = .revision(.init(value))
        case let value as V2RichMessageContentError: self = .content(.init(value))
        case let value as V2MentionValidationError: self = .mention(.init(value))
        case let value as V2MediaValidationError: self = .media(.init(value))
        case let value as V2CoreError: self = .core(.init(value))
        case let value as V2ActorMessagingMappingError: self = .mapping(.init(value))
        default: return nil
        }
    }

    func domainError() -> any Error {
        switch self {
        case .sendStore(let value): value.domainValue()
        case .editStore(let value): value.domainValue()
        case .withdrawalStore(let value): value.domainValue()
        case .reactionStore(let value): value.domainValue()
        case .sendValidation(let value): value.domainValue()
        case .editValidation(let value): value.domainValue()
        case .reactionValidation(let value): value.domainValue()
        case .revision(let value): value.domainValue()
        case .content(let value): value.domainValue()
        case .mention(let value): value.domainValue()
        case .media(let value): value.domainValue()
        case .core(let value): value.domainValue()
        case .mapping(let value): value.domainValue()
        }
    }
}

public extension V2ActorMessagingSendStoreErrorWire {
    init(_ value: V2RoomWriteStoreError) {
        switch value {
        case .messageOperationClosed: self = .messageOperationClosed
        case .roomNotFound: self = .roomNotFound
        case .actorNotEligible: self = .actorNotEligible
        case .actorMuted: self = .actorMuted
        case .roomFrozen: self = .roomFrozen
        case .capacityProfileMismatch: self = .capacityProfileMismatch
        case .corruptPersistenceState: self = .corruptPersistenceState
        case .directMessageBlocked: self = .directMessageBlocked
        case .strangerMessagePermissionDenied: self = .strangerMessagePermissionDenied
        case .strangerMessageLimitReached: self = .strangerMessageLimitReached
        case .replyTargetNotFound: self = .replyTargetNotFound
        }
    }

    func domainValue() -> V2RoomWriteStoreError {
        switch self {
        case .messageOperationClosed: .messageOperationClosed
        case .roomNotFound: .roomNotFound
        case .actorNotEligible: .actorNotEligible
        case .actorMuted: .actorMuted
        case .roomFrozen: .roomFrozen
        case .capacityProfileMismatch: .capacityProfileMismatch
        case .corruptPersistenceState: .corruptPersistenceState
        case .directMessageBlocked: .directMessageBlocked
        case .strangerMessagePermissionDenied: .strangerMessagePermissionDenied
        case .strangerMessageLimitReached: .strangerMessageLimitReached
        case .replyTargetNotFound: .replyTargetNotFound
        }
    }
}

public extension V2ActorMessagingEditStoreErrorWire {
    init(_ value: V2MessageEditStoreError) {
        switch value {
        case .roomNotFound: self = .roomNotFound
        case .messageNotFound: self = .messageNotFound
        case .actorNotAuthor: self = .actorNotAuthor
        case .corruptPersistenceState: self = .corruptPersistenceState
        }
    }

    func domainValue() -> V2MessageEditStoreError {
        switch self {
        case .roomNotFound: .roomNotFound
        case .messageNotFound: .messageNotFound
        case .actorNotAuthor: .actorNotAuthor
        case .corruptPersistenceState: .corruptPersistenceState
        }
    }
}

public extension V2ActorMessagingWithdrawalStoreErrorWire {
    init(_ value: V2MessageWithdrawalStoreError) {
        switch value {
        case .roomNotFound: self = .roomNotFound
        case .messageNotFound: self = .messageNotFound
        case .actorNotAuthor: self = .actorNotAuthor
        case .corruptPersistenceState: self = .corruptPersistenceState
        }
    }

    func domainValue() -> V2MessageWithdrawalStoreError {
        switch self {
        case .roomNotFound: .roomNotFound
        case .messageNotFound: .messageNotFound
        case .actorNotAuthor: .actorNotAuthor
        case .corruptPersistenceState: .corruptPersistenceState
        }
    }
}

public extension V2ActorMessagingReactionStoreErrorWire {
    init(_ value: V2MessageReactionStoreError) {
        switch value {
        case .roomNotFound: self = .roomNotFound
        case .messageNotFound: self = .messageNotFound
        case .actorNotMember: self = .actorNotMember
        case .messageWithdrawn: self = .messageWithdrawn
        case .reactionLimitReached: self = .reactionLimitReached
        case .corruptPersistenceState: self = .corruptPersistenceState
        }
    }

    func domainValue() -> V2MessageReactionStoreError {
        switch self {
        case .roomNotFound: .roomNotFound
        case .messageNotFound: .messageNotFound
        case .actorNotMember: .actorNotMember
        case .messageWithdrawn: .messageWithdrawn
        case .reactionLimitReached: .reactionLimitReached
        case .corruptPersistenceState: .corruptPersistenceState
        }
    }
}

public extension V2ActorMessagingSendValidationErrorWire {
    init(_ value: V2SendMessageValidationError) {
        switch value {
        case .invalidTextLength: self = .invalidTextLength
        }
    }

    func domainValue() -> V2SendMessageValidationError {
        switch self {
        case .invalidTextLength: .invalidTextLength
        }
    }
}

public extension V2ActorMessagingEditValidationErrorWire {
    init(_ value: V2MessageEditValidationError) {
        switch value {
        case .invalidText: self = .invalidText
        }
    }

    func domainValue() -> V2MessageEditValidationError {
        switch self {
        case .invalidText: .invalidText
        }
    }
}

public extension V2ActorMessagingReactionValidationErrorWire {
    init(_ value: V2MessageReactionValidationError) {
        switch value {
        case .invalidReaction: self = .invalidReaction
        }
    }

    func domainValue() -> V2MessageReactionValidationError {
        switch self {
        case .invalidReaction: .invalidReaction
        }
    }
}

public extension V2ActorMessagingRevisionErrorWire {
    init(_ value: V2RevisionValidationError) {
        switch value {
        case .outOfRange: self = .outOfRange
        }
    }

    func domainValue() -> V2RevisionValidationError {
        switch self {
        case .outOfRange: .outOfRange
        }
    }
}

public extension V2ActorMessagingContentErrorWire {
    init(_ value: V2RichMessageContentError) {
        switch value {
        case .invalidEntity: self = .invalidEntity
        }
    }

    func domainValue() -> V2RichMessageContentError {
        switch self {
        case .invalidEntity: .invalidEntity
        }
    }
}

public extension V2ActorMessagingMentionErrorWire {
    init(_ value: V2MentionValidationError) {
        switch value {
        case .invalidLimits: self = .invalidLimits
        case .invalidTargetSet: self = .invalidTargetSet
        case .notAuthorized: self = .notAuthorized
        }
    }

    func domainValue() -> V2MentionValidationError {
        switch self {
        case .invalidLimits: .invalidLimits
        case .invalidTargetSet: .invalidTargetSet
        case .notAuthorized: .notAuthorized
        }
    }
}

public extension V2ActorMessagingMediaErrorWire {
    init(_ value: V2MediaValidationError) {
        switch value {
        case .invalidLimits: self = .invalidLimits
        case .invalidUploadIntent: self = .invalidUploadIntent
        case .invalidStateTransition: self = .invalidStateTransition
        case .expired: self = .expired
        case .invalidAttachmentSet: self = .invalidAttachmentSet
        case .invalidDownloadTarget: self = .invalidDownloadTarget
        case .invalidPresentation: self = .invalidPresentation
        }
    }

    func domainValue() -> V2MediaValidationError {
        switch self {
        case .invalidLimits: .invalidLimits
        case .invalidUploadIntent: .invalidUploadIntent
        case .invalidStateTransition: .invalidStateTransition
        case .expired: .expired
        case .invalidAttachmentSet: .invalidAttachmentSet
        case .invalidDownloadTarget: .invalidDownloadTarget
        case .invalidPresentation: .invalidPresentation
        }
    }
}

public extension V2ActorMessagingCoreErrorWire {
    init(_ value: V2CoreError) {
        switch value {
        case .invalidIdentifier: self = .invalidIdentifier
        case .invalidNonNegativeValue: self = .invalidNonNegativeValue
        case .invalidPositiveValue: self = .invalidPositiveValue
        case .invalidGeneration: self = .invalidGeneration
        }
    }

    func domainValue() -> V2CoreError {
        switch self {
        case .invalidIdentifier: .invalidIdentifier
        case .invalidNonNegativeValue: .invalidNonNegativeValue
        case .invalidPositiveValue: .invalidPositiveValue
        case .invalidGeneration: .invalidGeneration
        }
    }
}

public extension V2ActorMessagingMappingErrorWire {
    init(_ value: V2ActorMessagingMappingError) {
        switch value {
        case .invalidSequence: self = .invalidSequence
        case .invalidMembershipRevision: self = .invalidMembershipRevision
        case .invalidMediaPresentationIdentity: self = .invalidMediaPresentationIdentity
        case .invalidDate: self = .invalidDate
        case .noncanonicalReaction: self = .noncanonicalReaction
        case .invalidRetryDelay: self = .invalidRetryDelay
        }
    }

    func domainValue() -> V2ActorMessagingMappingError {
        switch self {
        case .invalidSequence: .invalidSequence
        case .invalidMembershipRevision: .invalidMembershipRevision
        case .invalidMediaPresentationIdentity: .invalidMediaPresentationIdentity
        case .invalidDate: .invalidDate
        case .noncanonicalReaction: .noncanonicalReaction
        case .invalidRetryDelay: .invalidRetryDelay
        }
    }
}
