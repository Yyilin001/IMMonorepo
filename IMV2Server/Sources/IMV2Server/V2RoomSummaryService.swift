import Foundation
import IMV2Core

/// 房间类型。
///
/// 摘要是会话列表的唯一数据来源，单聊与群聊必须返回同一种结构，否则列表会把
/// "房间"重新拆成两条互不相容的读取路径。
public enum V2RoomKind: String, Equatable, Sendable {
    /// 群聊房间。
    case group
    /// 单聊房间。
    case direct
}

/// 会话列表里的一条最新可见消息摘要。
///
/// 摘要只承载列表展示需要的字段，正文永远通过房间游标拉取。把完整消息塞进列表响应
/// 会让"房间数无上限"变成"响应体随房间数增长"。
public struct V2RoomSummaryMessage: Equatable, Sendable {
    /// 该消息所属房间。
    public let roomID: RoomID
    /// 消息标识。
    public let messageID: MessageID
    /// 发送者用户标识。
    public let senderUserID: UserID
    /// 该消息在房间日志中的序号。
    ///
    /// 它同时是"从这条消息继续拉取"的游标，**不是**个人时间线序号。
    public let roomSequence: UInt64
    /// 正文预览，最多 ``V2RoomSummaryLimits/maximumPreviewCharacters`` 个字符；
    /// 被撤回时仍是撤回前的正文，由 ``isWithdrawn`` 决定展示方式。
    ///
    /// 它不是正文副本：完整正文必须经房间游标拉取。
    public let text: String
    /// 是否已撤回。
    public let isWithdrawn: Bool
    /// 未被撤销的媒体引用数量。
    public let mediaCount: Int
    /// 服务端创建时间。
    public let serverCreatedAt: Date

    /// 保存消息摘要。
    ///
    /// - Parameters:
    ///   - roomID: 该消息所属房间。
    ///   - messageID: 消息标识。
    ///   - senderUserID: 发送者用户标识。
    ///   - roomSequence: 房间日志序号。
    ///   - text: 当前正文。
    ///   - isWithdrawn: 是否已撤回。
    ///   - mediaCount: 未撤销的媒体数量。
    ///   - serverCreatedAt: 服务端创建时间。
    public init(
        roomID: RoomID,
        messageID: MessageID,
        senderUserID: UserID,
        roomSequence: UInt64,
        text: String,
        isWithdrawn: Bool,
        mediaCount: Int,
        serverCreatedAt: Date
    ) {
        self.roomID = roomID
        self.messageID = messageID
        self.senderUserID = senderUserID
        self.roomSequence = roomSequence
        self.text = text
        self.isWithdrawn = isWithdrawn
        self.mediaCount = mediaCount
        self.serverCreatedAt = serverCreatedAt
    }
}

/// 会话列表中的一条房间摘要。
public struct V2RoomSummary: Equatable, Sendable {
    /// 房间标识。
    public let roomID: RoomID
    /// 房间类型。
    public let roomKind: V2RoomKind
    /// 房间日志头，即 `rooms.room_sequence`。
    public let head: UInt64
    /// 房间日志头最后一次前进的时刻，也是列表排序键。
    public let lastEventAt: Date
    /// 未读数，公式见合同 §5.1。
    public let unreadCount: UInt64
    /// 对当前用户可见的最新消息；房间还没有可见消息时为空。
    public let latestMessage: V2RoomSummaryMessage?

    /// 保存房间摘要。
    ///
    /// - Parameters:
    ///   - roomID: 房间标识。
    ///   - roomKind: 房间类型。
    ///   - head: 房间日志头。
    ///   - lastEventAt: 房间日志头最后一次前进的时刻。
    ///   - unreadCount: 未读数。
    ///   - latestMessage: 最新可见消息摘要。
    public init(
        roomID: RoomID,
        roomKind: V2RoomKind,
        head: UInt64,
        lastEventAt: Date,
        unreadCount: UInt64,
        latestMessage: V2RoomSummaryMessage?
    ) {
        self.roomID = roomID
        self.roomKind = roomKind
        self.head = head
        self.lastEventAt = lastEventAt
        self.unreadCount = unreadCount
        self.latestMessage = latestMessage
    }
}

/// 会话列表分页游标。
///
/// 排序键是 `(rooms.last_event_at DESC, rooms.room_id DESC)`：`last_event_at` 决定会话
/// 顺序，`room_id` 只用于把时间戳相同的房间排成稳定序列。它与 `timeline_sequence`、
/// `room_sequence` 都无关，绝不能混用。传输层应把整个游标编码成不透明字符串，
/// 而不是把两个字段分别暴露给客户端。
///
/// - Important: 时间戳以**微秒整数**保存，不是毫秒。毫秒会让同一毫秒内结束的两个房间
///   在翻页时被静默跳过：游标行比它们新，四舍五入后的游标又比它们旧。
public struct V2RoomSummaryCursor: Equatable, Sendable {
    /// 上一页最后一行的事件时间，自 1970 年起的微秒数。
    public let lastEventAtMicroseconds: Int64
    /// 上一页最后一行的房间标识。
    public let roomID: RoomID

