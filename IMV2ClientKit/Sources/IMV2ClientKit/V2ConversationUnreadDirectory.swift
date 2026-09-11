import Foundation
import GRDB
import IMV2Core

/// 未读目录中的一条服务端未读记录。
///
/// 只保存展示需要的字段：未读数、房间头、活动时间。正文与身份仍由各自的投影负责，
/// 目录不复制内容，也不成为第二份会话列表。
public struct V2ClientRoomUnreadEntry: Equatable, Sendable {
    /// 房间标识。
    public let roomID: RoomID
    /// 服务端给出的房间日志头。
    public let head: UInt64
    /// 服务端给出的未读数。
    public let unreadCount: UInt64
    /// 房间日志头最后一次前进的时刻。
    public let lastEventAt: Date

    /// 保存一条未读记录。
    ///
    /// - Parameters:
    ///   - roomID: 房间标识。
    ///   - head: 房间日志头。
    ///   - unreadCount: 服务端未读数。
    ///   - lastEventAt: 房间活动时间。
    public init(roomID: RoomID, head: UInt64, unreadCount: UInt64, lastEventAt: Date) {
        self.roomID = roomID
        self.head = head
        self.unreadCount = unreadCount
        self.lastEventAt = lastEventAt
    }
}

/// 全房间轮转的持久化状态。
public struct V2ClientRoomUnreadRotation: Equatable, Sendable {
    /// 服务端摘要游标；为空表示本轮已走完，下次从最新活动重新开始。
    public let cursor: String?
    /// 轮次；每走完一轮递增，用于淘汰本轮没再出现的房间。
    public let cycle: Int

    /// 保存轮转状态。
    ///
    /// - Parameters:
    ///   - cursor: 服务端摘要游标。
    ///   - cycle: 轮次。
    public init(cursor: String?, cycle: Int) {
        self.cursor = cursor
        self.cycle = cycle
    }
}

/// 未读目录与轮转游标的本地持久化能力。
public protocol V2ClientRoomUnreadDirectoryStore: Sendable {
    /// 读取轮转状态；从未轮转过时返回空游标与第零轮。
    func unreadRotation() async throws -> V2ClientRoomUnreadRotation
    /// 写入本页未读记录，已有房间按新值覆盖。
    func recordUnread(_ entries: [V2ClientRoomUnreadEntry], cycle: Int, at: Date) async throws
    /// 保存轮转状态。
    func advanceUnreadRotation(cursor: String?, cycle: Int, at: Date) async throws
    /// 淘汰早于给定轮次的房间。
    func pruneUnread(directoryKeepingCycle cycle: Int) async throws
    /// 按房间标识读取未读记录。
    func unreadEntries(roomIDs: [RoomID]) async throws -> [RoomID: V2ClientRoomUnreadEntry]
}

