import Foundation
import HTTPTypes
import IMV2Core
import IMV2Server
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 Vapor media upload routes")
struct V2VaporMediaUploadRoutesTests {
    @Test("authenticated upload target, completion, and status preserve the device boundary")
    func authenticatedUploadLifecycle() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let userID = try UserID("user")
        let deviceID = try DeviceID("device")
        let mediaID = try MediaID("media")
        let uploadSessionID = try MediaUploadSessionID("upload-session")
        let mediaStore = UploadRouteMediaStore(
            grant: .init(mediaID: mediaID, uploadSessionID: uploadSessionID, expiresAt: now.addingTimeInterval(60))
        )
        let sessionStore = UploadRouteSessionStore(
            claim: .init(
                mediaID: mediaID,
                uploadSessionID: uploadSessionID,
                contentType: "image/jpeg",
                byteCount: 5,
                expiresAt: now.addingTimeInterval(60),
                claimToken: UUID()
            )
        )
        let target = V2MediaProviderObjectTarget(
            url: try #require(URL(string: "https://provider.invalid/upload")),
            headers: ["content-type": "image/jpeg", "x-oss-meta-purpose": "chat"],
            expiresAt: now.addingTimeInterval(30),
            expectedByteCount: 5
        )
        let edge = try V2MediaEdgeUploadService(
            media: .init(store: mediaStore, limits: try .init(maximumBytes: 10), now: { now }),
            providerSessions: .init(store: sessionStore, provider: UploadRouteProvider(target: target), now: { now })
        )
        V2VaporMediaUploadRoutes(
            authenticator: UploadRouteAuthenticator(userID: userID),
            handler: .init(edge: edge)
        ).register(on: app)

        let headers: HTTPFields = [
            .authorization: "Bearer access-token",
            HTTPField.Name("X-IM-Device-ID")!: deviceID.rawValue,
        ]

        try await app.testing { client in
            let response = try await client.send(.post, headers: headers, to: "v2/media/uploads", beforeSend: { request in
            try request.content.encode(V2MediaUploadTargetHTTPRequest(
                operationID: "operation",
                mediaID: mediaID.rawValue,
                contentType: "image/jpeg",
                byteCount: 5
            ))
        })
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "no-store")
            #expect(response.headers[.pragma] == "no-cache")
            var envelope: V2MediaUploadTargetEnvelope?
            envelope = try await response.content.decode(V2MediaUploadTargetEnvelope.self)
            #expect(envelope?.url == "https://provider.invalid/upload")
            #expect(envelope?.expectedByteCount == 5)
        }
        try await app.testing { client in
            let response = try await client.send(.post, headers: headers, to: "v2/media/media/complete")
            #expect(response.status == .noContent)
            #expect(response.headers[.cacheControl] == "no-store")
        }
        try await app.testing { client in
            let response = try await client.send(.get, headers: headers, to: "v2/media/media/upload-status")
            #expect(response.status == .ok)
            var envelope: V2MediaUploadStatusEnvelope?
            envelope = try await response.content.decode(V2MediaUploadStatusEnvelope.self)
            #expect(envelope?.state == .available)
        }

        let request = try #require(await mediaStore.uploadRequest())
        #expect(request.command.actorUserID == userID)
        #expect(request.deviceID == deviceID)
        let completions = await mediaStore.completions()
        #expect(completions.count == 1)
        #expect(completions.first?.ownerUserID == userID)
        #expect(completions.first?.deviceID == deviceID)
        #expect(completions.first?.mediaID == mediaID)
        #expect(await sessionStore.claimedDeviceID() == deviceID)
    }

    @Test("authentication failure never reaches the upload store")
    func rejectsUnauthenticatedUpload() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let store = UploadRouteMediaStore(grant: nil)
        let edge = try V2MediaEdgeUploadService(
            media: .init(store: store, limits: try .init(maximumBytes: 10)),
            providerSessions: .init(store: UnusedUploadSessionStore(), provider: UnusedUploadProvider())
        )
        V2VaporMediaUploadRoutes(
            authenticator: UploadRouteAuthenticator(error: .unauthenticated),
            handler: .init(edge: edge)
        ).register(on: app)

        try await app.testing { client in
            let response = try await client.send(.post, headers: [
            .authorization: "Bearer invalid",
            HTTPField.Name("X-IM-Device-ID")!: "device",
        ], to: "v2/media/uploads", beforeSend: { request in
            try request.content.encode(V2MediaUploadTargetHTTPRequest(
                operationID: "operation",
                mediaID: "media",
                contentType: "image/jpeg",
                byteCount: 5
            ))
        })
            #expect(response.status == .unauthorized)
        }
        #expect(await store.uploadRequest() == nil)
    }
}

