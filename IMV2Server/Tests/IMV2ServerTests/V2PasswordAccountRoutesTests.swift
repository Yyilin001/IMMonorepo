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
}

private struct BlockedPasswordAttemptLimiter: V2PasswordLoginAttemptLimiting {
    let retryAfterSeconds: Int

    func blockedRetryAfterSeconds(accountHandle _: String) async throws -> Int? { retryAfterSeconds }
    func recordRejectedAttempt(accountHandle _: String, userID _: UserID?, deviceID _: DeviceID) async throws {}
    func recordSuccessfulAttempt(accountHandle _: String, userID _: UserID, deviceID _: DeviceID) async throws {}
}
