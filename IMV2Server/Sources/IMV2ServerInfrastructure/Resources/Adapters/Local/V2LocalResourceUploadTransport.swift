import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core

/// Local transport enforces request size at the existing controlled HTTP byte ingress.
/// Its immutable no-overwrite object is a stable source for retrying a finalize copy.
public struct V2LocalResourceUploadTransport: V2UploadTransport {
    public let binding: V2StorageBinding
    public let capabilities = V2ResourceTransportCapabilities(modes: [.httpPartPut, .httpPut], maximumBytes: 256 * 1_024 * 1_024)
    let provider: V2LocalFilesystemMediaProvider
    public init(binding: V2StorageBinding, provider: V2LocalFilesystemMediaProvider) {
        self.binding = binding; self.provider = provider
    }
    public func plan(mode: V2ResourceTransferMode, mediaID: MediaID, contentType: String, byteCount: Int64, checksum: V2ResourceChecksum, expiresAt: Date) async throws -> V2ResourceTransferPlan {
        guard mode == .httpPut, byteCount <= capabilities.maximumBytes else { throw V2ResourceProviderError.unsupportedCapability }
        let target = try await provider.issueUploadTarget(mediaID: mediaID, contentType: contentType, byteCount: byteCount, expiresAt: expiresAt)
        return try .init(mode: .httpPut, url: target.url,
                         headers: target.headers.map { try .init(name: $0.key, value: $0.value) },
                         expiresAt: expiresAt, expectedByteCount: byteCount, checksum: checksum)
    }
    public func completedBytes(mediaID: MediaID, byteCount: Int64) async throws -> V2ResourceByteStream {
        let target = try await provider.issueDownloadTarget(mediaID: mediaID, expiresAt: Date().addingTimeInterval(60))
        let object = try await provider.downloadedObject(mediaID: mediaID, targetURL: target.url)
        guard object.byteCount == byteCount else { throw V2ResourceProviderError.integrityMismatch }
        return try await V2LocalResourceStorage.stream(file: object.fileURL)
    }
    public func importBytes(mediaID: MediaID, contentType: String, byteCount: Int64, bytes: V2ResourceByteStream) async throws {
        let target = try await provider.issueUploadTarget(mediaID: mediaID,contentType: contentType,byteCount: byteCount,expiresAt: Date().addingTimeInterval(300))
        let upload = try await provider.beginUploadedObject(mediaID: mediaID,targetURL: target.url,contentType: contentType,declaredByteCount: byteCount)
        do {
            let output = try await Task.detached(priority: .utility) {
                try Data().write(to: upload.fileURL, options: .withoutOverwriting)
                return try FileHandle(forWritingTo: upload.fileURL)
            }.value
            defer { try? output.close() }
            var count:Int64=0
            while let chunk = try await bytes.next() {
                guard Int64(chunk.count)<=byteCount-count else { throw V2ResourceProviderError.integrityMismatch }
                count += Int64(chunk.count)
                try await Task.detached(priority:.utility) { try output.write(contentsOf:chunk) }.value
            }
            guard count==byteCount else { throw V2ResourceProviderError.integrityMismatch }
            try await Task.detached(priority:.utility) { try output.synchronize() }.value
            try await provider.commitUploadedObject(upload,actualByteCount:count)
        } catch { await provider.discardUploadedObject(upload);throw error }
    }
    public func abort(mediaID: MediaID) async throws { try await provider.purge(mediaID: mediaID) }
}
