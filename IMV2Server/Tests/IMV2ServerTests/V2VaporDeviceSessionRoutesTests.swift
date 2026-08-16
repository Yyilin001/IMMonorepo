import Foundation
import IMV2Core
import IMV2Server
@testable import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 Vapor device-session routes")
struct V2VaporDeviceSessionRoutesTests {
    @Test("inventory is owner-authenticated, no-store, and labels only the current device")
    func listsOwnerSessions() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let userID = try UserID("00000000-0000-0000-0000-000000000801")
        let currentID = try DeviceID("00000000-0000-0000-0000-000000000802")
        let otherID = try DeviceID("00000000-0000-0000-0000-000000000803")
        V2VaporDeviceSessionRoutes(
            authenticator: DeviceSessionRouteAuthenticator(userID: userID),
            sessions: DeviceSessionRouteStore(values: [
                .init(deviceID: currentID, displayName: "Current iPhone", platform: "iPhone", createdAt: .distantPast, lastActiveAt: .distantFuture),
                .init(deviceID: otherID, displayName: "Other iPad", platform: "iPad", createdAt: .distantPast, lastActiveAt: .distantPast)
            ])
        ).register(on: app)

        try await app.testing().test(.GET, "v2/devices", beforeRequest: { request in
            request.headers.bearerAuthorization = .init(token: "opaque-token")
            request.headers.replaceOrAdd(name: "X-IM-Device-ID", value: currentID.rawValue)
        }) { response async in
            #expect(response.status == .ok)
            #expect(response.headers.first(name: .cacheControl) == "no-store")
            var page: V2DeviceSessionPageHTTPResponse?
            expectContent(V2DeviceSessionPageHTTPResponse.self, response) { page = $0 }
            #expect(page?.sessions.map(\.deviceID) == [currentID.rawValue, otherID.rawValue])
            #expect(page?.sessions.map(\.isCurrentDevice) == [true, false])
            #expect(page?.nextCursor == nil)
        }
    }

    @Test("remote revoke forwards the authenticated current device and durable operation")
    func revokesRequestedDevice() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let userID = try UserID("00000000-0000-0000-0000-000000000811")
        let currentID = try DeviceID("00000000-0000-0000-0000-000000000812")
        let otherID = try DeviceID("00000000-0000-0000-0000-000000000813")
        let store = DeviceSessionRouteStore(values: [])
        V2VaporDeviceSessionRoutes(authenticator: DeviceSessionRouteAuthenticator(userID: userID), sessions: store).register(on: app)
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000814")!

        try await app.testing().test(.POST, "v2/devices/revoke", beforeRequest: { request in
            request.headers.bearerAuthorization = .init(token: "opaque-token")
            request.headers.replaceOrAdd(name: "X-IM-Device-ID", value: currentID.rawValue)
            try request.content.encode(V2DeviceSessionMutationHTTPRequest(deviceID: otherID.rawValue, operationID: operationID))
        }) { response async in
            #expect(response.status == .noContent)
            #expect(response.headers.first(name: .cacheControl) == "no-store")
        }
        let request = try #require(await store.revokeRequest())
        #expect(request.actor == userID)
        #expect(request.current == currentID)
        #expect(request.target == otherID)
        #expect(request.operationID == operationID)
    }
}

private struct DeviceSessionRouteAuthenticator: V2GatewayAuthenticator {
    let userID: UserID
    func authenticateSession(accessToken: String, deviceID: DeviceID) throws -> V2GatewayAuthentication {
        guard accessToken == "opaque-token" else { throw V2GatewayAuthenticationError.unauthenticated }
        return .init(userID: userID, expiresAt: nil)
    }
}

private actor DeviceSessionRouteStore: V2DeviceSessionManaging {
    struct Request: Sendable { let actor: UserID; let current: DeviceID; let target: DeviceID; let operationID: UUID }
    private let values: [V2DeviceSession]
    private var recorded: Request?
    init(values: [V2DeviceSession]) { self.values = values }
    func sessions(for _: UserID, cursor _: String?, pageSize _: Int) -> V2DeviceSessionPage {
        .init(sessions: values, nextCursor: nil)
    }
    func revokeDevice(actorUserID: UserID, currentDeviceID: DeviceID, targetDeviceID: DeviceID, operationID: UUID) -> V2DeviceSessionMutationOutcome {
        recorded = .init(actor: actorUserID, current: currentDeviceID, target: targetDeviceID, operationID: operationID)
        return .applied
    }
    func revokeOtherDevices(actorUserID _: UserID, currentDeviceID _: DeviceID, operationID _: UUID) -> V2DeviceSessionMutationOutcome { .applied }
    func revokeRequest() -> Request? { recorded }
}
