import Foundation
@testable import IMV2Server
import Testing

@Suite("Physical-owner send metrics")
struct V2AggregatedSendMessageBatchMetricsTests {
    @Test("nested lanes preserve busiest lane and saturate counters")
    func nestedAndSaturated() async {
        let first = SendMetricsValue(snapshot: .init(
            pendingRequests: 5, inFlightBatches: 3, activeRooms: 4,
            laneCount: 2, busiestLanePendingRequests: 3,
            busiestLaneInFlightBatches: 2, dequeuedRequests: .max,
            queueWaitMillisecondsTotal: 10, queueWaitMillisecondsMax: 8,
            completedBatches: 7, stagingQueueFullRejections: 1,
            cancelledPendingRequests: 2, baseDelayFlushes: 3,
            highActivityDelayFlushes: 4, highActivityDelayScheduled: false,
            atomicBatchFallbackReasons: [.duplicateRoom: .max]))
        let second = SendMetricsValue(snapshot: .init(
            pendingRequests: 6, inFlightBatches: 1, activeRooms: 2,
            laneCount: 3, busiestLanePendingRequests: 4,
            busiestLaneInFlightBatches: 1, dequeuedRequests: 1,
            queueWaitMillisecondsTotal: 4, queueWaitMillisecondsMax: 3,
            completedBatches: 2, stagingQueueFullRejections: 0,
            cancelledPendingRequests: 1, baseDelayFlushes: 2,
            highActivityDelayFlushes: 0, highActivityDelayScheduled: true,
            atomicBatchFallbackReasons: [.duplicateRoom: 1]))
        let metrics = V2AggregatedSendMessageBatchMetrics(owners: [first, second])
        let value = await metrics.snapshot()
        #expect(value.pendingRequests == 11)
        #expect(value.inFlightBatches == 4)
        #expect(value.activeRooms == 6)
        #expect(value.laneCount == 5)
        #expect(value.busiestLanePendingRequests == 4)
        #expect(value.busiestLaneInFlightBatches == 2)
        #expect(value.dequeuedRequests == .max)
        #expect(value.queueWaitMillisecondsTotal == 14)
        #expect(value.queueWaitMillisecondsMax == 8)
        #expect(value.completedBatches == 9)
        #expect(value.highActivityDelayScheduled)
        #expect(value.atomicBatchFallbackReasons[.duplicateRoom] == .max)
    }

    @Test("sampling every physical owner has bounded concurrency")
    func boundedSampling() async {
        let probe = SendMetricsConcurrencyProbe()
        let owners: [any V2SendMessageBatchMetricsReading] = (0..<24).map { _ in
            SendMetricsDelayed(probe: probe)
        }
        let value = await V2AggregatedSendMessageBatchMetrics(owners: owners).snapshot()
        let observed = await probe.observation()
        #expect(observed.completed == 24)
        #expect(observed.maximumActive <= V2AggregatedSendMessageBatchMetrics.maximumConcurrentSnapshots)
        #expect(observed.maximumActive > 1)
        #expect(value.laneCount == 24)
        #expect(value.completedBatches == 24)
    }
}

private struct SendMetricsValue: V2SendMessageBatchMetricsReading {
    let value: V2SendMessageAdmissionBatcher.Snapshot
    init(snapshot: V2SendMessageAdmissionBatcher.Snapshot) { value = snapshot }
    func snapshot() -> V2SendMessageAdmissionBatcher.Snapshot { value }
}

private actor SendMetricsConcurrencyProbe {
    private var active = 0
    private var maximumActive = 0
    private var completed = 0
    func enter() {
        active += 1
        maximumActive = max(maximumActive, active)
    }
    func leave() {
        active -= 1
        completed += 1
    }
    func observation() -> (completed: Int, maximumActive: Int) {
        (completed, maximumActive)
    }
}

private struct SendMetricsDelayed: V2SendMessageBatchMetricsReading {
    let probe: SendMetricsConcurrencyProbe
    func snapshot() async -> V2SendMessageAdmissionBatcher.Snapshot {
        await probe.enter()
        try? await Task.sleep(for: .milliseconds(5))
        await probe.leave()
        return .init(pendingRequests: 0, inFlightBatches: 0, activeRooms: 0,
            completedBatches: 1, stagingQueueFullRejections: 0,
            cancelledPendingRequests: 0, baseDelayFlushes: 0,
            highActivityDelayFlushes: 0, highActivityDelayScheduled: false)
    }
}
