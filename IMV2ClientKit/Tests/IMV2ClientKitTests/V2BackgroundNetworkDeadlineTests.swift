#if canImport(Network) && canImport(Security)
import Foundation
import Network
import Synchronization
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Background real Network deadlines", .timeLimit(.minutes(1)))
struct V2BackgroundNetworkDeadlineTests {
    @Test("deadline drains real network work without losing credentials or committed data", arguments: DeadlinePhase.allCases)
    fileprivate func stalledNetworkPhase(phase: DeadlinePhase) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-background-deadline-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try DeadlineSocketServer(phase: phase)
        let port = try await server.start()
        let limits = try V2FrameLimits(maximumPayloadBytes: 65_536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)])
        let wire: V2TLSFrameConnection
        if phase == .tls {
            // Production TLS 1.3 configuration. The actual TCP peer accepts
            // ClientHello but never sends TLS handshake bytes back.
            wire = V2TLSFrameConnection(endpoint: try .init(host: "127.0.0.1", port: port.rawValue), frameLimits: limits)
        } else {
            // Plain TCP isolates framed-protocol phases from certificate
            // setup; the production byte adapter still handles callbacks.
            wire = V2TLSFrameConnection(connectionFactory: {
                V2NetworkTLSByteConnection(connection: NWConnection(host: "127.0.0.1", port: port, using: .tcp), queue: .global())
            }, frameLimits: limits)
        }
        let credentials = DeadlineCredentialStore(record: .init(credentials: try .init(userID: .init("deadline-user"), deviceID: .init("deadline-device"), accessToken: "fixture-access", accessTokenExpiresAt: Date().addingTimeInterval(3600), refreshCredential: "fixture-refresh")))
        let auth = V2AuthSession(credentialStore: credentials, transport: DeadlineUnusedRefresh())
        let coordinator = V2RealtimeSessionCoordinator(authSession: auth, connection: wire, supportedCapabilityProfiles: ["base"])
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "main.sqlite"), installationBinding: .init(value: UUID()))
        let runner = V2BackgroundSyncRunner(connection: coordinator, syncEngine: .init(transport: V2ProtobufSyncTransport(wire: wire, protocolVersion: UInt8(IMV2ProtocolVersion.current)), store: store, capabilityProfile: "base"), budget: .init(workDuration: .seconds(1)))
        do {
            let start = ContinuousClock.now
            await #expect(throws: V2BackgroundSyncError.deadlineReached) { try await runner.run() }
            #expect(start.duration(to: .now) < .seconds(5))
            #expect(await server.observedStall)
            try await server.waitForClosedConnections()
            #expect(await server.closedConnections == 1)
            #expect(await credentials.current() != nil)
            let cursor = try await store.cursor()
            #expect((cursor?.appliedSequence ?? 0) == (phase == .ack ? 1 : 0))
            #expect((cursor?.serverAcknowledgedSequence ?? 0) == 0)
            if phase != .tls {
                await server.allowResponses()
                let result = try await runner.run()
                #expect(result.stopReason == .caughtUp)
                #expect(result.didCommitNewRecords == (phase != .ack))
                #expect(try await store.cursor()?.appliedSequence == 1)
                #expect(try await store.cursor()?.serverAcknowledgedSequence == 1)
                try await server.waitForClosedConnections()
                #expect(await server.closedConnections == 2)
            }
            await runner.stop()
            await server.stop()
            try await store.close()
        } catch {
            await runner.stop()
            await server.stop()
            try? await store.close()
            throw error
        }
    }
}

private enum DeadlinePhase: String, CaseIterable, Sendable { case tls, hello, authenticate, pull, ack }
private enum DeadlineFixtureFailure: Error { case unexpected, closeTimedOut }

private actor DeadlineCredentialStore: V2CredentialStore {
    private var record: V2AuthCredentialRecord?
    init(record: V2AuthCredentialRecord) { self.record = record }
    func load() -> V2AuthCredentialRecord? { record }
    func save(_ value: V2AuthCredentialRecord) { record = value }
    func delete() { record = nil }
    func current() -> V2AuthCredentialRecord? { record }
}
private struct DeadlineUnusedRefresh: V2AuthTransport {
    func refresh(_ request: V2RefreshRequest) throws -> V2AuthCredentials { throw DeadlineFixtureFailure.unexpected }
}

