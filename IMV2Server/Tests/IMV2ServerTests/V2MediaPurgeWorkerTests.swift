@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 media purge worker")
struct V2MediaPurgeWorkerTests {
    @Test("Invalid retry clocks keep the media lease unreleased", arguments: Array(0...8))
    func invalidRetryClockDoesNotRelease(_ boundary: Int) async throws {
        let clock = V2WorkerRetryClockFixture(boundary)
        let lease = try V2MediaPurgeLease(mediaID: .init("media"), reason: .unreferencedExpired, claimToken: UUID())
        let store = RecordingMediaPurgeStore(leases: [lease])
        let worker = try V2MediaPurgeWorker(store: store, provider: FailingMediaPurgeProvider(), retryPolicy: clock.policy, now: { clock.now() })
        await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await worker.runOnce(limit: 1) }
        #expect(await store.retries().isEmpty)
        #expect(await store.completedLeases().isEmpty)
        let recoveredAt = Date(timeIntervalSince1970: 1_750_000_010)
        let recovered = try V2MediaPurgeWorker(store: store, provider: FailingMediaPurgeProvider(),
            retryPolicy: .init(initialDelay: 0.5, maximumDelay: 0.5, maximumAttempts: 3, jitterFraction: 0), now: { recoveredAt })
        #expect(try await recovered.runOnce(limit: 1).releasedCount == 1)
        #expect(await store.retries().map(\.disposition) == [.retry(at: recoveredAt.addingTimeInterval(0.5))])
    }

    @Test("provider failure releases only the cleanup work for retry")
    func providerFailureIsRetryable() async throws {
        let lease = try V2MediaPurgeLease(mediaID: .init("media"), reason: .withdrawnRetentionElapsed, claimToken: UUID())
        let store = RecordingMediaPurgeStore(leases: [lease])
        let worker = try V2MediaPurgeWorker(store: store, provider: FailingMediaPurgeProvider())

        #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, completedCount: 0, releasedCount: 1))
        #expect(await store.retries().count == 1)
        guard case .retry = try #require(await store.retries().first?.disposition) else {
            Issue.record("expected a delayed retry")
            return
        }
        #expect(await store.completedLeases().isEmpty)
    }

    @Test("retry exhaustion pauses cleanup for audited replay")
    func exhaustedPurgeRetriesLease() async throws {
        let lease = try V2MediaPurgeLease(
            mediaID: .init("media"),
            reason: .withdrawnRetentionElapsed,
            claimToken: UUID(),
            attempt: 2
        )
        let store = RecordingMediaPurgeStore(leases: [lease])
        let worker = try V2MediaPurgeWorker(
            store: store,
            provider: FailingMediaPurgeProvider(),
            retryPolicy: .init(initialDelay: 1, maximumDelay: 1, maximumAttempts: 2, jitterFraction: 0)
        )

        // A purge-provider outage is transient; the attempt budget must not
        // convert it into operator-only work.
        #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, completedCount: 0, releasedCount: 1))
        #expect(await store.retries().map(\.disposition) != [.pause])
    }

    @Test("a purge invariant violation pauses the cleanup on its first attempt")
    func invariantPurgeFailurePausesLease() async throws {
        let lease = try V2MediaPurgeLease(
            mediaID: .init("media"),
            reason: .withdrawnRetentionElapsed,
            claimToken: UUID(),
            attempt: 1
        )
        let store = RecordingMediaPurgeStore(leases: [lease])
        let worker = try V2MediaPurgeWorker(
            store: store,
            provider: InvariantFailingMediaPurgeProvider(),
            retryPolicy: .init(initialDelay: 1, maximumDelay: 1, maximumAttempts: 10, jitterFraction: 0)
        )

        #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, completedCount: 0, releasedCount: 0, pausedCount: 1))
        #expect(await store.retries().map(\.disposition) == [.pause])
    }

    @Test("successful purge marks only the fenced cleanup lease complete")
    func providerSuccessCompletesLease() async throws {
        let lease = try V2MediaPurgeLease(mediaID: .init("media"), reason: .unreferencedExpired, claimToken: UUID())
        let store = RecordingMediaPurgeStore(leases: [lease])
        let provider = RecordingMediaPurgeProvider()
        let worker = try V2MediaPurgeWorker(store: store, provider: provider)

        #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, completedCount: 1, releasedCount: 0))
        #expect(await provider.purgedMedia() == [lease.mediaID])
        #expect(await store.completedLeases() == [lease])
    }
}

private actor RecordingMediaPurgeStore: V2MediaPurgeStore {
    struct Retry: Equatable, Sendable { let lease: V2MediaPurgeLease; let disposition: V2DurableRetryDisposition }
    private let leases: [V2MediaPurgeLease]
    private var completed: [V2MediaPurgeLease] = []
    private var retryValues: [Retry] = []

    init(leases: [V2MediaPurgeLease]) { self.leases = leases }
    func claimPending(now _: Date, leaseDuration _: TimeInterval, limit: Int) -> [V2MediaPurgeLease] { Array(leases.prefix(limit)) }
    func markCompleted(_ lease: V2MediaPurgeLease, now _: Date) { completed.append(lease) }
    func scheduleRetry(_ lease: V2MediaPurgeLease, disposition: V2DurableRetryDisposition, now _: Date) {
        retryValues.append(.init(lease: lease, disposition: disposition))
    }
    func completedLeases() -> [V2MediaPurgeLease] { completed }
    func retries() -> [Retry] { retryValues }
}

private actor RecordingMediaPurgeProvider: V2MediaPurgeProvider {
    private var media: [MediaID] = []
    func purge(mediaID: MediaID) { media.append(mediaID) }
    func purgedMedia() -> [MediaID] { media }
}

private struct FailingMediaPurgeProvider: V2MediaPurgeProvider {
    func purge(mediaID _: MediaID) throws { throw MediaPurgeFailure.failed }
    private enum MediaPurgeFailure: Error { case failed }
}

/// 抛出确定性失败：提供商返回与持久状态矛盾的结果，重试不会改变结论。
private struct InvariantFailingMediaPurgeProvider: V2MediaPurgeProvider {
    func purge(mediaID _: MediaID) throws { throw V2RoomWriteStoreError.corruptPersistenceState }
}
