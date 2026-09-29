import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import PostgresNIO
import SQLKit

/// 判断错误是否为发送完成记录的竞争冲突。
///
/// 条件追加可能在单条语句内等待操作栅栏，同时保留更早的语句快照。只有这几类精确的
/// 操作键冲突才意味着「应改走已完成命令路径重试」；其他唯一约束或编程错误必须照常暴露。
///
/// - Parameter error: 待判断的错误。
/// - Returns: 属于发送完成主键或消息唯一键冲突时为 `true`。
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

/// 所有列式与 JSON 房间日志写入图共用的追加片段。
///
/// 输入携带已校验的命令指纹；序号与时间来自 `INSERT ... RETURNING`，成员修订来自已加锁的
/// 输入或分配结果。锁查询跟随并发更新之后，不得再用语句的更旧 MVCC 快照重读房间。
/// 该片段始终与消息写入处于同一语句和同一事务。
let v2DirectRoomLogSendCompletionCTE = roomLogSendCompletionCTE(isGroup: false)
/// 混合大群房间日志写入使用的追加片段。
let v2HybridGroupSendCompletionCTE = roomLogSendCompletionCTE(isGroup: true)
/// 私聊快速路径使用的追加片段，成员修订取自已分配结果。
let v2FastDirectRoomLogSendCompletionCTE = roomLogSendCompletionCTE(
    isGroup: false, acceptedSource: "eligible", membershipColumn: "expected_membership_revision"
)
let v2ConditionalHybridGroupSendCompletionCTE = roomLogSendCompletionCTE(
    isGroup: true, acceptedSource: "allocated"
)

private func roomLogSendCompletionCTE(
    isGroup: Bool, acceptedSource: String = "input", membershipColumn: String = "membership_revision"
) -> String {
    let groupMode = isGroup ? "'large'::text" : "NULL::text"
    let recipient = isGroup ? "NULL::uuid" : """
        CASE WHEN pair.lower_user_id = message.sender_user_id THEN pair.higher_user_id
             WHEN pair.higher_user_id = message.sender_user_id THEN pair.lower_user_id END
        """
    let pairJoin = isGroup ? "" : "LEFT JOIN im_v2.direct_room_pairs AS pair ON pair.room_id = message.room_id"
    let membershipSource = acceptedSource == "input" ? "input" : "accepted"
    let acceptedJoin = acceptedSource == "input" ? "" : "JOIN \(acceptedSource) AS accepted ON accepted.message_id = message.message_id"
    // 消息变更会推进事件流，但不分配新的时间线条目。两个游标分叉时，
    // 保留完整的已接受事件，不强制套用消息行格式的序号相等约束。
    // 已接受事件以完成锁定和分配的 CTE 为来源，绝不从旧快照重新读取房间。
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
             group_capacity_class, direct_recipient_user_id, created_at)
        SELECT message.room_id, message.sender_user_id, message.client_message_id,
               input.fingerprint_version, input.request_fingerprint,
               message.message_id, input.event_id, message.room_sequence,
               message.timeline_sequence, \(membershipSource).\(membershipColumn),
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
    , completion_insert AS (
        INSERT INTO im_v2.message_send_completions
            (room_id, sender_user_id, client_message_id,
             fingerprint_version, request_fingerprint, message_id, event_id,
             room_sequence, timeline_sequence, accepted_membership_revision,
             group_capacity_class, direct_recipient_user_id, created_at)
        SELECT message.room_id, message.sender_user_id, message.client_message_id,
               \(bind: Int16(fingerprint.version)), \(bind: fingerprint.digest),
               message.message_id, \(bind: eventID), message.room_sequence,
               message.timeline_sequence, \(bind: acceptedMembershipRevision),
               \(bind: groupCapacityClass?.rawValue),
               CASE WHEN pair.lower_user_id = message.sender_user_id THEN pair.higher_user_id
                    WHEN pair.higher_user_id = message.sender_user_id THEN pair.lower_user_id END,
               message.created_at
        FROM message_insert AS message
        LEFT JOIN im_v2.direct_room_pairs AS pair ON pair.room_id = message.room_id
        RETURNING message_id
    )
    """
}
