import Foundation
import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2MediaDownloadLifecycleTests {
    @Test("account close drains a late download and removes only its cache", arguments: [false, true])
    func closeDownload(cancelCaller: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "im-media-lifecycle-\(UUID())")
        let directory = root.appending(path: "account-a/media-cache")
        let other = root.appending(path: "account-b/media-cache")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let retained = other.appending(path: "keep.media")
        try Data([7]).write(to: retained)
        let entered = AsyncStream<Void>.makeStream()
        let cancelled = AsyncStream<Void>.makeStream()
        let transfer = LateMediaTransfer(entered: entered.continuation, cancelled: cancelled.continuation)
        let resolver = LifecycleMediaResolver()
        let downloader = try V2ForegroundConversationMediaDownloader(
            downloader: .init(targetResolver: resolver, byteTransfer: transfer), directory: directory
        )
        let reference = V2MediaReference(mediaID: try .init("lifecycle-media"))
        let request = Task { try await downloader.download(reference) }
        var starts = entered.stream.makeAsyncIterator()
        _ = await starts.next()
        if cancelCaller { request.cancel() }
        let close = Task { try await downloader.close() }
        var cancellations = cancelled.stream.makeAsyncIterator()
        _ = await cancellations.next()
        // Cancellation can reach the transfer before close() gets the actor.
        // Releasing it still must not allow publication under either ordering.
        await transfer.release()
        try await close.value
        await #expect(throws: CancellationError.self) { try await request.value }
        await #expect(throws: CancellationError.self) { try await downloader.download(reference) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try Data(contentsOf: retained) == Data([7]))
        #expect(await resolver.count == 1)
        try await downloader.close()
        entered.continuation.finish()
        cancelled.continuation.finish()
    }
}

private actor LifecycleMediaResolver: V2ClientMediaDownloadTargetResolver {
    private(set) var count = 0
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) throws -> V2ClientMediaTransferTarget {
        count += 1
        return try .init(downloadPlan: .init(mode: .httpGet, url: URL(string: "https://media.invalid/object")!, expiresAt: .distantFuture, expectedByteCount: 1, checksum: .init(value: "4bf5122f344554c53bde2ebb8cd2b7e3d1600ad631c385a5d7cce23c7785459a")))
    }
}

private actor LateMediaTransfer: V2ClientMediaByteTransfer {
    let entered: AsyncStream<Void>.Continuation
    let cancelled: AsyncStream<Void>.Continuation
    private var continuation: CheckedContinuation<Void, Never>?
    init(entered: AsyncStream<Void>.Continuation, cancelled: AsyncStream<Void>.Continuation) {
        self.entered = entered
        self.cancelled = cancelled
    }
    func upload(fileURL: URL, target: V2ClientMediaTransferTarget) throws { throw CancellationError() }
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                continuation = $0
                entered.yield(())
            }
        } onCancel: { cancelled.yield(()) }
        // Simulate a byte-transfer completion that does not honor cancellation.
        try Data([1]).write(to: destinationURL)
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
