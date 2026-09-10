import Crypto
import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 在物理分片之间流式迁移单个用户的完整数据面切片。
///
/// 迁移期间会以可续期的用户级栅栏暂停两端分片上的投影、构建与回收工作器，
/// 同时常规增量同步行仍可供迁移影子转发器使用。
public struct PostgresV2UserShardProjectionTransfer: V2UserShardMigrationCopying, V2UserShardMigrationVerifying, V2UserShardMigrationRetentionCleaning {
    private let source: any Database
    private let target: any Database
    private let sourceBucket: String
    private let targetBucket: String
    private let sourceSchema: String
    private let targetSchema: String
    private let pageSize: Int
    private let payloadPageSize: Int
    private let fenceLifetime: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        source: any Database,
        target: any Database,
        sourceBucket: String,
        targetBucket: String,
        sourceSchema: String = "im_v2",
        targetSchema: String = "im_v2",
        pageSize: Int = 1_000,
        fenceLifetime: TimeInterval = 120,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        let normalizedSource = sourceBucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTarget = targetBucket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSource.isEmpty, !normalizedTarget.isEmpty,
              normalizedSource != normalizedTarget,
              Self.validSchema(sourceSchema), Self.validSchema(targetSchema),
              (1 ... 1_000).contains(pageSize), fenceLifetime.isFinite, fenceLifetime >= 30
        else { throw V2UserShardProjectionTransferError.invalidConfiguration }
        self.source = source; self.target = target
        self.sourceBucket = normalizedSource; self.targetBucket = normalizedTarget
        self.sourceSchema = sourceSchema; self.targetSchema = targetSchema
        self.pageSize = pageSize
        // Projection/log/page payloads may each approach 64 KiB. Keep a
        // transfer batch bounded independently of the caller's row page size.
        payloadPageSize = min(pageSize, 64)
        self.fenceLifetime = fenceLifetime
        self.now = now
    }

    public func copy(_ record: V2UserShardMigrationRecord) async throws {
        try validate(record)
        guard let sourceSQL = source as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let userID = try projectionUUID(record.userID)
        try await acquireFence(database: source, schema: sourceSchema, userID: userID, token: record.migrationID)
        try await acquireFence(database: target, schema: targetSchema, userID: userID, token: record.migrationID)
        // The target is never the routed sync owner before cutover (and is the
        // retained fallback during rollback), so device capabilities can be
        // replaced exactly. This removes residue from an interrupted attempt.
        try await replaceTargetDeviceState(userID: userID, token: record.migrationID)

        try await copySequenceAndCheckpoint(sourceSQL: sourceSQL, userID: userID, token: record.migrationID)
        try await copyInbox(sourceSQL: sourceSQL, userID: userID, token: record.migrationID)
        // Shared states are immutable shard-local dependencies. Copy them
        // before either fan-out payloads or per-user projection references so
        // both foreign keys stay valid throughout the transfer.
        try await copyReferencedMessageStates(
            sourceSQL: sourceSQL, userID: userID, token: record.migrationID
        )
        try await copySyncLog(sourceSQL: sourceSQL, userID: userID, token: record.migrationID)
        try await copyProjectionEffects(sourceSQL: sourceSQL, userID: userID, token: record.migrationID)
        try await copyProjectionVersions(sourceSQL: sourceSQL, userID: userID, token: record.migrationID)
        try await copyArtifacts(sourceSQL: sourceSQL, userID: userID, token: record.migrationID)
        try await copyArtifactPages(sourceSQL: sourceSQL, userID: userID, token: record.migrationID)
        try await copyRevokedDeviceTombstones(
            sourceSQL: sourceSQL,
            userID: userID,
            token: record.migrationID
        )
        try await copyDeviceResets(sourceSQL: sourceSQL, userID: userID, token: record.migrationID)
        try await copyCursors(sourceSQL: sourceSQL, userID: userID, token: record.migrationID)
        try await copyTokens(sourceSQL: sourceSQL, userID: userID, token: record.migrationID)
        try await copyReceipts(sourceSQL: sourceSQL, userID: userID, token: record.migrationID)
    }

    public func fingerprints(for record: V2UserShardMigrationRecord) async throws -> (source: String, target: String) {
        try validate(record)
        guard let sourceSQL = source as? any SQLDatabase,
              let targetSQL = target as? any SQLDatabase
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let userID = try projectionUUID(record.userID)
        try await renewFences(userID: userID, token: record.migrationID)
        let sourceValue = try await fingerprint(
            sql: sourceSQL, schema: sourceSchema,
            userID: userID, token: record.migrationID
        )
        let targetValue = try await fingerprint(
            sql: targetSQL, schema: targetSchema,
            userID: userID, token: record.migrationID
        )
        // A source/target pair can be accidentally equal while source writes
        // race between the two scans. Re-read source and accept the pair only
        // when both endpoints and the source bookends are identical.
        let stableSourceValue = try await fingerprint(
            sql: sourceSQL, schema: sourceSchema,
            userID: userID, token: record.migrationID
        )
        let values = (
            source: stableSourceValue,
            target: sourceValue == stableSourceValue ? targetValue : "unstable:" + targetValue
        )
        // Copy/verification is the critical section. Workers must resume after
        // both immutable fingerprints have been captured; leaving a valid
        // fence behind would pause projection and reset publication until TTL.
        try await releaseFence(database: source, schema: sourceSchema, userID: userID, token: record.migrationID)
        try await releaseFence(database: target, schema: targetSchema, userID: userID, token: record.migrationID)
        return values
    }

    public func cleanSource(for record: V2UserShardMigrationRecord) async throws {
        try validate(record)
        let userID = try projectionUUID(record.userID)
        try await acquireFence(database: source, schema: sourceSchema, userID: userID, token: record.migrationID)
        guard let sql = source as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        // Child/lease tables first. Large histories are deleted in bounded
        // commits so retention cleanup cannot become one giant transaction.
        for (table, predicate) in [
            ("device_snapshot_resets", "user_id"),
            ("sync_tokens", "user_id"),
            ("sync_receipts", "user_id"),
            ("device_sync_cursors", "user_id"),
            ("revoked_device_projection_tombstones", "user_id"),
            ("user_projection_versions", "user_id"),
            ("user_projection_effects", "user_id"),
            ("consumer_inbox", "target_user_id"),
        ] {
            while try await deleteBounded(sql: sql, schema: sourceSchema, table: table, predicate: predicate, userID: userID) > 0 {
                try Task.checkCancellation()
                try await acquireFence(
                    database: source, schema: sourceSchema,
                    userID: userID, token: record.migrationID
                )
            }
        }
        while try await deleteSnapshotPages(
            sql: sql, schema: sourceSchema, userID: userID
        ) > 0 {
            try Task.checkCancellation()
            try await acquireFence(
                database: source, schema: sourceSchema,
                userID: userID, token: record.migrationID
            )
        }
        while try await deleteBounded(
            sql: sql, schema: sourceSchema,
            table: "sync_snapshot_artifacts", predicate: "user_id", userID: userID
        ) > 0 {
            try Task.checkCancellation()
            try await acquireFence(
                database: source, schema: sourceSchema,
                userID: userID, token: record.migrationID
            )
        }
        while try await deleteSyncLogBatch(
            sql: sql, schema: sourceSchema, userID: userID
        ) > 0 {
            try Task.checkCancellation()
            try await acquireFence(
                database: source, schema: sourceSchema,
                userID: userID, token: record.migrationID
            )
        }
        try await sql.raw("DELETE FROM \(unsafeRaw: sourceTable("user_projection_ready")) WHERE user_id = \(bind: userID)").run()
        try await sql.raw("DELETE FROM \(unsafeRaw: sourceTable("user_projection_checkpoints")) WHERE user_id = \(bind: userID)").run()
        try await sql.raw("DELETE FROM \(unsafeRaw: sourceTable("user_sync_retention")) WHERE user_id = \(bind: userID)").run()
        try await sql.raw("DELETE FROM \(unsafeRaw: sourceTable("user_sync_sequences")) WHERE user_id = \(bind: userID)").run()
    }

    // MARK: - Fencing

    private func acquireFence(database: any Database, schema: String, userID: UUID, token: UUID) async throws {
        let acquiredAt = try currentTimestamp()
        guard let expiresAt = v2PostgresFutureTimestamp(now: acquiredAt, interval: fenceLifetime) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: qualifiedTable("user_projection_checkpoints", schema: schema))
                    (user_id, projected_sequence, migration_fence_token,
                     migration_fence_expires_at, updated_at)
                VALUES (\(bind: userID), 0, \(bind: token), \(bind: expiresAt), \(bind: acquiredAt))
                ON CONFLICT (user_id) DO UPDATE SET
                    migration_fence_token = EXCLUDED.migration_fence_token,
                    migration_fence_expires_at = GREATEST(
                        \(unsafeRaw: qualifiedTable("user_projection_checkpoints", schema: schema)).migration_fence_expires_at,
                        EXCLUDED.migration_fence_expires_at
                    )
                WHERE \(unsafeRaw: qualifiedTable("user_projection_checkpoints", schema: schema)).migration_fence_token IS NULL
                   OR \(unsafeRaw: qualifiedTable("user_projection_checkpoints", schema: schema)).migration_fence_expires_at <= now()
                   OR \(unsafeRaw: qualifiedTable("user_projection_checkpoints", schema: schema)).migration_fence_token = EXCLUDED.migration_fence_token
                """).run()
            // Workers evaluate the fence against database time. A lagging
            // application clock must not authorize copying under a lease
            // those workers already consider expired.
            let fence = try await sql.raw("""
                SELECT migration_fence_token, migration_fence_expires_at,
                       COALESCE(migration_fence_expires_at > clock_timestamp(), FALSE) AS is_live
                FROM \(unsafeRaw: qualifiedTable("user_projection_checkpoints", schema: schema))
                WHERE user_id = \(bind: userID)
                FOR UPDATE
                """).first(decoding: ProjectionFenceRow.self)
            let observedAt = try currentTimestamp()
            guard let fence, let fenceExpiry = fence.expiresAt,
                  fence.token == token, fence.isLive, fenceExpiry > observedAt
            else { throw V2UserShardProjectionTransferError.migrationFenceConflict }
            // An in-flight builder will fail its lease check before appending;
            // a new builder observes the checkpoint fence and skips this user.
            try await sql.raw("""
                UPDATE \(unsafeRaw: qualifiedTable("sync_snapshot_artifacts", schema: schema))
                SET lease_token = NULL, lease_expires_at = NULL
                WHERE user_id = \(bind: userID) AND state = 'building'
                """).run()
        }
    }

    private func renewFences(userID: UUID, token: UUID) async throws {
        try await acquireFence(database: source, schema: sourceSchema, userID: userID, token: token)
        try await acquireFence(database: target, schema: targetSchema, userID: userID, token: token)
    }

    private func releaseFence(database: any Database, schema: String, userID: UUID, token: UUID) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        try await sql.raw("""
            UPDATE \(unsafeRaw: qualifiedTable("user_projection_checkpoints", schema: schema))
            SET migration_fence_token = NULL, migration_fence_expires_at = NULL
            WHERE user_id = \(bind: userID) AND migration_fence_token = \(bind: token)
            """).run()
    }

    // MARK: - Copy

    private func replaceTargetDeviceState(userID: UUID, token: UUID) async throws {
        guard let sql = target as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        // Projection workers are fenced on the target. Every potentially
        // large relation is reclaimed in bounded commits so an interrupted
        // transfer is retryable without a user-sized delete transaction.
        for table in [
            "device_snapshot_resets", "sync_tokens", "sync_receipts",
            "device_sync_cursors", "revoked_device_projection_tombstones",
        ] {
            try await deleteTargetRows(
                sql: sql, table: table, predicate: "user_id",
                userID: userID, token: token
            )
        }
        while try await deleteSnapshotPages(
            sql: sql, schema: targetSchema, userID: userID
        ) > 0 {
            try Task.checkCancellation()
            try await renewFences(userID: userID, token: token)
        }
        for table in [
            "sync_snapshot_artifacts", "user_projection_versions",
            "user_projection_effects",
        ] {
            try await deleteTargetRows(
                sql: sql, table: table, predicate: "user_id",
                userID: userID, token: token
            )
        }
        try await deleteTargetRows(
            sql: sql, table: "consumer_inbox", predicate: "target_user_id",
            userID: userID, token: token
        )
        while try await deleteSyncLogBatch(
            sql: sql, schema: targetSchema, userID: userID
        ) > 0 {
            try Task.checkCancellation()
            try await renewFences(userID: userID, token: token)
        }
        try await sql.raw("DELETE FROM \(unsafeRaw: targetTable("user_sync_retention")) WHERE user_id = \(bind: userID)").run()
        try await sql.raw("DELETE FROM \(unsafeRaw: targetTable("user_sync_sequences")) WHERE user_id = \(bind: userID)").run()
        try await renewFences(userID: userID, token: token)
    }

    private func deleteTargetRows(
        sql: any SQLDatabase,
        table: String,
        predicate: String,
        userID: UUID,
        token: UUID
    ) async throws {
        while try await deleteBounded(
            sql: sql, schema: targetSchema, table: table,
            predicate: predicate, userID: userID
        ) > 0 {
            try Task.checkCancellation()
            try await renewFences(userID: userID, token: token)
        }
    }

    private func deleteSnapshotPages(
        sql: any SQLDatabase,
        schema: String,
        userID: UUID
    ) async throws -> Int {
        try await sql.raw("""
            WITH candidates AS (
                SELECT page.ctid
                FROM \(unsafeRaw: qualifiedTable("sync_snapshot_pages", schema: schema)) AS page
                JOIN \(unsafeRaw: qualifiedTable("sync_snapshot_artifacts", schema: schema)) AS artifact
                  ON artifact.snapshot_id = page.snapshot_id
                WHERE artifact.user_id = \(bind: userID)
                ORDER BY page.snapshot_id, page.page_index
                LIMIT \(bind: payloadPageSize)
                FOR UPDATE OF page SKIP LOCKED
            )
            DELETE FROM \(unsafeRaw: qualifiedTable("sync_snapshot_pages", schema: schema)) AS page
            USING candidates WHERE page.ctid = candidates.ctid
            RETURNING 1 AS value
            """).all(decoding: ProjectionDeletedRow.self).count
    }

    private func deleteSyncLogBatch(
        sql: any SQLDatabase,
        schema: String,
        userID: UUID
    ) async throws -> Int {
        let row = try await sql.raw("""
            WITH candidates AS (
                SELECT ctid, source_event_id, projection_kind
                FROM \(unsafeRaw: qualifiedTable("user_sync_log", schema: schema))
                WHERE user_id = \(bind: userID)
                ORDER BY user_sync_sequence
                LIMIT \(bind: payloadPageSize)
                FOR UPDATE SKIP LOCKED
            ), removed AS (
                DELETE FROM \(unsafeRaw: qualifiedTable("user_sync_log", schema: schema)) AS log
                USING candidates WHERE log.ctid = candidates.ctid
                RETURNING candidates.source_event_id, candidates.projection_kind
            ), removed_keys AS (
                SELECT DISTINCT source_event_id, projection_kind FROM removed
            ), removed_payloads AS (
                DELETE FROM \(unsafeRaw: qualifiedTable("fanout_sync_payloads", schema: schema)) AS payload
                USING removed_keys
                WHERE payload.source_event_id = removed_keys.source_event_id
                  AND payload.projection_kind = removed_keys.projection_kind
                  AND NOT EXISTS (
                      SELECT 1 FROM \(unsafeRaw: qualifiedTable("user_sync_log", schema: schema)) AS remaining
                      WHERE remaining.source_event_id = payload.source_event_id
                        AND remaining.projection_kind = payload.projection_kind
                        AND remaining.payload_storage = 'fanout_shared'
                        AND NOT EXISTS (
                            SELECT 1 FROM candidates
                            WHERE candidates.ctid = remaining.ctid
                        )
                  )
                RETURNING 1
            )
            SELECT COUNT(*)::bigint AS value FROM removed
            """).first(decoding: ProjectionDeletedCountRow.self)
        return Int(row?.value ?? 0)
    }

    private func copySequenceAndCheckpoint(sourceSQL: any SQLDatabase, userID: UUID, token: UUID) async throws {
        let sequence = try await sourceSQL.raw("SELECT next_sequence FROM \(unsafeRaw: sourceTable("user_sync_sequences")) WHERE user_id = \(bind: userID)").first(decoding: ProjectionSequenceRow.self)
        let checkpoint = try await sourceSQL.raw("""
            SELECT projected_sequence, state, failure_count, failed_sequence,
                   next_attempt_at, last_failure_code, paused_at, updated_at
            FROM \(unsafeRaw: sourceTable("user_projection_checkpoints"))
            WHERE user_id = \(bind: userID)
            """).first(decoding: ProjectionCheckpointRow.self)
        let retention = try await sourceSQL.raw("""
            SELECT compacted_through_sequence, updated_at
            FROM \(unsafeRaw: sourceTable("user_sync_retention"))
            WHERE user_id = \(bind: userID)
            """).first(decoding: ProjectionRetentionRow.self)
        try await target.transaction { database in
            guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            if let sequence {
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: targetTable("user_sync_sequences")) (user_id, next_sequence)
                    VALUES (\(bind: userID), \(bind: sequence.nextSequence))
                    ON CONFLICT (user_id) DO UPDATE SET next_sequence = EXCLUDED.next_sequence
                    """).run()
            }
            if let checkpoint {
                try await sql.raw("""
                    UPDATE \(unsafeRaw: targetTable("user_projection_checkpoints"))
                    SET projected_sequence = \(bind: checkpoint.projectedSequence),
                        state = \(bind: checkpoint.state),
                        failure_count = \(bind: checkpoint.failureCount),
                        failed_sequence = \(bind: checkpoint.failedSequence),
                        next_attempt_at = \(bind: checkpoint.nextAttemptAt),
                        last_failure_code = \(bind: checkpoint.lastFailureCode),
                        paused_at = \(bind: checkpoint.pausedAt),
                        updated_at = \(bind: checkpoint.updatedAt)
                    WHERE user_id = \(bind: userID) AND migration_fence_token = \(bind: token)
                    """).run()
            }
            if let retention {
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: targetTable("user_sync_retention"))
                        (user_id, compacted_through_sequence, updated_at)
                    VALUES (\(bind: userID), \(bind: retention.compactedThroughSequence),
                            \(bind: retention.updatedAt))
                    ON CONFLICT (user_id) DO UPDATE SET
                        compacted_through_sequence = EXCLUDED.compacted_through_sequence,
                        updated_at = EXCLUDED.updated_at
                    """).run()
            }
            if let sequence, let checkpoint,
               checkpoint.state == "ready",
               checkpoint.projectedSequence < sequence.nextSequence {
                let updatedAt = try currentTimestamp()
                let availableAt = checkpoint.nextAttemptAt ?? checkpoint.updatedAt
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: targetTable("user_projection_ready"))
                        (user_id, available_at, enqueued_at, updated_at)
                    VALUES (\(bind: userID), \(bind: availableAt),
                            \(bind: checkpoint.updatedAt), \(bind: updatedAt))
                    ON CONFLICT (user_id) DO UPDATE
                    SET available_at = EXCLUDED.available_at,
                        enqueued_at = EXCLUDED.enqueued_at,
                        updated_at = EXCLUDED.updated_at
                    """).run()
            } else {
                try await sql.raw("""
                    DELETE FROM \(unsafeRaw: targetTable("user_projection_ready"))
                    WHERE user_id = \(bind: userID)
                    """).run()
            }
        }
        try await renewFences(userID: userID, token: token)
    }

    private func copyInbox(sourceSQL: any SQLDatabase, userID: UUID, token: UUID) async throws {
        var after: ProjectionInboxKey?
        while true {
            var query: SQLQueryString = "SELECT consumer_name, source_event_id, target_user_id, projection_kind, committed_at, user_sync_sequence FROM \(unsafeRaw: sourceTable("consumer_inbox")) WHERE target_user_id = \(bind: userID)"
            if let after { query += " AND (consumer_name, source_event_id, projection_kind) > (\(bind: after.consumerName), \(bind: after.sourceEventID), \(bind: after.projectionKind))" }
            query += " ORDER BY consumer_name, source_event_id, projection_kind LIMIT \(bind: pageSize)"
            let rows = try await sourceSQL.raw(query).all(decoding: ProjectionInboxRow.self)
            guard !rows.isEmpty else { return }
            try await insert(rows) { row in
                "(\(bind: row.consumerName), \(bind: row.sourceEventID), \(bind: row.targetUserID), \(bind: row.projectionKind), \(bind: row.committedAt), \(bind: row.userSyncSequence))"
            } prefix: {
                "INSERT INTO \(unsafeRaw: targetTable("consumer_inbox")) (consumer_name, source_event_id, target_user_id, projection_kind, committed_at, user_sync_sequence) VALUES "
            } suffix: { " ON CONFLICT (consumer_name, source_event_id, target_user_id, projection_kind) DO UPDATE SET committed_at = EXCLUDED.committed_at, user_sync_sequence = EXCLUDED.user_sync_sequence" }
            after = rows.last.map { .init(consumerName: $0.consumerName, sourceEventID: $0.sourceEventID, projectionKind: $0.projectionKind) }
            try await renewFences(userID: userID, token: token)
        }
    }

    private func copySyncLog(sourceSQL: any SQLDatabase, userID: UUID, token: UUID) async throws {
        var after: Int64 = 0
        while true {
            let rows = try await sourceSQL.raw("""
                SELECT log.user_sync_sequence, log.source_event_id, log.projection_kind,
                       CASE WHEN log.payload_storage = 'inline' THEN log.payload
                            ELSE COALESCE(shared.payload, state.payload) END::text AS payload_json,
                       shared.payload::text AS shared_payload_json,
                       log.payload_storage, shared.message_state_id, log.created_at, shared.created_at AS shared_created_at
                FROM \(unsafeRaw: sourceTable("user_sync_log")) AS log
                LEFT JOIN \(unsafeRaw: sourceTable("fanout_sync_payloads")) AS shared
                  ON shared.source_event_id = log.source_event_id
                 AND shared.projection_kind = log.projection_kind
                LEFT JOIN \(unsafeRaw: sourceTable("message_projection_state_values")) AS state
                  ON state.state_id = shared.message_state_id
                WHERE log.user_id = \(bind: userID) AND log.user_sync_sequence > \(bind: after)
                ORDER BY log.user_sync_sequence LIMIT \(bind: payloadPageSize)
                """).all(decoding: ProjectionSyncLogRow.self)
            guard !rows.isEmpty else { return }
            try await target.transaction { database in
                guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
                let shared = rows.filter { $0.payloadStorage == "fanout_shared" }
                if !shared.isEmpty {
                    var query: SQLQueryString = "INSERT INTO \(unsafeRaw: targetTable("fanout_sync_payloads")) (source_event_id, projection_kind, payload, message_state_id, created_at) VALUES "
                    query += shared.map { "(\(bind: $0.sourceEventID), \(bind: $0.projectionKind), \(bind: $0.sharedPayloadJSON)::jsonb, \(bind: $0.messageStateID), \(bind: $0.sharedCreatedAt))" }.joined(separator: ",")
                    query += " ON CONFLICT (source_event_id, projection_kind) DO UPDATE SET message_state_id = COALESCE(\(unsafeRaw: targetTable("fanout_sync_payloads")).message_state_id, EXCLUDED.message_state_id) WHERE \(unsafeRaw: targetTable("fanout_sync_payloads")).payload IS NOT DISTINCT FROM EXCLUDED.payload AND (\(unsafeRaw: targetTable("fanout_sync_payloads")).message_state_id IS NULL OR \(unsafeRaw: targetTable("fanout_sync_payloads")).message_state_id = EXCLUDED.message_state_id)"
                    try await sql.raw(query).run()
                }
                var query: SQLQueryString = "INSERT INTO \(unsafeRaw: targetTable("user_sync_log")) (user_id, user_sync_sequence, source_event_id, projection_kind, payload, payload_storage, created_at) VALUES "
                query += rows.map { "(\(bind: userID), \(bind: $0.sequence), \(bind: $0.sourceEventID), \(bind: $0.projectionKind), CASE WHEN \(bind: $0.payloadStorage) = 'inline' THEN \(bind: $0.payloadJSON)::jsonb ELSE NULL END, \(bind: $0.payloadStorage), \(bind: $0.createdAt))" }.joined(separator: ",")
                query += " ON CONFLICT DO NOTHING"
                try await sql.raw(query).run()
            }
            after = rows[rows.count - 1].sequence
            try await renewFences(userID: userID, token: token)
        }
    }

    private func copyReferencedMessageStates(
        sourceSQL: any SQLDatabase,
        userID: UUID,
        token: UUID
    ) async throws {
        var after: UUID?
        let targetRepository = PostgresV2MessageProjectionStateRepository(schema: targetSchema)
        while true {
            var query: SQLQueryString = """
                SELECT state.state_id, state.message_id, state.room_id,
                       state.message_revision, state.variant_key,
                       state.origin_event_id, state.state_event_id,
                       state.is_withdrawn, state.payload_schema_version,
                       state.payload::text AS payload_json, state.created_at
                FROM \(unsafeRaw: sourceTable("message_projection_state_values")) AS state
                WHERE (
                    EXISTS (
                        SELECT 1
                        FROM \(unsafeRaw: sourceTable("user_projection_versions")) AS version
                        WHERE version.user_id = \(bind: userID)
                          AND version.message_state_id = state.state_id
                    )
                    OR EXISTS (
                        SELECT 1
                        FROM \(unsafeRaw: sourceTable("fanout_sync_payloads")) AS shared
                        JOIN \(unsafeRaw: sourceTable("user_sync_log")) AS log
                          ON log.source_event_id = shared.source_event_id
                         AND log.projection_kind = shared.projection_kind
                        WHERE log.user_id = \(bind: userID)
                          AND shared.message_state_id = state.state_id
                    )
                )
                """
            if let after { query += " AND state.state_id > \(bind: after)" }
            query += " ORDER BY state.state_id LIMIT \(bind: payloadPageSize)"
            let rows = try await sourceSQL.raw(query)
                .all(decoding: ProjectionMessageStateRow.self)
            guard !rows.isEmpty else { return }
            try await target.transaction { database in
                guard let sql = database as? any SQLDatabase else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                for row in rows {
                    // `persist` is intentionally insert-and-verify: an
                    // interrupted migration can retry, while an immutable
                    // state collision stops the cutover.
                    try await targetRepository.persist(row.value, persistedCreatedAt: row.createdAt, sql: sql)
                }
            }
            after = rows.last?.stateID
            try await renewFences(userID: userID, token: token)
        }
    }

    private func copyProjectionEffects(sourceSQL: any SQLDatabase, userID: UUID, token: UUID) async throws {
        var after: ProjectionEffectKey?
        while true {
            var query: SQLQueryString = "SELECT source_event_id, projection_kind, user_sync_sequence, payload::text AS payload_json, created_at FROM \(unsafeRaw: sourceTable("user_projection_effects")) WHERE user_id = \(bind: userID)"
            if let after {
                query += " AND (source_event_id, projection_kind) > (\(bind: after.sourceEventID), \(bind: after.projectionKind))"
            }
            query += " ORDER BY source_event_id, projection_kind LIMIT \(bind: pageSize)"
            let rows = try await sourceSQL.raw(query).all(decoding: ProjectionEffectRow.self)
            guard !rows.isEmpty else { return }
            try await insert(rows) { row in
                "(\(bind: userID), \(bind: row.sourceEventID), \(bind: row.projectionKind), \(bind: row.sequence), \(bind: row.payloadJSON)::jsonb, \(bind: row.createdAt))"
            } prefix: {
                "INSERT INTO \(unsafeRaw: targetTable("user_projection_effects")) (user_id, source_event_id, projection_kind, user_sync_sequence, payload, created_at) VALUES "
            } suffix: {
                " ON CONFLICT (user_id, source_event_id, projection_kind) DO UPDATE SET user_sync_sequence = EXCLUDED.user_sync_sequence, payload = EXCLUDED.payload, created_at = EXCLUDED.created_at"
            }
            after = rows.last.map { .init(sourceEventID: $0.sourceEventID, projectionKind: $0.projectionKind) }
            try await renewFences(userID: userID, token: token)
        }
    }

    private func copyProjectionVersions(sourceSQL: any SQLDatabase, userID: UUID, token: UUID) async throws {
        var after: ProjectionVersionKey?
        while true {
            var query: SQLQueryString = "SELECT projection_kind, entity_key, scope_room_id, valid_from_sequence, valid_to_sequence, source_event_id, message_state_id, payload::text AS payload_json, created_at FROM \(unsafeRaw: sourceTable("user_projection_versions")) WHERE user_id = \(bind: userID)"
            if let after { query += " AND (projection_kind, entity_key, valid_from_sequence) > (\(bind: after.kind), \(bind: after.key), \(bind: after.sequence))" }
            query += " ORDER BY projection_kind, entity_key, valid_from_sequence LIMIT \(bind: payloadPageSize)"
            let rows = try await sourceSQL.raw(query).all(decoding: ProjectionVersionRow.self)
            guard !rows.isEmpty else { return }
            try await insert(rows) { row in
                "(\(bind: userID), \(bind: row.kind), \(bind: row.key), \(bind: row.roomID), \(bind: row.validFrom), \(bind: row.validTo), \(bind: row.sourceEventID), \(bind: row.messageStateID), \(bind: row.payloadJSON)::jsonb, \(bind: row.createdAt))"
            } prefix: {
                "INSERT INTO \(unsafeRaw: targetTable("user_projection_versions")) (user_id, projection_kind, entity_key, scope_room_id, valid_from_sequence, valid_to_sequence, source_event_id, message_state_id, payload, created_at) VALUES "
            } suffix: {
                " ON CONFLICT (user_id, projection_kind, entity_key, valid_from_sequence) DO UPDATE SET scope_room_id = EXCLUDED.scope_room_id, valid_to_sequence = EXCLUDED.valid_to_sequence, source_event_id = EXCLUDED.source_event_id, message_state_id = EXCLUDED.message_state_id, payload = EXCLUDED.payload, created_at = EXCLUDED.created_at"
            }
            after = rows.last.map { .init(kind: $0.kind, key: $0.key, sequence: $0.validFrom) }
            try await renewFences(userID: userID, token: token)
        }
    }

    private func copyArtifacts(sourceSQL: any SQLDatabase, userID: UUID, token: UUID) async throws {
        var after: UUID?
        while true {
            var query: SQLQueryString = "SELECT snapshot_id, user_id, base_user_sync_sequence, source_projected_sequence, schema_version, capability_profile, state, after_projection_kind, after_entity_key, next_page_index, rolling_digest, root_digest, page_count, item_count, total_bytes, expires_at, failure_code, created_at, published_at FROM \(unsafeRaw: sourceTable("sync_snapshot_artifacts")) WHERE user_id = \(bind: userID)"
            if let after { query += " AND snapshot_id > \(bind: after)" }
            query += " ORDER BY snapshot_id LIMIT \(bind: pageSize)"
            let rows = try await sourceSQL.raw(query).all(decoding: ProjectionArtifactRow.self)
            guard !rows.isEmpty else { return }
            try await insert(rows) { row in
                "(\(bind: row.snapshotID), \(bind: row.userID), \(bind: row.baseSequence), \(bind: row.projectedSequence), \(bind: row.schemaVersion), \(bind: row.capabilityProfile), \(bind: row.state), \(bind: row.afterKind), \(bind: row.afterKey), \(bind: row.nextPageIndex), \(bind: row.rollingDigest), \(bind: row.rootDigest), \(bind: row.pageCount), \(bind: row.itemCount), \(bind: row.totalBytes), NULL, NULL, \(bind: row.expiresAt), \(bind: row.failureCode), \(bind: row.createdAt), \(bind: row.publishedAt))"
            } prefix: {
                "INSERT INTO \(unsafeRaw: targetTable("sync_snapshot_artifacts")) (snapshot_id, user_id, base_user_sync_sequence, source_projected_sequence, schema_version, capability_profile, state, after_projection_kind, after_entity_key, next_page_index, rolling_digest, root_digest, page_count, item_count, total_bytes, lease_token, lease_expires_at, expires_at, failure_code, created_at, published_at) VALUES "
            } suffix: {
                " ON CONFLICT (snapshot_id) DO UPDATE SET user_id = EXCLUDED.user_id, base_user_sync_sequence = EXCLUDED.base_user_sync_sequence, source_projected_sequence = EXCLUDED.source_projected_sequence, schema_version = EXCLUDED.schema_version, capability_profile = EXCLUDED.capability_profile, state = EXCLUDED.state, after_projection_kind = EXCLUDED.after_projection_kind, after_entity_key = EXCLUDED.after_entity_key, next_page_index = EXCLUDED.next_page_index, rolling_digest = EXCLUDED.rolling_digest, root_digest = EXCLUDED.root_digest, page_count = EXCLUDED.page_count, item_count = EXCLUDED.item_count, total_bytes = EXCLUDED.total_bytes, lease_token = NULL, lease_expires_at = NULL, expires_at = EXCLUDED.expires_at, failure_code = EXCLUDED.failure_code, created_at = EXCLUDED.created_at, published_at = EXCLUDED.published_at"
            }
            after = rows.last?.snapshotID
            try await renewFences(userID: userID, token: token)
        }
    }

    private func copyArtifactPages(sourceSQL: any SQLDatabase, userID: UUID, token: UUID) async throws {
        var after: ProjectionPageKey?
        while true {
            var query: SQLQueryString = "SELECT page.snapshot_id, page.page_index, page.first_projection_kind, page.first_entity_key, page.last_projection_kind, page.last_entity_key, page.item_count, page.page_digest, page.payload, page.byte_count FROM \(unsafeRaw: sourceTable("sync_snapshot_pages")) AS page JOIN \(unsafeRaw: sourceTable("sync_snapshot_artifacts")) AS artifact ON artifact.snapshot_id = page.snapshot_id WHERE artifact.user_id = \(bind: userID)"
            if let after { query += " AND (page.snapshot_id, page.page_index) > (\(bind: after.snapshotID), \(bind: after.index))" }
            query += " ORDER BY page.snapshot_id, page.page_index LIMIT \(bind: payloadPageSize)"
            let rows = try await sourceSQL.raw(query).all(decoding: ProjectionPageRow.self)
            guard !rows.isEmpty else { return }
            try await insert(rows) { row in
                "(\(bind: row.snapshotID), \(bind: row.index), \(bind: row.firstKind), \(bind: row.firstKey), \(bind: row.lastKind), \(bind: row.lastKey), \(bind: row.itemCount), \(bind: row.digest), \(bind: row.payload), \(bind: row.byteCount))"
            } prefix: {
                "INSERT INTO \(unsafeRaw: targetTable("sync_snapshot_pages")) (snapshot_id, page_index, first_projection_kind, first_entity_key, last_projection_kind, last_entity_key, item_count, page_digest, payload, byte_count) VALUES "
            } suffix: { " ON CONFLICT (snapshot_id, page_index) DO NOTHING" }
            after = rows.last.map { .init(snapshotID: $0.snapshotID, index: $0.index) }
            try await renewFences(userID: userID, token: token)
        }
    }

    private func copyDeviceResets(sourceSQL: any SQLDatabase, userID: UUID, token: UUID) async throws {
        var after: ProjectionResetKey?
        while true {
            var query: SQLQueryString = "SELECT user_id, device_id, reset_generation, snapshot_id, state, next_sync_token, snapshot_receipt, expires_at, created_at, acknowledged_at FROM \(unsafeRaw: sourceTable("device_snapshot_resets")) WHERE user_id = \(bind: userID)"
            if let after { query += " AND (device_id, reset_generation) > (\(bind: after.deviceID), \(bind: after.generation))" }
            query += " ORDER BY device_id, reset_generation LIMIT \(bind: pageSize)"
            let rows = try await sourceSQL.raw(query).all(decoding: ProjectionResetRow.self)
            guard !rows.isEmpty else { return }
            try await insert(rows) { row in
                "(\(bind: row.userID), \(bind: row.deviceID), \(bind: row.generation), \(bind: row.snapshotID), \(bind: row.state), \(bind: row.nextToken), \(bind: row.receipt), \(bind: row.expiresAt), \(bind: row.createdAt), \(bind: row.acknowledgedAt))"
            } prefix: {
                "INSERT INTO \(unsafeRaw: targetTable("device_snapshot_resets")) (user_id, device_id, reset_generation, snapshot_id, state, next_sync_token, snapshot_receipt, expires_at, created_at, acknowledged_at) VALUES "
            } suffix: { " ON CONFLICT (user_id, device_id, reset_generation) DO UPDATE SET snapshot_id = EXCLUDED.snapshot_id, state = EXCLUDED.state, next_sync_token = EXCLUDED.next_sync_token, snapshot_receipt = EXCLUDED.snapshot_receipt, expires_at = EXCLUDED.expires_at, created_at = EXCLUDED.created_at, acknowledged_at = EXCLUDED.acknowledged_at" }
            after = rows.last.map { .init(deviceID: $0.deviceID, generation: $0.generation) }
            try await renewFences(userID: userID, token: token)
        }
    }

    private func copyRevokedDeviceTombstones(
        sourceSQL: any SQLDatabase,
        userID: UUID,
        token: UUID
    ) async throws {
        var after: UUID?
        while true {
            var query: SQLQueryString = "SELECT user_id, device_id, revoked_at FROM \(unsafeRaw: sourceTable("revoked_device_projection_tombstones")) WHERE user_id = \(bind: userID)"
            if let after { query += " AND device_id > \(bind: after)" }
            query += " ORDER BY device_id LIMIT \(bind: pageSize)"
            let rows = try await sourceSQL.raw(query)
                .all(decoding: ProjectionRevokedDeviceTombstoneRow.self)
            guard !rows.isEmpty else { return }
            try await insert(rows) { row in
                "(\(bind: row.userID), \(bind: row.deviceID), \(bind: row.revokedAt))"
            } prefix: {
                "INSERT INTO \(unsafeRaw: targetTable("revoked_device_projection_tombstones")) AS tombstone (user_id, device_id, revoked_at) VALUES "
            } suffix: {
                " ON CONFLICT (user_id, device_id) DO UPDATE SET revoked_at = LEAST(tombstone.revoked_at, EXCLUDED.revoked_at)"
            }
            after = rows.last?.deviceID
            try await renewFences(userID: userID, token: token)
        }
    }

    private func copyCursors(sourceSQL: any SQLDatabase, userID: UUID, token: UUID) async throws {
        var after: UUID?
        while true {
            var query: SQLQueryString = "SELECT user_id, device_id, state, reset_generation, acknowledged_sequence, pending_snapshot_id, pending_base_sequence, pending_snapshot_expires_at, completed_snapshot_id, completed_snapshot_ack_receipt, completed_snapshot_generation, completed_snapshot_base_sequence FROM \(unsafeRaw: sourceTable("device_sync_cursors")) WHERE user_id = \(bind: userID)"
            if let after { query += " AND device_id > \(bind: after)" }
            query += " ORDER BY device_id LIMIT \(bind: pageSize)"
            let rows = try await sourceSQL.raw(query).all(decoding: ProjectionCursorRow.self)
            guard !rows.isEmpty else { return }
            try await insert(rows) { row in
                "(\(bind: row.userID), \(bind: row.deviceID), \(bind: row.state), \(bind: row.generation), \(bind: row.acknowledgedSequence), \(bind: row.pendingSnapshotID), \(bind: row.pendingBaseSequence), \(bind: row.pendingExpiresAt), \(bind: row.completedSnapshotID), \(bind: row.completedReceipt), \(bind: row.completedGeneration), \(bind: row.completedBaseSequence))"
            } prefix: {
                "INSERT INTO \(unsafeRaw: targetTable("device_sync_cursors")) (user_id, device_id, state, reset_generation, acknowledged_sequence, pending_snapshot_id, pending_base_sequence, pending_snapshot_expires_at, completed_snapshot_id, completed_snapshot_ack_receipt, completed_snapshot_generation, completed_snapshot_base_sequence) VALUES "
            } suffix: { " ON CONFLICT (user_id, device_id) DO UPDATE SET state = EXCLUDED.state, reset_generation = EXCLUDED.reset_generation, acknowledged_sequence = EXCLUDED.acknowledged_sequence, pending_snapshot_id = EXCLUDED.pending_snapshot_id, pending_base_sequence = EXCLUDED.pending_base_sequence, pending_snapshot_expires_at = EXCLUDED.pending_snapshot_expires_at, completed_snapshot_id = EXCLUDED.completed_snapshot_id, completed_snapshot_ack_receipt = EXCLUDED.completed_snapshot_ack_receipt, completed_snapshot_generation = EXCLUDED.completed_snapshot_generation, completed_snapshot_base_sequence = EXCLUDED.completed_snapshot_base_sequence" }
            after = rows.last?.deviceID
            try await renewFences(userID: userID, token: token)
        }
    }

    private func copyTokens(sourceSQL: any SQLDatabase, userID: UUID, token: UUID) async throws {
        try await copyStringKeyRows(sourceSQL: sourceSQL, userID: userID, token: token, table: "sync_tokens", identity: "token", decode: ProjectionTokenRow.self) { rows in
            try await insert(rows) { row in "(\(bind: row.token), \(bind: row.userID), \(bind: row.deviceID), \(bind: row.generation), \(bind: row.watermark), \(bind: row.expiresAt), \(bind: row.createdAt))" } prefix: { "INSERT INTO \(unsafeRaw: targetTable("sync_tokens")) (token, user_id, device_id, reset_generation, watermark, expires_at, created_at) VALUES " } suffix: { " ON CONFLICT (token) DO NOTHING" }
        }
    }

    private func copyReceipts(sourceSQL: any SQLDatabase, userID: UUID, token: UUID) async throws {
        try await copyStringKeyRows(sourceSQL: sourceSQL, userID: userID, token: token, table: "sync_receipts", identity: "receipt", decode: ProjectionReceiptRow.self) { rows in
            try await insert(rows) { row in "(\(bind: row.receipt), \(bind: row.userID), \(bind: row.deviceID), \(bind: row.generation), \(bind: row.firstSequence), \(bind: row.lastSequence), \(bind: row.expiresAt), \(bind: row.createdAt))" } prefix: { "INSERT INTO \(unsafeRaw: targetTable("sync_receipts")) (receipt, user_id, device_id, reset_generation, first_sequence, last_sequence, expires_at, created_at) VALUES " } suffix: { " ON CONFLICT (receipt) DO NOTHING" }
        }
    }

    private func copyStringKeyRows<Row: ProjectionStringKeyedRow>(sourceSQL: any SQLDatabase, userID: UUID, token: UUID, table: String, identity: String, decode: Row.Type, write: ([Row]) async throws -> Void) async throws {
        var after: String?
        while true {
            var query: SQLQueryString = "SELECT * FROM \(unsafeRaw: sourceTable(table)) WHERE user_id = \(bind: userID)"
            if let after { query += " AND \(unsafeRaw: identity) > \(bind: after)" }
            query += " ORDER BY \(unsafeRaw: identity) LIMIT \(bind: pageSize)"
            let rows = try await sourceSQL.raw(query).all(decoding: Row.self)
            guard !rows.isEmpty else { return }
            try await write(rows)
            after = rows.last?.stringKey
            try await renewFences(userID: userID, token: token)
        }
    }

    private func insert<Row>(_ rows: [Row], value: (Row) -> SQLQueryString, prefix: () -> SQLQueryString, suffix: () -> SQLQueryString) async throws {
        guard let sql = target as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        var query = prefix()
        query += rows.map(value).joined(separator: ",")
        query += suffix()
        // One INSERT statement is already atomic; wrapping it in a separate
        // transaction would only hold a pooled connection around no extra work.
        try await sql.raw(query).run()
    }

    // MARK: - Fingerprint

    private func fingerprint(
        sql: any SQLDatabase,
        schema: String,
        userID: UUID,
        token: UUID
    ) async throws -> String {
        // Forwarding may apply the same record at different local times.
        // Inbox/log/checkpoint processing timestamps are copied faithfully,
        // but do not determine equality of canonical data and sync deadlines.
        var hasher = SHA256(); var hasLine = false
        func append(_ line: String) {
            if hasLine { hasher.update(data: Data([0x0A])) }
            hasher.update(data: Data(line.utf8)); hasLine = true
        }
        if let row = try await sql.raw("SELECT next_sequence FROM \(unsafeRaw: qualifiedTable("user_sync_sequences", schema: schema)) WHERE user_id = \(bind: userID)").first(decoding: ProjectionSequenceRow.self) { append("sequence|\(row.nextSequence)") }
        if let row = try await sql.raw("""
            SELECT projected_sequence, state, failure_count, failed_sequence,
                   next_attempt_at, last_failure_code, paused_at, updated_at
            FROM \(unsafeRaw: qualifiedTable("user_projection_checkpoints", schema: schema))
            WHERE user_id = \(bind: userID)
            """).first(decoding: ProjectionCheckpointRow.self) { append(row.line) }
        if let row = try await sql.raw("""
            SELECT compacted_through_sequence, updated_at
            FROM \(unsafeRaw: qualifiedTable("user_sync_retention", schema: schema))
            WHERE user_id = \(bind: userID)
            """).first(decoding: ProjectionRetentionRow.self) { append(row.line) }
        let renew: () async throws -> Void = {
            try await renewFences(userID: userID, token: token)
        }
        try await renew()
        try await fingerprintInbox(sql: sql, schema: schema, userID: userID, renew: renew, append: append)
        try await fingerprintLog(sql: sql, schema: schema, userID: userID, renew: renew, append: append)
        try await fingerprintProjectionEffects(sql: sql, schema: schema, userID: userID, renew: renew, append: append)
        try await fingerprintVersions(sql: sql, schema: schema, userID: userID, renew: renew, append: append)
        try await fingerprintArtifacts(sql: sql, schema: schema, userID: userID, renew: renew, append: append)
        try await fingerprintPages(sql: sql, schema: schema, userID: userID, renew: renew, append: append)
        try await fingerprintRevokedDeviceTombstones(
            sql: sql, schema: schema, userID: userID,
            renew: renew, append: append
        )
        try await fingerprintResets(sql: sql, schema: schema, userID: userID, renew: renew, append: append)
        try await fingerprintCursors(sql: sql, schema: schema, userID: userID, renew: renew, append: append)
        try await fingerprintTokens(sql: sql, schema: schema, userID: userID, renew: renew, append: append)
        try await fingerprintReceipts(sql: sql, schema: schema, userID: userID, renew: renew, append: append)
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func fingerprintInbox(sql: any SQLDatabase, schema: String, userID: UUID, renew: () async throws -> Void, append: (String) -> Void) async throws {
        var after: ProjectionInboxKey?
        while true {
            var query: SQLQueryString = "SELECT consumer_name, source_event_id, target_user_id, projection_kind, committed_at, user_sync_sequence FROM \(unsafeRaw: qualifiedTable("consumer_inbox", schema: schema)) WHERE target_user_id = \(bind: userID)"
            if let after { query += " AND (consumer_name, source_event_id, projection_kind) > (\(bind: after.consumerName), \(bind: after.sourceEventID), \(bind: after.projectionKind))" }
            query += " ORDER BY consumer_name, source_event_id, projection_kind LIMIT \(bind: pageSize)"
            let rows = try await sql.raw(query).all(decoding: ProjectionInboxRow.self); guard !rows.isEmpty else { return }
            rows.forEach { append($0.line) }; after = rows.last.map { .init(consumerName: $0.consumerName, sourceEventID: $0.sourceEventID, projectionKind: $0.projectionKind) }
            try await renew()
        }
    }

    private func fingerprintLog(sql: any SQLDatabase, schema: String, userID: UUID, renew: () async throws -> Void, append: (String) -> Void) async throws {
        var after: Int64 = 0
        while true {
            let rows = try await sql.raw("SELECT log.user_sync_sequence, log.source_event_id, log.projection_kind, CASE WHEN log.payload_storage = 'inline' THEN log.payload ELSE COALESCE(shared.payload, state.payload) END::text AS payload_json, shared.payload::text AS shared_payload_json, log.payload_storage, shared.message_state_id, log.created_at, shared.created_at AS shared_created_at FROM \(unsafeRaw: qualifiedTable("user_sync_log", schema: schema)) AS log LEFT JOIN \(unsafeRaw: qualifiedTable("fanout_sync_payloads", schema: schema)) AS shared ON shared.source_event_id = log.source_event_id AND shared.projection_kind = log.projection_kind LEFT JOIN \(unsafeRaw: qualifiedTable("message_projection_state_values", schema: schema)) AS state ON state.state_id = shared.message_state_id WHERE log.user_id = \(bind: userID) AND log.user_sync_sequence > \(bind: after) ORDER BY log.user_sync_sequence LIMIT \(bind: payloadPageSize)").all(decoding: ProjectionSyncLogRow.self)
            guard !rows.isEmpty else { return }; rows.forEach { append($0.line) }; after = rows[rows.count - 1].sequence
            try await renew()
        }
    }

    private func fingerprintProjectionEffects(sql: any SQLDatabase, schema: String, userID: UUID, renew: () async throws -> Void, append: (String) -> Void) async throws {
        var after: ProjectionEffectKey?
        while true {
            var query: SQLQueryString = "SELECT source_event_id, projection_kind, user_sync_sequence, payload::text AS payload_json, created_at FROM \(unsafeRaw: qualifiedTable("user_projection_effects", schema: schema)) WHERE user_id = \(bind: userID)"
            if let after {
                query += " AND (source_event_id, projection_kind) > (\(bind: after.sourceEventID), \(bind: after.projectionKind))"
            }
            query += " ORDER BY source_event_id, projection_kind LIMIT \(bind: pageSize)"
            let rows = try await sql.raw(query).all(decoding: ProjectionEffectRow.self)
            guard !rows.isEmpty else { return }
            rows.forEach { append($0.line) }
            after = rows.last.map { .init(sourceEventID: $0.sourceEventID, projectionKind: $0.projectionKind) }
            try await renew()
        }
    }

    private func fingerprintVersions(sql: any SQLDatabase, schema: String, userID: UUID, renew: () async throws -> Void, append: (String) -> Void) async throws {
        var after: ProjectionVersionKey?
        while true {
            var query: SQLQueryString = "SELECT version.projection_kind, version.entity_key, version.scope_room_id, version.valid_from_sequence, version.valid_to_sequence, version.source_event_id, version.message_state_id, COALESCE(state.payload, version.payload)::text AS payload_json, version.created_at FROM \(unsafeRaw: qualifiedTable("user_projection_versions", schema: schema)) AS version LEFT JOIN \(unsafeRaw: qualifiedTable("message_projection_state_values", schema: schema)) AS state ON state.state_id = version.message_state_id WHERE version.user_id = \(bind: userID)"
            if let after { query += " AND (version.projection_kind, version.entity_key, version.valid_from_sequence) > (\(bind: after.kind), \(bind: after.key), \(bind: after.sequence))" }
            query += " ORDER BY version.projection_kind, version.entity_key, version.valid_from_sequence LIMIT \(bind: payloadPageSize)"
            let rows = try await sql.raw(query).all(decoding: ProjectionVersionRow.self); guard !rows.isEmpty else { return }
            rows.forEach { append($0.line) }; after = rows.last.map { .init(kind: $0.kind, key: $0.key, sequence: $0.validFrom) }
            try await renew()
        }
    }

    private func fingerprintArtifacts(sql: any SQLDatabase, schema: String, userID: UUID, renew: () async throws -> Void, append: (String) -> Void) async throws {
        var after: UUID?
        while true {
            var query: SQLQueryString = "SELECT snapshot_id, user_id, base_user_sync_sequence, source_projected_sequence, schema_version, capability_profile, state, after_projection_kind, after_entity_key, next_page_index, rolling_digest, root_digest, page_count, item_count, total_bytes, expires_at, failure_code, created_at, published_at FROM \(unsafeRaw: qualifiedTable("sync_snapshot_artifacts", schema: schema)) WHERE user_id = \(bind: userID)"
            if let after { query += " AND snapshot_id > \(bind: after)" }; query += " ORDER BY snapshot_id LIMIT \(bind: pageSize)"
            let rows = try await sql.raw(query).all(decoding: ProjectionArtifactRow.self); guard !rows.isEmpty else { return }
            rows.forEach { append($0.line) }; after = rows.last?.snapshotID
            try await renew()
        }
    }

    private func fingerprintPages(sql: any SQLDatabase, schema: String, userID: UUID, renew: () async throws -> Void, append: (String) -> Void) async throws {
        var after: ProjectionPageKey?
        while true {
            var query: SQLQueryString = "SELECT page.snapshot_id, page.page_index, page.first_projection_kind, page.first_entity_key, page.last_projection_kind, page.last_entity_key, page.item_count, page.page_digest, page.payload, page.byte_count FROM \(unsafeRaw: qualifiedTable("sync_snapshot_pages", schema: schema)) AS page JOIN \(unsafeRaw: qualifiedTable("sync_snapshot_artifacts", schema: schema)) AS artifact ON artifact.snapshot_id = page.snapshot_id WHERE artifact.user_id = \(bind: userID)"
            if let after { query += " AND (page.snapshot_id, page.page_index) > (\(bind: after.snapshotID), \(bind: after.index))" }; query += " ORDER BY page.snapshot_id, page.page_index LIMIT \(bind: payloadPageSize)"
            let rows = try await sql.raw(query).all(decoding: ProjectionPageRow.self); guard !rows.isEmpty else { return }
            rows.forEach { append($0.line) }; after = rows.last.map { .init(snapshotID: $0.snapshotID, index: $0.index) }
            try await renew()
        }
    }

    private func fingerprintResets(sql: any SQLDatabase, schema: String, userID: UUID, renew: () async throws -> Void, append: (String) -> Void) async throws {
        var after: ProjectionResetKey?
        while true {
            var query: SQLQueryString = "SELECT user_id, device_id, reset_generation, snapshot_id, state, next_sync_token, snapshot_receipt, expires_at, created_at, acknowledged_at FROM \(unsafeRaw: qualifiedTable("device_snapshot_resets", schema: schema)) WHERE user_id = \(bind: userID)"
            if let after { query += " AND (device_id, reset_generation) > (\(bind: after.deviceID), \(bind: after.generation))" }
            query += " ORDER BY device_id, reset_generation LIMIT \(bind: pageSize)"
            let rows = try await sql.raw(query).all(decoding: ProjectionResetRow.self)
            guard !rows.isEmpty else { return }
            rows.forEach { append($0.line) }
            after = rows.last.map { .init(deviceID: $0.deviceID, generation: $0.generation) }
            try await renew()
        }
    }

    private func fingerprintRevokedDeviceTombstones(
        sql: any SQLDatabase,
        schema: String,
        userID: UUID,
        renew: () async throws -> Void,
        append: (String) -> Void
    ) async throws {
        var after: UUID?
        while true {
            var query: SQLQueryString = "SELECT user_id, device_id, revoked_at FROM \(unsafeRaw: qualifiedTable("revoked_device_projection_tombstones", schema: schema)) WHERE user_id = \(bind: userID)"
            if let after { query += " AND device_id > \(bind: after)" }
            query += " ORDER BY device_id LIMIT \(bind: pageSize)"
            let rows = try await sql.raw(query)
                .all(decoding: ProjectionRevokedDeviceTombstoneRow.self)
            guard !rows.isEmpty else { return }
            rows.forEach { append($0.line) }
            after = rows.last?.deviceID
            try await renew()
        }
    }

    private func fingerprintCursors(sql: any SQLDatabase, schema: String, userID: UUID, renew: () async throws -> Void, append: (String) -> Void) async throws {
        var after: UUID?
        while true {
            var query: SQLQueryString = "SELECT user_id, device_id, state, reset_generation, acknowledged_sequence, pending_snapshot_id, pending_base_sequence, pending_snapshot_expires_at, completed_snapshot_id, completed_snapshot_ack_receipt, completed_snapshot_generation, completed_snapshot_base_sequence FROM \(unsafeRaw: qualifiedTable("device_sync_cursors", schema: schema)) WHERE user_id = \(bind: userID)"
            if let after { query += " AND device_id > \(bind: after)" }
            query += " ORDER BY device_id LIMIT \(bind: pageSize)"
            let rows = try await sql.raw(query).all(decoding: ProjectionCursorRow.self)
            guard !rows.isEmpty else { return }
            rows.forEach { append($0.line) }
            after = rows.last?.deviceID
            try await renew()
        }
    }

    private func fingerprintTokens(sql: any SQLDatabase, schema: String, userID: UUID, renew: () async throws -> Void, append: (String) -> Void) async throws {
        try await fingerprintStringRows(
            sql: sql, schema: schema, table: "sync_tokens", userID: userID,
            type: ProjectionTokenRow.self, renew: renew, append: append
        )
    }

    private func fingerprintReceipts(sql: any SQLDatabase, schema: String, userID: UUID, renew: () async throws -> Void, append: (String) -> Void) async throws {
        try await fingerprintStringRows(
            sql: sql, schema: schema, table: "sync_receipts", userID: userID,
            type: ProjectionReceiptRow.self, renew: renew, append: append
        )
    }

    private func fingerprintStringRows<Row: ProjectionStringKeyedRow>(
        sql: any SQLDatabase,
        schema: String,
        table: String,
        userID: UUID,
        type: Row.Type,
        renew: () async throws -> Void,
        append: (String) -> Void
    ) async throws {
        var after: String?
        while true {
            var query: SQLQueryString = "SELECT * FROM \(unsafeRaw: qualifiedTable(table, schema: schema)) WHERE user_id = \(bind: userID)"
            if let after { query += " AND \(unsafeRaw: table == "sync_tokens" ? "token" : "receipt") > \(bind: after)" }
            query += " ORDER BY \(unsafeRaw: table == "sync_tokens" ? "token" : "receipt") LIMIT \(bind: pageSize)"
            let rows = try await sql.raw(query).all(decoding: Row.self)
            guard !rows.isEmpty else { return }
            rows.forEach { append($0.line) }
            after = rows.last?.stringKey
            try await renew()
        }
    }

    private func deleteBounded(sql: any SQLDatabase, schema: String, table: String, predicate: String, userID: UUID) async throws -> Int {
        try await sql.raw("""
            WITH candidates AS (
                SELECT ctid FROM \(unsafeRaw: qualifiedTable(table, schema: schema))
                WHERE \(unsafeRaw: predicate) = \(bind: userID)
                LIMIT \(bind: pageSize) FOR UPDATE SKIP LOCKED
            )
            DELETE FROM \(unsafeRaw: qualifiedTable(table, schema: schema)) AS target
            USING candidates WHERE target.ctid = candidates.ctid
            RETURNING 1 AS value
            """).all(decoding: ProjectionDeletedRow.self).count
    }

    private func validate(_ record: V2UserShardMigrationRecord) throws {
        guard record.sourceBucket == sourceBucket, record.targetBucket == targetBucket else {
            throw V2UserShardProjectionTransferError.routeMismatch
        }
    }
    private func currentTimestamp() throws -> Date {
        let value = now()
        guard v2PostgresTimestampCanEncode(value) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return value
    }

    private func sourceTable(_ name: String) -> String { "\(sourceSchema).\(name)" }
    private func targetTable(_ name: String) -> String { "\(targetSchema).\(name)" }
    private func qualifiedTable(_ name: String, schema: String) -> String { "\(schema).\(name)" }
    private static func validSchema(_ value: String) -> Bool { value.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }
}

