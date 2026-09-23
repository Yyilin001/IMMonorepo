import HTTPTypes
import Foundation
import IMV2Core
import IMV2Server
@testable import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 public identity routes")
struct V2VaporPublicIdentityRoutesTests {
    @Test("exact handle lookup requires device credentials and returns no-store profile facts")
    func resolvesExactHandle() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        V2VaporPublicIdentityRoutes(
            authenticator: PublicIdentityRouteAuthenticator(userID: try .init("actor-user")),
            directory: PublicIdentityDirectoryFake(identity: try .init(userID: .init("target-user"), handle: .init("target_user"), displayName: "Target", accountKind: .regular))
        ).register(on: app)

        try await app.testing { client in
            let response = try await client.send(.get, to: "v2/public-identities/resolve?handle=%40TARGET_USER", beforeSend: { request in
            request.headers.bearerAuthorization = .init(token: "access-token")
            request.headers[HTTPField.Name("X-IM-Device-ID")!] = "00000000-0000-0000-0000-000000000901"
        })
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "no-store")
            #expect(response.headers[.pragma] == "no-cache")
            let body = try await response.content.decode(V2PublicIdentityHTTPResponse.self)
            #expect(body.userID == "target-user")
            #expect(body.handle == "target_user")
            #expect(body.displayName == "Target")
        }
    }

    @Test("unknown and hidden identities share the same not-found response")
    func absentIdentityIsNotFound() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        V2VaporPublicIdentityRoutes(
            authenticator: PublicIdentityRouteAuthenticator(userID: try .init("actor-user")),
            directory: PublicIdentityDirectoryFake(identity: nil)
        ).register(on: app)

        try await app.testing { client in
            let response = try await client.send(.get, to: "v2/public-identities/resolve?handle=missing_user", beforeSend: { request in
            request.headers.bearerAuthorization = .init(token: "access-token")
            request.headers[HTTPField.Name("X-IM-Device-ID")!] = "00000000-0000-0000-0000-000000000901"
        })
            #expect(response.status == .notFound)
        }
    }
}

private struct PublicIdentityRouteAuthenticator: V2GatewayAuthenticator {
    let userID: UserID
    func authenticateSession(accessToken: String, deviceID _: DeviceID) throws -> V2GatewayAuthentication {
        guard accessToken == "access-token" else { throw PublicIdentityRouteAuthenticationFailure.denied }
        return .init(userID: userID, expiresAt: nil)
    }
}

private struct PublicIdentityDirectoryFake: V2PublicIdentityAccountManaging {
    let identity: V2PublicIdentity?
    func resolve(handle _: V2PublicHandle, actorUserID _: UserID) async throws -> V2PublicIdentity? { identity }
    func profile(for _: UserID) async throws -> V2PublicIdentity? { identity }
    func updateDisplayName(for _: UserID, displayName: String) async throws -> V2PublicIdentity {
        guard let identity else { throw PublicIdentityRouteAuthenticationFailure.denied }
        return try .init(userID: identity.userID, handle: identity.handle, displayName: displayName, accountKind: identity.accountKind)
    }
}

private enum PublicIdentityRouteAuthenticationFailure: Error { case denied }
