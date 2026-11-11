import FluentKit
import Foundation
import IMV2Core
import IMV2ServerContracts
import SQLKit

public struct PostgresV2RoomDispatchStore: V2RoomDispatchOutbox {
    let database: any Database
    public init(database: any Database) { self.database = database }

    public func claim(now: Date, limit: Int, leaseDuration: TimeInterval = 30) async throws -> [V2RoomDispatchLease] {
        guard (1...256).contains(limit), let expiry = v2PostgresFutureTimestamp(now: now, interval: leaseDuration),
              leaseDuration > 0, let sql = database as? any SQLDatabase else { throw V2RoomDispatchError.invalidInput }
        let token = UUID()
        let rows = try await sql.raw("""
            WITH candidates AS (
                SELECT source_event_id FROM im_v2.room_dispatch_outbox
                WHERE next_attempt_at <= \(bind: now)
                  AND (lease_expires_at IS NULL OR lease_expires_at <= \(bind: now))
                ORDER BY next_attempt_at, created_at, source_event_id
                LIMIT \(bind: limit) FOR UPDATE SKIP LOCKED
            )
            UPDATE im_v2.room_dispatch_outbox work
            SET claim_token = \(bind: token), lease_expires_at = \(bind: expiry),
                attempt = LEAST(work.attempt::bigint + 1, 2147483647)::integer
            FROM candidates WHERE work.source_event_id = candidates.source_event_id
            RETURNING work.*
            """).all(decoding: DispatchRow.self)
        return try rows.map { row in
            guard row.room_sequence > 0, row.membership_revision >= 0 else { throw V2RoomDispatchError.corruptPersistence }
            return .init(eventID: row.source_event_id, messageID: row.message_id, roomID: .init(uuid: row.room_id),
                roomSequence: UInt64(row.room_sequence), membershipRevision: UInt64(row.membership_revision),
                senderID: row.sender_user_id.map { .init(uuid: $0) }, mentionedUserIDs: Set(row.mentioned_user_ids.map { .init(uuid: $0) }),
                mentionsEveryone: row.mentions_everyone, createdAtTimestamp: row.created_at, recipientCursor: row.recipient_cursor, token: token,
                attempt: row.attempt, expiresAt: expiry)
        }
    }

    /// Includes the sender for their other devices' account synchronization.
    /// Push policy separately excludes self-notifications. Current membership
    /// is not substituted for membership at the accepted message's revision.
    public func recipients(_ lease: V2RoomDispatchLease, limit: Int, now: Date) async throws -> [UserID] {
        guard (1...256).contains(limit), v2PostgresTimestampCanEncode(now),
              let sql = database as? any SQLDatabase else { throw V2RoomDispatchError.invalidInput }
        let rows = try await sql.raw("""
            SELECT audience.user_id
            FROM im_v2.room_dispatch_outbox work
            LEFT JOIN LATERAL (
                SELECT DISTINCT membership.user_id FROM im_v2.room_memberships membership
                WHERE membership.room_id = work.room_id
                  AND membership.joined_revision <= work.membership_revision
                  AND (membership.left_revision IS NULL OR membership.left_revision > work.membership_revision)
                  AND (work.recipient_cursor IS NULL OR membership.user_id > work.recipient_cursor)
                ORDER BY membership.user_id LIMIT \(bind: limit)
            ) audience ON true
            WHERE work.source_event_id = \(bind: lease.eventID) AND work.claim_token = \(bind: lease.token)
              AND work.lease_expires_at > \(bind: now)
              AND work.recipient_cursor IS NOT DISTINCT FROM \(bind: lease.recipientCursor)::uuid
            ORDER BY audience.user_id
            """).all(decoding: DispatchRecipient.self)
        // A retained work row with an empty audience yields one NULL. No row
        // means the lease fence failed, not that delivery has completed.
        guard !rows.isEmpty else { throw V2RoomDispatchError.lostLease }
        return rows.compactMap { $0.user_id.map { .init(uuid: $0) } }
    }

    /// Read one bounded cohort in one statement, preserving each lease's fence
    /// and historical membership. A valid empty page differs from a lost lease.
    public func recipientPages(_ leases: [V2RoomDispatchLease], limit: Int, now: Date) async throws -> [[UserID]?] {
        guard leases.count <= 32, (1...256).contains(limit), v2PostgresTimestampCanEncode(now),
              let sql = database as? any SQLDatabase else { throw V2RoomDispatchError.invalidInput }
        guard !leases.isEmpty else { return [] }
        let input = SQLList(leases.enumerated().map { index, lease -> SQLQueryString in
            "(\(bind: index)::integer,\(bind: lease.eventID)::uuid,\(bind: lease.token)::uuid,\(bind: lease.recipientCursor)::uuid)"
        })
        let rows = try await sql.raw("""
            WITH requested(ordinal,event_id,token,cursor) AS (VALUES \(input))
            SELECT requested.ordinal, work.source_event_id IS NOT NULL AS owned, audience.user_id
            FROM requested
            LEFT JOIN im_v2.room_dispatch_outbox work
              ON work.source_event_id=requested.event_id AND work.claim_token=requested.token
             AND work.lease_expires_at>\(bind: now)
             AND work.recipient_cursor IS NOT DISTINCT FROM requested.cursor
            LEFT JOIN LATERAL (
                SELECT DISTINCT membership.user_id FROM im_v2.room_memberships membership
                WHERE membership.room_id=work.room_id
                  AND membership.joined_revision<=work.membership_revision
                  AND (membership.left_revision IS NULL OR membership.left_revision>work.membership_revision)
                  AND (work.recipient_cursor IS NULL OR membership.user_id>work.recipient_cursor)
                ORDER BY membership.user_id LIMIT \(bind: limit)
            ) audience ON true
            ORDER BY requested.ordinal,audience.user_id
            """).all(decoding: DispatchRecipientPage.self)
        var pages = Array<[UserID]?>(repeating: nil, count: leases.count)
        var observed = Set<Int>()
        for row in rows {
            guard pages.indices.contains(row.ordinal) else { throw V2RoomDispatchError.corruptPersistence }
            observed.insert(row.ordinal)
            if row.owned {
                if pages[row.ordinal] == nil { pages[row.ordinal] = [] }
                if let user = row.user_id { pages[row.ordinal]!.append(.init(uuid: user)) }
            }
        }
        guard observed.count == leases.count else { throw V2RoomDispatchError.corruptPersistence }
        return pages
    }

