@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 media scanner worker")
struct V2MediaScanWorkerTests {
    @Test("Invalid retry clocks keep the media lease unreleased", arguments: Array(0...8))
    func invalidRetryClockDoesNotRelease(_ boundary: Int) async throws {
        let clock = V2WorkerRetryClockFixture(boundary)
        let lease = try V2MediaScanLease(mediaID: .init("media"), claimToken: UUID())
        let store = RecordingMediaScanStore(leases: [lease])
        let worker = try V2MediaScanWorker(store: store, provider: FailingMediaScanner(), retryPolicy: clock.policy, now: { clock.now() })
        await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await worker.runOnce(limit: 1) }
        #expect(await store.retries().isEmpty)
        #expect(await store.completed().isEmpty)
        let recoveredAt = Date(timeIntervalSince1970: 1_750_000_010)
        let recovered = try V2MediaScanWorker(store: store, provider: FailingMediaScanner(),
            retryPolicy: .init(initialDelay: 0.5, maximumDelay: 0.5, maximumAttempts: 3, jitterFraction: 0), now: { recoveredAt })
        #expect(try await recovered.runOnce(limit: 1).releasedCount == 1)
        #expect(await store.retries().map(\.disposition) == [.retry(at: recoveredAt.addingTimeInterval(0.5))])
    }

    @Test("scanner failure releases only the scan job and keeps media non-referenceable")
    func scannerFailureReleasesLease() async throws {
        let lease = try V2MediaScanLease(mediaID: .init("media"), claimToken: UUID())
        let store = RecordingMediaScanStore(leases: [lease])
        let worker = try V2MediaScanWorker(store: store, provider: FailingMediaScanner())

        #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, completedCount: 0, releasedCount: 1))
        #expect(await store.retries().count == 1)
        guard case .retry = try #require(await store.retries().first?.disposition) else {
            Issue.record("expected a delayed retry")
            return
        }
        #expect(await store.completed().isEmpty)
    }

    @Test("an exhausted scan attempt keeps retrying instead of pausing")
    func exhaustedScanRetriesLease() async throws {
        let lease = try V2MediaScanLease(mediaID: .init("media"), claimToken: UUID(), attempt: 2)
        let store = RecordingMediaScanStore(leases: [lease])
        let worker = try V2MediaScanWorker(
            store: store,
            provider: FailingMediaScanner(),
            retryPolicy: .init(initialDelay: 1, maximumDelay: 1, maximumAttempts: 2, jitterFraction: 0)
        )

        // A scanner outage is transient: the attempt budget must not turn it
        // into work that only an operator can release.
        #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, completedCount: 0, releasedCount: 1))
        #expect(await store.retries().map(\.disposition) != [.pause])
    }

    @Test("a scan invariant violation pauses the job on its first attempt")
    func invariantScanFailurePausesLease() async throws {
        let lease = try V2MediaScanLease(mediaID: .init("media"), claimToken: UUID(), attempt: 1)
        let store = RecordingMediaScanStore(leases: [lease])
        let worker = try V2MediaScanWorker(
            store: store,
            provider: InvariantFailingMediaScanner(),
            retryPolicy: .init(initialDelay: 1, maximumDelay: 1, maximumAttempts: 10, jitterFraction: 0)
        )

        #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, completedCount: 0, releasedCount: 0, pausedCount: 1))
        #expect(await store.retries().map(\.disposition) == [.pause])
    }

    @Test("a passed scan completes the fenced job")
    func passedScanCompletesLease() async throws {
        let lease = try V2MediaScanLease(mediaID: .init("media"), claimToken: UUID())
        let store = RecordingMediaScanStore(leases: [lease])
        let worker = try V2MediaScanWorker(store: store, provider: PassingMediaScanner())

        #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, completedCount: 1, releasedCount: 0))
        #expect(await store.completed() == [.init(lease: lease, result: .passed)])
    }
}

