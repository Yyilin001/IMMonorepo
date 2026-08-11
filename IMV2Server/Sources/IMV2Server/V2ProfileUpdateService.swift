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

/// Kept separate from mutation so tests and deployments may expose profile
/// editing only when the authenticated own-profile reader is configured.
public protocol V2OwnProfileReading: Sendable {
    func currentProfile(for actorUserID: UserID) async throws -> V2ProfileView
}

public struct V2ProfileUpdateService: Sendable {
    private let store: any V2ProfileUpdateStore
    private let reader: (any V2OwnProfileReading)?

    public init(store: any V2ProfileUpdateStore, reader: (any V2OwnProfileReading)? = nil) {
        self.store = store
        self.reader = reader
    }

    public func update(_ command: V2ProfileUpdateCommand) async throws -> V2ProfileUpdateOutcome {
        try await store.update(command)
    }

    public func currentProfile(for actorUserID: UserID) async throws -> V2ProfileView {
        guard let reader else { throw V2ProfileUpdateError.unavailable }
        return try await reader.currentProfile(for: actorUserID)
    }
}

public enum V2ProfileUpdateError: Error, Equatable, Sendable {
    case unavailable
    case revisionConflict(current: V2ProfileRevision)
    case operationPayloadMismatch
    case avatarUnavailable
    case corruptPersistenceState
}
