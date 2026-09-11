import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 房间摘要的 PostgreSQL 读取实现。
///
/// 实现刻意保持成**两个各自有界的查询**，而不是一个覆盖全部房间的巨型 join：
///
/// 1. ``roomActivityWatermarks(after:actorUserID:limit:)`` 只读取排序与计数。它按
///    `rooms.last_event_at DESC, rooms.room_id DESC` 走 `rooms_last_event_at_idx` 顺序，
///    逐房间用 `room_memberships_pkey` 验证当前成员资格，并用
///    `messages_room_sender_sequence_idx` 取"自己最新消息序号"，因此每个房间都是常数级
///    索引查找，不做房间数级别的全量扫描。
/// 2. ``visibleMessages(roomIDs:actorUserID:)`` 只对本页已经取出的房间求最新可见消息。
///    房间集合由调用方限定为页大小，所以这一步的代价只随页大小增长。
///
/// 摘要是**预览**而不是投递：它不承诺补齐，也不承载完整性。无法解码的最新事件只会让
/// 该房间的预览为空，正文仍可经房间日志按游标拉取。
public struct PostgresV2RoomSummaryStore: V2RoomSummaryStore {
    private let database: any Database

    /// 组合数据库。
    ///
    /// - Parameter database: 存放房间、成员关系、消息与已读线的数据库。
    public init(database: any Database) {
        self.database = database
    }

    /// 读取一页房间活动水位。
    ///
    /// 未读数取 `rooms.room_sequence` 与 `MAX(已读线, 自己最新消息序号)` 之差，负数截断为零，
    /// 因此"自己发的消息"不会计为未读，刚加入且从未打开过的房间未读为零。
    ///
    /// - Parameters:
    ///   - cursor: 上一页游标；为空表示从最新活动开始。
    ///   - actorUserID: 发起查询的用户。
    ///   - limit: 本页最多返回的房间数。
    /// - Returns: 按活动倒序排列的有界分页。
    /// - Throws: 条数越界时抛出 ``V2RoomSummaryError/invalidRequest``；
    ///   标识非法或字段无法解码时抛出 ``V2RoomSummaryError/corruptPersistenceState``。
    public func roomActivityWatermarks(
        after cursor: V2RoomSummaryCursor?,
        actorUserID: UserID,
        limit: Int
    ) async throws -> V2RoomActivityPage {
        guard limit > 0, limit <= V2RoomSummaryRequest.maximumPageSize else {
            throw V2RoomSummaryError.invalidRequest
        }
        guard let sql = database as? any SQLDatabase,
              let actorID = actorUserID.uuidValue
        else { throw V2RoomSummaryError.corruptPersistenceState }
        let cursorPredicate: SQLQueryString
        if let cursor {
            guard let cursorRoomID = cursor.roomID.uuidValue else {
                throw V2RoomSummaryError.corruptPersistenceState
            }
            // 键集分页：两个排序键都按降序比较，因此 (last_event_at, room_id) 严格小于
            // 游标即可。它与房间序号、个人时间线序号都没有关系。
            //
            // 游标里的微秒整数经 `TIMESTAMPTZ 'epoch' + N microseconds` 精确还原：
            // 时间戳内部就是整数微秒，这样比较与写入的值逐位相同。用浮点秒或毫秒
            // 还原会让同一毫秒内的房间被跳过。
            cursorPredicate = """
                (room.last_event_at, room.room_id) < (
                    TIMESTAMPTZ 'epoch' + (\(bind: cursor.lastEventAtMicroseconds)::text || ' microseconds')::interval,
                    \(bind: cursorRoomID)
                )
                """
        } else {
            cursorPredicate = "TRUE"
        }
        let rows = try await sql.raw("""
            SELECT room.room_id, room.room_kind, room.room_sequence,
                   (EXTRACT(EPOCH FROM room.last_event_at) * 1000000)::bigint AS last_event_at_micros,
                   COALESCE(receipt.read_through_room_sequence, 0) AS read_through_room_sequence,
                   COALESCE(own_latest.room_sequence, 0) AS own_latest_room_sequence
            FROM im_v2.rooms AS room
            JOIN im_v2.room_memberships AS membership
              ON membership.room_id = room.room_id
             AND membership.user_id = \(bind: actorID)
             AND membership.left_revision IS NULL
             AND membership.joined_revision <= room.membership_revision
            LEFT JOIN im_v2.room_read_receipts AS receipt
              ON receipt.room_id = room.room_id
             AND receipt.user_id = \(bind: actorID)
            LEFT JOIN LATERAL (
                SELECT message.room_sequence
                FROM im_v2.messages AS message
                WHERE message.room_id = room.room_id
                  AND message.sender_user_id = \(bind: actorID)
                ORDER BY message.room_sequence DESC
                LIMIT 1
            ) AS own_latest ON TRUE
            WHERE \(cursorPredicate)
            ORDER BY room.last_event_at DESC, room.room_id DESC
            LIMIT \(bind: limit + 1)
            """).all(decoding: RoomActivityRow.self)
        let hasMore = rows.count > limit
        let page = hasMore ? rows.dropLast() : rows[...]
        let watermarks = try page.map { row -> V2RoomActivityWatermark in
            guard let roomKind = V2RoomKind(rawValue: row.roomKind),
                  row.roomSequence >= 0,
                  row.lastEventAtMicros >= 0,
                  row.readThroughRoomSequence >= 0,
                  row.ownLatestRoomSequence >= 0
            else { throw V2RoomSummaryError.corruptPersistenceState }
            let head = UInt64(row.roomSequence)
            let baseline = max(UInt64(row.readThroughRoomSequence), UInt64(row.ownLatestRoomSequence))
            return V2RoomActivityWatermark(
                roomID: RoomID(uuid: row.roomID),
                roomKind: roomKind,
                head: head,
                lastEventAtMicroseconds: row.lastEventAtMicros,
                unreadCount: head > baseline ? head - baseline : 0
            )
        }
        return V2RoomActivityPage(rooms: watermarks, hasMore: hasMore)
    }