private actor UploadRouteMediaStore: V2MediaStore {
    struct UploadRequest: Sendable {
        let command: V2RequestMediaUploadCommand
        let deviceID: DeviceID
    }
    struct Completion: Sendable {
        let ownerUserID: UserID
        let deviceID: DeviceID
        let mediaID: MediaID
    }

    private let grant: V2MediaUploadGrant?
    private var receivedUpload: UploadRequest?
    private var receivedCompletions: [Completion] = []

    init(grant: V2MediaUploadGrant?) { self.grant = grant }

    func requestUpload(_ command: V2RequestMediaUploadCommand, deviceID: DeviceID, expiresAt _: Date, now _: Date) throws -> V2MediaUploadGrant {
        receivedUpload = .init(command: command, deviceID: deviceID)
        guard let grant else { throw V2MediaStoreError.uploadNotAuthorized }
        return grant
    }
    func requestDownload(requesterUserID _: UserID, deviceID _: DeviceID, mediaID _: MediaID, expiresAt _: Date, now _: Date) -> V2MediaDownloadGrant { fatalError("unused") }
    func markUploadCompleted(ownerUserID: UserID, deviceID: DeviceID, mediaID: MediaID, now _: Date) {
        receivedCompletions.append(.init(ownerUserID: ownerUserID, deviceID: deviceID, mediaID: mediaID))
    }
    func uploadStatus(ownerUserID _: UserID, deviceID _: DeviceID, mediaID _: MediaID, now _: Date) -> V2MediaObjectState { .available }
    func recordScanResult(mediaID _: MediaID, passed _: Bool, now _: Date) {}
    func assertAvailableForReference(ownerUserID _: UserID, mediaIDs _: [MediaID], now _: Date) {}
    func uploadRequest() -> UploadRequest? { receivedUpload }
    func completions() -> [Completion] { receivedCompletions }
}

private actor UploadRouteSessionStore: V2MediaUploadSessionStore {
    private let claim: V2ClaimedMediaUpload
    private var deviceID: DeviceID?
    init(claim: V2ClaimedMediaUpload) { self.claim = claim }
    func claimUpload(ownerUserID _: UserID, deviceID: DeviceID, uploadSessionID _: MediaUploadSessionID, now _: Date, leaseDuration _: TimeInterval) -> V2ClaimedMediaUpload {
        self.deviceID = deviceID
        return claim
    }
    func completeUploadTarget(_: V2ClaimedMediaUpload, now _: Date) {}
    func releaseUploadTarget(_: V2ClaimedMediaUpload) {}
    func claimedDeviceID() -> DeviceID? { deviceID }
}

private struct UploadRouteProvider: V2MediaUploadObjectProvider {
    let target: V2MediaProviderObjectTarget
    func issueUploadTarget(mediaID _: MediaID, contentType _: String, byteCount _: Int64, expiresAt _: Date) -> V2MediaProviderObjectTarget { target }
}

private struct UploadRouteAuthenticator: V2GatewayAuthenticator {
    let userID: UserID?
    let error: V2GatewayAuthenticationError?
    init(userID: UserID) { self.userID = userID; error = nil }
    init(error: V2GatewayAuthenticationError) { userID = nil; self.error = error }
    func authenticateSession(accessToken _: String, deviceID _: DeviceID) throws -> V2GatewayAuthentication {
        if let error { throw error }
        return .init(userID: try #require(userID), expiresAt: nil)
    }
}

private actor UnusedUploadSessionStore: V2MediaUploadSessionStore {
    func claimUpload(ownerUserID _: UserID, deviceID _: DeviceID, uploadSessionID _: MediaUploadSessionID, now _: Date, leaseDuration _: TimeInterval) -> V2ClaimedMediaUpload { fatalError("unused") }
    func completeUploadTarget(_: V2ClaimedMediaUpload, now _: Date) {}
    func releaseUploadTarget(_: V2ClaimedMediaUpload) {}
}

private struct UnusedUploadProvider: V2MediaUploadObjectProvider {
    func issueUploadTarget(mediaID _: MediaID, contentType _: String, byteCount _: Int64, expiresAt _: Date) -> V2MediaProviderObjectTarget { fatalError("unused") }
}
