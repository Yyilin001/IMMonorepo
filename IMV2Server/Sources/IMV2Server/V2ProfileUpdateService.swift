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

/// Kept separate from mutation so each capability remains independently
/// testable while the profile API composes both at startup.
public protocol V2OwnProfileReading: Sendable {
    func currentProfile(for actorUserID: UserID) async throws -> V2ProfileView
}

public struct V2ProfileUpdateService: Sendable {
    private let store: any V2ProfileUpdateStore
    private let reader: any V2OwnProfileReading

    public init(store: any V2ProfileUpdateStore, reader: any V2OwnProfileReading) {
        self.store = store
        self.reader = reader
    }

    public func update(_ command: V2ProfileUpdateCommand) async throws -> V2ProfileUpdateOutcome {
        try await store.update(command)
    }

    public func currentProfile(for actorUserID: UserID) async throws -> V2ProfileView {
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
