import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("V2 realtime session coordinator")
struct V2RealtimeSessionCoordinatorTests {
    @Test("an expired access credential is refreshed before one coherent TLS handshake")
    func refreshesBeforeConnecting() async throws {
        let now = Date(timeIntervalSince1970: 1_750_001_000)
        let predecessor = try credentials(access: "old-access", refresh: "old-refresh", expiry: now.addingTimeInterval(-1))
        let successor = try credentials(access: "new-access", refresh: "new-refresh", expiry: now.addingTimeInterval(60))
        let auth = V2AuthSession(
            credentialStore: RealtimeCredentialStore(record: .init(credentials: predecessor)),
            transport: RealtimeRefreshTransport(result: .success(successor)),
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000702")! },
            now: { now }
        )
        let connection = RecordingRealtimeConnection(result: .success(session(for: successor)))
        let coordinator = V2RealtimeSessionCoordinator(
            authSession: auth,
            connection: connection,
            supportedCapabilityProfiles: ["standard"]
        )

        let established = try await coordinator.connect()

        #expect(established == session(for: successor))
        #expect(await connection.attempts() == [.init(accessToken: successor.accessToken, deviceID: successor.deviceID, profiles: ["standard"])])
    }

    @Test("terminal gateway rejection clears credentials and requires re-authentication")
    func terminalGatewayRejectionClearsSession() async throws {
        let now = Date(timeIntervalSince1970: 1_750_001_100)
        let current = try credentials(access: "current-access", refresh: "current-refresh", expiry: now.addingTimeInterval(60))
        let store = RealtimeCredentialStore(record: .init(credentials: current))
        let auth = V2AuthSession(credentialStore: store, transport: RealtimeRefreshTransport(result: .failure(V2AuthTransportError.terminalRejection)), now: { now })
        let coordinator = V2RealtimeSessionCoordinator(
            authSession: auth,
            connection: RecordingRealtimeConnection(result: .failure(V2TLSFrameConnectionError.authenticationFailed)),
            supportedCapabilityProfiles: ["standard"]
        )

        await #expect(throws: V2RealtimeSessionCoordinatorError.authenticationRequired) {
            _ = try await coordinator.connect()
        }
        #expect(await store.record() == nil)
        #expect(await auth.currentState() == .unauthenticated)
    }

    @Test("temporary gateway refusal preserves credentials and authenticated session epoch",
        arguments: ["SERVER_BUSY", "UNAVAILABLE"])
    func temporaryGatewayRefusalPreservesSession(code: String) async throws {
        let now = Date(timeIntervalSince1970: 1_750_001_100)
        let current = try credentials(access: "current-access", refresh: "current-refresh", expiry: now.addingTimeInterval(60))
        let store = RealtimeCredentialStore(record: .init(credentials: current))
        let auth = V2AuthSession(credentialStore: store,
            transport: RealtimeRefreshTransport(result: .failure(V2AuthTransportError.terminalRejection)), now: { now })
        let before = try await auth.realtimeCredentials()
        let error = V2RealtimeTransportError.server(code: code, retryable: true, retryAfterSeconds: 1, currentRevision: nil)
        let coordinator = V2RealtimeSessionCoordinator(authSession: auth,
            connection: RecordingRealtimeConnection(result: .failure(error)), supportedCapabilityProfiles: ["standard"])
        await #expect(throws: error) { _ = try await coordinator.connect() }
        #expect(await store.record() != nil)
        let after = try await auth.realtimeCredentials()
        #expect(after.sessionEpoch == before.sessionEpoch)
        #expect(after.accessToken == before.accessToken)
    }

    @Test("mismatched handshake identity is disconnected and never accepted")
    func rejectsIdentityMismatch() async throws {
        let now = Date(timeIntervalSince1970: 1_750_001_200)
        let current = try credentials(access: "current-access", refresh: "current-refresh", expiry: now.addingTimeInterval(60))
        let mismatch = V2AuthenticatedClientSession(
            userID: try .init("00000000-0000-0000-0000-000000000799"),
            deviceID: current.deviceID,
            protocolVersion: 1,
            capabilityProfile: "standard"
        )
        let connection = RecordingRealtimeConnection(result: .success(mismatch))
        let coordinator = V2RealtimeSessionCoordinator(
            authSession: V2AuthSession(credentialStore: RealtimeCredentialStore(record: .init(credentials: current)), transport: RealtimeRefreshTransport(result: .success(current)), now: { now }),
            connection: connection,
            supportedCapabilityProfiles: ["standard"]
        )

        await #expect(throws: V2RealtimeSessionCoordinatorError.identityMismatch) {
            _ = try await coordinator.connect()
        }
        #expect(await connection.disconnectCount() == 1)
    }

    @Test("terminal refresh rejection and missing restored credentials require authentication", arguments: [false, true])
    func terminalCredentialAcquisitionRequiresAuthentication(missingRecord: Bool) async throws {
        let now = Date(timeIntervalSince1970: 1_750_001_300)
        let expired = try credentials(access: "expired", refresh: "revoked", expiry: now.addingTimeInterval(-1))
        let store = RealtimeCredentialStore(record: missingRecord ? nil : .init(credentials: expired))
        let auth = V2AuthSession(credentialStore: store, transport: RealtimeRefreshTransport(result: .failure(V2AuthTransportError.terminalRejection)), now: { now })
        let connection = RecordingRealtimeConnection(result: .success(session(for: expired)))
        let coordinator = V2RealtimeSessionCoordinator(authSession: auth, connection: connection, supportedCapabilityProfiles: ["standard"])
        for _ in 0..<2 {
            await #expect(throws: V2RealtimeSessionCoordinatorError.authenticationRequired) {
                try await coordinator.connect()
            }
        }
        #expect(await store.record() == nil)
        #expect(await auth.currentState() == .unauthenticated)
        #expect(await connection.attempts().isEmpty)
    }

    @Test("a failed refresh network request preserves credentials and remains retryable")
    func transientCredentialFailureDoesNotBecomeLogout() async throws {
        let now = Date(timeIntervalSince1970: 1_750_001_300)
        let expired = try credentials(access: "expired", refresh: "valid", expiry: now.addingTimeInterval(-1))
        let store = RealtimeCredentialStore(record: .init(credentials: expired))
        let auth = V2AuthSession(credentialStore: store, transport: RealtimeRefreshTransport(result: .failure(URLError(.notConnectedToInternet))), now: { now })
        let connection = RecordingRealtimeConnection(result: .success(session(for: expired)))
        let coordinator = V2RealtimeSessionCoordinator(authSession: auth, connection: connection, supportedCapabilityProfiles: ["standard"])
        await #expect(throws: URLError.self) { try await coordinator.connect() }
        #expect(await store.record() != nil)
        #expect(await auth.currentState() != .unauthenticated)
        #expect(await connection.attempts().isEmpty)
    }

    private func credentials(access: String, refresh: String, expiry: Date) throws -> V2AuthCredentials {
        try .init(
            userID: .init("00000000-0000-0000-0000-000000000700"),
            deviceID: .init("00000000-0000-0000-0000-000000000701"),
            accessToken: access,
            accessTokenExpiresAt: expiry,
            refreshCredential: refresh
        )
    }

    private func session(for credentials: V2AuthCredentials) -> V2AuthenticatedClientSession {
        .init(userID: credentials.userID, deviceID: credentials.deviceID, protocolVersion: 1, capabilityProfile: "standard")
    }
}

