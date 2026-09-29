import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import SQLKit

/// 回收终态收件箱的正文副本，同时保留身份、摘要和结果。
/// 七天是诊断宽限期，不是幂等性过期窗口。
public struct PostgresV2ForwardInboxCompactor: Sendable {
    public static let retentionSeconds: TimeInterval = 7 * 24 * 60 * 60
    private let database: any Database

    public init(database: any Database) { self.database = database }

    /// 原子执行一个有界批次；并发清理器跳过彼此锁定的记录。
    /// 待处理和已接受的收件箱保留正文，包括已暂停的导入。
    public func runOnce(now: Date = Date(), limit: Int = 128) async throws -> Int {
        guard (1...1_024).contains(limit) else { throw V2ForwardDeliveryError.invalidConfiguration }
        let cutoff = now.addingTimeInterval(-Self.retentionSeconds)
        guard v2PostgresTimestampCanEncode(now), v2PostgresTimestampCanEncode(cutoff),
              let sql = database as? any SQLDatabase else { throw V2ForwardInboxError.corruptPersistenceState }
        let rows = try await sql.raw("""
            WITH candidates AS (
                SELECT inbox.export_id FROM im_v2.message_forward_inbox AS inbox
                WHERE (SELECT true FROM im_v2.rooms AS room
                       WHERE room.room_id = inbox.target_room_id
                       FOR SHARE OF room SKIP LOCKED)
                  AND inbox.state IN ('completed', 'rejected') AND inbox.payload IS NOT NULL
                  AND inbox.completed_at <= \(bind: cutoff)
                ORDER BY inbox.completed_at, inbox.export_id LIMIT \(bind: limit) FOR UPDATE OF inbox SKIP LOCKED
            )
            UPDATE im_v2.message_forward_inbox AS inbox
            SET payload = NULL, payload_compacted_at = \(bind: now)
            FROM candidates WHERE inbox.export_id = candidates.export_id
            RETURNING inbox.export_id
            """).all()
        return rows.count
    }
}