    /// 保存分页游标。
    ///
    /// - Parameters:
    ///   - lastEventAtMicroseconds: 上一页最后一行的事件时间，自 1970 年起的微秒数。
    ///   - roomID: 上一页最后一行的房间标识。
    public init(lastEventAtMicroseconds: Int64, roomID: RoomID) {
        self.lastEventAtMicroseconds = lastEventAtMicroseconds
        self.roomID = roomID
    }
}

/// 会话列表的一页。
///
/// 页内每一行的未读数都是精确值：页是有界的，必须算准。只有跨全部房间的总角标
/// 才允许滞后，见合同 §8。
public struct V2RoomSummaryPage: Equatable, Sendable {
    /// 本页房间摘要，按 `last_event_at DESC, room_id DESC` 排列。
    public let rooms: [V2RoomSummary]
    /// 下一页游标；为空表示没有更多房间。
    public let nextCursor: V2RoomSummaryCursor?

    /// 保存会话列表分页。
    ///
    /// - Parameters:
    ///   - rooms: 本页房间摘要。
    ///   - nextCursor: 下一页游标。
    public init(rooms: [V2RoomSummary], nextCursor: V2RoomSummaryCursor?) {
        self.rooms = rooms
        self.nextCursor = nextCursor
    }
}

/// 会话列表查询请求。
public struct V2RoomSummaryRequest: Equatable, Sendable {
    /// 单页允许的最大房间数。
    ///
    /// 上限存在的意义是保证"一页精确"这个承诺始终有界，而不是限制一个人能加入多少
    /// 房间：客户端可以连续翻页，且房间数本身没有配额。
    public static let maximumPageSize = 100

    /// 发起查询的用户。
    public let actorUserID: UserID
    /// 上一页游标；为空表示从最新活动开始。
    public let cursor: V2RoomSummaryCursor?
    /// 本页条数。
    public let pageSize: Int

    /// 校验并保存查询请求。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起查询的用户。
    ///   - cursor: 上一页游标。
    ///   - pageSize: 本页条数，需大于零且不超过 ``maximumPageSize``。
    /// - Throws: 条数越界时抛出 ``V2RoomSummaryError/invalidRequest``。
    public init(actorUserID: UserID, cursor: V2RoomSummaryCursor?, pageSize: Int) throws {
        guard pageSize > 0, pageSize <= Self.maximumPageSize else {
            throw V2RoomSummaryError.invalidRequest
        }
        self.actorUserID = actorUserID
        self.cursor = cursor
        self.pageSize = pageSize
    }
}

/// 会话摘要的展示与传输预算。
public enum V2RoomSummaryLimits {
    /// 预览正文的最大字符数。
    ///
    /// 摘要是列表展示用的预览，不是正文副本；正文永远经房间游标拉取。截断让"一页
    /// 100 个房间"的响应体有确定上界：按 UTF-8 最坏情况 4 字节/字符计算，
    /// 80 × 4 × 100 = 32 KB 预览，加上标识与计数仍留在 64 KB 帧预算内。
    public static let maximumPreviewCharacters = 80
}

/// 一个房间的活动水位。
///
/// 这是摘要的两个有界查询中的第一个：只返回排序与计数，不返回正文，因此可以按
/// `rooms_last_event_at_idx` 分页，而不必为每个房间读取事件或消息行。
public struct V2RoomActivityWatermark: Equatable, Sendable {
    /// 房间标识。
    public let roomID: RoomID
    /// 房间类型。
    public let roomKind: V2RoomKind
    /// 房间日志头。
    public let head: UInt64
    /// 房间日志头最后一次前进的时刻，自 1970 年起的微秒数。
    ///
    /// 它同时是分页排序键，因此以精确整数而不是浮点秒保存；毫秒精度会让同一毫秒
    /// 内结束的两个房间在翻页时被跳过。
    public let lastEventAtMicroseconds: Int64
    /// 未读数。
    public let unreadCount: UInt64

    /// 保存房间活动水位。
    ///
    /// - Parameters:
    ///   - roomID: 房间标识。
    ///   - roomKind: 房间类型。
    ///   - head: 房间日志头。
    ///   - lastEventAtMicroseconds: 房间日志头最后一次前进的时刻，自 1970 年起的微秒数。
    ///   - unreadCount: 未读数。
    public init(roomID: RoomID, roomKind: V2RoomKind, head: UInt64, lastEventAtMicroseconds: Int64, unreadCount: UInt64) {
        self.roomID = roomID
        self.roomKind = roomKind
        self.head = head
        self.lastEventAtMicroseconds = lastEventAtMicroseconds
        self.unreadCount = unreadCount
    }

    /// 事件时间的展示表示。
    public var lastEventAt: Date {
        Date(timeIntervalSince1970: Double(lastEventAtMicroseconds) / 1_000_000)
    }
}

/// 一页房间活动水位。
public struct V2RoomActivityPage: Equatable, Sendable {
    /// 本页水位。
    public let rooms: [V2RoomActivityWatermark]
    /// 是否还有后续房间。
    public let hasMore: Bool

