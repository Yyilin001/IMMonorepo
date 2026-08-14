import Fluent
import Foundation
import SQLKit

public struct V2SyncHousekeepingReport: Equatable, Sendable {
    public let expiredTokenCount: Int
    public let expiredReceiptCount: Int
    public let recoveredResetCount: Int
    public let purgedRevokedDeviceCount: Int
    public let purgedSnapshotCount: Int

    public init(
        expiredTokenCount: Int,
        expiredReceiptCount: Int,
        recoveredResetCount: Int,
        purgedRevokedDeviceCount: Int = 0,
        purgedSnapshotCount: Int
    ) {
        self.expiredTokenCount = expiredTokenCount
        self.expiredReceiptCount = expiredReceiptCount
        self.recoveredResetCount = recoveredResetCount
        self.purgedRevokedDeviceCount = purgedRevokedDeviceCount
        self.purgedSnapshotCount = purgedSnapshotCount
    }

    public var didWork: Bool {
        expiredTokenCount > 0 || expiredReceiptCount > 0 ||
            recoveredResetCount > 0 || purgedRevokedDeviceCount > 0 ||
            purgedSnapshotCount > 0
    }
}

public protocol V2SyncHousekeepingStore: Sendable {
    func purgeExpired(now: Date, limit: Int) async throws -> V2SyncHousekeepingReport
}

public struct V2SyncHousekeepingWorker: Sendable {
    private let store: any V2SyncHousekeepingStore
    private let now: @Sendable () -> Date

    public init(
        store: any V2SyncHousekeepingStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2SyncHousekeepingReport {
        guard limit > 0 else { throw V2SyncHousekeepingError.invalidLimit }
        return try await store.purgeExpired(now: now(), limit: limit)
    }
}

public enum V2SyncHousekeepingError: Error, Equatable, Sendable {
    case invalidLimit
    case corruptPersistenceState
}

/// Bounded expiry cleanup for one physical user-projection schema. Expired
/// staged resets are first returned to `ready` at their unchanged ACK
/// watermark, so cleanup can never make a device skip an undelivered record.
public struct PostgresV2SyncHousekeepingStore: V2SyncHousekeepingStore {
    private let database: any Database
    private let schema: String

    public init(database: any Database, schema: String = "im_v2") {
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.database = database
        self.schema = schema
    }

    public func purgeExpired(now: Date, limit: Int) async throws -> V2SyncHousekeepingReport {
        guard limit > 0 else { throw V2SyncHousekeepingError.invalidLimit }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2SyncHousekeepingError.corruptPersistenceState
            }
            let tokens = try await deleteBounded(
                sql: sql,
                table: "sync_tokens",
                identity: "token",
                predicate: "expires_at <= ",
                now: now,
                limit: limit
            )
            let receipts = try await deleteBounded(
                sql: sql,
                table: "sync_receipts",
                identity: "receipt",
                predicate: "expires_at <= ",
                now: now,
                limit: limit
            )
            let revokedDevices = try await purgeRevokedDeviceState(
                sql: sql,
                now: now,
                limit: limit
            )

            let expiredSnapshots = try await sql.raw("""
                SELECT snapshot_id
                FROM \(unsafeRaw: table("sync_snapshot_artifacts"))
                WHERE state IN ('building', 'published') AND expires_at <= \(bind: now)
                  AND NOT EXISTS (
                      SELECT 1 FROM \(unsafeRaw: table("user_projection_checkpoints")) AS checkpoint
                      WHERE checkpoint.user_id = sync_snapshot_artifacts.user_id
                        AND checkpoint.migration_fence_expires_at > \(bind: now)
                  )
                ORDER BY expires_at, snapshot_id
                LIMIT \(bind: limit)
                FOR UPDATE SKIP LOCKED
                """).all(decoding: SyncHousekeepingSnapshotRow.self).map(\.snapshotID)

