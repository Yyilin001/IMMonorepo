import IMV2ServerContracts
import Foundation
import Synchronization





/// 可变的饱和直方图累加器，并发访问由外层互斥锁保护。
package struct V2RuntimeLatencyAccumulator: Sendable {
    package init() {}
    var samples: UInt64 = 0
    var sumMilliseconds: UInt64 = 0
    var maximumMilliseconds: UInt64 = 0
    var buckets: [V2RuntimeLatencyBucket: UInt64] = [:]

    package mutating func record(milliseconds: UInt64) {
        samples = saturatingIncrement(samples)
        sumMilliseconds = saturatingAdd(sumMilliseconds, milliseconds)
        maximumMilliseconds = max(maximumMilliseconds, milliseconds)
        for bucket in V2RuntimeLatencyBucket.allCases where milliseconds <= bucket.rawValue {
            buckets[bucket] = saturatingIncrement(buckets[bucket, default: 0])
        }
    }

    package var snapshot: V2RuntimeLatencyHistogramSnapshot {
        .init(
            samples: samples,
            sumMilliseconds: sumMilliseconds,
            maximumMilliseconds: maximumMilliseconds,
            cumulativeBuckets: buckets
        )
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
