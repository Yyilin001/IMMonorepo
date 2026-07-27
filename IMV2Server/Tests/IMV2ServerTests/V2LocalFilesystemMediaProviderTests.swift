import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 local filesystem media provider")
struct V2LocalFilesystemMediaProviderTests {
    @Test("a signed local target stores, scans, downloads and purges opaque media bytes")
    func localMediaLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("im-v2-media-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let provider = try V2LocalFilesystemMediaProvider(
            rootDirectory: root,
            targetBaseURL: try #require(URL(string: "https://media.local.test")),
            signingKey: Data(repeating: 7, count: 32),
            now: { now }
        )
        try await provider.prepare()
        let mediaID = try MediaID(UUID().uuidString)
        let payload = Data("local media".utf8)
        let upload = try await provider.issueUploadTarget(
            mediaID: mediaID,
            contentType: "text/plain",
            byteCount: Int64(payload.count),
            expiresAt: now.addingTimeInterval(30)
        )
        #expect(upload.url.scheme == "https")
        #expect(upload.headers == ["Content-Type": "text/plain"])
        try await provider.storeUploadedObject(
            mediaID: mediaID,
            targetURL: upload.url,
            contentType: "text/plain",
            bytes: payload
        )
        #expect(try await V2LocalEICARMediaScanner(provider: provider).scan(mediaID: mediaID) == .passed)

        let download = try await provider.issueDownloadTarget(mediaID: mediaID, expiresAt: now.addingTimeInterval(30))
        #expect(download.expectedByteCount == Int64(payload.count))
        #expect(try await provider.readDownloadedObject(mediaID: mediaID, targetURL: download.url) == payload)

        try await provider.purge(mediaID: mediaID)
        await #expect(throws: V2LocalFilesystemMediaProviderError.objectUnavailable) {
            try await provider.readDownloadedObject(mediaID: mediaID, targetURL: download.url)
        }
    }

    @Test("the local scanner rejects the harmless EICAR fixture and signed targets enforce exact bytes")
    func eicarAndExactBytesAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("im-v2-media-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let provider = try V2LocalFilesystemMediaProvider(
            rootDirectory: root,
            targetBaseURL: try #require(URL(string: "https://media.local.test")),
            signingKey: Data(repeating: 9, count: 32),
            now: { now }
        )
        let mediaID = try MediaID(UUID().uuidString)
        let eicar = Data("X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*".utf8)
        let upload = try await provider.issueUploadTarget(
            mediaID: mediaID,
            contentType: "application/octet-stream",
            byteCount: Int64(eicar.count),
            expiresAt: now.addingTimeInterval(30)
        )
        await #expect(throws: V2LocalFilesystemMediaProviderError.byteCountMismatch) {
            try await provider.storeUploadedObject(
                mediaID: mediaID,
                targetURL: upload.url,
                contentType: "application/octet-stream",
                bytes: Data()
            )
        }
        try await provider.storeUploadedObject(
            mediaID: mediaID,
            targetURL: upload.url,
            contentType: "application/octet-stream",
            bytes: eicar
        )
        #expect(try await V2LocalEICARMediaScanner(provider: provider).scan(mediaID: mediaID) == .failed)
    }
}
