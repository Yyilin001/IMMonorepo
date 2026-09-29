import Foundation
import IMV2Core

/// 同步唤醒合并器的即时占用与生命周期累计计数。
///
/// 统计针对尽力发送的可用性提示，不表示客户端已经收取或确认持久化事件。
/// 累计计数在达到 `UInt64.max` 后保持最大值。
public struct V2SyncWakeCoalescerSnapshot: Equatable, Sendable {
    /// 等待下一次刷新通知的不同用户数。
    public let pendingUsers: Int
    /// 当前刷新批次尚未完成的用户数，包含尚未获得并发执行机会的批次成员。
    public let inFlightUsers: Int
    /// 新通知命中待发送或在途用户时的累计合并次数，包含未推进水位的重复通知。
    public let coalescedNotifications: UInt64
    /// 下游通知调用已返回的累计次数，不保证网络送达或客户端确认。
    public let deliveredNotifications: UInt64
    /// 容量不足、子任务开始前取消及运行循环退出时丢弃待发送提示的累计数量。
    public let droppedNotifications: UInt64

    package init(pendingUsers: Int, inFlightUsers: Int, coalescedNotifications: UInt64,
                 deliveredNotifications: UInt64, droppedNotifications: UInt64) {
        self.pendingUsers = pendingUsers
        self.inFlightUsers = inFlightUsers
        self.coalescedNotifications = coalescedNotifications
        self.deliveredNotifications = deliveredNotifications
        self.droppedNotifications = droppedNotifications
    }
}
