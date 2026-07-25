import Foundation

/// The visible state of a bilateral relationship. `none` deliberately means
/// no active relation; it does not reveal whether another user has blocked us.
public enum V2RelationshipState: String, Codable, Equatable, Sendable {
    case none
    case pending
    case accepted
}

/// A relationship request is directional while pending. Accept/reject are
/// valid only for the requested user; either participant may remove an active
/// relation. Each command has its own durable operation identity.
public enum V2RelationshipAction: String, Codable, Equatable, Sendable {
    case request
    case accept
    case reject
    case remove
}

public struct V2ChangeRelationshipCommand: Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: RelationshipOperationID
    public let targetUserID: UserID
    public let action: V2RelationshipAction

    public init(actorUserID: UserID, operationID: RelationshipOperationID, targetUserID: UserID, action: V2RelationshipAction) throws {
        guard actorUserID != targetUserID else { throw V2SocialRelationshipValidationError.selfTargetingNotAllowed }
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.targetUserID = targetUserID
        self.action = action
    }
}

public enum V2UserBlockAction: String, Codable, Equatable, Sendable {
    case block
    case unblock
}

public struct V2ChangeUserBlockCommand: Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: UserBlockOperationID
    public let targetUserID: UserID
    public let action: V2UserBlockAction

    public init(actorUserID: UserID, operationID: UserBlockOperationID, targetUserID: UserID, action: V2UserBlockAction) throws {
        guard actorUserID != targetUserID else { throw V2SocialRelationshipValidationError.selfTargetingNotAllowed }
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.targetUserID = targetUserID
        self.action = action
    }
}

public struct V2RelationshipChange: Equatable, Sendable {
    public let actorUserID: UserID
    public let targetUserID: UserID
    public let action: V2RelationshipAction
    public let resultingState: V2RelationshipState
    public let updatedAt: Date

    public init(actorUserID: UserID, targetUserID: UserID, action: V2RelationshipAction, resultingState: V2RelationshipState, updatedAt: Date) {
        self.actorUserID = actorUserID
        self.targetUserID = targetUserID
        self.action = action
        self.resultingState = resultingState
        self.updatedAt = updatedAt
    }
}

public struct V2UserBlockChange: Equatable, Sendable {
    public let actorUserID: UserID
    public let targetUserID: UserID
    public let action: V2UserBlockAction
    public let isBlocked: Bool
    public let updatedAt: Date

    public init(actorUserID: UserID, targetUserID: UserID, action: V2UserBlockAction, isBlocked: Bool, updatedAt: Date) {
        self.actorUserID = actorUserID
        self.targetUserID = targetUserID
        self.action = action
        self.isBlocked = isBlocked
        self.updatedAt = updatedAt
    }
}

public enum V2SocialRelationshipValidationError: Error, Equatable, Sendable {
    case selfTargetingNotAllowed
}
