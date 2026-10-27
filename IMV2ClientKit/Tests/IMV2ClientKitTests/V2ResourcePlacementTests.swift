import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Persistent originals, purgeable caches and journaled placement", .timeLimit(.minutes(1)))
struct V2ResourcePlacementTests {
    @Test("pin toggles during a live borrow keep both paths safe and retire the obsolete link once")
    func togglesDuringBorrow() async throws {
        let f = try await Fixture(), files = try f.files()
        let id = try await files.publishCopy(of: f.source, byteCount: 16, checksum: f.checksum, retention: .cache)
        let use = try await files.borrow(id)
        try await files.setRetained(true, fileID: id)
        try await files.setRetained(false, fileID: id)
        #expect(try f.journal.record(id)?.storage == .cache)
        #expect(try f.journal.record(id)?.isPinned == false)
        #expect(try Data(contentsOf: use.fileURL) == Data("resource fixture".utf8))
        await use.release()
        #expect(try f.journal.relocations().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.persistent.appending(path: "files").path).isEmpty)
        await files.close(); try await f.remove()
    }

    @Test("a corrupt interrupted placement cannot block unrelated files or discard the caller's input")
    func isolatedCorruptPlacement() async throws {
        struct Interrupted: Error {}
        let f = try await Fixture(), seed = try f.files()
        let id = try await seed.publishCopy(of: f.source, byteCount: 16, checksum: f.checksum, retention: .cache)
        let use = try await seed.borrow(id), url = use.fileURL
        await use.release(); await seed.close()
        let interrupted = try V2ResourceFileStore(root: f.persistent, cacheRoot: f.cache, journal: f.journal, policy: .testBounded(1_048_576),
            placementCheckpoint: { if $0 == .targetLinked { throw Interrupted() } }, checkpoint: { _ in })
        await #expect(throws: Interrupted.self) { try await interrupted.setRetained(true, fileID: id) }
        await interrupted.close()
        try Data(repeating: 8, count: 16).write(to: url)
        let restored = try f.files()
        try await restored.reconcileFiles()
        #expect(try f.journal.record(id)?.state == .invalid)
        #expect(try f.journal.relocations().isEmpty)
        let fresh = try await restored.publishCopy(of: f.source, byteCount: 16, checksum: f.checksum, retention: .cache)
        #expect(fresh != id)
        let lease = try await restored.borrow(fresh)
        #expect(try Data(contentsOf: lease.fileURL) == Data("resource fixture".utf8))
        let plan = try await restored.planCleanup()
        #expect(plan.fileIDs == [id])
        #expect(try await restored.commitCleanup(plan).deletedCount == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.persistent.appending(path: "files").path).isEmpty)
        await lease.release(); await restored.close(); try await f.remove()
    }

    @Test("promotion preserves live URLs and the same physical bytes until real consumers release")
    func retentionDuringPreview() async throws {
        let f = try await Fixture(), files = try f.files()
        let id = try await files.publishCopy(of: f.source, byteCount: 16, checksum: f.checksum, retention: .cache)
        let old = try await files.borrow(id), oldURL = old.fileURL
        #expect(oldURL.deletingLastPathComponent().deletingLastPathComponent().path == f.cache.path)
        let bytes = try await files.snapshot().totalBytes
        try await files.setRetained(true, fileID: id)
        let pinned = try await files.borrow(id), protectedURL = pinned.fileURL
        #expect(protectedURL != oldURL)
        #expect(protectedURL.deletingLastPathComponent().deletingLastPathComponent().path == f.persistent.path)
        #expect(try Data(contentsOf: oldURL) == Data(contentsOf: protectedURL))
        let oldAttributes = try FileManager.default.attributesOfItem(atPath: oldURL.path)
        let newAttributes = try FileManager.default.attributesOfItem(atPath: protectedURL.path)
        #expect(oldAttributes[.systemFileNumber] as? NSNumber == newAttributes[.systemFileNumber] as? NSNumber)
        #expect(try await files.snapshot().totalBytes == bytes)
        #expect(try f.journal.relocations().count == 1)
        await old.release()
        #expect(FileManager.default.fileExists(atPath: oldURL.path))
        await pinned.release()
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(try f.journal.relocations().isEmpty)
        try await files.setRetained(false, fileID: id)
        let cache = try await files.borrow(id)
        #expect(cache.fileURL == oldURL)
        #expect(!FileManager.default.fileExists(atPath: protectedURL.path))
        await cache.release(); await files.close(); try await f.remove()
    }

