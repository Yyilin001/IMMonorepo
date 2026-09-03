import Foundation
import IMV2Core
import IMV2Server
@testable import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 authenticated account middleware")
struct V2AuthenticatedAccountMiddlewareTests {
    @Test("authentication distinguishes credential rejection from dependency failure")
    func mapsAuthenticationFailures() async throws {
        for fixture in [
            (AccountAuthenticationFixture.rejected, HTTPResponseStatus.unauthorized),
            (.unavailable, .serviceUnavailable),
        ] {
            let app = try await Application.make(.testing)
            defer { Task { try? await app.asyncShutdown() } }
            V2RedactedHTTPMiddlewareConfiguration.install(on: app)
            let routes = app.grouped(V2AuthenticatedAccountMiddleware(
                authenticator: AccountAuthenticationFake(fixture: fixture.0)
            ))
            routes.get("v2", "profile", "me") { _ in "unreachable" }

            try await app.testing().test(.GET, "v2/profile/me", beforeRequest: authenticatedHeaders) { response async in
                #expect(response.status == fixture.1)
                #expect(response.headers.first(name: .cacheControl) == "no-store")
            }
        }
    }

    @Test("authenticated batch and mutation endpoints consume weighted scoped budgets")
    func chargesEndpointCosts() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let limiter = AccountRateLimitRecorder(result: .allowed)
        let routes = app
            .grouped(V2AuthenticatedAccountMiddleware(
                authenticator: AccountAuthenticationFake(fixture: .accepted)
            ))
            .grouped(V2AuthenticatedAccountRateLimitMiddleware(limiter: limiter))
        routes.post("v2", "profile-views", "batch") { _ in Response(status: .ok) }
        routes.put("v2", "profile", "me") { _ in Response(status: .ok) }
        routes.get("v2", "profile-presentations", "contact-aliases") { _ in Response(status: .ok) }
        routes.get("v2", "devices") { _ in Response(status: .ok) }
        routes.get("v2", "public-identities", "me") { _ in Response(status: .ok) }
        routes.get("v2", "public-identities", "resolve") { _ in Response(status: .ok) }

        for (method, path) in [
            (HTTPMethod.POST, "v2/profile-views/batch"),
            (.PUT, "v2/profile/me"),
            (.GET, "v2/profile-presentations/contact-aliases?limit=500"),
            (.GET, "v2/devices?page_size=100"),
            (.GET, "v2/public-identities/me"),
            (.GET, "v2/public-identities/resolve?handle=alice"),
        ] {
            try await app.testing().test(method, path, beforeRequest: authenticatedHeaders) { response async in
                #expect(response.status == .ok)
            }
        }
        let charges = await limiter.charges()
        #expect(charges.map(\.scope) == [
            "profile-views", "profile", "profile-presentations", "devices", "public-identities",
        ])
        #expect(charges.map(\.cost) == [5, 3, 6, 2, 1])
    }

    @Test("authenticated limiter returns a no-store retry interval")
    func rejectsExhaustedBudget() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let routes = app
            .grouped(V2AuthenticatedAccountMiddleware(
                authenticator: AccountAuthenticationFake(fixture: .accepted)
            ))
            .grouped(V2AuthenticatedAccountRateLimitMiddleware(
                limiter: AccountRateLimitRecorder(result: .rateLimited(retryAfterSeconds: 7))
            ))
        routes.get("v2", "devices") { _ in "unreachable" }

        try await app.testing().test(.GET, "v2/devices", beforeRequest: authenticatedHeaders) { response async in
            #expect(response.status == .tooManyRequests)
            #expect(response.headers.first(name: "Retry-After") == "7")
            #expect(response.headers.first(name: .cacheControl) == "no-store")
        }
    }
}

private func authenticatedHeaders(_ request: inout TestingHTTPRequest) throws {
    request.headers.bearerAuthorization = .init(token: "opaque")
    request.headers.replaceOrAdd(
        name: "X-IM-Device-ID",
        value: "00000000-0000-0000-0000-000000000902"
    )
}

private enum AccountAuthenticationFixture: Sendable {
    case accepted
    case rejected
    case unavailable
}

private enum AccountAuthenticationFixtureError: Error { case unavailable }

private struct AccountAuthenticationFake: V2GatewayAuthenticator {
    let fixture: AccountAuthenticationFixture

    func authenticateSession(
        accessToken _: String,
        deviceID _: DeviceID
    ) throws -> V2GatewayAuthentication {
        switch fixture {
        case .accepted:
            return .init(
                userID: try .init("00000000-0000-0000-0000-000000000901"),
                expiresAt: nil
            )
        case .rejected:
            throw V2GatewayAuthenticationError.unauthenticated
        case .unavailable:
            throw AccountAuthenticationFixtureError.unavailable
        }
    }
}

private actor AccountRateLimitRecorder: V2AuthenticatedAccountRateLimiting {
    struct Charge: Sendable {
        let scope: String
        let cost: Int
    }

    private let result: V2AccountEdgeClientRateLimitResult
    private var recorded: [Charge] = []

    init(result: V2AccountEdgeClientRateLimitResult) {
        self.result = result
    }

    func consume(
        identity _: V2AuthenticatedConnection,
        scope: String,
        cost: Int
    ) -> V2AccountEdgeClientRateLimitResult {
        recorded.append(.init(scope: scope, cost: cost))
        return result
    }

    func charges() -> [Charge] { recorded }
}
