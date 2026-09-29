import IMV2ServerContracts
import Foundation

/// 对通道与物理所有者快照进行共享计数聚合。
package enum V2SendMessageBatchSnapshotAggregator {
    /// 聚合子通道，包括本身已包含通道信息的快照。
    ///
    /// - Parameter snapshots: 各通道快照。
    /// - Returns: 聚合后的快照。
    package static func aggregate(
        _ snapshots: [V2SendMessageBatchMetricsSnapshot]
    ) -> V2SendMessageBatchMetricsSnapshot {
        .init(
            pendingRequests: saturatingIntSum(snapshots.map(\.pendingRequests)),
            inFlightBatches: saturatingIntSum(snapshots.map(\.inFlightBatches)),
            activeRooms: saturatingIntSum(snapshots.map(\.activeRooms)),
            laneCount: saturatingIntSum(snapshots.map(\.laneCount)),
            busiestLanePendingRequests: snapshots.map(\.busiestLanePendingRequests).max() ?? 0,
            busiestLaneInFlightBatches: snapshots.map(\.busiestLaneInFlightBatches).max() ?? 0,
            dequeuedRequests: saturatingSum(snapshots.map(\.dequeuedRequests)),
            queueWaitMillisecondsTotal: saturatingSum(
                snapshots.map(\.queueWaitMillisecondsTotal)
            ),
            queueWaitMillisecondsMax: snapshots.map(\.queueWaitMillisecondsMax).max() ?? 0,
            completedBatches: saturatingSum(snapshots.map(\.completedBatches)),
            batchExecutionMillisecondsTotal: saturatingSum(
                snapshots.map(\.batchExecutionMillisecondsTotal)
            ),
            batchExecutionMillisecondsMax:
                snapshots.map(\.batchExecutionMillisecondsMax).max() ?? 0,
            stagingQueueFullRejections: saturatingSum(
                snapshots.map(\.stagingQueueFullRejections)
            ),
            cancelledPendingRequests: saturatingSum(
                snapshots.map(\.cancelledPendingRequests)
            ),
            baseDelayFlushes: saturatingSum(snapshots.map(\.baseDelayFlushes)),
            highActivityDelayFlushes: saturatingSum(
                snapshots.map(\.highActivityDelayFlushes)
            ),
            highActivityDelayScheduled: snapshots.contains {
                $0.highActivityDelayScheduled
            },
            atomicBatchAttempts: saturatingSum(snapshots.map(\.atomicBatchAttempts)),
            atomicBatchCommitted: saturatingSum(snapshots.map(\.atomicBatchCommitted)),
            atomicBatchFallbacks: saturatingSum(snapshots.map(\.atomicBatchFallbacks)),
            atomicBatchCommittedRequests: saturatingSum(
                snapshots.map(\.atomicBatchCommittedRequests)
            ),
            atomicBatchFallbackRequests: saturatingSum(
                snapshots.map(\.atomicBatchFallbackRequests)
            ),
            atomicBatchFallbackReasons: Dictionary(uniqueKeysWithValues:
                V2AtomicRoomWriteBatchError.Reason.allCases.map { reason in
                    (reason, saturatingSum(snapshots.map {
                        $0.atomicBatchFallbackReasons[reason, default: 0]
                    }))
                }
            ),
            sameRoomDeferredRequests: saturatingSum(
                snapshots.map(\.sameRoomDeferredRequests)
            ),
            atomicPreclassifiedIndividualRequests: saturatingSum(
                snapshots.map(\.atomicPreclassifiedIndividualRequests)
            ),
            singletonDispatches: saturatingSum(snapshots.map(\.singletonDispatches))
        )
    }

    /// 以饱和方式求和，溢出时返回 `UInt64.max`。
    ///
    /// - Parameter values: 待求和的计数。
    /// - Returns: 求和结果。
    private static func saturatingSum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { partial, value in
            let sum = partial.addingReportingOverflow(value)
            return sum.overflow ? .max : sum.partialValue
        }
    }

    private static func saturatingIntSum(_ values: [Int]) -> Int {
        values.reduce(0) { partial, value in
            let sum = partial.addingReportingOverflow(value)
            return sum.overflow ? .max : sum.partialValue
        }
    }
}

/// 对所有已配置物理所有者准入批处理器的只读指标。
/// 此类型不能接受消息或认领准入槽位。
public struct V2AggregatedSendMessageBatchMetrics: V2SendMessageBatchMetricsReading {
    public static let maximumOwners = 256
    public static let maximumConcurrentSnapshots = 8

    private let owners: [any V2SendMessageBatchMetricsReading]

    /// 每个物理所有者只提供一次。上限与配置的最大房间分片数一致；
    /// 所有者身份不会成为指标标签。
    public init(owners: [any V2SendMessageBatchMetricsReading]) {
        precondition(!owners.isEmpty && owners.count <= Self.maximumOwners)
        self.owners = owners
    }

    public func snapshot() async -> V2SendMessageBatchMetricsSnapshot {
        let snapshots = await withTaskGroup(
            of: V2SendMessageBatchMetricsSnapshot.self,
            returning: [V2SendMessageBatchMetricsSnapshot].self
        ) { group in
            var iterator = owners.makeIterator()
            for _ in 0..<min(owners.count, Self.maximumConcurrentSnapshots) {
                if let owner = iterator.next() {
                    group.addTask { await owner.snapshot() }
                }
            }
            var values: [V2SendMessageBatchMetricsSnapshot] = []
            values.reserveCapacity(owners.count)
            while let value = await group.next() {
                values.append(value)
                if let owner = iterator.next() {
                    group.addTask { await owner.snapshot() }
                }
            }
            return values
        }
        return V2SendMessageBatchSnapshotAggregator.aggregate(snapshots)
    }
}
