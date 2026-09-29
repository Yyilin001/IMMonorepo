import IMV2ServerContracts
import Foundation

/// 汇总所有已配置物理所有者回执批处理器的只读指标。
/// 此来源不能接受回执，也不能申请数据库准入。
public struct V2AggregatedReadReceiptBatchMetrics: V2ReadReceiptBatchMetricsReading {
    public static let maximumOwners = 256
    public static let maximumConcurrentSnapshots = 8

    private let owners: [any V2ReadReceiptBatchMetricsReading]

    /// 每个物理所有者只提供一次；空来源会发布错误的零值。
    public init(owners: [any V2ReadReceiptBatchMetricsReading]) {
        precondition(!owners.isEmpty && owners.count <= Self.maximumOwners)
        self.owners = owners
    }

    public func snapshot() async -> V2ReadReceiptBatchMetricsSnapshot {
        let snapshots = await withTaskGroup(
            of: V2ReadReceiptBatchMetricsSnapshot.self,
            returning: [V2ReadReceiptBatchMetricsSnapshot].self
        ) { group in
            var iterator = owners.makeIterator()
            for _ in 0..<min(owners.count, Self.maximumConcurrentSnapshots) {
                if let owner = iterator.next() {
                    group.addTask { await owner.snapshot() }
                }
            }
            var values: [V2ReadReceiptBatchMetricsSnapshot] = []
            values.reserveCapacity(owners.count)
            while let value = await group.next() {
                values.append(value)
                if let owner = iterator.next() {
                    group.addTask { await owner.snapshot() }
                }
            }
            return values
        }
        return .init(
            pendingRequests: Self.saturatingIntSum(snapshots.map(\.pendingRequests)),
            inFlightBatches: Self.saturatingIntSum(snapshots.map(\.inFlightBatches)),
            completedBatches: Self.saturatingSum(snapshots.map(\.completedBatches)),
            completedRequests: Self.saturatingSum(snapshots.map(\.completedRequests)),
            maximumObservedBatchSize: snapshots.map(\.maximumObservedBatchSize).max() ?? 0,
            queueFullRejections: Self.saturatingSum(snapshots.map(\.queueFullRejections)),
            cancelledPendingRequests: Self.saturatingSum(snapshots.map(\.cancelledPendingRequests))
        )
    }

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
