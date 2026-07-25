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
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        V2VaporPublicIdentityRoutes(
            authenticator: PublicIdentityRouteAuthenticator(userID: try .init("actor-user")),
            directory: PublicIdentityDirectoryFake(identity: try .init(userID: .init("target-user"), handle: .init("target_user"), displayName: "Target"))
        ).register(on: app)

        try await app.testing().test(.GET, "v2/public-identities/resolve?handle=%40TARGET_USER", beforeRequest: { request in
            request.headers.bearerAuthorization = .init(token: "access-token")
            request.headers.replaceOrAdd(name: "X-IM-Device-ID", value: "00000000-0000-0000-0000-000000000901")
        }) { response async throws in
            #expect(response.status == .ok)
            #expect(response.headers.first(name: .cacheControl) == "no-store")
            #expect(response.headers.first(name: "Pragma") == "no-cache")
            let body = try response.content.decode(V2PublicIdentityHTTPResponse.self)
            #expect(body.userID == "target-user")
            #expect(body.handle == "target_user")
            #expect(body.displayName == "Target")
        }
    }

    @Test("unknown and hidden identities share the same not-found response")
    func absentIdentityIsNotFound() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        V2VaporPublicIdentityRoutes(
            authenticator: PublicIdentityRouteAuthenticator(userID: try .init("actor-user")),
            directory: PublicIdentityDirectoryFake(identity: nil)
        ).register(on: app)

        try await app.testing().test(.GET, "v2/public-identities/resolve?handle=missing_user", beforeRequest: { request in
            request.headers.bearerAuthorization = .init(token: "access-token")
            request.headers.replaceOrAdd(name: "X-IM-Device-ID", value: "00000000-0000-0000-0000-000000000901")
        }) { response async in
            #expect(response.status == .notFound)
        }
    }
}

private struct PublicIdentityRouteAuthenticator: V2GatewayAuthenticator {
    let userID: UserID
    func authenticate(accessToken: String, deviceID _: DeviceID) throws -> UserID {
        guard accessToken == "access-token" else { throw PublicIdentityRouteAuthenticationFailure.denied }
        return userID
    }
}

private struct PublicIdentityDirectoryFake: V2PublicIdentityDirectoryReading {
    let identity: V2PublicIdentity?
    func resolve(handle _: V2PublicHandle, actorUserID _: UserID) async throws -> V2PublicIdentity? { identity }
}

private enum PublicIdentityRouteAuthenticationFailure: Error { case denied }
