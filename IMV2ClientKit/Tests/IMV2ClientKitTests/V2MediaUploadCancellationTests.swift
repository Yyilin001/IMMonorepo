import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

struct V2MediaUploadCancellationTests {
    @Test("upload cancellation stops at each asynchronous business boundary", arguments: [-1, 0, 1, 2, 3])
    func cancellationBoundary(stage: Int) async throws {
        let transport = CancellingUploadTransport(cancelAt: stage)
        let service = V2ClientMediaUploadService(targetResolver: transport, byteTransfer: transport, completer: transport, statusReader: transport)
        let request = Task {
            if stage == -1 { withUnsafeCurrentTask { $0?.cancel() } }
            try await service.upload(fileURL: URL(fileURLWithPath: "/unused-upload-fixture"), operationID: .init(UUID().uuidString), mediaID: .init("media"), contentType: "image/png", byteCount: 1)
        }
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await transport.calls == Array(["resolve", "transfer", "complete", "status"].prefix(stage + 1)))
    }
}

private actor CancellingUploadTransport: V2ClientMediaUploadTargetResolver, V2ClientMediaByteTransfer, V2ClientMediaUploadCompleting, V2ClientMediaUploadStatusReading {
    let cancelAt: Int
    private(set) var calls: [String] = []
    init(cancelAt: Int) { self.cancelAt = cancelAt }
    private func record(_ name: String) {
        let stage = calls.count
        calls.append(name)
        if stage == cancelAt { withUnsafeCurrentTask { $0?.cancel() } }
    }
    func resolveUploadTarget(operationID: MediaUploadOperationID, mediaID: MediaID, contentType: String, byteCount: Int64) throws -> V2ClientMediaTransferTarget {
        record("resolve")
        return try .init(url: URL(string: "https://media.invalid/upload")!, expiresAt: .distantFuture, expectedByteCount: 1)
    }
    func upload(fileURL: URL, target: V2ClientMediaTransferTarget) { record("transfer") }
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) throws { throw CancellationError() }
    func completeUpload(mediaID: MediaID) { record("complete") }
    func uploadStatus(mediaID: MediaID) -> V2MediaObjectState {
        record("status")
        return .available
    }
}
