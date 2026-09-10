import Foundation
import IMV2Core

/// 已提交后用于加速活跃纯文本房间会话的实时事件载荷。
///
/// 它刻意不是持久化投递记录：丢失、重复与乱序都由既有房间日志游标修复。
/// 接收者集合取自提交该事件的同一加锁事务，因此网关绝不会依据之后可能过期的
/// 前台订阅推导授权。私聊房间携带精确的双方受众；群聊房间同时携带追加与订阅两侧的
/// 持久化成员修订，既避免逐消息枚举成员，又在任何成员变更后立即收敛为拒绝投递。
public struct V2DirectRoomLiveEvent: Equatable, Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 提交该事件时的房间水位。
    public let highWatermark: UInt64
    /// 来源事件标识。
    public let sourceEventID: EventID
    /// 事件在房间日志中的序号。
    public let roomSequence: UInt64
    /// 投影类型标识。
    public let projectionKind: String
    /// 已编码的事件载荷。
    public let payload: Data
    /// 私聊场景下的精确受众。
    public let recipientUserIDs: Set<UserID>
    /// 群聊广播时的成员修订；私聊为 `nil`。
    ///
    /// 路由注册表只会把载荷投递给恰好在该修订获得授权的订阅。
    public let groupMembershipRevision: UInt64?
    /// 接受事务记录的持久化成员栅栏。
    ///
    /// 套接字路由不需要它，但房间日志加速缓存可以借此复用已编码载荷，
    /// 无需为完整已接受消息再做一次复制与编码。
    let acceptedMembershipRevision: UInt64?
    /// 请求来源的进程内传输标识。
    ///
    /// 它只用于去除回送给该套接字的冗余回声，绝不构成受众授权；
    /// 在另一个网关上没有连接能匹配它，因此不会产生副作用。
    let excludedConnectionID: UUID?

    /// 保存实时事件。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - highWatermark: 提交时的房间水位。
    ///   - sourceEventID: 来源事件标识。
    ///   - roomSequence: 房间日志序号。
    ///   - projectionKind: 投影类型标识。
    ///   - payload: 已编码载荷。
    ///   - recipientUserIDs: 私聊受众。
    ///   - groupMembershipRevision: 群成员修订。
    ///   - acceptedMembershipRevision: 接受事务记录的成员栅栏。
    ///   - excludedConnectionID: 需要去重的来源连接。
    init(
        roomID: RoomID,
        highWatermark: UInt64,
        sourceEventID: EventID,
        roomSequence: UInt64,
        projectionKind: String,
        payload: Data,
        recipientUserIDs: Set<UserID>,
        groupMembershipRevision: UInt64? = nil,
        acceptedMembershipRevision: UInt64? = nil,
        excludedConnectionID: UUID? = nil
    ) {
        self.roomID = roomID
        self.highWatermark = highWatermark
        self.sourceEventID = sourceEventID
        self.roomSequence = roomSequence
        self.projectionKind = projectionKind
        self.payload = payload
        self.recipientUserIDs = recipientUserIDs
        self.groupMembershipRevision = groupMembershipRevision
        self.acceptedMembershipRevision = acceptedMembershipRevision
        self.excludedConnectionID = excludedConnectionID
    }

    /// 由已接受消息构造私聊实时事件。
    ///
    /// - Parameter message: 已接受消息。
    /// - Returns: 满足私聊快速路径条件时的事件；否则为 `nil`。
    public init?(_ message: V2AcceptedMessage) {
        guard let draft = V2DirectRoomLiveEventDraft(message),
              let materialized = draft.materialized()
        else { return nil }
        self = materialized
    }

    /// 编码消息对应的房间日志载荷。
    ///
    /// - Parameter message: 已接受消息。
    /// - Returns: 规范 JSON 载荷；无法投影时间戳时为 `nil`。
    static func payload(for message: V2AcceptedMessage) -> Data? {
        V2DirectRoomLogPayloadCodec.encode(message)
    }
}

/// 让已排序的生产微批保持共享写时复制存储，避免多余拷贝。
///
/// 兼容调用方仍可能传入乱序事件，此时退回既有的确定性排序。该函数刻意保持内部可见：
/// 对外契约始终是持久化房间序号，而不是到达顺序。
///
/// - Parameter events: 待排序的实时事件。
/// - Returns: 原始数组（已有序时）或按房间序号升序的新数组。
@inline(__always)
func v2GroupEventsOrderedByRoomSequence(
    _ events: [V2DirectRoomLiveEvent]
) -> [V2DirectRoomLiveEvent] {
    guard events.count > 1 else { return events }
    for index in 1..<events.count
    where events[index - 1].roomSequence > events[index].roomSequence {
        return events.sorted { $0.roomSequence < $1.roomSequence }
    }
    return events
}

