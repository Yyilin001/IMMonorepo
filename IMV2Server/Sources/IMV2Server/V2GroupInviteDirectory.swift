import Foundation
import IMV2Core

/// Control owns only the token locator and retry-stable creation input. Room
/// authorization, validity, usage and decisions remain on the current owner.
public struct V2GroupInviteLocation: Equatable, Sendable {
    public let inviteID: GroupInviteID
    public let roomID: RoomID
}

public struct V2GroupInviteCreationIntent: Sendable {
    public let request: V2GroupInviteCreatePersistenceRequest
    public let isReady: Bool
}

public enum V2GroupInviteDirectoryError: Error, Equatable, Sendable {
    case invalidRequest
    case conflict
    case ownerResultMismatch
    case corruptPersistenceState
}

public protocol V2GroupInviteDirectory: Sendable {
    /// A retry with the same actor/operation and business input returns the
    /// original invite ID and timestamps, regardless of the new candidates.
    func prepare(_ request: V2GroupInviteCreatePersistenceRequest) async throws -> V2GroupInviteCreationIntent
    /// Call only after the owner has durably committed the matching invite.
    func finalize(_ intent: V2GroupInviteCreationIntent, now: Date) async throws
    /// Prepared intents are never visible to token-only preview/submission.
    func resolve(tokenDigest: Data) async throws -> V2GroupInviteLocation?
    func readyInvites(roomID: RoomID, inviteIDs: Set<GroupInviteID>) async throws -> Set<GroupInviteID>
}

/// No database transaction spans the owner call. On an uncertain owner result
/// the durable intent stays prepared, and a retry uses the same owner operation.
/// The owner callback must resolve the room's current route and enforce its epoch
/// in the transaction; a token directory entry is never an ownership claim.
public struct V2GroupInviteCreationCoordinator: Sendable {
    private let directory: any V2GroupInviteDirectory

    public init(directory: any V2GroupInviteDirectory) { self.directory = directory }

    public func create(
        _ request: V2GroupInviteCreatePersistenceRequest,
        ownerCommit: @Sendable (V2GroupInviteCreatePersistenceRequest) async throws -> V2StoredGroupInvite
    ) async throws -> V2StoredGroupInvite {
        let intent = try await directory.prepare(request)
        let stored = try await ownerCommit(intent.request)
        guard stored.inviteID == intent.request.inviteID,
              stored.roomID == intent.request.roomID,
              stored.createdByUserID == intent.request.actorUserID,
              stored.creationOperationID == intent.request.operationID,
              stored.maximumApprovedUses == intent.request.maximumApprovedUses,
              creationTimesMatch(stored, intent.request)
        else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
        try await directory.finalize(intent, now: request.evaluatedAt)
        return stored
    }

    private func creationTimesMatch(_ stored: V2StoredGroupInvite, _ request: V2GroupInviteCreatePersistenceRequest) -> Bool {
        // A database receipt must prove the exact immutable binding. Date's
        // approximation must not hide differences that persistence preserves.
        if let actual = stored.persistedTimestamps, let expected = request.persistedTimestamps {
            return actual == expected
        }
        // Retain the established tolerance for Date-only store adapters.
        return abs(stored.createdAt.timeIntervalSince(request.createdAt)) < 0.000002
            && abs(stored.expiresAt.timeIntervalSince(request.expiresAt)) < 0.000002
    }
}
