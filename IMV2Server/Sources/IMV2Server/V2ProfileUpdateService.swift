import Foundation
import IMV2Core

/// Result of a revision-fenced profile mutation. `idempotent` means the same
/// operation was already committed; callers receive its original profile
/// revision instead of allocating another propagation event.
public enum V2ProfileUpdateOutcome: Equatable, Sendable {
    case updated(V2ProfileView)
    case idempotent(V2ProfileView)
}

public protocol V2ProfileUpdateStore: Sendable {
    func update(_ command: V2ProfileUpdateCommand) async throws -> V2ProfileUpdateOutcome
}

public struct V2ProfileUpdateService: Sendable {
    private let store: any V2ProfileUpdateStore

    public init(store: any V2ProfileUpdateStore) {
        self.store = store
    }

    public func update(_ command: V2ProfileUpdateCommand) async throws -> V2ProfileUpdateOutcome {
        try await store.update(command)
    }
}

public enum V2ProfileUpdateError: Error, Equatable, Sendable {
    case unavailable
    case revisionConflict(current: V2ProfileRevision)
    case operationPayloadMismatch
    case avatarUnavailable
    case corruptPersistenceState
}
