import Foundation
import IMV2Core
import Synchronization
import Testing
@testable import IMV2ClientKit
@testable import IMApp

@MainActor
@Suite("iOS account background source ownership", .timeLimit(.minutes(1)))
struct V2BackgroundUploadSourceTests {
    @Test("only the bounded upload part requests AFU protection; the source remains Complete")
    func boundedPartAndProtectionBoundaries() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "app-background-source-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = BackgroundSourceProtectionWitness()
        let fixture = try await V2OriginalResourceTestFixture(root: root.appending(path: "account"), protection: writer)
        let body = Data((0..<4096).map { UInt8($0 % 251) })
        let source = root.appending(path: "source.bin"); try body.write(to: source)
        let selected = try await fixture.stager.stageImportedFile(at: source, purpose: .personalAvatar)
        let use = try await fixture.stager.borrow(.selection(selected.localAssetID))
        let id = UUID(), session = UUID()
        let files = await fixture.resources.files
        let part = try await files.makeBackgroundUploadSource(from: use, sessionID: session, id: id,
            range: .init(lowerBound: 1024, upperBound: 2047))
        #expect(try Data(contentsOf: part) == body[1024..<2048])
        #expect(part.path.hasPrefix(fixture.scope.backgroundDirectory.path))
        #expect(!part.path.hasPrefix(fixture.scope.directory.path + "/"))
        #expect(writer.policy(at: use.fileURL) == .complete)
        #expect(writer.policy(at: part) == .untilFirstAuthentication)
        #expect(writer.policy(at: fixture.scope.backgroundDirectory) == .untilFirstAuthentication)
        #expect(try part.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let usage = try await fixture.resources.storageSnapshot()
        #expect(usage.backgroundReservedBytes >= 2048 && usage.backgroundAllocatedBytes > 0)
        let cleanup = try await fixture.resources.planCleanup()
        #expect(try await fixture.resources.commitCleanup(cleanup).deletedCount == 0)
        try await files.releaseBackgroundUploadSource(id: id, sessionID: session)
        #expect(!FileManager.default.fileExists(atPath: part.path))
        #expect(try Data(contentsOf: use.fileURL) == body)
        await use.release(); try await fixture.close()
    }

    @Test("system cache eviction preserves the AFU source and the only original")
    func cacheEvictionPreservesBackgroundAndOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "app-background-cache-purge-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await V2OriginalResourceTestFixture(root: root.appending(path: "account"))
        let body = Data(repeating: 4, count: 4096)
        let asset = try await fixture.resources.importLocal(data: body, displayName: .init("source.bin"), contentType: .init("application/octet-stream"), purpose: .personalAvatar)
        let use = try await fixture.stager.borrow(.selection(asset.id))
        let id = UUID(), session = UUID()
        let files = await fixture.resources.files
        let part = try await files.makeBackgroundUploadSource(from: use, sessionID: session, id: id, range: .init(lowerBound: 0, upperBound: 4095))
        try FileManager.default.removeItem(at: fixture.scope.cacheDirectory)
        let snapshot = try await fixture.resources.storageSnapshot()
        #expect(snapshot.backgroundReservedBytes >= 8192)
        #expect(try Data(contentsOf: part) == body && Data(contentsOf: use.fileURL) == body)
        try await files.releaseBackgroundUploadSource(id: id, sessionID: session)
        await use.release(); try await fixture.close()
    }
}

/// Records requested classes while applying the real iOS writer. Simulator
/// attributes cannot prove locked-device key availability; that remains a
/// separate device lifecycle gate.
nonisolated private final class BackgroundSourceProtectionWitness: V2ResourceFileProtectionWriting {
    private let values = Mutex<[String: V2ResourceFileProtection]>([:])
    func apply(_ protection: V2ResourceFileProtection, to file: URL) throws {
        try V2SystemResourceFileProtectionWriter().apply(protection, to: file)
        values.withLock { $0[file.path] = protection }
    }
    func policy(at file: URL) -> V2ResourceFileProtection? { values.withLock { $0[file.path] } }
}
