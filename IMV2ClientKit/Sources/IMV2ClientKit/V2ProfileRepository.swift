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
              Set(results.map(\.key)) == Set(keys)
        else {
            throw V2ProfileRepositoryError.invalidResponse
        }
        var changedUserIDs = Set<UserID>()
        for result in results {
            try Task.checkCancellation()
            switch result {
            case .profile(_, let view):
                try await store.saveProfileView(view)
                changedUserIDs.insert(view.userID)
            case .unavailable(let key):
                try await store.markProfileUnavailable(userID: key.userID)
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

public enum V2ProfileRepositoryError: Error, Equatable, Sendable {
    /// A profile endpoint must return exactly one result for every requested
    /// authorization context. Treating a partial response as success could
    /// leave an invalidated, no-longer-readable value on disk.
    case invalidResponse
}
