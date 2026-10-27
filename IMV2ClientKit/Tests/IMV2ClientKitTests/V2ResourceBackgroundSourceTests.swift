import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Account-owned background upload sources", .timeLimit(.minutes(1)))
struct V2ResourceBackgroundSourceTests {
    @Test func wholeUploadAbovePartLimitUsesManagedAFUSourceAndSameBudget() async throws {
        let f = try await Fixture(), files = try f.files()
        let body = Data(repeating: 7, count: 9 * 1_024 * 1_024)
        let asset = try await files.importOriginal(data: body, id: .init(), displayName: .init("whole.bin"),
            contentType: .init("application/octet-stream"), purpose: .personalAvatar, maximumBytes: Int64(body.count), maximumSelections: 1)
        let source = try await files.borrowSelection(asset.id), session = UUID(), id = UUID()
        await #expect(throws: V2ResourceStorageError.invalidRecord) {
            try await files.makeBackgroundUploadSource(from: source, sessionID: session, id: UUID(),
                range: .init(lowerBound: 0, upperBound: Int64(body.count - 1)))
        }
        let url = try await files.makeBackgroundWholeUploadSource(from: source, sessionID: session, id: id)
        #expect(try Data(contentsOf: url) == body)
        #expect(try await files.snapshot().quota.temporaryReservedBytes >= 2 * Int64(body.count))
        try await files.releaseBackgroundUploadSource(id: id, sessionID: session)
        #expect(try await files.snapshot().quota.temporaryReservedBytes == 0)
        await source.release(); await files.close(); try await f.remove()
    }

    enum Limit: CaseIterable, Sendable { case temporary, total }

    @Test("foreground publication and native upload copies compete for the same peak budget", arguments: [false, true])
    func mixedForegroundAndBackgroundPeak(nativeFirst: Bool) async throws {
        let f = try await Fixture()
        let policy = try V2ResourceStoragePolicy(maximumCacheBytes: 65536, maximumOriginalBytes: 65536,
            maximumTemporaryBytes: 12288, maximumManagedBytes: 65536)
        let files = try f.files(policy: policy), original = try await f.original(files)
        let session = UUID(), sourceID = UUID()
        if nativeFirst {
            let native = try await files.makeBackgroundUploadSource(from: original, sessionID: session, id: sourceID, range: f.range)
            await #expect(throws: V2ResourceStorageError.capacityExceeded) {
                try await files.reserveTransient(identity: "foreground-download", bytes: 4096)
            }
            #expect(try f.journal.stagingReservations().isEmpty)
            #expect(try Data(contentsOf: native) == f.body)
            // The publication copy matters: one slice fits the remaining 4 KiB,
            // but a download plus its immutable publication must not fit.
            let slice = try await files.reserveTransient(identity: "foreground-slice", bytes: 4096, footprint: .singleFile)
            try f.body.write(to: slice.fileURL)
            #expect(try await files.snapshot().quota.temporaryReservedBytes == 12288)
            try await files.releaseTransient(slice.id, discard: true)
            try await files.releaseBackgroundUploadSource(id: sourceID, sessionID: session)
        } else {
            let download = try await files.reserveTransient(identity: "foreground-download", bytes: 4096)
            try f.body.write(to: download.fileURL)
            await #expect(throws: V2ResourceStorageError.capacityExceeded) {
                try await files.makeBackgroundUploadSource(from: original, sessionID: session, id: sourceID, range: f.range)
            }
            #expect(try f.journal.backgroundSources().isEmpty)
            #expect(try Data(contentsOf: download.fileURL) == f.body)
            try await files.releaseTransient(download.id, discard: true)
            let native = try await files.makeBackgroundUploadSource(from: original, sessionID: session, id: sourceID, range: f.range)
            #expect(try Data(contentsOf: native) == f.body)
            try await files.releaseBackgroundUploadSource(id: sourceID, sessionID: session)
        }
        #expect(try await files.snapshot().quota.temporaryReservedBytes == 0)
        #expect(try Data(contentsOf: original.fileURL) == f.body)
        await original.release(); await files.close(); try await f.remove()
    }

    @Test("unavailable SQL leaves durable debt but cannot strand runtime close after the system task drained")
    func sqlUnavailableDuringRelease() async throws {
        let f = try await Fixture(), files = try f.files(), lease = try await f.original(files)
        let id = UUID(), session = UUID()
        let copy = try await files.makeBackgroundUploadSource(from: lease, sessionID: session, id: id, range: f.range)
        await lease.release()
        // Closing the pool deterministically exercises unavailable SQL; this
        // does not claim to simulate iOS Data Protection or an actual lock.
        try await f.store.close()
        await #expect(throws: DatabaseError.self) { try await files.releaseBackgroundUploadSource(id: id, sessionID: session) }
        await files.close()
        #expect(try Data(contentsOf: copy) == f.body)
        let reopened = try GRDBV2LocalSyncStore(databaseURL: f.scope.database.primary, installationBinding: f.binding, userID: f.scope.accountID)
        let restored = try V2ResourceFileStore(scope: f.scope, journal: await reopened.resourceFileJournal())
        #expect(try await restored.snapshot().backgroundReservedBytes >= 8192)
        _ = try await restored.reconcileBackgroundUploadSources(sessionID: session, retained: [])
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(try await restored.snapshot().files.first?.retention == .original)
        await restored.close(); try await reopened.close(); try FileManager.default.removeItem(at: f.root)
    }

    @Test("cancelling the AFU copy preserves the original and releases bytes only through its owner")
    func cancellationDuringSourceCopy() async throws {
        let f = try await Fixture(), files = try V2ResourceFileStore(scope: f.scope, journal: f.journal, protection: CancellingBackgroundSourceProtection())
        let lease = try await f.original(files), session = UUID(), id = UUID()
        let operation = Task { try await files.makeBackgroundUploadSource(from: lease, sessionID: session, id: id, range: f.range) }
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(try f.journal.backgroundSources().count == 1)
        try await files.releaseBackgroundUploadSource(id: id, sessionID: session)
        #expect(try f.journal.backgroundSources().isEmpty)
        #expect(try Data(contentsOf: lease.fileURL) == f.body)
        await lease.release(); await files.close(); try await f.remove()
    }

    @Test("AFU copies and the conservative OS copy share temporary and total quotas", arguments: Limit.allCases)
    func sharedQuotaAndProtectedOriginal(limit: Limit) async throws {
        let f = try await Fixture()
        let policy = try V2ResourceStoragePolicy(maximumCacheBytes: 65536, maximumOriginalBytes: 65536,
            maximumTemporaryBytes: limit == .temporary ? 12288 : 65536, maximumManagedBytes: limit == .total ? 16384 : 65536)
        let files = try f.files(policy: policy), lease = try await f.original(files)
        let session = UUID(), id = UUID()
        let copy = try await files.makeBackgroundUploadSource(from: lease, sessionID: session, id: id, range: f.range)
        #expect(copy.path.hasPrefix(f.scope.backgroundDirectory.path))
        #expect(!copy.path.hasPrefix(f.scope.directory.path + "/"))
        #expect(try Data(contentsOf: copy) == f.body)
        #expect(try copy.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let usage = try await files.snapshot()
        #expect(usage.backgroundReservedBytes >= 8192 && usage.backgroundAllocatedBytes >= 4096)
        #expect(usage.quota.temporaryReservedBytes == usage.backgroundReservedBytes)
        await #expect(throws: V2ResourceStorageError.capacityExceeded) {
            try await files.makeBackgroundUploadSource(from: lease, sessionID: session, id: UUID(), range: f.range)
        }
        let lowered = try V2ResourceStoragePolicy(maximumCacheBytes: 65536, maximumOriginalBytes: 65536,
            maximumTemporaryBytes: 1, maximumManagedBytes: 1)
        #expect(try await files.setStoragePolicy(lowered).temporaryOverageBytes >= 8191)
        let cleanup = try await files.planCleanup()
        #expect(cleanup.fileIDs.isEmpty && cleanup.skippedCount == 2)
        #expect(try await files.commitCleanup(cleanup).deletedCount == 0)
        #expect(try Data(contentsOf: copy) == f.body && Data(contentsOf: lease.fileURL) == f.body)
        try await files.releaseBackgroundUploadSource(id: id, sessionID: session)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(try await files.snapshot().backgroundReservedBytes == 0)
        await lease.release(); await files.close(); try await f.remove()
    }

    private actor CloseWitness { private(set) var done = false; func finish() { done = true } }
    @Test("file-owner close waits for the actual background consumer, independently of the original lease")
    func closeWaitsForSystemClaim() async throws {
        let f = try await Fixture(), files = try f.files(), lease = try await f.original(files)
        let id = UUID(), session = UUID(), witness = CloseWitness()
        let copy = try await files.makeBackgroundUploadSource(from: lease, sessionID: session, id: id, range: f.range)
        await lease.release()
        let closing = Task { await files.close(); await witness.finish() }
        while true {
            do { _ = try await files.snapshot() }
            catch V2ResourceStorageError.closed { break }
            await Task.yield()
        }
        #expect(await witness.done == false)
        try await files.releaseBackgroundUploadSource(id: id, sessionID: UUID())
        #expect(await witness.done == false)
        #expect(try Data(contentsOf: copy) == f.body)
        try await files.releaseBackgroundUploadSource(id: id, sessionID: session)
        await closing.value
        #expect(await witness.done && !FileManager.default.fileExists(atPath: copy.path))
        try await f.remove()
    }

    @Test("cold adoption retains byte verification and normal cleanup cannot delete a source awaiting OS reconciliation")
    func coldAdoption() async throws {
        let f = try await Fixture(), id = UUID(), session = UUID()
        let copy = try await f.leaveSourceAsStoppedProcess(id: id, session: session)
        let files = try f.files()
        #expect(try await files.snapshot().backgroundReservedBytes >= 8192)
        let cleanup = try await files.planCleanup()
        #expect(cleanup.fileIDs.isEmpty && cleanup.skippedCount == 2)
        try await files.adoptBackgroundUploadSource(id: id, sessionID: session)
        _ = try await files.reconcileBackgroundUploadSources(sessionID: session, retained: [])
        #expect(try Data(contentsOf: copy) == f.body)
        try await files.releaseBackgroundUploadSource(id: id, sessionID: session)
        #expect(try f.journal.backgroundSources().isEmpty)
        #expect(try await files.snapshot().files.first?.retention == .original)
        await files.close(); try await f.remove()
    }

    @Test("an interrupted source never becomes a usable OS input before Ready; drain proof reclaims every phase",
          arguments: V2ResourceFileStore.BackgroundSourceCheckpoint.allCases)
    func interruptedPreparation(stage: V2ResourceFileStore.BackgroundSourceCheckpoint) async throws {
        struct Interrupted: Error {}
        let f = try await Fixture(), id = UUID(), session = UUID()
        // This actor is never called again: leaving its runtime claim models a
        // killed process. Recovery must use SQL + actual OS reconciliation.
        let stopped = try V2ResourceFileStore(root: f.scope.resourceFilesDirectory, cacheRoot: f.scope.resourceCacheDirectory,
            backgroundRoot: f.scope.backgroundDirectory, journal: f.journal, policy: .standard,
            backgroundSourceCheckpoint: { checkpoint in if checkpoint == stage { throw Interrupted() } }, checkpoint: { _ in })
        let lease = try await f.original(stopped)
        await #expect(throws: Interrupted.self) {
            try await stopped.makeBackgroundUploadSource(from: lease, sessionID: session, id: id, range: f.range)
        }
        await lease.release()
        let files = try f.files()
        try await files.reconcileFiles()
        #expect(try f.journal.backgroundSources().count == 1)
        #expect(try await files.snapshot().backgroundReservedBytes >= 8192)
        if stage != .ready {
            await #expect(throws: V2ResourceStorageError.unavailable) { try await files.adoptBackgroundUploadSource(id: id, sessionID: session) }
        }
        _ = try await files.reconcileBackgroundUploadSources(sessionID: session, retained: [])
        #expect(try f.journal.backgroundSources().isEmpty)
        #expect(try await files.snapshot().backgroundReservedBytes == 0)
        #expect(try await files.snapshot().files.first?.retention == .original)
        await files.close(); try await f.remove()
    }

    @Test("corrupt AFU bytes cannot be adopted, while the only original remains protected")
    func corruptSourceIsNotAdopted() async throws {
        let f = try await Fixture(), id = UUID(), session = UUID()
        let copy = try await f.leaveSourceAsStoppedProcess(id: id, session: session)
        try Data(repeating: 4, count: 4096).write(to: copy)
        let files = try f.files()
        await #expect(throws: V2ResourceStorageError.integrityMismatch) { try await files.adoptBackgroundUploadSource(id: id, sessionID: session) }
        _ = try await files.reconcileBackgroundUploadSources(sessionID: session, retained: [])
        #expect(try f.journal.backgroundSources().isEmpty)
        let original = try #require(try await files.selectedAssets(purpose: .personalAvatar).first)
        let lease = try await files.borrowSelection(original.id)
        #expect(try Data(contentsOf: lease.fileURL) == f.body)
        await lease.release(); await files.close(); try await f.remove()
    }

    @Test("a source lease from another account cannot allocate or expose a background copy")
    func rejectsForeignLease() async throws {
        let first = try await Fixture(), second = try await Fixture()
        let a = try first.files(), b = try second.files(), lease = try await first.original(a)
        await #expect(throws: V2ResourceStorageError.invalidRecord) {
            try await b.makeBackgroundUploadSource(from: lease, sessionID: UUID(), id: UUID(), range: first.range)
        }
        #expect(try second.journal.backgroundSources().isEmpty)
        await lease.release(); await a.close(); await b.close(); try await first.remove(); try await second.remove()
    }

    @Test("failed deletion keeps its journal and never follows a swapped source-directory symlink")
    func deletionFailureRecoversWithoutDeletingForeignBytes() async throws {
        let f = try await Fixture(), files = try f.files(), lease = try await f.original(files)
        let id = UUID(), session = UUID()
        let copy = try await files.makeBackgroundUploadSource(from: lease, sessionID: session, id: id, range: f.range)
        let directory = copy.deletingLastPathComponent(), moved = directory.appendingPathExtension("saved")
        let foreign = f.root.appending(path: "foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        let sentinel = foreign.appending(path: id.uuidString)
        try f.body.write(to: sentinel)
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: foreign)
        await #expect(throws: V2ResourceStorageError.unsafeFile) { try await files.releaseBackgroundUploadSource(id: id, sessionID: session) }
        #expect(try Data(contentsOf: sentinel) == f.body)
        #expect(try f.journal.backgroundSources().first?.state == .deleting)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: moved, to: directory)
        _ = try await files.reconcileBackgroundUploadSources(sessionID: session, retained: [])
        #expect(try f.journal.backgroundSources().isEmpty)
        #expect(try Data(contentsOf: sentinel) == f.body)
        await lease.release(); await files.close(); try await f.remove()
    }

    private struct Fixture {
        let root: URL, scope: V2AccountStorageScope, store: GRDBV2LocalSyncStore, journal: V2ResourceFileJournal
        let body = Data(repeating: 7, count: 4096)
        let binding = V2LocalInstallationBinding(value: UUID())
        var range: V2ResourceByteRange { get throws { try .init(lowerBound: 0, upperBound: 4095) } }
        init() async throws {
            root = FileManager.default.temporaryDirectory.appending(path: "resource-background-\(UUID())")
            scope = .init(incarnation: UUID(), accountID: .init(uuid: UUID()), directory: root.appending(path: "support"), cacheDirectory: root.appending(path: "cache"))
            store = try .init(databaseURL: scope.database.primary, installationBinding: binding, userID: scope.accountID)
            journal = await store.resourceFileJournal()
        }
        func files(policy: V2ResourceStoragePolicy = .standard) throws -> V2ResourceFileStore { try .init(scope: scope, journal: journal, policy: policy) }
        func original(_ files: V2ResourceFileStore) async throws -> V2ResourceFileLease {
            let asset = try await files.importOriginal(data: body, id: .init(), displayName: .init("original.bin"), contentType: .init("application/octet-stream"),
                purpose: .personalAvatar, maximumBytes: 4096, maximumSelections: 1)
            return try await files.borrowSelection(asset.id)
        }
        func leaveSourceAsStoppedProcess(id: UUID, session: UUID) async throws -> URL {
            let stopped = try files(), lease = try await original(stopped)
            let copy = try await stopped.makeBackgroundUploadSource(from: lease, sessionID: session, id: id, range: range)
            await lease.release()
            return copy
        }
        func remove() async throws { try await store.close(); try FileManager.default.removeItem(at: root) }
    }
}

private struct CancellingBackgroundSourceProtection: V2ResourceFileProtectionWriting {
    func apply(_ protection: V2ResourceFileProtection, to file: URL) throws {
        if file.pathExtension == "partial" && file.deletingLastPathComponent().lastPathComponent == "sources" {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        try V2SystemResourceFileProtectionWriter().apply(protection, to: file)
    }
}
