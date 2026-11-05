import FluentKit
import Foundation
import IMV2Core
import IMV2ServerContracts
import SQLKit

public struct PostgresV2AccountNotificationStore: V2AccountNotificationStoring {
    private let database: any Database
    public init(database: any Database) { self.database = database }
    private func sql(now: Date, limit: Int) throws -> any SQLDatabase {
        guard (1...128).contains(limit), v2PostgresTimestampCanEncode(now),
              let sql = database as? any SQLDatabase else { throw V2RoomDispatchError.invalidInput }
        return sql
    }
    public func expire(now: Date, limit: Int) async throws -> Int {
        let sql = try sql(now: now, limit: limit)
        guard let cutoff = v2PostgresPastTimestamp(now: now, interval: V2AccountNotificationLimits.lifetime) else {
            throw V2RoomDispatchError.invalidInput
        }
        return try await sql.raw("""
            WITH candidates AS (
                SELECT user_id, source_event_id FROM im_v2.account_notification_outbox
                WHERE created_at <= \(bind: cutoff)
                  AND (lease_expires_at IS NULL OR lease_expires_at <= \(bind: now))
                ORDER BY created_at, user_id, source_event_id
                LIMIT \(bind: limit) FOR UPDATE SKIP LOCKED
            )
            DELETE FROM im_v2.account_notification_outbox work USING candidates
            WHERE work.user_id=candidates.user_id AND work.source_event_id=candidates.source_event_id
            RETURNING work.source_event_id
            """).all().count
    }
    public func claim(now: Date, limit: Int) async throws -> [V2AccountNotificationLease] {
        let sql = try sql(now: now, limit: limit)
        guard let expiry = v2PostgresFutureTimestamp(now: now, interval: 60),
              let cutoff = v2PostgresPastTimestamp(now: now, interval: V2AccountNotificationLimits.lifetime) else {
            throw V2RoomDispatchError.invalidInput
        }
        let token = UUID()
        let rows = try await sql.raw("""
            WITH candidates AS (
                SELECT user_id, source_event_id FROM im_v2.account_notification_outbox
                WHERE next_attempt_at <= \(bind: now) AND created_at > \(bind: cutoff)
                  AND (lease_expires_at IS NULL OR lease_expires_at <= \(bind: now))
                ORDER BY next_attempt_at, created_at, user_id, source_event_id
                LIMIT \(bind: limit) FOR UPDATE SKIP LOCKED
            )
            UPDATE im_v2.account_notification_outbox work
            SET claim_token=\(bind: token), lease_expires_at=\(bind: expiry),
                attempt=LEAST(work.attempt::bigint+1,2147483647)::integer
            FROM candidates WHERE work.user_id=candidates.user_id AND work.source_event_id=candidates.source_event_id
            RETURNING work.*
            """).all(decoding: AccountNotificationRow.self)
        return try rows.map { row in
            guard row.room_sequence > 0, row.membership_revision >= 0 else { throw V2RoomDispatchError.corruptPersistence }
            return .init(notification: .init(userID: .init(uuid: row.user_id), eventID: row.source_event_id,
                messageID: .init(uuid: row.message_id), roomID: .init(uuid: row.room_id), roomSequence: UInt64(row.room_sequence),
                membershipRevision: UInt64(row.membership_revision), senderID: .init(uuid: row.sender_user_id),
                isMention: row.is_mention, createdAt: row.created_at), token: token, expiresAt: expiry, attempt: row.attempt)
        }
    }
    public func complete(_ lease: V2AccountNotificationLease, now: Date) async throws -> Bool {
        let sql = try sql(now: now, limit: 1)
        guard let user = lease.notification.userID.uuidValue else { throw V2RoomDispatchError.invalidInput }
        return try await sql.raw("""
            DELETE FROM im_v2.account_notification_outbox
            WHERE user_id=\(bind: user) AND source_event_id=\(bind: lease.notification.eventID)
              AND claim_token=\(bind: lease.token) AND lease_expires_at>\(bind: now)
            RETURNING source_event_id
            """).first() != nil
    }
    public func retry(_ lease: V2AccountNotificationLease, now: Date, after: TimeInterval) async throws {
        let sql = try sql(now: now, limit: 1)
        guard let user = lease.notification.userID.uuidValue else { throw V2RoomDispatchError.invalidInput }
        guard after > 0, let next = v2PostgresFutureTimestamp(now: now, interval: after) else { throw V2RoomDispatchError.invalidInput }
        try await sql.raw("""
            UPDATE im_v2.account_notification_outbox
            SET claim_token=NULL, lease_expires_at=NULL, next_attempt_at=\(bind: next)
            WHERE user_id=\(bind: user) AND source_event_id=\(bind: lease.notification.eventID)
              AND claim_token=\(bind: lease.token) AND lease_expires_at>\(bind: now)
            """).run()
    }
}
private struct AccountNotificationRow: Decodable {
    let user_id: UUID, source_event_id: UUID, message_id: UUID, room_id: UUID, sender_user_id: UUID
    let room_sequence: Int64, membership_revision: Int64
    let is_mention: Bool
    let created_at: Date
    let attempt: Int
}
