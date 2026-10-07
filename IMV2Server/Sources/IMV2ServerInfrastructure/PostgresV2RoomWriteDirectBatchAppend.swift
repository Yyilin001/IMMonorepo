import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import SQLKit

// 仅在 Store 借用的事务中完成成员资格检查后调用。
// 此组件既不拥有事务，也不负责额度结算。
enum PlainDirectRoomLogBatchWritePath {
    static func persist(
        inputs: [PlainRoomLogMessageInput],
        sql: any SQLDatabase,
        operationReceipts: [V2DurableSendBatchPermanentReceipt]? = nil
    ) async throws {
        let completionCTE = roomLogSendCompletionCTE(isGroup: false,
            recipientFromInput: inputs.allSatisfy({ $0.directRecipientID != nil }), metadataFromInput: true)
        guard !inputs.isEmpty, inputs.count <= 256 else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let metadata = Dictionary(V2SendSuccessMetadata.current.map {
            ("\($0.room):\($0.sender):\($0.operation)", $0)
        }, uniquingKeysWith: { first, _ in first })
        let values = try inputs.map { input -> SQLQueryString in
            let success = metadata["\(input.roomID):\(input.senderID):\(input.clientMessageID)"]
            guard let fingerprintVersion = Int16(exactly: input.fingerprint.version) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            // JSON remains only for the existing JSONB entities column.
            let entities: SQLQueryString = input.entities.isEmpty
                ? "'[]'::jsonb" : "\(bind: try roomWriteJSON(input.entities))::jsonb"
            return """
                (\(bind: input.ordinal)::integer, \(bind: input.roomID)::uuid,
                 \(bind: input.messageID)::uuid, \(bind: fingerprintVersion)::smallint,
                 \(bind: input.fingerprint.digest)::bytea, \(bind: input.eventID)::uuid,
                 \(bind: input.senderID)::uuid, \(bind: input.clientMessageID)::uuid,
                 \(bind: input.roomSequence)::bigint, \(bind: input.timelineSequence)::bigint,
                 \(bind: input.runtimeGuard != nil)::boolean,
                 \(bind: input.runtimeGuard?.capacityProfileID)::text,
                 \(bind: input.directRecipientID)::uuid, \(bind: input.text)::text, \(entities),
                 \(bind: input.replyToMessageID)::uuid, \(bind: input.forwardedFromMessageID)::uuid,
                 \(bind: input.forwardedFromUserID)::uuid, \(bind: input.membershipRevision)::bigint,
                 \(bind: input.createdAtPostgresMicroseconds)::bigint,
                 \(bind: success?.fingerprint)::bytea, \(bind: success.map { Int64($0.resolvedAt) })::bigint)
                """
        }
        let typedValues = SQLList(values.map { $0 as any SQLExpression })
        let expectedCount = Int64(inputs.count)
        let expectedRoomCount = Int64(Set(inputs.map(\.roomID)).count)
        if let operationReceipts {
            try PostgresV2DurableSendBatchReceipts().validateAcknowledgments(operationReceipts, messages: inputs)
        }
        guard let row = try await sql.raw("""
            /* imv2_plain_direct_append */
            WITH typed_input(
                ordinal, room_id, message_id, fingerprint_version, request_fingerprint,
                event_id, sender_id, client_message_id, room_sequence, timeline_sequence,
                has_runtime_guard,
                runtime_capacity_profile_id, direct_recipient_id,
                text_body, rich_entities, reply_to_message_id, forwarded_from_message_id,
                forwarded_from_user_id, membership_revision, created_at_postgres_microseconds,
                operation_fingerprint, operation_resolved_at_ms
            ) AS (VALUES \(typedValues)), input AS MATERIALIZED (
                SELECT typed_input.*,
                       ((TIMESTAMP '2000-01-01 00:00:00'
                         + (created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC') AS created_at
                FROM typed_input
            ), final_room_input AS MATERIALIZED (
                SELECT DISTINCT ON (room_id) *
                FROM input
                ORDER BY room_id, ordinal DESC
            ), first_room_input AS MATERIALIZED (
                SELECT DISTINCT ON (room_id) * FROM input ORDER BY room_id, ordinal
            ), room_update AS (
                UPDATE im_v2.rooms AS room
                SET room_sequence = input.room_sequence,
                    timeline_sequence = input.timeline_sequence
                FROM final_room_input AS input
                JOIN first_room_input AS first ON first.room_id=input.room_id
                WHERE room.room_id = input.room_id
                  AND (NOT input.has_runtime_guard OR (
                      room.room_sequence=first.room_sequence-1
                      AND room.timeline_sequence=first.timeline_sequence-1
                      AND room.membership_revision=input.membership_revision
                      AND room.capacity_profile_id=input.runtime_capacity_profile_id
                      AND room.room_kind='direct' AND room.frozen_at IS NULL
                  ))
                RETURNING room.room_id
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
                JOIN room_update ON room_update.room_id = input.room_id
                RETURNING *
            )
            \(unsafeRaw: completionCTE)
            SELECT (SELECT count(*) FROM room_update) AS room_count,
                   (SELECT count(*) FROM room_update) AS admission_count,
                   (SELECT count(*) FROM message_insert) AS message_count,
                   0::bigint AS review_count,
                   0::bigint AS media_count,
                   0::bigint AS mention_count,
                   -- A plain direct accepted event is now materialized by
                   -- the message row itself.  Keep this cardinality fence so
                   -- callers still reject a partial set append.
                   (SELECT count(*) FROM message_insert) AS event_count,
                   (SELECT count(*) FROM completion_insert) AS completion_count
            """).first() else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let mutation = try row.decode(model: RoomLogMessageMutationRow.self)
        guard try row.decode(column: "completion_count", as: Int64.self) == expectedCount,
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
