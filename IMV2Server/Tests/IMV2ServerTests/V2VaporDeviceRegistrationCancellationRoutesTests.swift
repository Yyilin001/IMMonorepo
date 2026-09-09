import Foundation
import IMV2Core
import IMV2Server
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("Registration cancellation HTTP route")
struct V2VaporDeviceRegistrationCancellationRoutesTests {
    private func cancellation() throws -> V2DeviceRegistrationCancellation {
        try .init(deviceID: DeviceID(UUID().uuidString), operationID: UUID(), proof: .generate(), issueBeforeMilliseconds: 1_800_000_000_000)
    }

    @Test("cancelled, expired and infrastructure failure have distinct opaque responses", arguments: [204, 208, 410, 400, 503])
    func outcomes(status: Int) async throws {
        let app = try await Application.make(.testing)
        do {
            let service = CancellationRouteRecorder(status: status)
            V2VaporDeviceRegistrationCancellationRoutes(service: service).register(on: app)
            let value = try cancellation()
            try await app.testing().test(.POST, V2VaporDeviceRegistrationCancellationRoutes.path, beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "unrelated-new-account-token")
                try request.content.encode(V2DeviceRegistrationCancellationHTTPRequest(value))
            }) { response async in
                #expect(response.status.code == (status == 208 ? 204 : UInt(status)))
                #expect(response.headers.first(name: .cacheControl) == "no-store")
                #expect(response.headers.first(name: "Pragma") == "no-cache")
                #expect(response.body.readableBytes == 0)
            }
            #expect(await service.request() == value)
            try await app.asyncShutdown()
        } catch { try? await app.asyncShutdown(); throw error }
    }

    @Test("rejects account targeting, incomplete or malformed proof identities and oversized input", arguments: ["userID", "null-user", "unknown", "missing-proof", "access-proof", "bad-device", "bad-operation", "bad-deadline", "null-deadline", "malformed", "oversized", "form"])
    func validation(scenario: String) async throws {
        let app = try await Application.make(.testing)
        do {
            let service = CancellationRouteRecorder(status: 204)
            V2VaporDeviceRegistrationCancellationRoutes(service: service).register(on: app)
            var body = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(cancellation())) as? [String: Any])
            switch scenario {
            case "userID": body["userID"] = UUID().uuidString
            case "null-user": body["userID"] = NSNull()
            case "unknown": body["accessToken"] = "unrelated-token"
            case "missing-proof": body.removeValue(forKey: "proof")
            case "access-proof": body["proof"] = V2DeviceRevocationCredential.generate().rawValue
            case "bad-device": body["deviceID"] = "not-a-uuid"
            case "bad-operation": body["operationID"] = "not-a-uuid"
            case "bad-deadline": body["issueBeforeMilliseconds"] = Int64.max
            case "null-deadline": body["issueBeforeMilliseconds"] = NSNull()
            case "oversized": body["proof"] = String(repeating: "x", count: 2_048)
            default: break
            }
            let data = scenario == "malformed" ? Data("{".utf8) : try JSONSerialization.data(withJSONObject: body)
            try await app.testing().test(.POST, V2VaporDeviceRegistrationCancellationRoutes.path, beforeRequest: { request in
                request.headers.replaceOrAdd(name: .contentType, value: scenario == "form" ? "application/x-www-form-urlencoded" : "application/json")
                request.body = .init(data: data)
            }) { response async in
                #expect(response.status == (scenario == "oversized" ? .payloadTooLarge : .badRequest))
            }
            #expect(await service.request() == nil)
            try await app.asyncShutdown()
        } catch { try? await app.asyncShutdown(); throw error }
    }

    @Test("trusted edge and client address budget are required", arguments: ["missing-proof", "missing-address", "limited", "limiter-failed", "allowed"])
    func middleware(scenario: String) async throws {
        let app = try await Application.make(.testing)
        do {
            let edge = Data(repeating: 0x43, count: 32).base64EncodedString()
            app.middleware.use(V2AccountEdgeAuthenticationMiddleware(secret: try .init(base64Encoded: edge)))
            app.middleware.use(V2AccountEdgeClientRateLimitMiddleware(limiter: CancellationRouteLimiter(scenario: scenario),
                limitedPaths: [V2VaporDeviceRegistrationCancellationRoutes.path]))
            let service = CancellationRouteRecorder(status: 204)
            V2VaporDeviceRegistrationCancellationRoutes(service: service).register(on: app)
            let value = try cancellation()
            try await app.testing().test(.POST, V2VaporDeviceRegistrationCancellationRoutes.path, beforeRequest: { request in
                if scenario != "missing-proof" { request.headers.replaceOrAdd(name: V2AccountEdgeAuthenticationMiddleware.headerName, value: edge) }
                if scenario != "missing-address" { request.headers.replaceOrAdd(name: V2AccountEdgeAuthenticationMiddleware.clientAddressHeaderName, value: "192.0.2.16") }
                try request.content.encode(V2DeviceRegistrationCancellationHTTPRequest(value))
            }) { response async in
                let status: HTTPResponseStatus
                switch scenario {
                case "missing-proof", "missing-address": status = .forbidden
                case "limited": status = .tooManyRequests
                case "limiter-failed": status = .serviceUnavailable
                default: status = .noContent
                }
                #expect(response.status == status)
                if scenario == "limited" { #expect(response.headers.first(name: "Retry-After") == "19") }
            }
            #expect((await service.request() != nil) == (scenario == "allowed"))
            try await app.asyncShutdown()
        } catch { try? await app.asyncShutdown(); throw error }
    }
}

private actor CancellationRouteRecorder: V2DeviceRegistrationCancelling {
    let status: Int
    private var recorded: V2DeviceRegistrationCancellation?
    init(status: Int) { self.status = status }
    func cancel(_ request: V2DeviceRegistrationCancellation) throws -> V2DeviceRegistrationCancellationOutcome {
        recorded = request
        switch status {
        case 204: return .applied
        case 208: return .idempotent
        case 410: return .expired
        case 400: throw V2DeviceSessionServiceError.invalidRequest
        default: throw V2DeviceSessionServiceError.unavailable
        }
    }
    func request() -> V2DeviceRegistrationCancellation? { recorded }
}

private struct CancellationRouteLimiter: V2AccountEdgeClientRateLimiting {
    let scenario: String
    func consume(address: V2AccountEdgeClientAddress) throws -> V2AccountEdgeClientRateLimitResult {
        if scenario == "limiter-failed" { throw V2DeviceSessionServiceError.unavailable }
        return scenario == "limited" ? .rateLimited(retryAfterSeconds: 19) : .allowed
    }
}
