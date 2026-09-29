import IMV2ServerApplication
import IMV2ServerContracts
import HTTPTypes
import Foundation
import IMV2Core
import IMV2Server
import IMV2ServerInfrastructure
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 revoke-only HTTP route")
struct V2VaporDeviceRevocationCapabilityRoutesTests {
    @Test("Maps only confirmed redemption to 204 and keeps responses opaque", arguments: [204, 208, 401, 410, 409, 503])
    func outcomes(status: Int) async throws {
        let app = try await Application(.testing)
        do {
            let service = RevocationRouteRecorder(status: status)
            V2VaporDeviceRevocationCapabilityRoutes(service: service).register(on: app)
            let credential = V2DeviceRevocationCredential.generate(), operation = UUID()
            try await app.testing { client in
                let response = try await client.send(.post, to: URI(string: V2VaporDeviceRevocationCapabilityRoutes.path), beforeSend: { request in
                // Any new account headers are irrelevant to this request.
                request.headers.bearerAuthorization = .init(token: "unrelated-new-account-access")
                request.headers[HTTPField.Name("X-IM-Device-ID")!] = UUID().uuidString
                try request.content.encode(V2DeviceRevocationCapabilityHTTPRequest(credential: credential, operationID: operation))
            })
                #expect(response.status.code == (status == 208 ? 204 : status))
                #expect(response.headers[.cacheControl] == "no-store")
                #expect(response.headers[.pragma] == "no-cache")
                #expect((try await response.body.data() ?? Data()).isEmpty)
            }
            let request = await service.request()
            #expect(request?.0 == credential)
            #expect(request?.1 == operation)
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test("Rejects caller targets, invalid inputs and oversized bodies before redemption", arguments: [
        "deviceID", "userID", "null-target", "missing", "malformed", "invalid-credential", "invalid-operation", "oversized", "oversized-form", "form"
    ])
    func inputValidation(scenario: String) async throws {
        let app = try await Application(.testing)
        do {
            let service = RevocationRouteRecorder(status: 204)
            V2VaporDeviceRevocationCapabilityRoutes(service: service).register(on: app)
            var body: [String: Any] = ["credential": V2DeviceRevocationCredential.generate().rawValue, "operationID": UUID().uuidString]
            switch scenario {
            case "deviceID", "userID": body[scenario] = UUID().uuidString
            case "null-target": body["deviceID"] = NSNull()
            case "missing": body.removeValue(forKey: "credential")
            case "invalid-credential": body["credential"] = "ordinary-refresh-token"
            case "invalid-operation": body["operationID"] = "not-a-uuid"
            case "oversized", "oversized-form": body["credential"] = String(repeating: "a", count: 2_048)
            default: break
            }
            let data: Data
            if scenario == "form" || scenario == "oversized-form" {
                data = Data("credential=\(body["credential"] as! String)&operationID=\(body["operationID"] as! String)".utf8)
            } else {
                data = scenario == "malformed" ? Data("{".utf8) : try JSONSerialization.data(withJSONObject: body)
            }
            try await app.testing { client in
                let response = try await client.send(.post, to: URI(string: V2VaporDeviceRevocationCapabilityRoutes.path), beforeSend: { request in
                request.headers[.contentType] = scenario == "form" || scenario == "oversized-form" ? "application/x-www-form-urlencoded" : "application/json"
                request.body = .init(data: data)
            })
                #expect(response.status == (scenario == "oversized" || scenario == "oversized-form" ? .contentTooLarge : .badRequest))
            }
            #expect(await service.request() == nil)
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test("Trusted edge and address budget fence redemption", arguments: ["missing-proof", "limited", "limiter-failed", "allowed"])
    func middleware(scenario: String) async throws {
        let app = try await Application(.testing)
        do {
            let proof = Data(repeating: 0x41, count: 32).base64EncodedString()
            app.middleware.use(V2AccountEdgeAuthenticationMiddleware(secret: try .init(base64Encoded: proof)))
            app.middleware.use(V2AccountEdgeClientRateLimitMiddleware(limiter: RevocationRouteLimiter(scenario: scenario),
                limitedPaths: [V2VaporDeviceRevocationCapabilityRoutes.path]))
            let service = RevocationRouteRecorder(status: 204)
            V2VaporDeviceRevocationCapabilityRoutes(service: service).register(on: app)
            try await app.testing { client in
                let response = try await client.send(.post, to: URI(string: V2VaporDeviceRevocationCapabilityRoutes.path), beforeSend: { request in
                if scenario != "missing-proof" {
                    request.headers[V2AccountEdgeAuthenticationMiddleware.headerName] = proof
                    request.headers[V2AccountEdgeAuthenticationMiddleware.clientAddressHeaderName] = "192.0.2.15"
                }
                try request.content.encode(V2DeviceRevocationCapabilityHTTPRequest(credential: .generate(), operationID: UUID()))
            })
                let expected: HTTPResponse.Status = scenario == "missing-proof" ? .forbidden : scenario == "limited" ? .tooManyRequests : scenario == "limiter-failed" ? .serviceUnavailable : .noContent
                #expect(response.status == expected)
                if scenario == "limited" { #expect(response.headers[.retryAfter] == "19") }
            }
            #expect((await service.request() != nil) == (scenario == "allowed"))
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }
}

private actor RevocationRouteRecorder: V2DeviceRevocationCapabilityRedeeming {
    let status: Int
    private var recorded: (V2DeviceRevocationCredential, UUID)?
    init(status: Int) { self.status = status }
    func redeem(_ credential: V2DeviceRevocationCredential, operationID: UUID) throws -> V2DeviceRevocationCapabilityOutcome {
        recorded = (credential, operationID)
        switch status {
        case 204: return .applied
        case 208: return .idempotent
        case 401: return .invalidCredential
        case 410: return .expired
        case 409: return .operationConflict
        default: throw V2DeviceSessionServiceError.unavailable
        }
    }
    func request() -> (V2DeviceRevocationCredential, UUID)? { recorded }
}

private struct RevocationRouteLimiter: V2AccountEdgeClientRateLimiting {
    let scenario: String
    func consume(address: V2AccountEdgeClientAddress) throws -> V2AccountEdgeClientRateLimitResult {
        if scenario == "limiter-failed" { throw V2DeviceSessionServiceError.unavailable }
        return scenario == "limited" ? .rateLimited(retryAfterSeconds: 19) : .allowed
    }
}
