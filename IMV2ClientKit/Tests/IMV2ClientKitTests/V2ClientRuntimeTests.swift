import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("V2 client runtime lifecycle")
struct V2ClientRuntimeTests {
    @Test("authenticated connection starts live loops and independent initial recovery; stop drains both")
    func startsThenStopsOwnedLoops() async throws {
        let session = try authenticatedSession()
        let connection = RuntimeConnection(result: .success(session))
        let activity = BlockingRuntimeActivity()
        let runtime = V2ClientRuntime(connection: connection, activity: activity)

        #expect(try await runtime.start() == session)
        await activity.waitForLoops()
        await activity.waitForPolicyLoop()
        await activity.waitForInitialRecovery(count: 1)
        #expect(await activity.syncCount() == 1)
        #expect(await connection.connectCount() == 1)
        #expect(await runtime.currentState() == .running(session))

        await runtime.stop()
        #expect(await activity.loopExitCount() == 4)
        #expect(await activity.policyLoopWasCancelled())
        await activity.waitForRoomCatchUpCancellation()
        await activity.waitForSubscriptionCancellation()
        #expect(await activity.subscriptionConnectionIDs() == [session.connectionID])

        #expect(await runtime.currentState() == .stopped)
        #expect(await connection.disconnectCount() == 1)
    }

    @Test("a blocked initial history sync does not block running state or heartbeat")
    func slowInitialSyncDoesNotBlockConnectionReadiness() async throws {
        let session = try authenticatedSession()
        let connection = RuntimeConnection(result: .success(session))
        let activity = SlowInitialRuntimeActivity()
        let runtime = V2ClientRuntime(connection: connection, activity: activity)
        #expect(try await runtime.start() == session)
        await activity.waitForHeartbeat()
        #expect(await runtime.currentState() == .running(session))
        #expect(await activity.completedSynchronizations() == 0)
        await activity.releaseSync()
        for _ in 0..<1000 { if await activity.completedSynchronizations() == 1 { break }; await Task.yield() }
        #expect(await activity.completedSynchronizations() == 1)
        await runtime.stop()
    }

    @Test("a failed independent initial sync stops the authenticated connection")
    func initialSyncFailureStopsConnection() async throws {
        let connection = RuntimeConnection(result: .success(try authenticatedSession()))
        let activity = BlockingRuntimeActivity(syncFailure: RuntimeFailure.failed)
        let runtime = V2ClientRuntime(connection: connection, activity: activity)

        _ = try await runtime.start()
        await runtime.waitUntilStopped()
        for _ in 0..<1000 {
            if await connection.disconnectCount() == 1 { break }
            await Task.yield()
        }
        #expect(await runtime.currentState() == .stopped)
        #expect(await connection.disconnectCount() == 1)
        #expect(await runtime.lastBackgroundFailure() as? RuntimeFailure == .failed)
        #expect(await runtime.lastBackgroundFailureLoop() == .initialSync)
        await runtime.stop()
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
        await activity.waitForInitialRecovery(count: 1)
        await runtime.stop()
        _ = try await runtime.start()
        await activity.waitForInitialRecovery(count: 2)

        #expect(await connection.connectCount() == 2)
        #expect(await activity.syncCount() == 2)
        #expect(await runtime.currentState() == .running(session))

        await runtime.stop()
        #expect(await connection.disconnectCount() == 2)
    }

    @Test(.timeLimit(.minutes(1))) func failedHandshakeWakesRegisteredStopWaiter() async throws {
        let connection = BlockingRuntimeConnection(session: try authenticatedSession(), fails: true)
        let runtime = V2ClientRuntime(connection: connection, activity: BlockingRuntimeActivity())
        let start = Task { try await runtime.start() }
        await connection.waitForConnect()
        let waiter = Task { await runtime.waitUntilStopped() }
        while await runtime.waitingForStopCount == 0 { await Task.yield() }
        await connection.release()
        await #expect(throws: RuntimeFailure.failed) { _ = try await start.value }
        await waiter.value
        #expect(await runtime.waitingForStopCount == 0)
    }

