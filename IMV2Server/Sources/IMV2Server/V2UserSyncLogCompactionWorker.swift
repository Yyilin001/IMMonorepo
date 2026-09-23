import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 用户同步日志压缩报告。
public struct V2UserSyncLogCompactionReport: Equatable, Sendable {
    /// 本轮认领的用户数量。
    public let claimedUserCount: Int
    /// 删除的日志行数。
    public let deletedLogRowCount: Int

    /// 保存压缩统计。
    ///
    /// - Parameters:
    ///   - claimedUserCount: 认领用户数量。
    ///   - deletedLogRowCount: 删除日志行数。
    public init(
        claimedUserCount: Int,
        deletedLogRowCount: Int
    ) {
        self.claimedUserCount = claimedUserCount
        self.deletedLogRowCount = deletedLogRowCount
    }
    /// 本轮是否产生了实际删除。
    public var didWork: Bool {
        deletedLogRowCount > 0
    }
}

/// 在单个有界事务内推进一个用户的保留下限。
///
/// 选定的下限不会新于规范投影检查点，也不会新于任何有效的增量令牌或回执。
/// 设备恢复刻意采用惰性策略：拉取会在该保留行上串行，并且只有当处于低水位的活跃设备
/// 真正重连时才暂存共享检查点产物。
public struct PostgresV2UserSyncLogCompactionWorker: Sendable {
    private let database: any Database
    private let schema: String
    private let minimumLogAge: TimeInterval

    /// 校验并保存数据库、schema 与最短日志年龄。
    ///
    /// - Parameters:
    ///   - database: 存放用户同步日志的数据库。
    ///   - schema: 目标 schema，需符合 `^[A-Za-z_][A-Za-z0-9_]*$`。
    ///   - minimumLogAge: 日志在可被压缩前至少保留的秒数，需为正的有限值，默认 7 天。
    ///
    /// schema 名或最短年龄不满足约束时直接失败，避免越界压缩。
    public init(
        database: any Database,
        schema: String = "im_v2",
        minimumLogAge: TimeInterval = 7 * 86_400
    ) {
        precondition(minimumLogAge.isFinite && minimumLogAge > 0)
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.database = database
        self.schema = schema
        self.minimumLogAge = minimumLogAge
    }

    /// 执行一轮有界压缩。
    ///
    /// 认领用户后逐个推进保留下限并删除低于下限的日志；
    /// 每个用户都在独立的有界事务内处理，单个用户的失败不会阻塞其他用户。
    ///
    /// - Parameters:
    ///   - limit: 本轮最多处理的用户数。
    ///   - now: 本次判定的服务端时刻。
    /// - Returns: 本轮压缩统计。
    /// - Throws: 上限非正或持久化失败时抛出
    ///   ``V2UserSyncLogCompactionError``。
    public func runOnce(
        now: Date = Date(),
        userLimit: Int = 8,
        rowLimit: Int = 500
    ) async throws -> V2UserSyncLogCompactionReport {
        guard userLimit > 0, rowLimit > 0 else {
            throw V2UserSyncLogCompactionError.invalidLimit
        }
        guard let cutoff = v2PostgresPastTimestamp(now: now, interval: minimumLogAge) else {
            throw V2UserSyncLogCompactionError.corruptPersistence
        }
        var report = V2UserSyncLogCompactionReport(
            claimedUserCount: 0,
            deletedLogRowCount: 0
        )
        for _ in 0 ..< userLimit {
            try Task.checkCancellation()
            guard let pass = try await compactOne(now: now, cutoff: cutoff, rowLimit: rowLimit) else { break }
            report = .init(
                claimedUserCount: report.claimedUserCount + 1,
                deletedLogRowCount: report.deletedLogRowCount + pass.deletedLogRowCount
            )
        }
        return report
    }

    private func compactOne(now: Date, cutoff: Date, rowLimit: Int) async throws -> CompactionPass? {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2UserSyncLogCompactionError.corruptPersistence
            }
            guard let candidate = try await sql.raw("""
                SELECT checkpoint.user_id, checkpoint.projected_sequence,
                       retention.compacted_through_sequence
                FROM \(unsafeRaw: table("user_sync_retention")) AS retention
                JOIN \(unsafeRaw: table("user_projection_checkpoints")) AS checkpoint
                  ON checkpoint.user_id = retention.user_id
                WHERE checkpoint.state = 'ready'
                  AND (
                      checkpoint.projected_sequence >
                          retention.compacted_through_sequence
                      OR EXISTS (
                          SELECT 1 FROM \(unsafeRaw: table("user_sync_log")) AS prefix
                          WHERE prefix.user_id = checkpoint.user_id
                            AND prefix.user_sync_sequence <=
                                retention.compacted_through_sequence
                      )
                  )
                ORDER BY retention.updated_at, retention.user_id
                FOR UPDATE OF checkpoint, retention SKIP LOCKED
                LIMIT 1
                """).first(decoding: CompactionCandidateRow.self)
            else { return nil }