private actor RecordingMediaScanStore: V2MediaScanStore {
    struct Completion: Equatable, Sendable { let lease: V2MediaScanLease; let result: V2MediaScanResult }
    struct Retry: Equatable, Sendable { let lease: V2MediaScanLease; let disposition: V2DurableRetryDisposition }
    private let leases: [V2MediaScanLease]
    private var completionValues: [Completion] = []
    private var retryValues: [Retry] = []
    init(leases: [V2MediaScanLease]) { self.leases = leases }
    func claimPending(now _: Date, leaseDuration _: TimeInterval, limit: Int) -> [V2MediaScanLease] { Array(leases.prefix(limit)) }
    func complete(_ lease: V2MediaScanLease, result: V2MediaScanResult, now _: Date) { completionValues.append(.init(lease: lease, result: result)) }
    func scheduleRetry(_ lease: V2MediaScanLease, disposition: V2DurableRetryDisposition, now _: Date) {
        retryValues.append(.init(lease: lease, disposition: disposition))
    }
    func completed() -> [Completion] { completionValues }
    func retries() -> [Retry] { retryValues }
}

private struct PassingMediaScanner: V2MediaScanProvider { func scan(mediaID _: MediaID) -> V2MediaScanResult { .passed } }
private struct FailingMediaScanner: V2MediaScanProvider { func scan(mediaID _: MediaID) throws -> V2MediaScanResult { throw ScanFailure.failed }; private enum ScanFailure: Error { case failed } }

/// 抛出确定性失败：扫描器已返回与持久状态不一致的结果，重试不会改变结论。
private struct InvariantFailingMediaScanner: V2MediaScanProvider {
    func scan(mediaID _: MediaID) throws -> V2MediaScanResult { throw V2RoomWriteStoreError.corruptPersistenceState }
}

extension V2MediaScanWorkerTests {
    @Test("scan batches acquire fresh leases only when execution slots are available")
    func leasesStartAtExecution() async throws {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let clock = TestSequenceClock([base, base.addingTimeInterval(20), base.addingTimeInterval(20),
            base.addingTimeInterval(20), base.addingTimeInterval(40)])
        let store = BoundedScanClaimStore(count: 4)
        let worker = try V2MediaScanWorker(store: store, provider: PassingMediaScanner(), leaseDuration: 30,
            maximumConcurrency: 2, now: { clock.now() })
        #expect(try await worker.runOnce(limit: 3) == .init(claimedCount: 3, completedCount: 3, releasedCount: 0))
        let evidence = await store.evidence()
        #expect(evidence.limits == [2, 1])
        #expect(evidence.times == [base, base.addingTimeInterval(20)])
        #expect(evidence.remaining == 1)
        #expect(evidence.active == 0)
        #expect(!evidence.claimedWhileBusy)
        #expect(evidence.expired == 0)
    }
}

private actor BoundedScanClaimStore: V2MediaScanStore {
    private var pending: [V2MediaScanLease]
    private var active: [UUID: Date] = [:]
    private var limits: [Int] = []
    private var times: [Date] = []
    private var claimedWhileBusy = false
    private var expired = 0
    init(count: Int) {
        pending = (0..<count).map { _ in .init(mediaID: .init(uuid: UUID()), claimToken: UUID()) }
    }
    func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) -> [V2MediaScanLease] {
        if !active.isEmpty { claimedWhileBusy = true }
        limits.append(limit); times.append(now)
        let result = Array(pending.prefix(limit))
        pending.removeFirst(result.count)
        for lease in result { active[lease.claimToken] = now.addingTimeInterval(leaseDuration) }
        return result
    }
    func complete(_ lease: V2MediaScanLease, result: V2MediaScanResult, now: Date) throws {
        let savedDeadline = active.removeValue(forKey: lease.claimToken)
        let deadline = try #require(savedDeadline)
        if now >= deadline { expired += 1 }
    }
    func scheduleRetry(_ lease: V2MediaScanLease, disposition: V2DurableRetryDisposition, now: Date) {
        active.removeValue(forKey: lease.claimToken)
    }
    func evidence() -> (limits: [Int], times: [Date], remaining: Int, active: Int, claimedWhileBusy: Bool, expired: Int) {
        (limits, times, pending.count, active.count, claimedWhileBusy, expired)
    }
}
