import IMV2ServerApplication
import IMV2ServerContracts
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

            // 当前代次的能力仍可请求其确切旧水位。
            // 压缩下界须落后于每份未过期能力所保护的水位。
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
            // 为上层操作工作器保留持久化重放窗口：它们在推进自身检查点前，
            // 可能重新读取刚追加的副作用。该窗口也覆盖默认分片回滚期
            // 和能力有效期；压缩规模仍受速率 × 窗口约束，
            // 而不随账号总存续时间增长。
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
                // 当能力合法地保护此前的日志时，将此行移到同类记录后面，
                // 不要在热循环中反复认领它。
                try await sql.raw("""
                    UPDATE \(unsafeRaw: table("user_sync_retention"))
                    SET updated_at = \(bind: now)
                    WHERE user_id = \(bind: candidate.userID)
                    """).run()
                return .init()
            }

            // 删除此前的任何日志行前，先发布压缩下界。拉取操作在读取增量历史前
            // 会对这一行获取共享锁，因此要么按旧下界完成，
            // 要么看到新下界并进入快照恢复。维护过程不扫描用户无界的历史设备集合。
            // 有界的一轮清理可能留下位于下界及其之前的物理记录；
            // 它们已无法作为增量历史访问，后续轮次可在不改变协议状态的前提下回收。
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
