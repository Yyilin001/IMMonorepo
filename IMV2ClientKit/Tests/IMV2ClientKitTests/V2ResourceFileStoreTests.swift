import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Resource file ownership and recovery")
struct V2ResourceFileStoreTests {
    @Test(arguments: ["", ".", "..", "../outside.txt", "folder/file.txt", "folder\\file.txt", "a\u{0}b", " a.txt", String(repeating: "a", count: 256)])
    func exportNameRejectsPathsAndUnsafeComponents(value: String) {
        #expect(throws: V2ResourceStorageError.invalidRecord) { try V2ResourceExportFileName(value) }
    }

    @Test func namedExportsHaveIndependentLifetimesAndNoSecondPayload() async throws {
        let f = try await Fixture(), store = try f.store()
        let id = try await store.publishCopy(of: f.source, byteCount: 16, checksum: f.checksum, retention: .cache)
        let original = try await store.borrow(id), initial = try await store.snapshot().totalBytes
        let name = try V2ResourceExportFileName("设计说明 version 2.txt")
        let first = try await original.forExport(fileName: name), second = try await original.forExport(fileName: name)
        #expect(first.fileURL.lastPathComponent == name.value && second.fileURL.lastPathComponent == name.value)
        #expect(first.fileURL != second.fileURL)
        let a = try FileManager.default.attributesOfItem(atPath: original.fileURL.path)
        let b = try FileManager.default.attributesOfItem(atPath: first.fileURL.path)
        #expect(a[.systemFileNumber] as? NSNumber == b[.systemFileNumber] as? NSNumber)
        #expect(try await store.snapshot().totalBytes == initial)
        await original.release()
        #expect(try await store.planCleanup().fileIDs.isEmpty)
        await first.release()
        #expect(!FileManager.default.fileExists(atPath: first.fileURL.deletingLastPathComponent().path))
        #expect(try Data(contentsOf: second.fileURL) == Data("resource fixture".utf8))
        await second.release()
        #expect(!FileManager.default.fileExists(atPath: second.fileURL.deletingLastPathComponent().path))
        #expect(try await store.commitCleanup(store.planCleanup()).deletedCount == 1)
        await store.close(); try await f.remove()
    }

    @Test func recoveryRemovesOrphanedNamedExportAndRejectsSymlinkDirectories() async throws {
        let f = try await Fixture(), store = try f.store()
        let id = try await store.publishCopy(of: f.source, byteCount: 16, checksum: f.checksum, retention: .retained)
        let original = try await store.borrow(id)
        let orphan = f.root.appending(path: "exports").appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        try FileManager.default.linkItem(at: original.fileURL, to: orphan.appending(path: "原件.txt"))
        await original.release(); await store.close()
        let restored = try f.store(); try await restored.reconcileFiles()
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        let use = try await restored.borrow(id)
        #expect(try Data(contentsOf: use.fileURL) == Data("resource fixture".utf8))
        await use.release(); await restored.close()
        let link = f.root.appending(path: "exports").appending(path: UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.source.deletingLastPathComponent())
        let unsafe = try f.store()
        await #expect(throws: V2ResourceStorageError.unsafeFile) { try await unsafe.reconcileFiles() }
        #expect(FileManager.default.fileExists(atPath: f.source.path))
        try FileManager.default.removeItem(at: link)
        await unsafe.close(); try await f.remove()
    }

