import Foundation
import IMV2Core
import IMV2Server
@testable import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 Vapor Push endpoint routes")
struct V2VaporPushEndpointRoutesTests {
    @Test("authenticated device registers an opaque endpoint with no-store semantics")
    func authenticatedDeviceRegistersEndpoint() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let user = try UserID("00000000-0000-0000-0000-000000000811")
        let device = try DeviceID("00000000-0000-0000-0000-000000000812")
        let store = RoutePushEndpointStore()
        V2VaporPushEndpointRoutes(
            authenticator: RoutePushAuthenticator(userID: user),
            store: store,
            now: { Date(timeIntervalSince1970: 100) }
        ).register(on: app)

        let body = V2PushEndpointHTTPRequest(
            provider: .apns,
            environment: .development,
            token: String(repeating: "a", count: 64)
        )
        try await app.testing().test(.PUT, "v2/push-endpoint", headers: [
            "Authorization": "Bearer access-token",
            "X-IM-Device-ID": device.rawValue,
        ], beforeRequest: { request in
            try request.content.encode(body)
        }) { response async in
            #expect(response.status == .noContent)
            #expect(response.headers.first(name: .cacheControl) == "no-store")
            #expect(response.headers.first(name: "Pragma") == "no-cache")
            #expect(!response.body.string.contains(body.token))
        }
        let registration = try #require(await store.registrations().first)
        #expect(registration.userID == user)
        #expect(registration.deviceID == device)
        #expect(registration.endpoint.token == body.token)
    }

    @Test("malformed or unauthenticated endpoint registration is rejected")
    func rejectsInvalidRequests() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        V2VaporPushEndpointRoutes(
            authenticator: RoutePushAuthenticator(userID: try .init("user"), accepts: false),
            store: RoutePushEndpointStore()
        ).register(on: app)
        let tester = try app.testing()
        try await tester.test(.PUT, "v2/push-endpoint") { response async in
            #expect(response.status == .unauthorized)
        }
        try await tester.test(.PUT, "v2/push-endpoint", headers: [
            "Authorization": "Bearer rejected",
            "X-IM-Device-ID": "device",
        ]) { response async in
            #expect(response.status == .unauthorized)
        }
    }
}

private actor RoutePushEndpointStore: V2PushDeviceEndpointStore {
    struct Registration: Sendable {
        let userID: UserID
        let deviceID: DeviceID
        let endpoint: V2PushDeviceEndpointRegistration
    }

    private var received: [Registration] = []

    func register(
        actorUserID: UserID,
        deviceID: DeviceID,
        endpoint: V2PushDeviceEndpointRegistration,
        now _: Date
    ) {
        received.append(.init(userID: actorUserID, deviceID: deviceID, endpoint: endpoint))
    }

    func endpoint(for _: DeviceID) -> V2PushDeviceEndpoint? { nil }
    func disable(_: V2PushDeviceEndpoint, now _: Date) {}
    func registrations() -> [Registration] { received }
}

private struct RoutePushAuthenticator: V2GatewayAuthenticator {
    let userID: UserID
    var accepts = true

    func authenticate(accessToken: String, deviceID _: DeviceID) throws -> UserID {
        guard accepts, accessToken == "access-token" else { throw RoutePushAuthenticationFailure.denied }
        return userID
    }
}

private enum RoutePushAuthenticationFailure: Error {
    case denied
}
