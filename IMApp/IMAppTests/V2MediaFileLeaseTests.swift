import Foundation
import CryptoKit
import IMV2ClientKit
import IMV2Core
import Testing
import UniformTypeIdentifiers
@testable import IMApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct V2MediaFileLeaseTests {
    @Test("avatar decoders own the actual borrowed path and account close waits for that decoder")
    func avatarDecoderLeaseOutlivesAdapterClose() async throws {
        let fixture = try await MediaFileLeaseFixture()
        defer { fixture.remove() }
        let payload = Data(repeating: 1, count: 4)
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
        let access = try V2ResourceAvatarAccess(mediaID: .init(uuid: UUID()), variantID: .init(uuid: UUID()), version: 1, checksum: checksum,
            plan: .init(mode: .httpGet, url: #require(URL(string: "https://media.invalid/1")), expiresAt: Date().addingTimeInterval(120), expectedByteCount: 4, checksum: checksum))
        let home = V2ResourceHome.account(.init(uuid: UUID()))
        let use = try await fixture.files.avatar(access, home: home)
        var finished = false
        let closing = Task { try await fixture.files.close(); finished = true }
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
            do { let attempt = try await fixture.files.avatar(access, home: home); await attempt.release() }
            catch is CancellationError { break }
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
        }
        #expect(!finished)
        #expect(try Data(contentsOf: use.fileURL) == payload)
        await use.release()
        try await closing.value
        #expect(finished)
    }

    @Test("independent consumers survive expiry and each token releases at most once")
    func expiryAndIndependentLeases() async throws {
        let fixture = try await MediaFileLeaseFixture()
        defer { fixture.remove() }
        let downloaded = try await fixture.files.download(fixture.media)
        let first = try await downloaded.borrowFile(), second = try await downloaded.borrowFile()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: downloaded.fileURL.path)
        try await fixture.files.performMaintenance(now: Date().addingTimeInterval(3_600))
        #expect(fixture.exists(downloaded))
        await first.release(); await first.release()
        try await fixture.files.performMaintenance(now: Date().addingTimeInterval(3_600))
        #expect(fixture.exists(downloaded))
        await second.release()
        try await fixture.files.performMaintenance(now: Date().addingTimeInterval(3_600))
        #expect(!fixture.exists(downloaded))
        await #expect(throws: V2MediaFileAccessError.unavailable) { try await downloaded.borrowFile() }
        try await fixture.files.close()
    }

    @Test("redownload publishes immutable bytes and withdrawal defers deletion until the final use")
    func replacementAndDiscard() async throws {
        let fixture = try await MediaFileLeaseFixture()
        defer { fixture.remove() }
        let old = try await fixture.files.download(fixture.media), oldLease = try await old.borrowFile()
        let fresh = try await fixture.files.download(fixture.media), freshLease = try await fresh.borrowFile()
        #expect(old.fileURL != fresh.fileURL)
        #expect(try Data(contentsOf: oldLease.fileURL) == Data(repeating: 1, count: 4))
        #expect(try Data(contentsOf: freshLease.fileURL) == Data(repeating: 2, count: 4))
        await #expect(throws: V2MediaFileAccessError.unavailable) { try await old.borrowFile() }
        await fixture.files.discard(fixture.media)
        #expect(fixture.exists(old) && fixture.exists(fresh))
        await #expect(throws: V2MediaFileAccessError.unavailable) { try await fresh.borrowFile() }
        await oldLease.release()
        #expect(!fixture.exists(old) && fixture.exists(fresh))
        await freshLease.release()
        #expect(!fixture.exists(fresh))
        try await fixture.files.close()
    }

    @Test("close stops borrowing, waits for actual consumers and leaves another account intact")
    func closeDrainsConsumers() async throws {
        let fixture = try await MediaFileLeaseFixture()
        defer { fixture.remove() }
        let downloaded = try await fixture.files.download(fixture.media)
        let first = try await downloaded.borrowFile(), second = try await downloaded.borrowFile()
        let other = fixture.root.appending(path: "other-account")
        try Data([7]).write(to: other)
        var finished = 0
        let closing = Task { try await fixture.files.close(); finished += 1 }
        let alsoClosing = Task { try await fixture.files.close(); finished += 1 }
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
            do { let attempt = try await downloaded.borrowFile(); await attempt.release() }
            catch V2MediaFileAccessError.unavailable { break }
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
        }
        #expect(finished == 0 && fixture.exists(downloaded))
        await first.release()
        #expect(finished == 0 && fixture.exists(downloaded))
        await second.release()
        try await closing.value
        try await alsoClosing.value
        #expect(finished == 2 && fixture.exists(downloaded))
        #expect(try Data(contentsOf: other) == Data([7]))
        try await fixture.files.close()
    }

    @Test("an abandoned presentation releases its lease even if no controller was created")
    func abandonedPresentation() async throws {
        let fixture = try await MediaFileLeaseFixture()
        defer { fixture.remove() }
        let downloaded = try await fixture.files.download(fixture.media)
        var lease: V2ConversationMediaFileLease? = try await downloaded.borrowFile()
        #expect(lease?.fileURL == downloaded.fileURL)
        await fixture.files.discard(fixture.media)
        #expect(fixture.exists(downloaded))
        lease = nil
        try await fixture.files.close()
        #expect(!fixture.exists(downloaded))
    }

    @Test("untrusted paths, cancelled borrows and missing files cannot create file uses")
    func invalidBorrow() async throws {
        let fixture = try await MediaFileLeaseFixture()
        defer { fixture.remove() }
        let downloaded = try await fixture.files.download(fixture.media)
        let naked = V2DownloadedConversationMedia(mediaID: fixture.media.mediaID, fileURL: downloaded.fileURL)
        await #expect(throws: V2MediaFileAccessError.unavailable) { try await naked.borrowFile() }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await downloaded.borrowFile()
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let outside = fixture.root.appending(path: "external")
        try Data([9]).write(to: outside)
        try FileManager.default.removeItem(at: downloaded.fileURL)
        await #expect(throws: V2MediaFileAccessError.unavailable) { try await downloaded.borrowFile() }
        try FileManager.default.createSymbolicLink(at: downloaded.fileURL, withDestinationURL: outside)
        await #expect(throws: V2MediaFileAccessError.unavailable) { try await downloaded.borrowFile() }
        try await fixture.files.close()
        #expect(try Data(contentsOf: outside) == Data([9]))
    }

    @Test("file use admission is bounded independently of the byte budget")
    func leaseAdmission() async throws {
        let fixture = try await MediaFileLeaseFixture()
        defer { fixture.remove() }
        let downloaded = try await fixture.files.download(fixture.media)
        var leases: [V2ConversationMediaFileLease] = []
        for _ in 0..<64 { leases.append(try await downloaded.borrowFile()) }
        await #expect(throws: V2MediaFileAccessError.overloaded) { try await downloaded.borrowFile() }
        for lease in leases { await lease.release() }
        try await fixture.files.close()
    }

    @Test("maintenance preserves an active partial and withdrawal fences a noncooperative download")
    func maintenanceAndLateDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "im-file-use-late-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = FileUseTransferGate()
        let files = try await makeResourceMediaTestDownloader(downloader: .init(targetResolver: FileUseResolver(initialValue: 3), byteTransfer: gate), directory: root)
        let media = V2MediaReference(mediaID: try .init("late-media"))
        let loading = Task { try await files.download(media) }
        let partial = try await gate.waitForEntry()
        try await files.performMaintenance()
        #expect(try Data(contentsOf: partial) == Data(repeating: 3, count: 4))
        await files.discard(media)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await loading.value }
        try await files.performMaintenance(now: Date().addingTimeInterval(8 * 86_400))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "cache-scope/resources/files").path).isEmpty)
        try await files.close()
    }

    @Test("the system share coordinator retains bytes and exported names until completion", arguments: ["会话录音.wav", "notes version 2.wav", nil] as [String?])
    func shareCompletion(name: String?) async throws {
        let fixture = try await MediaFileLeaseFixture()
        defer { fixture.remove() }
        let downloaded = try await fixture.files.download(fixture.media), original = try await downloaded.borrowFile()
        let displayName = try name.map { try V2ResourceDisplayName($0) }
        let lease = try await V2LocalMediaShareSheet.prepareLease(original, kind: .audio, contentType: "audio/wav", displayName: displayName)
        let coordinator = V2LocalMediaShareSheet.Coordinator(lease: lease)
        #expect(lease.fileURL.lastPathComponent == (name ?? "音频.wav"))
        #expect(lease.fileURL != downloaded.fileURL)
        let directory = lease.fileURL.deletingLastPathComponent()
        #expect(UUID(uuidString: directory.lastPathComponent) != nil)
        #expect(directory.deletingLastPathComponent().lastPathComponent == "exports")
        let originalFacts = try FileManager.default.attributesOfItem(atPath: downloaded.fileURL.path)
        let exportFacts = try FileManager.default.attributesOfItem(atPath: lease.fileURL.path)
        #expect(originalFacts[.systemFileNumber] as? NSNumber == exportFacts[.systemFileNumber] as? NSNumber)
        await fixture.files.discard(fixture.media)
        #expect(fixture.exists(downloaded))
        #expect(try Data(contentsOf: lease.fileURL) == Data(repeating: 1, count: 4))
        coordinator.finish(); coordinator.finish()
        try await fixture.files.close()
        #expect(!fixture.exists(downloaded))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

@MainActor private struct MediaFileLeaseFixture {
    let root: URL
    let files: V2ResourceMediaTestOwner
    let transfer = FileUseTransfer()
    let media = V2MediaReference(mediaID: .init(uuid: UUID()))
    init(maximumBytes: Int64 = 1_048_576) async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "im-file-use-\(UUID())")
        files = try await makeResourceMediaTestDownloader(downloader: .init(targetResolver: FileUseResolver(), byteTransfer: transfer),
            directory: root.appending(path: "cache"), cachePolicy: .init(maximumByteCount: maximumBytes, maximumEntryCount: 8, maximumAge: 60))
    }
    func exists(_ file: V2DownloadedConversationMedia) -> Bool { FileManager.default.fileExists(atPath: file.fileURL.path) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
private actor FileUseResolver: V2ClientMediaDownloadTargetResolver {
    private var next: UInt8
    init(initialValue: UInt8 = 1) { next = initialValue }
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) throws -> V2ClientMediaTransferTarget {
        let value = next; next += 1
        let data = Data(repeating: value, count: 4)
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        return try .init(downloadPlan: .init(mode: .httpGet, url: URL(string: "https://media.invalid/\(value)")!,
            expiresAt: .distantFuture, expectedByteCount: 4, checksum: checksum))
    }
}
private actor FileUseTransfer: V2ClientMediaByteTransfer {
    private(set) var calls = 0
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) throws {
        calls += 1
        let value = try #require(UInt8(target.url.lastPathComponent))
        try Data(repeating: value, count: 4).write(to: destinationURL)
    }
}
private actor FileUseTransferGate: V2ClientMediaByteTransfer {
    private var entered: URL?
    private var continuation: CheckedContinuation<Void, Never>?
    func upload(fileURL: URL, target: V2ClientMediaTransferTarget) throws { throw CancellationError() }
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) async throws {
        try Data(repeating: 3, count: 4).write(to: destinationURL)
        entered = destinationURL
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForEntry() async throws -> URL {
        let deadline = ContinuousClock.now + .seconds(3)
        while entered == nil {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(1))
        }
        return entered!
    }
    func release() { continuation?.resume(); continuation = nil }
}