/// ``V2DirectRoomLiveEventDraft`` 的群聊对应实现。
///
/// 它刻意只支持已经规范化的纯文本混合大群消息形态；更丰富的消息仍走持久化游标路径，
/// 直到其载荷契约可以在不改变语义的前提下被复用。
struct V2GroupRoomLiveEventDraft: Equatable, Sendable {
    /// 已接受消息。
    let message: V2AcceptedMessage
    /// 来源事件标识。
    let sourceEventID: EventID
    /// 接受事务记录的成员修订。
    let membershipRevision: UInt64
    /// 需要去重的来源连接。
    let excludedConnectionID: UUID?

    /// 由已接受消息构造群聊草稿。
    ///
    /// 群聊批次必须对所有套接字保持字节一致且受众一致：发送方可能已根据接受回执推进本地游标
    /// 并跳过该重复条目，若按事件排除来源连接就会破坏「一次编码」特性，
    /// 因此此处刻意不设置排除连接。
    ///
    /// - Parameters:
    ///   - message: 已接受消息。
    ///   - excludingConnectionID: 忽略；群聊批次不使用该参数。
    /// - Returns: 满足条件时返回草稿；否则为 `nil`。
    init?(
        _ message: V2AcceptedMessage,
        excludingConnectionID: UUID? = nil
    ) {
        guard message.usesRoomEventLog,
              message.groupDeliveryMode == .largeGroupHybrid,
              message.media.isEmpty,
              message.mentions.isEmpty,
              message.replyTo == nil,
              let sourceEventID = message.sourceEventID,
              let membershipRevision = message.acceptedMembershipRevision
        else { return nil }
        self.message = message
        self.sourceEventID = sourceEventID
        self.membershipRevision = membershipRevision
        // A group batch must have one byte-identical representation and one
        // audience for every socket. The sender may already have advanced its
        // local cursor from the acceptance ACK and will simply skip the
        // duplicate entry; per-event connection exclusion would destroy the
        // encode-once property.
        self.excludedConnectionID = nil
    }

    /// 物化为实时事件。
    ///
    /// - Returns: 可投递事件；载荷编码失败时为 `nil`。
    func materialized() -> V2DirectRoomLiveEvent? {
        guard let payload = V2DirectRoomLiveEvent.payload(for: message) else { return nil }
        return .init(
            roomID: message.roomID,
            highWatermark: message.roomSequence,
            sourceEventID: sourceEventID,
            roomSequence: message.roomSequence,
            projectionKind: "message",
            payload: payload,
            recipientUserIDs: [],
            groupMembershipRevision: membershipRevision,
            acceptedMembershipRevision: membershipRevision,
            excludedConnectionID: excludedConnectionID
        )
    }
}

/// 私聊实时事件草稿。
///
/// 前台提示队列只保留已提交的不可变接受数据，JSON 构造刻意推迟到队列后台中继执行时进行：
/// 不能仅因为对端当前打开了该房间，就让发送方的接受响应承担两次 JSON 转换。
struct V2DirectRoomLiveEventDraft: Equatable, Sendable {
    /// 已接受消息。
    let message: V2AcceptedMessage
    /// 来源事件标识。
    let sourceEventID: EventID
    /// 私聊双方受众。
    let recipientUserIDs: Set<UserID>
    /// 需要去重的来源连接。
    let excludedConnectionID: UUID?

    /// 由已接受消息构造私聊草稿。
    ///
    /// 仅接受带房间事件日志、非群聊、无媒体与提及、无引用回复，且已具备来源事件标识、
    /// 接受成员修订与有效对端用户的纯文本消息。
    ///
    /// - Parameters:
    ///   - message: 已接受消息。
    ///   - excludingConnectionID: 需要去重的来源连接。
    /// - Returns: 满足条件时返回草稿；否则为 `nil`。
    init?(
        _ message: V2AcceptedMessage,
        excludingConnectionID: UUID? = nil
    ) {
        guard message.usesRoomEventLog,
              message.groupDeliveryMode == nil,
              message.media.isEmpty,
              message.mentions.isEmpty,
              message.replyTo == nil,
              let sourceEventID = message.sourceEventID,
              message.acceptedMembershipRevision != nil,
              let directRecipientUserID = message.directRecipientUserID,
              directRecipientUserID != message.senderUserID
        else { return nil }
        self.message = message
        self.sourceEventID = sourceEventID
        recipientUserIDs = [message.senderUserID, directRecipientUserID]
        self.excludedConnectionID = excludingConnectionID
    }

    /// 物化为实时事件。
    ///
    /// - Returns: 可投递事件；载荷编码失败时为 `nil`。
    func materialized() -> V2DirectRoomLiveEvent? {
        guard let payload = V2DirectRoomLiveEvent.payload(for: message) else { return nil }
        return .init(
            roomID: message.roomID,
            highWatermark: message.roomSequence,
            sourceEventID: sourceEventID,
            roomSequence: message.roomSequence,
            projectionKind: "message",
            payload: payload,
            recipientUserIDs: recipientUserIDs,
            acceptedMembershipRevision: message.acceptedMembershipRevision,
            excludedConnectionID: excludedConnectionID
        )
    }
}
