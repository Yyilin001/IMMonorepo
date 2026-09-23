import HTTPTypes
import IMV2Core
import IMV2Server
@testable import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 profile update routes")
struct V2VaporProfileUpdateRoutesTests {
    @Test("profile writes require credentials, retain the revision fence, and return no-store")
    func updatesProfile() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let actor = try UserID("00000000-0000-0000-0000-000000000811")
        let view = try updateFixtureProfile(userID: actor, revision: 2)
        let profiles = ProfileUpdateRouteStore(result: .updated(view))
        V2VaporProfileUpdateRoutes(
            authenticator: ProfileUpdateRouteAuthenticator(userID: actor),
            profiles: .init(store: profiles, reader: profiles)
        ).register(on: app)

        try await app.testing { client in
            let response = try await client.send(.put, to: "v2/profile/me", beforeSend: { request in
            request.headers.bearerAuthorization = .init(token: "access-token")
            request.headers[HTTPField.Name("X-IM-Device-ID")!] = "00000000-0000-0000-0000-000000000812"
            try request.content.encode(V2ProfileUpdateHTTPRequest(
                operationID: "00000000-0000-0000-0000-000000000813",
                expectedRevision: 1,
                displayName: "更新后名称",
                avatarMediaID: nil
            ))
        })
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "no-store")
            let body = try await response.content.decode(V2ProfileUpdateHTTPResponse.self)
            #expect(body.displayName == "资料名称")
            #expect(body.revision == 2)
            #expect(body.idempotent == false)
        }
    }

    @Test("revision conflict returns the current revision without leaking a profile")
    func reportsConflict() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let actor = try UserID("00000000-0000-0000-0000-000000000821")
        let currentRevision = try #require(V2ProfileRevision(rawValue: 9))
        let profiles = ProfileUpdateRouteStore(result: nil, error: .revisionConflict(current: currentRevision))
        V2VaporProfileUpdateRoutes(
            authenticator: ProfileUpdateRouteAuthenticator(userID: actor),
            profiles: .init(store: profiles, reader: profiles)
        ).register(on: app)

        try await app.testing { client in
            let response = try await client.send(.put, to: "v2/profile/me", beforeSend: { request in
            request.headers.bearerAuthorization = .init(token: "access-token")
            request.headers[HTTPField.Name("X-IM-Device-ID")!] = "00000000-0000-0000-0000-000000000822"
            try request.content.encode(V2ProfileUpdateHTTPRequest(
                operationID: "00000000-0000-0000-0000-000000000823",
                expectedRevision: 1,
                displayName: "冲突名称",
                avatarMediaID: nil
            ))
        })
            #expect(response.status == .conflict)
            let body = try await response.content.decode(V2ProfileUpdateHTTPResponse.self)
            #expect(body.currentRevision == 9)
            #expect(body.displayName == nil)
        }
    }
}

private struct ProfileUpdateRouteAuthenticator: V2GatewayAuthenticator {
    let userID: UserID
    func authenticateSession(accessToken: String, deviceID _: DeviceID) async throws -> V2GatewayAuthentication {
        guard accessToken == "access-token" else { throw ProfileUpdateRouteTestError.denied }
        return .init(userID: userID, expiresAt: nil)
    }
}

private actor ProfileUpdateRouteStore: V2ProfileUpdateStore, V2OwnProfileReading {
    let result: V2ProfileUpdateOutcome?
    let error: V2ProfileUpdateError?
    init(result: V2ProfileUpdateOutcome?, error: V2ProfileUpdateError? = nil) {
        self.result = result
        self.error = error
    }
    func update(_: V2ProfileUpdateCommand) async throws -> V2ProfileUpdateOutcome {
        if let error { throw error }
        return try #require(result)
    }

    func currentProfile(for _: UserID) async throws -> V2ProfileView {
        switch try #require(result) {
        case .updated(let profile), .idempotent(let profile):
            return profile
        }
    }
}

private func updateFixtureProfile(userID: UserID, revision: UInt64) throws -> V2ProfileView {
    try .init(
        userID: userID,
        publicIdentity: .init(userID: userID, handle: .init("profile_user"), displayName: "资料名称", accountKind: .regular),
        avatar: nil,
        state: .active,
        revision: try #require(V2ProfileRevision(rawValue: revision)),
        visibilityRevision: try #require(V2ProfileRevision(rawValue: revision))
    )
}

private enum ProfileUpdateRouteTestError: Error { case denied }
