import Foundation
import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2AttachmentUploadLifecycleTests {
    @Test("account upload close drains file readers before staging cleanup", arguments: [false, true])
    func closeUpload(cancelCaller: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "im-upload-close-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.txt")
        try Data([1]).write(to: source)
        let stager = try V2FileConversationAttachmentStager(directory: root.appending(path: "staging"))
        let attachment = try await stager.stageImportedFile(at: source)
        let entered = AsyncStream<Void>.makeStream()
        let cancelled = AsyncStream<Void>.makeStream()
        let transport = LateAttachmentUpload(entered: entered.continuation, cancelled: cancelled.continuation)
        let uploader = V2ForegroundConversationAttachmentUploader(uploader: .init(targetResolver: transport, byteTransfer: transport, completer: transport, statusReader: transport))
        let request = Task { try await uploader.upload(attachment) }
        var starts = entered.stream.makeAsyncIterator()
        _ = await starts.next()
        if cancelCaller { request.cancel() }
        let close = Task {
            await uploader.close()
            try await stager.close()
        }
        var cancellations = cancelled.stream.makeAsyncIterator()
        _ = await cancellations.next()
        #expect(FileManager.default.fileExists(atPath: attachment.fileURL.path))
        await transport.release()
        try await close.value
        await #expect(throws: CancellationError.self) { try await request.value }
        await #expect(throws: CancellationError.self) { try await uploader.upload(attachment) }
        #expect(await transport.calls == ["resolve", "transfer"])
        #expect(!FileManager.default.fileExists(atPath: attachment.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
        await uploader.close()
        entered.continuation.finish()
        cancelled.continuation.finish()
    }
}

private actor LateAttachmentUpload: V2ClientMediaUploadTargetResolver, V2ClientMediaByteTransfer, V2ClientMediaUploadCompleting, V2ClientMediaUploadStatusReading {
    let entered: AsyncStream<Void>.Continuation
    let cancelled: AsyncStream<Void>.Continuation
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls: [String] = []
    init(entered: AsyncStream<Void>.Continuation, cancelled: AsyncStream<Void>.Continuation) {
        self.entered = entered
        self.cancelled = cancelled
    }
    func resolveUploadTarget(operationID: MediaUploadOperationID, mediaID: MediaID, contentType: String, byteCount: Int64) throws -> V2ClientMediaTransferTarget {
        calls.append("resolve")
        return try .init(url: URL(string: "https://media.invalid/upload")!, expiresAt: .distantFuture, expectedByteCount: byteCount)
    }
    func upload(fileURL: URL, target: V2ClientMediaTransferTarget) async throws {
        calls.append("transfer")
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                continuation = $0
                entered.yield(())
            }
        } onCancel: { cancelled.yield(()) }
        // Model a transfer that keeps reading the file after cancellation.
        #expect(try Data(contentsOf: fileURL) == Data([1]))
    }
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) throws { throw CancellationError() }
    func completeUpload(mediaID: MediaID) { calls.append("complete") }
    func uploadStatus(mediaID: MediaID) -> V2MediaObjectState { calls.append("status"); return .available }
    func release() { continuation?.resume(); continuation = nil }
}
