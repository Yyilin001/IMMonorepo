import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("V2 client runtime lifecycle")
struct V2ClientRuntimeTests {
    @Test("initial durable sync completes before the live loops start, then stop owns cancellation")
    func startsThenStopsOwnedLoops() async throws {
        let session = try authenticatedSession()
        let connection = RuntimeConnection(result: .success(session))
        let activity = BlockingRuntimeActivity()
        let runtime = V2ClientRuntime(connection: connection, activity: activity)

        #expect(try await runtime.start() == session)
        await activity.waitForLoops()
        #expect(await activity.syncCount() == 1)
        #expect(await activity.commandFlushCount() == 1)
        #expect(await connection.connectCount() == 1)
        #expect(await runtime.currentState() == .running(session))

        await runtime.stop()

        #expect(await runtime.currentState() == .stopped)
        #expect(await connection.disconnectCount() == 1)
    }

    @Test("a failed initial sync disconnects and never starts live loops")
    func initialSyncFailureStopsConnection() async throws {
        let connection = RuntimeConnection(result: .success(try authenticatedSession()))
        let activity = BlockingRuntimeActivity(syncFailure: RuntimeFailure.failed)
        let runtime = V2ClientRuntime(connection: connection, activity: activity)

        await #expect(throws: RuntimeFailure.failed) {
            _ = try await runtime.start()
        }
        #expect(await runtime.currentState() == .stopped)
        #expect(await connection.disconnectCount() == 1)
        #expect(await activity.loopStartCount() == 0)
    }

    @Test("a running runtime reuses its established session without another handshake")
    func repeatedStartIsIdempotent() async throws {
        let session = try authenticatedSession()
        let connection = RuntimeConnection(result: .success(session))
        let activity = BlockingRuntimeActivity()
        let runtime = V2ClientRuntime(connection: connection, activity: activity)

        _ = try await runtime.start()
        _ = try await runtime.start()

        #expect(await connection.connectCount() == 1)
        await runtime.stop()
    }

    @Test("a runtime stopped for backgrounding establishes a fresh foreground session")
    func restartAfterStopReconnects() async throws {
        let session = try authenticatedSession()
        let connection = RuntimeConnection(result: .success(session))
        let activity = BlockingRuntimeActivity()
        let runtime = V2ClientRuntime(connection: connection, activity: activity)

        _ = try await runtime.start()
        await runtime.stop()
        _ = try await runtime.start()

        #expect(await connection.connectCount() == 2)
        #expect(await activity.syncCount() == 2)
        #expect(await activity.commandFlushCount() == 2)
        #expect(await runtime.currentState() == .running(session))

        await runtime.stop()
        #expect(await connection.disconnectCount() == 2)
    }

    @Test("backgrounding during a handshake prevents initial sync and outbox work")
    func stopDuringHandshakeCancelsPostHandshakeWork() async throws {
        let connection = BlockingRuntimeConnection(session: try authenticatedSession())
        let activity = BlockingRuntimeActivity()
        let runtime = V2ClientRuntime(connection: connection, activity: activity)

        let start = Task { try await runtime.start() }
        await connection.waitForConnect()
        await runtime.stop()

        await #expect(throws: CancellationError.self) {
            _ = try await start.value
        }
        #expect(await activity.syncCount() == 0)
        #expect(await activity.commandFlushCount() == 0)
        #expect(await runtime.currentState() == .stopped)
    }

    @Test("repeated stops do not repeatedly close an already stopped connection")
    func repeatedStopIsIdempotent() async throws {
        let connection = RuntimeConnection(result: .success(try authenticatedSession()))
        let runtime = V2ClientRuntime(connection: connection, activity: BlockingRuntimeActivity())

        _ = try await runtime.start()
        await runtime.stop()
        await runtime.stop()

        #expect(await connection.disconnectCount() == 1)
    }

    @Test("concurrent start callers share one in-flight handshake and initial sync")
    func concurrentStartsShareAttempt() async throws {
        let session = try authenticatedSession()
        let connection = BlockingRuntimeConnection(session: session)
        let activity = BlockingRuntimeActivity()
        let runtime = V2ClientRuntime(connection: connection, activity: activity)

        let first = Task { try await runtime.start() }
        await connection.waitForConnect()
        let second = Task { try await runtime.start() }
        await Task.yield()
        await connection.release()

        #expect(try await first.value == session)
        #expect(try await second.value == session)
        #expect(await connection.connectCount() == 1)
        #expect(await activity.syncCount() == 1)
        await runtime.stop()
    }

    @Test("availability-driven synchronization replays queued commands after reconnect")
    func availabilitySyncFlushesQueuedCommands() async throws {
        let sync = AvailabilitySyncDriver()
        let outbox = AvailabilityCommandFlusher()
        let activity = V2DefaultClientRuntimeActivity(
            syncEngine: sync,
            availabilitySource: OneAvailabilityHintThenStop(),
            heartbeatSender: NoopHeartbeatSender(),
            heartbeatInterval: .seconds(30),
            commandOutbox: outbox,
            maximumInitialCommandFlushes: 4
        )

        await #expect(throws: AvailabilityLoopStop.finished) {
            try await activity.runAvailabilityLoop()
        }

        #expect(await sync.synchronizationCount() == 1)
        #expect(await outbox.flushCount() == 2)
    }

    @Test("projection callback runs after initial and live synchronization")
    func projectionCallbackFollowsEverySuccessfulSync() async throws {
        let sync = AvailabilitySyncDriver()
        let recorder = ProjectionSyncRecorder()
        let activity = V2DefaultClientRuntimeActivity(
            syncEngine: sync,
            availabilitySource: OneAvailabilityHintThenStop(),
            heartbeatSender: NoopHeartbeatSender(),
            heartbeatInterval: .seconds(30),
            onProjectionSynchronized: { await recorder.record() }
        )

        try await activity.synchronizeAfterConnection()
        await #expect(throws: AvailabilityLoopStop.finished) {
            try await activity.runAvailabilityLoop()
        }

        #expect(await sync.synchronizationCount() == 2)
        #expect(await recorder.count() == 2)
    }

    @Test("terminal command maintenance follows each command flush after a successful sync")
    func terminalCommandMaintenanceFollowsCommandFlush() async throws {
        let sync = AvailabilitySyncDriver()
        let recorder = ProjectionSyncRecorder()
        let activity = V2DefaultClientRuntimeActivity(
            syncEngine: sync,
            availabilitySource: OneAvailabilityHintThenStop(),
            heartbeatSender: NoopHeartbeatSender(),
            heartbeatInterval: .seconds(30),
            afterDurableSynchronization: { await recorder.record() }
        )

        try await activity.synchronizeAfterConnection()
        try await activity.flushDurableCommands()
        await #expect(throws: AvailabilityLoopStop.finished) {
            try await activity.runAvailabilityLoop()
        }

        #expect(await sync.synchronizationCount() == 2)
        #expect(await recorder.count() == 2)
    }

    private func authenticatedSession() throws -> V2AuthenticatedClientSession {
        .init(
            userID: try .init("00000000-0000-0000-0000-000000000811"),
            deviceID: try .init("00000000-0000-0000-0000-000000000812"),
            protocolVersion: 1,
            capabilityProfile: "standard"
        )
    }
}

