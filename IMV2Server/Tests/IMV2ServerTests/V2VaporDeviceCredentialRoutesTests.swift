import HTTPTypes
import Foundation
import IMV2Core
import IMV2Server
@testable import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 Vapor device credential routes")
struct V2VaporDeviceCredentialRoutesTests {
    @Test("Server clock failure is unavailable rather than a rejected account assertion")
    func clockFailureIsUnavailable() async throws {
        let app = try await Application(.testing)
        do {
            let key = Data(repeating: 6, count: 32), user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
            let signer = try V2HMACAccountAssertionIssuer(rawKey: key)
            let proof = try signer.issue(userID: user, deviceID: device)
            let verifier = try V2HMACAccountAssertionIssuer(rawKey: key, now: { Date(timeIntervalSince1970: .nan) })
            let issuer = DeviceCredentialRouteIssuer(registration: .deviceUnavailable, refresh: .terminalRejection)
            V2VaporDeviceCredentialRoutes(assertionVerifier: verifier, issuer: issuer).register(on: app)
            try await app.testing { client in
                let response = try await client.send(.post, to: "v2/device-credentials", beforeSend: { request in
                try request.content.encode(issueInput(assertion: proof, device: device))
            })
                #expect(response.status == .serviceUnavailable)
                #expect(response.headers[.cacheControl] == "no-store")
                #expect((try await response.body.data() ?? Data()).isEmpty)
            }
            #expect(await issuer.registrationRequest() == nil)
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test("issuance rejects missing or mismatched cancellation identity before account verification", arguments: ["missing", "null", "device", "operation", "root-user", "nested-user", "proof"])
    func requiresCancellationIdentity(scenario: String) async throws {
        let app = try await Application(.testing)
        do {
            let verifier = RecordingRouteAssertionVerifier(userID: try UserID(UUID().uuidString))
            let issuer = DeviceCredentialRouteIssuer(registration: .deviceUnavailable, refresh: .terminalRejection)
            V2VaporDeviceCredentialRoutes(assertionVerifier: verifier, issuer: issuer).register(on: app)
            let value = try issueInput(assertion: "opaque-assertion", device: DeviceID(UUID().uuidString))
            var body = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            var cancellation = try #require(body["cancellation"] as? [String: Any])
            switch scenario {
            case "missing": body.removeValue(forKey: "cancellation")
            case "null": body["cancellation"] = NSNull()
            case "device": body["deviceID"] = UUID().uuidString
            case "operation": body["operationID"] = UUID().uuidString
            case "root-user": body["userID"] = UUID().uuidString
            case "nested-user": cancellation["userID"] = NSNull(); body["cancellation"] = cancellation
            default: cancellation["proof"] = V2DeviceRevocationCredential.generate().rawValue; body["cancellation"] = cancellation
            }
            let data = try JSONSerialization.data(withJSONObject: body)
            try await app.testing { client in
                let response = try await client.send(.post, to: "v2/device-credentials", beforeSend: { request in
                request.headers.contentType = .json; request.body = .init(data: data)
            })
 #expect(response.status == .badRequest)
            }
            #expect(await verifier.callCount() == 0)
            #expect(await issuer.registrationRequest() == nil)
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }
    private func proof(_ device: DeviceID, operationID: UUID) throws -> V2DeviceRegistrationCancellation {
        try .init(deviceID: device, operationID: operationID, proof: .generate(), issueBeforeMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000) + 600_000)
    }
    private func issueInput(assertion: String, device: DeviceID, deviceName: String? = nil) throws -> V2DeviceCredentialIssueHTTPRequest {
        let operation = UUID()
        return try .init(accountAssertion: assertion, deviceID: device.rawValue, operationID: operation,
            cancellation: proof(device, operationID: operation), deviceName: deviceName, platform: "iOS")
    }
    @Test("credential expiry cannot trap response encoding", arguments: [
        Double(Int64.max) / 1_000, Double(Int64.min).nextDown / 1_000
    ])
    func rejectsUnrepresentableTimestamp(seconds: Double) throws {
        let credentials = try V2IssuedDeviceCredentials(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), accessToken: "test", accessTokenExpiresAt: Date(timeIntervalSince1970: seconds), refreshCredential: "test")
        #expect(throws: V2DeviceCredentialServiceError.malformedPersistence) {
            try V2DeviceCredentialIssueHTTPResponse(credentials: credentials)
        }
    }