private actor RealtimeCredentialStore: V2CredentialStore {
    private var value: V2AuthCredentialRecord?
    init(record: V2AuthCredentialRecord?) { value = record }
    func load() -> V2AuthCredentialRecord? { value }
    func save(_ record: V2AuthCredentialRecord) { value = record }
    func delete() { value = nil }
    func record() -> V2AuthCredentialRecord? { value }
}

private actor RealtimeRefreshTransport: V2AuthTransport {
    private let result: Result<V2AuthCredentials, Error>
    init(result: Result<V2AuthCredentials, Error>) { self.result = result }
    func refresh(_: V2RefreshRequest) throws -> V2AuthCredentials { try result.get() }
}

private actor RecordingRealtimeConnection: V2RealtimeConnection {
    struct Attempt: Equatable, Sendable {
        let accessToken: String
        let deviceID: DeviceID
        let profiles: Set<String>
    }

    private let result: Result<V2AuthenticatedClientSession, Error>
    private var recordedAttempts: [Attempt] = []
    private var disconnections = 0

    init(result: Result<V2AuthenticatedClientSession, Error>) { self.result = result }

    func connectAndAuthenticate(accessToken: String, deviceID: DeviceID, supportedCapabilityProfiles: Set<String>) throws -> V2AuthenticatedClientSession {
        recordedAttempts.append(.init(accessToken: accessToken, deviceID: deviceID, profiles: supportedCapabilityProfiles))
        return try result.get()
    }

    func disconnect() { disconnections += 1 }
    func attempts() -> [Attempt] { recordedAttempts }
    func disconnectCount() -> Int { disconnections }
}
