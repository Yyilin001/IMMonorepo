import Foundation
import Synchronization
import Testing
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2ServerApplication

@Suite("Journal publisher actual work and recovery")
struct V2RealtimeJournalPublisherTests {
    @Test func uncertainCommittedAppendReplaysBeforeCheckpointAdvances() async throws {
        let store = JournalPublisherTestStore()
        let applied = JournalAppliedBatches()
        let worker = try V2RealtimeJournalPublisher(sources: [.init(id: "room", store: store)]) { _, lease, batch in
            await applied.record(lease: lease, batch: batch)
        }
        try await worker.setLeases(sourceID: "room", leases: [routeLease()])
        _ = await worker.runOnce()
        #expect(await applied.sequences == [])
        _ = await worker.runOnce()
        #expect(await applied.sequences == [1])
        // The source database allocated its own generation, independent of routing.
        #expect(await applied.epochs == [77])
        await worker.close()
        #expect(await worker.runOnce() == false)
    }

    @Test func projectionFailureRetainsReplayResponsibility() async throws {
        let store = JournalPublisherTestStore()
        await store.disableUnknownCommit()
        let applied = JournalAppliedBatches(failFirst: true)
        let worker = try V2RealtimeJournalPublisher(sources: [.init(id: "room", store: store)]) { _, lease, batch in
            try await applied.apply(lease: lease, batch: batch)
        }
        try await worker.setLeases(sourceID: "room", leases: [routeLease()])
        _ = await worker.runOnce()
        #expect(await applied.sequences == [])
        _ = await worker.runOnce()
        #expect(await applied.sequences == [1])
        await worker.close()
    }

    @Test func wrongProjectionReceiptCannotAdvanceDurableApplyCheckpoint() async throws {
        let store = JournalPublisherTestStore()
        await store.disableUnknownCommit()
        let policy = JournalWrongReceiptPolicy()
        let worker = try V2RealtimeJournalPublisher(sources: [.init(id: "room", store: store)]) { _, _, batch in
            await policy.apply(batch)
        }
        try await worker.setLeases(sourceID: "room", leases: [routeLease()])
        _ = await worker.runOnce()
        #expect(await policy.calls == 1)
        _ = await worker.runOnce()
        // The first callback returned an unrelated source/partition receipt.
        // Seeing the same durable sequence again proves no checkpoint advanced.
        #expect(await policy.seen == [[1], [1]])
        #expect(await policy.calls == 2)
        await worker.close()
    }

    @Test func callbackPastLocalDeadlineCannotCheckpoint() async throws {
        let store = JournalPublisherTestStore()
        await store.disableUnknownCommit()
        let clock = JournalPublisherClock()
        let policy = JournalDeadlinePolicy(clock: clock)
        let worker = try V2RealtimeJournalPublisher(sources: [.init(id: "room", store: store)],
            monotonicNow: { clock.read() }) { _, _, batch in
                await policy.apply(batch)
            }
        try await worker.setLeases(sourceID: "room", leases: [routeLease()])
        _ = await worker.runOnce()
        // The append committed and consumed the outbox. Expiry must retain
        // local replay responsibility even though indexed discovery is empty.
        #expect(await store.pendingPartitions(partitionIDs: [2], limit: 256).isEmpty)
        _ = await worker.runOnce()
        #expect(await policy.seen == [[1], [1]])
        await worker.close()
    }

    @Test func unavailablePrefixDoesNotStarveLaterPartitions() async throws {
        let store = JournalFairClaimStore()
        let applied = JournalAppliedBatches()
        let worker = try V2RealtimeJournalPublisher(sources: [.init(id: "room", store: store)]) { _, lease, batch in
            await applied.record(lease: lease, batch: batch)
        }
        let identity = routeLease().identity
        try await worker.setLeases(sourceID: "room", leases: (0..<6).map {
            .init(partitionID: $0, identity: identity, epoch: 1, token: UUID(), remainingLeaseSeconds: 30)
        })
        _ = await worker.runOnce()
        _ = await worker.runOnce()
        #expect(await store.claimed.contains(4))
        #expect(await applied.sequences == [1])
        await worker.close()
    }