    @Test("purging the entire cache root cannot remove an original or retained file")
    func systemCachePurge() async throws {
        let f = try await Fixture(), files = try f.files()
        let original = try await files.importOriginal(source: f.source, id: .init(), displayName: .init("draft.txt"),
            contentType: .init("text/plain"), purpose: .personalAvatar, maximumBytes: 1024, maximumSelections: 16)
        let cachedSource = f.directory.appending(path: "cached.dat")
        let retainedSource = f.directory.appending(path: "retained.dat")
        try Data(repeating: 2, count: 16).write(to: cachedSource)
        try Data(repeating: 3, count: 16).write(to: retainedSource)
        func digest(_ source: URL) throws -> V2ResourceChecksum { try .init(value: V2ResourceFileDigest.sha256(fileURL: source, expectedByteCount: 16)) }
        let cacheID = try await files.publishCopy(of: cachedSource, byteCount: 16, checksum: digest(cachedSource), retention: .cache)
        let retainedID = try await files.publishCopy(of: retainedSource, byteCount: 16, checksum: digest(retainedSource), retention: .retained)
        await files.close()
        try FileManager.default.removeItem(at: f.cache)
        let restored = try f.files()
        try await restored.reconcileFiles()
        #expect(try f.journal.record(cacheID)?.state == .missing)
        let originalLease = try await restored.borrowOriginal(for: .selection(original.id))
        let retainedLease = try await restored.borrow(retainedID)
        #expect(try Data(contentsOf: originalLease.fileURL) == Data(contentsOf: f.source))
        #expect(try Data(contentsOf: retainedLease.fileURL) == Data(repeating: 3, count: 16))
        #expect(try await restored.planCleanup().fileIDs == [cacheID])
        await originalLease.release(); await retainedLease.release()
        await restored.close(); try await f.remove()
    }

    @Test("a crash at any promotion boundary restores the durable import's identity", arguments: V2ResourceFileStore.PlacementCheckpoint.allCases)
    func importPromotionRecovery(checkpoint: V2ResourceFileStore.PlacementCheckpoint) async throws {
        struct Interrupted: Error {}
        let f = try await Fixture(), seed = try f.files(), assetID = V2LocalResourceAssetID()
        let id = try await seed.publishCopy(of: f.source, byteCount: 16, checksum: f.checksum, retention: .cache)
        await seed.close()
        let interrupted = try V2ResourceFileStore(root: f.persistent, cacheRoot: f.cache, journal: f.journal, policy: .testBounded(1_048_576),
            placementCheckpoint: { if $0 == checkpoint { throw Interrupted() } }, checkpoint: { _ in })
        await #expect(throws: Interrupted.self) {
            try await interrupted.importOriginal(source: f.source, id: assetID, displayName: .init("draft.txt"), contentType: .init("text/plain"),
                purpose: .personalAvatar, maximumBytes: 1024, maximumSelections: 16)
        }
        await interrupted.close()
        let restored = try f.files()
        try await restored.reconcileFiles()
        #expect(try f.journal.localAsset(assetID)?.fileID == id)
        #expect(try f.journal.record(id)?.retention == .original)
        #expect(try f.journal.record(id)?.storage == .persistent)
        #expect(try f.journal.relocations().isEmpty)
        let lease = try await restored.borrowOriginal(for: .selection(assetID))
        #expect(try Data(contentsOf: lease.fileURL) == Data(contentsOf: f.source))
        #expect(try await restored.snapshot().files.count == 1)
        await lease.release(); await restored.close(); try await f.remove()
    }

    private struct Fixture {
        let directory: URL, persistent: URL, cache: URL, source: URL
        let database: GRDBV2LocalSyncStore
        let journal: V2ResourceFileJournal
        let checksum: V2ResourceChecksum
        init() async throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "resource-placement-\(UUID())").resolvingSymlinksInPath()
            persistent = directory.appending(path: "support/resources")
            cache = directory.appending(path: "caches/resources")
            source = directory.appending(path: "source.txt")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("resource fixture".utf8).write(to: source)
            database = try .init(databaseURL: directory.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()), userID: .init(uuid: UUID()))
            journal = await database.resourceFileJournal()
            checksum = try .init(value: V2ResourceFileDigest.sha256(fileURL: source, expectedByteCount: 16))
        }
        func files() throws -> V2ResourceFileStore { try .init(root: persistent, cacheRoot: cache, journal: journal, policy: .testBounded(1_048_576)) }
        func remove() async throws { try await database.close(); try FileManager.default.removeItem(at: directory) }
    }
}