    @Test("credential expiry keeps truncation toward zero", arguments: [
        (1_750_000_000.1239, Int64(1_750_000_000_123)), (-0.5001, Int64(-500)),
        (0.0, Int64(0)), (9_000_000_000_000_000.0, Int64(9_000_000_000_000_000_000))
    ])
    func preservesTimestamp(sample: (Double, Int64)) throws {
        let credentials = try V2IssuedDeviceCredentials(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), accessToken: "test", accessTokenExpiresAt: Date(timeIntervalSince1970: sample.0), refreshCredential: "test")
        #expect(try V2DeviceCredentialIssueHTTPResponse(credentials: credentials).accessTokenExpiresAtMilliseconds == sample.1)
    }

    @Test("opaque account assertion issues device credentials without accepting a user ID")
    func issueRouteVerifiesAssertionAndDisablesCaching() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let userID = try UserID("00000000-0000-0000-0000-000000000701")
        let deviceID = try DeviceID("00000000-0000-0000-0000-000000000702")
        let credentials = try V2IssuedDeviceCredentials(userID: userID, deviceID: deviceID, accessToken: "access-secret", accessTokenExpiresAt: .distantFuture, refreshCredential: "refresh-secret")
        let issuer = DeviceCredentialRouteIssuer(registration: .issued(credentials), refresh: .rotated(credentials))
        V2VaporDeviceCredentialRoutes(assertionVerifier: RouteAssertionVerifier(userID: userID), issuer: issuer).register(on: app)

        let input = V2DeviceCredentialIssueHTTPRequest(accountAssertion: "opaque-assertion", deviceID: deviceID.rawValue, operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000703")!, cancellation: try proof(deviceID, operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000703")!))
        try await app.testing { client in
            let response = try await client.send(.post, to: "v2/device-credentials", beforeSend: { request in
            try request.content.encode(input)
        })
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "no-store")
            #expect(response.headers[.pragma] == "no-cache")
            var decoded: V2DeviceCredentialIssueHTTPResponse?
            decoded = try await response.content.decode(V2DeviceCredentialIssueHTTPResponse.self)
            #expect(decoded?.userID == userID.rawValue)
            #expect(decoded?.deviceID == deviceID.rawValue)
            #expect(decoded?.accessToken == "access-secret")
            #expect(decoded?.refreshCredential == "refresh-secret")
            #expect(decoded?.registrationCancellation == input.cancellation)
            #expect(!(try await response.body.string() ?? "").contains("opaque-assertion"))
        }
        let request = try #require(await issuer.registrationRequest())
        #expect(request.registration.userID == userID)
        #expect(request.registration.deviceID == deviceID)
        #expect(request.cancellation == input.cancellation)
    }

    @Test("failed assertion and terminal refresh do not issue replacement credentials")
    func routeRejectsUntrustedOrTerminalRequests() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let userID = try UserID("00000000-0000-0000-0000-000000000711")
        let deviceID = try DeviceID("00000000-0000-0000-0000-000000000712")
        let credentials = try V2IssuedDeviceCredentials(userID: userID, deviceID: deviceID, accessToken: "access", accessTokenExpiresAt: .distantFuture, refreshCredential: "refresh")
        V2VaporDeviceCredentialRoutes(
            assertionVerifier: RouteAssertionVerifier(userID: userID, accepts: false),
            issuer: DeviceCredentialRouteIssuer(registration: .issued(credentials), refresh: .terminalRejection)
        ).register(on: app)

        try await app.testing { client in
            let response = try await client.send(.post, to: "v2/device-credentials", beforeSend: { request in
            try request.content.encode(issueInput(assertion: "rejected", device: deviceID))
        })
            #expect(response.status == .unauthorized)
        }
        try await app.testing { client in
            let response = try await client.send(.post, to: "v2/device-credentials/refresh", beforeSend: { request in
            try request.content.encode(V2DeviceCredentialRefreshHTTPRequest(userID: userID.rawValue, deviceID: deviceID.rawValue, refreshCredential: "old-refresh", operationID: UUID()))
        })
            #expect(response.status == .unauthorized)
            #expect(!(try await response.body.string() ?? "").contains("access"))
        }
    }

    @Test("a device-bound assertion cannot be replayed to enrol another installation")
    func issueRouteUsesDeviceBoundVerifierWhenAvailable() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let userID = try UserID("00000000-0000-0000-0000-000000000721")
        let boundDeviceID = try DeviceID("00000000-0000-0000-0000-000000000722")
        let otherDeviceID = try DeviceID("00000000-0000-0000-0000-000000000723")
        let credentials = try V2IssuedDeviceCredentials(userID: userID, deviceID: boundDeviceID, accessToken: "access", accessTokenExpiresAt: .distantFuture, refreshCredential: "refresh")
        let issuer = DeviceCredentialRouteIssuer(registration: .issued(credentials), refresh: .rotated(credentials))
        V2VaporDeviceCredentialRoutes(assertionVerifier: DeviceBoundRouteAssertionVerifier(userID: userID, deviceID: boundDeviceID), issuer: issuer).register(on: app)

        try await app.testing { client in
            let response = try await client.send(.post, to: "v2/device-credentials", beforeSend: { request in
            try request.content.encode(issueInput(assertion: "bound-assertion", device: otherDeviceID))
        })
            #expect(response.status == .unauthorized)
        }
    }

    @Test("device registration budgets return a non-cacheable retry window")
    func issueRouteReturnsRetryAfterForRegistrationBudget() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let userID = try UserID("00000000-0000-0000-0000-000000000731")
        let deviceID = try DeviceID("00000000-0000-0000-0000-000000000732")
        V2VaporDeviceCredentialRoutes(
            assertionVerifier: RouteAssertionVerifier(userID: userID),
            issuer: DeviceCredentialRouteIssuer(
                registration: .rateLimited(retryAfterSeconds: 17),
                refresh: .terminalRejection
            )
        ).register(on: app)

        try await app.testing { client in
            let response = try await client.send(.post, to: "v2/device-credentials", beforeSend: { request in
            try request.content.encode(issueInput(assertion: "opaque-assertion", device: deviceID))
        })
            #expect(response.status == .tooManyRequests)
            #expect(response.headers[.retryAfter] == "17")
            #expect(response.headers[.cacheControl] == "no-store")
            #expect(response.headers[.pragma] == "no-cache")
        }
    }

    @Test("invalid device metadata is rejected before assertion verification or credential issuance")
    func rejectsInvalidDeviceMetadataEarly() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let userID = try UserID("00000000-0000-0000-0000-000000000741")
        let deviceID = try DeviceID("00000000-0000-0000-0000-000000000742")
        let verifier = RecordingRouteAssertionVerifier(userID: userID)
        let issuer = DeviceCredentialRouteIssuer(registration: .terminalTestFallback, refresh: .terminalRejection)
        V2VaporDeviceCredentialRoutes(assertionVerifier: verifier, issuer: issuer).register(on: app)

        try await app.testing { client in
            let response = try await client.send(.post, to: "v2/device-credentials", beforeSend: { request in
            try request.content.encode(issueInput(assertion: "opaque-assertion", device: deviceID, deviceName: String(repeating: "x", count: 300)))
        })
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
    private var receivedRegistration: V2CancellableDeviceRegistration?

    init(registration: V2DeviceRegistrationOutcome, refresh: V2DeviceCredentialRefreshOutcome) {
        self.registration = registration
        self.refresh = refresh
    }

    func register(_ request: V2CancellableDeviceRegistration) -> V2DeviceRegistrationOutcome {
        receivedRegistration = request
        return registration
    }

    func refresh(_: V2DeviceCredentialRefresh) -> V2DeviceCredentialRefreshOutcome { refresh }
    func registrationRequest() -> V2CancellableDeviceRegistration? { receivedRegistration }
}

private extension V2DeviceRegistrationOutcome {
    static var terminalTestFallback: Self { .deviceUnavailable }
}
