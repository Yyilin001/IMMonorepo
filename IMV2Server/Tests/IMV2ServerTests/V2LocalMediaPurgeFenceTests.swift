import Crypto
import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

struct V2LocalMediaPurgeFenceTests {
    @Test(arguments: [false, true])
    func purgeFencesStagedAndConcurrentCommits(forward: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "im-purge-fence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        func provider() throws -> V2LocalFilesystemMediaProvider {
            try .init(rootDirectory: root, targetBaseURL: #require(URL(string: "https://media.test")),
                      signingKey: Data(repeating: 1, count: 32), now: { now })
        }
        let writer = try provider(), remover = try provider()
        try await writer.prepare()
        let bytes = Data("staged before removal".utf8)
        let receipt = try V2ForwardMediaCopyReceipt(byteCount: Int64(bytes.count), digest: Data(SHA256.hash(data: bytes)))
        func stage(_ id: MediaID) async throws -> V2LocalFilesystemStagedUpload {
            let target = try await writer.issueUploadTarget(mediaID: id, contentType: "text/plain",
                byteCount: Int64(bytes.count), expiresAt: now.addingTimeInterval(60))
            let upload = try await writer.beginUploadedObject(mediaID: id, targetURL: target.url,
                contentType: "text/plain", declaredByteCount: Int64(bytes.count))
            try bytes.write(to: upload.fileURL, options: .withoutOverwriting)
            return upload
        }
        @Sendable func commit(_ upload: V2LocalFilesystemStagedUpload) async throws {
            if forward { try await writer.commitForwardImportedObject(upload, receipt: receipt) }
            else { try await writer.commitUploadedObject(upload, actualByteCount: Int64(bytes.count)) }
        }
        let removed = MediaID(uuid: UUID())
        let staged = try await stage(removed)
        try await remover.purge(mediaID: removed)
        await #expect(throws: V2LocalFilesystemMediaProviderError.objectUnavailable) { try await commit(staged) }
        await writer.discardUploadedObject(staged)
        for _ in 0..<8 {
            let id = MediaID(uuid: UUID()), upload = try await stage(id)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    do { try await commit(upload) }
                    catch V2LocalFilesystemMediaProviderError.objectUnavailable { }
                }
                group.addTask { try await remover.purge(mediaID: id) }
                try await group.waitForAll()
            }
            await writer.discardUploadedObject(upload)
            await #expect(throws: V2LocalFilesystemMediaProviderError.objectUnavailable) {
                _ = try await writer.issueDownloadTarget(mediaID: id, expiresAt: now.addingTimeInterval(60))
            }
            try await remover.purge(mediaID: id)
        }
        let restarted = try provider()
        try await restarted.prepare()
        let target = try await restarted.issueUploadTarget(mediaID: removed, contentType: "text/plain",
            byteCount: Int64(bytes.count), expiresAt: now.addingTimeInterval(60))
        await #expect(throws: V2LocalFilesystemMediaProviderError.objectUnavailable) {
            try await restarted.storeUploadedObject(mediaID: removed, targetURL: target.url, contentType: "text/plain", bytes: bytes)
        }
    }

    @Test func durableMarkerHidesObjectLeftBeforeUnlink() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "im-purge-marker-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let provider = try V2LocalFilesystemMediaProvider(rootDirectory: root,
            targetBaseURL: #require(URL(string: "https://media.test")), signingKey: Data(repeating: 1, count: 32), now: { now })
        let id = MediaID(uuid: UUID()), bytes = Data([1, 2, 3])
        let upload = try await provider.issueUploadTarget(mediaID: id, contentType: "text/plain", byteCount: 3, expiresAt: now.addingTimeInterval(60))
        try await provider.storeUploadedObject(mediaID: id, targetURL: upload.url, contentType: "text/plain", bytes: bytes)
        let download = try await provider.issueDownloadTarget(mediaID: id, expiresAt: now.addingTimeInterval(60))
        let object = try await provider.downloadedObject(mediaID: id, targetURL: download.url)
        try await provider.purge(mediaID: id)
        // Reconstruct the disk state after durable marker but before unlink.
        try bytes.write(to: object.fileURL, options: .withoutOverwriting)
        await #expect(throws: V2LocalFilesystemMediaProviderError.objectUnavailable) {
            _ = try await provider.readDownloadedObject(mediaID: id, targetURL: download.url)
        }
        await #expect(throws: V2LocalFilesystemMediaProviderError.objectUnavailable) {
            _ = try await provider.localBytesForScanning(mediaID: id)
        }
        await #expect(throws: V2LocalFilesystemMediaProviderError.objectUnavailable) {
            _ = try await provider.verifyForwardImportedObject(mediaID: id, byteCount: 3, digest: Data(SHA256.hash(data: bytes)))
        }
        try await provider.purge(mediaID: id)
        #expect(!FileManager.default.fileExists(atPath: object.fileURL.path))
    }
}
