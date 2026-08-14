import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 media scanner worker")
struct V2MediaScanWorkerTests {
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

    @Test("retry exhaustion pauses the scan job for audited replay")
    func exhaustedScanPausesLease() async throws {
        let lease = try V2MediaScanLease(mediaID: .init("media"), claimToken: UUID(), attempt: 2)
        let store = RecordingMediaScanStore(leases: [lease])
        let worker = try V2MediaScanWorker(
            store: store,
            provider: FailingMediaScanner(),
            retryPolicy: .init(initialDelay: 1, maximumDelay: 1, maximumAttempts: 2, jitterFraction: 0)
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
