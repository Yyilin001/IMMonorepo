import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 media service")
struct V2MediaServiceTests {
    @Test("an authenticated upload intent receives an opaque short-lived grant")
    func requestsUpload() async throws {
        let store = RecordingMediaStore()
        let service = V2MediaService(store: store, limits: try .init(maximumBytes: 100, temporaryLifetime: 60), now: { Date(timeIntervalSince1970: 100) })
        let grant = try await service.requestUpload(actorUserID: .init("user"), deviceID: .init("device"), operationID: .init("operation"), mediaID: .init("media"), contentType: "image/png", byteCount: 10)
        #expect(grant == .init(mediaID: try .init("media"), uploadSessionID: try .init("session"), expiresAt: Date(timeIntervalSince1970: 160)))
        #expect(await store.uploadRequestCount() == 1)
    }

    @Test("scan result and later message reference remain separate authority boundaries")
    func separatesScanAndReference() async throws {
        let store = RecordingMediaStore()
        let service = V2MediaService(store: store, limits: try .init(maximumBytes: 100))
        try await service.uploadCompleted(actorUserID: .init("user"), deviceID: .init("device"), mediaID: .init("media"))
        try await service.scannerCompleted(mediaID: .init("media"), passed: true)
        try await service.assertAvailableForReference(ownerUserID: .init("user"), media: [.init(mediaID: try .init("media"))])
        #expect(await store.events() == ["uploaded", "scanned:true", "referenced"])
    }

    @Test("an authenticated download receives only a short-lived opaque grant")
    func requestsDownload() async throws {
        let store = RecordingMediaStore()
        let service = V2MediaService(
            store: store,
            limits: try .init(maximumBytes: 100),
            downloadLimits: try .init(grantLifetime: 30),
            now: { Date(timeIntervalSince1970: 100) }
        )
        let grant = try await service.requestDownload(
            actorUserID: .init("user"),
            deviceID: .init("device"),
            mediaID: .init("media")
        )
        #expect(grant == .init(mediaID: try .init("media"), downloadSessionID: try .init("download-session"), expiresAt: Date(timeIntervalSince1970: 130)))
        #expect(await store.events() == ["downloaded"])
    }
}

private actor RecordingMediaStore: V2MediaStore {
    private var eventLog: [String] = []
    func requestUpload(_ command: V2RequestMediaUploadCommand, deviceID _: DeviceID, expiresAt: Date, now _: Date) -> V2MediaUploadGrant {
        eventLog.append("requested")
        return try! .init(mediaID: command.mediaID, uploadSessionID: .init("session"), expiresAt: expiresAt)
    }
    func requestDownload(requesterUserID _: UserID, deviceID _: DeviceID, mediaID: MediaID, expiresAt: Date, now _: Date) -> V2MediaDownloadGrant {
        eventLog.append("downloaded")
        return try! .init(mediaID: mediaID, downloadSessionID: .init("download-session"), expiresAt: expiresAt)
    }
    func markUploadCompleted(ownerUserID _: UserID, deviceID _: DeviceID, mediaID _: MediaID, now _: Date) { eventLog.append("uploaded") }
    func uploadStatus(ownerUserID _: UserID, deviceID _: DeviceID, mediaID _: MediaID, now _: Date) -> V2MediaObjectState { .available }
    func recordScanResult(mediaID _: MediaID, passed: Bool, now _: Date) { eventLog.append("scanned:\(passed)") }
    func assertAvailableForReference(ownerUserID _: UserID, mediaIDs _: [MediaID], now _: Date) { eventLog.append("referenced") }
    func uploadRequestCount() -> Int { eventLog.filter { $0 == "requested" }.count }
    func events() -> [String] { eventLog }
}