    @Test func slowPartitionDoesNotBlockOtherSlotAndCloseJoins() async throws {
        let store = JournalFairClaimStore(allowed: [0, 1])
        let gate = JournalSlowCallback()
        let worker = try V2RealtimeJournalPublisher(sources: [.init(id: "room", store: store)]) { _, _, batch in
            await gate.apply(batch)
        }
        let identity = routeLease().identity
        try await worker.setLeases(sourceID: "room", leases: (0..<2).map {
            .init(partitionID: $0, identity: identity, epoch: 1, token: UUID(), remainingLeaseSeconds: 30)
        })
        _ = await worker.runOnce()
        // Partition zero is still in the actual callback. A second iteration
        // must spend the free slot without waiting for that slow tail.
        _ = await worker.runOnce()
        #expect(await gate.fastCalls == 2)
        let closing = Task { await worker.close() }
        await gate.release()
        await closing.value
        #expect(await gate.slowFinished)
        #expect(await worker.runOnce() == false)
    }

    private func routeLease() -> V2RealtimePartitionLease {
        .init(partitionID: 2, identity: .init(nodeID: "host", serviceID: "service", incarnationID: UUID()),
              epoch: 1, token: UUID(), remainingLeaseSeconds: 30)
    }
}

private enum JournalTestError: Error { case uncertainCommit, projection }
private actor JournalAppliedBatches {
    var sequences: [Int64] = []
    var epochs: [Int64] = []
    private var failFirst: Bool
    init(failFirst: Bool = false) { self.failFirst = failFirst }
    func record(lease: V2RealtimePartitionLease, batch: V2RealtimeJournalBatch) -> V2RealtimeJournalApplyResult {
        sequences += batch.entries.map(\.sequence); epochs += batch.entries.map { _ in lease.epoch }
        return .init(sourceID: "room", partitionID: batch.partitionID,
                     appliedThrough: batch.entries.last?.sequence ?? batch.publishedThrough,
                     snapshotInstalled: batch.requiresSnapshot)
    }
    func apply(lease: V2RealtimePartitionLease, batch: V2RealtimeJournalBatch) throws -> V2RealtimeJournalApplyResult {
        if failFirst { failFirst = false; throw JournalTestError.projection }
        return record(lease: lease, batch: batch)
    }
}

private actor JournalPublisherTestStore: V2RealtimeChangeJournalStore {
    private var pending = true
    private var unknownCommit = true
    private var entries: [V2RealtimeJournalEntry] = []
    func disableUnknownCommit() { unknownCommit = false }
    func clearPending() { pending = false }
    func pendingPartitions(partitionIDs: [Int], limit: Int) -> [Int] { pending && partitionIDs.contains(2) ? [2] : [] }
    func claim(partitionIDs: [Int], identity: V2GatewayRealtimeIdentity, token: UUID,
               leaseDuration: TimeInterval) -> [V2RealtimePartitionLease] {
        partitionIDs.map { .init(partitionID: $0, identity: identity, epoch: 77, token: token, remainingLeaseSeconds: leaseDuration) }
    }
    func renew(_ leases: [V2RealtimePartitionLease], leaseDuration: TimeInterval) -> [V2RealtimePartitionLease] { leases }
    func confirm(_ leases: [V2RealtimePartitionLease]) -> [V2RealtimePartitionLease] { leases }
    func release(_ leases: [V2RealtimePartitionLease]) {}
    func publishPending(lease: V2RealtimePartitionLease, limit: Int) throws -> V2RealtimeJournalBatch {
        let before = Int64(entries.count)
        if pending {
            pending = false
            entries.append(.init(partitionID: 2, sequence: 1, sourceEventID: UUID(), topicKind: "roomEvents",
                                 topicID: UUID().uuidString.lowercased(), changeKind: "message.accepted", roomSequence: 10))
            if unknownCommit { unknownCommit = false; throw JournalTestError.uncertainCommit }
        }
        return replay(partitionID: 2, after: before, limit: limit)
    }
    func replay(partitionID: Int, after: Int64, limit: Int) -> V2RealtimeJournalBatch {
        .init(partitionID: partitionID, publishedThrough: Int64(entries.count), trimmedThrough: 0,
              requiresSnapshot: false, entries: Array(entries.filter { $0.sequence > after }.prefix(limit)))
    }
    func trim(lease: V2RealtimePartitionLease, through: Int64) {}
}

