@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("Read receipt metrics aggregation")
struct V2AggregatedReadReceiptBatchMetricsTests {
    @Test("owner counts saturate, while maximum batch size remains a maximum")
    func aggregatesWithoutOverflow() async {
        let first = ReceiptMetricsProbe(value: .init(
            pendingRequests: Int.max, inFlightBatches: 2,
            completedBatches: UInt64.max, completedRequests: 3,
            maximumObservedBatchSize: 6, queueFullRejections: UInt64.max,
            cancelledPendingRequests: 4))
        let second = ReceiptMetricsProbe(value: .init(
            pendingRequests: 1, inFlightBatches: Int.max,
            completedBatches: 1, completedRequests: UInt64.max,
            maximumObservedBatchSize: 4, queueFullRejections: 1,
            cancelledPendingRequests: UInt64.max))
        let metrics = V2AggregatedReadReceiptBatchMetrics(owners: [first, second])
        let value = await metrics.snapshot()
        #expect(value.pendingRequests == Int.max)
        #expect(value.inFlightBatches == Int.max)
        #expect(value.completedBatches == UInt64.max)
        #expect(value.completedRequests == UInt64.max)
        #expect(value.maximumObservedBatchSize == 6)
        #expect(value.queueFullRejections == UInt64.max)
        #expect(value.cancelledPendingRequests == UInt64.max)
    }

    @Test("snapshot fanout never exceeds eight physical owners")
    func boundedFanout() async {
        let tracker = ReceiptMetricsConcurrencyTracker()
        let owners: [any V2ReadReceiptBatchMetricsReading] = (0..<24).map { _ in
            ReceiptMetricsProbe(value: .init(
                pendingRequests: 1, inFlightBatches: 0,
                completedBatches: 1, completedRequests: 2,
                maximumObservedBatchSize: 2, queueFullRejections: 0,
                cancelledPendingRequests: 0), tracker: tracker)
        }
        let value = await V2AggregatedReadReceiptBatchMetrics(owners: owners).snapshot()
        let peak = await tracker.maximum
        #expect(value.pendingRequests == 24)
        #expect(value.completedBatches == 24)
        #expect(value.completedRequests == 48)
        #expect(peak > 1)
        #expect(peak <= V2AggregatedReadReceiptBatchMetrics.maximumConcurrentSnapshots)
    }
}

private struct ReceiptMetricsProbe: V2ReadReceiptBatchMetricsReading {
    let value: V2ReadReceiptBatchMetricsSnapshot
    var tracker: ReceiptMetricsConcurrencyTracker?

    func snapshot() async -> V2ReadReceiptBatchMetricsSnapshot {
        if let tracker {
            await tracker.enter()
            try? await Task.sleep(for: .milliseconds(5))
            await tracker.leave()
        }
        return value
    }
}

private actor ReceiptMetricsConcurrencyTracker {
    private var active = 0
    private(set) var maximum = 0

    func enter() {
        active += 1
        maximum = max(maximum, active)
    }

    func leave() { active -= 1 }
}
