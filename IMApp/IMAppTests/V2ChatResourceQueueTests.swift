import CryptoKit
import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit
@testable import IMApp

@MainActor
@Suite("Chat reads persist resource demand before authorization", .timeLimit(.minutes(1)))
struct V2ChatResourceQueueTests {
    @Test(arguments: [true, false]) func canceledAuthorizationSurvivesColdAccountAndRecoversOriginalDownload(knownMetadata: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "chat-read-queue-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = ChatReadResolver(), bytes = ChatReadBytes()
        let network = V2ClientMediaDownloadService(targetResolver: resolver, byteTransfer: bytes)
        let first = try await makeResourceMediaTestDownloader(downloader: network, directory: root)
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let location = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        if knownMetadata { try await index(media, message: location, store: first.store) }
        let page = Task { try await first.download(media, message: location) }
        await resolver.entered()
        let queued = try #require(try await first.store.managedResourceTransfers(.init()).entries.first)
        #expect(queued.phase == (knownMetadata ? .queued : .resolvingMetadata) && queued.mediaID == media.mediaID)
        #expect(await bytes.calls == 0)
        page.cancel()
        await #expect(throws: CancellationError.self) { try await page.value }
        #expect(try await first.store.managedResourceTransfers(.init()).entries.first?.id == queued.id)
        try await first.close()
        await resolver.allow()
        let restored = try await makeResourceMediaTestDownloader(downloader: network, directory: root)
        #expect(try await restored.store.managedResourceTransfers(.init()).entries.first?.phase == (knownMetadata ? .queued : .resolvingMetadata))
        let recovery = Task { try await restored.downloader.runRecovery() }
        let deadline = ContinuousClock.now + .seconds(10)
        while try await restored.store.managedResourceTransfers(.init()).entries.first?.phase != .completed {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        let completed = try #require(try await restored.store.managedResourceTransfers(.init()).entries.first)
        #expect(completed.id == queued.id && completed.createdAt == queued.createdAt && completed.confirmedBytes == 4)
        let cached = try await restored.download(media, message: location), lease = try await cached.borrowFile()
        #expect(try Data(contentsOf: lease.fileURL) == ChatReadBytes.payload)
        await lease.release()
        #expect(await bytes.calls == 1)
        #expect(try await restored.store.managedResourceTransfers(.init()).entries.map(\.id) == [queued.id])
        recovery.cancel(); _ = await recovery.result
        try await restored.close()
    }

    @Test func pausedChatDemandCannotRestartThroughAnotherOpenFileAction() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "chat-read-pause-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = ChatReadResolver(), bytes = ChatReadBytes()
        let owner = try await makeResourceMediaTestDownloader(downloader: .init(targetResolver: resolver, byteTransfer: bytes), directory: root)
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let location = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await index(media, message: location, store: owner.store)
        let page = Task { try await owner.download(media, message: location) }
        await resolver.entered(); page.cancel(); _ = await page.result
        let row = try #require(try await owner.store.managedResourceTransfers(.init()).entries.first)
        guard case .download(let job) = row.id else { Issue.record("Expected download"); return }
        let journal = await owner.store.resourceFileJournal()
        _ = try journal.requestForegroundDownloadControl(job, control: .pause, liveOwner: nil)
        await #expect(throws: V2ResourceDownloadControlError.paused) { try await owner.download(media, message: location) }
        #expect(await resolver.calls == 1)
        #expect(await bytes.calls == 0)
        #expect(try await owner.store.managedResourceTransfers(.init()).entries.first?.phase == .paused)
        try await owner.close()
    }

    private func index(_ media: V2MediaReference, message: V2MediaMessageLocation, store: GRDBV2LocalSyncStore) async throws {
        let descriptor = try V2ResourceDescriptor(key: .init(home: .room(message.roomID), mediaID: media.mediaID), revision: 1,
            displayName: .init("聊天文件.bin"), contentType: "application/octet-stream", byteCount: 4, checksum: ChatReadBytes.checksum, state: .ready)
        try await store.indexResource(descriptor, reference: .message(message, ordinal: 0), businessRevision: 1)
    }
}

private actor ChatReadResolver: V2ClientMediaDownloadTargetResolver {
    private var held = true
    private let starts = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private(set) var calls = 0
    func entered() async { for await _ in starts.stream { return } }
    func allow() { held = false }
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) async throws -> V2ClientMediaTransferTarget {
        calls += 1
        if held {
            let wait = AsyncStream<Void>.makeStream()
            starts.continuation.yield(())
            for await _ in wait.stream { }
            throw CancellationError()
        }
        return try .init(downloadPlan: .init(mode: .httpGet, url: #require(URL(string: "https://bytes.invalid/chat")),
            expiresAt: .distantFuture, expectedByteCount: 4, checksum: ChatReadBytes.checksum))
    }
}

private actor ChatReadBytes: V2ClientMediaByteTransfer {
    static let payload = Data([1,2,3,4])
    static var checksum: V2ResourceChecksum { get throws { try .init(value: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()) } }
    private(set) var calls = 0
    func upload(fileURL: URL, target: V2ClientMediaTransferTarget) throws { throw CancellationError() }
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) throws {
        calls += 1; try Self.payload.write(to: destinationURL)
    }
}