private actor DeadlineSocketServer {
    private let listener: NWListener
    private let phase: DeadlinePhase
    private let payload: Data
    private let eventID = UUID().uuidString
    private var stalled = true
    private var stopped = false
    private var connections: [UUID: V2NetworkTLSByteConnection] = [:]
    private var tasks: [Task<Void, Never>] = []
    private(set) var observedStall = false
    private(set) var closedConnections = 0

    init(phase: DeadlinePhase) throws {
        self.phase = phase
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        payload = try JSONSerialization.data(withJSONObject: [
            "event_type": "message.accepted", "message_id": UUID().uuidString,
            "room_id": UUID().uuidString, "room_sequence": 1, "message_revision": 1,
            "sender_user_id": "deadline-user", "text": "deadline payload",
            "mentioned_user_ids": [], "mentions_everyone": false,
            "server_created_at_ms": 1_750_000_000_000,
        ])
    }

    func start() async throws -> NWEndpoint.Port {
        listener.newConnectionHandler = { connection in Task { await self.accept(connection) } }
        return try await withCheckedThrowingContinuation { continuation in
            let pending = Mutex<CheckedContinuation<NWEndpoint.Port, Error>?>(continuation)
            listener.stateUpdateHandler = { [listener] state in
                let result: Result<NWEndpoint.Port, Error>
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    result = .success(port)
                case .failed, .cancelled: result = .failure(DeadlineFixtureFailure.unexpected)
                default: return
                }
                let waiter = pending.withLock { value in
                    let waiter = value; value = nil; return waiter
                }
                listener.stateUpdateHandler = nil
                waiter?.resume(with: result)
            }
            listener.start(queue: .global())
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        let id = UUID()
        let bytes = V2NetworkTLSByteConnection(connection: connection, queue: .global())
        connections[id] = bytes
        tasks.append(Task { await self.serve(bytes, id: id) })
    }

    private func serve(_ bytes: V2NetworkTLSByteConnection, id: UUID) async {
        do {
            try await bytes.start()
            let limits = try V2FrameLimits(maximumPayloadBytes: 65_536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)])
            var decoder = V2FrameDecoder(limits: limits)
            while !Task.isCancelled {
                let chunk = try await bytes.receive(maximumLength: 65_536)
                if phase == .tls { observedStall = true; continue }
                for frame in try decoder.append(chunk) {
                    let request = try V2ProtobufFrameCodec.decode(frame)
                    if let response = try respond(request) {
                        try await bytes.send(V2FrameCodec.encode(V2ProtobufFrameCodec.encode(response, frameVersion: UInt8(IMV2ProtocolVersion.current)), limits: limits))
                    }
                }
            }
        } catch { /* Expected EOF/cancellation when the deadline closes it. */ }
        bytes.cancel()
        connections.removeValue(forKey: id)
        closedConnections += 1
    }

    private func respond(_ request: IMV2Envelope) throws -> IMV2Envelope? {
        var response = IMV2Envelope()
        response.requestID = request.requestID
        response.protocolVersion = IMV2ProtocolVersion.current
        let current: DeadlinePhase
        switch request.body {
        case .clientHello:
            current = .hello
            response.serverHello = .init()
            response.serverHello.selectedProtocolVersion = IMV2ProtocolVersion.current
            response.serverHello.selectedCapabilityProfile = "base"
        case .authenticate(let authentication):
            current = .authenticate
            response.authenticated = .init()
            response.authenticated.userID = "deadline-user"
            response.authenticated.deviceID = authentication.deviceID
            response.authenticated.selectedCapabilityProfile = "base"
        case .presencePublicationControl(let control):
            current = .authenticate
            response.presencePublicationControlled.mode = control.mode
        case .syncPull:
            current = .pull
            response.syncBatch = .init()
            response.syncBatch.generation = 1
            response.syncBatch.nextSyncToken = "deadline-token"
            response.syncBatch.syncReceipt = "deadline-receipt"
            response.syncBatch.capabilityProfile = "base"
            response.syncBatch.records = [.init()]
            response.syncBatch.records[0].userSyncSequence = 1
            response.syncBatch.records[0].sourceEventID = eventID
            response.syncBatch.records[0].projectionKind = "message"
            response.syncBatch.records[0].payload = payload
        case .syncAck:
            current = .ack
            response.acknowledged = .init()
        default: throw DeadlineFixtureFailure.unexpected
        }
        if stalled && phase == current { observedStall = true; return nil }
        return response
    }

    func allowResponses() { stalled = false }
    func waitForClosedConnections() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !connections.isEmpty {
            guard ContinuousClock.now < deadline else { throw DeadlineFixtureFailure.closeTimedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func stop() async {
        stopped = true
        listener.cancel()
        for bytes in connections.values { bytes.cancel() }
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }
}
#endif
