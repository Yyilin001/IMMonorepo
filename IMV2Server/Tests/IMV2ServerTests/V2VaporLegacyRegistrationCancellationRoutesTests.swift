import Foundation
import IMV2Core
import IMV2Server
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("Legacy registration cancellation HTTP")
struct V2VaporLegacyRegistrationCancellationRoutesTests {
    @Test("Only the verified account reaches cancellation and outcomes remain opaque", arguments: [204, 208, 403, 404, 409, 507, 503])
    func outcomes(status: Int) async throws {
        let app = try await Application.make(.testing)
        do {
            let user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), target = DeviceID(uuid: UUID()), operation = UUID()
            let issuer = try V2HMACAccountAssertionIssuer(rawKey: Data(repeating: 0x49, count: 32))
            let service = LegacyRouteRecorder(status: status)
            V2VaporLegacyDeviceRegistrationCancellationRoutes(assertionVerifier: issuer, service: service).register(on: app)
            let input = V2LegacyDeviceRegistrationCancellationHTTPRequest(accountAssertion: try issuer.issue(userID: user, deviceID: device),
                assertionDeviceID: device.rawValue.lowercased(), targetDeviceID: target.rawValue.lowercased(), operationID: operation)
            try await app.testing().test(.POST, V2VaporLegacyDeviceRegistrationCancellationRoutes.path, beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "unrelated-account-token")
                try request.content.encode(input)
            }) { response async in
                #expect(response.status.code == UInt(status == 208 ? 204 : status))
                #expect(response.body.readableBytes == 0)
                #expect(response.headers.first(name: .cacheControl) == "no-store")
                #expect(response.headers.first(name: "Pragma") == "no-cache")
            }
            let recorded = await service.request()
            #expect(recorded?.userID == user)
            #expect(recorded?.assertionDeviceID == device)
            #expect(recorded?.targetDeviceID == target)
            #expect(recorded?.operationID == operation)
            try await app.asyncShutdown()
        } catch { try? await app.asyncShutdown(); throw error }
    }

    @Test("Malformed targets are rejected before factor verification", arguments: ["userID", "extra", "missing", "null", "opaque-device", "bad-target", "same-device", "operation", "blank", "long-assertion", "oversized", "malformed", "form"])
    func validation(scenario: String) async throws {
        let app = try await Application.make(.testing)
        do {
            let verifier = LegacyRouteVerifier(failure: false)
            let service = LegacyRouteRecorder(status: 204)
            V2VaporLegacyDeviceRegistrationCancellationRoutes(assertionVerifier: verifier, service: service).register(on: app)
            let device = UUID().uuidString
            var body: [String: Any] = ["accountAssertion": "opaque-factor", "assertionDeviceID": device,
                "targetDeviceID": UUID().uuidString, "operationID": UUID().uuidString]
            switch scenario {
            case "userID": body["userID"] = UUID().uuidString
            case "extra": body["accessToken"] = "token"
            case "missing": body.removeValue(forKey: "accountAssertion")
            case "null": body["accountAssertion"] = NSNull()
            case "opaque-device": body["assertionDeviceID"] = "opaque"
            case "bad-target": body["targetDeviceID"] = "bad"
            case "same-device": body["targetDeviceID"] = device.lowercased()
            case "operation": body["operationID"] = "bad"
            case "blank": body["accountAssertion"] = " \n "
            case "long-assertion": body["accountAssertion"] = String(repeating: "x", count: 4_097)
            case "oversized": body["accountAssertion"] = String(repeating: "x", count: 9_000)
            default: break
            }
            let data = scenario == "malformed" ? Data("{".utf8) : try JSONSerialization.data(withJSONObject: body)
            try await app.testing().test(.POST, V2VaporLegacyDeviceRegistrationCancellationRoutes.path, beforeRequest: { request in
                request.headers.replaceOrAdd(name: .contentType, value: scenario == "form" ? "application/x-www-form-urlencoded" : "application/json")
                request.body = .init(data: data)
            }) { response async in
                #expect(response.status == (scenario == "oversized" ? .payloadTooLarge : .badRequest))
            }
            #expect(await verifier.calls() == 0)
            #expect(await service.request() == nil)
            try await app.asyncShutdown()
        } catch { try? await app.asyncShutdown(); throw error }
    }

    @Test("Expired, forged, wrong-device and ordinary credentials cannot authorize cleanup", arguments: ["expired", "forged", "wrong-device", "access-token", "infrastructure"])
    func authority(scenario: String) async throws {
        let app = try await Application.make(.testing)
        do {
            let user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
            let key = Data(repeating: 0x49, count: 32)
            let now = Date()
            let current = try V2HMACAccountAssertionIssuer(rawKey: key, now: { now })
            let signer = try V2HMACAccountAssertionIssuer(rawKey: scenario == "forged" ? Data(repeating: 0x50, count: 32) : key,
                now: { scenario == "expired" ? now.addingTimeInterval(-120) : now })
            let service = LegacyRouteRecorder(status: 204)
            let verifier: any V2DeviceBoundAccountAssertionVerifier = scenario == "infrastructure" ? LegacyRouteVerifier(failure: true) : current
            V2VaporLegacyDeviceRegistrationCancellationRoutes(assertionVerifier: verifier, service: service).register(on: app)
            let assertion = scenario == "access-token" ? "ordinary-access-token" : try signer.issue(userID: user, deviceID: scenario == "wrong-device" ? .init(uuid: UUID()) : device)
            let input = V2LegacyDeviceRegistrationCancellationHTTPRequest(accountAssertion: assertion, assertionDeviceID: device.rawValue,
                targetDeviceID: UUID().uuidString, operationID: UUID())
            try await app.testing().test(.POST, V2VaporLegacyDeviceRegistrationCancellationRoutes.path, beforeRequest: { request in
                try request.content.encode(input)
            }) { response async in
                #expect(response.status == (scenario == "infrastructure" ? .serviceUnavailable : .unauthorized))
                #expect(response.body.readableBytes == 0)
                #expect(response.headers.first(name: .cacheControl) == "no-store")
            }
            #expect(await service.request() == nil)
            try await app.asyncShutdown()
        } catch { try? await app.asyncShutdown(); throw error }
    }

    @Test("Trusted edge and address limit run before factor verification", arguments: ["missing-proof", "missing-address", "limited", "failed", "allowed"])
    func middleware(scenario: String) async throws {
        let app = try await Application.make(.testing)
        do {
            let edge = Data(repeating: 0x43, count: 32).base64EncodedString()
            app.middleware.use(V2AccountEdgeAuthenticationMiddleware(secret: try .init(base64Encoded: edge)))
            app.middleware.use(V2AccountEdgeClientRateLimitMiddleware(limiter: LegacyRouteLimiter(scenario: scenario),
                limitedPaths: [V2VaporLegacyDeviceRegistrationCancellationRoutes.path]))
            let verifier = LegacyRouteVerifier(failure: false), service = LegacyRouteRecorder(status: 204)
            V2VaporLegacyDeviceRegistrationCancellationRoutes(assertionVerifier: verifier, service: service).register(on: app)
            let input = V2LegacyDeviceRegistrationCancellationHTTPRequest(accountAssertion: "factor", assertionDeviceID: UUID().uuidString,
                targetDeviceID: UUID().uuidString, operationID: UUID())
            try await app.testing().test(.POST, V2VaporLegacyDeviceRegistrationCancellationRoutes.path, beforeRequest: { request in
                if scenario != "missing-proof" { request.headers.replaceOrAdd(name: V2AccountEdgeAuthenticationMiddleware.headerName, value: edge) }
                if scenario != "missing-address" { request.headers.replaceOrAdd(name: V2AccountEdgeAuthenticationMiddleware.clientAddressHeaderName, value: "192.0.2.17") }
                try request.content.encode(input)
            }) { response async in
                let status: HTTPResponseStatus
                switch scenario {
                case "missing-proof", "missing-address": status = .forbidden
                case "limited": status = .tooManyRequests
                case "failed": status = .serviceUnavailable
                default: status = .noContent
                }
                #expect(response.status == status)
                if scenario == "limited" { #expect(response.headers.first(name: "Retry-After") == "19") }
            }
            #expect(await verifier.calls() == (scenario == "allowed" ? 1 : 0))
            #expect((await service.request() != nil) == (scenario == "allowed"))
            try await app.asyncShutdown()
        } catch { try? await app.asyncShutdown(); throw error }
    }
}

