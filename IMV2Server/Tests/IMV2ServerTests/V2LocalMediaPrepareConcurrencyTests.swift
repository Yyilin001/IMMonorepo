import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

struct V2LocalMediaPrepareConcurrencyTests {
    @Test
    func concurrentPreparationPreservesNewUploads() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "im-media-prepare-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let provider = try V2LocalFilesystemMediaProvider(rootDirectory: root,
            targetBaseURL: #require(URL(string: "https://media.test")), signingKey: Data(repeating: 1, count: 32), now: { now })
        // All callers share the actor, but its filesystem preparation suspends.
        let uploads = try await withThrowingTaskGroup(of: (MediaID, V2LocalFilesystemStagedUpload).self) { group in
            for _ in 0..<32 {
                group.addTask {
                    try await provider.prepare()
                    let id = MediaID(uuid: UUID())
                    let target = try await provider.issueUploadTarget(mediaID: id, contentType: "text/plain", byteCount: 1, expiresAt: now.addingTimeInterval(60))
                    let upload = try await provider.beginUploadedObject(mediaID: id, targetURL: target.url, contentType: "text/plain", declaredByteCount: 1)
                    try Data([42]).write(to: upload.fileURL, options: .withoutOverwriting)
                    return (id, upload)
                }
            }
            var uploads: [(MediaID, V2LocalFilesystemStagedUpload)] = []
            for try await upload in group { uploads.append(upload) }
            return uploads
        }
        #expect(uploads.count == 32)
        for (_, upload) in uploads {
            #expect(try Data(contentsOf: upload.fileURL) == Data([42]))
            try await provider.commitUploadedObject(upload, actualByteCount: 1)
        }
        try await provider.prepare()
        for (id, _) in uploads {
            let download = try await provider.issueDownloadTarget(mediaID: id, expiresAt: now.addingTimeInterval(60))
            #expect(try await provider.readDownloadedObject(mediaID: id, targetURL: download.url) == Data([42]))
        }
    }

    @Test
    func failedPreparationCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "im-media-prepare-failure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root, options: .withoutOverwriting)
        let provider = try V2LocalFilesystemMediaProvider(rootDirectory: root,
            targetBaseURL: #require(URL(string: "https://media.test")), signingKey: Data(repeating: 1, count: 32))
        await #expect(throws: (any Error).self) { try await provider.prepare() }
        try FileManager.default.removeItem(at: root)
        try await provider.prepare()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: ".upload-staging").path).isEmpty)
    }
}