private actor JournalWrongReceiptPolicy {
    var calls = 0
    var seen: [[Int64]] = []
    func apply(_ batch: V2RealtimeJournalBatch) -> V2RealtimeJournalApplyResult {
        calls += 1; seen.append(batch.entries.map(\.sequence))
        if calls == 1 {
            return .init(sourceID: "wrong-source", partitionID: batch.partitionID + 1,
                         appliedThrough: batch.entries.last?.sequence ?? batch.publishedThrough)
        }
        return .init(sourceID: "room", partitionID: batch.partitionID,
                     appliedThrough: batch.entries.last?.sequence ?? batch.publishedThrough)
    }
}

private final class JournalPublisherClock: Sendable {
    private let instant = Mutex<ContinuousClock.Instant>(.now)
    func read() -> ContinuousClock.Instant { instant.withLock { $0 } }
    func advance() { instant.withLock { $0 += .seconds(20) } }
}
private actor JournalDeadlinePolicy {
    let clock: JournalPublisherClock
    var seen: [[Int64]] = []
    init(clock: JournalPublisherClock) { self.clock = clock }
    func apply(_ batch: V2RealtimeJournalBatch) -> V2RealtimeJournalApplyResult {
        seen.append(batch.entries.map(\.sequence))
        if seen.count == 1 { clock.advance() }
        return .init(sourceID: "room", partitionID: batch.partitionID,
            appliedThrough: batch.entries.last?.sequence ?? batch.publishedThrough)
    }
}

private actor JournalFairClaimStore: V2RealtimeChangeJournalStore {
    var claimed: [Int] = []
    let allowed: Set<Int>
    init(allowed: Set<Int> = [4]) { self.allowed = allowed }
    func pendingPartitions(partitionIDs: [Int], limit: Int) -> [Int] { partitionIDs.sorted() }
    func claim(partitionIDs: [Int], identity: V2GatewayRealtimeIdentity, token: UUID,
               leaseDuration: TimeInterval) -> [V2RealtimePartitionLease] {
        claimed += partitionIDs
        return partitionIDs.filter { allowed.contains($0) }.map {
            .init(partitionID: $0, identity: identity, epoch: 77, token: token, remainingLeaseSeconds: leaseDuration)
        }
    }
    func renew(_ leases: [V2RealtimePartitionLease], leaseDuration: TimeInterval) -> [V2RealtimePartitionLease] { leases }
    func confirm(_ leases: [V2RealtimePartitionLease]) -> [V2RealtimePartitionLease] { leases }
    func release(_ leases: [V2RealtimePartitionLease]) {}
    func publishPending(lease: V2RealtimePartitionLease, limit: Int) -> V2RealtimeJournalBatch {
        .init(partitionID: lease.partitionID, publishedThrough: 1, trimmedThrough: 0, requiresSnapshot: false,
            entries: [.init(partitionID: lease.partitionID, sequence: 1, sourceEventID: UUID(), topicKind: "roomEvents",
                topicID: UUID().uuidString.lowercased(), changeKind: "message.accepted", roomSequence: 1)])
    }
    func replay(partitionID: Int, after: Int64, limit: Int) -> V2RealtimeJournalBatch {
        .init(partitionID: partitionID, publishedThrough: 0, trimmedThrough: 0, requiresSnapshot: false, entries: [])
    }
    func trim(lease: V2RealtimePartitionLease, through: Int64) {}
}

private actor JournalSlowCallback {
    var fastCalls = 0
    var slowFinished = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func apply(_ batch: V2RealtimeJournalBatch) async -> V2RealtimeJournalApplyResult {
        if batch.partitionID == 0 {
            if !released { await withCheckedContinuation { waiter = $0 } }
            slowFinished = true
        } else { fastCalls += 1 }
        return .init(sourceID: "room", partitionID: batch.partitionID,
            appliedThrough: batch.entries.last?.sequence ?? batch.publishedThrough)
    }
    func release() {
        released = true
        waiter?.resume(); waiter = nil
    }
}
