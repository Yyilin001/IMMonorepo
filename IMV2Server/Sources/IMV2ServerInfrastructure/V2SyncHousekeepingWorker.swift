import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 单个物理用户投影 schema 的有界过期清理实现。
///
/// 过期的暂存重置会先以未改变的确认水位恢复为就绪状态，
/// 因此清理过程绝不会让设备跳过尚未投递的记录。
public struct PostgresV2SyncHousekeepingStore: V2SyncHousekeepingStore {
    private let database: any Database
    private let schema: String

    /// 组合数据库与 schema。
    ///
    /// - Parameters:
    ///   - database: 存放同步令牌、回执与快照产物的数据库。
    ///   - schema: 目标 schema，默认 `im_v2`。
    public init(database: any Database, schema: String = "im_v2") {
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.database = database
        self.schema = schema
    }

    /// 清理过期同步状态并恢复暂存重置。
    ///
    /// - Parameters:
    ///   - now: 本次判定的服务端时刻。
    ///   - projectionEffectRetention: 投影效果记录的最短保留时长。
    ///   - limit: 本轮最多处理的数量。
    /// - Returns: 本轮维护统计。
    /// - Throws: 持久化失败时抛出。
    public func purgeExpired(
        now: Date,
        projectionEffectRetention: TimeInterval,
        limit: Int
    ) async throws -> V2SyncHousekeepingReport {
        guard limit > 0,
              projectionEffectRetention.isFinite,
              projectionEffectRetention >= V2IdempotencyPolicy.minimumServerRetention
        else { throw V2SyncHousekeepingError.invalidLimit }
        let effectCutoff = now.addingTimeInterval(-projectionEffectRetention)
        guard v2PostgresTimestampCanEncode(now), v2PostgresTimestampCanEncode(effectCutoff) else {
            throw V2SyncHousekeepingError.corruptPersistenceState
        }
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
            var resetCandidates = try await sql.raw("""
                SELECT snapshot_id
                FROM \(unsafeRaw: table("sync_snapshot_artifacts"))
                WHERE state IN ('building', 'published') AND expires_at <= \(bind: now)
                ORDER BY expires_at, snapshot_id
                LIMIT \(bind: limit)
                FOR UPDATE SKIP LOCKED
                """).all(decoding: SyncHousekeepingSnapshotRow.self).map(\.snapshotID)

            // 后来的设备可延长共享产物的存续期，而不延长较早设备的分配。
            // 在该设备自身的截止时间恢复它，同时为其他设备保留载荷。
            // 与构建器和过期产物路径一致，先锁定产物。
            let remaining = limit - resetCandidates.count
            if remaining > 0 {
                let sharedSnapshots = try await sql.raw("""
                    SELECT artifact.snapshot_id
                    FROM \(unsafeRaw: table("device_snapshot_resets")) AS reset
                    JOIN \(unsafeRaw: table("sync_snapshot_artifacts")) AS artifact
                      ON artifact.snapshot_id = reset.snapshot_id AND artifact.user_id = reset.user_id
                    WHERE reset.state IN ('preparing', 'ready') AND reset.expires_at <= \(bind: now)
                      AND artifact.state IN ('building', 'published') AND artifact.expires_at > \(bind: now)
                      AND EXISTS (
                          SELECT 1 FROM \(unsafeRaw: table("device_sync_cursors")) AS cursor
                          WHERE cursor.user_id = reset.user_id AND cursor.device_id = reset.device_id
                            AND cursor.reset_generation = reset.reset_generation
                            AND cursor.pending_snapshot_id = reset.snapshot_id
                            AND cursor.state IN ('reset_preparing', 'reset_pending')
                      )
                    ORDER BY reset.expires_at, reset.user_id, reset.device_id
                    LIMIT \(bind: remaining)
                    FOR UPDATE OF artifact SKIP LOCKED
                    """).all(decoding: SyncHousekeepingSnapshotRow.self).map(\.snapshotID)
                resetCandidates.append(contentsOf: sharedSnapshots)
            }

            var recovered = 0
            if !resetCandidates.isEmpty {
                let ids = resetCandidates.map { $0.uuidString.lowercased() }
                recovered = try await sql.raw("""
                    UPDATE \(unsafeRaw: table("device_sync_cursors")) AS cursor
                    SET state = 'ready', reset_generation = cursor.reset_generation - 1,
                        pending_snapshot_id = NULL,
                        pending_base_sequence = NULL, pending_snapshot_expires_at = NULL
                    FROM \(unsafeRaw: table("device_snapshot_resets")) AS reset
                    JOIN \(unsafeRaw: table("sync_snapshot_artifacts")) AS artifact
                      ON artifact.snapshot_id = reset.snapshot_id AND artifact.user_id = reset.user_id
                    WHERE reset.snapshot_id::text IN (SELECT jsonb_array_elements_text(\(bind: try json(ids))::jsonb))
                      AND reset.state IN ('preparing', 'ready')
                      AND (reset.expires_at <= \(bind: now) OR artifact.expires_at <= \(bind: now))
                      AND cursor.user_id = reset.user_id AND cursor.device_id = reset.device_id
                      AND cursor.reset_generation = reset.reset_generation
                      AND cursor.pending_snapshot_id = reset.snapshot_id
                      AND cursor.state IN ('reset_preparing', 'reset_pending')
                    RETURNING cursor.device_id
                    """).all(decoding: SyncHousekeepingDeviceRow.self).count
                try await sql.raw("""
                    DELETE FROM \(unsafeRaw: table("sync_tokens")) AS token
                    USING \(unsafeRaw: table("device_snapshot_resets")) AS reset
                    JOIN \(unsafeRaw: table("sync_snapshot_artifacts")) AS artifact
                      ON artifact.snapshot_id = reset.snapshot_id AND artifact.user_id = reset.user_id
                    WHERE reset.snapshot_id::text IN (SELECT jsonb_array_elements_text(\(bind: try json(ids))::jsonb))
                      AND reset.state IN ('preparing', 'ready')
                      AND (reset.expires_at <= \(bind: now) OR artifact.expires_at <= \(bind: now))
                      AND token.token = reset.next_sync_token
                      AND token.user_id = reset.user_id AND token.device_id = reset.device_id
                      AND token.reset_generation = reset.reset_generation
                    """).run()
                try await sql.raw("""
                    DELETE FROM \(unsafeRaw: table("device_snapshot_resets")) AS reset
                    USING \(unsafeRaw: table("sync_snapshot_artifacts")) AS artifact
                    WHERE artifact.snapshot_id = reset.snapshot_id AND artifact.user_id = reset.user_id
                      AND reset.snapshot_id::text IN (SELECT jsonb_array_elements_text(\(bind: try json(ids))::jsonb))
                      AND reset.state IN ('preparing', 'ready')
                      AND (reset.expires_at <= \(bind: now) OR artifact.expires_at <= \(bind: now))
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
            // 只有投影器已物化副作用，且增量重放不再保留源记录后，
            // 才能移除它。当前投影版本仍是权威。
            let projectionEffects = try await sql.raw("""
                WITH candidates AS (
                    SELECT effect.ctid
                    FROM \(unsafeRaw: table("user_projection_effects")) AS effect
                    JOIN \(unsafeRaw: table("user_projection_checkpoints")) AS checkpoint
                      ON checkpoint.user_id = effect.user_id
                     AND checkpoint.projected_sequence >= effect.user_sync_sequence
                    WHERE effect.created_at <= \(bind: effectCutoff)
                      AND NOT EXISTS (
                          SELECT 1 FROM \(unsafeRaw: table("user_sync_log")) AS log
                          WHERE log.user_id = effect.user_id
                            AND log.user_sync_sequence = effect.user_sync_sequence
                            AND log.source_event_id = effect.source_event_id
                            AND log.projection_kind = effect.projection_kind
                      )
                    ORDER BY effect.created_at, effect.user_id,
                             effect.user_sync_sequence, effect.source_event_id
                    LIMIT \(bind: limit)
                    FOR UPDATE OF effect SKIP LOCKED
                )
                DELETE FROM \(unsafeRaw: table("user_projection_effects")) AS effect
                USING candidates
                WHERE effect.ctid = candidates.ctid
                RETURNING 1 AS value
                """).all(decoding: SyncHousekeepingDeletedRow.self).count
            return .init(
                expiredTokenCount: tokens,
                expiredReceiptCount: receipts,
                recoveredResetCount: recovered,
                purgedSnapshotCount: purgeCandidates.count,
                purgedProjectionEffectCount: projectionEffects
            )
        }
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

private func json<T: Encodable>(_ values: T) throws -> String {
    let data = try JSONEncoder().encode(values)
    guard let value = String(data: data, encoding: .utf8) else {
        throw V2SyncHousekeepingError.corruptPersistenceState
    }
    return value
}
