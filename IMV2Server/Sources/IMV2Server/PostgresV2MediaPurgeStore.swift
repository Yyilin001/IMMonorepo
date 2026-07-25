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
        let token = makeUUID()
        let expiresAt = now.addingTimeInterval(leaseDuration)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let rows = try await sql.raw("""
                WITH candidates AS (
                    SELECT media_id, reason
                    FROM im_v2.media_purge_outbox
                    WHERE (state = 'pending' OR (state = 'claimed' AND lease_expires_at <= \(bind: now)))
                    ORDER BY created_at, media_id
                    LIMIT \(bind: limit)
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE im_v2.media_purge_outbox AS outbox
                SET state = 'claimed', claim_token = \(bind: token), lease_expires_at = \(bind: expiresAt), retry_count = outbox.retry_count + 1
                FROM candidates
                WHERE outbox.media_id = candidates.media_id
                RETURNING outbox.media_id, outbox.reason
                """).all(decoding: MediaPurgeRow.self)
            return try rows.map {
                guard let reason = V2MediaPurgeReason(rawValue: $0.reason) else { throw V2RoomWriteStoreError.corruptPersistenceState }
                return try .init(mediaID: .init($0.mediaID.uuidString), reason: reason, claimToken: token)
            }
        }
    }

    public func markCompleted(_ lease: V2MediaPurgeLease, now: Date) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            UPDATE im_v2.media_purge_outbox
            SET state = 'completed', completed_at = \(bind: now), claim_token = NULL, lease_expires_at = NULL
            WHERE media_id = \(bind: try mediaPurgeUUID(lease.mediaID))
              AND state = 'claimed'
              AND claim_token = \(bind: lease.claimToken)
            """).run()
    }

    public func release(_ lease: V2MediaPurgeLease) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            UPDATE im_v2.media_purge_outbox
            SET state = 'pending', claim_token = NULL, lease_expires_at = NULL
            WHERE media_id = \(bind: try mediaPurgeUUID(lease.mediaID))
              AND state = 'claimed'
              AND claim_token = \(bind: lease.claimToken)
            """).run()
    }
}

private struct MediaPurgeRow: Decodable {
    let mediaID: UUID
    let reason: String
    enum CodingKeys: String, CodingKey { case mediaID = "media_id"; case reason }
}

private func mediaPurgeUUID(_ identifier: MediaID) throws -> UUID {
    guard let uuid = UUID(uuidString: identifier.rawValue) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return uuid
}
