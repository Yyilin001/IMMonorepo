import HTTPTypes
import Foundation
import IMV2Core
import IMV2Server
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("Password lifecycle HTTP contract", .serialized)
struct V2PasswordLifecycleRoutesTests {
    @Test("all actions map to the service and return empty no-store confirmation", arguments: ["change", "recover", "recovery-code"])
    func success(_ action: String) async throws {
        let app = try await Application(.testing)
        let service = LifecycleSpy()
        V2PasswordLifecycleRoutes(service: service).register(on: app)
        do {
            try await app.testing { client in
                let response = try await client.send(.post, to: URI(string: "v2/account-auth/password/\(action)"), beforeSend: { request in
                try request.content.encode(["accountHandle": "account", "deviceID": UUID().uuidString,
                    "currentPassword": "current-password", "newPassword": "replacement-password", "recoveryCode": String(repeating: "a", count: 64)])
            })
                #expect(response.status == .noContent)
                #expect((try await response.body.data() ?? Data()).isEmpty)
                #expect(response.headers[.cacheControl] == "no-store")
            }
            #expect(await service.action == action)
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test("missing factor fields are rejected before service invocation")
    func missingInput() async throws {
        let app = try await Application(.testing)
        let service = LifecycleSpy()
        V2PasswordLifecycleRoutes(service: service).register(on: app)
        do {
            try await app.testing { client in
                let response = try await client.send(.post, to: "v2/account-auth/password/recover", beforeSend: { request in
                try request.content.encode(["accountHandle": "account", "deviceID": UUID().uuidString])
            })
 #expect(response.status == .badRequest)
            }
            #expect(await service.action == nil)
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test("factor throttling preserves the server retry interval")
    func rateLimit() async throws {
        let app = try await Application(.testing)
        V2PasswordLifecycleRoutes(service: LifecycleSpy(rejection: .rateLimited(17))).register(on: app)
        do {
            try await app.testing { client in
                let response = try await client.send(.post, to: "v2/account-auth/password/change", beforeSend: { request in
                try request.content.encode(["accountHandle": "account", "deviceID": UUID().uuidString,
                    "currentPassword": "current-password", "newPassword": "replacement-password"])
            })
                #expect(response.status == .tooManyRequests)
                #expect(response.headers[.retryAfter] == "17")
                #expect(response.headers[.cacheControl] == "no-store")
            }
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test("a running HTTP request over the password body limit remains a 413", arguments: ["application/json", "text/plain"])
    func oversizedDecodedBody(contentType: String) async throws {
        try await withApp { app in
            let service = LifecycleSpy()
            V2PasswordLifecycleRoutes(service: service).register(on: app)
            let body = "{\"accountHandle\":\"account\",\"deviceID\":\"\(UUID().uuidString)\",\"currentPassword\":\"\(String(repeating: "x", count: 9_000))\",\"newPassword\":\"replacement-password\"}"

            try await app.testing(.running) { client in
                let response = try await client.post("v2/account-auth/password/change", headers: [.contentType: contentType]) {
                    $0.body = .init(string: body)
                }
                #expect(response.status == .contentTooLarge)
                #expect(response.headers[.cacheControl] == "no-store")
                #expect((try await response.body.data() ?? Data()).isEmpty)
            }
            #expect(await service.action == nil)
        }
    }
}

private actor LifecycleSpy: V2PasswordLifecycleManaging {
    private(set) var action: String?
    let rejection: V2PasswordLifecycleError?
    init(rejection: V2PasswordLifecycleError? = nil) { self.rejection = rejection }
    private func record(_ value: String) throws { if let rejection { throw rejection }; action = value }
    func setRecoveryCode(accountHandle: String, password: String, recoveryCode: String, deviceID: DeviceID) throws { try record("recovery-code") }
    func changePassword(accountHandle: String, currentPassword: String, newPassword: String, deviceID: DeviceID) throws { try record("change") }
    func resetPassword(accountHandle: String, recoveryCode: String, newPassword: String, deviceID: DeviceID) throws { try record("recover") }
}
