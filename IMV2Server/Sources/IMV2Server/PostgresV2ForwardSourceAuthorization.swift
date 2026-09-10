import Foundation
import SQLKit

/// 转发、引用与媒体调用方共用的来源可见性谓词，要求外部绑定 `message` 与 `room` 别名。
///
/// 历史成员关系与当前成员关系是两个独立区间：重新入群的用户可以读取更早区间的消息，
/// 但绝不能读取中间空档期的消息。缺少已接受凭据时一律拒绝，不会退回用当前成员关系兜底。
/// 已接受的权威来自不可变完成主键，载荷存放位置与其修订的物理兼容副本都不构成权威。
///
/// 除成员区间外，还会校验正文修订：修订为 1 直接通过，否则必须存在与该修订匹配的编辑事件，
/// 以确认请求者在该次编辑提交时同样具备成员资格。
///
/// - Parameter actorID: 发起访问的用户标识。
/// - Returns: 可直接嵌入查询的可见性条件 SQL 片段。
func v2ForwardSourceVisibility(actorID: UUID) -> SQLQueryString {
    """
    EXISTS (
        SELECT 1 FROM im_v2.room_memberships AS current_membership
        WHERE current_membership.room_id = message.room_id
          AND current_membership.user_id = \(bind: actorID)
          AND current_membership.joined_revision <= room.membership_revision
          AND (current_membership.left_revision IS NULL
               OR current_membership.left_revision > room.membership_revision)
    )
    AND EXISTS (
        SELECT 1 FROM im_v2.room_memberships AS historical_membership
        WHERE historical_membership.room_id = message.room_id
          AND historical_membership.user_id = \(bind: actorID)
          AND historical_membership.joined_revision <= (
              \(unsafeRaw: v2ForwardAcceptedMembershipRevision)
          )
          AND (historical_membership.left_revision IS NULL
               OR historical_membership.left_revision > (
                   \(unsafeRaw: v2ForwardAcceptedMembershipRevision)
               ))
    )
    AND (
        message.content_revision = 1
        OR EXISTS (
            SELECT 1
            FROM im_v2.room_events AS content_event
            JOIN im_v2.room_memberships AS content_membership
              ON content_membership.room_id = content_event.room_id
             AND content_membership.user_id = \(bind: actorID)
             AND content_membership.joined_revision <= content_event.committed_membership_revision
             AND (content_membership.left_revision IS NULL
                  OR content_membership.left_revision > content_event.committed_membership_revision)
            WHERE content_event.room_id = message.room_id
              AND content_event.event_type = 'message.edited'
              AND lower(content_event.payload->>'message_id') = message.message_id::text
              AND content_event.payload->>'message_revision' = message.content_revision::text
              AND lower(content_event.payload->>'room_id') = message.room_id::text
        )
    )
    """
}

private let v2ForwardAcceptedMembershipRevision = """
SELECT completion.accepted_membership_revision
FROM im_v2.message_send_completions AS completion
WHERE completion.room_id = message.room_id
  AND completion.sender_user_id = message.sender_user_id
  AND completion.client_message_id = message.client_message_id
  AND completion.message_id = message.message_id
  AND completion.room_sequence = message.room_sequence
  AND completion.room_sequence > 0
  AND completion.accepted_membership_revision >= 0
"""

/// 在目标准入或消息加锁之前，先按固定顺序取得本次转发涉及的全部房间锁。
///
/// 成员变更、编辑与撤回同样从房间锁开始，因此相向而行的两次转发会按房间标识的 UUID 顺序串行，
/// 不会出现一方持有目标房间却等待另一方源房间的反向等待。
/// 源消息缺失时返回 `nil` 而不报错，使已持久化完成的发送仍可重放；
/// 真正的新命令会在最终来源校验中失败。
///
/// - Parameters:
///   - sourceMessageID: 源消息标识。
///   - targetRoomID: 目标房间标识。
///   - sql: 当前事务使用的数据库连接。
/// - Returns: 源消息所在房间标识；源消息不存在时为 `nil`。
/// - Throws: 查询失败时抛出。
func v2LockForwardRooms(
    sourceMessageID: UUID,
    targetRoomID: UUID,
    sql: any SQLDatabase
) async throws -> UUID? {
    let source = try await sql.raw("""
        SELECT room_id FROM im_v2.messages WHERE message_id = \(bind: sourceMessageID)
        """).first(decoding: ForwardRoomIDRow.self)
    let sourceRoomID = source?.roomID
    _ = try await sql.raw("""
        SELECT room_id FROM im_v2.rooms
        WHERE room_id = \(bind: targetRoomID) OR room_id = \(bind: sourceRoomID)
        ORDER BY room_id FOR UPDATE
        """).all(decoding: ForwardRoomIDRow.self)
    return sourceRoomID
}

private struct ForwardRoomIDRow: Decodable {
    let roomID: UUID
    enum CodingKeys: String, CodingKey { case roomID = "room_id" }
}
