import FluentKit
import Foundation
import SQLKit

/// 一次转发投递的租约。
public struct V2ForwardDeliveryLease: Sendable {
    /// 本次投递的不可变导出内容。
    public let export: V2ForwardExport
    /// 本次租约的认领令牌，后续完成、重排都必须携带。
    public let claimToken: UUID
    /// 本次是第几次尝试，从 1 开始。
    public let attempt: Int
    /// 租约到期时刻。
    public let expiresAt: Date
}

/// 持久化投递调度实现，与不可变的源端信封分离存放。
public struct PostgresV2ForwardDeliveryStore: Sendable {
    private let database: any Database
    /// 组合数据库。
    ///
    /// - Parameter database: 存放转发导出与投递任务的数据库。
    public init(database: any Database) { self.database = database }

    /// 查询指定导出的投递任务是否已被暂停。
    ///
    /// - Parameter exportID: 目标导出标识。
    /// - Returns: 任务处于暂停状态时为 `true`。
    /// - Throws: 连接不支持 SQL 时抛出
    ///   ``V2ForwardExportError/corruptPersistenceState``。
    public func isPaused(exportID: UUID) async throws -> Bool {
        guard let sql = database as? any SQLDatabase else { throw V2ForwardExportError.corruptPersistenceState }
        return try await sql.raw("SELECT EXISTS(SELECT 1 FROM im_v2.message_forward_delivery_jobs WHERE export_id = \(bind: exportID) AND state = 'paused') AS value").first(decoding: DeliveryBoolRow.self)?.value == true
    }

