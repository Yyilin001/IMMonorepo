import FluentKit
import Foundation
import SQLKit

/// Reclaims terminal inbox body copies while preserving identity, digest and outcome.
/// Seven days is a diagnostic grace period, not an idempotency expiration window.
public struct PostgresV2ForwardInboxCompactor: Sendable {
    public static let retentionSeconds: TimeInterval = 7 * 24 * 60 * 60
    private let database: any Database

    public init(database: any Database) { self.database = database }

    /// Runs one atomic bounded batch. Concurrent cleaners skip each other's locks.
    /// Pending and accepted inboxes retain their bodies, including paused imports.
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
