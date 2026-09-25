import Foundation

/// 有限的 D2 领域错误。传输与基础设施错误仍由房间调用信封承载。
public enum V2ActorMembershipFailureWire: String, Codable, Equatable, Sendable {
    case ownerChanged, roomNotFound, actorNotOwner, targetUnavailable, corruptPersistenceState
}
public enum V2ActorGroupCapabilityFailureWire: String, Codable, Equatable, Sendable {
    case roomNotFound, messageNotFound, actorNotMember, actorNotAuthorized
    case targetNotMember, notGroupRoom, messageWithdrawn, corruptPersistenceState
}
public enum V2ActorModerationFailureWire: String, Codable, Equatable, Sendable {
    case roomNotFound, messageNotFound, actorNotAuthorized, unsupportedAction, corruptPersistenceState
}
public enum V2ActorProfileFailureWire: Codable, Equatable, Sendable {
    case unavailable, forbidden
    case revisionConflict(current: UInt64?)
    case operationPayloadMismatch, invalidPresentation, corruptPersistenceState
}
public enum V2ActorAdministrationInputFailureWire: String, Codable, Equatable, Sendable {
    case invalidIdentifier, invalidNonNegativeValue, invalidPositiveValue, invalidGeneration
    case revisionOutOfRange, selfTargetingNotAllowed
    case ownerPolicyIsImmutable, memberRoleCannotBeOwner, emptyAnnouncement, announcementTooLarge
    case invalidReasonCode, invalidActionShape, invalidMuteExpiry, moderationNotAuthorized
    case invalidProfileView, invalidDisplayName
    case invalidPermissionList, invalidDate, invalidPageLimit, invalidRetryAfter
    case trustedActionOnUserLane, unsupportedAuthenticatedRevision
}
public enum V2ActorAdministrationFailureWire: Codable, Equatable, Sendable, Error {
    case membership(V2ActorMembershipFailureWire)
    case groupCapability(V2ActorGroupCapabilityFailureWire)
    case moderation(V2ActorModerationFailureWire)
    case profile(V2ActorProfileFailureWire)
    case input(V2ActorAdministrationInputFailureWire)
}
