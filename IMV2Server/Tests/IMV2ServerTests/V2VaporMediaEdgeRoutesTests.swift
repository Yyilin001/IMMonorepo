import Foundation
import IMV2Core
import IMV2Server
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 Vapor media edge routes")
struct V2VaporMediaEdgeRoutesTests {
    @Test("route authenticates the device and emits an ephemeral no-store JSON target")
    func routeAuthenticatesAndReturnsTarget() async throws {
        try await withApp { app in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let mediaID = try MediaID("media")
            let sessionID = try MediaDownloadSessionID("session")
            let mediaStore = RouteMediaStore(grant: .init(mediaID: mediaID, downloadSessionID: sessionID, expiresAt: now.addingTimeInterval(30)))
            let sessionStore = RouteSessionStore(claim: .init(mediaID: mediaID, downloadSessionID: sessionID, expiresAt: now.addingTimeInterval(30), claimToken: UUID()))
            let target = V2MediaProviderObjectTarget(
                url: try #require(URL(string: "https://provider.invalid/object")),
                headers: ["x-oss-meta-provider": "opaque"],
                expiresAt: now.addingTimeInterval(20),
                expectedByteCount: 5
            )
            let edge = try V2MediaEdgeDownloadService(
                media: .init(store: mediaStore, limits: try .init(maximumBytes: 10), downloadLimits: try .init(grantLifetime: 30), now: { now }),
                providerSessions: .init(store: sessionStore, provider: RouteProvider(target: target), now: { now })
            )
            V2VaporMediaEdgeRoutes(
                authenticator: RouteAuthenticator(result: .success(try .init("user"))),
                handler: .init(edge: edge)
            ).register(on: app)

            let tester = try app.testing()
            try await tester.test(.GET, "v2/media/media", headers: [
                "Authorization": "Bearer access-token",
                "X-IM-Device-ID": "device",
            ]) { response async in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: .cacheControl) == "no-store")
                #expect(response.headers.first(name: "Pragma") == "no-cache")
                var envelope: V2MediaDownloadTargetEnvelope?
                expectContent(V2MediaDownloadTargetEnvelope.self, response) { envelope = $0 }
                guard let envelope else {
                    Issue.record("media edge did not return a decodable target envelope")
                    return
                }
                #expect(envelope.url == "https://provider.invalid/object")
                #expect(envelope.expectedByteCount == 5)
            }
            #expect(await mediaStore.requests() == [mediaID])
            #expect(await sessionStore.completions() == [sessionID])
        }
    }

    @Test("message location query is validated before owner resolution", arguments: ["valid", "room-only", "message-only", "malformed"])
    func validatesMessageQuery(scenario: String) async throws {
        try await withApp { app in
            let room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID())
            let resolver = ScopedRouteResolver()
            V2VaporMediaEdgeRoutes(
                authenticator: RouteAuthenticator(result: .success(try .init("user"))),
                handler: .init(resolver: resolver)
            ).register(on: app)
            let query: String
            switch scenario {
            case "room-only": query = "room_id=\(room.rawValue)"
            case "message-only": query = "message_id=\(message.rawValue)"
            case "malformed": query = "room_id=invalid&message_id=\(message.rawValue)"
            default: query = "room_id=\(room.rawValue.lowercased())&message_id=\(message.rawValue.lowercased())"
            }
            try await app.testing().test(.GET, "v2/media/media?\(query)", headers: [
                "Authorization": "Bearer access-token", "X-IM-Device-ID": "device",
            ]) { response async in
                #expect(response.status == (scenario == "valid" ? .ok : .badRequest))
            }
            #expect(await resolver.locations == (scenario == "valid" ? [.init(roomID: room, messageID: message)] : []))
        }
    }

    @Test("missing or invalid authentication is rejected before the media handler")
    func routeRejectsUnauthenticatedRequest() async throws {
        try await withApp { app in
            let edge = try V2MediaEdgeDownloadService(
                media: .init(store: UnusedMediaStore(), limits: try .init(maximumBytes: 10)),
                providerSessions: .init(store: UnusedSessionStore(), provider: UnusedProvider())
            )
            V2VaporMediaEdgeRoutes(
                authenticator: RouteAuthenticator(result: .failure(RouteAuthenticationFailure.unauthenticated)),
                handler: .init(edge: edge)
            ).register(on: app)

            let tester = try app.testing()
            try await tester.test(.GET, "v2/media/media") { response async in
                #expect(response.status == .unauthorized)
            }
            try await tester.test(.GET, "v2/media/media", headers: [
                "Authorization": "Bearer invalid",
                "X-IM-Device-ID": "device",
            ]) { response async in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test("authorization denial is an opaque not-found response")
    func routeDoesNotExposeMediaAuthorizationFailure() async throws {
        try await withApp { app in
            let edge = try V2MediaEdgeDownloadService(
                media: .init(store: DenyingMediaStore(), limits: try .init(maximumBytes: 10)),
                providerSessions: .init(store: UnusedSessionStore(), provider: UnusedProvider())
            )
            V2VaporMediaEdgeRoutes(
                authenticator: RouteAuthenticator(result: .success(try .init("user"))),
                handler: .init(edge: edge)
            ).register(on: app)

            let tester = try app.testing()
            try await tester.test(.GET, "v2/media/media", headers: [
                "Authorization": "Bearer access-token",
                "X-IM-Device-ID": "device",
            ]) { response async in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("provider issuance failures are a retryable unavailable response")
    func routeDoesNotExposeProviderFailure() async throws {
        try await withApp { app in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let mediaID = try MediaID("media")
            let sessionID = try MediaDownloadSessionID("session")
            let edge = try V2MediaEdgeDownloadService(
                media: .init(
                    store: RouteMediaStore(grant: .init(mediaID: mediaID, downloadSessionID: sessionID, expiresAt: now.addingTimeInterval(30))),
                    limits: try .init(maximumBytes: 10),
                    downloadLimits: try .init(grantLifetime: 30),
                    now: { now }
                ),
                providerSessions: .init(
                    store: RouteSessionStore(claim: .init(mediaID: mediaID, downloadSessionID: sessionID, expiresAt: now.addingTimeInterval(30), claimToken: UUID())),
                    provider: InsecureRouteProvider(),
                    now: { now }
                )
            )
            V2VaporMediaEdgeRoutes(
                authenticator: RouteAuthenticator(result: .success(try .init("user"))),
                handler: .init(edge: edge)
            ).register(on: app)

            let tester = try app.testing()
            try await tester.test(.GET, "v2/media/media", headers: [
                "Authorization": "Bearer access-token",
                "X-IM-Device-ID": "device",
            ]) { response async in
                #expect(response.status == .serviceUnavailable)
            }
        }
    }
}

private actor RouteMediaStore: V2MediaStore {
    private let grant: V2MediaDownloadGrant
    private var received: [MediaID] = []
    init(grant: V2MediaDownloadGrant) { self.grant = grant }
    func requestUpload(_: V2RequestMediaUploadCommand, deviceID _: DeviceID, expiresAt _: Date, now _: Date) -> V2MediaUploadGrant { fatalError("unused") }
    func requestDownload(requesterUserID _: UserID, deviceID _: DeviceID, mediaID: MediaID, expiresAt _: Date, now _: Date) -> V2MediaDownloadGrant { received.append(mediaID); return grant }
    func markUploadCompleted(ownerUserID _: UserID, deviceID _: DeviceID, mediaID _: MediaID, now _: Date) {}
    func uploadStatus(ownerUserID _: UserID, deviceID _: DeviceID, mediaID _: MediaID, now _: Date) -> V2MediaObjectState { .available }
    func recordScanResult(mediaID _: MediaID, passed _: Bool, now _: Date) {}
    func assertAvailableForReference(ownerUserID _: UserID, mediaIDs _: [MediaID], now _: Date) {}
    func requests() -> [MediaID] { received }
}

private actor RouteSessionStore: V2MediaDownloadSessionStore {
    private let claim: V2ClaimedMediaDownload
    private var completed: [MediaDownloadSessionID] = []
    init(claim: V2ClaimedMediaDownload) { self.claim = claim }
    func claimDownload(requesterUserID _: UserID, deviceID _: DeviceID, downloadSessionID _: MediaDownloadSessionID, now _: Date, leaseDuration _: TimeInterval) -> V2ClaimedMediaDownload { claim }
    func completeDownload(_ claim: V2ClaimedMediaDownload, now _: Date) { completed.append(claim.downloadSessionID) }
    func releaseDownload(_: V2ClaimedMediaDownload) {}
    func completions() -> [MediaDownloadSessionID] { completed }
}

private struct RouteProvider: V2MediaObjectProvider {
    let target: V2MediaProviderObjectTarget
    func issueDownloadTarget(mediaID _: MediaID, expiresAt _: Date) -> V2MediaProviderObjectTarget { target }
}

private struct InsecureRouteProvider: V2MediaObjectProvider {
    func issueDownloadTarget(mediaID _: MediaID, expiresAt: Date) -> V2MediaProviderObjectTarget {
        .init(url: URL(string: "http://provider.invalid/object")!, expiresAt: expiresAt)
    }
}

private struct RouteAuthenticator: V2GatewayAuthenticator {
    let result: Result<UserID, Error>
    func authenticateSession(accessToken _: String, deviceID _: DeviceID) throws -> V2GatewayAuthentication {
        .init(userID: try result.get(), expiresAt: nil)
    }
}

private typealias RouteAuthenticationFailure = V2GatewayAuthenticationError

private actor UnusedMediaStore: V2MediaStore {
    func requestUpload(_: V2RequestMediaUploadCommand, deviceID _: DeviceID, expiresAt _: Date, now _: Date) -> V2MediaUploadGrant { fatalError("unused") }
    func requestDownload(requesterUserID _: UserID, deviceID _: DeviceID, mediaID _: MediaID, expiresAt _: Date, now _: Date) -> V2MediaDownloadGrant { fatalError("unused") }
    func markUploadCompleted(ownerUserID _: UserID, deviceID _: DeviceID, mediaID _: MediaID, now _: Date) {}
    func uploadStatus(ownerUserID _: UserID, deviceID _: DeviceID, mediaID _: MediaID, now _: Date) -> V2MediaObjectState { .available }
    func recordScanResult(mediaID _: MediaID, passed _: Bool, now _: Date) {}
    func assertAvailableForReference(ownerUserID _: UserID, mediaIDs _: [MediaID], now _: Date) {}
}

private actor DenyingMediaStore: V2MediaStore {
    func requestUpload(_: V2RequestMediaUploadCommand, deviceID _: DeviceID, expiresAt _: Date, now _: Date) -> V2MediaUploadGrant { fatalError("unused") }
    func requestDownload(requesterUserID _: UserID, deviceID _: DeviceID, mediaID _: MediaID, expiresAt _: Date, now _: Date) throws -> V2MediaDownloadGrant { throw V2MediaStoreError.downloadNotAuthorized }
    func markUploadCompleted(ownerUserID _: UserID, deviceID _: DeviceID, mediaID _: MediaID, now _: Date) {}
    func uploadStatus(ownerUserID _: UserID, deviceID _: DeviceID, mediaID _: MediaID, now _: Date) -> V2MediaObjectState { .available }
    func recordScanResult(mediaID _: MediaID, passed _: Bool, now _: Date) {}
    func assertAvailableForReference(ownerUserID _: UserID, mediaIDs _: [MediaID], now _: Date) {}
}

private actor UnusedSessionStore: V2MediaDownloadSessionStore {
    func claimDownload(requesterUserID _: UserID, deviceID _: DeviceID, downloadSessionID _: MediaDownloadSessionID, now _: Date, leaseDuration _: TimeInterval) -> V2ClaimedMediaDownload { fatalError("unused") }
    func completeDownload(_: V2ClaimedMediaDownload, now _: Date) {}
    func releaseDownload(_: V2ClaimedMediaDownload) {}
}

private struct UnusedProvider: V2MediaObjectProvider {
    func issueDownloadTarget(mediaID _: MediaID, expiresAt _: Date) -> V2MediaProviderObjectTarget { fatalError("unused") }
}

private actor ScopedRouteResolver: V2MediaDownloadTargetResolving {
    private(set) var locations: [V2MediaMessageLocation] = []
    func downloadTarget(actorUserID: UserID, deviceID: DeviceID, mediaID: MediaID, message: V2MediaMessageLocation?) throws -> V2MediaProviderObjectTarget {
        guard let message else { throw V2MediaEdgeHTTPHandlerError.invalidMessageLocation }
        locations.append(message)
        return .init(url: URL(string: "https://provider.invalid/object")!, expiresAt: .now.addingTimeInterval(60))
    }
}
