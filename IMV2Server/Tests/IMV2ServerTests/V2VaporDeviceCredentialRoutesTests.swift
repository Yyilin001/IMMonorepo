import Foundation
import IMV2Core
import IMV2Server
@testable import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 Vapor device credential routes")
struct V2VaporDeviceCredentialRoutesTests {
    @Test("opaque account assertion issues device credentials without accepting a user ID")
    func issueRouteVerifiesAssertionAndDisablesCaching() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let userID = try UserID("00000000-0000-0000-0000-000000000701")
        let deviceID = try DeviceID("00000000-0000-0000-0000-000000000702")
        let credentials = try V2IssuedDeviceCredentials(userID: userID, deviceID: deviceID, accessToken: "access-secret", accessTokenExpiresAt: .distantFuture, refreshCredential: "refresh-secret")
        let issuer = DeviceCredentialRouteIssuer(registration: .issued(credentials), refresh: .rotated(credentials))
        V2VaporDeviceCredentialRoutes(assertionVerifier: RouteAssertionVerifier(userID: userID), issuer: issuer).register(on: app)

        let input = V2DeviceCredentialIssueHTTPRequest(accountAssertion: "opaque-assertion", deviceID: deviceID.rawValue, operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000703")!)
        try await app.testing().test(.POST, "v2/device-credentials", beforeRequest: { request in
            try request.content.encode(input)
        }) { response async in
            #expect(response.status == .ok)
            #expect(response.headers.first(name: .cacheControl) == "no-store")
            #expect(response.headers.first(name: "Pragma") == "no-cache")
            var decoded: V2DeviceCredentialIssueHTTPResponse?
            expectContent(V2DeviceCredentialIssueHTTPResponse.self, response) { decoded = $0 }
            #expect(decoded?.userID == userID.rawValue)
            #expect(decoded?.deviceID == deviceID.rawValue)
            #expect(decoded?.accessToken == "access-secret")
            #expect(decoded?.refreshCredential == "refresh-secret")
            #expect(!response.body.string.contains("opaque-assertion"))
        }
        let request = try #require(await issuer.registrationRequest())
        #expect(request.userID == userID)
        #expect(request.deviceID == deviceID)
    }

    @Test("failed assertion and terminal refresh do not issue replacement credentials")
    func routeRejectsUntrustedOrTerminalRequests() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let userID = try UserID("00000000-0000-0000-0000-000000000711")
        let deviceID = try DeviceID("00000000-0000-0000-0000-000000000712")
        let credentials = try V2IssuedDeviceCredentials(userID: userID, deviceID: deviceID, accessToken: "access", accessTokenExpiresAt: .distantFuture, refreshCredential: "refresh")
        V2VaporDeviceCredentialRoutes(
            assertionVerifier: RouteAssertionVerifier(userID: userID, accepts: false),
            issuer: DeviceCredentialRouteIssuer(registration: .issued(credentials), refresh: .terminalRejection)
        ).register(on: app)

