import Foundation
import IMV2Core

/// Device-local read models derived only from durable user-sync records. They
/// intentionally expose no explanation for another user's blocked state.
public struct V2ClientRelationshipProjection: Equatable, Sendable {
    public let targetUserID: UserID
    public let state: V2RelationshipState
    public let requestedByUserID: UserID?
    public let updatedAt: Date
    public init(targetUserID: UserID, state: V2RelationshipState, requestedByUserID: UserID?, updatedAt: Date) { self.targetUserID = targetUserID; self.state = state; self.requestedByUserID = requestedByUserID; self.updatedAt = updatedAt }
}

public enum V2ClientRelationshipPageScope: Equatable, Sendable {
    case accepted
    case incomingRequests(currentUserID: UserID)
    case outgoingRequests(currentUserID: UserID)
}

public struct V2ClientRelationshipCursor: Equatable, Sendable {
    public let updatedAt: Date
    public let targetUserID: UserID

    public init(updatedAt: Date, targetUserID: UserID) {
        self.updatedAt = updatedAt
        self.targetUserID = targetUserID
    }
}

public struct V2ClientRelationshipPage: Equatable, Sendable {
    public let relationships: [V2ClientRelationshipProjection]
    public let nextCursor: V2ClientRelationshipCursor?
    public let totalCount: Int?

    public init(
        relationships: [V2ClientRelationshipProjection],
        nextCursor: V2ClientRelationshipCursor?,
        totalCount: Int?
    ) {
        self.relationships = relationships
        self.nextCursor = nextCursor
        self.totalCount = totalCount
    }
}

public struct V2ClientUserBlockProjection: Equatable, Sendable {
    public let targetUserID: UserID
    public let isBlocked: Bool
    public let updatedAt: Date
    public init(targetUserID: UserID, isBlocked: Bool, updatedAt: Date) { self.targetUserID = targetUserID; self.isBlocked = isBlocked; self.updatedAt = updatedAt }
}

public struct V2ClientStrangerMessagePreference: Equatable, Sendable {
    public let allowsStrangerMessages: Bool
    public let updatedAt: Date
    public init(allowsStrangerMessages: Bool, updatedAt: Date) { self.allowsStrangerMessages = allowsStrangerMessages; self.updatedAt = updatedAt }
}

public struct V2ClientUserAddPreference: Equatable, Sendable {
    public let allowsBeingAdded: Bool
    public let updatedAt: Date
    public init(allowsBeingAdded: Bool, updatedAt: Date) { self.allowsBeingAdded = allowsBeingAdded; self.updatedAt = updatedAt }
}

public enum V2ClientSocialProjectionError: Error, Equatable, Sendable { case invalidPayload }
