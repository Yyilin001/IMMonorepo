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
        let withdrawnBefore = now.addingTimeInterval(-withdrawnRetention)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let rows = try await sql.raw("""
                WITH candidates AS (
                    SELECT media.media_id,
                           CASE
                             WHEN NOT EXISTS (
                               SELECT 1 FROM im_v2.message_media_references AS reference
                               WHERE reference.media_id = media.media_id
                             ) THEN 'unreferenced_expired'
                             ELSE 'withdrawn_retention_elapsed'
                           END AS reason
                    FROM im_v2.media_objects AS media
                    WHERE media.state <> 'expired'
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
                    ORDER BY media.created_at, media.media_id
                    FOR UPDATE SKIP LOCKED
                    LIMIT \(bind: limit)
                ), expired AS (
                    UPDATE im_v2.media_objects AS media
                    SET state = 'expired', state_updated_at = \(bind: now)
                    FROM candidates
                    WHERE media.media_id = candidates.media_id
                    RETURNING media.media_id
                )
                INSERT INTO im_v2.media_purge_outbox (media_id, reason, state, created_at)
                SELECT candidates.media_id, candidates.reason, 'pending', \(bind: now)
                FROM candidates
                JOIN expired ON expired.media_id = candidates.media_id
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