    @Test func avatarCacheClassificationSurvivesReopenAndNeverDoubleCountsSharedBytes() async throws {
        let f = try await Fixture(), files = try f.store()
        let id = try await files.publishCopy(of: f.source, byteCount: 16, checksum: f.checksum, retention: .cache)
        let avatar = MediaID(uuid: UUID()), message = MediaID(uuid: UUID())
        _ = try f.journal.bindCache(identity: "avatar-test", family: "avatar:account:test", mediaID: avatar, fileID: id)
        let first = try await files.snapshot()
        #expect(first.avatarCacheBytes > 0 && first.avatarCacheBytes == first.totalBytes && first.otherCacheBytes == 0)
        await files.close()
        let reopened = try f.store()
        #expect(try await reopened.snapshot().avatarCacheBytes == first.avatarCacheBytes)
        _ = try f.journal.bindCache(identity: "message-test", family: "message:test", mediaID: message, fileID: id)
        let shared = try await reopened.snapshot()
        #expect(shared.avatarCacheBytes == 0 && shared.otherCacheBytes == first.totalBytes && shared.totalBytes == first.totalBytes)
        try f.journal.removeCacheBindings(mediaID: message)
        #expect(try await reopened.snapshot().avatarCacheBytes == first.totalBytes)
        try await reopened.setRetained(true, fileID: id)
        let retained = try await reopened.snapshot()
        #expect(retained.avatarCacheBytes == 0 && retained.otherCacheBytes == 0)
        #expect(retained.bytes(for: .retained) == first.totalBytes && retained.totalBytes == first.totalBytes)
        await reopened.close(); try await f.remove()
    }
    @Test func presentationAliasIsAnIndependentBorrowAndCannotEscapeOwner() async throws {
        let f = try await Fixture(), store = try f.store()
        let id = try await store.publishCopy(of: f.source, byteCount: 16, checksum: f.checksum, retention: .cache)
        let original = try await store.borrow(id)
        let initialBytes = try await store.snapshot().totalBytes
        let preview = try await original.forPresentation(fileExtension: "txt")
        #expect(preview.fileURL.pathExtension == "txt")
        #expect(try Data(contentsOf: preview.fileURL) == Data(contentsOf: original.fileURL))
        let a = try FileManager.default.attributesOfItem(atPath: original.fileURL.path)
        let b = try FileManager.default.attributesOfItem(atPath: preview.fileURL.path)
        #expect(a[.systemFileNumber] as? NSNumber == b[.systemFileNumber] as? NSNumber)
        #expect(try await store.snapshot().totalBytes == initialBytes)
        try FileManager.default.removeItem(at: original.fileURL)
        try await store.reconcileFiles()
        #expect(try Data(contentsOf: original.fileURL) == Data(contentsOf: preview.fileURL))
        #expect(try await store.snapshot().totalBytes == initialBytes)
        await #expect(throws: V2ResourceStorageError.invalidRecord) { try await original.forPresentation(fileExtension: "../outside") }
        await original.release()
        await #expect(throws: V2ResourceStorageError.unavailable) { try await original.forPresentation(fileExtension: "txt") }
        #expect(try await store.planCleanup().fileIDs.isEmpty)
        let alias = preview.fileURL
        await preview.release(); await preview.release()
        #expect(!FileManager.default.fileExists(atPath: alias.path))
        let plan = try await store.planCleanup()
        #expect(try await store.commitCleanup(plan).deletedCount == 1)
        await store.close(); try await f.remove()
    }

    @Test func recoveryRemovesAbandonedPresentationAliasWithoutDeletingCanonicalBytes() async throws {
        let f = try await Fixture(), store = try f.store()
        let id = try await store.publishCopy(of: f.source, byteCount: 16, checksum: f.checksum, retention: .retained)
        let borrowed = try await store.borrow(id)
        let orphan = f.root.appending(path: "presentations/\(UUID()).txt")
        try FileManager.default.linkItem(at: borrowed.fileURL, to: orphan)
        await borrowed.release(); await store.close()
        let restored = try f.store()
        try await restored.reconcileFiles()
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        let use = try await restored.borrow(id)
        #expect(try Data(contentsOf: use.fileURL) == Data("resource fixture".utf8))
        await use.release(); await restored.close(); try await f.remove()
    }

    @Test func activeBorrowCannotBeEvictedToAdmitAnotherTransfer() async throws {
        let f = try await Fixture()
        let facts = try f.source.resourceValues(forKeys: [.totalFileAllocatedSizeKey,.fileAllocatedSizeKey])
        let allocation = Int64(try #require(facts.totalFileAllocatedSize ?? facts.fileAllocatedSize))
        let store = try f.store(budget: allocation + 31)
        let id = try await store.publishCopy(of: f.source, byteCount: 16, checksum: f.checksum, retention: .cache)
        let use = try await store.borrow(id), path = use.fileURL
        await #expect(throws: V2ResourceStorageError.capacityExceeded) {
            try await store.reserveTransient(identity: "new-content", bytes: 16)
        }
        #expect(try Data(contentsOf: path) == Data("resource fixture".utf8))
        await use.release()
        let reservation = try await store.reserveTransient(identity: "new-content", bytes: 16)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        try await store.releaseTransient(reservation.id, discard: true)
        await store.close(); try await f.remove()
    }