        try await app.testing().test(.POST, "v2/device-credentials", beforeRequest: { request in
            try request.content.encode(V2DeviceCredentialIssueHTTPRequest(accountAssertion: "rejected", deviceID: deviceID.rawValue, operationID: UUID()))
        }) { response async in
            #expect(response.status == .unauthorized)
        }
        try await app.testing().test(.POST, "v2/device-credentials/refresh", beforeRequest: { request in
            try request.content.encode(V2DeviceCredentialRefreshHTTPRequest(userID: userID.rawValue, deviceID: deviceID.rawValue, refreshCredential: "old-refresh", operationID: UUID()))
        }) { response async in
            #expect(response.status == .unauthorized)
            #expect(!response.body.string.contains("access"))
        }
    }

    @Test("a device-bound assertion cannot be replayed to enrol another installation")
    func issueRouteUsesDeviceBoundVerifierWhenAvailable() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let userID = try UserID("00000000-0000-0000-0000-000000000721")
        let boundDeviceID = try DeviceID("00000000-0000-0000-0000-000000000722")
        let otherDeviceID = try DeviceID("00000000-0000-0000-0000-000000000723")
        let credentials = try V2IssuedDeviceCredentials(userID: userID, deviceID: boundDeviceID, accessToken: "access", accessTokenExpiresAt: .distantFuture, refreshCredential: "refresh")
        let issuer = DeviceCredentialRouteIssuer(registration: .issued(credentials), refresh: .rotated(credentials))
        V2VaporDeviceCredentialRoutes(assertionVerifier: DeviceBoundRouteAssertionVerifier(userID: userID, deviceID: boundDeviceID), issuer: issuer).register(on: app)

        try await app.testing().test(.POST, "v2/device-credentials", beforeRequest: { request in
            try request.content.encode(V2DeviceCredentialIssueHTTPRequest(accountAssertion: "bound-assertion", deviceID: otherDeviceID.rawValue, operationID: UUID()))
        }) { response async in
            #expect(response.status == .unauthorized)
        }
    }

    @Test("device registration budgets return a non-cacheable retry window")
    func issueRouteReturnsRetryAfterForRegistrationBudget() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let userID = try UserID("00000000-0000-0000-0000-000000000731")
        let deviceID = try DeviceID("00000000-0000-0000-0000-000000000732")
        V2VaporDeviceCredentialRoutes(
            assertionVerifier: RouteAssertionVerifier(userID: userID),
            issuer: DeviceCredentialRouteIssuer(
                registration: .rateLimited(retryAfterSeconds: 17),
                refresh: .terminalRejection
            )
        ).register(on: app)

        try await app.testing().test(.POST, "v2/device-credentials", beforeRequest: { request in
            try request.content.encode(V2DeviceCredentialIssueHTTPRequest(
                accountAssertion: "opaque-assertion",
                deviceID: deviceID.rawValue,
                operationID: UUID()
            ))
        }) { response async in
            #expect(response.status == .tooManyRequests)
            #expect(response.headers.first(name: "Retry-After") == "17")
            #expect(response.headers.first(name: .cacheControl) == "no-store")
            #expect(response.headers.first(name: "Pragma") == "no-cache")
        }
    }

    @Test("invalid device metadata is rejected before assertion verification or credential issuance")
    func rejectsInvalidDeviceMetadataEarly() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let userID = try UserID("00000000-0000-0000-0000-000000000741")
        let deviceID = try DeviceID("00000000-0000-0000-0000-000000000742")
        let verifier = RecordingRouteAssertionVerifier(userID: userID)
        let issuer = DeviceCredentialRouteIssuer(registration: .terminalTestFallback, refresh: .terminalRejection)
        V2VaporDeviceCredentialRoutes(assertionVerifier: verifier, issuer: issuer).register(on: app)

        try await app.testing().test(.POST, "v2/device-credentials", beforeRequest: { request in
            try request.content.encode(V2DeviceCredentialIssueHTTPRequest(
                accountAssertion: "opaque-assertion",
                deviceID: deviceID.rawValue,
                operationID: UUID(),
                deviceName: String(repeating: "x", count: 300),
                platform: "iOS"
            ))
        }) { response async in
            #expect(response.status == .badRequest)
        }
        #expect(await verifier.callCount() == 0)
        #expect(await issuer.registrationRequest() == nil)
    }
}

private struct RouteAssertionVerifier: V2DeviceBoundAccountAssertionVerifier {
    let userID: UserID
    var accepts = true
    func verifiedUserID(for accountAssertion: String) throws -> UserID {
        guard accepts, accountAssertion == "opaque-assertion" else { throw RouteAssertionFailure.denied }
        return userID
    }
    func verifiedUserID(for accountAssertion: String, deviceID _: DeviceID) throws -> UserID {
        try verifiedUserID(for: accountAssertion)
    }
}

private struct DeviceBoundRouteAssertionVerifier: V2DeviceBoundAccountAssertionVerifier {
    let userID: UserID
    let deviceID: DeviceID
    func verifiedUserID(for accountAssertion: String) throws -> UserID {
        guard accountAssertion == "bound-assertion" else { throw RouteAssertionFailure.denied }
        return userID
    }
    func verifiedUserID(for accountAssertion: String, deviceID: DeviceID) throws -> UserID {
        guard accountAssertion == "bound-assertion", deviceID == self.deviceID else { throw RouteAssertionFailure.denied }
        return userID
    }
}

private enum RouteAssertionFailure: Error { case denied }

private actor RecordingRouteAssertionVerifier: V2DeviceBoundAccountAssertionVerifier {
    let userID: UserID
    private var calls = 0
    init(userID: UserID) { self.userID = userID }
    func verifiedUserID(for _: String) -> UserID { calls += 1; return userID }
    func verifiedUserID(for _: String, deviceID _: DeviceID) -> UserID { calls += 1; return userID }
    func callCount() -> Int { calls }
}

private actor DeviceCredentialRouteIssuer: V2DeviceCredentialIssuing {
    private let registration: V2DeviceRegistrationOutcome
    private let refresh: V2DeviceCredentialRefreshOutcome
    private var receivedRegistration: V2TrustedDeviceRegistration?

    init(registration: V2DeviceRegistrationOutcome, refresh: V2DeviceCredentialRefreshOutcome) {
        self.registration = registration
        self.refresh = refresh
    }

    func register(_ request: V2TrustedDeviceRegistration) -> V2DeviceRegistrationOutcome {
        receivedRegistration = request
        return registration
    }

    func refresh(_: V2DeviceCredentialRefresh) -> V2DeviceCredentialRefreshOutcome { refresh }
    func registrationRequest() -> V2TrustedDeviceRegistration? { receivedRegistration }
}

private extension V2DeviceRegistrationOutcome {
    static var terminalTestFallback: Self { .deviceUnavailable }
}