    /// 读取指定房间对指定用户可见的最新消息摘要。
    ///
    /// 可见性谓词与房间事件日志读取完全一致：**事件发生时成员 ∩ 当前成员**。两种接受形态
    /// 都覆盖：房间事件行携带 `committed_membership_revision`，而热点私聊把消息行本身
    /// 当作事件，携带 `accepted_membership_revision`。
    ///
    /// - Parameters:
    ///   - roomIDs: 待查询房间；调用方必须传入有界集合。
    ///   - actorUserID: 发起查询的用户。
    /// - Returns: 每个有可见消息的房间各一条摘要。
    /// - Throws: 房间集合为空或越界时抛出 ``V2RoomSummaryError/invalidRequest``；
    ///   标识非法或字段无法解码时抛出 ``V2RoomSummaryError/corruptPersistenceState``。
    public func visibleMessages(roomIDs: [RoomID], actorUserID: UserID) async throws -> [V2RoomSummaryMessage] {
        guard !roomIDs.isEmpty, roomIDs.count <= V2RoomSummaryRequest.maximumPageSize else {
            throw V2RoomSummaryError.invalidRequest
        }
        guard let sql = database as? any SQLDatabase,
              let actorID = actorUserID.uuidValue
        else { throw V2RoomSummaryError.corruptPersistenceState }
        let ids = try roomIDs.map { roomID -> UUID in
            guard let value = roomID.uuidValue else { throw V2RoomSummaryError.corruptPersistenceState }
            return value
        }
        let legacyVisibility = v2RoomSummaryVisibilityPredicate(
            roomIDExpression: "event.room_id",
            actorUserID: actorID,
            revisionExpression: "event.committed_membership_revision"
        )
        let messageRowVisibility = v2RoomSummaryVisibilityPredicate(
            roomIDExpression: "message.room_id",
            actorUserID: actorID,
            revisionExpression: "message.accepted_membership_revision"
        )
        let rows = try await sql.raw("""
            WITH requested(room_id) AS (
                SELECT value::uuid FROM unnest(\(bind: ids)::uuid[]) AS value
            ),
            latest(room_id, message_id, log_room_sequence) AS (
                -- 每个房间只取一条，而且两个形态各自按房间序号倒序扫描并在第一行停下：
                -- 预览的代价因此是"最近的可见事件"，不是"该房间的全部历史"。
                SELECT requested.room_id, candidate.message_id, candidate.log_room_sequence
                FROM requested
                JOIN LATERAL (
                    SELECT source.message_id, source.log_room_sequence
                    FROM (
                        (
                            -- 房间事件形态：事件行是接受事实，载荷携带消息标识。
                            SELECT (event.payload->>'message_id')::uuid AS message_id,
                                   event.room_sequence AS log_room_sequence
                            FROM im_v2.room_events AS event
                            WHERE event.room_id = requested.room_id
                              AND event.event_type = 'message.accepted'
                              AND event.payload->>'message_id' IS NOT NULL
                              AND \(legacyVisibility)
                            ORDER BY event.room_sequence DESC
                            LIMIT 1
                        )
                        UNION ALL
                        (
                            -- 热点私聊形态：消息行本身即接受事件。
                            SELECT message.message_id, message.room_sequence
                            FROM im_v2.messages AS message
                            WHERE message.room_id = requested.room_id
                              AND message.accepted_event_storage = 'message_row'
                              AND \(messageRowVisibility)
                            ORDER BY message.room_sequence DESC
                            LIMIT 1
                        )
                    ) AS source
                    ORDER BY source.log_room_sequence DESC
                    LIMIT 1
                ) AS candidate ON TRUE
            )
            SELECT latest.room_id, latest.message_id, latest.log_room_sequence,
                   message.room_sequence AS message_room_sequence,
                   message.sender_user_id,
                   left(message.text_body, \(bind: V2RoomSummaryLimits.maximumPreviewCharacters)::integer) AS text_body,
                   message.created_at,
                   message.withdrawn_at,
                   COALESCE(media.total, 0) AS media_count
            FROM latest
            JOIN im_v2.messages AS message ON message.message_id = latest.message_id
            LEFT JOIN LATERAL (
                SELECT count(*) AS total
                FROM im_v2.message_media_references AS reference
                WHERE reference.message_id = latest.message_id
                  AND reference.revoked_at IS NULL
            ) AS media ON TRUE
            """).all(decoding: RoomVisibleMessageRow.self)
        return try rows.map { row in
            guard row.logRoomSequence >= 0,
                  row.messageRoomSequence == row.logRoomSequence,
                  row.mediaCount >= 0
            else { throw V2RoomSummaryError.corruptPersistenceState }
            return V2RoomSummaryMessage(
                roomID: RoomID(uuid: row.roomID),
                messageID: MessageID(uuid: row.messageID),
                senderUserID: UserID(uuid: row.senderUserID),
                roomSequence: UInt64(row.messageRoomSequence),
                text: row.textBody,
                isWithdrawn: row.withdrawnAt != nil,
                mediaCount: Int(row.mediaCount),
                serverCreatedAt: row.createdAt
            )
        }
    }
}