    @Test(arguments: [V2ResourceFileRetention.cache, .retained, .original])
    func corruptPublishedBytesCannotPoisonDedupOrDeleteProtectedOriginals(retention: V2ResourceFileRetention) async throws {
        let f = try await Fixture(), store = try f.store()
        let id = try await store.publishCopy(of: f.source, byteCount: 16, checksum: f.checksum, retention: retention)
        let use = try await store.borrow(id), oldURL = use.fileURL
        await use.release()
        try Data(repeating: 0, count: 16).write(to: oldURL)
        let fresh = try await store.publishCopy(of: f.source, byteCount: 16, checksum: f.checksum, retention: .cache)
        #expect(fresh != id)
        #expect(try await store.publishCopy(of: f.source, byteCount: 16, checksum: f.checksum, retention: .cache) == fresh)
        if retention == .cache {
            #expect(try f.journal.record(id) == nil)
            #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        } else {
            #expect(try f.journal.record(id)?.state == .invalid)
            #expect(try Data(contentsOf: oldURL) == Data(repeating: 0, count: 16))
            let plan = try await store.planCleanup()
            #expect(!plan.fileIDs.contains(id))
            #expect(try await store.snapshot().totalBytes > 0)
        }
        let recovered = try await store.borrow(fresh)
        #expect(try Data(contentsOf: recovered.fileURL) == Data("resource fixture".utf8))
        await recovered.release()
        await store.close(); try await f.remove()
    }

