import Foundation
import IMV2Core
import PostgresNIO
import SQLKit

/// A conditional append can wait for the operation fence inside its single
/// statement while retaining the older statement snapshot. Only these exact
/// operation-key collisions mean "retry through the completed-command path";
/// unrelated uniqueness/programming failures must still surface normally.
func v2IsSendCompletionRace(_ error: any Error) -> Bool {
    let state: String?
    let constraint: String?
    if let error = error as? PSQLError {
        state = error.serverInfo?[.sqlState]
        constraint = error.serverInfo?[.constraintName]
    } else if let error = error as? PostgresError, case .server(let message) = error {
        state = message.fields[.sqlState]
        constraint = message.fields[.constraintName]
    } else { return false }
    return state == "23505" && [
        "message_send_completions_pkey", "messages_room_sender_client_key"
    ].contains(constraint ?? "")
}

/// Shared append fragment for all columnar/JSON room-log write graphs. Input
/// carries the validated command fingerprint. Sequence/time come from INSERT
/// RETURNING and membership comes from the locked input/allocation. Do not
/// re-read rooms through a statement's
/// older MVCC snapshot after its lock query has followed a concurrent update.
/// This stays inside the same statement and transaction as the message write.
let v2DirectRoomLogSendCompletionCTE = roomLogSendCompletionCTE(isGroup: false)
let v2HybridGroupSendCompletionCTE = roomLogSendCompletionCTE(isGroup: true)
let v2FastDirectRoomLogSendCompletionCTE = roomLogSendCompletionCTE(
    isGroup: false, acceptedSource: "eligible", membershipColumn: "expected_membership_revision"
)
let v2ConditionalHybridGroupSendCompletionCTE = roomLogSendCompletionCTE(
    isGroup: true, acceptedSource: "allocated"
)

private func roomLogSendCompletionCTE(
    isGroup: Bool, acceptedSource: String = "input", membershipColumn: String = "membership_revision"
) -> String {
    let groupMode = isGroup ? "'large_group_hybrid'::text" : "NULL::text"
    let recipient = isGroup ? "NULL::uuid" : """
        CASE WHEN pair.lower_user_id = message.sender_user_id THEN pair.higher_user_id
             WHEN pair.higher_user_id = message.sender_user_id THEN pair.lower_user_id END
        """
    let pairJoin = isGroup ? "" : "LEFT JOIN im_v2.direct_room_pairs AS pair ON pair.room_id = message.room_id"
    let membershipSource = acceptedSource == "input" ? "input" : "accepted"
    let acceptedJoin = acceptedSource == "input" ? "" : "JOIN \(acceptedSource) AS accepted ON accepted.message_id = message.message_id"
    // Message mutations advance the event stream without allocating a new timeline
    // item. When the two cursors diverge, preserve the full accepted event instead
    // of forcing the message-row format's equal-sequence invariant. The accepted
    // source is the locked/allocated CTE, never a room re-read from an older snapshot.
    return """
    , event_insert AS (
        INSERT INTO im_v2.room_events
            (event_id, room_id, room_sequence, event_type, actor_user_id, payload,
             committed_membership_revision, created_at)
        SELECT accepted.event_id, message.room_id, message.room_sequence,
               'message.accepted', message.sender_user_id,
               jsonb_build_object(
                   'event_type', 'message.accepted',
                   'message_id', upper(message.message_id::text),
                   'room_id', upper(message.room_id::text),
                   'room_sequence', message.room_sequence,
                   'timeline_sequence', message.timeline_sequence,
                   'sender_user_id', upper(message.sender_user_id::text),
                   'text', message.text_body,
                   'media_ids', '[]'::jsonb, 'media_presentations', '[]'::jsonb,
                   'mention_user_ids', '[]'::jsonb, 'mentions_everyone', false,
                   'entities', message.rich_entities,
                   'reply_to_message_id', upper(message.reply_to_message_id::text),
                   'forwarded_from_message_id', upper(message.forwarded_from_message_id::text),
                   'forwarded_from_user_id', upper(message.forwarded_from_user_id::text),
                   'message_revision', 1,
                   'server_created_at_ms', floor(extract(epoch FROM message.created_at) * 1000)::bigint
               ), accepted.\(membershipColumn), message.created_at
        FROM message_insert AS message
        JOIN \(acceptedSource) AS accepted ON accepted.message_id = message.message_id
        WHERE message.accepted_event_storage = 'room_event'
        RETURNING event_id
    ), completion_insert AS (
        INSERT INTO im_v2.message_send_completions
            (room_id, sender_user_id, client_message_id,
             fingerprint_version, request_fingerprint, message_id, event_id,
             room_sequence, timeline_sequence, accepted_membership_revision,
             delivery_authority, group_delivery_mode, direct_recipient_user_id, created_at)
        SELECT message.room_id, message.sender_user_id, message.client_message_id,
               input.fingerprint_version, input.request_fingerprint,
               message.message_id, input.event_id, message.room_sequence,
               message.timeline_sequence, \(membershipSource).\(membershipColumn), 'room_log',
               \(groupMode), \(recipient),
               message.created_at
        FROM message_insert AS message
        JOIN input ON input.message_id = message.message_id
        \(acceptedJoin)
        \(pairJoin)
        RETURNING message_id
    )
    """
}

/// Scalar equivalent for richer content paths. No body, entity URL, media
/// presentation or current projection is retained in the completion ledger.
func v2SendCompletionCTE(
    fingerprint: V2SendMessageFingerprint,
    eventID: UUID,
    acceptedMembershipRevision: Int64,
    groupDeliveryMode: V2GroupDeliveryMode?,
    usesRoomEventLog: Bool
) -> SQLQueryString {
    """
    , completion_insert AS (
        INSERT INTO im_v2.message_send_completions
            (room_id, sender_user_id, client_message_id,
             fingerprint_version, request_fingerprint, message_id, event_id,
             room_sequence, timeline_sequence, accepted_membership_revision,
             delivery_authority, group_delivery_mode, direct_recipient_user_id, created_at)
        SELECT message.room_id, message.sender_user_id, message.client_message_id,
               \(bind: Int16(fingerprint.version)), \(bind: fingerprint.digest),
               message.message_id, \(bind: eventID), message.room_sequence,
               message.timeline_sequence, \(bind: acceptedMembershipRevision),
               \(bind: usesRoomEventLog ? "room_log" : "personal"),
               \(bind: groupDeliveryMode?.rawValue),
               CASE WHEN pair.lower_user_id = message.sender_user_id THEN pair.higher_user_id
                    WHEN pair.higher_user_id = message.sender_user_id THEN pair.lower_user_id END,
               message.created_at
        FROM message_insert AS message
        LEFT JOIN im_v2.direct_room_pairs AS pair ON pair.room_id = message.room_id
        RETURNING message_id
    )
    """
}
