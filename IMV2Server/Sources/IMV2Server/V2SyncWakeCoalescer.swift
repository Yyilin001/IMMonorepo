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
}

/// 按用户合并同步可用性提示，并保留已知的最高持久化水位。
///
/// 通知是可丢失的加速提示，持久化事件仍须由客户端通过游标拉取恢复。
/// 每个用户在待发送区或当前批次中只占一个跟踪名额，在途期间的更高水位保留为后续通知。
/// 刷新使用有界任务组调用下游，避免单个慢连接使所有用户串行等待。
///
/// 调用方负责持有并取消 ``run()`` 的生命周期任务，也可以显式调用 ``flush()``。
/// 初始化不会启动任务；取消运行循环不将对象永久关闭，后续提交仍可能进入待发送区。
public actor V2SyncWakeCoalescer: V2LiveSyncNotifier {
    /// 一个用户待发送的事件提示及其最高持久化水位。
    private struct PendingWake: Sendable {
        var eventID: UInt64
        var highWatermark: UInt64
    }

    /// 从待发送区截取到某次刷新批次的不可变用户与提示组合。
    private struct Delivery: Sendable {
        let userID: UserID
        let wake: PendingWake
    }

    /// 当前批次提示与在其投递期间收到的更高水位，后者最多保留一份。
    private struct InFlightWake: Sendable {
        let delivering: PendingWake
        var followUp: PendingWake?
    }

    private let downstream: any V2LiveSyncNotifier
    private let interval: Duration
    private let maximumTrackedUsers: Int
    private let maximumConcurrentDeliveries: Int
    private let clock = ContinuousClock()
    private var pending: [UserID: PendingWake] = [:]
    private var inFlight: [UserID: InFlightWake] = [:]
    private var coalescedNotifications: UInt64 = 0
    private var deliveredNotifications: UInt64 = 0
    private var droppedNotifications: UInt64 = 0
    private var isRunning = false
    private var isFlushing = false

    /// 创建未启动的有界通知合并器。
    ///
    /// - Parameters:
    ///   - downstream: 实际投递提示的下游；调用完成不代表客户端确认。
    ///   - interval: 运行循环每轮刷新前的等待时长，必须为正；刷新耗时不包含在此间隔内。
    ///   - maximumPendingUsers: 待发送与在途用户合计的最大跟踪数量，必须大于零。
    ///   - maximumConcurrentDeliveries: 同一刷新批次最多并发调用的下游数量，必须大于零。
    /// - Precondition: 间隔及两个容量参数均为正数。
    public init(
        downstream: any V2LiveSyncNotifier,
        interval: Duration,
        maximumPendingUsers: Int,
        maximumConcurrentDeliveries: Int
    ) {
        precondition(interval > .zero)
        precondition(maximumPendingUsers > 0)
        precondition(maximumConcurrentDeliveries > 0)
        self.downstream = downstream
        self.interval = interval
        maximumTrackedUsers = maximumPendingUsers
        self.maximumConcurrentDeliveries = maximumConcurrentDeliveries
    }

    /// 提交可用性提示，按用户合并后留待刷新，不立即调用下游。
    ///
    /// 已在待发送区的用户保留较高水位，相同水位时使用本次事件标识替换旧值。
    /// 在途用户仅在水位严格超过当前投递及已有后续水位时更新后续提示。
    /// 新用户使总跟踪数超过上限时被丢弃并计数；已跟踪用户的合并不额外占用容量。
    ///
    /// - Parameters:
    ///   - userID: 需要唤醒同步拉取的用户。
    ///   - eventID: 与本次提示配对的事件标识，不单独取最大值。
    ///   - highWatermark: 调用方已知的持久化水位，用于选择保留哪一份提示。
    public func notifySyncAvailable(
        userID: UserID,
        eventID: UInt64,
        highWatermark: UInt64
    ) {
        if var existing = pending[userID] {
            coalescedNotifications = saturatingIncrement(coalescedNotifications)
            if highWatermark >= existing.highWatermark {
                existing.eventID = eventID
                existing.highWatermark = highWatermark
                pending[userID] = existing
            }
            return
        }
        if var existing = inFlight[userID] {
            coalescedNotifications = saturatingIncrement(coalescedNotifications)
            let knownHighWatermark = max(
                existing.delivering.highWatermark,
                existing.followUp?.highWatermark ?? 0
            )
            if highWatermark > knownHighWatermark {
                existing.followUp = .init(
                    eventID: eventID,
                    highWatermark: highWatermark
                )
                inFlight[userID] = existing
            }
            return
        }
        guard pending.count + inFlight.count < maximumTrackedUsers else {
            // Hints are explicitly lossy; clients recover through cursor pull.
            // Count every bounded-capacity drop, including while an earlier
            // flush is still in flight, so operators can see the real pressure.
            droppedNotifications = saturatingIncrement(droppedNotifications)
            return
        }
        pending[userID] = .init(eventID: eventID, highWatermark: highWatermark)
    }

    /// 运行周期刷新循环，直到生命周期任务取消或时钟等待抛错。
    ///
    /// 首轮也先等待配置间隔；每轮刷新完成后才开始下一次等待，因此不追赶错过的周期。
    /// 已有运行循环时重复调用立即返回。退出时将剩余待发送用户逐个计为丢弃并清空待发送区。
    ///
    /// 取消为协作式：当前刷新须等待下游任务返回，不提供强制超时，也不停止由其他任务
    /// 独立发起的刷新。调用方应先协调生产者停止提交，再取消并等待生命周期任务结束。
    public func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: interval)
            } catch {
                break
            }
            await flush()
        }
        dropPendingForShutdown()
    }

    /// 截取当前待发送用户，以有界并发向下游投递一轮提示。
    ///
    /// 已有刷新或没有待发送数据时立即返回，不等待正在进行的刷新。
    /// 当前批次从字典生成，不保证用户间顺序；每完成一个成员才补入下一位，限制并发数量。
    /// 批次期间的新用户及已完成成员的更高水位进入待发送区，由后续刷新处理。
    ///
    /// 子任务开始时已取消则跳过下游调用并计为丢弃；调用开始后仍等待下游返回，
    /// 返回即计为已投递，不表示客户端收到。此方法不将后续提示递归刷新到队列完全清空。
    public func flush() async {
        guard !isFlushing, !pending.isEmpty else { return }
        isFlushing = true
        let batch = pending.map { Delivery(userID: $0.key, wake: $0.value) }
        pending.removeAll(keepingCapacity: true)
        inFlight = Dictionary(uniqueKeysWithValues: batch.map { delivery in
            (delivery.userID, InFlightWake(delivering: delivery.wake, followUp: nil))
        })
        defer { isFlushing = false }

        let downstream = downstream
        func add(
            _ delivery: Delivery,
            to group: inout TaskGroup<(UserID, Bool)>
        ) {
            group.addTask {
                guard !Task.isCancelled else { return (delivery.userID, false) }
                await downstream.notifySyncAvailable(
                    userID: delivery.userID,
                    eventID: delivery.wake.eventID,
                    highWatermark: delivery.wake.highWatermark
                )
                return (delivery.userID, true)
            }
        }

        let concurrency = min(maximumConcurrentDeliveries, batch.count)
        var iterator = batch.makeIterator()
        await withTaskGroup(of: (UserID, Bool).self) { group in
            for _ in 0 ..< concurrency {
                guard let delivery = iterator.next() else { break }
                add(delivery, to: &group)
            }
            while let (userID, delivered) = await group.next() {
                let completed = inFlight.removeValue(forKey: userID)
                if let followUp = completed?.followUp {
                    pending[userID] = followUp
                }
                if delivered {
                    deliveredNotifications = saturatingIncrement(deliveredNotifications)
                }
                if !delivered {
                    droppedNotifications = saturatingIncrement(droppedNotifications)
                }
                guard let delivery = iterator.next() else { continue }
                add(delivery, to: &group)
            }
        }
        assert(inFlight.isEmpty)
    }

    /// 读取当前占用和累计结果，不触发刷新、不重置计数。
    ///
    /// - Returns: 当前 actor 状态对应的用户数与提示计数；在途用户数可能大于并发执行上限。
    public func snapshot() -> V2SyncWakeCoalescerSnapshot {
        .init(
            pendingUsers: pending.count,
            inFlightUsers: inFlight.count,
            coalescedNotifications: coalescedNotifications,
            deliveredNotifications: deliveredNotifications,
            droppedNotifications: droppedNotifications
        )
    }

    /// 运行循环退出时按待发送用户数增加丢弃计数并释放缓冲，不修改在途批次。
    private func dropPendingForShutdown() {
        guard !pending.isEmpty else { return }
        droppedNotifications = saturatingAdd(
            droppedNotifications,
            UInt64(pending.count)
        )
        pending.removeAll(keepingCapacity: false)
    }

    /// 饱和递增提示计数，防止长期运行时整数溢出。
    private func saturatingIncrement(_ value: UInt64) -> UInt64 {
        value == .max ? .max : value + 1
    }

    /// 累加提示计数，溢出时保持 `UInt64.max`。
    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}