extension GRDBV2LocalSyncStore: V2ClientRoomUnreadDirectoryStore {
    /// 读取轮转状态。
    ///
    /// - Returns: 已保存的游标与轮次；没有记录时为空游标、第零轮。
    /// - Throws: 本地读取失败。
    public func unreadRotation() throws -> V2ClientRoomUnreadRotation {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT cursor, cycle FROM v2_room_unread_rotation WHERE singleton = 1"
            ) else { return .init(cursor: nil, cycle: 0) }
            let cycle: Int64 = row["cycle"]
            guard cycle >= 0, cycle <= Int64(Int32.max) else { throw V2ClientCommandError.commandConflict }
            return .init(cursor: row["cursor"], cycle: Int(cycle))
        }
    }

    /// 写入本页未读记录。
    ///
    /// - Parameters:
    ///   - entries: 本页记录。
    ///   - cycle: 本页所属轮次。
    ///   - at: 记录时刻。
    /// - Throws: 本地写入失败。
    public func recordUnread(_ entries: [V2ClientRoomUnreadEntry], cycle: Int, at: Date) throws {
        guard cycle >= 0 else { throw V2ClientCommandError.commandConflict }
        guard !entries.isEmpty else { return }
        let timestamp = at.timeIntervalSince1970
        try databasePool.write { db in
            for entry in entries {
                guard entry.head >= 0, entry.head <= UInt64(Int64.max),
                      entry.unreadCount >= 0, entry.unreadCount <= UInt64(Int64.max)
                else { throw V2ClientCommandError.commandConflict }
                try db.execute(
                    sql: """
                        INSERT INTO v2_room_unread_directory
                            (room_id, head, unread_count, last_event_at, cycle, recorded_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(room_id) DO UPDATE SET
                            head = excluded.head,
                            unread_count = excluded.unread_count,
                            last_event_at = excluded.last_event_at,
                            cycle = excluded.cycle,
                            recorded_at = excluded.recorded_at
                        """,
                    arguments: [
                        entry.roomID.rawValue,
                        Int64(entry.head),
                        Int64(entry.unreadCount),
                        entry.lastEventAt.timeIntervalSince1970,
                        Int64(cycle),
                        timestamp
                    ]
                )
            }
        }
    }

    /// 保存轮转状态。
    ///
    /// - Parameters:
    ///   - cursor: 服务端摘要游标；为空表示本轮结束。
    ///   - cycle: 轮次。
    ///   - at: 记录时刻。
    /// - Throws: 本地写入失败。
    public func advanceUnreadRotation(cursor: String?, cycle: Int, at: Date) throws {
        guard cycle >= 0 else { throw V2ClientCommandError.commandConflict }
        try databasePool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO v2_room_unread_rotation (singleton, cursor, cycle, updated_at)
                    VALUES (1, ?, ?, ?)
                    ON CONFLICT(singleton) DO UPDATE SET
                        cursor = excluded.cursor, cycle = excluded.cycle, updated_at = excluded.updated_at
                    """,
                arguments: [cursor, Int64(cycle), at.timeIntervalSince1970]
            )
        }
    }

    /// 淘汰早于给定轮次的房间。
    ///
    /// - Parameter cycle: 保留的轮次。
    /// - Throws: 本地写入失败。
    public func pruneUnread(directoryKeepingCycle cycle: Int) throws {
        try databasePool.write { db in
            try db.execute(
                sql: "DELETE FROM v2_room_unread_directory WHERE cycle < ?",
                arguments: [Int64(cycle)]
            )
        }
    }

    /// 按房间标识读取未读记录。
    ///
    /// - Parameter roomIDs: 目标房间，调用方需传入有界集合。
    /// - Returns: 命中的房间到记录的映射。
    /// - Throws: 本地读取失败。
    public func unreadEntries(roomIDs: [RoomID]) throws -> [RoomID: V2ClientRoomUnreadEntry] {
        guard !roomIDs.isEmpty else { return [:] }
        let identifiers = roomIDs.map(\.rawValue)
        let placeholders = Array(repeating: "?", count: identifiers.count).joined(separator: ", ")
        return try databasePool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT room_id, head, unread_count, last_event_at
                    FROM v2_room_unread_directory
                    WHERE room_id IN (\(placeholders))
                    """,
                arguments: StatementArguments(identifiers)
            )
            var entries: [RoomID: V2ClientRoomUnreadEntry] = [:]
            for row in rows {
                let stored: String = row["room_id"]
                let head: Int64 = row["head"]
                let unread: Int64 = row["unread_count"]
                guard let roomID = try? RoomID(stored), head >= 0, unread >= 0 else { continue }
                entries[roomID] = .init(
                    roomID: roomID,
                    head: UInt64(head),
                    unreadCount: UInt64(unread),
                    lastEventAt: Date(timeIntervalSince1970: row["last_event_at"] as Double)
                )
            }
            return entries
        }
    }
}

/// 一次轮转刷新的结果。
public struct V2ClientRoomUnreadRotationReport: Equatable, Sendable {
    /// 本次取回的页数。
    public let pagesFetched: Int
    /// 本次写入的房间数。
    public let roomsRecorded: Int
    /// 刷新后的轮转状态。
    public let rotation: V2ClientRoomUnreadRotation
    /// 本轮是否已走完。
    public let completedCycle: Bool

    /// 保存轮转结果。
    ///
    /// - Parameters:
    ///   - pagesFetched: 本次取回的页数。
    ///   - roomsRecorded: 本次写入的房间数。
    ///   - rotation: 刷新后的轮转状态。
    ///   - completedCycle: 本轮是否已走完。
    public init(pagesFetched: Int, roomsRecorded: Int, rotation: V2ClientRoomUnreadRotation, completedCycle: Bool) {
        self.pagesFetched = pagesFetched
        self.roomsRecorded = roomsRecorded
        self.rotation = rotation
        self.completedCycle = completedCycle
    }
}

