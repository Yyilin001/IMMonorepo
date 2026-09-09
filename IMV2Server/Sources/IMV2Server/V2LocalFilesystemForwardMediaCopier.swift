import Crypto
import Foundation
import IMV2Core
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Local-development adapter. Provider-native copy/streaming and scanning
/// remain deployment adapters; no file path or signed URL enters persistence.
public struct V2LocalFilesystemForwardMediaCopier: V2ForwardMediaObjectCopying {
    private let sources: [String: V2LocalFilesystemMediaProvider]
    private let target: V2LocalFilesystemMediaProvider
    private let maximumBytes: Int64
    private let now: @Sendable () -> Date

    public init(sources: [String: V2LocalFilesystemMediaProvider], target: V2LocalFilesystemMediaProvider,
                maximumBytes: Int64 = 64 * 1_024 * 1_024, now: @escaping @Sendable () -> Date = Date.init) throws {
        guard !sources.isEmpty, maximumBytes > 0 else { throw V2ForwardMediaCopyError.invalidReceipt }
        self.sources = sources; self.target = target; self.maximumBytes = maximumBytes; self.now = now
    }

    public func copy(_ lease: V2ForwardMediaImportLease) async throws -> V2ForwardMediaCopyReceipt {
        let manifest = lease.source
        guard manifest.byteCount <= maximumBytes else { throw V2ForwardMediaCopyError.sizeLimitExceeded }
        guard lease.targetMediaID.uuidValue != manifest.mediaID else { throw V2ForwardMediaCopyError.contentConflict }
        try Task.checkCancellation()
        if let digest = lease.copiedDigest,
           try await target.verifyForwardImportedObject(mediaID: lease.targetMediaID, byteCount: manifest.byteCount, digest: digest) {
            // A copy acknowledged before the scanner crashed is independent
            // of subsequent source-provider availability.
            return try .init(byteCount: manifest.byteCount, digest: digest)
        }
        guard let source = sources[lease.export.intent.sourceShardID] else { throw V2ForwardMediaCopyError.sourceUnavailable }
        let sourceID = MediaID(uuid: manifest.mediaID)
        guard let expiry = v2PostgresFutureTimestamp(now: now(), interval: 600) else {
            throw V2ForwardMediaCopyError.invalidReceipt
        }
        // Export commit already authorized this independent copy. Do not
        // redeem a user's download grant, which rechecks mutable membership.
        let download = try await source.issueDownloadTarget(mediaID: sourceID, expiresAt: expiry)
        let object = try await source.downloadedObject(mediaID: sourceID, targetURL: download.url)
        guard object.byteCount == manifest.byteCount else { throw V2ForwardMediaCopyError.byteCountMismatch }
        let uploadTarget = try await target.issueUploadTarget(mediaID: lease.targetMediaID, contentType: manifest.contentType, byteCount: manifest.byteCount, expiresAt: expiry)
        let upload = try await target.beginUploadedObject(mediaID: lease.targetMediaID, targetURL: uploadTarget.url,
                                                        contentType: manifest.contentType, declaredByteCount: manifest.byteCount)
        do {
            // Own and drain the detached file-I/O task on every path; the
            // staging file is discarded only after its writer has stopped.
            let transfer = Task.detached(priority: .utility) {
                try ForwardMediaFileIO.copy(from: object.fileURL, to: upload.fileURL, byteCount: manifest.byteCount)
            }
            let receipt = try await withTaskCancellationHandler {
                try await transfer.value
            } onCancel: { transfer.cancel() }
            try Task.checkCancellation()
            if let expected = lease.copiedDigest, expected != receipt.digest { throw V2ForwardMediaCopyError.contentConflict }
            try await target.commitForwardImportedObject(upload, receipt: receipt)
            try Task.checkCancellation()
            await target.discardUploadedObject(upload)
            return receipt
        } catch {
            await target.discardUploadedObject(upload)
            throw error
        }
    }
}

/// Synchronous helpers used only on owned utility tasks. Memory is bounded to
/// one 64 KiB chunk; both the transferred stream and installed file are hashed.
enum ForwardMediaFileIO {
    static func copy(from source: URL, to target: URL, byteCount: Int64) throws -> V2ForwardMediaCopyReceipt {
        try Data().write(to: target, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        let digest = try read(input, byteCount: byteCount) { try output.write(contentsOf: $0) }
        try output.synchronize()
        return try .init(byteCount: byteCount, digest: digest)
    }

    static func digest(_ url: URL, byteCount: Int64) throws -> Data {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        return try read(input, byteCount: byteCount) { _ in }
    }

    private static func read(_ input: FileHandle, byteCount: Int64, consume: (Data) throws -> Void) throws -> Data {
        var remaining = byteCount
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty else { break }
            guard Int64(chunk.count) <= remaining else { throw V2ForwardMediaCopyError.byteCountMismatch }
            remaining -= Int64(chunk.count)
            hash.update(data: chunk)
            try consume(chunk)
        }
        guard remaining == 0 else { throw V2ForwardMediaCopyError.byteCountMismatch }
        return Data(hash.finalize())
    }

    static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}
