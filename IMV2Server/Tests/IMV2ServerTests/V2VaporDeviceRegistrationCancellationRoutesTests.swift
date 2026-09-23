import Foundation
import HTTPTypes
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
        let app = try await Application(.testing)
        do {
            let service = CancellationRouteRecorder(status: status)
            V2VaporDeviceRegistrationCancellationRoutes(service: service).register(on: app)
            let value = try cancellation()
            try await app.testing { client in
                let response = try await client.send(.post, to: URI(string: V2VaporDeviceRegistrationCancellationRoutes.path), beforeSend: { request in
                request.headers.bearerAuthorization = .init(token: "unrelated-new-account-token")
                try request.content.encode(V2DeviceRegistrationCancellationHTTPRequest(value))
            })
                #expect(response.status.code == (status == 208 ? 204 : status))
                #expect(response.headers[.cacheControl] == "no-store")
                #expect(response.headers[.pragma] == "no-cache")
                #expect((try await response.body.data() ?? Data()).isEmpty)
            }
            #expect(await service.request() == value)
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test("rejects account targeting, incomplete or malformed proof identities and oversized input", arguments: ["userID", "null-user", "unknown", "missing-proof", "access-proof", "bad-device", "bad-operation", "bad-deadline", "null-deadline", "malformed", "oversized", "oversized-form", "form"])
    func validation(scenario: String) async throws {
        let app = try await Application(.testing)
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
            case "oversized", "oversized-form": body["proof"] = String(repeating: "x", count: 2_048)
            default: break
            }
            let data = scenario == "malformed" ? Data("{".utf8) : try JSONSerialization.data(withJSONObject: body)
            try await app.testing { client in
                let response = try await client.send(.post, to: URI(string: V2VaporDeviceRegistrationCancellationRoutes.path), beforeSend: { request in
                request.headers[.contentType] = scenario == "form" || scenario == "oversized-form" ? "application/x-www-form-urlencoded" : "application/json"
                request.body = .init(data: data)
            })
                #expect(response.status == (scenario == "oversized" || scenario == "oversized-form" ? .contentTooLarge : .badRequest))
            }
            #expect(await service.request() == nil)
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test("trusted edge and client address budget are required", arguments: ["missing-proof", "missing-address", "limited", "limiter-failed", "allowed"])
    func middleware(scenario: String) async throws {
        let app = try await Application(.testing)
        do {
            let edge = Data(repeating: 0x43, count: 32).base64EncodedString()
            app.middleware.use(V2AccountEdgeAuthenticationMiddleware(secret: try .init(base64Encoded: edge)))
            app.middleware.use(V2AccountEdgeClientRateLimitMiddleware(limiter: CancellationRouteLimiter(scenario: scenario),
                limitedPaths: [V2VaporDeviceRegistrationCancellationRoutes.path]))
            let service = CancellationRouteRecorder(status: 204)
            V2VaporDeviceRegistrationCancellationRoutes(service: service).register(on: app)
            let value = try cancellation()
            try await app.testing { client in
                let response = try await client.send(.post, to: URI(string: V2VaporDeviceRegistrationCancellationRoutes.path), beforeSend: { request in
                if scenario != "missing-proof" { request.headers[V2AccountEdgeAuthenticationMiddleware.headerName] = edge }
                if scenario != "missing-address" { request.headers[V2AccountEdgeAuthenticationMiddleware.clientAddressHeaderName] = "192.0.2.16" }
                try request.content.encode(V2DeviceRegistrationCancellationHTTPRequest(value))
            })
                let status: HTTPResponse.Status
                switch scenario {
                case "missing-proof", "missing-address": status = .forbidden
                case "limited": status = .tooManyRequests
                case "limiter-failed": status = .serviceUnavailable
                default: status = .noContent
                }
                #expect(response.status == status)
                if scenario == "limited" { #expect(response.headers[.retryAfter] == "19") }
            }
            #expect((await service.request() != nil) == (scenario == "allowed"))
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
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
