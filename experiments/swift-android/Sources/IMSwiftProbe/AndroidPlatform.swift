import Foundation
import IMV2Core
import IMV2ClientRuntime
import IMV2ClientAndroid

private let probeUser = "00000000-0000-0000-0000-000000000701"
private let probeDevice = "00000000-0000-0000-0000-000000000702"
private func credentials() throws -> V2AuthCredentials {
    try .init(userID: .init(probeUser), deviceID: .init(probeDevice), accessToken: "phase3-fixture-access",
        accessTokenExpiresAt: Date().addingTimeInterval(3600), refreshCredential: "phase3-fixture-refresh",
        revocationCredential: .init(rawValue: "imv2-revoke-v1." + String(repeating: "A", count: 43)),
        revocationCredentialExpiresAt: Date().addingTimeInterval(7200))
}
private struct NoRefresh: V2AuthTransport {
    func refresh(_ request: V2RefreshRequest) async throws -> V2AuthCredentials { throw ProbeFailure.assertion("unexpected refresh") }
}
func androidPlatformProbe(_ input: ProbeInput) async throws -> ProbeResult {
    let name = input.path ?? "phase3-auth"
    let store = V2AndroidCredentialStore(name: name)
    switch input.operation {
    case "android_credentials":
        try await store.delete()
        try require(try await store.load() == nil, "initially absent")
        let record = V2AuthCredentialRecord(credentials: try credentials(), pendingRefreshOperationID: UUID(), pendingRevocationOperationID: UUID())
        try await store.save(record)
        let reopened = V2AndroidCredentialStore(name: name)
        try require(try await reopened.load() == record, "atomic credential and operation identities")
        return .init(outcome: "ok", values: ["reopened": "true", "pendingOperations": "true"])
    case "android_credential_load":
        _ = try await store.load()
        return .init(outcome: "ok", values: [:])
    case "android_credential_delete":
        try await store.delete()
        try require(try await store.load() == nil, "deleted")
        return .init(outcome: "ok", values: [:])
    default: break
    }
    guard let url = input.url.flatMap(URL.init(string:)), let host = url.host, let port = url.port,
          let port = UInt16(exactly: port) else { throw ProbeFailure.assertion("invalid endpoint") }
    let endpoint = try V2RealtimeEndpoint(host: host, port: port)
    if input.operation == "android_tls" || input.operation == "android_tls_wait" {
        let connection = V2AndroidTLSByteConnection(endpoint: endpoint)
        defer { connection.cancel() }
        try await connection.start()
        try await connection.send(Data("phase3".utf8))
        let received = try await connection.receive(maximumLength: 64)
        try require(received == Data("phase3".utf8), "TLS roundtrip")
        return .init(outcome: "ok", values: ["tls": "1.3", "bytes": String(received.count)])
    }
    guard let path = input.path else { throw ProbeFailure.assertion("database path required") }
    let authStore = V2AndroidCredentialStore(name: "phase3-session")
    try await authStore.delete()
    let revocations = V2DeviceRevocationStore(persistence: V2AndroidSecurePersistence(name: "phase3-revocations"))
    let auth = V2AuthSession(credentialStore: authStore, transport: NoRefresh(), revocationScheduler: revocations)
    try await auth.establish(credentials())
    // Recreate the auth owner: the TLS authentication must use Keystore-restored credentials.
    let restored = V2AuthSession(credentialStore: V2AndroidCredentialStore(name: "phase3-session"), transport: NoRefresh(), revocationScheduler: revocations)
    let binding = V2AndroidInstallationBindingStore(name: "phase3-binding")
    let bootstrap = V2LocalStoreBootstrapper(bindingStore: binding)
    let local = try await bootstrap.open(databaseURL: URL(fileURLWithPath: path), userID: .init(probeUser))
    let wire = V2TLSFrameConnection(androidEndpoint: endpoint,
        frameLimits: try .init(maximumPayloadBytes: 65_536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]), requestTimeout: .seconds(5))
    let coordinator = V2RealtimeSessionCoordinator(authSession: restored, connection: wire, supportedCapabilityProfiles: ["base"])
    let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: UInt8(IMV2ProtocolVersion.current))
    let sync = V2SyncEngine(transport: transport, store: local, capabilityProfile: "base")
    let activity = V2DefaultClientRuntimeActivity(syncEngine: sync, availabilitySource: wire,
        heartbeatSender: transport, heartbeatInterval: .milliseconds(100))
    let runtime = V2ClientRuntime(connection: coordinator, activity: activity)
    do {
        _ = try await runtime.start()
        try await waitForSequence(1, store: local)
        // Fixture closes the first authenticated connection after the first durable ACK.
        let deadline = ContinuousClock.now + .seconds(10)
        while await runtime.currentState() != .stopped {
            try require(ContinuousClock.now < deadline, "disconnect observed")
            try await Task.sleep(for: .milliseconds(10))
        }
        await runtime.stop() // Drain old reads/loops before starting the next generation.
        _ = try await runtime.start()
        try await waitForSequence(2, store: local)
        await runtime.stop()
        try await local.close()
        let reopened = try await bootstrap.open(databaseURL: URL(fileURLWithPath: path), userID: .init(probeUser))
        let cursor = try await reopened.cursor()
        try require(cursor?.appliedSequence == 2 && cursor?.serverAcknowledgedSequence == 2, "durable reconnect cursor")
        try require(try await reopened.events().count == 2, "no duplicate sync application")
        try await reopened.close()
        try await authStore.delete()
        return .init(outcome: "ok", values: ["credentialRestore": "true", "authenticatedConnections": "2", "durableSequence": "2", "runtime": "IMV2ClientRuntime"])
    } catch {
        await runtime.stop()
        try? await local.close()
        try? await authStore.delete()
        throw error
    }
}
private func waitForSequence(_ sequence: UInt64, store: GRDBV2LocalSyncStore) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while try await store.cursor()?.serverAcknowledgedSequence != sequence {
        try require(ContinuousClock.now < deadline, "sync deadline")
        try await Task.sleep(for: .milliseconds(10))
    }
}
