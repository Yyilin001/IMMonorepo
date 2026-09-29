import Foundation

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
