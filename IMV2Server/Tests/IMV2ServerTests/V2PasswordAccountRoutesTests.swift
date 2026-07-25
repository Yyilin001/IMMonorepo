import Foundation
import FluentPostgresDriver
import IMV2Core
import IMV2Server
@testable import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 password fallback routes")
struct V2PasswordAccountRoutesTests {
    @Test("account routes reject a direct caller without the edge proof")
    func accountEdgeProofIsRequired() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let proof = Data(repeating: 9, count: 32).base64EncodedString()
        let secret = try V2AccountEdgeAuthorizationSecret(base64Encoded: proof)
        app.middleware.use(V2AccountEdgeAuthenticationMiddleware(secret: secret))
        app.get("ready") { _ in "ok" }

        try await app.testing().test(.GET, "ready") { response async in
            #expect(response.status == .forbidden)
        }
        try await app.testing().test(.GET, "ready", beforeRequest: { request in
            request.headers.replaceOrAdd(name: V2AccountEdgeAuthenticationMiddleware.headerName, value: proof)
        }) { response async in
            #expect(response.status == .forbidden)
        }
        try await app.testing().test(.GET, "ready", beforeRequest: { request in
            request.headers.replaceOrAdd(name: V2AccountEdgeAuthenticationMiddleware.headerName, value: proof)
            request.headers.replaceOrAdd(name: V2AccountEdgeAuthenticationMiddleware.clientAddressHeaderName, value: "127.0.0.1")
        }) { response async in
            #expect(response.status == .ok)
            #expect(response.body.string == "ok")
        }
    }

    @Test("account edge limits only an authenticated Caddy-derived client address")
    func accountEdgeClientBudgetIsNoStoreAndFailsClosed() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let proof = Data(repeating: 7, count: 32).base64EncodedString()
        let secret = try V2AccountEdgeAuthorizationSecret(base64Encoded: proof)
        app.middleware.use(V2AccountEdgeAuthenticationMiddleware(secret: secret))
        app.middleware.use(V2AccountEdgeClientRateLimitMiddleware(limiter: FixedEdgeClientLimiter()))
        app.get("ready") { _ in "must not be reached" }

        try await app.testing().test(.GET, "ready", beforeRequest: { request in
            request.headers.replaceOrAdd(name: V2AccountEdgeAuthenticationMiddleware.headerName, value: proof)
            request.headers.replaceOrAdd(name: V2AccountEdgeAuthenticationMiddleware.clientAddressHeaderName, value: "not-an-address")
        }) { response async in
            #expect(response.status == .forbidden)
        }
        try await app.testing().test(.GET, "ready", beforeRequest: { request in
            request.headers.replaceOrAdd(name: V2AccountEdgeAuthenticationMiddleware.headerName, value: proof)
            request.headers.replaceOrAdd(name: V2AccountEdgeAuthenticationMiddleware.clientAddressHeaderName, value: "2001:db8::1")
        }) { response async in
            #expect(response.status == .tooManyRequests)
            #expect(response.headers.first(name: .cacheControl) == "no-store")
            #expect(response.headers.first(name: "Pragma") == "no-cache")
            #expect(response.headers.first(name: "Retry-After") == "19")
            #expect(response.body.string.isEmpty)
        }
    }

    @Test("account-edge limiter preserves an allowed route's client status")
    func accountEdgeClientBudgetDoesNotRewriteRouteErrors() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let proof = Data(repeating: 8, count: 32).base64EncodedString()
        let secret = try V2AccountEdgeAuthorizationSecret(base64Encoded: proof)
        app.middleware.use(V2AccountEdgeAuthenticationMiddleware(secret: secret))
        app.middleware.use(V2AccountEdgeClientRateLimitMiddleware(limiter: AllowedEdgeClientLimiter()))
        app.get("invalid") { _ throws -> Response in throw Abort(.badRequest) }

        try await app.testing().test(.GET, "invalid", beforeRequest: { request in
            request.headers.replaceOrAdd(name: V2AccountEdgeAuthenticationMiddleware.headerName, value: proof)
            request.headers.replaceOrAdd(name: V2AccountEdgeAuthenticationMiddleware.clientAddressHeaderName, value: "192.0.2.8")
        }) { response async in
            #expect(response.status == .badRequest)
        }
    }

    @Test("locked password fallback responses are no-store and expose the durable retry interval")
    func lockedPasswordAttemptReturnsNoStoreRetryAfter() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        app.databases.use(
            try .postgres(url: "postgres://im_v2_test:im_v2_test@127.0.0.1:1/im_v2_test"),
            as: .psql,
            isDefault: true
        )
        let assertionIssuer = try V2HMACAccountAssertionIssuer(rawKey: Data(repeating: 1, count: 32))
        V2PasswordAccountRoutes(
            store: .init(database: app.db(.psql)),
            assertionIssuer: assertionIssuer,
            dummyPasswordHash: "$2b$12$123456789012345678901u12345678901234567890123456789012",
            loginAttemptLimiter: BlockedPasswordAttemptLimiter(retryAfterSeconds: 47)
        ).register(on: app)

        let body = V2PasswordAccountHTTPRequest(
            accountHandle: "locked-account",
            password: "a-valid-length-password",
            deviceID: "00000000-0000-0000-0000-000000000901"
        )
        try await app.testing().test(.POST, "v2/account-auth/password/assertion", beforeRequest: { request in
            try request.content.encode(body)
        }) { response async in
            #expect(response.status == .tooManyRequests)
            #expect(response.headers.first(name: .cacheControl) == "no-store")
            #expect(response.headers.first(name: "Pragma") == "no-cache")
            #expect(response.headers.first(name: "Retry-After") == "47")
            #expect(response.body.string.isEmpty)
        }
    }

    @Test("password registration missing public profile fields remains a bad request")
    func passwordRegistrationMissingPublicProfileReturnsBadRequest() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        app.databases.use(
            try .postgres(url: "postgres://im_v2_test:im_v2_test@127.0.0.1:1/im_v2_test"),
            as: .psql,
            isDefault: true
        )
        let assertionIssuer = try V2HMACAccountAssertionIssuer(rawKey: Data(repeating: 2, count: 32))
        V2PasswordAccountRoutes(
            store: .init(database: app.db(.psql)),
            assertionIssuer: assertionIssuer,
            dummyPasswordHash: "$2b$12$123456789012345678901u12345678901234567890123456789012",
            loginAttemptLimiter: BlockedPasswordAttemptLimiter(retryAfterSeconds: 1)
        ).register(on: app)

        let body = V2PasswordAccountHTTPRequest(
            accountHandle: "new-account",
            password: "a-valid-length-password",
            deviceID: "00000000-0000-0000-0000-000000000902"
        )
        try await app.testing().test(.POST, "v2/account-auth/password/register", beforeRequest: { request in
            try request.content.encode(body)
        }) { response async in
            #expect(response.status == .badRequest)
        }
    }
}

private struct BlockedPasswordAttemptLimiter: V2PasswordLoginAttemptLimiting {
    let retryAfterSeconds: Int

    func blockedRetryAfterSeconds(accountHandle _: String) async throws -> Int? { retryAfterSeconds }
    func recordRejectedAttempt(accountHandle _: String, userID _: UserID?, deviceID _: DeviceID) async throws {}
    func recordSuccessfulAttempt(accountHandle _: String, userID _: UserID, deviceID _: DeviceID) async throws {}
}

private struct FixedEdgeClientLimiter: V2AccountEdgeClientRateLimiting {
    func consume(address _: V2AccountEdgeClientAddress) async throws -> V2AccountEdgeClientRateLimitResult {
        .rateLimited(retryAfterSeconds: 19)
    }
}

private struct AllowedEdgeClientLimiter: V2AccountEdgeClientRateLimiting {
    func consume(address _: V2AccountEdgeClientAddress) async throws -> V2AccountEdgeClientRateLimitResult {
        .allowed
    }
}
