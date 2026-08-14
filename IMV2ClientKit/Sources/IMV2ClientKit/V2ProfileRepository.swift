import Foundation
import IMV2Core

/// The persistence boundary consumed by profile hydration. Views and feature
/// stores depend on `V2ProfileRepository`, never directly on GRDB rows.
public protocol V2ClientProfileProjectionStore: Sendable {
    func profileView(userID: UserID) async throws -> V2ProfileView?
    func profileViews(userIDs: [UserID]) async throws -> [UserID: V2ProfileView]
    func saveProfileView(_ profile: V2ProfileView) async throws
    func markProfileUnavailable(userID: UserID) async throws
    func pendingProfileInvalidations(limit: Int) async throws -> [V2ProfileInvalidation]
    func applyProfileViewResults(_ results: [V2ProfileViewLookupResult]) async throws
}

public extension V2ClientProfileProjectionStore {
    /// Compatibility implementation for small fakes. Persistent stores should
    /// override this and commit the complete authorized response atomically.
    func applyProfileViewResults(_ results: [V2ProfileViewLookupResult]) async throws {
        let batch = V2ProfileViewResultBatch(results)
        for profile in batch.profiles.values {
            try Task.checkCancellation()
            try await saveProfileView(profile)
        }
        for userID in batch.unavailableUserIDs.subtracting(batch.profiles.keys) {
            try Task.checkCancellation()
            try await markProfileUnavailable(userID: userID)
        }
    }
}

/// Coordinates remote hydration with the durable projection. The actor owns
/// no UI state and never leaks transport DTOs above this boundary.
public actor V2ProfileRepository {
    private let store: any V2ClientProfileProjectionStore
    private let reader: any V2ProfileViewReading

    public init(store: any V2ClientProfileProjectionStore, reader: any V2ProfileViewReading) {
        self.store = store
        self.reader = reader
    }

    public func profileView(userID: UserID) async throws -> V2ProfileView? {
        try await store.profileView(userID: userID)
    }

    /// Hydrates only the requested contexts. A server-side unavailable result
    /// removes any stale authorized projection for that target immediately.
    @discardableResult
    public func hydrate(_ keys: [V2ProfileViewLookupKey]) async throws -> Set<UserID> {
        guard !keys.isEmpty else { return [] }
        let results = try await reader.readProfileViews(keys)
        guard results.count == keys.count,
              Set(results.map(\.key)) == Set(keys),
              V2ProfileViewResultBatch(results).hasConsistentProfiles
        else {
            throw V2ProfileRepositoryError.invalidResponse
        }
        try Task.checkCancellation()
        try await store.applyProfileViewResults(results)
        var changedUserIDs = Set<UserID>()
        for result in results {
            try Task.checkCancellation()
            switch result {
            case .profile(_, let view):
                changedUserIDs.insert(view.userID)
            case .unavailable(let key):
                changedUserIDs.insert(key.userID)
            }
        }
        return changedUserIDs
    }

    /// Direct-profile invalidations are delivered through the durable personal
    /// sync log. They have an implicit direct-room authorization context.
    @discardableResult
    public func refreshPendingInvalidations(limit: Int = V2ProfileViewLookupLimits.maximumKeys) async throws -> Set<UserID> {
        let invalidations = try await store.pendingProfileInvalidations(limit: limit)
        return try await hydrate(invalidations.map {
            .init(userID: $0.userID, context: .directConversation)
        })
    }

    public func resolve(
        userID: UserID,
        alias: V2ContactAlias? = nil,
        groupMember: V2GroupMemberPresentation? = nil,
        surface: V2ProfileDisplaySurface
    ) async throws -> V2ResolvedProfile {
        V2ProfileResolver.resolve(
            userID: userID,
            profile: try await store.profileView(userID: userID),
            alias: alias,
            groupMember: groupMember,
            surface: surface
        )
    }
}

struct V2ProfileViewResultBatch {
    let profiles: [UserID: V2ProfileView]
    let unavailableUserIDs: Set<UserID>
    let hasConsistentProfiles: Bool

    init(_ results: [V2ProfileViewLookupResult]) {
        var profiles: [UserID: V2ProfileView] = [:]
        var unavailableUserIDs = Set<UserID>()
        var isConsistent = true
        for result in results {
            switch result {
            case .profile(_, let profile):
                if let existing = profiles[profile.userID], existing != profile {
                    isConsistent = false
                } else {
                    profiles[profile.userID] = profile
                }
            case .unavailable(let key):
                unavailableUserIDs.insert(key.userID)
            }
        }
        self.profiles = profiles
        self.unavailableUserIDs = unavailableUserIDs
        hasConsistentProfiles = isConsistent
    }
}

public enum V2ProfileRepositoryError: Error, Equatable, Sendable {
    /// A profile endpoint must return exactly one result for every requested
    /// authorization context. Treating a partial response as success could
    /// leave an invalidated, no-longer-readable value on disk.
    case invalidResponse
}
