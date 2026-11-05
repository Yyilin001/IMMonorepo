import FluentKit
import Foundation
import IMV2Core
import IMV2ServerContracts
import SQLKit

extension PostgresV2UserStateEventProjector {
    /// Batch already accepted room facts on one account storage shard. Sequence
    /// rows serialize writers only. Snapshot checkpoints never participate.
    package func appendRoomChanges(_ targets: [V2RoomDispatchTarget]) async throws {
        guard !targets.isEmpty, targets.count <= 1024,
              Set(targets.map(\.userID)).count == targets.count,
              targets.allSatisfy({ (1...32).contains($0.leases.count) }),
              targets.reduce(0, { $0 + $1.leases.count }) <= 1024 else { throw V2RoomDispatchError.invalidInput }
        var input: SQLQueryString = ""
        var ordinal = 0
        for target in targets.sorted(by: { $0.userID.rawValue < $1.userID.rawValue }) {
            guard let user = target.userID.uuidValue,
                  Set(target.leases.map(\.eventID)).count == target.leases.count else { throw V2RoomDispatchError.invalidInput }
            for lease in target.leases {
                let event = try v2AccountRoomChangeEvent(lease, userID: target.userID)
                guard let room = lease.roomID.uuidValue,
                      let sequence = Int64(exactly: lease.roomSequence),
                      let revision = Int64(exactly: lease.membershipRevision) else { throw V2RoomDispatchError.invalidInput }
                if ordinal > 0 { input += "," }
                input += """
                    (\(bind: ordinal)::integer,\(bind: user)::uuid,\(bind: lease.eventID)::uuid,
                     \(bind: event.payloadJSON)::jsonb,\(bind: lease.createdAtTimestamp)::timestamptz,
                     \(bind: lease.messageID)::uuid,\(bind: room)::uuid,\(bind: sequence)::bigint,
                     \(bind: revision)::bigint,\(bind: lease.senderID?.uuidValue)::uuid,
                     \(bind: lease.mentionsEveryone || lease.mentionedUserIDs.contains(target.userID))::boolean)
                    """
                ordinal += 1
            }
        }
        let users = targets.map(\.userID).sorted { $0.rawValue < $1.rawValue }
        let usersJSON = String(decoding: try JSONEncoder().encode(users.map(\.rawValue)), as: UTF8.self)
        let values = input
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomDispatchError.corruptPersistence }
            // Stable order prevents overlapping multi-account batches taking
            // each other's sequence rows in opposite orders.
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).user_sync_sequences(user_id,next_sequence)
                SELECT value::uuid,0 FROM jsonb_array_elements_text(\(bind: usersJSON)::jsonb)
                ORDER BY value::uuid ON CONFLICT(user_id) DO NOTHING
                """).run()
            let locked = try await sql.raw("""
                SELECT user_id FROM \(unsafeRaw: schema).user_sync_sequences
                WHERE user_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: usersJSON)::jsonb))
                ORDER BY user_id FOR UPDATE
                """).all()
            guard locked.count == users.count else { throw V2RoomDispatchError.corruptPersistence }
            let result = try await sql.raw("""
                WITH input(ordinal,user_id,source_event_id,payload,created_at,message_id,room_id,
                           room_sequence,membership_revision,sender_user_id,is_mention) AS MATERIALIZED (VALUES \(values)),
                prior AS MATERIALIZED (
                    SELECT i.*,r.user_sync_sequence AS prior_sequence,r.payload AS prior_payload
                    FROM input i LEFT JOIN \(unsafeRaw: schema).user_state_event_receipts r
                      ON r.user_id=i.user_id AND r.source_event_id=i.source_event_id AND r.projection_kind='room_head'
                ), fresh AS MATERIALIZED (
                    SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY ordinal) AS offset
                    FROM prior WHERE prior_payload IS NULL
                ), counts AS (SELECT user_id,count(*) AS n FROM fresh GROUP BY user_id),
                allocated AS (
                    UPDATE \(unsafeRaw: schema).user_sync_sequences s SET next_sequence=s.next_sequence+c.n
                    FROM counts c WHERE s.user_id=c.user_id AND s.next_sequence<=9223372036854775807-c.n
                    RETURNING s.user_id,s.next_sequence,c.n
                ), receipts AS (
                    INSERT INTO \(unsafeRaw: schema).user_state_event_receipts
                        (user_id,source_event_id,projection_kind,payload,projection_payload,source_created_at,user_sync_sequence)
                    SELECT f.user_id,f.source_event_id,'room_head',f.payload,f.payload,f.created_at,
                           a.next_sequence-a.n+f.offset
                    FROM fresh f JOIN allocated a USING(user_id)
                    RETURNING user_id,source_event_id,user_sync_sequence,projection_payload,source_created_at
                ), logged AS (
                    INSERT INTO \(unsafeRaw: schema).user_sync_log
                        (user_id,user_sync_sequence,source_event_id,projection_kind,payload,created_at)
                    SELECT user_id,user_sync_sequence,source_event_id,'room_head',projection_payload,source_created_at
                    FROM receipts ORDER BY user_id,user_sync_sequence
                    RETURNING user_id,source_event_id
                ), notified AS (
                    INSERT INTO \(unsafeRaw: schema).account_notification_outbox
                        (user_id,source_event_id,message_id,room_id,room_sequence,membership_revision,
                         sender_user_id,is_mention,created_at,next_attempt_at)
                    SELECT i.user_id,i.source_event_id,i.message_id,i.room_id,i.room_sequence,i.membership_revision,
                           i.sender_user_id,i.is_mention,i.created_at,i.created_at
                    FROM input i JOIN logged l USING(user_id,source_event_id)
                    WHERE i.message_id IS NOT NULL AND i.sender_user_id<>i.user_id
                )
                SELECT (SELECT count(*) FROM prior WHERE prior_payload IS NOT NULL
                          AND (prior_payload<>payload OR prior_sequence IS NULL OR prior_sequence<=0)) AS conflicts,
                       (SELECT count(*) FROM fresh) AS expected,
                       (SELECT count(*) FROM logged) AS inserted
                """).first(decoding: JournalAppendResult.self)
            guard let result, result.conflicts == 0 else { throw V2UserStateEventError.identityConflict }
            guard result.expected == result.inserted else { throw V2RoomDispatchError.corruptPersistence }
        }
    }
}
private struct JournalAppendResult: Decodable { let conflicts: Int64; let expected: Int64; let inserted: Int64 }