    @Test func corruptInterruptedRenameIsIsolatedDuringRecovery() async throws {
        struct Interrupted: Error {}
        let f = try await Fixture(), id = V2LocalResourceFileID()
        let interrupted = try V2ResourceFileStore(root: f.root, journal: f.journal, policy: .testBounded(1_048_576)) { stage in
            if stage == .renamed { throw Interrupted() }
        }
        await #expect(throws: Interrupted.self) {
            try await interrupted.publishCopy(of: f.source, fileID: id, byteCount: 16, checksum: f.checksum, retention: .original)
        }
        await interrupted.close()
        let file = f.root.appending(path: "files/\(id.value.uuidString)")
        try Data(repeating: 9, count: 16).write(to: file)
        let restored = try f.store()
        try await restored.reconcileFiles()
        #expect(try f.journal.record(id)?.state == .invalid)
        let fresh = try await restored.publishCopy(of: f.source, byteCount: 16, checksum: f.checksum, retention: .cache)
        #expect(fresh != id)
        #expect(try Data(contentsOf: file) == Data(repeating: 9, count: 16))
        await restored.close(); try await f.remove()
    }

    @Test func cleanupAccountsForAbandonedDownloadBytesButNeverAnActiveProducer() async throws {
        let f = try await Fixture(), store = try f.store()
        let active = try await store.reserveTransient(identity: "bounded-download", bytes: 4096)
        try Data(repeating: 7, count: 2048).write(to: active.fileURL.appendingPathExtension("range-part"))
        let protected = try await store.planCleanup()
        #expect(protected.transferStagingIDs.isEmpty && protected.skippedCount == 1)
        #expect(try await store.commitCleanup(protected).deletedCount == 0)
        try await store.releaseTransient(active.id, discard: false)
        let usage = try await store.snapshot()
        #expect(usage.transferReservedBytes == 8192 && usage.transferAllocatedBytes > 0)
        let plan = try await store.planCleanup()
        #expect(plan.transferStagingIDs == [active.id])
        #expect(plan.estimatedBytes == usage.transferAllocatedBytes)
        let result = try await store.commitCleanup(plan)
        #expect(result.deletedCount == 1 && result.releasedBytes == usage.transferAllocatedBytes)
        #expect(try await store.snapshot().transferReservedBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: active.fileURL.appendingPathExtension("range-part").path))
        await store.close(); try await f.remove()
    }
    private struct Fixture {
        let directory: URL
        let source: URL
        let root: URL
        let database: GRDBV2LocalSyncStore
        let journal: V2ResourceFileJournal
        let checksum: V2ResourceChecksum

        init() async throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("resource-files-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            source = directory.appendingPathComponent("source.txt")
            try Data("resource fixture".utf8).write(to: source)
            root = directory.appendingPathComponent("managed")
            database = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("V2.sqlite"),
                installationBinding: .init(value: UUID()), userID: .init(uuid: UUID()))
            journal = await database.resourceFileJournal()
            checksum = try .init(value: V2ResourceFileDigest.sha256(fileURL: source, expectedByteCount: 16))
        }

        func store(budget: Int64 = 1_048_576) throws -> V2ResourceFileStore {
            try .init(root: root, journal: journal, policy: .testBounded(budget))
        }
        func remove() async throws {
            try await database.close()
            try FileManager.default.removeItem(at: directory)
        }
    }

    @Test func publicationIsImmutableAndRetryKeepsIdentity() async throws {
        let f = try await Fixture(), store = try f.store(), id = V2LocalResourceFileID()
        let published = try await store.publishCopy(of: f.source, fileID: id, byteCount: 16, checksum: f.checksum, retention: .cache)
        #expect(published == id)
        #expect(try await store.publishCopy(of: f.source, fileID: id, byteCount: 16, checksum: f.checksum, retention: .cache) == id)
        #expect(try await store.snapshot().files.count == 1)
        #expect(FileManager.default.fileExists(atPath: f.source.path))
        let lease = try await store.borrow(id)
        #expect(try Data(contentsOf: lease.fileURL) == Data("resource fixture".utf8))
        await lease.release()
        await store.close()
        await #expect(throws: V2ResourceStorageError.closed) { try await store.snapshot() }
        try await f.remove()
    }

    @Test func cleanupRechecksNewBorrowAndPersistentDependency() async throws {
        let f = try await Fixture(), store = try f.store()
        let id = try await store.publishCopy(of: f.source, byteCount: 16, checksum: f.checksum, retention: .cache)
        let plan = try await store.planCleanup()
        #expect(plan.fileIDs == [id])
        let lease = try await store.borrow(id)
        let blocked = try await store.commitCleanup(plan)
        #expect(blocked.deletedCount == 0 && blocked.skippedCount == 1)
        await lease.release()
        let second = try await store.planCleanup(), consumer = UUID()
        try f.journal.addConsumer(consumer, fileID: id)
        #expect(try await store.commitCleanup(second).skippedCount == 1)
        try f.journal.removeConsumer(consumer, fileID: id)
        let third = try await store.planCleanup()
        #expect(try await store.commitCleanup(third).deletedCount == 1)
        #expect(try await store.snapshot().files.isEmpty)
        await store.close(); try await f.remove()
    }

    @Test func retainedAndOriginalNeverEnterOrdinaryCleanup() async throws {
        let f = try await Fixture(), store = try f.store()
        let retained = try await store.publishCopy(of: f.source, byteCount: 16, checksum: f.checksum, retention: .retained)
        let other = f.directory.appendingPathComponent("original.txt")
        try Data("another original".utf8).write(to: other)
        let digest = try V2ResourceChecksum(value: V2ResourceFileDigest.sha256(fileURL: other, expectedByteCount: 16))
        let original = try await store.publishCopy(of: other, byteCount: 16, checksum: digest, retention: .original)
        let plan = try await store.planCleanup()
        #expect(plan.fileIDs.isEmpty && plan.skippedCount == 2)
        try await store.setRetained(false, fileID: original)
        #expect(try f.journal.record(original)?.retention == .original)
        try await store.setRetained(false, fileID: retained)
        #expect(try await store.planCleanup().fileIDs == [retained])
        await store.close(); try await f.remove()
    }

    @Test(arguments: V2ResourceFileStore.PublicationCheckpoint.allCases)
    func interruptedPublicationRecoversWithoutPublishingPartial(checkpoint: V2ResourceFileStore.PublicationCheckpoint) async throws {
        struct Interrupted: Error {}
        let f = try await Fixture(), id = V2LocalResourceFileID()
        let interrupted = try V2ResourceFileStore(root: f.root, journal: f.journal, policy: .testBounded(1_048_576)) { stage in
            if stage == checkpoint { throw Interrupted() }
        }
        await #expect(throws: Interrupted.self) {
            try await interrupted.publishCopy(of: f.source, fileID: id, byteCount: 16, checksum: f.checksum, retention: .cache)
        }
        await interrupted.close()
        let restarted = try f.store()
        let snapshot = try await restarted.snapshot()
        if checkpoint == .partialWritten {
            #expect(snapshot.files.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("partials").path).isEmpty)
        } else {
            #expect(snapshot.files.map(\.id) == [id])
            #expect(try await restarted.publishCopy(of: f.source, fileID: id, byteCount: 16, checksum: f.checksum, retention: .cache) == id)
        }
        await restarted.close(); try await f.remove()
    }

    @Test func sizeAndDigestFailuresCannotPublishBytes() async throws {
        let f = try await Fixture(), store = try f.store()
        await #expect(throws: V2ResourceStorageError.integrityMismatch) {
            try await store.publishCopy(of: f.source, byteCount: 15, checksum: f.checksum, retention: .cache)
        }
        #expect(try await store.snapshot().files.isEmpty)
        let wrong = try V2ResourceChecksum(value: String(repeating: "0", count: 64))
        await #expect(throws: V2ResourceStorageError.integrityMismatch) {
            try await store.publishCopy(of: f.source, byteCount: 16, checksum: wrong, retention: .cache)
        }
        #expect(try await store.snapshot().files.isEmpty)
        await store.close(); try await f.remove()
    }

    @Test func expiredPlanAndLateRetentionChangeDoNotDelete() async throws {
        let f = try await Fixture(), store = try f.store(), now = Date()
        let id = try await store.publishCopy(of: f.source, byteCount: 16, checksum: f.checksum, retention: .cache)
        let expired = try await store.planCleanup(now: now)
        await #expect(throws: V2ResourceStorageError.expiredCleanupPlan) { try await store.commitCleanup(expired, now: now.addingTimeInterval(31)) }
        let changed = try await store.planCleanup()
        try await store.setRetained(true, fileID: id)
        #expect(try await store.commitCleanup(changed).skippedCount == 1)
        await store.close(); try await f.remove()
    }

    @Test func symlinkInputAndManagedDirectoryAreRejected() async throws {
        let f = try await Fixture(), store = try f.store()
        let link = f.directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.source)
        await #expect(throws: V2ResourceStorageError.unsafeFile) {
            try await store.publishCopy(of: link, byteCount: 16, checksum: f.checksum, retention: .cache)
        }
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("files"))
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("files"), withDestinationURL: f.directory)
        await #expect(throws: V2ResourceStorageError.unsafeFile) { try await store.snapshot() }
        #expect(FileManager.default.fileExists(atPath: f.source.path))
        await store.close(); try await f.remove()
    }

    @Test func boundedAdmissionAndMissingFileReconciliation() async throws {
        let f = try await Fixture(), tiny = try f.store(budget: 15)
        await #expect(throws: V2ResourceStorageError.capacityExceeded) {
            try await tiny.publishCopy(of: f.source, byteCount: 16, checksum: f.checksum, retention: .cache)
        }
        await tiny.close()
        let first = try f.store()
        _ = try await first.setStoragePolicy(.testBounded(1_048_576))
        let id = try await first.publishCopy(of: f.source, byteCount: 16, checksum: f.checksum, retention: .retained)
        let lease = try await first.borrow(id), path = lease.fileURL
        await lease.release(); await first.close()
        try FileManager.default.removeItem(at: path)
        let restarted = try f.store()
        #expect(try await restarted.snapshot().files.first?.state == .missing)
        #expect(try await restarted.snapshot().totalBytes == 0)
        await #expect(throws: V2ResourceStorageError.unavailable) { try await restarted.borrow(id) }
        await restarted.close(); try await f.remove()
    }
}
