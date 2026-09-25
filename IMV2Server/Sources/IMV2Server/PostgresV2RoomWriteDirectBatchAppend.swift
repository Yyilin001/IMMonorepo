import Foundation
import SQLKit

// 仅在 Store 借用的事务中完成成员资格检查后调用。
// 此组件既不拥有事务，也不负责额度结算。
enum PlainDirectRoomLogBatchWritePath {
    static func persist(
        inputs: [PlainRoomLogMessageInput],
        sql: any SQLDatabase
    ) async throws {
        let inputsJSON = try roomWriteJSON(inputs)
        let expectedCount = Int64(inputs.count)
        let expectedRoomCount = Int64(Set(inputs.map(\.roomID)).count)
        guard let mutation = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT input.ordinal, input.room_id, input.message_id,
                       (input.fingerprint->>'version')::smallint AS fingerprint_version,
                       decode(input.fingerprint->>'digest', 'base64') AS request_fingerprint,
                       input.event_id, input.sender_id, input.client_message_id,
                       input.room_sequence, input.timeline_sequence,
                       input.command_window_used, input.persists_room_admission,
                       input.text_body,
                       input.rich_entities, input.reply_to_message_id,
                       input.forwarded_from_message_id,
                       input.forwarded_from_user_id,
                       input.membership_revision,
                       input.created_at_postgres_microseconds,
                       ((TIMESTAMP '2000-01-01 00:00:00'
                         + (input.created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (input.created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC') AS created_at
                FROM jsonb_to_recordset(\(bind: inputsJSON)::jsonb) AS input(
                    ordinal integer,
                    room_id uuid,
                    message_id uuid,
                    event_id uuid,
                    sender_id uuid,
                    client_message_id uuid,
                    room_sequence bigint,
                    timeline_sequence bigint,
                    command_window_used bigint,
                    persists_room_admission boolean,
                    text_body text,
                    rich_entities jsonb,
                    reply_to_message_id uuid,
                    forwarded_from_message_id uuid,
                    forwarded_from_user_id uuid,
                    membership_revision bigint,
                    fingerprint jsonb,
                    created_at_postgres_microseconds bigint
                )
            ), final_room_input AS MATERIALIZED (
                SELECT DISTINCT ON (room_id) *
                FROM input
                ORDER BY room_id, ordinal DESC
            ), room_update AS (
                UPDATE im_v2.rooms AS room
                SET room_sequence = input.room_sequence,
                    timeline_sequence = input.timeline_sequence
                FROM final_room_input AS input
                WHERE room.room_id = input.room_id
                RETURNING room.room_id
            ), admission_update AS (
                UPDATE im_v2.room_admission AS admission
                SET command_window_used = input.command_window_used
                FROM final_room_input AS input
                JOIN room_update ON room_update.room_id = input.room_id
                WHERE admission.room_id = input.room_id
                  AND input.persists_room_admission
                RETURNING admission.room_id
            ), admission_passthrough AS (
                SELECT room_update.room_id FROM room_update
                JOIN final_room_input AS input ON input.room_id = room_update.room_id
                WHERE NOT input.persists_room_admission
            ), admission_gate AS (
                SELECT room_id FROM admission_update
                UNION ALL
                SELECT room_id FROM admission_passthrough
            ), message_insert AS (
                INSERT INTO im_v2.messages
                    (message_id, room_id, room_sequence, timeline_sequence, sender_user_id,
                     client_message_id, text_body, rich_entities, reply_to_message_id,
                     forwarded_from_message_id, forwarded_from_user_id, created_at,
                     accepted_event_id, accepted_event_storage,
                     accepted_membership_revision)
                SELECT input.message_id, input.room_id, input.room_sequence,
                       input.timeline_sequence, input.sender_id,
                       input.client_message_id, input.text_body,
                       input.rich_entities, input.reply_to_message_id,
                       input.forwarded_from_message_id,
                       input.forwarded_from_user_id, input.created_at,
                       CASE WHEN input.room_sequence = input.timeline_sequence THEN input.event_id END,
                   CASE WHEN input.room_sequence = input.timeline_sequence THEN 'message_row' ELSE 'room_event' END,
                   CASE WHEN input.room_sequence = input.timeline_sequence THEN input.membership_revision END
                FROM input
                JOIN admission_gate ON admission_gate.room_id = input.room_id
                RETURNING *
            )
            \(unsafeRaw: v2DirectRoomLogSendCompletionCTE)
            SELECT (SELECT count(*) FROM room_update) AS room_count,
                   (SELECT count(*) FROM admission_gate) AS admission_count,
                   (SELECT count(*) FROM message_insert) AS message_count,
                   0::bigint AS review_count,
                   0::bigint AS media_count,
                   0::bigint AS mention_count,
                   -- A plain direct accepted event is now materialized by
                   -- the message row itself.  Keep this cardinality fence so
                   -- callers still reject a partial set append.
                   (SELECT count(*) FROM message_insert) AS event_count
            """).first(decoding: RoomLogMessageMutationRow.self),
              mutation.roomCount == expectedRoomCount,
              mutation.admissionCount == expectedRoomCount,
              mutation.messageCount == expectedCount,
              mutation.reviewCount == 0,
              mutation.mediaCount == 0,
              mutation.mentionCount == 0,
              mutation.eventCount == expectedCount
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }
}
