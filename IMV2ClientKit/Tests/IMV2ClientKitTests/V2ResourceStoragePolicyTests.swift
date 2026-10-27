import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Resource storage categories, policy persistence and quota debt", .timeLimit(.minutes(1)))
struct V2ResourceStoragePolicyTests {
    @Test func policyValidatesConstructionAndDecoding() throws {
        #expect(try JSONDecoder().decode(V2ResourceStoragePolicy.self, from: JSONEncoder().encode(V2ResourceStoragePolicy.standard)) == .standard)
        for invalid in [Int64.min, -1, 0, Int64.max] {
            #expect(throws: V2ResourceStorageError.invalidRecord) { try V2ResourceStoragePolicy(maximumCacheBytes: invalid) }
        }
        var body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(V2ResourceStoragePolicy.standard)) as? [String:Any])
        body["maximumOriginalBytes"] = 0
        #expect(throws: V2ResourceStorageError.invalidRecord) {
            try JSONDecoder().decode(V2ResourceStoragePolicy.self, from: JSONSerialization.data(withJSONObject: body))
        }
    }

    @Test("originals and retained files do not consume the ordinary cache allowance")
    func independentCategoriesAndCacheLRU() async throws {
        let f = try await Fixture()
        let policy = try f.policy(cache: f.allocation, originals: f.allocation * 2)
        let files = try f.files(policy)
        let original = try await files.importOriginal(source: f.sources[0], id: .init(), displayName: .init("original.dat"), contentType: .init("application/octet-stream"),
            purpose: .personalAvatar, maximumBytes: 8192, maximumSelections: 16)
        let retained = try await f.publish(1, to: files, retention: .retained)
        let cache = try await f.publish(2, to: files, retention: .cache)
        let held = try await files.borrow(cache)
        await #expect(throws: V2ResourceStorageError.capacityExceeded) { try await f.publish(3, to: files, retention: .cache) }
        #expect(try Data(contentsOf: held.fileURL) == f.body(2))
        await held.release()
        let next = try await f.publish(3, to: files, retention: .cache)
        #expect(try f.journal.record(cache) == nil)
        let snapshot = try await files.snapshot()
        #expect(snapshot.quota.cacheBytes == f.allocation)
        #expect(snapshot.quota.originalBytes == f.allocation)
        #expect(snapshot.quota.retainedBytes == f.allocation)
        #expect(snapshot.quota.retainedWarning)
        #expect(snapshot.quota.managedBytes > policy.maximumCacheBytes)
        #expect(snapshot.quota.policy.maximumManagedBytes == nil)
        let originalUse = try await files.borrowOriginal(for: .selection(original.id))
        let retainedUse = try await files.borrow(retained), nextUse = try await files.borrow(next)
        #expect(try Data(contentsOf: originalUse.fileURL) == f.body(0))
        #expect(try Data(contentsOf: retainedUse.fileURL) == f.body(1))
        #expect(try Data(contentsOf: nextUse.fileURL) == f.body(3))
        await originalUse.release(); await retainedUse.release(); await nextUse.release()
        await files.close(); try await f.remove()
    }

    @Test("a smaller policy preserves active and original bytes, exposes overage and survives a cold owner")
    func lowerPolicyWithoutDestroyingProtectedBytes() async throws {
        let f = try await Fixture(), initial = try f.policy(cache: f.allocation * 3, originals: f.allocation * 3)
        let files = try f.files(initial)
        let a = try await f.publish(0, to: files, retention: .cache)
        let b = try await f.publish(1, to: files, retention: .cache)
        let original = try await files.importOriginal(source: f.sources[2], id: .init(), displayName: .init("draft.dat"), contentType: .init("application/octet-stream"),
            purpose: .personalAvatar, maximumBytes: 8192, maximumSelections: 16)
        let use = try await files.borrow(a)
        let smaller = try f.policy(cache: 1, originals: 1)
        let changed = try await files.setStoragePolicy(smaller)
        #expect(changed.cacheOverageBytes == f.allocation - 1)
        #expect(changed.originalOverageBytes == f.allocation - 1)
        #expect(try f.journal.record(b) == nil)
        #expect(try Data(contentsOf: use.fileURL) == f.body(0))
        await #expect(throws: V2ResourceStorageError.capacityExceeded) { try await f.publish(3, to: files, retention: .cache) }
        await #expect(throws: V2ResourceStorageError.capacityExceeded) {
            try await files.importOriginal(source: f.sources[3], id: .init(), displayName: .init("new.dat"), contentType: .init("application/octet-stream"),
                purpose: .personalAvatar, maximumBytes: 8192, maximumSelections: 16)
        }
        // Another draft referencing an already protected physical original does
        // not grow disk use and does not erase the older draft's dependency.
        let shared = try await files.importOriginal(source: f.sources[2], id: .init(), displayName: .init("shared.dat"), contentType: .init("application/octet-stream"),
            purpose: .messageDraft(.init(uuid: UUID())), maximumBytes: 8192, maximumSelections: 16)
        #expect(shared.fileID == original.fileID)
        await use.release()
        try await files.maintainCache(maximumEntryCount: 8, maximumAge: 3600)
        #expect(try f.journal.record(a) == nil)
        await files.close()
        let restored = try f.files(.standard)
        let state = try await restored.snapshot()
        #expect(state.quota.policy == smaller)
        #expect(state.quota.cacheBytes == 0 && state.quota.originalOverageBytes == f.allocation - 1)
        let saved = try await restored.borrowOriginal(for: .selection(original.id))
        #expect(try Data(contentsOf: saved.fileURL) == f.body(2))
        await saved.release(); await restored.close(); try await f.remove()
    }

    @Test("active transfer reservations cannot be reclaimed and existing checkpoints can resume after a smaller limit")
    func temporaryPolicyAndResume() async throws {
        let f = try await Fixture(), files = try f.files(.init(maximumCacheBytes: 65536, maximumTemporaryBytes: 10))
        let first = try await files.reserveTransient(identity: "checkpoint", bytes: 6, footprint: .singleFile)
        try Data(repeating: 1, count: 6).write(to: first.fileURL)
        await #expect(throws: V2ResourceStorageError.capacityExceeded) { try await files.reserveTransient(identity: "other", bytes: 6, footprint: .singleFile) }
        let smaller = try V2ResourceStoragePolicy(maximumCacheBytes: 65536, maximumTemporaryBytes: 4)
        #expect(try await files.setStoragePolicy(smaller).temporaryOverageBytes == 2)
        #expect(try Data(contentsOf: first.fileURL) == Data(repeating: 1, count: 6))
        try await files.releaseTransient(first.id, discard: false)
        let resumed = try await files.reserveTransient(identity: "checkpoint", bytes: 6, footprint: .singleFile)
        #expect(resumed.fileURL == first.fileURL)
        try await files.releaseTransient(resumed.id, discard: true)
        #expect(try await files.snapshot().quota.temporaryReservedBytes == 0)
        await files.close(); try await f.remove()
    }

    @Test("verified interrupted originals recover even when a lower policy was persisted before restart")
    func recoveryAdoptsBytesInsteadOfStrandingPublication() async throws {
        struct Interrupted: Error {}
        let f = try await Fixture(), initial = try f.policy(cache: 65536, originals: 65536)
        let files = try V2ResourceFileStore(root: f.persistent, cacheRoot: f.cache, journal: f.journal, policy: initial) { stage in
            if stage == .renamed { throw Interrupted() }
        }
        let id = V2LocalResourceFileID()
        await #expect(throws: Interrupted.self) {
            try await files.publishCopy(of: f.sources[0], fileID: id, byteCount: 4096, checksum: f.digest(0), retention: .original)
        }
        await files.close()
        try f.journal.setStoragePolicy(f.policy(cache: 1, originals: 1))
        let restored = try f.files(.standard)
        try await restored.reconcileFiles()
        #expect(try f.journal.record(id)?.state == .published)
        #expect(try await restored.snapshot().quota.originalOverageBytes == f.allocation - 1)
        let use = try await restored.borrow(id)
        #expect(try Data(contentsOf: use.fileURL) == f.body(0))
        await use.release(); await restored.close(); try await f.remove()
    }

    @Test("minimum free-space admission leaves external source and draft journal untouched")
    func lowDiskAdmission() async throws {
        let f = try await Fixture()
        let files = try f.files(.init(maximumCacheBytes: 65536, minimumFreeBytes: Int64.max / 8))
        await #expect(throws: V2ResourceStorageError.capacityExceeded) {
            try await files.importOriginal(source: f.sources[0], id: .init(), displayName: .init("original.dat"), contentType: .init("application/octet-stream"),
                purpose: .personalAvatar, maximumBytes: 8192, maximumSelections: 16)
        }
        #expect(try await files.snapshot().files.isEmpty)
        #expect(try await files.selectedAssets(purpose: .personalAvatar).isEmpty)
        #expect(try Data(contentsOf: f.sources[0]) == f.body(0))
        await files.close(); try await f.remove()
    }

    private struct Fixture {
        let root: URL, persistent: URL, cache: URL, sources: [URL], allocation: Int64
        let store: GRDBV2LocalSyncStore, journal: V2ResourceFileJournal
        init() async throws {
            root = FileManager.default.temporaryDirectory.appending(path: "resource-policy-\(UUID())")
            persistent = root.appending(path: "support"); cache = root.appending(path: "cache")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let sourceRoot = root
            sources = (0..<4).map { sourceRoot.appending(path: "source-\($0)") }
            for (i, source) in sources.enumerated() { try Data(repeating: UInt8(i + 1), count: 4096).write(to: source) }
            let facts = try sources[0].resourceValues(forKeys: [.totalFileAllocatedSizeKey,.fileAllocatedSizeKey])
            allocation = Int64(try #require(facts.totalFileAllocatedSize ?? facts.fileAllocatedSize))
            store = try .init(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()), userID: .init(uuid: UUID()))
            journal = await store.resourceFileJournal()
        }
        func policy(cache: Int64, originals: Int64) throws -> V2ResourceStoragePolicy {
            try .init(maximumCacheBytes: cache, maximumOriginalBytes: originals, retainedWarningBytes: allocation)
        }
        func files(_ policy: V2ResourceStoragePolicy) throws -> V2ResourceFileStore { try .init(root: persistent, cacheRoot: cache, journal: journal, policy: policy) }
        func body(_ index: Int) -> Data { Data(repeating: UInt8(index + 1), count: 4096) }
        func digest(_ index: Int) throws -> V2ResourceChecksum { try .init(value: V2ResourceFileDigest.sha256(fileURL: sources[index], expectedByteCount: 4096)) }
        func publish(_ index: Int, to files: V2ResourceFileStore, retention: V2ResourceFileRetention) async throws -> V2LocalResourceFileID {
            try await files.publishCopy(of: sources[index], byteCount: 4096, checksum: digest(index), retention: retention)
        }
        func remove() async throws { try await store.close(); try FileManager.default.removeItem(at: root) }
    }
}