/// "事件发生时成员 ∩ 当前成员"的可见性谓词。
///
/// 谓词与 ``PostgresV2GroupEventLogStore`` 的房间日志读取共用同一规则：加入修订必须不晚于
/// 事件提交时的成员修订，且该成员尚未在该修订上离开。两侧都放宽会让摘要在用户无权
/// 查看的历史上泄漏正文；任何一侧收紧则会让摘要比日志少显示内容。改动必须同时验证两处。
///
/// - Parameters:
///   - roomIDExpression: 已绑定的房间标识表达式。
///   - actorUserID: 发起查询的用户。
///   - revisionExpression: 事件提交时的成员修订表达式。
/// - Returns: 可直接嵌入 `WHERE` 的可见性谓词。
private func v2RoomSummaryVisibilityPredicate(
    roomIDExpression: SQLQueryString,
    actorUserID: UUID,
    revisionExpression: SQLQueryString
) -> SQLQueryString {
    """
    EXISTS (
        SELECT 1 FROM im_v2.room_memberships AS membership
        WHERE membership.room_id = \(roomIDExpression)
          AND membership.user_id = \(bind: actorUserID)
          AND membership.joined_revision <= \(revisionExpression)
          AND (membership.left_revision IS NULL
               OR membership.left_revision > \(revisionExpression))
    )
    """
}

private struct RoomActivityRow: Decodable {
    let roomID: UUID
    let roomKind: String
    let roomSequence: Int64
    let lastEventAtMicros: Int64
    let readThroughRoomSequence: Int64
    let ownLatestRoomSequence: Int64
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", roomKind = "room_kind", roomSequence = "room_sequence"
        case lastEventAtMicros = "last_event_at_micros"
        case readThroughRoomSequence = "read_through_room_sequence"
        case ownLatestRoomSequence = "own_latest_room_sequence"
    }
}

private struct RoomVisibleMessageRow: Decodable {
    let roomID: UUID
    let messageID: UUID
    let logRoomSequence: Int64
    let messageRoomSequence: Int64
    let senderUserID: UUID
    let textBody: String
    let createdAt: Date
    let withdrawnAt: Date?
    let mediaCount: Int64
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", messageID = "message_id"
        case logRoomSequence = "log_room_sequence", messageRoomSequence = "message_room_sequence"
        case senderUserID = "sender_user_id", textBody = "text_body"
        case createdAt = "created_at", withdrawnAt = "withdrawn_at", mediaCount = "media_count"
    }
}
