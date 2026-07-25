import Foundation
import IMV2Core

public enum V2RelationshipOutcome: Equatable, Sendable {
    case changed(V2RelationshipChange)
    case idempotent(V2RelationshipChange)
    case idempotencyConflict
    case invalidState
    /// A block is intentionally surfaced as a generic authorization failure;
    /// callers must never learn which side owns the block.
    case forbidden
}

public enum V2UserBlockOutcome: Equatable, Sendable {
    case changed(V2UserBlockChange)
    case idempotent(V2UserBlockChange)
    case idempotencyConflict
}

public protocol V2SocialRelationshipStore: Sendable {
    func changeRelationship(_ command: V2ChangeRelationshipCommand, now: Date) async throws -> V2RelationshipOutcome
    func changeUserBlock(_ command: V2ChangeUserBlockCommand, now: Date) async throws -> V2UserBlockOutcome
}

/// Authenticated relationship and block command boundary. The store owns the
/// pair lock, durable idempotency result, and user-sync projections.
public struct V2SocialRelationshipService: Sendable {
    private let store: any V2SocialRelationshipStore
    private let now: @Sendable () -> Date

    public init(store: any V2SocialRelationshipStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    public func changeRelationship(actorUserID: UserID, operationID: RelationshipOperationID, targetUserID: UserID, action: V2RelationshipAction) async throws -> V2RelationshipOutcome {
        try await store.changeRelationship(try .init(actorUserID: actorUserID, operationID: operationID, targetUserID: targetUserID, action: action), now: now())
    }

    public func changeUserBlock(actorUserID: UserID, operationID: UserBlockOperationID, targetUserID: UserID, action: V2UserBlockAction) async throws -> V2UserBlockOutcome {
        try await store.changeUserBlock(try .init(actorUserID: actorUserID, operationID: operationID, targetUserID: targetUserID, action: action), now: now())
    }
}
