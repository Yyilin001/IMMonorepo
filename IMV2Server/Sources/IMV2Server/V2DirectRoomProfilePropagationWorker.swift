import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Bounded high-fan-out propagation for a display-name update. The account
/// service commits the source fact and its outbox record atomically; this
/// worker is the only component that enumerates direct counterparts. Group
/// membership is deliberately outside this path.
public struct V2DirectRoomProfilePropagationReport: Equatable, Sendable {
    public let claimedUpdateCount: Int
    public let projectedRecipientCount: Int
    public let completedUpdateCount: Int

    public init(claimedUpdateCount: Int, projectedRecipientCount: Int, completedUpdateCount: Int) {
        self.claimedUpdateCount = claimedUpdateCount
        self.projectedRecipientCount = projectedRecipientCount
        self.completedUpdateCount = completedUpdateCount
    }
}

/// The worker's durable checkpoint is advanced only after every projection in
/// the page has reached the live user shard. A crash before that checkpoint
/// replays the same page; `(recipient, source event, kind)` makes that replay
/// idempotent. This avoids a distributed transaction between control and user
/// shards without accepting a dropped profile update.
public struct V2DirectRoomProfilePropagationWorker: Sendable {
    private let database: any Database
    private let shadowForwarder: any V2UserShardProjectionShadowing
    private let liveNotifier: (any V2LiveSyncNotifier)?
    private let leaseDuration: TimeInterval
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    public init(
        database: any Database,
        shadowForwarder: any V2UserShardProjectionShadowing,
        liveNotifier: (any V2LiveSyncNotifier)? = nil,
        leaseDuration: TimeInterval = 30,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(leaseDuration > 0)
        self.database = database
        self.shadowForwarder = shadowForwarder
        self.liveNotifier = liveNotifier
        self.leaseDuration = leaseDuration
        self.makeUUID = makeUUID
        self.now = now
    }

    /// `limit` is a recipient work budget, rather than an unbounded count of
    /// source updates. One invocation therefore remains safe even when a
    /// profile has a very large direct-contact graph.
    public func runOnce(limit: Int) async throws -> V2DirectRoomProfilePropagationReport {
        guard limit > 0, limit < Int.max else {
            throw V2DirectRoomProfilePropagationError.invalidLimit
        }
        var remaining = limit
        var claimed = 0
        var projected = 0
        var completed = 0

        while remaining > 0, let lease = try await claimNext(now: now()) {
            claimed += 1
            // Read one non-delivered look-ahead row. It does not consume the
            // recipient work budget, but lets an exact full page complete
            // immediately instead of requiring an otherwise empty later
            // poll solely to discover the end of the graph.
            let candidates = try await directTargets(for: lease, limit: remaining + 1)
            let targets = Array(candidates.prefix(remaining))
            let isComplete = candidates.count <= remaining
            for target in targets {
                _ = try await appendControlProjections(target: target, lease: lease)
                let eventID = try EventID(lease.sourceEventID.uuidString)
                guard let liveSequence = try await shadowForwarder.shadowIfForwarding(
                    userID: try .init(target.userID.uuidString), sourceEventID: eventID,
                    projectionKinds: ["direct_room_profile", "profile_invalidation"]
                ) else {
                    throw V2DirectRoomProfilePropagationError.missingControlProjection
                }
                await liveNotifier?.notifySyncAvailable(
                    userID: try .init(target.userID.uuidString), eventID: liveSequence, highWatermark: liveSequence
                )
                projected += 1
            }

            // An empty contact graph still consumes one source update, so
            // concurrent profile changes cannot make this pass unbounded.
            remaining -= max(1, targets.count)
            try await advance(lease: lease, lastTargetUserID: targets.last?.userID, completed: isComplete, now: now())
            if isComplete { completed += 1 }
        }
        return .init(claimedUpdateCount: claimed, projectedRecipientCount: projected, completedUpdateCount: completed)
    }