    /// 保存一页房间活动水位。
    ///
    /// - Parameters:
    ///   - rooms: 本页水位。
    ///   - hasMore: 是否还有后续房间。
    public init(rooms: [V2RoomActivityWatermark], hasMore: Bool) {
        self.rooms = rooms
        self.hasMore = hasMore
    }
}

/// 会话列表读取的持久化能力。
///
/// 刻意拆成两个有界查询，而不是一个巨型 join：
///
/// - ``roomActivityWatermarks(after:actorUserID:limit:)`` 只做排序与计数，可以完全走
///   `rooms_last_event_at_idx` 与 `messages_room_sender_sequence_idx`；
/// - ``visibleMessages(roomIDs:actorUserID:)`` 只对**本页已经取出的**房间求最新可见
///   消息，房间集合由调用方限定，因此不会随用户房间总数增长。
///
/// 合并后的工作量为 O(页大小)，不随房间总数线性增长。
public protocol V2RoomSummaryStore: Sendable {
    /// 读取一页房间活动水位。
    ///
    /// - Parameters:
    ///   - cursor: 上一页游标；为空表示从最新活动开始。
    ///   - actorUserID: 发起查询的用户。
    ///   - limit: 本页最多返回的房间数，需大于零。
    /// - Returns: 按活动倒序排列的有界分页。
    /// - Throws: 参数越界或持久化状态损坏时抛出 ``V2RoomSummaryError``。
    func roomActivityWatermarks(
        after cursor: V2RoomSummaryCursor?,
        actorUserID: UserID,
        limit: Int
    ) async throws -> V2RoomActivityPage

    /// 读取指定房间对指定用户可见的最新消息摘要。
    ///
    /// - Parameters:
    ///   - roomIDs: 待查询房间；调用方必须传入有界集合。
    ///   - actorUserID: 发起查询的用户。
    /// - Returns: 每个有可见消息的房间各一条摘要。
    /// - Throws: 房间集合为空或持久化状态损坏时抛出 ``V2RoomSummaryError``。
    func visibleMessages(roomIDs: [RoomID], actorUserID: UserID) async throws -> [V2RoomSummaryMessage]
}

/// 会话列表服务。
///
/// 服务只负责合并两个有界查询并校验它们的一致性；授权与可见性谓词都在存储实现里，
/// 且与房间事件日志读取使用同一套"事件发生时成员 ∩ 当前成员"规则。
public struct V2RoomSummaryService: Sendable {
    private let store: any V2RoomSummaryStore

    /// 组合摘要存储。
    ///
    /// - Parameter store: 实际执行读取的存储实现。
    public init(store: any V2RoomSummaryStore) {
        self.store = store
    }

    /// 读取一页会话摘要。
    ///
    /// - Parameter request: 已校验的查询请求。
    /// - Returns: 页内有界且每行未读精确的会话摘要。
    /// - Throws: 存储返回自相矛盾的数据时抛出
    ///   ``V2RoomSummaryError/corruptPersistenceState``；其余错误来自存储实现。
    public func summaries(_ request: V2RoomSummaryRequest) async throws -> V2RoomSummaryPage {
        let activity = try await store.roomActivityWatermarks(
            after: request.cursor,
            actorUserID: request.actorUserID,
            limit: request.pageSize
        )
        let messages: [V2RoomSummaryMessage]
        if activity.rooms.isEmpty {
            messages = []
        } else {
            messages = try await store.visibleMessages(
                roomIDs: activity.rooms.map(\.roomID),
                actorUserID: request.actorUserID
            )
        }
        var latestByRoom: [RoomID: V2RoomSummaryMessage] = [:]
        for message in messages {
            guard latestByRoom.updateValue(message, forKey: message.roomID) == nil else {
                throw V2RoomSummaryError.corruptPersistenceState
            }
        }
        var seen: Set<RoomID> = []
        let rooms = try activity.rooms.map { watermark -> V2RoomSummary in
            guard seen.insert(watermark.roomID).inserted else {
                throw V2RoomSummaryError.corruptPersistenceState
            }
            let latest = latestByRoom[watermark.roomID]
            if let latest, latest.roomSequence > watermark.head {
                throw V2RoomSummaryError.corruptPersistenceState
            }
            return V2RoomSummary(
                roomID: watermark.roomID,
                roomKind: watermark.roomKind,
                head: watermark.head,
                lastEventAt: watermark.lastEventAt,
                unreadCount: watermark.unreadCount,
                latestMessage: latest
            )
        }
        let nextCursor = activity.hasMore
            ? activity.rooms.last.map {
                V2RoomSummaryCursor(lastEventAtMicroseconds: $0.lastEventAtMicroseconds, roomID: $0.roomID)
            }
            : nil
        return V2RoomSummaryPage(rooms: rooms, nextCursor: nextCursor)
    }
}

/// 会话摘要错误。
public enum V2RoomSummaryError: Error, Equatable, Sendable {
    /// 请求参数不满足约束。
    case invalidRequest
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}