private actor LegacyRouteRecorder: V2LegacyDeviceRegistrationCancelling {
    let status: Int
    private var recorded: V2TrustedLegacyDeviceRegistrationCancellation?
    init(status: Int) { self.status = status }
    func cancel(_ request: V2TrustedLegacyDeviceRegistrationCancellation) throws -> V2LegacyDeviceRegistrationCancellationOutcome {
        recorded = request
        switch status {
        case 204: return .applied
        case 208: return .idempotent
        case 403: return .accountUnavailable
        case 404: return .targetUnavailable
        case 409: return .conflict
        case 507: return .capacityExceeded
        default: throw V2DeviceSessionServiceError.unavailable
        }
    }
    func request() -> V2TrustedLegacyDeviceRegistrationCancellation? { recorded }
}

private actor LegacyRouteVerifier: V2DeviceBoundAccountAssertionVerifier {
    let failure: Bool
    private var count = 0
    init(failure: Bool) { self.failure = failure }
    func verifiedUserID(for accountAssertion: String) throws -> UserID { throw V2AccountAssertionError.invalidAssertion }
    func verifiedUserID(for accountAssertion: String, deviceID: DeviceID) throws -> UserID {
        count += 1
        if failure { throw V2DeviceSessionServiceError.unavailable }
        return UserID(uuid: UUID())
    }
    func calls() -> Int { count }
}

private struct LegacyRouteLimiter: V2AccountEdgeClientRateLimiting {
    let scenario: String
    func consume(address: V2AccountEdgeClientAddress) throws -> V2AccountEdgeClientRateLimitResult {
        if scenario == "failed" { throw V2DeviceSessionServiceError.unavailable }
        return scenario == "limited" ? .rateLimited(retryAfterSeconds: 19) : .allowed
    }
}