    private func claimNext(now: Date) async throws -> ProfileUpdateLease? {
        guard let sql = database as? any SQLDatabase else { throw V2DirectRoomProfilePropagationError.corruptPersistenceState }
        guard let expiresAt = v2PostgresFutureTimestamp(now: now, interval: leaseDuration) else {
            throw V2DirectRoomProfilePropagationError.corruptPersistenceState
        }
        let token = makeUUID()
        return try await sql.raw("""
            WITH candidate AS (
                SELECT source_event_id
                FROM im_v2.public_profile_update_outbox
                WHERE state = 'pending'
                   OR (state = 'claimed' AND lease_expires_at <= \(bind: now))
                ORDER BY created_at, source_event_id
                LIMIT 1
                FOR UPDATE SKIP LOCKED
            )
            UPDATE im_v2.public_profile_update_outbox AS outbox
            SET state = 'claimed', claim_token = \(bind: token),
                lease_expires_at = \(bind: expiresAt),
                retry_count = CASE WHEN outbox.state = 'claimed' AND outbox.retry_count < 9223372036854775807
                    THEN outbox.retry_count + 1 ELSE outbox.retry_count END
            FROM candidate
            WHERE outbox.source_event_id = candidate.source_event_id
            RETURNING outbox.source_event_id, outbox.source_user_id, outbox.public_handle,
                      outbox.display_name, outbox.account_kind, outbox.profile_state,
                      outbox.revision, outbox.profile_updated_at,
                      outbox.enumeration_checkpoint, outbox.claim_token
            """).first(decoding: ProfileUpdateLeaseRow.self).map(ProfileUpdateLease.init)
    }

    private func directTargets(for lease: ProfileUpdateLease, limit: Int) async throws -> [DirectProfileTarget] {
        guard let sql = database as? any SQLDatabase else { throw V2DirectRoomProfilePropagationError.corruptPersistenceState }
        return try await sql.raw("""
            SELECT pair.room_id,
                   CASE WHEN pair.lower_user_id = \(bind: lease.sourceUserID)
                        THEN pair.higher_user_id ELSE pair.lower_user_id END AS target_user_id
            FROM im_v2.direct_room_pairs AS pair
            INNER JOIN im_v2.room_memberships AS source_membership
                ON source_membership.room_id = pair.room_id
               AND source_membership.user_id = \(bind: lease.sourceUserID)
               AND source_membership.left_revision IS NULL
            INNER JOIN im_v2.room_memberships AS target_membership
                ON target_membership.room_id = pair.room_id
               AND target_membership.user_id = CASE WHEN pair.lower_user_id = \(bind: lease.sourceUserID)
                    THEN pair.higher_user_id ELSE pair.lower_user_id END
               AND target_membership.left_revision IS NULL
            WHERE (pair.lower_user_id = \(bind: lease.sourceUserID) OR pair.higher_user_id = \(bind: lease.sourceUserID))
              AND EXISTS (SELECT 1 FROM im_v2.messages WHERE room_id = pair.room_id)
              AND (\(bind: lease.enumerationCheckpoint) IS NULL OR
                   CASE WHEN pair.lower_user_id = \(bind: lease.sourceUserID)
                        THEN pair.higher_user_id ELSE pair.lower_user_id END > \(bind: lease.enumerationCheckpoint))
            ORDER BY target_user_id
            LIMIT \(bind: limit)
            """).all(decoding: DirectProfileTarget.self)
    }

