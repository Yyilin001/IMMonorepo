/// 封闭的领域错误集合。基础设施故障或提交结果不明仍属运行时失败，
/// 绝不转成任意远程错误字符串。
public enum V2ActorMessagingErrorWire: Codable, Equatable, Sendable {
    case sendStore(V2ActorMessagingSendStoreErrorWire)
    case editStore(V2ActorMessagingEditStoreErrorWire)
    case withdrawalStore(V2ActorMessagingWithdrawalStoreErrorWire)
    case reactionStore(V2ActorMessagingReactionStoreErrorWire)
    case sendValidation(V2ActorMessagingSendValidationErrorWire)
    case editValidation(V2ActorMessagingEditValidationErrorWire)
    case reactionValidation(V2ActorMessagingReactionValidationErrorWire)
    case revision(V2ActorMessagingRevisionErrorWire)
    case content(V2ActorMessagingContentErrorWire)
    case mention(V2ActorMessagingMentionErrorWire)
    case media(V2ActorMessagingMediaErrorWire)
    case core(V2ActorMessagingCoreErrorWire)
    case mapping(V2ActorMessagingMappingErrorWire)
}

public enum V2ActorMessagingSendStoreErrorWire: String, Codable, CaseIterable, Sendable {
    case messageOperationClosed
    case roomNotFound
    case actorNotEligible
    case actorMuted
    case roomFrozen
    case capacityProfileMismatch
    case corruptPersistenceState
    case directMessageBlocked
    case strangerMessagePermissionDenied
    case strangerMessageLimitReached
    case replyTargetNotFound
}

public enum V2ActorMessagingEditStoreErrorWire: String, Codable, CaseIterable, Sendable {
    case roomNotFound
    case messageNotFound
    case actorNotAuthor
    case corruptPersistenceState
}

public enum V2ActorMessagingWithdrawalStoreErrorWire: String, Codable, CaseIterable, Sendable {
    case roomNotFound
    case messageNotFound
    case actorNotAuthor
    case corruptPersistenceState
}

public enum V2ActorMessagingReactionStoreErrorWire: String, Codable, CaseIterable, Sendable {
    case roomNotFound
    case messageNotFound
    case actorNotMember
    case messageWithdrawn
    case reactionLimitReached
    case corruptPersistenceState
}

public enum V2ActorMessagingSendValidationErrorWire: String, Codable, CaseIterable, Sendable {
    case invalidTextLength
}

public enum V2ActorMessagingEditValidationErrorWire: String, Codable, CaseIterable, Sendable {
    case invalidText
}

public enum V2ActorMessagingReactionValidationErrorWire: String, Codable, CaseIterable, Sendable {
    case invalidReaction
}

public enum V2ActorMessagingRevisionErrorWire: String, Codable, CaseIterable, Sendable {
    case outOfRange
}

public enum V2ActorMessagingContentErrorWire: String, Codable, CaseIterable, Sendable {
    case invalidEntity
}

public enum V2ActorMessagingMentionErrorWire: String, Codable, CaseIterable, Sendable {
    case invalidLimits
    case invalidTargetSet
    case notAuthorized
}

public enum V2ActorMessagingMediaErrorWire: String, Codable, CaseIterable, Sendable {
    case invalidLimits
    case invalidUploadIntent
    case invalidStateTransition
    case expired
    case invalidAttachmentSet
    case invalidDownloadTarget
    case invalidPresentation
}

public enum V2ActorMessagingCoreErrorWire: String, Codable, CaseIterable, Sendable {
    case invalidIdentifier
    case invalidNonNegativeValue
    case invalidPositiveValue
    case invalidGeneration
}

public enum V2ActorMessagingMappingErrorWire: String, Codable, CaseIterable, Sendable {
    case invalidSequence
    case invalidMembershipRevision
    case invalidMediaPresentationIdentity
    case invalidDate
    case noncanonicalReaction
    case invalidRetryDelay
}
