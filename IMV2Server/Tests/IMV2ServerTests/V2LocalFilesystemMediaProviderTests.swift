@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
import Synchronization
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 local filesystem media provider")
struct V2LocalFilesystemMediaProviderTests {
    @Test func nativeDownloadGrantPreservesExactSignedObjectAndChecksum() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), expiry = now.addingTimeInterval(30)
        let provider = try V2LocalFilesystemMediaProvider(rootDirectory: root,
            targetBaseURL: #require(URL(string: "https://media.local.test")),
            signingKey: Data(repeating: 13, count: 32), now: { now })
        let media = MediaID(uuid: UUID()), bytes = Data([1, 2, 3])
        let upload = try await provider.issueUploadTarget(mediaID: media, contentType: "application/octet-stream",
            byteCount: 3, expiresAt: expiry)
        try await provider.storeUploadedObject(mediaID: media, targetURL: upload.url,
            contentType: "application/octet-stream", bytes: bytes)
        let download = try await provider.issueDownloadTarget(mediaID: media, expiresAt: expiry)
        let grant = try #require(download.backgroundDownloadAuthorization)
        #expect(grant.checksum == download.checksum && grant.expectedByteCount == 3)
        #expect(grant.expiresAtMilliseconds == download.expiresAtUnixMilliseconds)
        #expect(try await provider.readDownloadedObject(mediaID: media, targetURL: download.url) == bytes)
        await #expect(throws: V2LocalFilesystemMediaProviderError.invalidTarget) {
            _ = try await provider.readDownloadedObject(mediaID: MediaID(uuid: UUID()), targetURL: download.url)
        }
    }
    @Test("Media deadline rounding cannot make expired or submillisecond targets usable",
          arguments: [Double(-1.0005), -1_000_000_000.1255, 1_750_000_000.1255])
    func signedDeadlineRounding(seconds: Double) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("im-v2-media-rounding-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: seconds)
        let provider = try V2LocalFilesystemMediaProvider(rootDirectory: root,
            targetBaseURL: #require(URL(string: "https://media.local.test")),
            signingKey: Data(repeating: 13, count: 32), now: { now })
        let media = MediaID(uuid: UUID())
        for remaining in [-0.0001, 0, 0.0001] {
            let expiry = now.addingTimeInterval(remaining)
            await #expect(throws: V2LocalFilesystemMediaProviderError.invalidTarget) {
                _ = try await provider.issueUploadTarget(mediaID: media, contentType: "text/plain", byteCount: 1, expiresAt: expiry)
            }
            // Invalid deadlines must be rejected before metadata lookup,
            // even though this fixture deliberately has no stored object.
            await #expect(throws: V2LocalFilesystemMediaProviderError.invalidTarget) {
                _ = try await provider.issueDownloadTarget(mediaID: media, expiresAt: expiry)
            }
        }
        let expiry = now.addingTimeInterval(0.5)
        let valid = try await provider.issueUploadTarget(mediaID: media, contentType: "text/plain", byteCount: 1, expiresAt: expiry)
        #expect(valid.expiresAt == expiry)
        await #expect(throws: V2LocalFilesystemMediaProviderError.objectUnavailable) {
            _ = try await provider.issueDownloadTarget(mediaID: media, expiresAt: expiry)
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Invalid media deadlines and clock samples fail without altering an existing object")
    func nonFiniteAndOverflowingClock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("im-v2-media-clock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_750_000_000.125)
        let clock = MediaTargetTestClock(now)
        let provider = try V2LocalFilesystemMediaProvider(rootDirectory: root,
            targetBaseURL: #require(URL(string: "https://media.local.test")),
            signingKey: Data(repeating: 13, count: 32), now: { clock.read() })
        let media = MediaID(uuid: UUID()), expiry = now.addingTimeInterval(30)
        let upload = try await provider.issueUploadTarget(mediaID: media, contentType: "text/plain", byteCount: 1, expiresAt: expiry)
        try await provider.storeUploadedObject(mediaID: media, targetURL: upload.url, contentType: "text/plain", bytes: Data([42]))
        let download = try await provider.issueDownloadTarget(mediaID: media, expiresAt: expiry)
        for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, Double(Int64.max) / 1_000] {
            let invalid = Date(timeIntervalSince1970: seconds)
            await #expect(throws: V2LocalFilesystemMediaProviderError.invalidTarget) {
                try await provider.issueUploadTarget(mediaID: media, contentType: "text/plain", byteCount: 1, expiresAt: invalid)
            }
            await #expect(throws: V2LocalFilesystemMediaProviderError.invalidTarget) {
                try await provider.issueDownloadTarget(mediaID: media, expiresAt: invalid)
            }
            clock.set([invalid])
            await #expect(throws: V2LocalFilesystemMediaProviderError.invalidTarget) {
                try await provider.issueUploadTarget(mediaID: media, contentType: "text/plain", byteCount: 1, expiresAt: expiry)
            }
            await #expect(throws: V2LocalFilesystemMediaProviderError.invalidTarget) {
                try await provider.issueDownloadTarget(mediaID: media, expiresAt: expiry)
            }
            await #expect(throws: V2LocalFilesystemMediaProviderError.invalidTarget) {
                try await provider.readDownloadedObject(mediaID: media, targetURL: download.url)
            }
            clock.set([now])
        }
        #expect(try await provider.readDownloadedObject(mediaID: media, targetURL: download.url) == Data([42]))
        clock.set([expiry])
        await #expect(throws: V2LocalFilesystemMediaProviderError.invalidTarget) {
            try await provider.readDownloadedObject(mediaID: media, targetURL: download.url)
        }
    }

    @Test("Media targets reject an elapsed encoded deadline and recheck after metadata lookup")
    func targetDeadlineBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("im-v2-media-clock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let clock = MediaTargetTestClock(now)
        let provider = try V2LocalFilesystemMediaProvider(rootDirectory: root,
            targetBaseURL: #require(URL(string: "https://media.local.test")),
            signingKey: Data(repeating: 13, count: 32), now: { clock.read() })
        let media = MediaID(uuid: UUID())
        await #expect(throws: V2LocalFilesystemMediaProviderError.invalidTarget) {
            try await provider.issueUploadTarget(mediaID: media, contentType: "text/plain", byteCount: 1,
                expiresAt: now.addingTimeInterval(0.0001))
        }
        let upload = try await provider.issueUploadTarget(mediaID: media, contentType: "text/plain",
            byteCount: 1, expiresAt: now.addingTimeInterval(30))
        try await provider.storeUploadedObject(mediaID: media, targetURL: upload.url,
            contentType: "text/plain", bytes: Data([42]))
        // First sample is before the awaited metadata lookup; the second is
        // when the target is signed. No file-system scheduling race is needed.
        clock.set([now, now.addingTimeInterval(60)])
        await #expect(throws: V2LocalFilesystemMediaProviderError.invalidTarget) {
            try await provider.issueDownloadTarget(mediaID: media, expiresAt: now.addingTimeInterval(30))
        }
        clock.set([now])
        let download = try await provider.issueDownloadTarget(mediaID: media, expiresAt: now.addingTimeInterval(30))
        #expect(try await provider.readDownloadedObject(mediaID: media, targetURL: download.url) == Data([42]))
    }

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

private final class MediaTargetTestClock: Sendable {
    private let samples: Mutex<[Date]>
    init(_ date: Date) { samples = Mutex([date]) }
    func set(_ dates: [Date]) { samples.withLock { $0 = dates } }
    func read() -> Date {
        samples.withLock { values in
            if values.count > 1 { return values.removeFirst() }
            return values[0]
        }
    }
}