            var recovered = 0
            if !expiredSnapshots.isEmpty {
                let ids = expiredSnapshots.map { $0.uuidString.lowercased() }
                recovered = try await sql.raw("""
                    UPDATE \(unsafeRaw: table("device_sync_cursors")) AS cursor
                    SET state = 'ready', reset_generation = cursor.reset_generation - 1,
                        pending_snapshot_id = NULL,
                        pending_base_sequence = NULL, pending_snapshot_expires_at = NULL
                    WHERE cursor.state IN ('reset_preparing', 'reset_pending')
                      AND cursor.pending_snapshot_id::text IN (SELECT jsonb_array_elements_text(\(bind: try json(ids))::jsonb))
                    RETURNING cursor.device_id
                    """).all(decoding: SyncHousekeepingDeviceRow.self).count
                try await sql.raw("""
                    DELETE FROM \(unsafeRaw: table("sync_tokens")) AS token
                    USING \(unsafeRaw: table("device_snapshot_resets")) AS reset
                    WHERE reset.snapshot_id::text IN (SELECT jsonb_array_elements_text(\(bind: try json(ids))::jsonb))
                      AND reset.state IN ('preparing', 'ready') AND reset.expires_at <= \(bind: now)
                      AND token.token = reset.next_sync_token
                      AND token.user_id = reset.user_id AND token.device_id = reset.device_id
                      AND token.reset_generation = reset.reset_generation
                    """).run()
                try await sql.raw("""
                    DELETE FROM \(unsafeRaw: table("device_snapshot_resets"))
                    WHERE snapshot_id::text IN (SELECT jsonb_array_elements_text(\(bind: try json(ids))::jsonb))
                      AND state IN ('preparing', 'ready') AND expires_at <= \(bind: now)
                    """).run()
                try await sql.raw("""
                    UPDATE \(unsafeRaw: table("sync_snapshot_artifacts"))
                    SET state = 'expired', lease_token = NULL, lease_expires_at = NULL
                    WHERE snapshot_id::text IN (SELECT jsonb_array_elements_text(\(bind: try json(ids))::jsonb))
                      AND state IN ('building', 'published') AND expires_at <= \(bind: now)
                    """).run()
            }