private enum RuntimeFailure: Error, Equatable { case failed }
private enum AvailabilityLoopStop: Error, Equatable { case finished }

private actor RuntimeConnection: V2RealtimeSessionConnecting {
    private let result: Result<V2AuthenticatedClientSession, Error>
    private var connections = 0
    private var disconnections = 0
    init(result: Result<V2AuthenticatedClientSession, Error>) { self.result = result }
    func connect() throws -> V2AuthenticatedClientSession { connections += 1; return try result.get() }
    func disconnect() { disconnections += 1 }
    func connectCount() -> Int { connections }
    func disconnectCount() -> Int { disconnections }
}

private actor BlockingRuntimeConnection: V2RealtimeSessionConnecting {
    private let session: V2AuthenticatedClientSession
    private var connections = 0
    private var didConnectWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    init(session: V2AuthenticatedClientSession) { self.session = session }

    func connect() async -> V2AuthenticatedClientSession {
        connections += 1
        didConnectWaiter?.resume()
        didConnectWaiter = nil
        if !released {
            await withCheckedContinuation { continuation in
                if released { continuation.resume() }
                else { releaseWaiter = continuation }
            }
        }
        return session
    }

    func disconnect() { release() }
    func waitForConnect() async {
        guard connections == 0 else { return }
        await withCheckedContinuation { didConnectWaiter = $0 }
    }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
    func connectCount() -> Int { connections }
}