    /// Current clients use the compact direct-room projection for conversation
    /// presentation and the revision fence for normalized profile hydration.
    /// Both records share one source event and are appended atomically so a
    /// retry cannot expose a half-updated projection.
    private func appendControlProjections(target: DirectProfileTarget, lease: ProfileUpdateLease) async throws -> UInt64 {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2DirectRoomProfilePropagationError.corruptPersistenceState }
            let existingInvalidation = try await sql.raw("""
                SELECT user_sync_sequence, payload->>'user_id' AS user_id,
                       (payload->>'minimum_profile_revision')::bigint AS minimum_profile_revision,
                       COALESCE(payload->>'profile_state', 'active') AS profile_state
                FROM im_v2.user_projection_effects
                WHERE user_id = \(bind: target.userID) AND source_event_id = \(bind: lease.sourceEventID)
                  AND projection_kind = 'profile_invalidation'
                """).first(decoding: ExistingProfileInvalidationRow.self)
            if let existingInvalidation, !existingInvalidation.matches(lease: lease) {
                throw V2DirectRoomProfilePropagationError.corruptPersistenceState
            }
            if lease.profileState != "active" {
                if let existingInvalidation {
                    return try directProfileUnsigned(existingInvalidation.sequence)
                }
                let invalidationSequence = try await allocateSequence(userID: target.userID, sql: sql)
                try await appendInvalidation(
                    target: target, lease: lease, sequence: invalidationSequence, sql: sql
                )
                return try directProfileUnsigned(invalidationSequence)
            }
            if let existing = try await sql.raw("""
                SELECT user_sync_sequence, payload->>'room_id' AS room_id,
                       payload->>'target_user_id' AS target_user_id,
                       payload->>'public_handle' AS public_handle,
                       payload->>'display_name' AS display_name,
                       payload->>'account_kind' AS account_kind,
                       (payload->>'revision')::bigint AS revision,
                       (payload->>'updated_at_ms')::bigint AS updated_at_ms
                FROM im_v2.user_projection_effects
                WHERE user_id = \(bind: target.userID) AND source_event_id = \(bind: lease.sourceEventID)
                  AND projection_kind = 'direct_room_profile'
                """).first(decoding: ExistingDirectProfileProjectionRow.self) {
                guard existing.matches(target: target, lease: lease) else {
                    throw V2DirectRoomProfilePropagationError.corruptPersistenceState
                }
                if let existingInvalidation {
                    return try directProfileUnsigned(max(existing.sequence, existingInvalidation.sequence))
                }
                let invalidationSequence = try await allocateSequence(userID: target.userID, sql: sql)
                try await appendInvalidation(
                    target: target, lease: lease, sequence: invalidationSequence, sql: sql
                )
                return try directProfileUnsigned(invalidationSequence)
            }
            let sequence = try await allocateSequence(userID: target.userID, sql: sql)
            // Match the room-event UUID spelling used by the gateway. The
            // direct-profile update must not create a second lexical room key
            // on a client that receives both projections.
            let wireRoomID = target.roomID.uuidString
            let wireTargetUserID = lease.sourceUserID.uuidString
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                VALUES (\(bind: target.userID), \(bind: sequence), \(bind: lease.sourceEventID), 'direct_room_profile',
                        jsonb_build_object('room_id', \(bind: wireRoomID),
                                           'target_user_id', \(bind: wireTargetUserID),
                                           'public_handle', \(bind: lease.publicHandle),
                                           'display_name', \(bind: lease.displayName),
                                           'account_kind', \(bind: lease.accountKind),
                                           'revision', \(bind: lease.revision),
                                           'updated_at_ms', \(bind: lease.updatedAtMilliseconds)),
                        \(bind: lease.profileUpdatedAt))
                """).run()
            if let existingInvalidation {
                return try directProfileUnsigned(max(sequence, existingInvalidation.sequence))
            }
            let invalidationSequence = try await allocateSequence(userID: target.userID, sql: sql)
            try await appendInvalidation(target: target, lease: lease, sequence: invalidationSequence, sql: sql)
            return try directProfileUnsigned(invalidationSequence)
        }
    }

    private func allocateSequence(userID: UUID, sql: any SQLDatabase) async throws -> Int64 {
        guard let sequence = try await sql.raw("""
            INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence)
            VALUES (\(bind: userID), 1)
            ON CONFLICT (user_id) DO UPDATE
            SET next_sequence = im_v2.user_sync_sequences.next_sequence + 1
            WHERE im_v2.user_sync_sequences.next_sequence < \(bind: Int64.max)
            RETURNING next_sequence AS user_sync_sequence
            """).first(decoding: DirectProfileSequenceRow.self) else {
            throw V2DirectRoomProfilePropagationError.corruptPersistenceState
        }
        return sequence.sequence
    }

    private func appendInvalidation(
        target: DirectProfileTarget,
        lease: ProfileUpdateLease,
        sequence: Int64,
        sql: any SQLDatabase
    ) async throws {
        try await sql.raw("""
            INSERT INTO im_v2.user_sync_log
                (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
            VALUES (\(bind: target.userID), \(bind: sequence), \(bind: lease.sourceEventID), 'profile_invalidation',
                    jsonb_build_object('user_id', \(bind: lease.sourceUserID.uuidString),
                                       'minimum_profile_revision', \(bind: lease.revision),
                                       'profile_state', \(bind: lease.profileState)),
                    \(bind: lease.profileUpdatedAt))
            """).run()
    }

    private func advance(lease: ProfileUpdateLease, lastTargetUserID: UUID?, completed: Bool, now: Date) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2DirectRoomProfilePropagationError.corruptPersistenceState }
        if completed {
            guard v2PostgresTimestampCanEncode(now) else {
                throw V2DirectRoomProfilePropagationError.corruptPersistenceState
            }
            try await sql.raw("""
                UPDATE im_v2.public_profile_update_outbox
                SET state = 'completed', claim_token = NULL, lease_expires_at = NULL,
                    completed_at = \(bind: now)
                WHERE source_event_id = \(bind: lease.sourceEventID) AND state = 'claimed'
                  AND claim_token = \(bind: lease.claimToken)
                """).run()
        } else {
            guard let lastTargetUserID else { throw V2DirectRoomProfilePropagationError.corruptPersistenceState }
            try await sql.raw("""
                UPDATE im_v2.public_profile_update_outbox
                SET state = 'pending', claim_token = NULL, lease_expires_at = NULL,
                    enumeration_checkpoint = \(bind: lastTargetUserID)
                WHERE source_event_id = \(bind: lease.sourceEventID) AND state = 'claimed'
                  AND claim_token = \(bind: lease.claimToken)
                """).run()
        }
    }
}

public enum V2DirectRoomProfilePropagationError: Error, Equatable, Sendable {
    case invalidLimit
    case corruptPersistenceState
    case missingControlProjection
}

private struct ProfileUpdateLease: Sendable {
    let sourceEventID: UUID
    let sourceUserID: UUID
    let publicHandle: String
    let displayName: String
    let accountKind: String
    let profileState: String
    let revision: Int64
    let profileUpdatedAt: V2PostgresTimestamp
    let enumerationCheckpoint: UUID?
    let claimToken: UUID

    let updatedAtMilliseconds: Int64
}

private struct ProfileUpdateLeaseRow: Decodable {
    let sourceEventID: UUID
    let sourceUserID: UUID
    let publicHandle: String
    let displayName: String
    let accountKind: String
    let profileState: String
    let revision: Int64
    let profileUpdatedAt: V2PostgresTimestamp
    let enumerationCheckpoint: UUID?
    let claimToken: UUID

    enum CodingKeys: String, CodingKey {
        case sourceEventID = "source_event_id"
        case sourceUserID = "source_user_id"
        case publicHandle = "public_handle"
        case displayName = "display_name"
        case accountKind = "account_kind"
        case profileState = "profile_state"
        case revision
        case profileUpdatedAt = "profile_updated_at"
        case enumerationCheckpoint = "enumeration_checkpoint"
        case claimToken = "claim_token"
    }
}

private extension ProfileUpdateLease {
    init(_ row: ProfileUpdateLeaseRow) throws {
        guard let milliseconds = try? v2GatewayMilliseconds(row.profileUpdatedAt.date) else {
            throw V2DirectRoomProfilePropagationError.corruptPersistenceState
        }
        updatedAtMilliseconds = milliseconds
        sourceEventID = row.sourceEventID
        sourceUserID = row.sourceUserID
        publicHandle = row.publicHandle
        displayName = row.displayName
        accountKind = row.accountKind
        profileState = row.profileState
        revision = row.revision
        profileUpdatedAt = row.profileUpdatedAt
        enumerationCheckpoint = row.enumerationCheckpoint
        claimToken = row.claimToken
    }
}

private struct DirectProfileTarget: Decodable {
    let roomID: UUID
    let userID: UUID

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case userID = "target_user_id"
    }
}

private struct DirectProfileSequenceRow: Decodable {
    let sequence: Int64
    enum CodingKeys: String, CodingKey { case sequence = "user_sync_sequence" }
}

private struct ExistingDirectProfileProjectionRow: Decodable {
    let sequence: Int64
    let roomID: String
    let targetUserID: String
    let publicHandle: String
    let displayName: String
    let accountKind: String
    let revision: Int64
    let updatedAtMilliseconds: Int64

    enum CodingKeys: String, CodingKey {
        case sequence = "user_sync_sequence"
        case roomID = "room_id"
        case targetUserID = "target_user_id"
        case publicHandle = "public_handle"
        case displayName = "display_name"
        case accountKind = "account_kind"
        case revision
        case updatedAtMilliseconds = "updated_at_ms"
    }

    func matches(target: DirectProfileTarget, lease: ProfileUpdateLease) -> Bool {
        guard let persistedRoomID = UUID(uuidString: roomID),
              let persistedTargetUserID = UUID(uuidString: targetUserID),
              persistedRoomID == target.roomID,
              persistedTargetUserID == lease.sourceUserID
        else {
            return false
        }
        return publicHandle == lease.publicHandle && displayName == lease.displayName &&
            accountKind == lease.accountKind &&
            revision == lease.revision && updatedAtMilliseconds == lease.updatedAtMilliseconds
    }
}

private struct ExistingProfileInvalidationRow: Decodable {
    let sequence: Int64
    let userID: String
    let minimumProfileRevision: Int64
    let profileState: String

    enum CodingKeys: String, CodingKey {
        case sequence = "user_sync_sequence"
        case userID = "user_id"
        case minimumProfileRevision = "minimum_profile_revision"
        case profileState = "profile_state"
    }

    func matches(lease: ProfileUpdateLease) -> Bool {
        userID == lease.sourceUserID.uuidString && minimumProfileRevision == lease.revision &&
            profileState == lease.profileState
    }
}

private func directProfileUnsigned(_ value: Int64) throws -> UInt64 {
    guard value > 0 else { throw V2DirectRoomProfilePropagationError.corruptPersistenceState }
    return UInt64(value)
}
