import Foundation

/// Read-only metrics over all configured physical-owner receipt batchers.
/// The source cannot accept a receipt or claim database admission.
public struct V2AggregatedReadReceiptBatchMetrics: V2ReadReceiptBatchMetricsReading {
    public static let maximumOwners = 256
    public static let maximumConcurrentSnapshots = 8

    private let owners: [any V2ReadReceiptBatchMetricsReading]

    /// Supply each physical owner once; an empty source would publish false zeroes.
    public init(owners: [any V2ReadReceiptBatchMetricsReading]) {
        precondition(!owners.isEmpty && owners.count <= Self.maximumOwners)
        self.owners = owners
    }

    public func snapshot() async -> V2ReadReceiptBatcher.Snapshot {
        let snapshots = await withTaskGroup(
            of: V2ReadReceiptBatcher.Snapshot.self,
            returning: [V2ReadReceiptBatcher.Snapshot].self
        ) { group in
            var iterator = owners.makeIterator()
            for _ in 0..<min(owners.count, Self.maximumConcurrentSnapshots) {
                if let owner = iterator.next() {
                    group.addTask { await owner.snapshot() }
                }
            }
            var values: [V2ReadReceiptBatcher.Snapshot] = []
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

public extension V2RoomServerOwnerResources {
    /// Per-owner receipt metrics without exposing the admission batcher.
    var receiptBatchMetrics: any V2ReadReceiptBatchMetricsReading { receiptBatcher }
}
