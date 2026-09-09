import Fluent
import Foundation
import IMV2Core
import SQLKit

/// PostgreSQL lease store for the coalesced Hybrid-room wake outbox. It never
/// stores a user, device, message body, or event payload.
public struct PostgresV2GroupEventWakeStore: V2GroupEventWakeStore {
    private let database: any Database

    public init(database: any Database) { self.database = database }

    public func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2GroupEventWakeLease] {
        guard limit > 0,
              let expiry = v2PostgresFutureTimestamp(now: now, interval: leaseDuration)
        else { throw V2GroupEventWakeStoreError.corruptPersistenceState }
        let token = UUID()
        let rows = try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2GroupEventWakeStoreError.corruptPersistenceState
            }
            try await sql.raw("""
                WITH candidates AS (
                    SELECT room_id
                    FROM im_v2.group_event_wake_outbox
                    WHERE (state = 'pending' AND next_attempt_at <= \(bind: now))
                       OR (state = 'leased' AND lease_expires_at <= \(bind: now))
                    ORDER BY next_attempt_at, updated_at
                    LIMIT \(bind: limit)
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE im_v2.group_event_wake_outbox AS wake
                SET state = 'leased',
                    lease_token = \(bind: token),
                    lease_expires_at = \(bind: expiry),
                    attempt_count = CASE WHEN wake.attempt_count = 2147483647
                        THEN wake.attempt_count ELSE wake.attempt_count + 1 END,
                    updated_at = \(bind: now)
                FROM candidates
                WHERE wake.room_id = candidates.room_id
                """).run()

            // This deliberately is a second READ COMMITTED statement. A
            // message transaction that committed before the lease lock became
            // ours is now visible here. A transaction that is still appending
            // must update the leased outbox row before it can commit, which
            // replaces this revision and preserves another wake. Reading the
            // room counter in the claim UPDATE's original statement snapshot
            // would leave a narrow lost-watermark race after lock waits.
            return try await sql.raw("""
                SELECT wake.room_id,
                       GREATEST(wake.target_room_sequence, room.room_sequence)
                           AS target_room_sequence,
                       wake.revision,
                       wake.attempt_count
                FROM im_v2.group_event_wake_outbox AS wake
                JOIN im_v2.rooms AS room ON room.room_id = wake.room_id
                WHERE wake.lease_token = \(bind: token)
                  AND wake.state = 'leased'
                ORDER BY wake.next_attempt_at, wake.updated_at
                """).all(decoding: GroupEventWakeLeaseRow.self)
        }
        return try rows.map { row in
            guard row.targetRoomSequence > 0, row.revision > 0, row.attemptCount > 0 else {
                throw V2GroupEventWakeStoreError.corruptPersistenceState
            }
            return .init(
                wake: .init(roomID: try .init(row.roomID.uuidString), highWatermark: UInt64(row.targetRoomSequence)),
                revision: UInt64(row.revision),
                claimToken: token,
                attempt: row.attemptCount
            )
        }
    }

    public func markPublished(_ lease: V2GroupEventWakeLease) async throws {
        guard let sql = database as? any SQLDatabase,
              let roomID = UUID(uuidString: lease.wake.roomID.rawValue),
              lease.revision <= UInt64(Int64.max)
        else { throw V2GroupEventWakeStoreError.corruptPersistenceState }
        // Revision fencing is intentional: an UPSERT that observed a newer
        // event changes revision/state before this delete can run.
        try await sql.raw("""
            DELETE FROM im_v2.group_event_wake_outbox
            WHERE room_id = \(bind: roomID)
              AND lease_token = \(bind: lease.claimToken)
              AND revision = \(bind: Int64(lease.revision))
            """).run()
    }

    public func scheduleRetry(_ lease: V2GroupEventWakeLease, nextAttemptAt: Date) async throws {
        guard let sql = database as? any SQLDatabase,
              let roomID = UUID(uuidString: lease.wake.roomID.rawValue),
              lease.revision <= UInt64(Int64.max),
              v2PostgresTimestampCanEncode(nextAttemptAt)
        else { throw V2GroupEventWakeStoreError.corruptPersistenceState }
        try await sql.raw("""
            UPDATE im_v2.group_event_wake_outbox
            SET state = 'pending',
                lease_token = NULL,
                lease_expires_at = NULL,
                next_attempt_at = \(bind: nextAttemptAt),
                updated_at = \(bind: nextAttemptAt)
            WHERE room_id = \(bind: roomID)
              AND lease_token = \(bind: lease.claimToken)
              AND revision = \(bind: Int64(lease.revision))
            """).run()
    }
}

public enum V2GroupEventWakeStoreError: Error, Equatable, Sendable {
    case corruptPersistenceState
}

private struct GroupEventWakeLeaseRow: Decodable {
    let roomID: UUID
    let targetRoomSequence: Int64
    let revision: Int64
    let attemptCount: Int

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case targetRoomSequence = "target_room_sequence"
        case revision
        case attemptCount = "attempt_count"
    }
}
