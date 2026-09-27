import HTTPTypes
import Foundation
import IMV2Core
import IMV2Server
@testable import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting
import Synchronization

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
            let body = try await response.content.decode(V2PublicIdentityResolution.self)
            #expect(body.identity.userID.rawValue == "target-user")
            #expect(body.identity.handle.rawValue == "target_user")
            #expect(body.identity.displayName == "Target")
            #expect(body.actorUserID.rawValue == "actor-user")
            #expect(body.deviceID.rawValue == "00000000-0000-0000-0000-000000000901")
            #expect(body.validUntilUnixMilliseconds - body.observedAtUnixMilliseconds == 60_000)
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
            #expect(response.headers[.cacheControl] == "no-store")
        }
    }

    @Test func resolutionIsClippedToBothCredentialObservations() async throws {
        let clock = ResolutionTestClock(elapsed: 10)
        let actor = try UserID("actor-user")
        let authenticator = ResolutionSequenceAuthenticator(results: [
            .success(.init(userID: actor, expiresAt: clock.start.addingTimeInterval(15))),
            .success(.init(userID: actor, expiresAt: clock.start.addingTimeInterval(25)))
        ])
        let service = V2PublicIdentityResolutionService(authenticator: authenticator,
            directory: PublicIdentityDirectoryFake(identity: try .init(userID: .init("target-user"), handle: .init("target_user"), displayName: "Target", accountKind: .regular)),
            now: { clock.read() })
        let result = try #require(await service.resolve(handle: .init("target_user"), accessToken: "token",
            deviceID: .init("device")))
        #expect(result.validUntilUnixMilliseconds - result.observedAtUnixMilliseconds == 15_000)
        #expect(result.serverNowUnixMilliseconds - result.observedAtUnixMilliseconds == 10_000)
        #expect(await authenticator.calls == 2)
    }

    @Test(arguments: ["revoked", "switched", "expired", "slow", "mismatchedHandle"])
    func resolutionDoesNotPublishAfterFailedRevalidation(kind: String) async throws {
        let clock = ResolutionTestClock(elapsed: kind == "slow" ? 61 : 10)
        let actor = try UserID("actor-user")
        let initial = V2GatewayAuthentication(userID: actor, expiresAt: nil)
        let final: Result<V2GatewayAuthentication, V2GatewayAuthenticationError> = kind == "revoked"
            ? .failure(.unauthenticated)
            : .success(.init(userID: kind == "switched" ? try .init("other") : actor,
                expiresAt: kind == "expired" ? clock.start.addingTimeInterval(5) : nil))
        let authenticator = ResolutionSequenceAuthenticator(results: [.success(initial), final])
        let service = V2PublicIdentityResolutionService(authenticator: authenticator,
            directory: PublicIdentityDirectoryFake(identity: try .init(userID: .init("target-user"),
                handle: .init(kind == "mismatchedHandle" ? "another_user" : "target_user"), displayName: "Target", accountKind: .regular)),
            now: { clock.read() })
        await #expect(throws: (any Error).self) {
            try await service.resolve(handle: .init("target_user"), accessToken: "token", deviceID: .init("device"))
        }
    }
}

private final class ResolutionTestClock: Sendable {
    let start = Date(timeIntervalSince1970: 2_000_000_000)
    let elapsed: TimeInterval
    private let first = Mutex(true)
    init(elapsed: TimeInterval) { self.elapsed = elapsed }
    func read() -> Date {
        first.withLock { value in
            defer { value = false }
            return value ? start : start.addingTimeInterval(elapsed)
        }
    }
}

private actor ResolutionSequenceAuthenticator: V2GatewayAuthenticator {
    let results: [Result<V2GatewayAuthentication, V2GatewayAuthenticationError>]
    private(set) var calls = 0
    init(results: [Result<V2GatewayAuthentication, V2GatewayAuthenticationError>]) { self.results = results }
    func authenticateSession(accessToken: String, deviceID: DeviceID) throws -> V2GatewayAuthentication {
        defer { calls += 1 }
        return try results[min(calls, results.count - 1)].get()
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