public enum V2UserShardProjectionTransferError: Error, Equatable, Sendable {
    case invalidConfiguration
    case routeMismatch
    case migrationFenceConflict
}

private protocol ProjectionFingerprintRow: Decodable { var line: String { get } }
private protocol ProjectionStringKeyedRow: ProjectionFingerprintRow { var stringKey: String { get } }
private struct ProjectionFenceRow: Decodable {
    let token: UUID?
    let expiresAt: Date?
    let isLive: Bool
    enum CodingKeys: String, CodingKey {
        case token = "migration_fence_token", expiresAt = "migration_fence_expires_at", isLive = "is_live"
    }
}
private struct ProjectionSequenceRow: Decodable { let nextSequence: Int64; enum CodingKeys: String, CodingKey { case nextSequence = "next_sequence" } }
private struct ProjectionRetentionRow: Decodable {
    let compactedThroughSequence: Int64
    let updatedAt: V2PostgresTimestamp
    enum CodingKeys: String, CodingKey {
        case compactedThroughSequence = "compacted_through_sequence"
        case updatedAt = "updated_at"
    }
    var line: String { "retention|\(compactedThroughSequence)" }
}
private struct ProjectionCheckpointRow: Decodable {
    let projectedSequence: Int64
    let state: String
    let failureCount: Int64
    let failedSequence: Int64?
    let nextAttemptAt: V2PostgresTimestamp?
    let lastFailureCode: String?
    let pausedAt: V2PostgresTimestamp?
    let updatedAt: V2PostgresTimestamp
    enum CodingKeys: String, CodingKey {
        case projectedSequence = "projected_sequence", state
        case failureCount = "failure_count", failedSequence = "failed_sequence"
        case nextAttemptAt = "next_attempt_at", lastFailureCode = "last_failure_code"
        case pausedAt = "paused_at", updatedAt = "updated_at"
    }
    var line: String {
        "checkpoint|\(projectedSequence)|\(state)|\(failureCount)|\(projectionOptional(failedSequence))|\(projectionOptionalDate(nextAttemptAt))|\(projectionOptional(lastFailureCode))|\(projectionOptionalDate(pausedAt))"
    }
}
private struct ProjectionInboxKey { let consumerName: String; let sourceEventID: UUID; let projectionKind: String }
private struct ProjectionInboxRow: ProjectionFingerprintRow { let consumerName: String; let sourceEventID: UUID; let targetUserID: UUID; let projectionKind: String; let committedAt: V2PostgresTimestamp; let userSyncSequence: Int64?; enum CodingKeys: String, CodingKey { case consumerName = "consumer_name", sourceEventID = "source_event_id", targetUserID = "target_user_id", projectionKind = "projection_kind", committedAt = "committed_at", userSyncSequence = "user_sync_sequence" }; var line: String { "inbox|\(consumerName)|\(sourceEventID)|\(targetUserID)|\(projectionKind)|\(projectionOptional(userSyncSequence))" } }
private struct ProjectionSyncLogRow: ProjectionFingerprintRow {
    let sequence: Int64
    let sourceEventID: UUID
    let projectionKind: String
    let payloadJSON: String
    let sharedPayloadJSON: String?
    let sharedCreatedAt: V2PostgresTimestamp?
    let payloadStorage: String
    let messageStateID: UUID?
    let createdAt: V2PostgresTimestamp
    enum CodingKeys: String, CodingKey {
        case sequence = "user_sync_sequence", sourceEventID = "source_event_id"
        case projectionKind = "projection_kind", payloadJSON = "payload_json"
        case sharedPayloadJSON = "shared_payload_json"
        case sharedCreatedAt = "shared_created_at"
        case payloadStorage = "payload_storage", messageStateID = "message_state_id"
        case createdAt = "created_at"
    }
    var line: String {
        "log|\(sequence)|\(sourceEventID)|\(projectionKind)|\(projectionOptional(messageStateID))|\(payloadJSON)"
    }
}
private struct ProjectionEffectKey { let sourceEventID: UUID; let projectionKind: String }
private struct ProjectionEffectRow: ProjectionFingerprintRow { let sourceEventID: UUID; let projectionKind: String; let sequence: Int64; let payloadJSON: String; let createdAt: V2PostgresTimestamp; enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id", projectionKind = "projection_kind", sequence = "user_sync_sequence", payloadJSON = "payload_json", createdAt = "created_at" }; var line: String { "effect|\(sourceEventID)|\(projectionKind)|\(sequence)|\(payloadJSON)" } }
private struct ProjectionVersionKey { let kind: String; let key: String; let sequence: Int64 }
private struct ProjectionVersionRow: ProjectionFingerprintRow {
    let kind: String
    let key: String
    let roomID: UUID?
    let validFrom: Int64
    let validTo: Int64?
    let sourceEventID: UUID
    let messageStateID: UUID?
    let payloadJSON: String?
    let createdAt: V2PostgresTimestamp
    enum CodingKeys: String, CodingKey {
        case kind = "projection_kind", key = "entity_key", roomID = "scope_room_id"
        case validFrom = "valid_from_sequence", validTo = "valid_to_sequence"
        case sourceEventID = "source_event_id", messageStateID = "message_state_id"
        case payloadJSON = "payload_json", createdAt = "created_at"
    }
    var line: String {
        "version|\(kind)|\(key)|\(projectionOptional(roomID))|\(validFrom)|\(projectionOptional(validTo))|\(sourceEventID)|\(projectionOptional(messageStateID))|\(projectionOptional(payloadJSON))|\(projectionDate(createdAt))"
    }
}
private struct ProjectionMessageStateRow: Decodable {
    let stateID: UUID
    let messageID: UUID
    let roomID: UUID
    let messageRevision: Int64
    let variantKey: Int16
    let originEventID: UUID
    let stateEventID: UUID?
    let isWithdrawn: Bool
    let payloadSchemaVersion: Int16
    let payloadJSON: String
    let createdAt: V2PostgresTimestamp
    enum CodingKeys: String, CodingKey {
        case stateID = "state_id", messageID = "message_id", roomID = "room_id"
        case messageRevision = "message_revision", variantKey = "variant_key"
        case originEventID = "origin_event_id", stateEventID = "state_event_id"
        case isWithdrawn = "is_withdrawn", payloadSchemaVersion = "payload_schema_version"
        case payloadJSON = "payload_json", createdAt = "created_at"
    }
    var value: V2StoredMessageProjectionState {
        .init(
            stateID: stateID, messageID: messageID, roomID: roomID,
            messageRevision: messageRevision, variantKey: variantKey,
            originEventID: originEventID, stateEventID: stateEventID,
            isWithdrawn: isWithdrawn, payloadSchemaVersion: payloadSchemaVersion,
            payloadJSON: payloadJSON, createdAt: createdAt.date
        )
    }
}
private struct ProjectionArtifactRow: ProjectionFingerprintRow { let snapshotID: UUID; let userID: UUID; let baseSequence: Int64; let projectedSequence: Int64; let schemaVersion: Int32; let capabilityProfile: String; let state: String; let afterKind: String?; let afterKey: String?; let nextPageIndex: Int; let rollingDigest: String; let rootDigest: String?; let pageCount: Int?; let itemCount: Int64; let totalBytes: Int64; let expiresAt: V2PostgresTimestamp; let failureCode: String?; let createdAt: V2PostgresTimestamp; let publishedAt: V2PostgresTimestamp?; enum CodingKeys: String, CodingKey { case snapshotID = "snapshot_id", userID = "user_id", baseSequence = "base_user_sync_sequence", projectedSequence = "source_projected_sequence", schemaVersion = "schema_version", capabilityProfile = "capability_profile", state, afterKind = "after_projection_kind", afterKey = "after_entity_key", nextPageIndex = "next_page_index", rollingDigest = "rolling_digest", rootDigest = "root_digest", pageCount = "page_count", itemCount = "item_count", totalBytes = "total_bytes", expiresAt = "expires_at", failureCode = "failure_code", createdAt = "created_at", publishedAt = "published_at" }; var line: String { "artifact|\(snapshotID)|\(userID)|\(baseSequence)|\(projectedSequence)|\(schemaVersion)|\(capabilityProfile)|\(state)|\(projectionOptional(afterKind))|\(projectionOptional(afterKey))|\(nextPageIndex)|\(rollingDigest)|\(projectionOptional(rootDigest))|\(projectionOptional(pageCount))|\(itemCount)|\(totalBytes)|\(projectionDate(expiresAt))|\(projectionOptional(failureCode))|\(projectionDate(createdAt))|\(projectionOptionalDate(publishedAt))" } }
private struct ProjectionPageKey { let snapshotID: UUID; let index: Int }
private struct ProjectionPageRow: ProjectionFingerprintRow { let snapshotID: UUID; let index: Int; let firstKind: String; let firstKey: String; let lastKind: String; let lastKey: String; let itemCount: Int; let digest: String; let payload: Data; let byteCount: Int; enum CodingKeys: String, CodingKey { case snapshotID = "snapshot_id", index = "page_index", firstKind = "first_projection_kind", firstKey = "first_entity_key", lastKind = "last_projection_kind", lastKey = "last_entity_key", itemCount = "item_count", digest = "page_digest", payload, byteCount = "byte_count" }; var line: String { "page|\(snapshotID)|\(index)|\(firstKind)|\(firstKey)|\(lastKind)|\(lastKey)|\(itemCount)|\(digest)|\(payload.base64EncodedString())|\(byteCount)" } }
private struct ProjectionResetKey { let deviceID: UUID; let generation: Int64 }
private struct ProjectionRevokedDeviceTombstoneRow: ProjectionFingerprintRow {
    let userID: UUID
    let deviceID: UUID
    let revokedAt: V2PostgresTimestamp
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case deviceID = "device_id"
        case revokedAt = "revoked_at"
    }
    var line: String {
        "revoked-device|\(userID)|\(deviceID)|\(projectionDate(revokedAt))"
    }
}
private struct ProjectionResetRow: ProjectionFingerprintRow { let userID: UUID; let deviceID: UUID; let generation: Int64; let snapshotID: UUID; let state: String; let nextToken: String; let receipt: String; let expiresAt: V2PostgresTimestamp; let createdAt: V2PostgresTimestamp; let acknowledgedAt: V2PostgresTimestamp?; enum CodingKeys: String, CodingKey { case userID = "user_id", deviceID = "device_id", generation = "reset_generation", snapshotID = "snapshot_id", state, nextToken = "next_sync_token", receipt = "snapshot_receipt", expiresAt = "expires_at", createdAt = "created_at", acknowledgedAt = "acknowledged_at" }; var line: String { "reset|\(userID)|\(deviceID)|\(generation)|\(snapshotID)|\(state)|\(nextToken)|\(receipt)|\(projectionDate(expiresAt))|\(projectionDate(createdAt))|\(projectionOptionalDate(acknowledgedAt))" } }
private struct ProjectionCursorRow: ProjectionFingerprintRow { let userID: UUID; let deviceID: UUID; let state: String; let generation: Int64; let acknowledgedSequence: Int64; let pendingSnapshotID: UUID?; let pendingBaseSequence: Int64?; let pendingExpiresAt: V2PostgresTimestamp?; let completedSnapshotID: UUID?; let completedReceipt: String?; let completedGeneration: Int64?; let completedBaseSequence: Int64?; enum CodingKeys: String, CodingKey { case userID = "user_id", deviceID = "device_id", state, generation = "reset_generation", acknowledgedSequence = "acknowledged_sequence", pendingSnapshotID = "pending_snapshot_id", pendingBaseSequence = "pending_base_sequence", pendingExpiresAt = "pending_snapshot_expires_at", completedSnapshotID = "completed_snapshot_id", completedReceipt = "completed_snapshot_ack_receipt", completedGeneration = "completed_snapshot_generation", completedBaseSequence = "completed_snapshot_base_sequence" }; var line: String { "cursor|\(userID)|\(deviceID)|\(state)|\(generation)|\(acknowledgedSequence)|\(projectionOptional(pendingSnapshotID))|\(projectionOptional(pendingBaseSequence))|\(projectionOptionalDate(pendingExpiresAt))|\(projectionOptional(completedSnapshotID))|\(projectionOptional(completedReceipt))|\(projectionOptional(completedGeneration))|\(projectionOptional(completedBaseSequence))" } }
private struct ProjectionTokenRow: ProjectionStringKeyedRow { let token: String; let userID: UUID; let deviceID: UUID; let generation: Int64; let watermark: Int64; let expiresAt: V2PostgresTimestamp; let createdAt: V2PostgresTimestamp; enum CodingKeys: String, CodingKey { case token, userID = "user_id", deviceID = "device_id", generation = "reset_generation", watermark, expiresAt = "expires_at", createdAt = "created_at" }; var stringKey: String { token }; var line: String { "token|\(token)|\(userID)|\(deviceID)|\(generation)|\(watermark)|\(projectionDate(expiresAt))|\(projectionDate(createdAt))" } }
private struct ProjectionReceiptRow: ProjectionStringKeyedRow { let receipt: String; let userID: UUID; let deviceID: UUID; let generation: Int64; let firstSequence: Int64; let lastSequence: Int64; let expiresAt: V2PostgresTimestamp; let createdAt: V2PostgresTimestamp; enum CodingKeys: String, CodingKey { case receipt, userID = "user_id", deviceID = "device_id", generation = "reset_generation", firstSequence = "first_sequence", lastSequence = "last_sequence", expiresAt = "expires_at", createdAt = "created_at" }; var stringKey: String { receipt }; var line: String { "receipt|\(receipt)|\(userID)|\(deviceID)|\(generation)|\(firstSequence)|\(lastSequence)|\(projectionDate(expiresAt))|\(projectionDate(createdAt))" } }
private struct ProjectionDeletedRow: Decodable { let value: Int }
private struct ProjectionDeletedCountRow: Decodable { let value: Int64 }

private func projectionUUID(_ userID: UserID) throws -> UUID { guard let value = UUID(uuidString: userID.rawValue) else { throw V2RoomWriteStoreError.corruptPersistenceState }; return value }
private func projectionDate(_ value: V2PostgresTimestamp) -> String { String(value.microseconds) }
private func projectionOptional<T>(_ value: T?) -> String { value.map { String(describing: $0) } ?? "<nil>" }
private func projectionOptionalDate(_ value: V2PostgresTimestamp?) -> String { value.map(projectionDate) ?? "<nil>" }
