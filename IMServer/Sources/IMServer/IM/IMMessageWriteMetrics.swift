import Foundation

actor IMMessageWriteMetrics {
    struct Snapshot: Sendable {
        var sequenceBlocksReserved: Int = 0
        var sequenceBlockReserveFailures: Int = 0
        var sequenceBlockRemaining: Int = 0
        var ownerForwardCount: Int = 0
        var ownerForwardFailureCount: Int = 0
        var writeQueueDepth: Int = 0
        var memberCacheHits: Int = 0
        var memberCacheMisses: Int = 0
        var messageWriteBatches: Int = 0
        var messageWriteBatchMessages: Int = 0
        var writeQueueRejected: Int = 0
    }

    private var snapshot = Snapshot()

    func recordSequenceBlockReserved() { snapshot.sequenceBlocksReserved += 1 }
    func recordSequenceBlockReserveFailed() { snapshot.sequenceBlockReserveFailures += 1 }
    func recordSequenceBlockRemaining(_ value: Int) { snapshot.sequenceBlockRemaining = value }
    func recordOwnerForwarded() { snapshot.ownerForwardCount += 1 }
    func recordOwnerForwardFailed() { snapshot.ownerForwardFailureCount += 1 }
    func recordWriteQueueDepth(_ value: Int) { snapshot.writeQueueDepth = value }
    func recordMemberCacheHit() { snapshot.memberCacheHits += 1 }
    func recordMemberCacheMiss() { snapshot.memberCacheMisses += 1 }
    func recordWriteQueueRejected() { snapshot.writeQueueRejected += 1 }
    func recordMessageWriteBatch(messageCount: Int) {
        snapshot.messageWriteBatches += 1
        snapshot.messageWriteBatchMessages += messageCount
    }
    func currentSnapshot() -> Snapshot { snapshot }
}
