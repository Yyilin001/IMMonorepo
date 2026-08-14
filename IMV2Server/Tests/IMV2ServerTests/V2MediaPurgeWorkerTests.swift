import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 media purge worker")
struct V2MediaPurgeWorkerTests {
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
    func exhaustedPurgePausesLease() async throws {
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
