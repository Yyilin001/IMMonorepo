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
        let app = try await Application.make(.testing)
        let service = LifecycleSpy()
        V2PasswordLifecycleRoutes(service: service).register(on: app)
        do {
            try await app.testing().test(.POST, "v2/account-auth/password/\(action)", beforeRequest: { request in
                try request.content.encode(["accountHandle": "account", "deviceID": UUID().uuidString,
                    "currentPassword": "current-password", "newPassword": "replacement-password", "recoveryCode": String(repeating: "a", count: 64)])
            }) { response async in
                #expect(response.status == .noContent)
                #expect(response.body.readableBytes == 0)
                #expect(response.headers.first(name: .cacheControl) == "no-store")
            }
            #expect(await service.action == action)
            try await app.asyncShutdown()
        } catch { try? await app.asyncShutdown(); throw error }
    }

    @Test("missing factor fields are rejected before service invocation")
    func missingInput() async throws {
        let app = try await Application.make(.testing)
        let service = LifecycleSpy()
        V2PasswordLifecycleRoutes(service: service).register(on: app)
        do {
            try await app.testing().test(.POST, "v2/account-auth/password/recover", beforeRequest: { request in
                try request.content.encode(["accountHandle": "account", "deviceID": UUID().uuidString])
            }) { response async in #expect(response.status == .badRequest) }
            #expect(await service.action == nil)
            try await app.asyncShutdown()
        } catch { try? await app.asyncShutdown(); throw error }
    }

    @Test("factor throttling preserves the server retry interval")
    func rateLimit() async throws {
        let app = try await Application.make(.testing)
        V2PasswordLifecycleRoutes(service: LifecycleSpy(rejection: .rateLimited(17))).register(on: app)
        do {
            try await app.testing().test(.POST, "v2/account-auth/password/change", beforeRequest: { request in
                try request.content.encode(["accountHandle": "account", "deviceID": UUID().uuidString,
                    "currentPassword": "current-password", "newPassword": "replacement-password"])
            }) { response async in
                #expect(response.status == .tooManyRequests)
                #expect(response.headers.first(name: "Retry-After") == "17")
                #expect(response.headers.first(name: .cacheControl) == "no-store")
            }
            try await app.asyncShutdown()
        } catch { try? await app.asyncShutdown(); throw error }
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