    @Test(.timeLimit(.minutes(1))) func stopJoinsFailedHandshakeDisconnect() async throws {
        actor SlowDisconnect: V2RealtimeSessionConnecting {
            var gate: CheckedContinuation<Void, Never>?
            var finished = false
            func connect() throws -> V2AuthenticatedClientSession { throw RuntimeFailure.failed }
            func disconnect() async {
                await withCheckedContinuation { gate = $0 }
                finished = true
            }
            func release() { gate?.resume(); gate = nil }
        }
        let wire = SlowDisconnect()
        let runtime = V2ClientRuntime(connection: wire, activity: BlockingRuntimeActivity())
        let start = Task { try await runtime.start() }
        while await wire.gate == nil { await Task.yield() }
        #expect(await runtime.currentState() == .stopped)
        let stopping = Task {
            await runtime.stop()
            return await wire.finished
        }
        for _ in 0..<100 { await Task.yield() }
        await wire.release()
        #expect(await stopping.value)
        await #expect(throws: RuntimeFailure.failed) { _ = try await start.value }
    }

    @Test("backgrounding during a handshake prevents initial sync")
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
        await activity.waitForInitialRecovery(count: 1)
        #expect(await activity.syncCount() == 1)
        await runtime.stop()
    }

    @Test("availability-driven synchronization completes before projection maintenance")
    func availabilitySyncPrecedesMaintenance() async throws {
        let sync = AvailabilitySyncDriver()
        let maintenance = ProjectionSyncRecorder()
        let activity = V2DefaultClientRuntimeActivity(
            syncEngine: sync,
            availabilitySource: OneAvailabilityHintThenStop(),
            heartbeatSender: NoopHeartbeatSender(),
            heartbeatInterval: .seconds(30),
            afterDurableSynchronization: {
                #expect(await sync.synchronizationCount() == 1)
                await maintenance.record()
            }
        )

        await #expect(throws: AvailabilityLoopStop.finished) {
            try await activity.runAvailabilityLoop()
        }

        #expect(await sync.synchronizationCount() == 1)
        #expect(await maintenance.count() == 1)
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

    @Test("projection maintenance follows initial and availability synchronization")
    func maintenanceFollowsSuccessfulSynchronization() async throws {
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
        await #expect(throws: AvailabilityLoopStop.finished) {
            try await activity.runAvailabilityLoop()
        }

        #expect(await sync.synchronizationCount() == 2)
        #expect(await recorder.count() == 2)
    }

    @Test("a failed recovery child cancels and drains its siblings before stopping the connection")
    func recoveryChildFailureStopsConnectionAfterSiblingDrain() async throws {
        let session = try authenticatedSession()
        let connection = RuntimeConnection(result: .success(session))
        let sibling = RuntimeRecoveryProbe()
        let activity = recoveryActivity(loops: [
            { try await sibling.run() },
            { await sibling.waitUntilStarted(); throw RuntimeFailure.failed },
        ])
        let runtime = V2ClientRuntime(connection: connection, activity: activity)
        _ = try await runtime.start()

        let cancelled = await waitForRecoveryCancellation([sibling])
        #expect(cancelled)
        #expect(await sibling.hasExited == false)
        #expect(await runtime.currentState() == .running(session))
        #expect(await runtime.lastBackgroundFailure() == nil)
        await sibling.releaseCleanup()
        if cancelled { await runtime.waitUntilStopped() }
        // Also drains the original implementation after the bounded failure
        // assertion, so a regression cannot leave the test process hanging.
        await runtime.stop()

        #expect(await sibling.hasExited)
        #expect(await runtime.currentState() == .stopped)
        #expect(await runtime.lastBackgroundFailure() as? RuntimeFailure == .failed)
        #expect(await runtime.lastBackgroundFailureLoop() == .policy)
        #expect(await connection.disconnectCount() >= 1)
    }

    @Test("parent cancellation drains recovery streams that finish normally and remains cancellation")
    func cancelledRecoveryStreamsDrainWithoutReportingSuccess() async throws {
        let first = RuntimeRecoveryProbe()
        let second = RuntimeRecoveryProbe()
        let activity = recoveryActivity(loops: [
            { try await first.run(gracefulCancellation: true) },
            { try await second.run(gracefulCancellation: true) },
        ])
        let task = Task { try await activity.runPolicyRecoveryLoop() }
        await first.waitUntilStarted()
        await second.waitUntilStarted()
        task.cancel()
        #expect(await waitForRecoveryCancellation([first, second]))
        await first.releaseCleanup()
        await second.releaseCleanup()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await first.hasExited)
        #expect(await second.hasExited)
    }

    private func recoveryActivity(loops: [@Sendable () async throws -> Void]) -> V2DefaultClientRuntimeActivity {
        .init(syncEngine: AvailabilitySyncDriver(), availabilitySource: SleepingAvailabilityHints(),
              heartbeatSender: NoopHeartbeatSender(), heartbeatInterval: .seconds(3_600),
              policyRecoveryLoops: loops)
    }

    private func waitForRecoveryCancellation(_ probes: [RuntimeRecoveryProbe]) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline && !Task.isCancelled {
            var allCancelled = true
            for probe in probes where await probe.wasCancelled == false { allCancelled = false }
            if allCancelled { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func authenticatedSession() throws -> V2AuthenticatedClientSession {
        .init(
            userID: try .init("00000000-0000-0000-0000-000000000811"),
            deviceID: try .init("00000000-0000-0000-0000-000000000812"),
            protocolVersion: 1,
            capabilityProfile: "standard",
            connectionID: UUID()
        )
    }
}

private enum RuntimeFailure: Error, Equatable { case failed }
private enum AvailabilityLoopStop: Error, Equatable { case finished }

private struct SleepingAvailabilityHints: V2SyncAvailabilityHintSource {
    func nextAvailabilityHint() async throws -> V2SyncAvailabilityHint {
        try await Task.sleep(for: .seconds(3_600))
        throw AvailabilityLoopStop.finished
    }
}

private actor RuntimeRecoveryProbe {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var cleanupReleased = false
    private var cleanupWaiter: CheckedContinuation<Void, Never>?
    private(set) var wasCancelled = false
    private(set) var hasExited = false

    func run(gracefulCancellation: Bool = false) async throws {
        started = true
        startWaiter?.resume(); startWaiter = nil
        defer { hasExited = true }
        do { try await Task.sleep(for: .seconds(3_600)) }
        catch is CancellationError {
            wasCancelled = true
            if !cleanupReleased { await withCheckedContinuation { cleanupWaiter = $0 } }
            if !gracefulCancellation { throw CancellationError() }
        }
    }

    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }

    func releaseCleanup() {
        cleanupReleased = true
        cleanupWaiter?.resume(); cleanupWaiter = nil
    }
}

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

    private let fails: Bool
    init(session: V2AuthenticatedClientSession, fails: Bool = false) {
        self.session = session
        self.fails = fails
    }

    func connect() async throws -> V2AuthenticatedClientSession {
        connections += 1
        didConnectWaiter?.resume()
        didConnectWaiter = nil
        if !released {
            await withCheckedContinuation { continuation in
                if released { continuation.resume() }
                else { releaseWaiter = continuation }
            }
        }
        if fails { throw RuntimeFailure.failed }
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
    private var policyStarted = false
    private var policyCancelled = false
    private var policyObserver: CheckedContinuation<Void, Never>?
    func runPolicyRecoveryLoop() async throws {
        policyStarted = true
        policyObserver?.resume(); policyObserver = nil
        do { try await Task.sleep(for: .seconds(3_600)) }
        catch { policyCancelled = true; throw error }
    }
    func waitForPolicyLoop() async {
        if policyStarted { return }
        await withCheckedContinuation { policyObserver = $0 }
    }
    func policyLoopWasCancelled() -> Bool { policyCancelled }

    private let syncFailure: RuntimeFailure?
    private var synchronizations = 0
    private var starts = 0
    private var exits = 0
    func loopExitCount() -> Int { exits }
    private var availabilityWaiter: CheckedContinuation<Void, Never>?
    private var heartbeatWaiter: CheckedContinuation<Void, Never>?
    private var loopsWaiter: CheckedContinuation<Void, Never>?
    private var availabilityCancelled = false
    private var heartbeatCancelled = false
    private var roomCatchUpWaiter: CheckedContinuation<Void, Never>?
    private var roomCancellationObserver: CheckedContinuation<Void, Never>?
    private var roomCatchUpCancelled = false
    private var subscriptionWaiter: CheckedContinuation<Void, Never>?
    private var subscriptionCancellationObserver: CheckedContinuation<Void, Never>?
    private var subscriptionCancelled = false
    private var subscriptionIDs: [UUID?] = []

    init(syncFailure: RuntimeFailure? = nil) { self.syncFailure = syncFailure }

    func synchronizeAfterConnection() throws {
        synchronizations += 1
        if let syncFailure { throw syncFailure }
    }


    func runAvailabilityLoop() async throws {
        defer { exits += 1 }
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
        defer { exits += 1 }
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

    func runRoomCatchUpLoop() async throws {
        defer { exits += 1 }
        startedLoop()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if roomCatchUpCancelled || Task.isCancelled { continuation.resume() }
                else { roomCatchUpWaiter = continuation }
            }
        }, onCancel: { Task { await self.cancelRoomCatchUp() } })
        try Task.checkCancellation()
    }

    func runRoomSubscriptionLoop(connectionID: UUID?) async throws {
        defer { exits += 1 }
        subscriptionIDs.append(connectionID)
        startedLoop()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if subscriptionCancelled || Task.isCancelled { continuation.resume() }
                else { subscriptionWaiter = continuation }
            }
        }, onCancel: { Task { await self.cancelSubscription() } })
        try Task.checkCancellation()
    }

    func subscriptionConnectionIDs() -> [UUID?] { subscriptionIDs }
    func waitForSubscriptionCancellation() async {
        if subscriptionCancelled { return }
        await withCheckedContinuation { subscriptionCancellationObserver = $0 }
    }
    private func cancelSubscription() {
        subscriptionCancelled = true
        subscriptionWaiter?.resume()
        subscriptionWaiter = nil
        subscriptionCancellationObserver?.resume()
        subscriptionCancellationObserver = nil
    }

    func waitForRoomCatchUpCancellation() async {
        if roomCatchUpCancelled { return }
        await withCheckedContinuation { roomCancellationObserver = $0 }
    }

    private func cancelRoomCatchUp() {
        roomCatchUpCancelled = true
        roomCatchUpWaiter?.resume()
        roomCatchUpWaiter = nil
        roomCancellationObserver?.resume()
        roomCancellationObserver = nil
    }

    func waitForLoops() async {
        guard starts < 4 else { return }
        await withCheckedContinuation { loopsWaiter = $0 }
    }

    func syncCount() -> Int { synchronizations }
    func waitForInitialRecovery(count: Int) async {
        for _ in 0..<10000 {
            if synchronizations >= count { return }
            await Task.yield()
        }
    }
    func loopStartCount() -> Int { starts }

    private func startedLoop() {
        starts += 1
        if starts == 4 { loopsWaiter?.resume(); loopsWaiter = nil }
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

private actor SlowInitialRuntimeActivity: V2ClientRuntimeActivity {
    private var syncReleased = false
    private var syncWaiter: CheckedContinuation<Void, Never>?
    private var heartbeatStarted = false
    private var heartbeatObserver: CheckedContinuation<Void, Never>?
    private var syncCompletionCount = 0
    func synchronizeAfterConnection() async throws {
        if !syncReleased { await withCheckedContinuation { syncWaiter = $0 } }
        try Task.checkCancellation()
        syncCompletionCount += 1
    }
    func runAvailabilityLoop() async throws { while true { try await Task.sleep(for: .seconds(3600)) } }
    func runHeartbeatLoop() async throws {
        heartbeatStarted = true; heartbeatObserver?.resume(); heartbeatObserver = nil
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
    func waitForHeartbeat() async {
        if heartbeatStarted { return }
        await withCheckedContinuation { heartbeatObserver = $0 }
    }
    func releaseSync() { syncReleased = true; syncWaiter?.resume(); syncWaiter = nil }
    func completedSynchronizations() -> Int { syncCompletionCount }
}
