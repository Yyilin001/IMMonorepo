import Fluent
import Foundation
import IMV2Core
import SQLKit

public struct PostgresV2MediaScanStore: V2MediaScanStore {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID

    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database
        self.makeUUID = makeUUID
    }

    public func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2MediaScanLease] {
        guard limit > 0, leaseDuration > 0 else { return [] }
        guard let leaseExpiresAt = v2PostgresFutureTimestamp(now: now, interval: leaseDuration) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let token = makeUUID()
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let rows = try await sql.raw("""
                WITH candidates AS (
                    SELECT media_id
                    FROM im_v2.media_scan_outbox
                    WHERE (state = 'pending' AND (next_attempt_at IS NULL OR next_attempt_at <= \(bind: now)))
                       OR (state = 'claimed' AND lease_expires_at <= \(bind: now))
                    ORDER BY created_at, media_id
                    LIMIT \(bind: limit)
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE im_v2.media_scan_outbox AS outbox
                SET state = 'claimed', claim_token = \(bind: token), lease_expires_at = \(bind: leaseExpiresAt),
                    next_attempt_at = NULL, paused_at = NULL,
                    retry_count = CASE WHEN outbox.retry_count = 9223372036854775807
                        THEN outbox.retry_count ELSE outbox.retry_count + 1 END
                FROM candidates
                WHERE outbox.media_id = candidates.media_id
                RETURNING outbox.media_id, outbox.retry_count
                """).all(decoding: MediaScanRow.self)
            return try rows.map {
                guard $0.retryCount > 0, $0.retryCount <= Int64(Int.max) else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                return try .init(
                    mediaID: .init($0.mediaID.uuidString),
                    claimToken: token,
                    attempt: Int($0.retryCount)
                )
            }
        }
    }

    public func complete(_ lease: V2MediaScanLease, result: V2MediaScanResult, now: Date) async throws {
        let mediaID = try mediaScanUUID(lease.mediaID)
        let nextState = result == .passed ? "available" : "failed"
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard let scan = try await sql.raw("""
                SELECT media_id, retry_count FROM im_v2.media_scan_outbox
                WHERE media_id = \(bind: mediaID) AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                FOR UPDATE
                """).first(decoding: MediaScanRow.self) else { return }
            let currentTime = try V2PostgresTimestamp(date: now)
            guard let media = try await sql.raw("SELECT state, expires_at FROM im_v2.media_objects WHERE media_id = \(bind: scan.mediaID) FOR UPDATE").first(decoding: MediaScanObjectRow.self), media.expiresAt.microseconds > currentTime.microseconds, media.state == "scanning" else {
                try await sql.raw("""
                    UPDATE im_v2.media_scan_outbox
                    SET state = 'completed', completed_at = \(bind: now), claim_token = NULL,
                        lease_expires_at = NULL, next_attempt_at = NULL, paused_at = NULL
                    WHERE media_id = \(bind: scan.mediaID) AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                    """).run()
                return
            }
            try await sql.raw("UPDATE im_v2.media_objects SET state = \(bind: nextState), state_updated_at = \(bind: now) WHERE media_id = \(bind: scan.mediaID)").run()
            try await sql.raw("""
                UPDATE im_v2.media_scan_outbox
                SET state = 'completed', completed_at = \(bind: now), claim_token = NULL,
                    lease_expires_at = NULL, next_attempt_at = NULL, paused_at = NULL
                WHERE media_id = \(bind: scan.mediaID) AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                """).run()
        }
    }

    public func scheduleRetry(_ lease: V2MediaScanLease, disposition: V2DurableRetryDisposition, now: Date) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let mediaID = try mediaScanUUID(lease.mediaID)
        switch disposition {
        case .retry(let retryAt):
            guard v2PostgresTimestampCanEncode(retryAt) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await sql.raw("""
                UPDATE im_v2.media_scan_outbox
                SET state = 'pending', claim_token = NULL, lease_expires_at = NULL,
                    next_attempt_at = \(bind: retryAt), paused_at = NULL
                WHERE media_id = \(bind: mediaID)
                  AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                """).run()
        case .pause:
            guard v2PostgresTimestampCanEncode(now) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await sql.raw("""
                UPDATE im_v2.media_scan_outbox
                SET state = 'paused', claim_token = NULL, lease_expires_at = NULL,
                    next_attempt_at = NULL, paused_at = \(bind: now)
                WHERE media_id = \(bind: mediaID)
                  AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                """).run()
        }
    }
}

private struct MediaScanRow: Decodable {
    let mediaID: UUID
    let retryCount: Int64
    enum CodingKeys: String, CodingKey { case mediaID = "media_id"; case retryCount = "retry_count" }
}
private struct MediaScanObjectRow: Decodable { let state: String; let expiresAt: V2PostgresTimestamp; enum CodingKeys: String, CodingKey { case state; case expiresAt = "expires_at" } }
private func mediaScanUUID(_ identifier: MediaID) throws -> UUID { guard let uuid = UUID(uuidString: identifier.rawValue) else { throw V2RoomWriteStoreError.corruptPersistenceState }; return uuid }