    /// 认领一批待投递或租约已过期的任务。
    ///
    /// 只有源分片标识与房间当前归属均匹配的导出才会被认领；候选行按下次尝试时间排序并使用
    /// `FOR UPDATE SKIP LOCKED` 选取，重试计数在事务内自增且不会溢出。
    ///
    /// - Parameters:
    ///   - sourceShardID: 源逻辑分片标识。
    ///   - now: 本次认领时刻。
    ///   - leaseDuration: 租约时长秒数，需大于零且不超过 3600。
    ///   - limit: 单批最多认领的任务数，需落在 `1...1024`。
    /// - Returns: 本批租约列表。
    /// - Throws: 参数越界时抛出 ``V2ForwardDeliveryError/invalidConfiguration``；
    ///   租约到期时刻不可编码、重试计数无法写入 `Int` 或导出载荷校验失败时抛出
    ///   ``V2ForwardExportError/corruptPersistenceState``。
    public func claim(sourceShardID: String, now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2ForwardDeliveryLease] {
        guard !sourceShardID.isEmpty, (1...1_024).contains(limit), leaseDuration.isFinite,
              leaseDuration > 0, leaseDuration <= 3_600 else { throw V2ForwardDeliveryError.invalidConfiguration }
        guard let expiresAt = v2PostgresFutureTimestamp(now: now, interval: leaseDuration) else {
            throw V2ForwardExportError.corruptPersistenceState
        }
        let token = UUID()
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ForwardExportError.corruptPersistenceState }
            let rows = try await sql.raw("""
                WITH candidates AS (
                    SELECT job.export_id FROM im_v2.message_forward_delivery_jobs AS job
                    JOIN im_v2.message_forward_exports AS export ON export.export_id = job.export_id
                    JOIN im_v2.rooms AS room ON room.room_id = export.source_room_id
                    WHERE export.source_shard_id = \(bind: sourceShardID)
                      AND room.room_shard_id = export.source_shard_id AND room.owner_epoch = export.source_epoch

                      AND ((job.state = 'pending' AND job.next_attempt_at <= \(bind: now))
                           OR (job.state = 'claimed' AND job.lease_expires_at <= \(bind: now)))
                    ORDER BY job.next_attempt_at NULLS FIRST, job.created_at, job.export_id
                    LIMIT \(bind: limit) FOR UPDATE OF job SKIP LOCKED FOR SHARE OF room SKIP LOCKED
                ), claimed AS (
                    UPDATE im_v2.message_forward_delivery_jobs AS job
                    SET state = 'claimed', claim_token = \(bind: token), lease_expires_at = \(bind: expiresAt),
                        next_attempt_at = NULL, retry_count = CASE WHEN retry_count = 9223372036854775807 THEN retry_count ELSE retry_count + 1 END
                    FROM candidates WHERE candidates.export_id = job.export_id
                    RETURNING job.export_id, job.retry_count
                )
                SELECT export.payload, export.payload_digest, claimed.retry_count
                FROM claimed JOIN im_v2.message_forward_exports AS export ON export.export_id = claimed.export_id
                """).all(decoding: DeliveryClaimRow.self)
            return try rows.map { row in
                guard let attempt = Int(exactly: row.attempt), attempt > 0 else { throw V2ForwardExportError.corruptPersistenceState }
                return try .init(export: .init(payload: row.payload, digest: row.digest), claimToken: token, attempt: attempt, expiresAt: expiresAt)
            }
        }
    }

    /// 判断租约是否仍然有效。
    ///
    /// - Parameters:
    ///   - lease: 本次投递租约。
    ///   - now: 判定时刻。
    /// - Returns: 任务仍是该令牌持有且未过期时为 `true`。
    /// - Throws: 时刻不可编码或连接不支持 SQL 时抛出
    ///   ``V2ForwardExportError/corruptPersistenceState``。
    public func isCurrent(_ lease: V2ForwardDeliveryLease, now: Date) async throws -> Bool {
        guard v2PostgresTimestampCanEncode(now) else { throw V2ForwardExportError.corruptPersistenceState }
        guard let sql = database as? any SQLDatabase else { throw V2ForwardExportError.corruptPersistenceState }
        return try await sql.raw("""
            SELECT EXISTS(SELECT 1 FROM im_v2.message_forward_delivery_jobs AS job
                JOIN im_v2.message_forward_exports AS export ON export.export_id = job.export_id
                JOIN im_v2.rooms AS room ON room.room_id = export.source_room_id
                WHERE room.room_shard_id = export.source_shard_id AND room.owner_epoch = export.source_epoch
                  AND job.export_id = \(bind: lease.export.intent.exportID) AND job.state = 'claimed'
                  AND job.claim_token = \(bind: lease.claimToken) AND job.lease_expires_at > \(bind: now)) AS value
            """).first(decoding: DeliveryBoolRow.self)?.value == true
    }

    /// 把租约标记为完成。
    ///
    /// 只有租约仍有效且已存在对应终态回执时才会迁移状态，避免在没有回执的情况下提前结束投递。
    ///
    /// - Parameters:
    ///   - lease: 本次投递租约。
    ///   - now: 完成时刻。
    /// - Returns: 状态实际发生迁移时为 `true`。
    /// - Throws: 时刻不可编码或连接不支持 SQL 时抛出
    ///   ``V2ForwardExportError/corruptPersistenceState``。
    public func complete(_ lease: V2ForwardDeliveryLease, now: Date) async throws -> Bool {
        guard v2PostgresTimestampCanEncode(now) else { throw V2ForwardExportError.corruptPersistenceState }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ForwardExportError.corruptPersistenceState }
            guard try await lockActiveSource(exportID: lease.export.intent.exportID, sql: sql) else { return false }
            return try await sql.raw("""
                UPDATE im_v2.message_forward_delivery_jobs AS job
                SET state = 'completed', claim_token = NULL, lease_expires_at = NULL,
                    next_attempt_at = NULL, completed_at = \(bind: now)
                WHERE job.export_id = \(bind: lease.export.intent.exportID) AND job.state = 'claimed'
                  AND job.claim_token = \(bind: lease.claimToken) AND job.lease_expires_at > \(bind: now)
                  AND EXISTS(SELECT 1 FROM im_v2.message_forward_export_receipts AS receipt WHERE receipt.export_id = job.export_id)
                RETURNING true AS value
                """).first(decoding: DeliveryBoolRow.self)?.value == true
        }
    }

    /// 按处置结果重排租约。
    ///
    /// 重试处置会把任务置回待处理并写入下次尝试时刻；暂停处置会清空下次尝试时刻。
    /// 两种情况下都会清空认领令牌与租约，只有当前有效租约才能重排成功。
    ///
    /// - Parameters:
    ///   - lease: 本次投递租约。
    ///   - disposition: 下一步处置，来自持久化重试策略。
    ///   - resetAttempts: 是否把重试计数清零。
    ///   - now: 重排时刻。
    /// - Returns: 状态实际发生迁移时为 `true`。
    /// - Throws: 时刻（含重试时刻）不可编码或连接不支持 SQL 时抛出
    ///   ``V2ForwardExportError/corruptPersistenceState``。
    public func reschedule(_ lease: V2ForwardDeliveryLease, disposition: V2DurableRetryDisposition,
                           resetAttempts: Bool = false, now: Date) async throws -> Bool {
        guard v2PostgresTimestampCanEncode(now) else { throw V2ForwardExportError.corruptPersistenceState }
        let state: String, retryAt: Date?
        switch disposition {
        case .retry(let at):
            guard v2PostgresTimestampCanEncode(at) else { throw V2ForwardExportError.corruptPersistenceState }
            state = "pending"; retryAt = at
        case .pause: state = "paused"; retryAt = nil
        }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ForwardExportError.corruptPersistenceState }
            guard try await lockActiveSource(exportID: lease.export.intent.exportID, sql: sql) else { return false }
            return try await sql.raw("""
                UPDATE im_v2.message_forward_delivery_jobs
                SET state = \(bind: state), next_attempt_at = \(bind: retryAt), claim_token = NULL, lease_expires_at = NULL,
                    retry_count = CASE WHEN \(bind: resetAttempts) THEN 0 ELSE retry_count END
                WHERE export_id = \(bind: lease.export.intent.exportID) AND state = 'claimed'
                  AND claim_token = \(bind: lease.claimToken) AND lease_expires_at > \(bind: now)
                RETURNING true AS value
                """).first(decoding: DeliveryBoolRow.self)?.value == true
        }
    }

    /// 更新任务期间保持当前源不变；导出绑定不可变。
    private func lockActiveSource(exportID: UUID, sql: any SQLDatabase) async throws -> Bool {
        try await sql.raw("""
            SELECT true AS value FROM im_v2.rooms AS room
            JOIN im_v2.message_forward_exports AS export ON export.source_room_id = room.room_id
            WHERE export.export_id = \(bind: exportID)
              AND room.room_shard_id = export.source_shard_id AND room.owner_epoch = export.source_epoch

            FOR SHARE OF room
            """).first(decoding: DeliveryBoolRow.self)?.value == true
    }

}

private struct DeliveryClaimRow: Decodable {
    let payload: Data; let digest: Data; let attempt: Int64
    enum CodingKeys: String, CodingKey { case payload; case digest = "payload_digest"; case attempt = "retry_count" }
}
private struct DeliveryBoolRow: Decodable { let value: Bool }
