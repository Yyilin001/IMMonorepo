import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 房间事件日志的 PostgreSQL 存储实现。
///
/// 它同时服务群房间与私聊房间：私聊路径只有在用户对与成员策略接受该写入之后才会进入，
/// 并且每次拉取仍会校验成员修订栅栏，因此陈旧唤醒无法泄漏入群前或退群后的载荷。
public struct PostgresV2GroupEventLogStore: V2PreparedGroupEventLogStore {
    private let database: any Database
    private let directRoomLogEventCache: V2DirectRoomLogEventCache?

    /// 组合数据库与可选的私聊日志缓存。
    ///
    /// - Parameters:
    ///   - database: 存放房间事件与成员关系的数据库。
    ///   - directRoomLogEventCache: 私聊日志加速缓存，可选。
    public init(
        database: any Database,
        directRoomLogEventCache: V2DirectRoomLogEventCache? = nil
    ) {
        self.database = database
        self.directRoomLogEventCache = directRoomLogEventCache
    }

    /// 按房间序号拉取一页事件。
    ///
    /// 起始序号需可表示为合法游标，分页大小需落在服务上限内；
    /// 拉取前会校验房间存在性与发起者的当前成员资格。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起拉取的用户。
    ///   - afterRoomSequence: 起始序号。
    ///   - pageSize: 本页条数。
    /// - Returns: 事件分页。
    /// - Throws: 参数越界时抛出 ``V2GroupEventLogError/invalidRequest``；
    ///   标识非法或连接不支持 SQL 时抛出
    ///   ``V2GroupEventLogError/corruptPersistenceState``；房间不存在或发起者非成员时抛出对应错误。
    public func pull(roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2GroupEventLogPage {
        guard let cursor = try? V2RoomCursor(afterRoomSequence),
              (1 ... V2GroupEventLogService.maximumPageSize).contains(pageSize)
        else { throw V2GroupEventLogError.invalidRequest }
        guard let sql = database as? any SQLDatabase,
              let roomUUID = UUID(uuidString: roomID.rawValue),
              let actorUUID = UUID(uuidString: actorUserID.rawValue)
        else { throw V2GroupEventLogError.corruptPersistenceState }

        // Inspect only local coverage before spending a database round trip on
        // the cache path. A candidate contains no identity and is never
        // returned without the same fresh durable membership fence as before.
        // A definite local miss therefore goes straight to the complete,
        // authorization-bearing query below instead of paying two SQL calls.
        if let directRoomLogEventCache,
           let candidate = await directRoomLogEventCache.candidate(
               roomID: roomID,
               afterRoomSequence: afterRoomSequence,
               pageSize: pageSize
           ) {
            if let access = try await authorizedRoomCacheAccess(
                roomID: roomUUID,
                actorUserID: actorUUID,
                sql: sql
            ), // 被保留裁剪过的房间不再走进程内缓存：缓存里可能仍留有已经删除的历史，
               // 而且只有持久查询能回报"历史不完整"的下界。
               access.trimmedThroughRoomSequence == 0 {
                if let cached = await directRoomLogEventCache.page(
                    candidate: candidate,
                    actorJoinedRevision: try groupEventUnsigned(access.actorJoinedRevision),
                    actorLeftRevision: try access.actorLeftRevision.map(groupEventUnsigned),
                    currentHighWatermark: try groupEventUnsigned(access.roomSequence)
                ) {
                    return cached
                }
            } else {
                await directRoomLogEventCache.recordMiss(roomID: roomID)
            }
        }

        let acceptedDelivery = v2MessageAcceptedDeliveryQuery(
            messageID: "CASE WHEN event.event_type IN ('message.edited', 'message.withdrawn', 'message.reaction_changed') THEN (event.payload->>'message_id')::uuid ELSE NULL END",
            roomID: "event.room_id"
        )
        let rows = try await sql.raw("""
            WITH room AS MATERIALIZED (
                SELECT rooms.room_sequence, rooms.room_kind,
                       rooms.log_trimmed_through_room_sequence,
                       EXISTS (
                           SELECT 1 FROM im_v2.room_memberships AS membership
                           WHERE membership.room_id = rooms.room_id
                             AND membership.user_id = \(bind: actorUUID)
                             AND membership.joined_revision <= rooms.membership_revision
                             AND (membership.left_revision IS NULL OR membership.left_revision > rooms.membership_revision)
                       ) AS actor_is_active_member
                FROM im_v2.rooms AS rooms
                WHERE rooms.room_id = \(bind: roomUUID)
            ), visible_event_candidates AS MATERIALIZED (
                -- Legacy/group events retain their immutable event row.
                SELECT event.event_id, event.room_id, event.room_sequence, event.event_type,
                       event.payload, event.committed_membership_revision,
                       NULL::uuid AS message_id, FALSE AS is_message_row
                FROM im_v2.room_events AS event
                WHERE event.room_id = \(bind: roomUUID)
                  -- Keep the cursor predicate inside the indexed source.  It
                  -- is logically identical to the visibility fence below,
                  -- but prevents a recovery miss from materializing the
                  -- room's complete legacy-event history before filtering.
                  AND event.room_sequence > \(bind: cursor.signedValue)

                UNION ALL

                -- Plain direct room-log messages materialize their accepted
                -- event in the messages row itself. They retain an explicit
                -- event ID and membership revision, so cursor and visibility
                -- semantics are identical to the legacy room-event form.
                SELECT message.accepted_event_id, message.room_id, message.room_sequence,
                       'message.accepted', NULL::jsonb,
                       message.accepted_membership_revision,
                       message.message_id, TRUE
                FROM im_v2.messages AS message
                WHERE message.room_id = \(bind: roomUUID)
                  AND message.accepted_event_storage = 'message_row'
                  -- `message_row` is constrained to use the same room and
                  -- timeline sequence.  Keep the cursor predicate on the
                  -- existing unique `(room_id, timeline_sequence)` index so
                  -- direct event pulls do not need a second write index.
                  AND message.timeline_sequence > \(bind: cursor.signedValue)
            ), visible_events AS MATERIALIZED (
                SELECT event.event_id, event.room_sequence, event.event_type,
                       event.payload, event.message_id, event.is_message_row,
                       (event.event_type NOT IN ('message.edited', 'message.withdrawn', 'message.reaction_changed')
                        OR accepted.message_id IS NOT NULL) AS authority_complete
                FROM room
                JOIN visible_event_candidates AS event ON TRUE
                LEFT JOIN LATERAL (\(acceptedDelivery)) AS accepted ON TRUE
                WHERE room.room_kind IN ('group', 'direct')
                  AND room.actor_is_active_member
                  AND event.room_sequence > \(bind: cursor.signedValue)
                  AND EXISTS (
                      SELECT 1 FROM im_v2.room_memberships AS membership
                      WHERE membership.room_id = event.room_id
                        AND membership.user_id = \(bind: actorUUID)
                        AND membership.joined_revision <= event.committed_membership_revision
                        AND (membership.left_revision IS NULL OR membership.left_revision > event.committed_membership_revision)
                  )
                  AND (
                      event.event_type NOT IN ('message.edited', 'message.withdrawn', 'message.reaction_changed')
                      -- Keep unknown authority as an incomplete row: fail the
                      -- page instead of silently skipping its cursor range.
                      OR accepted.message_id IS NULL
                      OR EXISTS (
                          SELECT 1 FROM im_v2.room_memberships AS original_membership
                          WHERE original_membership.room_id = event.room_id
                            AND original_membership.user_id = \(bind: actorUUID)
                            AND original_membership.joined_revision <= accepted.accepted_membership_revision
                            AND (original_membership.left_revision IS NULL
                                 OR original_membership.left_revision > accepted.accepted_membership_revision)
                      )
                  )
                ORDER BY event.room_sequence
                LIMIT \(bind: pageSize + 1)
            )
            SELECT room.room_kind, room.actor_is_active_member,
                   room.room_sequence AS scanned_through_room_sequence,
                   room.log_trimmed_through_room_sequence AS trimmed_through_room_sequence,
                   event.event_id, event.room_sequence, event.event_type,
                   CASE
                       WHEN event.is_message_row
                       THEN jsonb_build_object(
                           'event_type', 'message.accepted',
                           'message_id', message.message_id::text,
                           'room_id', message.room_id::text,
                           'room_sequence', event.room_sequence,
                           'timeline_sequence', message.timeline_sequence,
                           'sender_user_id', message.sender_user_id::text,
                           'text', COALESCE(snapshot.text_body, message.text_body),
                           'media_ids', '[]'::jsonb,
                           'media_presentations', '[]'::jsonb,
                           'mention_user_ids', '[]'::jsonb,
                           'mentions_everyone', FALSE,
                           'entities', COALESCE(snapshot.rich_entities, message.rich_entities),
                           'reply_to_message_id', message.reply_to_message_id::text,
                           'forwarded_from_message_id', message.forwarded_from_message_id::text,
                           'forwarded_from_user_id', message.forwarded_from_user_id::text,
                           'message_revision', 1,
                           'server_created_at_ms',
                               floor(extract(epoch FROM message.created_at) * 1000)::bigint
                       )
                       WHEN event.event_type = 'message.accepted'
                        AND event.payload->>'payload_storage' = 'message_reference_v1'
                       THEN jsonb_build_object(
                           'event_type', 'message.accepted',
                           'message_id', message.message_id::text,
                           'room_id', message.room_id::text,
                           'room_sequence', event.room_sequence,
                           'timeline_sequence', message.timeline_sequence,
                           'sender_user_id', message.sender_user_id::text,
                           'text', COALESCE(snapshot.text_body, message.text_body),
                           'media_ids', '[]'::jsonb,
                           'media_presentations', '[]'::jsonb,
                           'mention_user_ids', '[]'::jsonb,
                           'mentions_everyone', FALSE,
                           'entities', COALESCE(snapshot.rich_entities, message.rich_entities),
                           'reply_to_message_id', message.reply_to_message_id::text,
                           'forwarded_from_message_id', message.forwarded_from_message_id::text,
                           'forwarded_from_user_id', message.forwarded_from_user_id::text,
                           'message_revision', (event.payload->>'message_revision')::bigint,
                           'server_created_at_ms',
                               (event.payload->>'server_created_at_ms')::bigint
                       )
                       ELSE event.payload
                   END::text AS payload_json,
                   (CASE
                       WHEN event.is_message_row
                       THEN message.message_id IS NOT NULL
                            AND (snapshot.message_id IS NOT NULL
                                 OR message.content_revision = 1)
                       WHEN event.event_type = 'message.accepted'
                        AND event.payload->>'payload_storage' = 'message_reference_v1'
                       THEN message.message_id IS NOT NULL
                            AND (
                                snapshot.message_id IS NOT NULL
                                OR message.content_revision = (event.payload->>'message_revision')::bigint
                            )
                       ELSE TRUE
                   END) AND COALESCE(event.authority_complete, TRUE) AS payload_is_complete
            FROM room
            LEFT JOIN visible_events AS event ON TRUE
            LEFT JOIN im_v2.messages AS message
              ON message.message_id = COALESCE(
                    event.message_id,
                    (event.payload->>'message_id')::uuid
                 )
             AND message.room_id = \(bind: roomUUID)
             AND message.room_sequence = event.room_sequence
            LEFT JOIN im_v2.message_content_versions AS snapshot
              ON snapshot.message_id = message.message_id
             AND snapshot.message_revision = CASE
                 WHEN event.is_message_row THEN 1
                 ELSE (event.payload->>'message_revision')::bigint
             END
            ORDER BY event.room_sequence NULLS LAST
            """).all(decoding: GroupEventLogRow.self)
        guard let room = rows.first else { throw V2GroupEventLogError.roomNotFound }
        guard room.roomKind == "group" || room.roomKind == "direct" else {
            throw V2GroupEventLogError.roomNotFound
        }
        guard room.actorIsActiveMember else { throw V2GroupEventLogError.actorNotMember }

        let eventRows = rows.compactMap { $0.eventID == nil ? nil : $0 }
        let hasMore = eventRows.count > pageSize
        let pageRows = hasMore ? Array(eventRows.prefix(pageSize)) : eventRows
        let entries: [V2GroupEventLogEntry] = try pageRows.map { row in
            guard let eventID = row.eventID,
                  let roomSequence = row.roomSequence,
                  let eventType = row.eventType,
                  let payloadJSON = row.payloadJSON,
                  row.payloadIsComplete,
                  let payload = payloadJSON.data(using: .utf8)
            else { throw V2GroupEventLogError.corruptPersistenceState }
            return try V2GroupEventLogEntry(
                sourceEventID: try EventID(eventID.uuidString),
                roomSequence: try groupEventUnsigned(roomSequence),
                projectionKind: groupEventProjectionKind(for: eventType),
                payload: payload
            )
        }
        // An exhausted snapshot has checked the complete tail, including
        // authorized sequence gaps. Never advertise that tail as consumed
        // while another visible (or incomplete-authority) row remains.
        let trimmedThrough = try groupEventUnsigned(room.trimmedThroughRoomSequence)
        let next = hasMore
            ? (entries.last?.roomSequence ?? afterRoomSequence)
            : max(afterRoomSequence, try groupEventUnsigned(room.scannedThroughRoomSequence))
        return try V2GroupEventLogPage(
            roomID: roomID,
            events: entries,
            nextRoomSequence: next,
            hasMore: hasMore,
            logTrimmedThroughRoomSequence: trimmedThrough
        )
    }

    func pullPrepared(
        roomID: RoomID,
        actorUserID: UserID,
        afterRoomSequence: UInt64,
        pageSize: Int,
        context: V2PreparedGroupEventPageEncodingContext
    ) async throws -> V2PreparedGroupEventPullResult {
        guard (try? V2RoomCursor(afterRoomSequence)) != nil,
              (1 ... V2GroupEventLogService.maximumPageSize).contains(pageSize)
        else { throw V2GroupEventLogError.invalidRequest }
        guard let sql = database as? any SQLDatabase,
              let roomUUID = UUID(uuidString: roomID.rawValue),
              let actorUUID = UUID(uuidString: actorUserID.rawValue),
              let directRoomLogEventCache,
              await directRoomLogEventCache.hasPreparedPageCoverage(
                  roomID: roomID,
                  afterRoomSequence: afterRoomSequence,
                  pageSize: pageSize
              )
        else {
            return .page(try await pull(
                roomID: roomID,
                actorUserID: actorUserID,
                afterRoomSequence: afterRoomSequence,
                pageSize: pageSize
            ))
        }

        guard let access = try await authorizedRoomCacheAccess(
            roomID: roomUUID,
            actorUserID: actorUUID,
            sql: sql
        ) else {
            // Preserve the complete durable query's public missing-room and
            // membership error mapping. No prepared payload is reachable
            // without the fresh row above.
            return .page(try await pull(
                roomID: roomID,
                actorUserID: actorUserID,
                afterRoomSequence: afterRoomSequence,
                pageSize: pageSize
            ))
        }

        switch try await directRoomLogEventCache.preparedPage(
            roomID: roomID,
            actorJoinedRevision: try groupEventUnsigned(access.actorJoinedRevision),
            actorLeftRevision: try access.actorLeftRevision.map(groupEventUnsigned),
            currentHighWatermark: try groupEventUnsigned(access.roomSequence),
            afterRoomSequence: afterRoomSequence,
            pageSize: pageSize,
            context: context
        ) {
        case .prepared(let response):
            return .prepared(response)
        case .eventTooLarge:
            return .eventTooLarge
        case .miss:
            // A cache eviction, gap, or membership-epoch mismatch after the
            // probe is a normal race. The durable query remains authoritative.
            return .page(try await pull(
                roomID: roomID,
                actorUserID: actorUserID,
                afterRoomSequence: afterRoomSequence,
                pageSize: pageSize
            ))
        }
    }

    /// 校验订阅资格并返回当前水位与成员修订。
    ///
    /// 与拉取路径共用同一套房间与成员校验，因此订阅成功即代表该连接在当前修订下具备资格。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起订阅的用户。
    /// - Returns: 订阅结果。
    /// - Throws: 房间不存在、发起者非成员或持久化失败时抛出。
    public func subscribe(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupEventSubscription {
        guard let sql = database as? any SQLDatabase else {
            throw V2GroupEventLogError.corruptPersistenceState
        }
        let room = try await authorizedRoom(roomID: roomID, actorUserID: actorUserID, sql: sql)
        return try .init(
            roomID: roomID,
            highWatermark: try groupEventUnsigned(room.roomSequence),
            membershipRevision: try groupEventUnsigned(room.membershipRevision)
        )
    }

    /// 校验房间与发起者资格。
    ///
    /// 群房间与私聊房间使用同一套游标协议。私聊房间只有在用户对与成员策略接受该写入之后
    /// 才会进入此路径；每次拉取仍会校验下方的修订栅栏，因此陈旧唤醒绝不会泄漏入群前或
    /// 退群后的载荷。标准群仍只是预览用途：除非房间显式配置为混合事件日志模式，
    /// 其投递流依然是权威。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起拉取的用户。
    ///   - sql: 当前使用的数据库连接。
    /// - Returns: 房间与成员状态行。
    /// - Throws: 房间不存在时抛出 ``V2GroupEventLogError/roomNotFound``；
    ///   发起者非成员时抛出 ``V2GroupEventLogError/actorNotMember``。
    private func authorizedRoom(
        roomID: RoomID,
        actorUserID: UserID,
        sql: any SQLDatabase
    ) async throws -> GroupEventLogRoomRow {
        guard let roomUUID = UUID(uuidString: roomID.rawValue),
              let actorUUID = UUID(uuidString: actorUserID.rawValue)
        else { throw V2GroupEventLogError.corruptPersistenceState }
        guard let room = try await sql.raw("""
            SELECT room_sequence, membership_revision, room_kind,
                   EXISTS (
                       SELECT 1 FROM im_v2.room_memberships AS membership
                       WHERE membership.room_id = rooms.room_id
                         AND membership.user_id = \(bind: actorUUID)
                         AND membership.joined_revision <= rooms.membership_revision
                         AND (membership.left_revision IS NULL OR membership.left_revision > rooms.membership_revision)
                   ) AS actor_is_active_member
            FROM im_v2.rooms AS rooms
            WHERE rooms.room_id = \(bind: roomUUID)
            """).first(decoding: GroupEventLogRoomRow.self)
        else { throw V2GroupEventLogError.roomNotFound }
        guard room.roomKind == "group" || room.roomKind == "direct" else {
            throw V2GroupEventLogError.roomNotFound
        }
        guard room.actorIsActiveMember else { throw V2GroupEventLogError.actorNotMember }
        return room
    }

    /// 提供本地房间事件缓存所需的最小当前成员栅栏。
    ///
    /// 返回 `nil` 与缓存未命中刻意不做区分；房间缺失与未授权仍由持久化拉取保留对外错误映射。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起拉取的用户。
    ///   - sql: 当前使用的数据库连接。
    /// - Returns: 缓存访问所需的栅栏信息；不满足条件时为 `nil`。
    /// - Throws: 查询失败时抛出。
    private func authorizedRoomCacheAccess(
        roomID: UUID,
        actorUserID: UUID,
        sql: any SQLDatabase
    ) async throws -> DirectRoomCacheAccessRow? {
        try await sql.raw("""
            SELECT room.room_sequence, membership.joined_revision,
                   membership.left_revision, room.log_trimmed_through_room_sequence
            FROM im_v2.rooms AS room
            JOIN im_v2.room_memberships AS membership
              ON membership.room_id = room.room_id
             AND membership.user_id = \(bind: actorUserID)
             AND membership.joined_revision <= room.membership_revision
             AND (membership.left_revision IS NULL
                  OR membership.left_revision > room.membership_revision)
            WHERE room.room_id = \(bind: roomID)
              AND room.room_kind IN ('direct', 'group')
            """).first(decoding: DirectRoomCacheAccessRow.self)
    }
}

private struct GroupEventLogRoomRow: Decodable {
    let roomSequence: Int64
    let membershipRevision: Int64
    let roomKind: String
    let actorIsActiveMember: Bool
    enum CodingKeys: String, CodingKey {
        case roomSequence = "room_sequence"
        case membershipRevision = "membership_revision"
        case roomKind = "room_kind"
        case actorIsActiveMember = "actor_is_active_member"
    }
}

private struct DirectRoomCacheAccessRow: Decodable {
    let roomSequence: Int64
    let actorJoinedRevision: Int64
    let actorLeftRevision: Int64?
    let trimmedThroughRoomSequence: Int64

    enum CodingKeys: String, CodingKey {
        case roomSequence = "room_sequence"
        case actorJoinedRevision = "joined_revision"
        case actorLeftRevision = "left_revision"
        case trimmedThroughRoomSequence = "log_trimmed_through_room_sequence"
    }
}

private struct GroupEventLogRow: Decodable {
    let scannedThroughRoomSequence: Int64
    let trimmedThroughRoomSequence: Int64
    let roomKind: String
    let actorIsActiveMember: Bool
    let eventID: UUID?
    let roomSequence: Int64?
    let eventType: String?
    let payloadJSON: String?
    let payloadIsComplete: Bool
    enum CodingKeys: String, CodingKey {
        case scannedThroughRoomSequence = "scanned_through_room_sequence"
        case trimmedThroughRoomSequence = "trimmed_through_room_sequence"
        case roomKind = "room_kind"
        case actorIsActiveMember = "actor_is_active_member"
        case eventID = "event_id"
        case roomSequence = "room_sequence"
        case eventType = "event_type"
        case payloadJSON = "payload_json"
        case payloadIsComplete = "payload_is_complete"
    }
}

private func groupEventUnsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2GroupEventLogError.corruptPersistenceState }
    return UInt64(value)
}

private func groupEventProjectionKind(for eventType: String) -> String {
    switch eventType {
    case "room.created": "room"
    case "membership_changed": "membership"
    case "member.muted", "room.frozen", "room.unfrozen": "moderation"
    case "message.reaction_changed": "message_reaction"
    case "message.pinned_changed", "group.announcement_changed", "group.role_permissions_changed", "group.member_role_changed": "group_capability"
    default: "message"
    }
}
