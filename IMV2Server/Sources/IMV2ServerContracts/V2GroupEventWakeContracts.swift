import Foundation
import IMV2Core

/// 混合群组房间事件提交后产生的纯元数据工作项。
///
/// 其载荷刻意不包含事件内容与接收者身份。
public struct V2GroupEventWake: Equatable, Sendable {
    public let roomID: RoomID
    public let highWatermark: UInt64

    public init(roomID: RoomID, highWatermark: UInt64) {
        self.roomID = roomID
        self.highWatermark = highWatermark
    }
}

public struct V2GroupEventWakeLease: Equatable, Sendable {
    public let wake: V2GroupEventWake
    public let revision: UInt64
    public let claimToken: UUID
    public let attempt: Int

    public init(wake: V2GroupEventWake, revision: UInt64, claimToken: UUID, attempt: Int) {
        self.wake = wake
        self.revision = revision
        self.claimToken = claimToken
        self.attempt = attempt
    }
}

public protocol V2GroupEventWakeStore: Sendable {
    func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2GroupEventWakeLease]
    /// 在发布进行期间，更新的某个事件可能已替换掉被认领的修订。
    ///
    /// 存储必须保留这条更新的水位线，而不是删除已合并的那一行。
    ///
    /// - Parameter lease: 已完成发布的租约。
    func markPublished(_ lease: V2GroupEventWakeLease) async throws
    func scheduleRetry(_ lease: V2GroupEventWakeLease, nextAttemptAt: Date) async throws
}

public protocol V2GroupEventWakePublishing: Sendable {
    func publish(_ wake: V2GroupEventWake) async throws
}

/// 群消息源事务提交后发出的尽力而为提示。
///
/// 与 `V2GroupEventWakePublishing` 不同，该契约没有发件箱、重试或投递义务。
/// 它唯一的目的是缩短一个已打开详情页拉取授权房间日志之前的等待时间。
public protocol V2ForegroundGroupEventHintPublishing: Sendable {
    func publishForegroundHint(_ hint: V2GroupEventWake) async
    func publishForegroundDirectEvent(_ event: V2DirectRoomLiveEvent) async
    func publishForegroundGroupEvents(_ events: [V2DirectRoomLiveEvent]) async
}

/// Gateway 接受路径使用的不挂起提交后边界。
///
/// 实现只能执行有界的进程本地入队工作。
/// 任何 broker、套接字、序列化或重试工作都归该边界之后由运行时拥有的消费者负责。
public protocol V2ForegroundGroupEventHintSubmitting: Sendable {
    func submitForegroundHint(_ hint: V2GroupEventWake)
    func submitForegroundDirectEvent(_ event: V2DirectRoomLiveEvent)
    func submitForegroundDirectMessage(_ message: V2AcceptedMessage)
    func submitForegroundDirectMessage(
        _ message: V2AcceptedMessage,
        excludingConnectionID: UUID?
    )
}

/// 群事件唤醒存储错误。
public enum V2GroupEventWakeStoreError: Error, Equatable, Sendable {
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}
