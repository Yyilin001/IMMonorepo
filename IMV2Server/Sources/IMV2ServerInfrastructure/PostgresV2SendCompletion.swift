import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import PostgresNIO
import SQLKit

func roomLogSendCompletionCTE(
    isGroup: Bool, acceptedSource: String = "input", membershipColumn: String = "membership_revision",
    recipientFromInput: Bool = false, metadataFromInput: Bool = false,
    persistRoomEvents: Bool
) -> String {
    let groupMode = isGroup ? "'large'::text" : "NULL::text"
    let recipient = isGroup ? "NULL::uuid" : recipientFromInput ? "input.direct_recipient_id" : """
        CASE WHEN pair.lower_user_id = message.sender_user_id THEN pair.higher_user_id
             WHEN pair.higher_user_id = message.sender_user_id THEN pair.lower_user_id END
        """
    let pairJoin = (isGroup || recipientFromInput) ? "" : "LEFT JOIN im_v2.direct_room_pairs AS pair ON pair.room_id = message.room_id"
    let membershipSource = acceptedSource == "input" ? "input" : "accepted"
    let acceptedJoin = acceptedSource == "input" ? "" : "JOIN \(acceptedSource) AS accepted ON accepted.message_id = message.message_id"
    let metadataCTE = metadataFromInput ? "" : V2SendSuccessMetadata.cte
    let metadataJoin = metadataFromInput ? "" : V2SendSuccessMetadata.join
    let metadataSource = metadataFromInput ? "input" : "metadata"
    // 消息变更会推进事件流，但不分配新的时间线条目。两个游标分叉时，
    // 保留完整的已接受事件，不强制套用消息行格式的序号相等约束。
    // 已接受事件以完成锁定和分配的 CTE 为来源，绝不从旧快照重新读取房间。
    // 序号一致的批次全部由消息行承载事件，省掉空 INSERT 及其语句级触发器。
    let eventCTE = persistRoomEvents ? """
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
    )
    """ : ""
    return """
    \(eventCTE)
    \(metadataCTE)
    , completion_insert AS (
        INSERT INTO im_v2.message_send_completions
            (room_id, sender_user_id, client_message_id,
             fingerprint_version, request_fingerprint, message_id, event_id,
             room_sequence, timeline_sequence, accepted_membership_revision,
             group_capacity_class, direct_recipient_user_id, created_at,
             operation_fingerprint, operation_resolved_at_ms)
        SELECT message.room_id, message.sender_user_id, message.client_message_id,
               input.fingerprint_version, input.request_fingerprint,
               message.message_id, input.event_id, message.room_sequence,
               message.timeline_sequence, \(membershipSource).\(membershipColumn),
               \(groupMode), \(recipient),
               message.created_at, \(metadataSource).operation_fingerprint, \(metadataSource).operation_resolved_at_ms
        FROM message_insert AS message
        JOIN input ON input.message_id = message.message_id
        \(acceptedJoin)
        \(pairJoin)
        \(metadataJoin)
        RETURNING message_id
    )
    """
}

/// 面向更丰富内容路径的标量等价实现。
///
/// 完成台账中不保留正文、实体 URL、媒体展示信息或当前投影。
func v2SendCompletionCTE(
    fingerprint: V2SendMessageFingerprint,
    eventID: UUID,
    acceptedMembershipRevision: Int64,
    groupCapacityClass: V2GroupCapacityClass?
) -> SQLQueryString {
    """
    \(unsafeRaw: V2SendSuccessMetadata.cte)
    , completion_insert AS (
        INSERT INTO im_v2.message_send_completions
            (room_id, sender_user_id, client_message_id,
             fingerprint_version, request_fingerprint, message_id, event_id,
             room_sequence, timeline_sequence, accepted_membership_revision,
             group_capacity_class, direct_recipient_user_id, created_at,
             operation_fingerprint, operation_resolved_at_ms)
        SELECT message.room_id, message.sender_user_id, message.client_message_id,
               \(bind: Int16(fingerprint.version)), \(bind: fingerprint.digest),
               message.message_id, \(bind: eventID), message.room_sequence,
               message.timeline_sequence, \(bind: acceptedMembershipRevision),
               \(bind: groupCapacityClass?.rawValue),
               CASE WHEN pair.lower_user_id = message.sender_user_id THEN pair.higher_user_id
                    WHEN pair.higher_user_id = message.sender_user_id THEN pair.lower_user_id END,
               message.created_at,
               metadata.operation_fingerprint,
               metadata.operation_resolved_at_ms
        FROM message_insert AS message
        LEFT JOIN im_v2.direct_room_pairs AS pair ON pair.room_id = message.room_id
        \(unsafeRaw: V2SendSuccessMetadata.join)
        RETURNING message_id
    )
    """
}
