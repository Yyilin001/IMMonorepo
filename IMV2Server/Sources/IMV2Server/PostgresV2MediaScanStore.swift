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
        let token = makeUUID()
        let leaseExpiresAt = now.addingTimeInterval(leaseDuration)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let rows = try await sql.raw("""
                WITH candidates AS (
                    SELECT media_id
                    FROM im_v2.media_scan_outbox
                    WHERE state = 'pending' OR (state = 'claimed' AND lease_expires_at <= \(bind: now))
                    ORDER BY created_at, media_id
                    LIMIT \(bind: limit)
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE im_v2.media_scan_outbox AS outbox
                SET state = 'claimed', claim_token = \(bind: token), lease_expires_at = \(bind: leaseExpiresAt), retry_count = outbox.retry_count + 1
                FROM candidates
                WHERE outbox.media_id = candidates.media_id
                RETURNING outbox.media_id
                """).all(decoding: MediaScanRow.self)
            return try rows.map { try .init(mediaID: .init($0.mediaID.uuidString), claimToken: token) }
        }
    }

    public func complete(_ lease: V2MediaScanLease, result: V2MediaScanResult, now: Date) async throws {
        let mediaID = try mediaScanUUID(lease.mediaID)
        let nextState = result == .passed ? "available" : "failed"
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard let scan = try await sql.raw("""
                SELECT media_id FROM im_v2.media_scan_outbox
                WHERE media_id = \(bind: mediaID) AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                FOR UPDATE
                """).first(decoding: MediaScanRow.self) else { return }
            guard let media = try await sql.raw("SELECT state, expires_at FROM im_v2.media_objects WHERE media_id = \(bind: scan.mediaID) FOR UPDATE").first(decoding: MediaScanObjectRow.self), media.expiresAt > now, media.state == "scanning" else {
                try await sql.raw("""
                    UPDATE im_v2.media_scan_outbox
                    SET state = 'completed', completed_at = \(bind: now), claim_token = NULL, lease_expires_at = NULL
                    WHERE media_id = \(bind: scan.mediaID) AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                    """).run()
                return
            }
            try await sql.raw("UPDATE im_v2.media_objects SET state = \(bind: nextState), state_updated_at = \(bind: now) WHERE media_id = \(bind: scan.mediaID)").run()
            try await sql.raw("""
                UPDATE im_v2.media_scan_outbox
                SET state = 'completed', completed_at = \(bind: now), claim_token = NULL, lease_expires_at = NULL
                WHERE media_id = \(bind: scan.mediaID) AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                """).run()
        }
    }

    public func release(_ lease: V2MediaScanLease) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            UPDATE im_v2.media_scan_outbox
            SET state = 'pending', claim_token = NULL, lease_expires_at = NULL
            WHERE media_id = \(bind: try mediaScanUUID(lease.mediaID))
              AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
            """).run()
    }
}

private struct MediaScanRow: Decodable { let mediaID: UUID; enum CodingKeys: String, CodingKey { case mediaID = "media_id" } }
private struct MediaScanObjectRow: Decodable { let state: String; let expiresAt: Date; enum CodingKeys: String, CodingKey { case state; case expiresAt = "expires_at" } }
private func mediaScanUUID(_ identifier: MediaID) throws -> UUID { guard let uuid = UUID(uuidString: identifier.rawValue) else { throw V2RoomWriteStoreError.corruptPersistenceState }; return uuid }
