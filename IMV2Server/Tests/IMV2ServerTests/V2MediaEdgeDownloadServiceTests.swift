import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 authenticated media edge")
struct V2MediaEdgeDownloadServiceTests {
    @Test("edge keeps the opaque grant internal and returns only the bounded provider target")
    func issuesTargetForAuthenticatedDevice() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let mediaID = try MediaID("media")
        let sessionID = try MediaDownloadSessionID("session")
        let store = EdgeMediaStore(downloadGrant: .init(mediaID: mediaID, downloadSessionID: sessionID, expiresAt: now.addingTimeInterval(30)))
        let sessionStore = EdgeSessionStore(claim: .init(mediaID: mediaID, downloadSessionID: sessionID, expiresAt: now.addingTimeInterval(30), claimToken: UUID()))
        let target = V2MediaProviderObjectTarget(url: try #require(URL(string: "https://media.invalid/object")), expiresAt: now.addingTimeInterval(20))
        let edge = try V2MediaEdgeDownloadService(
            media: .init(store: store, limits: try .init(maximumBytes: 10), downloadLimits: try .init(grantLifetime: 30), now: { now }),
            providerSessions: .init(store: sessionStore, provider: EdgeProvider(target: target), now: { now })
        )

        #expect(try await edge.downloadTarget(actorUserID: .init("user"), deviceID: .init("device"), mediaID: mediaID) == target)
        #expect(await store.requestedMedia() == [mediaID])
        #expect(await sessionStore.completedSessions() == [sessionID])
    }

    @Test("HTTP handler validates the path ID and returns only the short-lived target envelope")
    func handlerBuildsEphemeralEnvelope() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let mediaID = try MediaID("media")
        let sessionID = try MediaDownloadSessionID("session")
        let store = EdgeMediaStore(downloadGrant: .init(mediaID: mediaID, downloadSessionID: sessionID, expiresAt: now.addingTimeInterval(30)))
        let sessionStore = EdgeSessionStore(claim: .init(mediaID: mediaID, downloadSessionID: sessionID, expiresAt: now.addingTimeInterval(30), claimToken: UUID()))
        let target = V2MediaProviderObjectTarget(
            url: try #require(URL(string: "https://media.invalid/object")),
            headers: ["x-oss-meta-provider": "opaque"],
            expiresAt: now.addingTimeInterval(20),
            expectedByteCount: 42
        )
        let edge = try V2MediaEdgeDownloadService(
            media: .init(store: store, limits: try .init(maximumBytes: 10), downloadLimits: try .init(grantLifetime: 30), now: { now }),
            providerSessions: .init(store: sessionStore, provider: EdgeProvider(target: target), now: { now })
        )
        let handler = V2MediaEdgeHTTPHandler(edge: edge)

        let response = try await handler.downloadTarget(actorUserID: .init("user"), deviceID: .init("device"), rawMediaID: "media")

        #expect(response.url == "https://media.invalid/object")
        #expect(response.headers == ["x-oss-meta-provider": "opaque"])
        #expect(response.expectedByteCount == 42)
        #expect(response.expiresAtUnixMilliseconds == 1_750_000_020_000)
        await #expect(throws: V2MediaEdgeHTTPHandlerError.invalidMediaID) {
            _ = try await handler.downloadTarget(actorUserID: .init("user"), deviceID: .init("device"), rawMediaID: " ")
        }
    }
}

private actor EdgeMediaStore: V2MediaStore {
    private let downloadGrant: V2MediaDownloadGrant
    private var downloads: [MediaID] = []
    init(downloadGrant: V2MediaDownloadGrant) { self.downloadGrant = downloadGrant }
    func requestUpload(_: V2RequestMediaUploadCommand, deviceID _: DeviceID, expiresAt _: Date, now _: Date) -> V2MediaUploadGrant { fatalError("not used") }
    func requestDownload(requesterUserID _: UserID, deviceID _: DeviceID, mediaID: MediaID, expiresAt _: Date, now _: Date) -> V2MediaDownloadGrant { downloads.append(mediaID); return downloadGrant }
    func markUploadCompleted(ownerUserID _: UserID, deviceID _: DeviceID, mediaID _: MediaID, now _: Date) {}
    func uploadStatus(ownerUserID _: UserID, deviceID _: DeviceID, mediaID _: MediaID, now _: Date) -> V2MediaObjectState { .available }
    func recordScanResult(mediaID _: MediaID, passed _: Bool, now _: Date) {}
    func assertAvailableForReference(ownerUserID _: UserID, mediaIDs _: [MediaID], now _: Date) {}
    func requestedMedia() -> [MediaID] { downloads }
}

private actor EdgeSessionStore: V2MediaDownloadSessionStore {
    private let claim: V2ClaimedMediaDownload
    private var completed: [MediaDownloadSessionID] = []
    init(claim: V2ClaimedMediaDownload) { self.claim = claim }
    func claimDownload(requesterUserID _: UserID, deviceID _: DeviceID, downloadSessionID _: MediaDownloadSessionID, now _: Date, leaseDuration _: TimeInterval) -> V2ClaimedMediaDownload { claim }
    func completeDownload(_ claim: V2ClaimedMediaDownload, now _: Date) { completed.append(claim.downloadSessionID) }
    func releaseDownload(_: V2ClaimedMediaDownload) {}
    func completedSessions() -> [MediaDownloadSessionID] { completed }
}

private struct EdgeProvider: V2MediaObjectProvider {
    let target: V2MediaProviderObjectTarget
    func issueDownloadTarget(mediaID _: MediaID, expiresAt _: Date) -> V2MediaProviderObjectTarget { target }
}