    /// Call only after every target in the page has durably accepted the effect.
    /// A crash before this CAS replays the page with stable event/user identities.
    /// An exhausted audience is removed in this acknowledgement, avoiding a
    /// second empty claim for every private-chat message. Nil checks an empty page.
    public func acknowledgePage(_ lease: V2RoomDispatchLease, through cursor: UUID?, now: Date) async throws -> Bool {
        guard v2PostgresTimestampCanEncode(now), let sql = database as? any SQLDatabase else {
            throw V2RoomDispatchError.invalidInput
        }
        if let cursor {
            return try await sql.raw("""
                WITH owned AS MATERIALIZED (
                    SELECT work.source_event_id, NOT EXISTS (
                        SELECT 1 FROM im_v2.room_memberships membership
                        WHERE membership.room_id = work.room_id
                          AND membership.joined_revision <= work.membership_revision
                          AND (membership.left_revision IS NULL OR membership.left_revision > work.membership_revision)
                          AND membership.user_id > \(bind: cursor)
                    ) AS exhausted
                    FROM im_v2.room_dispatch_outbox work
                    WHERE work.source_event_id = \(bind: lease.eventID) AND work.claim_token = \(bind: lease.token)
                      AND work.lease_expires_at > \(bind: now)
                      AND work.recipient_cursor IS NOT DISTINCT FROM \(bind: lease.recipientCursor)::uuid
                      AND (work.recipient_cursor IS NULL OR work.recipient_cursor < \(bind: cursor))
                    FOR UPDATE OF work
                ), finished AS (
                    DELETE FROM im_v2.room_dispatch_outbox work USING owned
                    WHERE work.source_event_id = owned.source_event_id AND owned.exhausted
                    RETURNING work.source_event_id
                ), advanced AS (
                    UPDATE im_v2.room_dispatch_outbox work
                    SET recipient_cursor = \(bind: cursor), claim_token = NULL, lease_expires_at = NULL,
                        next_attempt_at = \(bind: now)
                    FROM owned WHERE work.source_event_id = owned.source_event_id AND NOT owned.exhausted
                    RETURNING work.source_event_id
                )
                SELECT source_event_id FROM finished UNION ALL SELECT source_event_id FROM advanced
                """).first() != nil
        }
        return try await sql.raw("""
            DELETE FROM im_v2.room_dispatch_outbox
            WHERE source_event_id = \(bind: lease.eventID) AND claim_token = \(bind: lease.token)
              AND lease_expires_at > \(bind: now)
              AND recipient_cursor IS NOT DISTINCT FROM \(bind: lease.recipientCursor)::uuid
              AND NOT EXISTS (
                  SELECT 1 FROM im_v2.room_memberships membership
                  WHERE membership.room_id = room_dispatch_outbox.room_id
                    AND membership.joined_revision <= room_dispatch_outbox.membership_revision
                    AND (membership.left_revision IS NULL OR membership.left_revision > room_dispatch_outbox.membership_revision)
                    AND (room_dispatch_outbox.recipient_cursor IS NULL OR membership.user_id > room_dispatch_outbox.recipient_cursor)
              )
            RETURNING source_event_id
            """).first() != nil
    }

    public func retry(_ lease: V2RoomDispatchLease, now: Date, after delay: TimeInterval) async throws {
        guard delay >= 0, v2PostgresTimestampCanEncode(now),
              let next = delay == 0 ? now : v2PostgresFutureTimestamp(now: now, interval: delay),
              let sql = database as? any SQLDatabase else { throw V2RoomDispatchError.invalidInput }
        try await sql.raw("""
            UPDATE im_v2.room_dispatch_outbox
            SET claim_token = NULL, lease_expires_at = NULL, next_attempt_at = \(bind: next)
            WHERE source_event_id = \(bind: lease.eventID) AND claim_token = \(bind: lease.token)
              AND lease_expires_at > \(bind: now)
            """).run()
    }
}

private struct DispatchRow: Decodable {
    let source_event_id: UUID
    let message_id: UUID?
    let room_id: UUID
    let room_sequence: Int64
    let membership_revision: Int64
    let sender_user_id: UUID?
    let mentioned_user_ids: [UUID]
    let mentions_everyone: Bool
    let created_at: V2PersistenceTimestamp
    let attempt: Int
    let recipient_cursor: UUID?
}
private struct DispatchRecipient: Decodable { let user_id: UUID? }

private struct DispatchRecipientPage: Decodable { let ordinal: Int; let owned: Bool; let user_id: UUID? }
