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
        #expect(await store.released() == [lease])
        #expect(await store.completed().isEmpty)
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
    private let leases: [V2MediaScanLease]
    private var completionValues: [Completion] = []
    private var releasedValues: [V2MediaScanLease] = []
    init(leases: [V2MediaScanLease]) { self.leases = leases }
    func claimPending(now _: Date, leaseDuration _: TimeInterval, limit: Int) -> [V2MediaScanLease] { Array(leases.prefix(limit)) }
    func complete(_ lease: V2MediaScanLease, result: V2MediaScanResult, now _: Date) { completionValues.append(.init(lease: lease, result: result)) }
    func release(_ lease: V2MediaScanLease) { releasedValues.append(lease) }
    func completed() -> [Completion] { completionValues }
    func released() -> [V2MediaScanLease] { releasedValues }
}

private struct PassingMediaScanner: V2MediaScanProvider { func scan(mediaID _: MediaID) -> V2MediaScanResult { .passed } }
private struct FailingMediaScanner: V2MediaScanProvider { func scan(mediaID _: MediaID) throws -> V2MediaScanResult { throw ScanFailure.failed }; private enum ScanFailure: Error { case failed } }
