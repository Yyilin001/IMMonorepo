import Fluent
import Foundation
import IMV2Core
import SQLKit

public struct PostgresV2MediaPurgeStore: V2MediaPurgeStore {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID

    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database
        self.makeUUID = makeUUID
    }

    public func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2MediaPurgeLease] {
        guard limit > 0, leaseDuration > 0 else { return [] }
        guard let expiresAt = v2PostgresFutureTimestamp(now: now, interval: leaseDuration) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let token = makeUUID()
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let rows = try await sql.raw("""
                WITH candidates AS (
                    SELECT media_id, reason
                    FROM im_v2.media_purge_outbox
                    WHERE (state = 'pending' AND (next_attempt_at IS NULL OR next_attempt_at <= \(bind: now)))
                       OR (state = 'claimed' AND lease_expires_at <= \(bind: now))
                    ORDER BY created_at, media_id
                    LIMIT \(bind: limit)
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE im_v2.media_purge_outbox AS outbox
                SET state = 'claimed', claim_token = \(bind: token), lease_expires_at = \(bind: expiresAt),
                    next_attempt_at = NULL, paused_at = NULL,
                    retry_count = CASE WHEN outbox.retry_count = 9223372036854775807
                        THEN outbox.retry_count ELSE outbox.retry_count + 1 END
                FROM candidates
                WHERE outbox.media_id = candidates.media_id
                RETURNING outbox.media_id, outbox.reason, outbox.retry_count
                """).all(decoding: MediaPurgeRow.self)
            return try rows.map {
                guard let reason = V2MediaPurgeReason(rawValue: $0.reason) else { throw V2RoomWriteStoreError.corruptPersistenceState }
                guard $0.retryCount > 0, $0.retryCount <= Int64(Int.max) else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                return try .init(
                    mediaID: .init($0.mediaID.uuidString),
                    reason: reason,
                    claimToken: token,
                    attempt: Int($0.retryCount)
                )
            }
        }
    }

    public func markCompleted(_ lease: V2MediaPurgeLease, now: Date) async throws {
        guard v2PostgresTimestampCanEncode(now),
              let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            UPDATE im_v2.media_purge_outbox
            SET state = 'completed', completed_at = \(bind: now), claim_token = NULL,
                lease_expires_at = NULL, next_attempt_at = NULL, paused_at = NULL
            WHERE media_id = \(bind: try mediaPurgeUUID(lease.mediaID))
              AND state = 'claimed'
              AND claim_token = \(bind: lease.claimToken)
            """).run()
    }

    public func scheduleRetry(_ lease: V2MediaPurgeLease, disposition: V2DurableRetryDisposition, now: Date) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let mediaID = try mediaPurgeUUID(lease.mediaID)
        switch disposition {
        case .retry(let retryAt):
            guard v2PostgresTimestampCanEncode(retryAt) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await sql.raw("""
                UPDATE im_v2.media_purge_outbox
                SET state = 'pending', claim_token = NULL, lease_expires_at = NULL,
                    next_attempt_at = \(bind: retryAt), paused_at = NULL
                WHERE media_id = \(bind: mediaID)
                  AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                """).run()
        case .pause:
            guard v2PostgresTimestampCanEncode(now) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await sql.raw("""
                UPDATE im_v2.media_purge_outbox
                SET state = 'paused', claim_token = NULL, lease_expires_at = NULL,
                    next_attempt_at = NULL, paused_at = \(bind: now)
                WHERE media_id = \(bind: mediaID)
                  AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                """).run()
        }
    }
}

private struct MediaPurgeRow: Decodable {
    let mediaID: UUID
    let reason: String
    let retryCount: Int64
    enum CodingKeys: String, CodingKey {
        case mediaID = "media_id"
        case reason
        case retryCount = "retry_count"
    }
}

private func mediaPurgeUUID(_ identifier: MediaID) throws -> UUID {
    guard let uuid = UUID(uuidString: identifier.rawValue) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return uuid
}
