import Foundation
import IMV2Core

/// 动态房间订阅与持久化唤醒发件箱工作刻意分离。
///
/// 网络分区期间代理可能丢失订阅，但客户端游标与低频恢复拉取依然保证正确性。
public protocol V2GroupEventWakeInterestManaging: Sendable {
    /// 订阅指定房间的事件唤醒。
    ///
    /// - Parameter roomID: 目标房间。
    /// - Throws: 连接或订阅失败时抛出。
    func activate(roomID: RoomID) async throws

    /// 取消指定房间的事件唤醒订阅。
    ///
    /// - Parameter roomID: 目标房间。
    func deactivate(roomID: RoomID) async
}

/// 面向瞬时活动的尽力而为跨网关扇出。
///
/// 隐私与在线状态的权威仍在 PostgreSQL；该代理只是避免当对端连接在另一个网关副本上时，
/// 必须等对方重新打开视图才能收到提示。
public protocol V2LiveActivityInterestManaging: Sendable {
    /// 订阅指定用户的在线状态变化。
    ///
    /// - Parameter targetUserID: 被关注的用户。
    /// - Throws: 连接或订阅失败时抛出。
    func activatePresence(targetUserID: UserID) async throws

    /// 取消指定用户的在线状态订阅。
    ///
    /// - Parameter targetUserID: 目标用户。
    func deactivatePresence(targetUserID: UserID) async

    /// 订阅指定房间的正在输入提示。
    ///
    /// - Parameter roomID: 目标房间。
    /// - Throws: 连接或订阅失败时抛出。
    func activateTyping(roomID: RoomID) async throws

    /// 取消指定房间的正在输入提示订阅。
    ///
    /// - Parameter roomID: 目标房间。
    func deactivateTyping(roomID: RoomID) async
}

/// 瞬时活动的发布能力。
public protocol V2LiveActivityPublishing: Sendable {
    /// 发布一次在线状态变化。
    ///
    /// - Parameters:
    ///   - targetUserID: 状态变化的用户。
    ///   - isOnline: 是否在线。
    ///   - expiresAt: 该状态的过期时刻。
    func publishPresence(targetUserID: UserID, isOnline: Bool, expiresAt: Date) async

    /// 发布一次正在输入状态。
    ///
    /// - Parameter state: 正在输入状态。
    func publishTyping(_ state: V2TypingState) async
}
