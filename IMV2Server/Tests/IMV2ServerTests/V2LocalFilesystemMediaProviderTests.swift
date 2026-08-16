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

    @Test("startup removes crash-stale upload fragments without touching committed or active files")
    func startupRecoversStagingDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "im-v2-media-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let baseURL = try #require(URL(string: "https://media.local.test"))
        let signingKey = Data(repeating: 11, count: 32)
        let firstProcess = try V2LocalFilesystemMediaProvider(
            rootDirectory: root,
            targetBaseURL: baseURL,
            signingKey: signingKey,
            now: { now }
        )
        try await firstProcess.prepare()

        let committedID = try MediaID(UUID().uuidString)
        let committedBytes = Data("committed".utf8)
        let committedTarget = try await firstProcess.issueUploadTarget(
            mediaID: committedID,
            contentType: "application/octet-stream",
            byteCount: Int64(committedBytes.count),
            expiresAt: now.addingTimeInterval(30)
        )
        try await firstProcess.storeUploadedObject(
            mediaID: committedID,
            targetURL: committedTarget.url,
            contentType: "application/octet-stream",
            bytes: committedBytes
        )

        let abandonedID = try MediaID(UUID().uuidString)
        let abandonedTarget = try await firstProcess.issueUploadTarget(
            mediaID: abandonedID,
            contentType: "application/octet-stream",
            byteCount: 3,
            expiresAt: now.addingTimeInterval(30)
        )
        let abandoned = try await firstProcess.beginUploadedObject(
            mediaID: abandonedID,
            targetURL: abandonedTarget.url,
            contentType: "application/octet-stream",
            declaredByteCount: 3
        )
        try Data([1, 2, 3]).write(to: abandoned.fileURL, options: .withoutOverwriting)
        #expect(FileManager.default.fileExists(atPath: abandoned.fileURL.path))

        let restartedProcess = try V2LocalFilesystemMediaProvider(
            rootDirectory: root,
            targetBaseURL: baseURL,
            signingKey: signingKey,
            now: { now }
        )
        try await restartedProcess.prepare()
        #expect(!FileManager.default.fileExists(atPath: abandoned.fileURL.path))
        let download = try await restartedProcess.issueDownloadTarget(
            mediaID: committedID,
            expiresAt: now.addingTimeInterval(30)
        )
        #expect(try await restartedProcess.readDownloadedObject(
            mediaID: committedID,
            targetURL: download.url
        ) == committedBytes)

        let activeID = try MediaID(UUID().uuidString)
        let activeTarget = try await restartedProcess.issueUploadTarget(
            mediaID: activeID,
            contentType: "application/octet-stream",
            byteCount: 1,
            expiresAt: now.addingTimeInterval(30)
        )
        let active = try await restartedProcess.beginUploadedObject(
            mediaID: activeID,
            targetURL: activeTarget.url,
            contentType: "application/octet-stream",
            declaredByteCount: 1
        )
        try Data([4]).write(to: active.fileURL, options: .withoutOverwriting)
        try await restartedProcess.prepare()
        #expect(FileManager.default.fileExists(atPath: active.fileURL.path))
        await restartedProcess.discardUploadedObject(active)
    }
}
