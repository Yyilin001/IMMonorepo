#if canImport(Network) && canImport(Security)
import Foundation
import Network
import Synchronization
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Network durable retry lifecycle", .timeLimit(.minutes(1)))
struct V2NetworkCommandRetryTests {
    @Test("two SQLite lanes retry on a quiet socket and recover overdue work after runtime stop")
    func quietRetryAndStoppedRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-network-retry-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = RetryWireScript()
        let peers = (0..<2).map { _ in TLSTestPeer(commandResponder: { try await script.respond($0) }) }
        let server = try TCPCallbackTestServer(peers: peers)
        let port = try await server.start()
        let connection = V2TLSFrameConnection(connectionFactory: {
            V2NetworkTLSByteConnection(connection: NWConnection(host: "127.0.0.1", port: port, using: .tcp), queue: .global())
        }, frameLimits: try .init(maximumPayloadBytes: 65_536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]))
        let transport = V2ProtobufSyncTransport(wire: connection, protocolVersion: UInt8(IMV2ProtocolVersion.current))
        let binding = V2LocalInstallationBinding(value: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "main.sqlite"), installationBinding: binding)
        let clockOffset = Mutex<TimeInterval>(0)
        let now: @Sendable () -> Date = { Date().addingTimeInterval(clockOffset.withLock { $0 }) }
        let activity = RetryNetworkActivity(store: store, transport: transport, now: now)
        let runtime = V2ClientRuntime(connection: RetryNetworkConnection(connection: connection), activity: activity)
        var restoredRuntime: V2ClientRuntime?
        do {
            // Enqueued before startup: one-item startup budget must leave
            // the other lane for the runtime-owned retry worker.
            try await activity.enqueuePair()
            _ = try await runtime.start()
            try await eventually {
                let messages = try await store.pendingMessageCommands()
                let edits = try await store.pendingMessageEdits()
                return messages.filter { $0.state == .accepted }.count == 1
                    && edits.filter { $0.state == .acknowledged }.count == 1
            }
            #expect(await script.totalAttempts == 4)
            #expect(try await store.commandRetrySchedule(lanes: [.messages, .edits]).nextAttemptAt() == nil)

            // Idle enqueue is discovered through the actual GRDB observation.
            try await activity.enqueuePair()
            try await eventually {
                let messages = try await store.pendingMessageCommands()
                let edits = try await store.pendingMessageEdits()
                return messages.contains { $0.state == .pending && $0.attemptCount == 1 }
                    && edits.contains { $0.state == .pending && $0.attemptCount == 1 }
            }
            await runtime.stop()
            let attemptsAtStop = await script.totalAttempts
            let readsAtStop = activity.scheduleReads.withLock { $0 }
            clockOffset.withLock { $0 = 60 }
            try await Task.sleep(for: .milliseconds(100))
            #expect(await script.totalAttempts == attemptsAtStop)
            #expect(activity.scheduleReads.withLock { $0 } == readsAtStop)

            // Open another SQLite pool and recreate engines/runtime. No
            // in-memory notification or timer from the old worker is reused.
            let restored = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "main.sqlite"), installationBinding: binding)
            let restoredActivity = RetryNetworkActivity(store: restored, transport: transport, now: now)
            let replacement = V2ClientRuntime(connection: RetryNetworkConnection(connection: connection), activity: restoredActivity)
            restoredRuntime = replacement
            _ = try await replacement.start()
            try await eventually {
                let messages = try await restored.pendingMessageCommands()
                let edits = try await restored.pendingMessageEdits()
                return messages.filter { $0.state == .accepted }.count == 2
                    && edits.filter { $0.state == .acknowledged }.count == 2
            }
            #expect(await script.totalAttempts == 8)
            #expect(await script.attemptsPerOperation.values.allSatisfy { $0 == 2 })
            #expect(await script.attemptsPerOperation.count == 4)
            await replacement.stop()
            await server.stop()
        } catch {
            await runtime.stop()
            await restoredRuntime?.stop()
            await server.stop()
            throw error
        }
    }

    private func eventually(_ predicate: @Sendable () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try await !predicate() {
            guard ContinuousClock.now < deadline else { throw RetryNetworkFailure.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum RetryNetworkFailure: Error { case timedOut, unexpectedCommand }

private struct RetryNetworkConnection: V2RealtimeSessionConnecting {
    let connection: V2TLSFrameConnection
    func connect() async throws -> V2AuthenticatedClientSession {
        try await connection.connectAndAuthenticate(accessToken: "fixture-access", deviceID: .init("fixture-device"), supportedCapabilityProfiles: ["base"])
    }
    func disconnect() async { await connection.disconnect() }
}

// Exercise production runtime ownership, retry scheduling, fair scheduling,
// both engines, SQLite and protobuf/TCP. Unrelated sync/heartbeat loops are
// deliberately omitted; this is not full App or server authorization E2E.
private final class RetryNetworkActivity: V2ClientRuntimeActivity, Sendable {
    let store: GRDBV2LocalSyncStore
    let messages: V2CommandOutboxEngine
    let edits: V2MessageEditOutboxEngine
    let scheduler: V2FairDurableCommandScheduler
    let scheduleReads = Mutex(0)
    let now: @Sendable () -> Date

    init(store: GRDBV2LocalSyncStore, transport: V2ProtobufSyncTransport, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.now = now
        let messages = V2CommandOutboxEngine(store: store, transport: transport, now: now)
        let edits = V2MessageEditOutboxEngine(store: store, transport: transport, now: now)
        self.messages = messages
        self.edits = edits
        scheduler = V2FairDurableCommandScheduler(lanes: [
            .init { if case .idle = try await messages.flushOnce() { return false }; return true },
            .init { if case .idle = try await edits.flushOnce() { return false }; return true },
        ])
    }
    func enqueuePair() async throws {
        _ = try await messages.enqueueMessage(roomID: .init(uuid: UUID()), text: "durable send")
        _ = try await edits.enqueueEdit(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()), expectedMessageRevision: 1, text: "durable edit")
    }
    func synchronizeAfterConnection() async throws {}
    func flushDurableCommands() async throws { _ = try await scheduler.flush(maximumWorkItems: 1) }
    func runAvailabilityLoop() async throws {}
    func runHeartbeatLoop() async throws {}
    func resumeDurableCommands() async {
        await messages.resumeCommandFlushing()
        await edits.resumeCommandFlushing()
        await scheduler.resumeCommandFlushing()
    }
    func suspendDurableCommands() async {
        await scheduler.suspendCommandFlushing()
        await messages.suspendCommandFlushing()
        await edits.suspendCommandFlushing()
    }
    func runCommandRetryLoop() async throws {
        let durable = store.commandRetrySchedule(lanes: [.messages, .edits])
        let observed = V2CommandRetrySchedule(nextAttemptAt: { [self] in
            scheduleReads.withLock { $0 += 1 }
            return try await durable.nextAttemptAt()
        }, updates: durable.updates)
        try await V2CommandRetryScheduler(schedule: observed, flush: { [self] in
            try await flushDurableCommands()
        }, now: now).run()
    }
}

private actor RetryWireScript {
    private(set) var totalAttempts = 0
    private(set) var attemptsPerOperation: [String: Int] = [:]
    func respond(_ request: IMV2Envelope) throws -> IMV2Envelope {
        let id: String
        var response = IMV2Envelope()
        response.requestID = request.requestID
        response.protocolVersion = IMV2ProtocolVersion.current
        switch request.body {
        case .sendMessage(let command):
            id = command.clientMessageID
            response.messageAccepted = .init()
            response.messageAccepted.roomID = command.roomID
            response.messageAccepted.messageID = UUID().uuidString
            response.messageAccepted.roomSequence = 1
        case .editMessage(let command):
            id = command.operationID
            response.messageEdited = .init()
            response.messageEdited.roomID = command.roomID
            response.messageEdited.messageID = command.messageID
            response.messageEdited.text = command.content.text
            response.messageEdited.messageRevision = 2
            response.messageEdited.roomSequence = 2
        default: throw RetryNetworkFailure.unexpectedCommand
        }
        totalAttempts += 1
        attemptsPerOperation[id, default: 0] += 1
        if attemptsPerOperation[id] == 1 {
            response.error = .init()
            response.error.code = "UNAVAILABLE"
            response.error.retryable = true
            response.error.retryAfterSeconds = 1
        }
        return response
    }
}
#endif
