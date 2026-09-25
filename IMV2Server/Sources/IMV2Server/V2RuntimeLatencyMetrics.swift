import Foundation
import Synchronization
@preconcurrency import NIOCore
@preconcurrency import NIOPosix

/// 运行时诊断共用的固定累积直方图桶，原始值为含端点的毫秒上界。
///
/// 边界固定，不携带用户、房间、请求或数据库标识，可映射为有限数量的指标标签。
public enum V2RuntimeLatencyBucket: Int, CaseIterable, Sendable {
    /// 耗时不超过 1 毫秒的累计样本。
    case milliseconds1 = 1
    /// 耗时不超过 2 毫秒的累计样本。
    case milliseconds2 = 2
    /// 耗时不超过 4 毫秒的累计样本。
    case milliseconds4 = 4
    /// 耗时不超过 8 毫秒的累计样本。
    case milliseconds8 = 8
    /// 耗时不超过 16 毫秒的累计样本。
    case milliseconds16 = 16
    /// 耗时不超过 32 毫秒的累计样本。
    case milliseconds32 = 32
    /// 耗时不超过 64 毫秒的累计样本。
    case milliseconds64 = 64
    /// 耗时不超过 128 毫秒的累计样本。
    case milliseconds128 = 128
    /// 耗时不超过 256 毫秒的累计样本。
    case milliseconds256 = 256
    /// 耗时不超过 512 毫秒的累计样本。
    case milliseconds512 = 512
    /// 耗时不超过 1,000 毫秒的累计样本。
    case milliseconds1_000 = 1_000
    /// 耗时不超过 2,000 毫秒的累计样本。
    case milliseconds2_000 = 2_000
    /// 耗时不超过 5,000 毫秒的累计样本。
    case milliseconds5_000 = 5_000
}

/// 耗时总数、累计值、最大值与固定累积桶的不可变快照。
///
/// 一个样本计入所有覆盖它的桶；超过最大桶的样本仍计入总数、总和与最大值。
/// 零毫秒也是有效样本，不代表未采样。
public struct V2RuntimeLatencyHistogramSnapshot: Equatable, Sendable {
    /// 样本总数，包含零值与超过最大有限桶的样本。
    public let samples: UInt64
    /// 累计耗时毫秒数，内部记录器使用饱和加法。
    public let sumMilliseconds: UInt64
    /// 已观察到的最大毫秒值；空快照为零。
    public let maximumMilliseconds: UInt64
    private let cumulativeBuckets: [V2RuntimeLatencyBucket: UInt64]

    /// 保存直方图数据，不校验计数间的一致性。
    ///
    /// - Parameters:
    ///   - samples: 样本总数。
    ///   - sumMilliseconds: 累计耗时毫秒数。
    ///   - maximumMilliseconds: 最大耗时毫秒数。
    ///   - cumulativeBuckets: 各含端点上界内的累计样本数。
    public init(
        samples: UInt64,
        sumMilliseconds: UInt64,
        maximumMilliseconds: UInt64,
        cumulativeBuckets: [V2RuntimeLatencyBucket: UInt64]
    ) {
        self.samples = samples
        self.sumMilliseconds = sumMilliseconds
        self.maximumMilliseconds = maximumMilliseconds
        self.cumulativeBuckets = cumulativeBuckets
    }

    /// 读取指定上界内的累计样本数。
    ///
    /// - Parameter bucket: 含端点的毫秒上界。
    /// - Returns: 保存的累计计数；缺失桶返回零。
    public func count(atOrBelow bucket: V2RuntimeLatencyBucket) -> UInt64 {
        cumulativeBuckets[bucket, default: 0]
    }

    /// 尚无样本的全零直方图。
    public static let empty = Self(
        samples: 0,
        sumMilliseconds: 0,
        maximumMilliseconds: 0,
        cumulativeBuckets: [:]
    )
}

/// 可变的饱和直方图累加器，并发访问由外层互斥锁保护。
private struct V2RuntimeLatencyAccumulator: Sendable {
    var samples: UInt64 = 0
    var sumMilliseconds: UInt64 = 0
    var maximumMilliseconds: UInt64 = 0
    var buckets: [V2RuntimeLatencyBucket: UInt64] = [:]

    mutating func record(milliseconds: UInt64) {
        samples = saturatingIncrement(samples)
        sumMilliseconds = saturatingAdd(sumMilliseconds, milliseconds)
        maximumMilliseconds = max(maximumMilliseconds, milliseconds)
        for bucket in V2RuntimeLatencyBucket.allCases where milliseconds <= bucket.rawValue {
            buckets[bucket] = saturatingIncrement(buckets[bucket, default: 0])
        }
    }

    var snapshot: V2RuntimeLatencyHistogramSnapshot {
        .init(
            samples: samples,
            sumMilliseconds: sumMilliseconds,
            maximumMilliseconds: maximumMilliseconds,
            cumulativeBuckets: buckets
        )
    }
}

