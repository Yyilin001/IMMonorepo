import Fluent
import Foundation
import SQLKit

/// Reclaims source envelopes only after durable receipt and delivery completion.
public struct PostgresV2ForwardExportCompactor: Sendable {
    public static let retentionSeconds: TimeInterval = 7 * 24 * 60 * 60
    private let database: any Database

    public init(database: any Database) { self.database = database }

    /// Keeps operation identity, digest, routing, media IDs and receipt indefinitely.
    public func runOnce(now: Date = Date(), limit: Int = 128) async throws -> Int {
        guard (1...1_024).contains(limit) else { throw V2ForwardDeliveryError.invalidConfiguration }
        let cutoff = now.addingTimeInterval(-Self.retentionSeconds)
        guard v2PostgresTimestampCanEncode(now), v2PostgresTimestampCanEncode(cutoff),
              let sql = database as? any SQLDatabase else { throw V2ForwardExportError.corruptPersistenceState }
        // Primary-key scalar probes keep historical receipts out of the candidate join.
        // Each probe returns at most one row; a missing row is NULL and cannot qualify.
        return try await sql.raw("""
            WITH candidates AS (
                SELECT export.export_id FROM im_v2.message_forward_exports AS export
                WHERE export.delivery_completed_at IS NOT NULL
                  AND (SELECT true FROM im_v2.rooms AS room
                       WHERE room.room_id = export.source_room_id AND room.migration_fence_id IS NULL
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
