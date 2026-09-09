import Fluent
import Foundation
import IMV2Core

/// All room operations select the durable owner, including single-database
/// deployments. The selected PostgreSQL transaction checks the room's epoch;
/// stale routes and unknown owners never fall back to control or another owner.
public struct V2RoutedGroupInvitationStore: V2GroupInvitationStore, V2GroupInviteCreationResuming {
    private let router: any V2RoomShardRouting
    private let owners: any V2RoomShardStorageResolving
    private let directory: any V2GroupInviteDirectory
    private let identities: any V2GroupInvitationIdentityReading

    public init(controlDatabase: any Database, router: any V2RoomShardRouting, owners: any V2RoomShardStorageResolving) {
        self.router = router
        self.owners = owners
        self.directory = PostgresV2GroupInviteDirectory(database: controlDatabase)
        self.identities = PostgresV2GroupInvitationIdentityReader(database: controlDatabase)
    }

    public func create(_ request: V2GroupInviteCreatePersistenceRequest) async throws -> V2StoredGroupInvite {
        // Reject missing rooms and unauthorized new creations before allocating
        // a durable control intent. The owner repeats authorization on commit.
        let existing = try await owner(roomID: request.roomID).preflightCreation(request)
        // A legacy owner can hold the creation before control has a directory
        // entry. Preflight verified its business input; preserve that binding
        // instead of allocating a contradictory ID/time from this retry.
        // Existing directory intents stay immutable, and owner commit still
        // resolves the current route and rechecks its epoch and original input.
        let candidate: V2GroupInviteCreatePersistenceRequest
        if let existing {
            candidate = .init(inviteID: existing.inviteID, roomID: request.roomID,
                actorUserID: request.actorUserID, operationID: request.operationID,
                tokenDigest: request.tokenDigest, requestedLifetimeSeconds: request.requestedLifetimeSeconds,
                expiresAt: existing.expiresAt, maximumApprovedUses: request.maximumApprovedUses,
                maximumActiveInvitesPerRoom: request.maximumActiveInvitesPerRoom,
                createdAt: existing.createdAt, evaluatedAt: request.evaluatedAt)
                .preservingTimestamps(existing.persistedTimestamps)
        } else {
            candidate = request
        }
        return try await V2GroupInviteCreationCoordinator(directory: directory).create(candidate) { fixed in
            try await owner(roomID: fixed.roomID).create(fixed)
        }
    }

    public func resumeCreation(_ intent: V2GroupInviteCreationIntent, now: Date) async throws {
        _ = try await create(intent.request.evaluated(at: now))
    }

    public func activeInvites(roomID: RoomID, actorUserID: UserID, now: Date) async throws -> [V2StoredGroupInvite] {
        let values = try await owner(roomID: roomID).activeInvites(roomID: roomID, actorUserID: actorUserID, now: now)
        // An owner commit can outlive a lost finalize response. Never return an
        // unregistered token from the management list; creation retry resumes it.
        let ready = try await directory.readyInvites(roomID: roomID, inviteIDs: Set(values.map(\.inviteID)))
        return values.filter { ready.contains($0.inviteID) }
    }

    public func revoke(inviteID: GroupInviteID, roomID: RoomID, actorUserID: UserID, operationID: GroupInviteOperationID, now: Date) async throws {
        try await owner(roomID: roomID).revoke(inviteID: inviteID, roomID: roomID, actorUserID: actorUserID, operationID: operationID, now: now)
    }

    public func preview(tokenDigest: Data, applicantUserID: UserID, now: Date) async throws -> V2GroupInvitePreviewPersistenceOutcome {
        guard let location = try await directory.resolve(tokenDigest: tokenDigest) else { return .unavailable }
        return try await owner(roomID: location.roomID, inviteID: location.inviteID).preview(tokenDigest: tokenDigest, applicantUserID: applicantUserID, now: now)
    }

    public func submit(_ request: V2GroupJoinSubmissionPersistenceRequest) async throws -> V2GroupJoinSubmissionPersistenceOutcome {
        guard let location = try await directory.resolve(tokenDigest: request.tokenDigest) else { return .unavailable }
        return try await owner(roomID: location.roomID, inviteID: location.inviteID).submit(request)
    }

    public func pendingRequests(roomID: RoomID, reviewerUserID: UserID, cursor: String?, pageSize: Int, now: Date) async throws -> V2GroupJoinRequestRecordPage {
        try await owner(roomID: roomID).pendingRequests(roomID: roomID, reviewerUserID: reviewerUserID, cursor: cursor, pageSize: pageSize, now: now)
    }

    public func approve(roomID: RoomID, requestID: GroupJoinRequestID, reviewerUserID: UserID, operationID: GroupJoinDecisionOperationID, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2GroupJoinApprovalPersistenceOutcome {
        try await owner(roomID: roomID).approve(roomID: roomID, requestID: requestID, reviewerUserID: reviewerUserID, operationID: operationID, capacityProfile: capacityProfile, eventID: eventID, planID: planID, now: now)
    }

    public func reject(roomID: RoomID, requestID: GroupJoinRequestID, reviewerUserID: UserID, operationID: GroupJoinDecisionOperationID, now: Date) async throws -> V2GroupJoinDecisionPreparationOutcome {
        try await owner(roomID: roomID).reject(roomID: roomID, requestID: requestID, reviewerUserID: reviewerUserID, operationID: operationID, now: now)
    }

    private func owner(roomID: RoomID, inviteID: GroupInviteID? = nil) async throws -> PostgresV2GroupInvitationStore {
        guard let room = roomID.uuidValue else { throw V2GroupInvitationServiceError.invalidRequest }
        let route = try await router.route(for: roomID)
        let location = try owners.location(for: route.shardID)
        guard location.schema == "im_v2" else { throw V2RoomShardStorageRegistryError.invalidLocation }
        return .init(database: location.database, identities: identities, scope: .init(roomID: room, route: route, inviteID: inviteID?.uuidValue))
    }
}