            let purgeCandidates = try await sql.raw("""
                SELECT snapshot_id
                FROM \(unsafeRaw: table("sync_snapshot_artifacts")) AS artifact
                WHERE state IN ('expired', 'failed') AND expires_at <= \(bind: now)
                  AND NOT EXISTS (
                      SELECT 1 FROM \(unsafeRaw: table("user_projection_checkpoints")) AS checkpoint
                      WHERE checkpoint.user_id = artifact.user_id
                        AND checkpoint.migration_fence_expires_at > \(bind: now)
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM \(unsafeRaw: table("device_snapshot_resets")) AS reset
                      WHERE reset.snapshot_id = artifact.snapshot_id
                        AND reset.state IN ('preparing', 'ready')
                  )
                ORDER BY expires_at, snapshot_id
                LIMIT \(bind: limit)
                FOR UPDATE SKIP LOCKED
                """).all(decoding: SyncHousekeepingSnapshotRow.self).map(\.snapshotID)
            if !purgeCandidates.isEmpty {
                let ids = purgeCandidates.map { $0.uuidString.lowercased() }
                let encoded = try json(ids)
                try await sql.raw("""
                    DELETE FROM \(unsafeRaw: table("device_snapshot_resets"))
                    WHERE snapshot_id::text IN (SELECT jsonb_array_elements_text(\(bind: encoded)::jsonb))
                      AND state IN ('acknowledged', 'expired')
                    """).run()
                try await sql.raw("""
                    DELETE FROM \(unsafeRaw: table("sync_snapshot_artifacts"))
                    WHERE snapshot_id::text IN (SELECT jsonb_array_elements_text(\(bind: encoded)::jsonb))
                      AND state IN ('expired', 'failed') AND expires_at <= \(bind: now)
                    """).run()
            }
            return .init(
                expiredTokenCount: tokens,
                expiredReceiptCount: receipts,
                recoveredResetCount: recovered,
                purgedRevokedDeviceCount: revokedDevices,
                purgedSnapshotCount: purgeCandidates.count
            )
        }
    }

    /// Revoked device rows cannot authenticate again. Retaining their cursor,
    /// capabilities and reset assignments only makes compaction/metrics grow
    /// with account history. Delete the bounded batch in dependency order.
    private func purgeRevokedDeviceState(
        sql: any SQLDatabase,
        now: Date,
        limit: Int
    ) async throws -> Int {
        let candidates = try await sql.raw("""
            SELECT cursor.user_id, cursor.device_id
            FROM \(unsafeRaw: table("device_sync_cursors")) AS cursor
            JOIN \(unsafeRaw: table("auth_devices")) AS device
              ON device.user_id = cursor.user_id
             AND device.device_id = cursor.device_id
            WHERE device.revoked_at IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1 FROM \(unsafeRaw: table("user_projection_checkpoints")) AS checkpoint
                  WHERE checkpoint.user_id = cursor.user_id
                    AND checkpoint.migration_fence_expires_at > \(bind: now)
              )
            ORDER BY device.revoked_at, cursor.user_id, cursor.device_id
            LIMIT \(bind: limit)
            FOR UPDATE OF cursor SKIP LOCKED
            """).all(decoding: SyncHousekeepingRevokedDeviceRow.self)
        guard !candidates.isEmpty else { return 0 }
        let encoded = try json(candidates.map {
            ["user_id": $0.userID.uuidString.lowercased(),
             "device_id": $0.deviceID.uuidString.lowercased()]
        })
        try await sql.raw("""
            DELETE FROM \(unsafeRaw: table("sync_tokens")) AS target
            WHERE EXISTS (
                SELECT 1 FROM jsonb_to_recordset(\(bind: encoded)::jsonb)
                    AS candidate(user_id uuid, device_id uuid)
                WHERE candidate.user_id = target.user_id
                  AND candidate.device_id = target.device_id
            )
            """).run()
        try await sql.raw("""
            DELETE FROM \(unsafeRaw: table("sync_receipts")) AS target
            WHERE EXISTS (
                SELECT 1 FROM jsonb_to_recordset(\(bind: encoded)::jsonb)
                    AS candidate(user_id uuid, device_id uuid)
                WHERE candidate.user_id = target.user_id
                  AND candidate.device_id = target.device_id
            )
            """).run()
        try await sql.raw("""
            DELETE FROM \(unsafeRaw: table("device_snapshot_resets")) AS target
            WHERE EXISTS (
                SELECT 1 FROM jsonb_to_recordset(\(bind: encoded)::jsonb)
                    AS candidate(user_id uuid, device_id uuid)
                WHERE candidate.user_id = target.user_id
                  AND candidate.device_id = target.device_id
            )
            """).run()
        try await sql.raw("""
            DELETE FROM \(unsafeRaw: table("device_sync_cursors")) AS target
            WHERE EXISTS (
                SELECT 1 FROM jsonb_to_recordset(\(bind: encoded)::jsonb)
                    AS candidate(user_id uuid, device_id uuid)
                WHERE candidate.user_id = target.user_id
                  AND candidate.device_id = target.device_id
            )
            """).run()
        return candidates.count
    }

    private func deleteBounded(
        sql: any SQLDatabase,
        table name: String,
        identity: String,
        predicate: String,
        now: Date,
        limit: Int
    ) async throws -> Int {
        try await sql.raw("""
            WITH candidates AS (
                SELECT \(unsafeRaw: identity)
                FROM \(unsafeRaw: table(name))
                WHERE \(unsafeRaw: predicate)\(bind: now)
                ORDER BY expires_at, \(unsafeRaw: identity)
                LIMIT \(bind: limit)
                FOR UPDATE SKIP LOCKED
            )
            DELETE FROM \(unsafeRaw: table(name)) AS target
            USING candidates
            WHERE target.\(unsafeRaw: identity) = candidates.\(unsafeRaw: identity)
            RETURNING 1 AS value
            """).all(decoding: SyncHousekeepingDeletedRow.self).count
    }

    private func table(_ name: String) -> String { "\(schema).\(name)" }
}

private struct SyncHousekeepingSnapshotRow: Decodable {
    let snapshotID: UUID
    enum CodingKeys: String, CodingKey { case snapshotID = "snapshot_id" }
}
private struct SyncHousekeepingDeviceRow: Decodable {
    let deviceID: UUID
    enum CodingKeys: String, CodingKey { case deviceID = "device_id" }
}
private struct SyncHousekeepingDeletedRow: Decodable { let value: Int }
private struct SyncHousekeepingRevokedDeviceRow: Decodable {
    let userID: UUID
    let deviceID: UUID
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case deviceID = "device_id"
    }
}

private func json<T: Encodable>(_ values: T) throws -> String {
    let data = try JSONEncoder().encode(values)
    guard let value = String(data: data, encoding: .utf8) else {
        throw V2SyncHousekeepingError.corruptPersistenceState
    }
    return value
}
