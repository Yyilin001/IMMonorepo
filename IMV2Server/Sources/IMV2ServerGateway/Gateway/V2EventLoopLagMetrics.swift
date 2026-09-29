import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import Synchronization
@preconcurrency import NIOCore
@preconcurrency import NIOPosix

/// 通过低频定时任务测量 SwiftNIO 事件循环的调度延迟。
///
/// 每个循环独立安排探测，默认间隔 100 毫秒；样本是实际回调时刻超出预期时刻的部分。
/// 下一轮从实际回调时刻安排，不密集补执行错过周期。所有循环共用直方图，不添加循环身份标签。
/// 停止通过运行标记和代次使旧回调失效，不持有定时任务取消句柄。
public final class V2EventLoopLagMetrics: Sendable {
    private struct State: Sendable {
        var isRunning = false
        var generation: UInt64 = 0
        var latency = V2RuntimeLatencyAccumulator()
    }

    private let intervalNanoseconds: UInt64
    private let state = Mutex(State())

    /// 配置探测频率，初始化不会开始调度。
    ///
    /// - Parameter intervalMilliseconds: 间隔毫秒数，默认 100。
    /// - Precondition: 间隔在 10 至 1,000 毫秒之间，包含两端。
    public init(intervalMilliseconds: Int = 100) {
        precondition((10 ... 1_000).contains(intervalMilliseconds))
        intervalNanoseconds = UInt64(intervalMilliseconds) * 1_000_000
    }

    /// 在组内每个事件循环上安排本代第一次探测。
    ///
    /// 停止后可以再次启动，历史直方图不会清零。调用方负责事件循环组的关闭。
    ///
    /// - Parameter group: 由运行时管理生命周期的事件循环组。
    /// - Precondition: 当前未运行，且本次递增后的代次不为零。
    public func start(on group: MultiThreadedEventLoopGroup) {
        let generation = state.withLock { state -> UInt64 in
            precondition(!state.isRunning, "event-loop lag metrics started more than once")
            state.isRunning = true
            state.generation &+= 1
            precondition(state.generation != 0, "event-loop lag metrics generation exhausted")
            return state.generation
        }
        for eventLoop in Array(group.makeIterator()) {
            schedule(
                on: eventLoop,
                expected: .now() + .nanoseconds(Int64(intervalNanoseconds)),
                generation: generation
            )
        }
    }

    /// 停止后续有效采样并推进代次，保留历史直方图。
    ///
    /// 不等待已执行回调结束，不撤销已入队定时任务。与停止交错的回调可能再安排一个旧代次
    /// 任务，该任务触发时会因运行状态或代次失效而退出。
    public func stop() {
        state.withLock { state in
            state.isRunning = false
            state.generation &+= 1
        }
    }

    /// 读取自动与手动探测共同形成的累计分布，不改变运行状态。
    ///
    /// - Returns: 当前锁保护下的一致直方图快照。
    public func snapshot() -> V2RuntimeLatencyHistogramSnapshot {
        state.withLock { $0.latency.snapshot }
    }

    /// 手动注入外部探测器或测试测得的延迟。
    ///
    /// - Parameter milliseconds: 完整毫秒延迟，零值也作为样本。
    ///
    /// 不要求处于运行状态，与自动探测共享分布；调用方应避免重复记录同一观测。
    public func recordLag(milliseconds: UInt64) {
        state.withLock { $0.latency.record(milliseconds: milliseconds) }
    }

    /// 以弱引用安排单次回调，携带预期时刻和代次。
    private func schedule(
        on eventLoop: any EventLoop,
        expected: NIODeadline,
        generation: UInt64
    ) {
        eventLoop.scheduleTask(deadline: expected) { [weak self] in
            self?.sample(on: eventLoop, expected: expected, generation: generation)
        }
    }

    /// 检查运行代次并记录完整毫秒延迟，从实际回调时刻安排下一轮。
    private func sample(
        on eventLoop: any EventLoop,
        expected: NIODeadline,
        generation: UInt64
    ) {
        let now = NIODeadline.now()
        let shouldContinue = state.withLock { state -> Bool in
            guard state.isRunning, state.generation == generation else { return false }
            let lagNanoseconds = now.uptimeNanoseconds > expected.uptimeNanoseconds
                ? now.uptimeNanoseconds - expected.uptimeNanoseconds
                : 0
            state.latency.record(milliseconds: lagNanoseconds / 1_000_000)
            return true
        }
        guard shouldContinue else { return }
        schedule(
            on: eventLoop,
            expected: now + .nanoseconds(Int64(intervalNanoseconds)),
            generation: generation
        )
    }
}
