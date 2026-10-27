@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import IMV2ServerHTTP
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 authenticated media edge")
struct V2MediaEdgeDownloadServiceTests {
    @Test func previewSelectionRequiresMessageScopeAndNeverFallsBackToOriginal() async throws {
        let media = MediaID(uuid: UUID()), room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID())
        let resolver = PreviewOnlyEdgeResolver()
        let handler = V2MediaEdgeHTTPHandler(resolver: resolver)
        let output = try await handler.downloadTarget(actorUserID: .init("actor"), deviceID: .init("device"),
            rawMediaID: media.rawValue, rawRoomID: room.rawValue, rawMessageID: message.rawValue, rawImageSize: "320")
        #expect(output.preview?.key.resource == .init(home: .room(room), mediaID: media))
        #expect(output.plan.expectedByteCount == 3)
        await #expect(throws: V2MediaEdgeHTTPHandlerError.invalidMessageLocation) {
            try await handler.downloadTarget(actorUserID: .init("actor"), deviceID: .init("device"), rawMediaID: media.rawValue, rawImageSize: "320")
        }
        await #expect(throws: V2MediaEdgeHTTPHandlerError.invalidMessageLocation) {
            try await handler.downloadTarget(actorUserID: .init("actor"), deviceID: .init("device"), rawMediaID: media.rawValue,
                rawRoomID: room.rawValue, rawMessageID: message.rawValue, rawImageSize: "999999")
        }
        #expect(await resolver.originalCalls == 0)
        #expect(await resolver.previewCalls == 1)
    }

    @Test("edge keeps the opaque grant internal and returns only the bounded provider target")
    func issuesTargetForAuthenticatedDevice() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let mediaID = try MediaID("media")
        let sessionID = try MediaDownloadSessionID("session")
        let store = EdgeMediaStore(downloadGrant: .init(mediaID: mediaID, downloadSessionID: sessionID, expiresAt: now.addingTimeInterval(30)))
        let sessionStore = EdgeSessionStore(claim: .init(mediaID: mediaID, downloadSessionID: sessionID, expiresAt: now.addingTimeInterval(30), claimToken: UUID()))
        let target = try resourceDownloadTestPlan(url: try #require(URL(string: "https://media.invalid/object")), expiresAt: now.addingTimeInterval(20))
        let edge = try V2MediaEdgeDownloadService(
            media: .init(store: store, downloadLimits: try .init(grantLifetime: 30), now: { now }),
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
        let target = try resourceDownloadTestPlan(
            url: try #require(URL(string: "https://media.invalid/object")),
            headers: ["x-oss-meta-provider": "opaque"],
            expiresAt: now.addingTimeInterval(20),
            expectedByteCount: 42
        )
        let edge = try V2MediaEdgeDownloadService(
            media: .init(store: store, downloadLimits: try .init(grantLifetime: 30), now: { now }),
            providerSessions: .init(store: sessionStore, provider: EdgeProvider(target: target), now: { now })
        )
        let handler = V2MediaEdgeHTTPHandler(edge: edge)

        let response = try await handler.downloadTarget(actorUserID: .init("user"), deviceID: .init("device"), rawMediaID: "media")

        #expect(response.plan.url.absoluteString == "https://media.invalid/object")
        #expect(response.plan.headers == [try .init(name: "x-oss-meta-provider", value: "opaque")])
        #expect(response.plan.expectedByteCount == 42)
        #expect(response.plan.expiresAtUnixMilliseconds == 1_750_000_020_000)
        await #expect(throws: V2MediaEdgeHTTPHandlerError.invalidMediaID) {
            _ = try await handler.downloadTarget(actorUserID: .init("user"), deviceID: .init("device"), rawMediaID: " ")
        }
    }
}

private actor EdgeMediaStore: V2MediaStore {
    private let downloadGrant: V2MediaDownloadGrant
    private var downloads: [MediaID] = []
    init(downloadGrant: V2MediaDownloadGrant) { self.downloadGrant = downloadGrant }
    func requestDownload(requesterUserID _: UserID, deviceID _: DeviceID, mediaID: MediaID, expiresAt _: Date, now _: Date) -> V2MediaDownloadGrant { downloads.append(mediaID); return downloadGrant }
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
    let target: V2ResourceTransferPlan
    func issueDownloadTarget(mediaID _: MediaID, expiresAt _: Date) -> V2ResourceTransferPlan { target }
}

private actor PreviewOnlyEdgeResolver: V2MediaDownloadTargetResolving {
    var originalCalls = 0
    var previewCalls = 0
    func downloadTarget(actorUserID: UserID, deviceID: DeviceID, mediaID: MediaID, message: V2MediaMessageLocation?) throws -> V2ResourceTransferPlan {
        originalCalls += 1; throw V2MediaStoreError.downloadNotAuthorized
    }
    func imagePreviewTarget(actorUserID: UserID, deviceID: DeviceID, mediaID: MediaID, message: V2MediaMessageLocation, size: V2MediaImagePreviewSize) throws -> V2MediaDownloadTargetEnvelope {
        previewCalls += 1
        let digest = try V2ResourceChecksum(value: String(repeating: "a", count: 64))
        let variant = try V2ResourceVariantDescriptor(key: .init(resource: .init(home: .room(message.roomID), mediaID: mediaID),
            rendition: .derived(id: .init(uuid: UUID()), version: .init(1))), checksum: digest, byteCount: 3)
        let plan = try V2ResourceTransferPlan(mode: .httpGet, url: URL(string: "https://objects.invalid/preview")!,
            expiresAt: .distantFuture, expectedByteCount: 3, checksum: digest)
        return try .init(plan: plan, preview: variant)
    }
}
