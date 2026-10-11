import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
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

        // 在缓存路径花费数据库往返前，只检查本地覆盖情况。
        // 候选项不含身份信息；未经过与此前相同的最新持久化成员围栏，
        // 就绝不返回候选项。因此明确的本地未命中会直接进入下方
        // 包含授权检查的完整查询，避免付出两次 SQL 调用的开销。
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
                    actorJoinedRevision: try v2PersistenceUnsigned(access.actorJoinedRevision, invalid: V2GroupEventLogError.corruptPersistenceState),
                    actorLeftRevision: try access.actorLeftRevision.map { try v2PersistenceUnsigned($0, invalid: V2GroupEventLogError.corruptPersistenceState) },
                    currentHighWatermark: try v2PersistenceUnsigned(access.roomSequence, invalid: V2GroupEventLogError.corruptPersistenceState)
                ) {
                    return cached
                }
            } else {
                await directRoomLogEventCache.recordMiss(roomID: roomID)
            }
        }

        let rows = try await sql.raw(v2GroupEventPullQuery(room: "\(bind: roomUUID)",
            viewer: "\(bind: actorUUID)", cursor: "\(bind: cursor.signedValue)",
            pageLimit: "\(bind: pageSize)", candidateLimit: "\(bind: pageSize + 1)"))
            .all(decoding: GroupEventLogRow.self)

        return try v2DecodeGroupEventPull(rows, roomID: roomID, afterRoomSequence: afterRoomSequence)
    }

    package func pullPrepared(
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
            // 保持完整持久查询对外的房间缺失和成员错误映射。
            // 没有上方的最新记录，就无法访问已准备的载荷。
            return .page(try await pull(
                roomID: roomID,
                actorUserID: actorUserID,
                afterRoomSequence: afterRoomSequence,
                pageSize: pageSize
            ))
        }

        switch try await directRoomLogEventCache.preparedPage(
            roomID: roomID,
            actorJoinedRevision: try v2PersistenceUnsigned(access.actorJoinedRevision, invalid: V2GroupEventLogError.corruptPersistenceState),
            actorLeftRevision: try access.actorLeftRevision.map { try v2PersistenceUnsigned($0, invalid: V2GroupEventLogError.corruptPersistenceState) },
            currentHighWatermark: try v2PersistenceUnsigned(access.roomSequence, invalid: V2GroupEventLogError.corruptPersistenceState),
            afterRoomSequence: afterRoomSequence,
            pageSize: pageSize,
            context: context
        ) {
        case .prepared(let response):
            return .prepared(response)
        case .eventTooLarge:
            return .eventTooLarge
        case .miss:
            // 探测后发生缓存淘汰、缺口或成员纪元不匹配，是正常竞态。
            // 持久化查询仍是权威。
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
            highWatermark: try v2PersistenceUnsigned(room.roomSequence, invalid: V2GroupEventLogError.corruptPersistenceState),
            membershipRevision: try v2PersistenceUnsigned(room.membershipRevision, invalid: V2GroupEventLogError.corruptPersistenceState)
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

struct GroupEventLogRow: Decodable {
    let hasMoreCandidates: Bool
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
        case hasMoreCandidates = "has_more_candidates"
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

func groupEventProjectionKind(for eventType: String) -> String {
    switch eventType {
    case "room.created": "room"
    case "membership_changed": "membership"
    case "member.muted", "room.frozen", "room.unfrozen": "moderation"
    case "message.reaction_changed": "message_reaction"
    case "message.pinned_changed", "group.announcement_changed", "group.role_permissions_changed", "group.member_role_changed", "group.avatar_changed", "group.nickname_changed": "group_capability"
    default: "message"
    }
}

func v2DecodeGroupEventPull(_ rows: [GroupEventLogRow], roomID: RoomID,
    afterRoomSequence: UInt64
) throws -> V2GroupEventLogPage {
        guard let room = rows.first else { throw V2GroupEventLogError.roomNotFound }
        guard room.roomKind == "group" || room.roomKind == "direct" else {
            throw V2GroupEventLogError.roomNotFound
        }
        guard room.actorIsActiveMember else { throw V2GroupEventLogError.actorNotMember }

        let eventRows = rows.compactMap { $0.eventID == nil ? nil : $0 }
        let hasMore = room.hasMoreCandidates
        let entries: [V2GroupEventLogEntry] = try eventRows.map { row in
            guard let eventID = row.eventID,
                  let roomSequence = row.roomSequence,
                  let eventType = row.eventType,
                  let payloadJSON = row.payloadJSON,
                  row.payloadIsComplete,
                  let payload = payloadJSON.data(using: .utf8)
            else { throw V2GroupEventLogError.corruptPersistenceState }
            return try V2GroupEventLogEntry(
                sourceEventID: try EventID(eventID.uuidString),
                roomSequence: try v2PersistenceUnsigned(roomSequence, invalid: V2GroupEventLogError.corruptPersistenceState),
                projectionKind: groupEventProjectionKind(for: eventType),
                payload: payload
            )
        }
        // Advance through the inspected candidate window, including invisible
        // events. Only an exhausted pair of sources may advance to the room head.
        let trimmedThrough = try v2PersistenceUnsigned(room.trimmedThroughRoomSequence, invalid: V2GroupEventLogError.corruptPersistenceState)
        let next = max(afterRoomSequence, try v2PersistenceUnsigned(room.scannedThroughRoomSequence, invalid: V2GroupEventLogError.corruptPersistenceState))
        return try V2GroupEventLogPage(
            roomID: roomID,
            events: entries,
            nextRoomSequence: next,
            hasMore: hasMore,
            logTrimmedThroughRoomSequence: trimmedThrough
        )
}
