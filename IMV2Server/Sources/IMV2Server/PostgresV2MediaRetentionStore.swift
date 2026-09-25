import FluentKit
import Foundation
import SQLKit

/// PostgreSQL 媒体保留的权威实现。
///
/// 元数据继续保留以支持消息与审计重放：这里只把对象置为终态并产生一条提供方清理任务。
/// 候选行使用 `SKIP LOCKED` 选取，因此多个工作器实例可安全并行。
public struct PostgresV2MediaRetentionStore: V2MediaRetentionStore {
    private let database: any Database

    /// 组合数据库。
    ///
    /// - Parameter database: 存放媒体对象、引用与清理发件箱的数据库。
    public init(database: any Database) {
        self.database = database
    }

    /// 使满足条件的媒体进入过期状态并登记清理任务。
    ///
    /// 判定条件为：对象尚未过期；不属于任何未收到回执的转发导出；不被待处理或已接受的
    /// 转发导入引用；并且要么自身已过期且没有任何消息引用，要么其全部消息引用都已超过
    /// 撤回保留期。候选行先加锁选取，再在 `READ COMMITTED` 的新语句中重新判定，
    /// 避免单条 CTE 的 MVCC 快照漏掉加锁期间提交的导出。
    ///
    /// - Parameters:
    ///   - now: 本次判定的服务端时刻。
    ///   - withdrawnRetention: 已撤回媒体在清理前保留的秒数，需大于零。
    ///   - limit: 本轮最多处理的媒体数，需大于零。
    /// - Returns: 实际标记过期的媒体数。
    /// - Throws: 参数非正或保留截止点不可编码时抛出
    ///   ``V2MediaRetentionStoreError/invalidRequest``；事务连接不支持 SQL 时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``。
    public func expireEligibleMedia(now: Date, withdrawnRetention: TimeInterval, limit: Int) async throws -> Int {
        guard limit > 0, withdrawnRetention > 0 else {
            throw V2MediaRetentionStoreError.invalidRequest
        }
        guard let withdrawnBefore = v2PostgresPastTimestamp(now: now, interval: withdrawnRetention) else {
            throw V2MediaRetentionStoreError.invalidRequest
        }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let eligible: SQLQueryString = """
                WHERE media.state <> 'expired'
                  AND NOT EXISTS (
                    SELECT 1 FROM im_v2.message_forward_exports AS export
                    WHERE export.media_ids @> ARRAY[media.media_id]
                      AND NOT EXISTS (SELECT 1 FROM im_v2.message_forward_export_receipts AS receipt
                                      WHERE receipt.export_id = export.export_id)
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM im_v2.message_forward_inbox_media AS imported
                    JOIN im_v2.message_forward_inbox AS inbox ON inbox.export_id = imported.export_id
                    WHERE imported.target_media_id = media.media_id AND inbox.state IN ('pending', 'accepted')
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM im_v2.message_forward_media_imports AS job
                    JOIN im_v2.message_forward_inbox AS inbox ON inbox.export_id = job.export_id
                    WHERE job.target_media_id = media.media_id AND job.state IN ('pending', 'claimed', 'paused')
                      AND inbox.state IN ('pending', 'accepted')
                  )
                  AND (
                    (
                      media.expires_at <= \(bind: now)
                      AND NOT EXISTS (
                        SELECT 1 FROM im_v2.message_media_references AS reference
                        WHERE reference.media_id = media.media_id
                      )
                    )
                    OR (
                      EXISTS (
                        SELECT 1 FROM im_v2.message_media_references AS reference
                        WHERE reference.media_id = media.media_id
                      )
                      AND NOT EXISTS (
                        SELECT 1
                        FROM im_v2.message_media_references AS reference
                        JOIN im_v2.messages AS message ON message.message_id = reference.message_id
                        WHERE reference.media_id = media.media_id
                          AND (message.withdrawn_at IS NULL OR message.withdrawn_at > \(bind: withdrawnBefore))
                      )
                    )
                  )
                """
            // 先锁定有界的候选集合，再用新的 READ COMMITTED 语句复查。
            // 单个 CTE 只有一份 MVCC 快照：如果导出在快照建立后、
            // 行锁获取前提交，即使随后释放行锁，单次查询仍可能看不到该导出。
            let locked = try await sql.raw("""
                SELECT media.media_id FROM im_v2.media_objects AS media
                \(eligible)
                ORDER BY media.created_at, media.media_id
                FOR UPDATE SKIP LOCKED
                LIMIT \(bind: limit)
                """).all(decoding: MediaPurgedRow.self)
            guard !locked.isEmpty else { return 0 }
            let mediaJSON = String(decoding: try JSONEncoder().encode(locked.map(\.mediaID)), as: UTF8.self)
            let rows = try await sql.raw("""
                WITH candidates AS (
                    SELECT media.media_id,
                           CASE WHEN NOT EXISTS (
                               SELECT 1 FROM im_v2.message_media_references AS reference
                               WHERE reference.media_id = media.media_id
                           ) THEN 'unreferenced_expired' ELSE 'withdrawn_retention_elapsed' END AS reason
                    FROM im_v2.media_objects AS media
                    JOIN jsonb_array_elements_text(\(bind: mediaJSON)::jsonb) AS locked(media_id)
                      ON media.media_id = locked.media_id::uuid
                    \(eligible)
                ), expired AS (
                    UPDATE im_v2.media_objects AS media
                    SET state = 'expired', state_updated_at = \(bind: now)
                    FROM candidates
                    WHERE media.media_id = candidates.media_id
                    RETURNING media.media_id
                )
                INSERT INTO im_v2.media_purge_outbox (media_id, reason, state, created_at)
                SELECT candidates.media_id, candidates.reason, 'pending', \(bind: now)
                FROM candidates JOIN expired ON expired.media_id = candidates.media_id
                ON CONFLICT (media_id) DO NOTHING
                RETURNING media_id
                """).all(decoding: MediaPurgedRow.self)
            return rows.count
        }
    }
}

/// 媒体保留存储错误。
public enum V2MediaRetentionStoreError: Error, Equatable, Sendable {
    /// 请求参数不满足约束。
    case invalidRequest
}

private struct MediaPurgedRow: Decodable {
    let mediaID: UUID
    enum CodingKeys: String, CodingKey { case mediaID = "media_id" }
}