            // Current generation capabilities can still ask for their exact
            // old watermark. Keep the floor behind every unexpired one.
            let protected = try await sql.raw("""
                SELECT MIN(value) AS value
                FROM (
                    SELECT token.watermark AS value
                    FROM \(unsafeRaw: table("sync_tokens")) AS token
                    WHERE token.user_id = \(bind: candidate.userID)
                      AND token.expires_at > \(bind: now)
                    UNION ALL
                    -- An incremental receipt authorizes ACK of its inclusive
                    -- first sequence. Keep that row itself until the receipt
                    -- expires; only the prefix strictly before it is safe.
                    SELECT GREATEST(receipt.first_sequence - 1, 0)
                    FROM \(unsafeRaw: table("sync_receipts")) AS receipt
                    WHERE receipt.user_id = \(bind: candidate.userID)
                      AND receipt.expires_at > \(bind: now)
                ) AS capability
            """).first(decoding: OptionalCompactionFloorRow.self)?.value
            // Keep a durable replay window for higher-level operation workers
            // that may re-read a freshly appended effect before advancing
            // their own checkpoint. This also spans the default shard rollback
            // and capability lifetimes; compaction is still bounded by rate ×
            // window rather than total account age.
            let recentFloor = try await sql.raw("""
                SELECT MIN(user_sync_sequence) - 1 AS value
                FROM \(unsafeRaw: table("user_sync_log"))
                WHERE user_id = \(bind: candidate.userID)
                  AND created_at > \(bind: cutoff)
                """).first(decoding: OptionalCompactionFloorRow.self)?.value
            let safeFloor = min(
                candidate.projectedSequence,
                protected ?? candidate.projectedSequence,
                recentFloor ?? candidate.projectedSequence
            )
            let floor = max(candidate.compactedThroughSequence, safeFloor)
            guard floor > 0 else {
                // Move the row behind peers instead of reclaiming it in a hot
                // loop while a capability legitimately protects the prefix.
                try await sql.raw("""
                    UPDATE \(unsafeRaw: table("user_sync_retention"))
                    SET updated_at = \(bind: now)
                    WHERE user_id = \(bind: candidate.userID)
                    """).run()
                return .init()
            }

            // Publish the floor before deleting any prefix row. Pull takes a
            // shared lock on this row before reading incremental history, so it
            // either completes against the old floor or observes the new floor
            // and enters snapshot recovery. No maintenance pass scans a user's
            // unbounded historical device set.
            // A bounded pass may leave physical rows at/below the floor; they
            // are unreachable incremental history and a later pass reclaims
            // them without changing protocol state.
            if floor > candidate.compactedThroughSequence {
                try await sql.raw("""
                    UPDATE \(unsafeRaw: table("user_sync_retention"))
                    SET compacted_through_sequence = \(bind: floor),
                        updated_at = \(bind: now)
                    WHERE user_id = \(bind: candidate.userID)
                    """).run()
            }

            let deleted = try await sql.raw("""
                WITH candidates AS (
                    SELECT ctid
                    FROM \(unsafeRaw: table("user_sync_log"))
                    WHERE user_id = \(bind: candidate.userID)
                      AND user_sync_sequence <= \(bind: floor)
                    ORDER BY user_sync_sequence
                    LIMIT \(bind: rowLimit)
                    FOR UPDATE SKIP LOCKED
                )
                DELETE FROM \(unsafeRaw: table("user_sync_log")) AS log
                USING candidates
                WHERE log.ctid = candidates.ctid
                RETURNING 1 AS value
                """).all(decoding: CompactionExistsRow.self)
            return .init(deletedLogRowCount: deleted.count)
        }
    }

    private func table(_ name: String) -> String { "\(schema).\(name)" }
}

public enum V2UserSyncLogCompactionError: Error, Equatable, Sendable {
    case invalidLimit
    case corruptPersistence
}

private struct CompactionPass {
    let deletedLogRowCount: Int
    init(deletedLogRowCount: Int = 0) {
        self.deletedLogRowCount = deletedLogRowCount
    }
}
private struct CompactionCandidateRow: Decodable {
    let userID: UUID
    let projectedSequence: Int64
    let compactedThroughSequence: Int64
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case projectedSequence = "projected_sequence"
        case compactedThroughSequence = "compacted_through_sequence"
    }
}
private struct OptionalCompactionFloorRow: Decodable { let value: Int64? }
private struct CompactionExistsRow: Decodable { let value: Int }