/// 私聊追加路径使用的固定计时阶段，原始字符串属于运维指标约定。
///
/// 调用方决定各阶段的实际计时边界。阶段可能嵌套或重叠，不能直接相加作为请求总耗时。
/// 不应使用动态分片、关系名、房间或请求标识扩展阶段集合。
public enum V2DirectRoomLogAppendStage: String, CaseIterable, Sendable {
    /// 快速路径探测阶段。
    case fastPathProbe = "fast_path_probe"
    /// 加速路径整体阶段。
    case acceleratedTotal = "accelerated_total"
    /// 缓存查询阶段。
    case cacheLookup = "cache_lookup"
    /// 数据库事务阶段。
    case transaction = "transaction"
    /// 操作锁获取阶段。
    case operationLocks = "operation_locks"
    /// 授权预检查阶段。
    case authorizationPreflight = "authorization_preflight"
    /// 追加准备阶段。
    case preparation
    /// 策略变更阶段。
    case policyMutations = "policy_mutations"
    /// 消息持久化阶段。
    case messagePersistence = "message_persistence"
    /// 投影持久化阶段。
    case projectionPersistence = "projection_persistence"
    /// 缓存收尾阶段。
    case cacheFinalization = "cache_finalization"
    /// 提交后缓存与额度收尾阶段。
    case commitFinalization = "commit_finalization"
}

/// 按追加阶段保存的耗时分布，未采样阶段读取为全零直方图。
public struct V2DirectRoomLogAppendStageMetricsSnapshot: Equatable, Sendable {
    private let histograms: [V2DirectRoomLogAppendStage: V2RuntimeLatencyHistogramSnapshot]

    /// 保存已采集的阶段分布。
    ///
    /// - Parameter histograms: 阶段与直方图映射，允许省略未采样阶段。
    public init(
        histograms: [V2DirectRoomLogAppendStage: V2RuntimeLatencyHistogramSnapshot]
    ) {
        self.histograms = histograms
    }

    /// 读取一个阶段的分布。
    ///
    /// - Parameter stage: 固定计时阶段。
    /// - Returns: 对应分布，缺失时返回全零快照。
    public func value(
        for stage: V2DirectRoomLogAppendStage
    ) -> V2RuntimeLatencyHistogramSnapshot {
        histograms[stage] ?? .empty
    }
}

/// 可在 PostgreSQL 事务中同步调用的线程安全阶段耗时记录器。
///
/// 只在互斥锁内修改内存，不挂起、不获取数据库连接，也不进入 actor，避免嵌套连接池访问。
/// 同步调用仍可能等待互斥锁，不保证无锁执行。
public final class V2DirectRoomLogAppendStageMetrics: Sendable {
    private let state = Mutex([V2DirectRoomLogAppendStage: V2RuntimeLatencyAccumulator]())

    /// 创建尚未采样的记录器。
    public init() {}

    /// 记录一次阶段耗时，不清空先前样本。
    ///
    /// - Parameters:
    ///   - stage: 样本所属固定阶段。
    ///   - duration: 测得的持续时间；负值计为零，正值截断为完整毫秒，溢出饱和到 `UInt64.max`。
    public func record(
        _ stage: V2DirectRoomLogAppendStage,
        duration: Duration
    ) {
        record(stage, milliseconds: runtimeMilliseconds(duration))
    }

    /// 记录一次阶段耗时，不清空先前样本。
    ///
    /// - Parameters:
    ///   - stage: 样本所属固定阶段。
    ///   - milliseconds: 已转换的完整毫秒值，零值也会增加样本数。
    public func record(
        _ stage: V2DirectRoomLogAppendStage,
        milliseconds: UInt64
    ) {
        state.withLock { state in
            state[stage, default: .init()].record(milliseconds: milliseconds)
        }
    }

    /// 在同一次锁定中复制全部阶段分布，不重置计数。
    ///
    /// - Returns: 当前已采样阶段的不可变分布。
    public func snapshot() -> V2DirectRoomLogAppendStageMetricsSnapshot {
        state.withLock { state in
            .init(histograms: state.mapValues(\.snapshot))
        }
    }
}

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

/// 把非负耗时截断为完整毫秒；负值返回零，乘加溢出饱和到无符号最大值。
private func runtimeMilliseconds(_ duration: Duration) -> UInt64 {
    let components = duration.components
    guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
    let seconds = UInt64(components.seconds)
    let secondsMilliseconds = seconds.multipliedReportingOverflow(by: 1_000)
    guard !secondsMilliseconds.overflow else { return .max }
    let fractionalMilliseconds = UInt64(components.attoseconds / 1_000_000_000_000_000)
    return saturatingAdd(secondsMilliseconds.partialValue, fractionalMilliseconds)
}

/// 饱和递增计数，达到最大值后不变。
private func saturatingIncrement(_ value: UInt64) -> UInt64 {
    value == .max ? .max : value + 1
}

/// 饱和累加两个计数，溢出返回最大值。
private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let sum = lhs.addingReportingOverflow(rhs)
    return sum.overflow ? .max : sum.partialValue
}
