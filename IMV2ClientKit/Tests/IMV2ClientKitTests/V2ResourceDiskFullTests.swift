#if os(macOS)
import Foundation
import Darwin
import IMV2Core
import Testing
@testable import IMV2ClientKit

/// Opt-in destructive writes are confined to a tiny, separately mounted test
/// volume. Never run the filler against the host data volume or an arbitrary path.
@Suite("Real filesystem exhaustion recovery", .serialized, .timeLimit(.minutes(1)))
struct V2ResourceDiskFullTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_ENOSPC_VOLUME"] != nil))
    func publicationFailurePreservesSourceAndRecoversAfterSpaceReturns() async throws {
        let volume = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_ENOSPC_VOLUME"])).resolvingSymlinksInPath()
        let facts = try volume.resourceValues(forKeys: [.volumeIsRootFileSystemKey, .volumeTotalCapacityKey])
        try #require(facts.volumeIsRootFileSystem == false)
        let directoryFD = Darwin.open(volume.path, O_RDONLY)
        try #require(directoryFD >= 0)
        defer { Darwin.close(directoryFD) }
        var filesystem = statfs()
        try #require(fstatfs(directoryFD, &filesystem) == 0)
        let mount = withUnsafeBytes(of: filesystem.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        try #require(URL(fileURLWithPath: mount).resolvingSymlinksInPath().path == volume.path)
        try #require((facts.volumeTotalCapacity ?? .max) <= 256 * 1024 * 1024)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("disk-full-journal-\(UUID())")
        let work = volume.appendingPathComponent("owned-resource-test-\(UUID())")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work); try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("original"), bytes = Data(repeating: 37, count: 256 * 1024)
        try bytes.write(to: source)
        let checksum = try V2ResourceChecksum(value: V2ResourceFileDigest.sha256(fileURL: source, expectedByteCount: Int64(bytes.count)))
        let store = try GRDBV2LocalSyncStore(databaseURL: local.appendingPathComponent("journal.sqlite"), installationBinding: .init(value: UUID()), userID: .init(uuid: UUID()))
        let journal = await store.resourceFileJournal(), filler = work.appendingPathComponent("concurrent-space-consumer")
        let policy = try V2ResourceStoragePolicy(maximumCacheBytes: 2 * 1024 * 1024, minimumFreeBytes: 0)
        let files = try V2ResourceFileStore(root: work.appendingPathComponent("resources"), journal: journal, policy: policy,
            protection: FillTestVolumeBeforePublication(filler: filler))
        let id = V2LocalResourceFileID()
        do {
            do {
                _ = try await files.publishCopy(of: source, fileID: id, byteCount: Int64(bytes.count), checksum: checksum, retention: .cache)
                Issue.record("Publication unexpectedly succeeded on an exhausted filesystem")
            } catch { #expect(Self.isDiskFull(error), "Expected actual ENOSPC, got \(error)") }
            #expect(try Data(contentsOf: source) == bytes)
            #expect(try journal.record(id)?.state == .publishing)
            await files.close()
            try FileManager.default.removeItem(at: filler)
            let recovered = try V2ResourceFileStore(root: work.appendingPathComponent("resources"), journal: journal, policy: policy)
            #expect(try await recovered.snapshot().files.isEmpty)
            let published = try await recovered.publishCopy(of: source, fileID: id, byteCount: Int64(bytes.count), checksum: checksum, retention: .cache)
            let lease = try await recovered.borrow(published)
            #expect(try Data(contentsOf: lease.fileURL) == bytes)
            await lease.release(); await recovered.close(); try await store.close()
        } catch { await files.close(); try? await store.close(); throw error }
    }
    static func isDiskFull(_ error: any Error) -> Bool {
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain && value.code == 28 { return true }
        if value.domain == NSCocoaErrorDomain && value.code == CocoaError.Code.fileWriteOutOfSpace.rawValue { return true }
        return (value.userInfo[NSUnderlyingErrorKey] as? any Error).map(isDiskFull) ?? false
    }
}

private struct FillTestVolumeBeforePublication: V2ResourceFileProtectionWriting {
    let filler: URL
    func apply(_ protection: V2ResourceFileProtection, to file: URL) throws {
        guard file.deletingLastPathComponent().lastPathComponent == "partials",
              (try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular else { return }
        // This callback runs after successful admission and creation of the
        // journaled partial, reproducing a concurrent disk consumer's race.
        try Data().write(to: filler, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: filler)
        defer { try? handle.close() }
        let chunk = Data(repeating: 91, count: 65536)
        while true {
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: filler.path)
            let free = try #require((attributes[.systemFreeSize] as? NSNumber)?.int64Value)
            // Leave metadata room so backup/protection xattrs can be installed;
            // the actual 256 KiB payload write must encounter real ENOSPC.
            guard free > 96 * 1024 + Int64(chunk.count) else { break }
            try handle.write(contentsOf: chunk)
        }
        try handle.synchronize()
    }
}
#endif
