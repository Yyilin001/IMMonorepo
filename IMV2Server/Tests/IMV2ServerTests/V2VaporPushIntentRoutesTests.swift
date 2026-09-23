import Foundation
import HTTPTypes
import IMV2Core
import IMV2Server
@testable import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("Versioned Push HTTP routes")
struct V2VaporPushIntentRoutesTests {
    @Test("authenticated metadata and writes bind the bearer device and never return provider data")
    func routesBindIdentity() async throws {
        let app = try await Application(.testing)
        do {
            let store = PushIntentRouteStore()
            let identity = PushIntentRouteAuthenticator()
            V2VaporPushIntentRoutes(authenticator: identity, store: store).register(on: app)

            let headers: HTTPFields = [.authorization: "Bearer access-token", HTTPField.Name("X-IM-Device-ID")!: identity.device.rawValue, .contentType: "application/json"]
            try await app.testing { client in
                let response = try await client.send(.get, headers: headers, to: "v2/push-endpoint/session")
                #expect(response.status == .ok)
                #expect(try await response.content.decode(V2PushIntentEpochHTTPResponse.self).epoch == 0)
                #expect(response.headers[.cacheControl] == "no-store")
            }
            let claim = UUID()
            try await app.testing { client in
                let response = try await client.send(.post, headers: headers, to: "v2/push-endpoint/session", beforeSend: { request in
                request.body = .init(string: "{\"requestID\":\"\(claim)\",\"expectedEpoch\":0}")
            })
                #expect(response.status == .ok)
                #expect(try await response.content.decode(V2PushIntentEpochHTTPResponse.self).epoch == 1)
            }
            let token = String(repeating: "a", count: 64)
            for body in ["{\"epoch\":1,\"revision\":2,\"enabled\":false}", "{\"epoch\":1,\"revision\":3,\"enabled\":true,\"provider\":\"apns\",\"environment\":\"development\",\"token\":\"\(token)\"}"] {
                try await app.testing { client in
                    let response = try await client.send(.put, headers: headers, to: "v2/push-endpoint/intent", beforeSend: { $0.body = .init(string: body) })
                    #expect(response.status == .noContent)
                    #expect((try await response.body.data() ?? Data()).isEmpty)
                    #expect(response.headers[.cacheControl] == "no-store")
                }
            }
            #expect(await store.users == [identity.user, identity.user, identity.user, identity.user])
            #expect(await store.devices == [identity.device, identity.device, identity.device, identity.device])
            #expect(await store.claim?.requestID == claim)
            #expect(await store.versions.map(\.revision) == [2, 3])
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test("invalid versions and intent shapes never reach storage; conditional failures remain distinct")
    func rejectsAndMaps() async throws {
        let app = try await Application(.testing)
        do {
            let store = PushIntentRouteStore()
            let identity = PushIntentRouteAuthenticator()
            V2VaporPushIntentRoutes(authenticator: identity, store: store).register(on: app)

            let headers: HTTPFields = [.authorization: "Bearer access-token", HTTPField.Name("X-IM-Device-ID")!: identity.device.rawValue, .contentType: "application/json"]
            for body in ["{}", "{\"epoch\":0,\"revision\":1,\"enabled\":false}", "{\"epoch\":1,\"revision\":18446744073709551615,\"enabled\":false}", "{\"epoch\":1,\"revision\":1,\"enabled\":true}", "{\"epoch\":1,\"revision\":1,\"enabled\":false,\"token\":\"secret\"}"] {
                try await app.testing { client in
                    let response = try await client.send(.put, headers: headers, to: "v2/push-endpoint/intent", beforeSend: { $0.body = .init(string: body) })
                    #expect(response.status == .badRequest)
                    #expect(response.headers[.cacheControl] == "no-store")
                    #expect(!(try await response.body.string() ?? "").contains("secret"))
                }
            }
            #expect(await store.users.isEmpty)
            for (failure, status, code) in [(V2PushDeviceEndpointError.staleIntent, 409, "stale_intent"), (.intentConflict, 409, "intent_conflict"), (.intentVersionRequired, 428, "intent_version_required"), (.deviceUnavailable, 403, "device_unavailable"), (.unavailable, 503, "unavailable")] {
                await store.fail(failure)
                try await app.testing { client in
                    let response = try await client.send(.put, headers: headers, to: "v2/push-endpoint/intent", beforeSend: { $0.body = .init(string: "{\"epoch\":1,\"revision\":1,\"enabled\":false}") })
                    #expect(response.status.code == status)
                    #expect((try await response.body.string() ?? "") == "{\"code\":\"\(code)\"}")
                    #expect(response.headers[.cacheControl] == "no-store")
                }
            }
            try await app.testing { client in
                let response = try await client.send(.get, to: "v2/push-endpoint/session")
                #expect(response.status == .unauthorized)
                #expect(response.headers[.cacheControl] == "no-store")
            }
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }
}

struct PushIntentRouteAuthenticator: V2GatewayAuthenticator {
    let user = UserID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000811")!)
    let device = DeviceID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000812")!)
    func authenticateSession(accessToken: String, deviceID: DeviceID) throws -> V2GatewayAuthentication {
        guard accessToken == "access-token", deviceID == device else { throw V2GatewayAuthenticationError.unauthenticated }
        return .init(userID: user, expiresAt: nil)
    }
}

private actor PushIntentRouteStore: V2PushEndpointIntentStoring {
    var users: [UserID] = []
    var devices: [DeviceID] = []
    var claim: V2PushIntentSessionClaim?
    var versions: [V2PushIntentVersion] = []
    var failure: V2PushDeviceEndpointError?
    func fail(_ error: V2PushDeviceEndpointError) { failure = error }
    func intentEpoch(actorUserID: UserID, deviceID: DeviceID) -> UInt64 {
        users.append(actorUserID); devices.append(deviceID); return 0
    }
    func claimIntentSession(actorUserID: UserID, deviceID: DeviceID, claim: V2PushIntentSessionClaim, now: Date) -> UInt64 {
        users.append(actorUserID); devices.append(deviceID); self.claim = claim; return claim.expectedEpoch + 1
    }
    func publishIntent(actorUserID: UserID, deviceID: DeviceID, version: V2PushIntentVersion, intent: V2PushEndpointIntent, now: Date) throws {
        if let failure { throw failure }
        users.append(actorUserID); devices.append(deviceID); versions.append(version)
    }
}
