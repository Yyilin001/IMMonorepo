import Foundation
import IMV2Core
import IMV2Server
@testable import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 Vapor device-session routes")
struct V2VaporDeviceSessionRoutesTests {
    @Test("session mutation clock failures return a no-store unavailable response", arguments: ["revoke", "revoke-current", "revoke-others"])
    func mutationClockFailureResponse(path: String) async throws {
        let app = try await Application.make(.testing)
        do {
            let user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
            let target = DeviceID(uuid: UUID())
            let store = DeviceSessionRouteStore(values: [], failure: .unavailable)
            V2VaporDeviceSessionRoutes(authenticator: DeviceSessionRouteAuthenticator(userID: user), sessions: store).register(on: app)
            try await app.testing().test(.POST, "v2/devices/\(path)", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "opaque-token")
                request.headers.replaceOrAdd(name: "X-IM-Device-ID", value: device.rawValue)
                try request.content.encode(V2DeviceSessionMutationHTTPRequest(deviceID: path == "revoke" ? target.rawValue : nil, operationID: UUID()))
            }) { response async in
                #expect(response.status == .serviceUnavailable)
                #expect(response.headers.first(name: .cacheControl) == "no-store")
                #expect(response.headers.first(name: "Pragma") == "no-cache")
                #expect(!response.body.string.contains(device.rawValue))
                #expect(!response.body.string.contains(target.rawValue))
            }
            #expect(await store.revokeRequest() == nil)
            try await app.asyncShutdown()
        } catch { try? await app.asyncShutdown(); throw error }
    }

    @Test("inventory errors preserve no-store and distinguish invalid paging from service failure", arguments: [V2DeviceSessionServiceError.invalidRequest, .unavailable, .malformedPersistence])
    func inventoryFailureHeaders(error: V2DeviceSessionServiceError) async throws {
        let app = try await Application.make(.testing)
        do {
            let user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
            let store = DeviceSessionRouteStore(values: [], failure: error)
            V2VaporDeviceSessionRoutes(authenticator: DeviceSessionRouteAuthenticator(userID: user), sessions: store).register(on: app)
            for path in ["v2/devices", "v2/devices?page_size=0", "v2/devices?page_size=invalid"] {
                try await app.testing().test(.GET, path, beforeRequest: { request in
                    request.headers.bearerAuthorization = .init(token: "opaque-token")
                    request.headers.replaceOrAdd(name: "X-IM-Device-ID", value: device.rawValue)
                }) { response async in
                    #expect(response.status == (path != "v2/devices" || error == .invalidRequest ? .badRequest : .serviceUnavailable))
                    #expect(response.headers.first(name: .cacheControl) == "no-store")
                    #expect(response.headers.first(name: "Pragma") == "no-cache")
                    #expect(!response.body.string.contains(device.rawValue))
                }
            }
            try await app.asyncShutdown()
        } catch { try? await app.asyncShutdown(); throw error }
    }

    @Test("current-device logout takes its target only from authenticated identity", arguments: [false, true])
    func currentDeviceLogoutRejectsCallerTarget(includeTarget: Bool) async throws {
        let app = try await Application.make(.testing)
        do {
            let user = UserID(uuid: UUID()); let current = DeviceID(uuid: UUID())
            let store = DeviceSessionRouteStore(values: [])
            let operation = UUID()
            V2VaporDeviceSessionRoutes(authenticator: DeviceSessionRouteAuthenticator(userID: user), sessions: store).register(on: app)
            try await app.testing().test(.POST, "v2/devices/revoke-current", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "opaque-token")
                request.headers.replaceOrAdd(name: "X-IM-Device-ID", value: current.rawValue)
                try request.content.encode(V2DeviceSessionMutationHTTPRequest(deviceID: includeTarget ? UUID().uuidString : nil, operationID: operation))
            }) { response async in
                #expect(response.status == (includeTarget ? .badRequest : .noContent))
                if !includeTarget { #expect(response.headers.first(name: .cacheControl) == "no-store") }
            }
            let recorded = await store.revokeRequest()
            if includeTarget { #expect(recorded == nil) }
            else {
                #expect(recorded?.actor == user)
                #expect(recorded?.current == current)
                #expect(recorded?.target == current)
                #expect(recorded?.operationID == operation)
            }
            try await app.asyncShutdown()
        } catch { try? await app.asyncShutdown(); throw error }
    }

    @Test("current-device logout cannot run without a valid account credential")
    func currentDeviceLogoutRequiresAuthentication() async throws {
        let app = try await Application.make(.testing)
        do {
            let store = DeviceSessionRouteStore(values: [])
            V2VaporDeviceSessionRoutes(authenticator: DeviceSessionRouteAuthenticator(userID: .init(uuid: UUID())), sessions: store).register(on: app)
            try await app.testing().test(.POST, "v2/devices/revoke-current", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "invalid")
                request.headers.replaceOrAdd(name: "X-IM-Device-ID", value: UUID().uuidString)
                try request.content.encode(V2DeviceSessionMutationHTTPRequest(operationID: UUID()))
            }) { response async in #expect(response.status == .unauthorized) }
            #expect(await store.revokeRequest() == nil)
            try await app.asyncShutdown()
        } catch { try? await app.asyncShutdown(); throw error }
    }

    @Test("inventory rejects invalid dates without terminating HTTP", arguments: [
        Double(Int64.max) / 1_000, Double(Int64.min).nextDown / 1_000,
        Double.infinity, -Double.infinity, Double.nan
    ], [false, true])
    func rejectsUnrepresentableTimestamp(seconds: Double, lastActive: Bool) async throws {
        let app = try await Application.make(.testing)
        do {
            let user = UserID(uuid: UUID()); let device = DeviceID(uuid: UUID())
            let invalid = Date(timeIntervalSince1970: seconds)
            let store = DeviceSessionRouteStore(values: [
                .init(deviceID: .init(uuid: UUID()), displayName: "First", platform: "test", createdAt: .distantPast, lastActiveAt: .distantPast),
                .init(deviceID: device, displayName: "Test", platform: "test",
                      createdAt: lastActive ? .distantPast : invalid,
                      lastActiveAt: lastActive ? invalid : .distantPast)
            ])
            V2VaporDeviceSessionRoutes(authenticator: DeviceSessionRouteAuthenticator(userID: user), sessions: store).register(on: app)
            try await app.testing().test(.GET, "v2/devices", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "opaque-token")
                request.headers.replaceOrAdd(name: "X-IM-Device-ID", value: device.rawValue)
            }) { response async in
                #expect(response.status == .serviceUnavailable)
                #expect(response.headers.first(name: .cacheControl) == "no-store")
                #expect(response.headers.first(name: "Pragma") == "no-cache")
                #expect(!response.body.string.contains(device.rawValue))
                #expect(!response.body.string.contains("First"))
            }
            await store.replaceValues([.init(deviceID: device, displayName: "Recovered", platform: "test", createdAt: .init(timeIntervalSince1970: -1.00025), lastActiveAt: .init(timeIntervalSince1970: 1_750_000_000.125))])
            try await app.testing().test(.GET, "v2/devices", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "opaque-token")
                request.headers.replaceOrAdd(name: "X-IM-Device-ID", value: device.rawValue)
            }) { response async in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: .cacheControl) == "no-store")
                expectContent(V2DeviceSessionPageHTTPResponse.self, response) { page in
                    #expect(page.sessions.first?.createdAtMilliseconds == -1_000)
                    #expect(page.sessions.first?.lastActiveAtMilliseconds == 1_750_000_000_125)
                    #expect(page.sessions.first?.isCurrentDevice == true)
                }
            }
            try await app.asyncShutdown()
        } catch { try? await app.asyncShutdown(); throw error }
    }

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
    private var values: [V2DeviceSession]
    private let failure: V2DeviceSessionServiceError?
    private var recorded: Request?
    init(values: [V2DeviceSession], failure: V2DeviceSessionServiceError? = nil) { self.values = values; self.failure = failure }
    func replaceValues(_ values: [V2DeviceSession]) { self.values = values }
    func sessions(for _: UserID, cursor _: String?, pageSize _: Int) throws -> V2DeviceSessionPage {
        if let failure { throw failure }
        return .init(sessions: values, nextCursor: nil)
    }
    func revokeDevice(actorUserID: UserID, currentDeviceID: DeviceID, targetDeviceID: DeviceID, operationID: UUID) throws -> V2DeviceSessionMutationOutcome {
        if let failure { throw failure }
        recorded = .init(actor: actorUserID, current: currentDeviceID, target: targetDeviceID, operationID: operationID)
        return .applied
    }
    func revokeCurrentDevice(actorUserID: UserID, currentDeviceID: DeviceID, operationID: UUID) throws -> V2DeviceSessionMutationOutcome {
        if let failure { throw failure }
        recorded = .init(actor: actorUserID, current: currentDeviceID, target: currentDeviceID, operationID: operationID)
        return .applied
    }
    func revokeOtherDevices(actorUserID _: UserID, currentDeviceID _: DeviceID, operationID _: UUID) throws -> V2DeviceSessionMutationOutcome {
        if let failure { throw failure }
        return .applied
    }
    func revokeRequest() -> Request? { recorded }
}
