import IMV2ServerApplication
import IMV2ServerContracts
import HTTPTypes
import Foundation
import IMV2Core
import IMV2Server
import IMV2ServerInfrastructure
@testable import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 Vapor Push endpoint routes")
struct V2VaporPushEndpointRoutesTests {
    @Test("authenticated device registers an opaque endpoint with no-store semantics")
    func authenticatedDeviceRegistersEndpoint() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
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
        try await app.testing { client in
            let response = try await client.send(.put, headers: [
            .authorization: "Bearer access-token",
            HTTPField.Name("X-IM-Device-ID")!: device.rawValue,
        ], to: "v2/push-endpoint", beforeSend: { request in
            try request.content.encode(body)
        })
            #expect(response.status == .noContent)
            #expect(response.headers[.cacheControl] == "no-store")
            #expect(response.headers[.pragma] == "no-cache")
            #expect(!(try await response.body.string() ?? "").contains(body.token))
        }
        let registration = try #require(await store.registrations().first)
        #expect(registration.userID == user)
        #expect(registration.deviceID == device)
        #expect(registration.endpoint.token == body.token)
    }

    @Test("authenticated delete disables by identity without reading provider material")
    func authenticatedDeviceDeletesEndpoint() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let user = try UserID("00000000-0000-0000-0000-000000000811")
        let device = try DeviceID("00000000-0000-0000-0000-000000000812")
        let store = RoutePushEndpointStore()
        V2VaporPushEndpointRoutes(
            authenticator: RoutePushAuthenticator(userID: user),
            store: store,
            now: { Date(timeIntervalSince1970: 100) }
        ).register(on: app)

        try await app.testing { client in
            let response = try await client.send(.delete, headers: [
            .authorization: "Bearer access-token",
            HTTPField.Name("X-IM-Device-ID")!: device.rawValue,
        ], to: "v2/push-endpoint")
            #expect(response.status == .noContent)
            #expect(response.headers[.cacheControl] == "no-store")
        }
        let deletion = try #require(await store.deletions().first)
        #expect(deletion.userID == user)
        #expect(deletion.deviceID == device)
        #expect(await store.endpointReadCount() == 0)
    }

    @Test("malformed or unauthenticated endpoint registration is rejected")
    func rejectsInvalidRequests() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        V2VaporPushEndpointRoutes(
            authenticator: RoutePushAuthenticator(userID: try .init("user"), accepts: false),
            store: RoutePushEndpointStore()
        ).register(on: app)

        try await app.testing { client in
            let response = try await client.send(.put, to: "v2/push-endpoint")
            #expect(response.status == .unauthorized)
        }
        try await app.testing { client in
            let response = try await client.send(.put, headers: [
            .authorization: "Bearer rejected",
            HTTPField.Name("X-IM-Device-ID")!: "device",
        ], to: "v2/push-endpoint")
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
    private var deleted: [(userID: UserID, deviceID: DeviceID)] = []
    private var reads = 0

    func register(
        actorUserID: UserID,
        deviceID: DeviceID,
        endpoint: V2PushDeviceEndpointRegistration,
        now _: Date
    ) {
        received.append(.init(userID: actorUserID, deviceID: deviceID, endpoint: endpoint))
    }

    func endpoint(for _: DeviceID) -> V2PushDeviceEndpoint? {
        reads += 1
        return nil
    }
    func disable(_: V2PushDeviceEndpoint, now _: Date) {}
    func disableOwnedEndpoint(actorUserID: UserID, deviceID: DeviceID, now _: Date) {
        deleted.append((actorUserID, deviceID))
    }
    func registrations() -> [Registration] { received }
    func deletions() -> [(userID: UserID, deviceID: DeviceID)] { deleted }
    func endpointReadCount() -> Int { reads }
}

private struct RoutePushAuthenticator: V2GatewayAuthenticator {
    let userID: UserID
    var accepts = true

    func authenticateSession(accessToken: String, deviceID _: DeviceID) throws -> V2GatewayAuthentication {
        guard accepts, accessToken == "access-token" else { throw V2GatewayAuthenticationError.unauthenticated }
        return .init(userID: userID, expiresAt: nil)
    }
}
