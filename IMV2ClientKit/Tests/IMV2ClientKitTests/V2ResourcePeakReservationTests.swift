import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Durable download peak reservations and publication credit", .timeLimit(.minutes(1)))
struct V2ResourcePeakReservationTests {
    enum Limit: CaseIterable, Sendable { case temporary, total }

    @Test("the actual download cache reserves its publication peak before starting another network transfer")
    func cacheReservesBeforeNetwork() async throws {
        let f = try await Fixture()
        let scope = V2AccountStorageScope(incarnation: UUID(), accountID: try f.journal.accountID(),
            directory: f.root, cacheDirectory: f.root.appending(path: "system-cache"))
        let center = try await V2ResourceCenter.make(scope: scope, store: f.store,
            policy: f.policy(temporary: 12288, total: 12288))
        let bytes = PeakGateBytes(body: f.body)
        let firstMedia = MediaID(uuid: UUID())
        let resolver = PeakResolver(first: firstMedia, checksum: f.checksum)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        let first = Task { try await cache.download(.init(mediaID: firstMedia)) }
        await bytes.started()
        #expect(try await center.storageSnapshot().quota.temporaryReservedBytes == 8192)
        await #expect(throws: V2ResourceStorageError.capacityExceeded) {
            try await cache.download(.init(mediaID: .init(uuid: UUID())))
        }
        #expect(await bytes.calls == 1)
        await bytes.release()
        let downloaded = try await first.value
        let lease = try await downloaded.borrowFile()
        #expect(try Data(contentsOf: lease.fileURL) == f.body)
        #expect(try await center.storageSnapshot().quota.temporaryReservedBytes == 0)
        await lease.release(); await center.close(); try await f.remove()
    }

    @Test("two concurrent downloads cannot both spend the same future-copy capacity", arguments: Limit.allCases)
    func concurrentPeakAndColdResume(limit: Limit) async throws {
        let f = try await Fixture(), policy = try f.policy(temporary: limit == .temporary ? 12288 : 65536,
            total: limit == .total ? 12288 : 65536)
        let files = try f.files(policy)
        let tasks = ["first","second"].map { identity in
            Task { try await files.reserveTransient(identity: identity, bytes: 4096) }
        }
        var accepted: [V2ResourceTransferStaging] = [], rejected = 0
        for task in tasks {
            switch await task.result {
            case .success(let reservation): accepted.append(reservation)
            case .failure(let error):
                #expect(error as? V2ResourceStorageError == .capacityExceeded)
                rejected += 1
            }
        }
        #expect(accepted.count == 1 && rejected == 1)
        let reservation = try #require(accepted.first)
        try f.body.write(to: reservation.fileURL)
        let row = try #require(try f.journal.stagingReservations().first)
        #expect(row.bytes == 4096 && row.publicationBytes == 4096 && row.reservedBytes == 8192)
        #expect(try await files.snapshot().quota.temporaryReservedBytes == 8192)
        try await files.releaseTransient(reservation.id, discard: false)
        await files.close()
        let restored = try f.files(.standard)
        let resumed = try await restored.reserveTransient(identity: row.identity, bytes: 4096)
        #expect(resumed.id == reservation.id && resumed.fileURL == reservation.fileURL)
        try await files.releaseTransient(reservation.id, discard: true)
        #expect(try Data(contentsOf: resumed.fileURL) == f.body)
        #expect(try f.journal.stagingReservations().first?.id == resumed.id)
        #expect(try await restored.snapshot().transferReservedBytes == 8192)
        await #expect(throws: V2ResourceStorageError.capacityExceeded) {
            try await restored.reserveTransient(identity: "third", bytes: 4096)
        }
        try await restored.releaseTransient(resumed.id, discard: true)
        await restored.close(); try await f.remove()
    }

    @Test("publication atomically converts its existing credit instead of demanding a third copy")
    func publicationDoesNotDoubleCharge() async throws {
        let f = try await Fixture(), policy = try f.policy(temporary: 8192, total: 4096 + f.allocation)
        let files = try f.files(policy)
        let reservation = try await files.reserveTransient(identity: "publication", bytes: 4096)
        try f.body.write(to: reservation.fileURL)
        let publication = try await files.publishDownload(of: reservation.fileURL, reservation: reservation, byteCount: 4096, checksum: f.checksum)
        let row = try #require(try f.journal.stagingReservations().first)
        #expect(row.publicationBytes == 0 && row.reservedBytes == 4096)
        let snapshot = try await files.snapshot()
        #expect(snapshot.quota.cacheBytes == f.allocation && snapshot.quota.temporaryReservedBytes == 4096)
        #expect(snapshot.quota.managedBytes == policy.maximumManagedBytes)
        #expect(try Data(contentsOf: publication.lease.fileURL) == f.body)
        await #expect(throws: V2ResourceStorageError.capacityExceeded) {
            try await files.reserveTransient(identity: "no-capacity", bytes: 1, footprint: .singleFile)
        }
        // A spent credit cannot publish another file or be replayed, even
        // though the original producer still owns its staging reservation.
        await #expect(throws: V2ResourceStorageError.conflict) {
            try await files.publishDownload(of: reservation.fileURL, reservation: reservation, byteCount: 4096, checksum: f.checksum)
        }
        try await files.releaseTransient(reservation.id, discard: true)
        let extra = try await files.reserveTransient(identity: "released-capacity", bytes: 1, footprint: .singleFile)
        try await files.releaseTransient(extra.id, discard: true)
        await publication.lease.release(); await files.close(); try await f.remove()
    }

    @Test("lowering total and temporary limits preserves a previously admitted publication")
    func admittedCreditSurvivesLowerLimit() async throws {
        let f = try await Fixture(), files = try f.files(f.policy(temporary: 8192, total: 4096 + f.allocation))
        let reservation = try await files.reserveTransient(identity: "already-admitted", bytes: 4096)
        try f.body.write(to: reservation.fileURL)
        let lowered = try f.policy(temporary: 1, total: 1)
        _ = try await files.setStoragePolicy(lowered)
        let publication = try await files.publishDownload(of: reservation.fileURL, reservation: reservation, byteCount: 4096, checksum: f.checksum)
        #expect(try Data(contentsOf: publication.lease.fileURL) == f.body)
        #expect(try await files.snapshot().quota.managedBytes == 4096 + f.allocation)
        await #expect(throws: V2ResourceStorageError.capacityExceeded) {
            try await files.reserveTransient(identity: "new-growth", bytes: 1, footprint: .singleFile)
        }
        try await files.releaseTransient(reservation.id, discard: true)
        await publication.lease.release(); await files.close(); try await f.remove()
    }

    @Test("every interrupted publication accounts credit once and failed copies rearm before retry",
          arguments: V2ResourceFileStore.PublicationCheckpoint.allCases)
    func interruptedPublication(stage: V2ResourceFileStore.PublicationCheckpoint) async throws {
        struct Interrupted: Error {}
        let f = try await Fixture(), policy = try f.policy(temporary: 8192, total: 4096 + f.allocation)
        let files = try V2ResourceFileStore(root: f.root.appending(path: "files"), journal: f.journal, policy: policy) { checkpoint in
            if checkpoint == stage { throw Interrupted() }
        }
        let reservation = try await files.reserveTransient(identity: "interrupted", bytes: 4096)
        try f.body.write(to: reservation.fileURL)
        await #expect(throws: Interrupted.self) {
            try await files.publishDownload(of: reservation.fileURL, reservation: reservation, byteCount: 4096, checksum: f.checksum)
        }
        #expect(try f.journal.stagingReservations().first?.publicationBytes == 0)
        try await files.releaseTransient(reservation.id, discard: false)
        await files.close()
        let restored = try f.files(.standard)
        let snapshot = try await restored.snapshot()
        if stage == .partialWritten {
            #expect(snapshot.files.isEmpty && snapshot.quota.managedBytes == 4096)
            let resumed = try await restored.reserveTransient(identity: "interrupted", bytes: 4096)
            #expect(resumed.fileURL == reservation.fileURL)
            #expect(try await restored.snapshot().quota.temporaryReservedBytes == 8192)
            let publication = try await restored.publishDownload(of: resumed.fileURL, reservation: resumed, byteCount: 4096, checksum: f.checksum)
            #expect(try Data(contentsOf: publication.lease.fileURL) == f.body)
            await publication.lease.release()
            try await restored.releaseTransient(resumed.id, discard: true)
        } else {
            #expect(snapshot.files.count == 1 && snapshot.files.first?.state == .published)
            #expect(snapshot.quota.managedBytes == 4096 + f.allocation)
            let plan = try await restored.planCleanup(fileIDs: [])
            #expect(plan.transferStagingIDs.isEmpty)
            // Explicit cleanup can release the inactive raw checkpoint. Its
            // already-published bytes have their independent file identity.
            let cleanup = try await restored.planCleanup()
            #expect(cleanup.transferStagingIDs == [reservation.id])
            _ = try await restored.commitCleanup(cleanup)
        }
        await restored.close(); try await f.remove()
    }

    private struct Fixture {
        let root: URL, body: Data, checksum: V2ResourceChecksum, allocation: Int64
        let store: GRDBV2LocalSyncStore, journal: V2ResourceFileJournal
        init() async throws {
            root = FileManager.default.temporaryDirectory.appending(path: "peak-reservation-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            body = Data(repeating: 7, count: 4096)
            let source = root.appending(path: "source")
            try body.write(to: source)
            checksum = try .init(value: V2ResourceFileDigest.sha256(fileURL: source, expectedByteCount: 4096))
            let values = try source.resourceValues(forKeys: [.totalFileAllocatedSizeKey,.fileAllocatedSizeKey])
            allocation = max(4096,Int64(try #require(values.totalFileAllocatedSize ?? values.fileAllocatedSize)))
            store = try .init(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()), userID: .init(uuid: UUID()))
            journal = await store.resourceFileJournal()
        }
        func policy(temporary: Int64, total: Int64) throws -> V2ResourceStoragePolicy {
            try .init(maximumCacheBytes: 65536, maximumTemporaryBytes: temporary, maximumManagedBytes: total)
        }
        func files(_ policy: V2ResourceStoragePolicy) throws -> V2ResourceFileStore {
            try .init(root: root.appending(path: "files"), journal: journal, policy: policy)
        }
        func remove() async throws { try await store.close(); try FileManager.default.removeItem(at: root) }
    }
}

private struct PeakResolver: V2ClientMediaDownloadTargetResolver {
    let first: MediaID, checksum: V2ResourceChecksum
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) throws -> V2ClientMediaTransferTarget {
        try .init(downloadPlan: .init(mode: .httpGet, url: #require(URL(string: "https://bytes.invalid/peak")),
            expiresAt: Date().addingTimeInterval(120), expectedByteCount: 4096,
            checksum: mediaID == first ? checksum : .init(value: String(repeating: "a", count: 64))))
    }
}

private actor PeakGateBytes: V2ClientMediaByteTransfer {
    enum Failure: Error { case unexpectedNetworkAdmission }
    let body: Data
    let starts = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    init(body: Data) { self.body = body }
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) async throws {
        calls += 1
        guard calls == 1 else { throw Failure.unexpectedNetworkAdmission }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            starts.continuation.yield(())
        }
        try Task.checkCancellation()
        try body.write(to: destinationURL)
    }
    func started() async { var iterator = starts.stream.makeAsyncIterator(); _ = await iterator.next() }
    func release() { continuation?.resume(); continuation = nil }
}
