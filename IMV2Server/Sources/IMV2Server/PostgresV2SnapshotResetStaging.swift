import Foundation
import IMV2Core
import SQLKit

/// Shared primitive for automatic low-cursor recovery and operator resets.
/// The caller must hold the device cursor row lock in its transaction.
struct PostgresV2SnapshotResetStager {
    struct Result: Sendable {
        let snapshotID: UUID
        let generation: Int64
        let baseSequence: Int64
    }

    static func stage(
        sql: any SQLDatabase,
        schema: String,
        userID: UUID,
        deviceID: UUID,
        currentGeneration: Int64,
        retainedFloor: Int64,
        capabilityProfile: String,
        capabilityLifetime: TimeInterval,
        now: Date,
        makeUUID: @Sendable () -> UUID
    ) async throws -> Result {
        guard currentGeneration > 0,
              retainedFloor >= 0,
              capabilityLifetime.isFinite,
              capabilityLifetime > 0,
              !capabilityProfile.isEmpty,
              let checkpoint = try await sql.raw("""
                SELECT projected_sequence
                FROM \(unsafeRaw: table(schema, "user_projection_checkpoints"))
                WHERE user_id = \(bind: userID)
                  AND state = 'ready'
                  AND (migration_fence_expires_at IS NULL
                       OR migration_fence_expires_at <= \(bind: now))
                """).first(decoding: SnapshotResetCheckpointRow.self)
        else { throw V2SyncStoreError.snapshotCheckpointUnavailable }
        let (generation, overflow) = currentGeneration.addingReportingOverflow(1)
        guard !overflow, generation > currentGeneration else {
            throw V2SyncStoreError.snapshotCheckpointUnavailable
        }

        let nextToken = makeUUID().uuidString
        let receipt = makeUUID().uuidString
        let checkpointBase = checkpoint.projectedSequence
        guard retainedFloor <= checkpointBase else {
            throw V2SyncStoreError.snapshotCheckpointUnavailable
        }
        let assignmentExpiresAt = now.addingTimeInterval(capabilityLifetime)
        // Serialize all automatic artifacts for one user/profile, not merely
        // one exact checkpoint. A still-valid older base at/above the retained
        // floor can serve a newly reconnecting device; normal incremental
        // sync catches it up after snapshot ACK.
        let artifactLock = "v2-snapshot-artifact:\(userID.uuidString):\(capabilityProfile)"
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: artifactLock), 0))").run()
        let artifact: SnapshotResetArtifactRow
        if let existing = try await sql.raw("""
            SELECT snapshot_id, base_user_sync_sequence, state, expires_at
            FROM \(unsafeRaw: table(schema, "sync_snapshot_artifacts"))
            WHERE user_id = \(bind: userID)
              AND base_user_sync_sequence >= \(bind: retainedFloor)
              AND base_user_sync_sequence <= \(bind: checkpointBase)
              AND source_projected_sequence = base_user_sync_sequence
              AND schema_version = \(bind: Int32(V2SnapshotProjectionV3Codec.schemaVersion))
              AND capability_profile = \(bind: capabilityProfile)
              AND state IN ('building', 'published')
              AND expires_at > \(bind: now)
            ORDER BY base_user_sync_sequence DESC, created_at DESC
            LIMIT 1
            FOR UPDATE
            """).first(decoding: SnapshotResetArtifactRow.self) {
            // A late-arriving device receives a full capability lifetime.
            // Keep the shared immutable payload alive for at least as long as
            // its newest assignment instead of inheriting the first device's
            // nearly-expired deadline.
            if existing.expiresAt < assignmentExpiresAt {
                try await sql.raw("""
                    UPDATE \(unsafeRaw: table(schema, "sync_snapshot_artifacts"))
                    SET expires_at = \(bind: assignmentExpiresAt)
                    WHERE snapshot_id = \(bind: existing.snapshotID)
                    """).run()
            }
            artifact = .init(
                snapshotID: existing.snapshotID,
                baseSequence: existing.baseSequence,
                state: existing.state,
                expiresAt: max(existing.expiresAt, assignmentExpiresAt)
            )
        } else {
            let snapshotID = makeUUID()
            let initialDigest = V2SnapshotV3Digest.initial(
                baseSequence: UInt64(checkpointBase), capabilityProfile: capabilityProfile
            )
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table(schema, "sync_snapshot_artifacts"))
                    (snapshot_id, user_id, base_user_sync_sequence,
                     source_projected_sequence, schema_version,
                     capability_profile, state, rolling_digest,
                     expires_at, created_at)
                VALUES (\(bind: snapshotID), \(bind: userID), \(bind: checkpointBase), \(bind: checkpointBase),
                        \(bind: Int32(V2SnapshotProjectionV3Codec.schemaVersion)),
                        \(bind: capabilityProfile), 'building', \(bind: initialDigest),
                        \(bind: assignmentExpiresAt), \(bind: now))
                """).run()
            artifact = .init(
                snapshotID: snapshotID,
                baseSequence: checkpointBase,
                state: "building",
                expiresAt: assignmentExpiresAt
            )
        }
        let resetState = artifact.state == "published" ? "ready" : "preparing"
        let cursorState = artifact.state == "published" ? "reset_pending" : "reset_preparing"
        let base = artifact.baseSequence
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: table(schema, "device_snapshot_resets"))
                (user_id, device_id, reset_generation, snapshot_id, state,
                 next_sync_token, snapshot_receipt, expires_at, created_at)
            VALUES (\(bind: userID), \(bind: deviceID), \(bind: generation),
                    \(bind: artifact.snapshotID), \(bind: resetState), \(bind: nextToken),
                    \(bind: receipt), \(bind: assignmentExpiresAt), \(bind: now))
            """).run()
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: table(schema, "sync_tokens"))
                (token, user_id, device_id, reset_generation, watermark,
                 expires_at, created_at)
            VALUES (\(bind: nextToken), \(bind: userID), \(bind: deviceID),
                    \(bind: generation), \(bind: base), \(bind: assignmentExpiresAt), \(bind: now))
            """).run()
        try await sql.raw("""
            UPDATE \(unsafeRaw: table(schema, "device_sync_cursors"))
            SET state = \(bind: cursorState), reset_generation = \(bind: generation),
                pending_snapshot_id = \(bind: artifact.snapshotID),
                pending_base_sequence = \(bind: base),
                pending_snapshot_expires_at = \(bind: assignmentExpiresAt)
            WHERE user_id = \(bind: userID) AND device_id = \(bind: deviceID)
              AND state = 'ready' AND reset_generation = \(bind: currentGeneration)
            """).run()
        return .init(
            snapshotID: artifact.snapshotID, generation: generation, baseSequence: base
        )
    }

    private static func table(_ schema: String, _ name: String) -> String {
        "\(schema).\(name)"
    }
}

private struct SnapshotResetArtifactRow: Decodable {
    let snapshotID: UUID
    let baseSequence: Int64
    let state: String
    let expiresAt: Date
    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id"
        case baseSequence = "base_user_sync_sequence"
        case state
        case expiresAt = "expires_at"
    }
}

private struct SnapshotResetCheckpointRow: Decodable {
    let projectedSequence: Int64
    enum CodingKeys: String, CodingKey {
        case projectedSequence = "projected_sequence"
    }
}
