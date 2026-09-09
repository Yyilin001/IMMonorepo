import Fluent
import Foundation
import SQLKit

/// PostgreSQL retention authority. Metadata remains available for message and
/// audit replay; only the object becomes terminal and a provider cleanup task
/// is emitted. `SKIP LOCKED` makes concurrent worker instances safe.
public struct PostgresV2MediaRetentionStore: V2MediaRetentionStore {
    private let database: any Database

    public init(database: any Database) {
        self.database = database
    }

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
            // Lock a bounded candidate set first, then recheck in a new
            // READ COMMITTED statement. A single CTE has one MVCC snapshot:
            // an export committing between its snapshot and row lock could
            // otherwise be invisible even after the lock was released.
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

public enum V2MediaRetentionStoreError: Error, Equatable, Sendable {
    case invalidRequest
}

private struct MediaPurgedRow: Decodable {
    let mediaID: UUID
    enum CodingKeys: String, CodingKey { case mediaID = "media_id" }
}
