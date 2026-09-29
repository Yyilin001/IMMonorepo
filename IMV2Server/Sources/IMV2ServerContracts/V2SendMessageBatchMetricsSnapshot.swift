import Foundation

public struct V2SendMessageBatchMetricsSnapshot: Equatable, Sendable {
    public let pendingRequests: Int
    public let inFlightBatches: Int
    public let activeRooms: Int
    /// 该快照所代表的、彼此隔离的批处理通道数量。
    ///
    /// 单个 actor 报告 1；按房间建键的路由器会汇总其各通道，并在下方同时报告最繁忙通道。
    public let laneCount: Int
    public let busiestLanePendingRequests: Int
    public let busiestLaneInFlightBatches: Int
    /// 单调的阶段耗时，用于揭示延迟是累积在出队之前，还是在批次开始持久执行路径之后。
    public let dequeuedRequests: UInt64
    public let queueWaitMillisecondsTotal: UInt64
    public let queueWaitMillisecondsMax: UInt64
    public let completedBatches: UInt64
    public let batchExecutionMillisecondsTotal: UInt64
    public let batchExecutionMillisecondsMax: UInt64
    public let stagingQueueFullRejections: UInt64
    public let cancelledPendingRequests: UInt64
    /// 使用常规交互延迟预算的延迟刷新次数。
    ///
    /// 它刻意统计实际触发的计时器数量，而不是请求数，
    /// 使运维遥测不会把取消或整批刷新误当成额外的排队延迟。
    public let baseDelayFlushes: UInt64
    /// 在有界到达率检测器被满足之后，使用显式配置的高活跃预算的延迟刷新次数。
    public let highActivityDelayFlushes: UInt64
    /// 当前暂存的首个请求是否正以高活跃预算等待。
    ///
    /// 它仅供诊断；硬性延迟上限仍由已排定的计时器持有。
    public let highActivityDelayScheduled: Bool
    /// 包含两个或更多独立房间的原子追加尝试次数。
    ///
    /// 这些计数器刻意区分成功的集合写入与形态回退，
    /// 使运维可以衡量真实的 SQL 合并程度，而不是仅凭暂存延迟去推断。
    public let atomicBatchAttempts: UInt64
    public let atomicBatchCommitted: UInt64
    public let atomicBatchFallbacks: UInt64
    public let atomicBatchCommittedRequests: UInt64
    public let atomicBatchFallbackRequests: UInt64
    /// 权威存储在某个原子子集于任何持久提交之前回滚时所报告的、有界的原因计数。
    public let atomicBatchFallbackReasons: [V2AtomicRoomWriteBatchError.Reason: UInt64]
    /// 同一房间中刻意排在首条命令之后、并在后续唯一房间波次中执行的命令数。
    public let sameRoomDeferredRequests: UInt64
    /// 在原子尝试之前就已确知需要走常规持久路径的请求。
    ///
    /// 它们不会让一个本可兼容的批次放弃其共享事务。
    public let atomicPreclassifiedIndividualRequests: UInt64
    /// 延迟后仍不足量的批次会直接派发，而不会先从存储抛出预期的不支持形态错误。
    public let singletonDispatches: UInt64

    public init(
        pendingRequests: Int,
        inFlightBatches: Int,
        activeRooms: Int,
        laneCount: Int = 1,
        busiestLanePendingRequests: Int? = nil,
        busiestLaneInFlightBatches: Int? = nil,
        dequeuedRequests: UInt64 = 0,
        queueWaitMillisecondsTotal: UInt64 = 0,
        queueWaitMillisecondsMax: UInt64 = 0,
        completedBatches: UInt64 = 0,
        batchExecutionMillisecondsTotal: UInt64 = 0,
        batchExecutionMillisecondsMax: UInt64 = 0,
        stagingQueueFullRejections: UInt64,
        cancelledPendingRequests: UInt64,
        baseDelayFlushes: UInt64,
        highActivityDelayFlushes: UInt64,
        highActivityDelayScheduled: Bool,
        atomicBatchAttempts: UInt64 = 0,
        atomicBatchCommitted: UInt64 = 0,
        atomicBatchFallbacks: UInt64 = 0,
        atomicBatchCommittedRequests: UInt64 = 0,
        atomicBatchFallbackRequests: UInt64 = 0,
        atomicBatchFallbackReasons: [V2AtomicRoomWriteBatchError.Reason: UInt64] = [:],
        sameRoomDeferredRequests: UInt64 = 0,
        atomicPreclassifiedIndividualRequests: UInt64 = 0,
        singletonDispatches: UInt64 = 0
    ) {
        self.pendingRequests = pendingRequests
        self.inFlightBatches = inFlightBatches
        self.activeRooms = activeRooms
        self.laneCount = laneCount
        self.busiestLanePendingRequests = busiestLanePendingRequests ?? pendingRequests
        self.busiestLaneInFlightBatches = busiestLaneInFlightBatches ?? inFlightBatches
        self.dequeuedRequests = dequeuedRequests
        self.queueWaitMillisecondsTotal = queueWaitMillisecondsTotal
        self.queueWaitMillisecondsMax = queueWaitMillisecondsMax
        self.completedBatches = completedBatches
        self.batchExecutionMillisecondsTotal = batchExecutionMillisecondsTotal
        self.batchExecutionMillisecondsMax = batchExecutionMillisecondsMax
        self.stagingQueueFullRejections = stagingQueueFullRejections
        self.cancelledPendingRequests = cancelledPendingRequests
        self.baseDelayFlushes = baseDelayFlushes
        self.highActivityDelayFlushes = highActivityDelayFlushes
        self.highActivityDelayScheduled = highActivityDelayScheduled
        self.atomicBatchAttempts = atomicBatchAttempts
        self.atomicBatchCommitted = atomicBatchCommitted
        self.atomicBatchFallbacks = atomicBatchFallbacks
        self.atomicBatchCommittedRequests = atomicBatchCommittedRequests
        self.atomicBatchFallbackRequests = atomicBatchFallbackRequests
        self.atomicBatchFallbackReasons = atomicBatchFallbackReasons
        self.sameRoomDeferredRequests = sameRoomDeferredRequests
        self.atomicPreclassifiedIndividualRequests = atomicPreclassifiedIndividualRequests
        self.singletonDispatches = singletonDispatches
    }
}