private actor BlockingRuntimeActivity: V2ClientRuntimeActivity {
    private let syncFailure: RuntimeFailure?
    private var synchronizations = 0
    private var commandFlushes = 0
    private var starts = 0
    private var availabilityWaiter: CheckedContinuation<Void, Never>?
    private var heartbeatWaiter: CheckedContinuation<Void, Never>?
    private var loopsWaiter: CheckedContinuation<Void, Never>?
    private var availabilityCancelled = false
    private var heartbeatCancelled = false

    init(syncFailure: RuntimeFailure? = nil) { self.syncFailure = syncFailure }

    func synchronizeAfterConnection() throws {
        synchronizations += 1
        if let syncFailure { throw syncFailure }
    }

    func flushDurableCommands() {
        commandFlushes += 1
    }

    func runAvailabilityLoop() async throws {
        startedLoop()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if availabilityCancelled { continuation.resume() }
                else { availabilityWaiter = continuation }
            }
        }, onCancel: {
            Task { await self.cancelAvailability() }
        })
        try Task.checkCancellation()
    }

    func runHeartbeatLoop() async throws {
        startedLoop()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if heartbeatCancelled { continuation.resume() }
                else { heartbeatWaiter = continuation }
            }
        }, onCancel: {
            Task { await self.cancelHeartbeat() }
        })
        try Task.checkCancellation()
    }

    func waitForLoops() async {
        guard starts < 2 else { return }
        await withCheckedContinuation { loopsWaiter = $0 }
    }

    func syncCount() -> Int { synchronizations }
    func commandFlushCount() -> Int { commandFlushes }
    func loopStartCount() -> Int { starts }

    private func startedLoop() {
        starts += 1
        if starts == 2 { loopsWaiter?.resume(); loopsWaiter = nil }
    }
    private func cancelAvailability() { availabilityCancelled = true; availabilityWaiter?.resume(); availabilityWaiter = nil }
    private func cancelHeartbeat() { heartbeatCancelled = true; heartbeatWaiter?.resume(); heartbeatWaiter = nil }
}

private actor AvailabilitySyncDriver: V2SyncDriving {
    private var count = 0
    func synchronizeUntilCaughtUp() -> V2SyncCycleResult {
        count += 1
        return .synchronized(appliedThrough: 0, hasMore: false)
    }
    func completePendingReset() {}
    func synchronizationCount() -> Int { count }
}

private actor AvailabilityCommandFlusher: V2ClientCommandFlushing {
    private var results: [V2CommandFlushResult] = [
        .accepted(try! .init("00000000-0000-0000-0000-000000000813")),
        .idle,
    ]
    private var count = 0

    func flushOnce() -> V2CommandFlushResult {
        count += 1
        return results.removeFirst()
    }

    func flushCount() -> Int { count }
}

private actor ProjectionSyncRecorder {
    private var value = 0
    func record() { value += 1 }
    func count() -> Int { value }
}

private actor OneAvailabilityHintThenStop: V2SyncAvailabilityHintSource {
    private var emitted = false

    func nextAvailabilityHint() throws -> V2SyncAvailabilityHint {
        guard !emitted else { throw AvailabilityLoopStop.finished }
        emitted = true
        return .init(eventID: 1, highWatermark: 1)
    }
}

private struct NoopHeartbeatSender: V2HeartbeatSender {
    func sendHeartbeat(clientTime: Date) {}
}
