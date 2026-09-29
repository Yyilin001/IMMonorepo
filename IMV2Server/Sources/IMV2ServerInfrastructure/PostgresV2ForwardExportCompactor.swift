import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import SQLKit

/// 仅在持久回执和投递都完成后回收来源信封。
public struct PostgresV2ForwardExportCompactor: Sendable {
    public static let retentionSeconds: TimeInterval = 7 * 24 * 60 * 60
    private let database: any Database

    public init(database: any Database) { self.database = database }

    /// 永久保留操作身份、摘要、路由、媒体 ID 和回执。
    public func runOnce(now: Date = Date(), limit: Int = 128) async throws -> Int {
        guard (1...1_024).contains(limit) else { throw V2ForwardDeliveryError.invalidConfiguration }
        let cutoff = now.addingTimeInterval(-Self.retentionSeconds)
        guard v2PostgresTimestampCanEncode(now), v2PostgresTimestampCanEncode(cutoff),
              let sql = database as? any SQLDatabase else { throw V2ForwardExportError.corruptPersistenceState }
        // 通过主键标量探测，避免把历史回执纳入候选集合的连接。
        // 每次探测最多返回一行；缺失行是 NULL，不符合筛选条件。
        return try await sql.raw("""
            WITH candidates AS (
                SELECT export.export_id FROM im_v2.message_forward_exports AS export
                WHERE export.delivery_completed_at IS NOT NULL
                  AND (SELECT true FROM im_v2.rooms AS room
                       WHERE room.room_id = export.source_room_id
                       FOR SHARE OF room SKIP LOCKED) AND export.payload IS NOT NULL
                  AND export.delivery_completed_at <= \(bind: cutoff)
                  AND (SELECT job.state = 'completed' AND job.completed_at = export.delivery_completed_at
                       FROM im_v2.message_forward_delivery_jobs AS job WHERE job.export_id = export.export_id)
                  AND (SELECT receipt.payload_digest = export.payload_digest AND receipt.recorded_at <= \(bind: cutoff)
                       FROM im_v2.message_forward_export_receipts AS receipt WHERE receipt.export_id = export.export_id)
                ORDER BY export.delivery_completed_at, export.export_id LIMIT \(bind: limit)
                FOR UPDATE OF export SKIP LOCKED
            )
            UPDATE im_v2.message_forward_exports AS export
            SET payload = NULL, payload_compacted_at = \(bind: now)
            FROM candidates WHERE export.export_id = candidates.export_id
            RETURNING export.export_id
            """).all().count
    }
}
