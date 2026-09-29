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
    package let acceptedMembershipRevision: UInt64?
    /// 请求来源的进程内传输标识。
    ///
    /// 它只用于去除回送给该套接字的冗余回声，绝不构成受众授权；
    /// 在另一个网关上没有连接能匹配它，因此不会产生副作用。
    package let excludedConnectionID: UUID?

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
    package init(
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

}

/// 让已排序的生产微批保持共享写时复制存储，避免多余拷贝。
///
/// 兼容调用方仍可能传入乱序事件，此时退回既有的确定性排序。该函数刻意保持内部可见：
/// 对外契约始终是持久化房间序号，而不是到达顺序。
///
/// - Parameter events: 待排序的实时事件。
/// - Returns: 原始数组（已有序时）或按房间序号升序的新数组。
@inline(__always)
package func v2GroupEventsOrderedByRoomSequence(
    _ events: [V2DirectRoomLiveEvent]
) -> [V2DirectRoomLiveEvent] {
    guard events.count > 1 else { return events }
    for index in 1..<events.count
    where events[index - 1].roomSequence > events[index].roomSequence {
        return events.sorted { $0.roomSequence < $1.roomSequence }
    }
    return events
}