/// 本地优先会话列表的未读目录。
///
/// 会话列表按本地投影渲染，未读却只能由服务端给出，因此这里做一件事：**有界轮转**。
/// 每次刷新只走给定页数，把服务端摘要里的未读写进本地目录并推进持久化游标；一轮走完
/// 后从最新活动重新开始，并淘汰本轮没再出现的房间。
///
/// 代价随页数增长，与房间总数无关；最活跃的房间永远最先刷新，冷房间靠后续轮转补齐
/// （活跃窗口优先，见合同 §8）。轮转不阻塞界面：界面读不到某房间的未读时不显示角标，
/// 而不会用本地推算冒充服务端值。
public actor V2ClientConversationUnreadDirectory {
    private let transport: any V2ClientRoomSummaryTransport
    private let store: any V2ClientRoomUnreadDirectoryStore
    private let watermarks: any V2ClientRoomReadWatermarkReading
    private let now: @Sendable () -> Date

    /// 组合摘要传输、本地目录存储与本地已读水位。
    ///
    /// - Parameters:
    ///   - transport: 会话摘要传输。
    ///   - store: 未读目录与轮转游标存储。
    ///   - watermarks: 本地有效已读水位。
    ///   - now: 可注入的当前时刻。
    public init(
        transport: any V2ClientRoomSummaryTransport,
        store: any V2ClientRoomUnreadDirectoryStore,
        watermarks: any V2ClientRoomReadWatermarkReading,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.store = store
        self.watermarks = watermarks
        self.now = now
    }

    /// 按页预算推进一次轮转。
    ///
    /// - Parameters:
    ///   - pageBudget: 本次最多取回的页数，需大于零。
    ///   - pageSize: 单页房间数，需落在传输预算内。
    /// - Returns: 本次刷新结果。
    /// - Throws: 页预算非法、传输或本地存储失败。
    @discardableResult
    public func refresh(
        pageBudget: Int,
        pageSize: Int = V2ClientRoomSummaryPageLimits.maximumPageSize
    ) async throws -> V2ClientRoomUnreadRotationReport {
        guard pageBudget > 0, pageSize > 0, pageSize <= V2ClientRoomSummaryPageLimits.maximumPageSize else {
            throw V2RoomUnreadDirectoryError.invalidRequest
        }
        var rotation = try await store.unreadRotation()
        var pagesFetched = 0
        var roomsRecorded = 0
        var completedCycle = false
        while pagesFetched < pageBudget {
            let page = try await transport.roomSummaries(cursor: rotation.cursor, pageSize: pageSize)
            let entries = page.rooms.map {
                V2ClientRoomUnreadEntry(roomID: $0.roomID, head: $0.head, unreadCount: $0.unreadCount, lastEventAt: $0.lastEventAt)
            }
            try await store.recordUnread(entries, cycle: rotation.cycle, at: now())
            pagesFetched += 1
            roomsRecorded += entries.count
            guard let cursor = page.nextCursor else {
                // 一轮走完：淘汰本轮没再出现的房间，并让下一轮从最新活动重新开始。
                let nextCycle = rotation.cycle + 1
                try await store.pruneUnread(directoryKeepingCycle: rotation.cycle)
                rotation = .init(cursor: nil, cycle: nextCycle)
                try await store.advanceUnreadRotation(cursor: nil, cycle: nextCycle, at: now())
                completedCycle = true
                break
            }
            rotation = .init(cursor: cursor, cycle: rotation.cycle)
            try await store.advanceUnreadRotation(cursor: cursor, cycle: rotation.cycle, at: now())
        }
        return .init(
            pagesFetched: pagesFetched,
            roomsRecorded: roomsRecorded,
            rotation: rotation,
            completedCycle: completedCycle
        )
    }

    /// 读取若干房间的展示未读。
    ///
    /// - Parameter roomIDs: 目标房间，调用方需传入有界集合。
    /// - Returns: 目录中有记录的房间到展示行的映射；没有记录的房间不出现，界面据此
    ///   决定是否显示角标，而不是显示一个本地推算值。
    /// - Throws: 本地读取失败。
    public func snapshot(roomIDs: [RoomID]) async throws -> [RoomID: V2ClientConversationUnreadRow] {
        guard !roomIDs.isEmpty else { return [:] }
        let entries = try await store.unreadEntries(roomIDs: roomIDs)
        guard !entries.isEmpty else { return [:] }
        let local = try await watermarks.roomReadWatermarks(roomIDs: Array(entries.keys))
        var rows: [RoomID: V2ClientConversationUnreadRow] = [:]
        for (roomID, entry) in entries {
            let watermark = local[roomID]
            rows[roomID] = .init(
                roomID: entry.roomID,
                head: entry.head,
                serverUnreadCount: entry.unreadCount,
                localReadWatermark: watermark,
                displayedUnread: V2ClientConversationUnread.displayedUnread(
                    serverUnread: entry.unreadCount,
                    head: entry.head,
                    localWatermark: watermark
                )
            )
        }
        return rows
    }

    /// 读取若干房间的服务端房间头。
    ///
    /// 房间头是"进入房间即已读"要推进到的目标（合同 §5.4）：它包含编辑、撤回、
    /// reaction、置顶、公告、角色变更这些非消息事件，因此不能由最后一条可见消息的
    /// 序号代替。没有轮转覆盖到的房间不出现，调用方不得用本地推算冒充。
    ///
    /// - Parameter roomIDs: 目标房间，调用方需传入有界集合。
    /// - Returns: 目录中有记录的房间到房间头的映射。
    /// - Throws: 本地读取失败。
    public func knownHeads(roomIDs: [RoomID]) async throws -> [RoomID: UInt64] {
        guard !roomIDs.isEmpty else { return [:] }
        return try await store.unreadEntries(roomIDs: roomIDs).mapValues(\.head)
    }
}

/// 未读目录错误。
public enum V2RoomUnreadDirectoryError: Error, Equatable, Sendable {
    /// 请求参数不满足约束。
    case invalidRequest
}
