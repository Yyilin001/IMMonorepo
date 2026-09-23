import HTTPTypes
import Foundation
import IMV2Core
import IMV2Server
@testable import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 profile view routes")
struct V2VaporProfileViewRoutesTests {
    @Test("batch profile hydration is authenticated, no-store, and preserves unavailable results")
    func readsAuthorizedViews() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let profile = try fixtureProfile()
        V2VaporProfileViewRoutes(
            authenticator: ProfileRouteAuthenticator(userID: try .init("00000000-0000-0000-0000-000000000801")),
            profiles: .init(store: ProfileRouteStore(profile: profile))
        ).register(on: app)

        try await app.testing { client in
            let response = try await client.send(.post, to: "v2/profile-views/batch", beforeSend: { request in
            request.headers.bearerAuthorization = .init(token: "access-token")
            request.headers[HTTPField.Name("X-IM-Device-ID")!] = "00000000-0000-0000-0000-000000000803"
            try request.content.encode(V2ProfileViewBatchHTTPRequest(keys: [
                .init(userID: profile.userID.rawValue),
                .init(userID: "00000000-0000-0000-0000-000000000804", context: "room", roomID: "00000000-0000-0000-0000-000000000805"),
            ]))
        })
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "no-store")
            let body = try await response.content.decode(V2ProfileViewBatchHTTPResponse.self)
            #expect(body.results.count == 2)
            #expect(body.results[0].unavailable == false)
            #expect(body.results[0].context == "direct")
            #expect(body.results[0].displayName == "资料名称")
            #expect(body.results[0].accountKind == .regular)
            #expect(body.results[0].revision == 4)
            #expect(body.results[1].unavailable == true)
            #expect(body.results[1].context == "room")
            #expect(body.results[1].displayName == nil)
        }
    }

    @Test("relationship context is preserved without a room identifier")
    func preservesRelationshipContext() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let profile = try fixtureProfile()
        V2VaporProfileViewRoutes(
            authenticator: ProfileRouteAuthenticator(userID: try .init("00000000-0000-0000-0000-000000000801")),
            profiles: .init(store: ProfileRouteStore(profile: profile))
        ).register(on: app)

        try await app.testing { client in
            let response = try await client.send(.post, to: "v2/profile-views/batch", beforeSend: { request in
            request.headers.bearerAuthorization = .init(token: "access-token")
            request.headers[HTTPField.Name("X-IM-Device-ID")!] = "00000000-0000-0000-0000-000000000803"
            try request.content.encode(V2ProfileViewBatchHTTPRequest(keys: [
                .init(userID: profile.userID.rawValue, context: "relationship"),
            ]))
        })
            #expect(response.status == .ok)
            let body = try await response.content.decode(V2ProfileViewBatchHTTPResponse.self)
            #expect(body.results.first?.context == "relationship")
            #expect(body.results.first?.roomID == nil)
        }
    }
}

private struct ProfileRouteAuthenticator: V2GatewayAuthenticator {
    let userID: UserID
    func authenticateSession(accessToken: String, deviceID _: DeviceID) async throws -> V2GatewayAuthentication {
        guard accessToken == "access-token" else { throw ProfileRouteError.denied }
        return .init(userID: userID, expiresAt: nil)
    }
}

private actor ProfileRouteStore: V2ProfileViewStore {
    let profile: V2ProfileView
    init(profile: V2ProfileView) { self.profile = profile }

    func read(_ request: V2ProfileViewReadRequest) async throws -> [V2ProfileViewLookupResult] {
        request.keys.map { key in
            key.userID == profile.userID ? .profile(key: key, view: profile) : .unavailable(key: key)
        }
    }
}

private func fixtureProfile() throws -> V2ProfileView {
    let userID = try UserID("00000000-0000-0000-0000-000000000802")
    return try .init(
        userID: userID,
        publicIdentity: .init(userID: userID, handle: .init("profile_user"), displayName: "资料名称", accountKind: .regular),
        avatar: nil,
        state: .active,
        revision: try #require(V2ProfileRevision(rawValue: 4)),
        visibilityRevision: try #require(V2ProfileRevision(rawValue: 2))
    )
}

private enum ProfileRouteError: Error { case denied }
