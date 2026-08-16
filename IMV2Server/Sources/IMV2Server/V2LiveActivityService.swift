import Foundation
import IMV2Core

public enum V2SetLiveActivityPreferencesOutcome: Equatable, Sendable {
    case updated(V2LiveActivityPreferences)
    case idempotent(V2LiveActivityPreferences)
    case idempotencyConflict
}

public enum V2LiveActivityStoreError: Error, Equatable, Sendable {
    case roomNotFound
    case actorNotMember
    case typingNotAllowed
    /// A direct-room block intentionally has the same externally observable
    /// effect as any other authorization denial.
    case interactionBlocked
    case notDirectRoom
    case corruptPersistenceState
}

/// Database-backed authorization and preference boundary. The states it
/// authorizes are kept in the gateway registry and deliberately never enter a
/// durable chat/event projection.
public protocol V2LiveActivityStore: Sendable {
    func setPreferences(command: V2SetLiveActivityPreferencesCommand, now: Date) async throws -> V2SetLiveActivityPreferencesOutcome
    func preferences(userID: UserID, now: Date) async throws -> V2LiveActivityPreferences
    func presence(roomID: RoomID, viewerUserID: UserID, now: Date) async throws -> V2PresenceState
    func authorizeTyping(roomID: RoomID, actorUserID: UserID, now: Date) async throws
    /// Re-checks delivery authorization for ephemeral events.  This is
    /// separate from subscribing because a user can block someone after a
    /// socket has already subscribed.
    func authorizeObservation(roomID: RoomID, viewerUserID: UserID, subjectUserID: UserID, now: Date) async throws
    func allowsOnlinePresence(userID: UserID) async throws -> Bool
}

/// Connection lifecycle owns the lease, while request handlers own room
/// authorization. Keeping the two protocols separate prevents a socket from
/// gaining database authorization capabilities.
public protocol V2LivePresenceLeaseManaging: Sendable {
    /// Admits a new authenticated connection against the cross-replica
    /// device/user budgets. This is intentionally separate from renewal so a
    /// routine heartbeat never repeats the locks and aggregate counts required
    /// only at the connection boundary.
    func admitConnection(
        identity: V2AuthenticatedConnection,
        connectionID: UUID,
        policy: V2AuthenticatedConnectionAdmissionPolicy,
        now: Date
    ) async throws -> V2AuthenticatedConnectionLeaseOutcome
    /// Extends only an existing, unexpired, identity-matching lease. A missing
    /// or expired row is rejected rather than being resurrected without the
    /// full admission transaction.
    func renewConnection(
        identity: V2AuthenticatedConnection,
        connectionID: UUID,
        now: Date
    ) async throws -> V2AuthenticatedConnectionLeaseOutcome
    /// Returns whether another unexpired connection still keeps the user online.
    func removePresence(identity: V2AuthenticatedConnection, connectionID: UUID, now: Date) async throws -> Bool
    func allowsOnlinePresence(userID: UserID) async throws -> Bool
}

/// Registry-side delivery policy for best-effort activity.  The registry owns
/// sockets, while the database-backed service remains the authority for room
/// membership and direct-room block state.
public protocol V2LiveActivityObservationAuthorizing: Sendable {
    func authorizeObservation(roomID: RoomID, viewerUserID: UserID, subjectUserID: UserID, now: Date) async throws
}

public struct V2LiveActivityService: Sendable, V2LiveActivityObservationAuthorizing {
    private let store: any V2LiveActivityStore

    public init(store: any V2LiveActivityStore) { self.store = store }

    public func setPreferences(_ command: V2SetLiveActivityPreferencesCommand, now: Date) async throws -> V2SetLiveActivityPreferencesOutcome {
        try await store.setPreferences(command: command, now: now)
    }

    public func preferences(userID: UserID, now: Date) async throws -> V2LiveActivityPreferences {
        try await store.preferences(userID: userID, now: now)
    }

    public func presence(roomID: RoomID, viewerUserID: UserID, now: Date) async throws -> V2PresenceState {
        try await store.presence(roomID: roomID, viewerUserID: viewerUserID, now: now)
    }

    public func authorizeTyping(roomID: RoomID, actorUserID: UserID, now: Date) async throws {
        try await store.authorizeTyping(roomID: roomID, actorUserID: actorUserID, now: now)
    }

    public func authorizeObservation(roomID: RoomID, viewerUserID: UserID, subjectUserID: UserID, now: Date) async throws {
        try await store.authorizeObservation(
            roomID: roomID,
            viewerUserID: viewerUserID,
            subjectUserID: subjectUserID,
            now: now
        )
    }

    public func allowsOnlinePresence(userID: UserID) async throws -> Bool {
        try await store.allowsOnlinePresence(userID: userID)
    }
}

extension PostgresV2LiveActivityStore: V2LivePresenceLeaseManaging {}
