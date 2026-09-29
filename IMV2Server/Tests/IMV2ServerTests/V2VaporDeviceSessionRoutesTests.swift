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

@Suite("V2 Vapor device-session routes")
struct V2VaporDeviceSessionRoutesTests {
    @Test("session mutation clock failures return a no-store unavailable response", arguments: ["remote-revocations/submit", "revoke-current", "remote-revocations/operations/recover"])
    func mutationClockFailureResponse(path: String) async throws {
        let app = try await Application(.testing)
        do {
            let user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
            let target = DeviceID(uuid: UUID())
            let store = DeviceSessionRouteStore(values: [], failure: .unavailable)
            V2VaporDeviceSessionRoutes(authenticator: DeviceSessionRouteAuthenticator(userID: user), sessions: store).register(on: app)
            try await app.testing { client in
                let response = try await client.send(.post, to: URI(string: "v2/devices/\(path)"), beforeSend: { request in
                request.headers.bearerAuthorization = .init(token: "opaque-token")
                request.headers[HTTPField.Name("X-IM-Device-ID")!] = device.rawValue
                if path == "revoke-current" { try request.content.encode(V2DeviceSessionMutationHTTPRequest(operationID: UUID())) }
                else {
                    let command = try deviceRouteCommand(user: user, current: device, target: target)
                    if path.hasSuffix("recover") { try request.content.encode(V2RemoteDeviceRevocationRecoveryRequest(command: command, action: .query), as: .json) }
                    else { try request.content.encode(command, as: .json) }
                }
            })
                #expect(response.status == .serviceUnavailable)
                #expect(response.headers[.cacheControl] == "no-store")
                #expect(response.headers[.pragma] == "no-cache")
                #expect(!(try await response.body.string() ?? "").contains(device.rawValue))
                #expect(!(try await response.body.string() ?? "").contains(target.rawValue))
            }
            #expect(await store.revokeRequest() == nil)
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test("inventory errors preserve no-store and distinguish invalid paging from service failure", arguments: [V2DeviceSessionServiceError.invalidRequest, .unavailable, .malformedPersistence])
    func inventoryFailureHeaders(error: V2DeviceSessionServiceError) async throws {
        let app = try await Application(.testing)
        do {
            let user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
            let store = DeviceSessionRouteStore(values: [], failure: error)
            V2VaporDeviceSessionRoutes(authenticator: DeviceSessionRouteAuthenticator(userID: user), sessions: store).register(on: app)
            for path in ["v2/devices", "v2/devices?page_size=0", "v2/devices?page_size=invalid"] {
                try await app.testing { client in
                    let response = try await client.send(.get, to: URI(string: path), beforeSend: { request in
                    request.headers.bearerAuthorization = .init(token: "opaque-token")
                    request.headers[HTTPField.Name("X-IM-Device-ID")!] = device.rawValue
                })
                    #expect(response.status == (path != "v2/devices" || error == .invalidRequest ? .badRequest : .serviceUnavailable))
                    #expect(response.headers[.cacheControl] == "no-store")
                    #expect(response.headers[.pragma] == "no-cache")
                    #expect(!(try await response.body.string() ?? "").contains(device.rawValue))
                }
            }
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test("current-device logout takes its target only from authenticated identity", arguments: [false, true])
    func currentDeviceLogoutRejectsCallerTarget(includeTarget: Bool) async throws {
        let app = try await Application(.testing)
        do {
            let user = UserID(uuid: UUID()); let current = DeviceID(uuid: UUID())
            let store = DeviceSessionRouteStore(values: [])
            let operation = UUID()
            V2VaporDeviceSessionRoutes(authenticator: DeviceSessionRouteAuthenticator(userID: user), sessions: store).register(on: app)
            try await app.testing { client in
                let response = try await client.send(.post, to: "v2/devices/revoke-current", beforeSend: { request in
                request.headers.bearerAuthorization = .init(token: "opaque-token")
                request.headers[HTTPField.Name("X-IM-Device-ID")!] = current.rawValue
                try request.content.encode(V2DeviceSessionMutationHTTPRequest(deviceID: includeTarget ? UUID().uuidString : nil, operationID: operation))
            })
                #expect(response.status == (includeTarget ? .badRequest : .noContent))
                if !includeTarget { #expect(response.headers[.cacheControl] == "no-store") }
            }
            let recorded = await store.revokeRequest()
            if includeTarget { #expect(recorded == nil) }
            else {
                #expect(recorded?.actor == user)
                #expect(recorded?.current == current)
                #expect(recorded?.target == current)
                #expect(recorded?.operationID == operation)
            }
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test("current-device logout cannot run without a valid account credential")
    func currentDeviceLogoutRequiresAuthentication() async throws {
        let app = try await Application(.testing)
        do {
            let store = DeviceSessionRouteStore(values: [])
            V2VaporDeviceSessionRoutes(authenticator: DeviceSessionRouteAuthenticator(userID: .init(uuid: UUID())), sessions: store).register(on: app)
            try await app.testing { client in
                let response = try await client.send(.post, to: "v2/devices/revoke-current", beforeSend: { request in
                request.headers.bearerAuthorization = .init(token: "invalid")
                request.headers[HTTPField.Name("X-IM-Device-ID")!] = UUID().uuidString
                try request.content.encode(V2DeviceSessionMutationHTTPRequest(operationID: UUID()))
            })
 #expect(response.status == .unauthorized)
            }
            #expect(await store.revokeRequest() == nil)
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test("inventory rejects invalid dates without terminating HTTP", arguments: [
        Double(Int64.max) / 1_000, Double(Int64.min).nextDown / 1_000,
        Double.infinity, -Double.infinity, Double.nan
    ], [false, true])
    func rejectsUnrepresentableTimestamp(seconds: Double, lastActive: Bool) async throws {
        let app = try await Application(.testing)
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
            try await app.testing { client in
                let response = try await client.send(.get, to: "v2/devices", beforeSend: { request in
                request.headers.bearerAuthorization = .init(token: "opaque-token")
                request.headers[HTTPField.Name("X-IM-Device-ID")!] = device.rawValue
            })
                #expect(response.status == .serviceUnavailable)
                #expect(response.headers[.cacheControl] == "no-store")
                #expect(response.headers[.pragma] == "no-cache")
                #expect(!(try await response.body.string() ?? "").contains(device.rawValue))
                #expect(!(try await response.body.string() ?? "").contains("First"))
            }
            await store.replaceValues([.init(deviceID: device, displayName: "Recovered", platform: "test", createdAt: .init(timeIntervalSince1970: -1.00025), lastActiveAt: .init(timeIntervalSince1970: 1_750_000_000.125))])
            try await app.testing { client in
                let response = try await client.send(.get, to: "v2/devices", beforeSend: { request in
                request.headers.bearerAuthorization = .init(token: "opaque-token")
                request.headers[HTTPField.Name("X-IM-Device-ID")!] = device.rawValue
            })
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-store")
                let page = try await response.content.decode(V2DeviceSessionPageHTTPResponse.self)
                #expect(page.sessions.first?.createdAtMilliseconds == -1_000)
                #expect(page.sessions.first?.lastActiveAtMilliseconds == 1_750_000_000_125)
                #expect(page.sessions.first?.isCurrentDevice == true)
            }
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test("inventory is owner-authenticated, no-store, and labels only the current device")
    func listsOwnerSessions() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
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

        try await app.testing { client in
            let response = try await client.send(.get, to: "v2/devices", beforeSend: { request in
            request.headers.bearerAuthorization = .init(token: "opaque-token")
            request.headers[HTTPField.Name("X-IM-Device-ID")!] = currentID.rawValue
        })
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "no-store")
            var page: V2DeviceSessionPageHTTPResponse?
            page = try await response.content.decode(V2DeviceSessionPageHTTPResponse.self)
            #expect(page?.sessions.map(\.deviceID) == [currentID.rawValue, otherID.rawValue])
            #expect(page?.sessions.map(\.isCurrentDevice) == [true, false])
            #expect(page?.nextCursor == nil)
        }
    }

    @Test("remote revoke forwards the authenticated current device and durable operation")
    func revokesRequestedDevice() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let userID = try UserID("00000000-0000-0000-0000-000000000811")
        let currentID = try DeviceID("00000000-0000-0000-0000-000000000812")
        let otherID = try DeviceID("00000000-0000-0000-0000-000000000813")
        let store = DeviceSessionRouteStore(values: [])
        V2VaporDeviceSessionRoutes(authenticator: DeviceSessionRouteAuthenticator(userID: userID), sessions: store).register(on: app)
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000814")!

        try await app.testing { client in
            let response = try await client.send(.post, to: "v2/devices/remote-revocations/submit", beforeSend: { request in
            request.headers.bearerAuthorization = .init(token: "opaque-token")
            request.headers[HTTPField.Name("X-IM-Device-ID")!] = currentID.rawValue
            try request.content.encode(deviceRouteCommand(user: userID, current: currentID, target: otherID, operation: operationID), as: .json)
        })
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "no-store")
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
    func remoteRevocationBaseline(actorUserID: UserID, currentDeviceID: DeviceID) throws -> V2RemoteDeviceRevocationBaseline {
        if let failure { throw failure }
        return try .init(id: UUID(), actorUserID: actorUserID, currentDeviceID: currentDeviceID,
            targetDeviceIDs: values.map(\.deviceID).filter { $0 != currentDeviceID }.sorted { $0.rawValue < $1.rawValue },
            issuedAtMilliseconds: 1_750_000_000_000, expiresAtMilliseconds: 1_750_000_120_000)
    }
    func submitRemoteRevocation(_ command: V2RemoteDeviceRevocationCommand) throws -> V2RemoteDeviceRevocationResult {
        if let failure { throw failure }
        if let target = command.targetDeviceIDs.first { recorded = .init(actor: command.baseline.actorUserID, current: command.baseline.currentDeviceID, target: target, operationID: command.operationID) }
        return .receipt(try .init(command: command, outcome: .revoked, resolvedAtMilliseconds: 1_750_000_000_001))
    }
    func recoverRemoteRevocation(_ request: V2RemoteDeviceRevocationRecoveryRequest) throws -> V2RemoteDeviceRevocationResult {
        if let failure { throw failure }
        return .unresolved
    }
    func revokeCurrentDevice(actorUserID: UserID, currentDeviceID: DeviceID, operationID: UUID) throws -> V2DeviceSessionMutationOutcome {
        if let failure { throw failure }
        recorded = .init(actor: actorUserID, current: currentDeviceID, target: currentDeviceID, operationID: operationID)
        return .applied
    }
    func revokeRequest() -> Request? { recorded }
}

private func deviceRouteCommand(user: UserID, current: DeviceID, target: DeviceID, operation: UUID = UUID()) throws -> V2RemoteDeviceRevocationCommand {
    let baseline = try V2RemoteDeviceRevocationBaseline(id: UUID(), actorUserID: user, currentDeviceID: current,
        targetDeviceIDs: [target], issuedAtMilliseconds: 1_750_000_000_000, expiresAtMilliseconds: 1_750_000_120_000)
    return try .init(operationID: operation, baseline: baseline, selection: .device(target), firstSubmissionDeadlineMilliseconds: baseline.expiresAtMilliseconds)
}
