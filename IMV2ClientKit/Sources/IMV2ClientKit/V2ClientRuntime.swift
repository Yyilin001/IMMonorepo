import Foundation

/// Effects that are valid only after the realtime handshake has completed.
/// `synchronizeAfterConnection` owns the initial durable catch-up; the runtime
/// loops are long-lived, best-effort triggers and are cancelled together when
/// the runtime stops.
public protocol V2ClientRuntimeActivity: Sendable {
    func synchronizeAfterConnection() async throws
    func flushDurableCommands() async throws
    func resumeDurableCommands() async
    func suspendDurableCommands() async
    func runAvailabilityLoop() async throws
    func runHeartbeatLoop() async throws
    func runCommandRetryLoop() async throws
    func runRoomSubscriptionLoop(connectionID: UUID?) async throws
    func runRoomCatchUpLoop() async throws
    func runPolicyRecoveryLoop() async throws
}

extension V2ClientRuntimeActivity {
    public func runCommandRetryLoop() async throws {}
    public func runRoomCatchUpLoop() async throws {}
    public func runPolicyRecoveryLoop() async throws {}
    public func runRoomSubscriptionLoop(connectionID: UUID?) async throws {}
    public func resumeDurableCommands() async {}
    public func suspendDurableCommands() async {}
}

/// Default V2 activity composition. A reset is completely materialized and
/// acknowledged before the runtime starts live availability or heartbeat
/// loops.  Priority user commands are flushed before optional post-sync
/// maintenance, so large background histories cannot block sending.
public struct V2DefaultClientRuntimeActivity: V2ClientRuntimeActivity, Sendable {
    private let syncEngine: any V2SyncDriving
    private let availabilityRunner: V2AvailabilityDrivenSyncRunner
    private let heartbeatScheduler: V2HeartbeatScheduler
    private let commandOutbox: (any V2ClientCommandFlushing)?
    private let commandRetrySchedule: V2CommandRetrySchedule?
    private let commandLifecycles: [any V2CommandFlushControlling]
    private let maximumInitialCommandFlushes: Int
    private let flushAdditionalDurableCommands: @Sendable () async throws -> Void
    private let afterDurableSynchronization: @Sendable () async throws -> Void
    private let roomSubscriptionLoop: @Sendable (UUID?) async throws -> Void
    private let roomCatchUpLoop: @Sendable () async throws -> Void
    private let policyRecoveryLoop: @Sendable () async throws -> Void
    private let onProjectionSynchronized: @Sendable () async -> Void

    public init(
        syncEngine: any V2SyncDriving,
        availabilitySource: any V2SyncAvailabilityHintSource,
        heartbeatSender: any V2HeartbeatSender,
        heartbeatInterval: Duration,
        commandOutbox: (any V2ClientCommandFlushing)? = nil,
        maximumInitialCommandFlushes: Int = 256,
        commandLifecycles: [any V2CommandFlushControlling] = [],
        commandRetrySchedule: V2CommandRetrySchedule? = nil,
        flushAdditionalDurableCommands: @escaping @Sendable () async throws -> Void = {},
        afterDurableSynchronization: @escaping @Sendable () async throws -> Void = {},
        roomSubscriptionLoop: @escaping @Sendable (UUID?) async throws -> Void = { _ in },
        roomCatchUpLoop: @escaping @Sendable () async throws -> Void = {},
        policyRecoveryLoop: @escaping @Sendable () async throws -> Void = {},
        onProjectionSynchronized: @escaping @Sendable () async -> Void = {}
    ) {
        precondition(maximumInitialCommandFlushes > 0)
        self.syncEngine = syncEngine
        self.availabilityRunner = .init(
            source: availabilitySource,
            syncEngine: syncEngine,
            afterSynchronization: { [commandOutbox, maximumInitialCommandFlushes, flushAdditionalDurableCommands, afterDurableSynchronization, onProjectionSynchronized] in
                try await Self.flush(
                    commandOutbox: commandOutbox,
                    maximumFlushes: maximumInitialCommandFlushes,
                    flushAdditionalDurableCommands: flushAdditionalDurableCommands
                )
                try await afterDurableSynchronization()
                await onProjectionSynchronized()
            }
        )
        self.heartbeatScheduler = .init(sender: heartbeatSender, interval: heartbeatInterval)
        self.commandOutbox = commandOutbox
        self.commandLifecycles = commandLifecycles
        self.commandRetrySchedule = commandRetrySchedule
        self.maximumInitialCommandFlushes = maximumInitialCommandFlushes
        self.flushAdditionalDurableCommands = flushAdditionalDurableCommands
        self.afterDurableSynchronization = afterDurableSynchronization
        self.roomCatchUpLoop = roomCatchUpLoop
        self.policyRecoveryLoop = policyRecoveryLoop
        self.roomSubscriptionLoop = roomSubscriptionLoop
        self.onProjectionSynchronized = onProjectionSynchronized
    }

    public func resumeDurableCommands() async {
        for lane in commandLifecycles { await lane.resumeCommandFlushing() }
    }

    public func suspendDurableCommands() async {
        for lane in commandLifecycles { await lane.suspendCommandFlushing() }
    }

    public func synchronizeAfterConnection() async throws {
        if case .resetPending = try await syncEngine.synchronizeUntilCaughtUp() {
            try await syncEngine.completePendingReset()
        }
        await onProjectionSynchronized()
    }

    /// Replays at most one configured batch after the durable initial sync.
    /// Every command still retains its immutable ID and local retry schedule;
    /// a huge offline queue never monopolizes the foreground connection.
    public func flushDurableCommands() async throws {
        try await Self.flush(
            commandOutbox: commandOutbox,
            maximumFlushes: maximumInitialCommandFlushes,
            flushAdditionalDurableCommands: flushAdditionalDurableCommands
        )
        try await afterDurableSynchronization()
        await onProjectionSynchronized()
    }

    private static func flush(
        commandOutbox: (any V2ClientCommandFlushing)?,
        maximumFlushes: Int,
        flushAdditionalDurableCommands: @Sendable () async throws -> Void
    ) async throws {
        if let commandOutbox {
            for _ in 0 ..< maximumFlushes {
                try Task.checkCancellation()
                guard case .idle = try await commandOutbox.flushOnce() else { continue }
                break
            }
        }
        try Task.checkCancellation()
        try await flushAdditionalDurableCommands()
    }

    public func runCommandRetryLoop() async throws {
        guard let commandRetrySchedule else { return }
        try await V2CommandRetryScheduler(schedule: commandRetrySchedule, flush: {
            try await Self.flush(
                commandOutbox: commandOutbox,
                maximumFlushes: maximumInitialCommandFlushes,
                flushAdditionalDurableCommands: flushAdditionalDurableCommands
            )
            await onProjectionSynchronized()
        }).run()
    }

    public func runAvailabilityLoop() async throws {
        try await availabilityRunner.run()
    }

    public func runHeartbeatLoop() async throws {
        try await heartbeatScheduler.run()
    }

    public func runPolicyRecoveryLoop() async throws { try await policyRecoveryLoop() }

    public func runRoomCatchUpLoop() async throws {
        try await roomCatchUpLoop()
    }

    public func runRoomSubscriptionLoop(connectionID: UUID?) async throws {
        try await roomSubscriptionLoop(connectionID)
    }
}

public enum V2ClientRuntimeState: Equatable, Sendable {
    case stopped
    case starting
    case running(V2AuthenticatedClientSession)
}

/// Owns foreground realtime lifecycle, its single start attempt, and all live
/// synchronization, retry and subscription tasks. A failing live loop closes
/// the connection so the app can make an explicit retry decision; it never
/// silently treats a wake signal as durable delivery.
public actor V2ClientRuntime {
    private let connection: any V2RealtimeSessionConnecting
    private let activity: any V2ClientRuntimeActivity
    private var state: V2ClientRuntimeState = .stopped
    private var generation: UInt64 = 0
    private var startAttempt: StartAttempt?
    private var availabilityTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var commandRetryTask: Task<Void, Never>?
    private var roomCatchUpTask: Task<Void, Never>?
    private var roomSubscriptionTask: Task<Void, Never>?
    private var policyRecoveryTask: Task<Void, Never>?
    private var stopWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init(connection: any V2RealtimeSessionConnecting, activity: any V2ClientRuntimeActivity) {
        self.connection = connection
        self.activity = activity
    }

    public func currentState() -> V2ClientRuntimeState { state }

    /// Waits for a running/starting lifecycle to reach its terminal stopped
    /// state. The app owns reconnection policy; this actor only exposes the
    /// transition so foreground recovery has no polling race.
    public func waitUntilStopped() async {
        guard state != .stopped else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard state != .stopped else {
                    continuation.resume()
                    return
                }
                stopWaiters[waiterID] = continuation
            }
        }, onCancel: {
            Task { await self.cancelStopWaiter(waiterID) }
        })
    }

    /// Connects and completes initial durable sync before live tasks exist.
    /// Simultaneous callers share the same result rather than performing two
    /// TLS handshakes or two initial pulls.
    public func start() async throws -> V2AuthenticatedClientSession {
        let attempt: StartAttempt
        if let startAttempt {
            attempt = startAttempt
        } else if case .running(let session) = state {
            return session
        } else {
            let id = UUID()
            generation &+= 1
            let attemptGeneration = generation
            state = .starting
            let task = Task { [connection, activity] in
                let session = try await connection.connect()
                try Task.checkCancellation()
                await activity.resumeDurableCommands()
                try Task.checkCancellation()
                try await activity.synchronizeAfterConnection()
                try Task.checkCancellation()
                try await activity.flushDurableCommands()
                try Task.checkCancellation()
                return session
            }
            attempt = .init(id: id, generation: attemptGeneration, task: task)
            startAttempt = attempt
        }

        let result = await attempt.task.result
        guard generation == attempt.generation else {
            throw CancellationError()
        }
        guard startAttempt?.id == attempt.id else {
            if case .running(let session) = state { return session }
            return try result.get()
        }
        startAttempt = nil
        switch result {
        case .success(let session):
            state = .running(session)
            startBackgroundTasks(for: attempt.generation, connectionID: session.connectionID)
            return session
        case .failure(let error):
            state = .stopped
            await activity.suspendDurableCommands()
            await connection.disconnect()
            throw error
        }
    }

    /// The app calls this on backgrounding or logout. It is idempotent and
    /// fences late completion of a previously suspended start attempt.
    public func stop() async {
        guard state != .stopped || startAttempt != nil || availabilityTask != nil || heartbeatTask != nil || commandRetryTask != nil || roomCatchUpTask != nil || roomSubscriptionTask != nil || policyRecoveryTask != nil else {
            await activity.suspendDurableCommands()
            return
        }
        generation &+= 1
        let starting = startAttempt?.task
        let ownedLoops = [availabilityTask, heartbeatTask, commandRetryTask, roomCatchUpTask, roomSubscriptionTask, policyRecoveryTask].compactMap { $0 }
        startAttempt?.task.cancel()
        startAttempt = nil
        availabilityTask?.cancel()
        availabilityTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        commandRetryTask?.cancel()
        commandRetryTask = nil
        roomCatchUpTask?.cancel()
        roomCatchUpTask = nil
        roomSubscriptionTask?.cancel()
        roomSubscriptionTask = nil
        policyRecoveryTask?.cancel()
        policyRecoveryTask = nil
        state = .stopped
        resumeStopWaiters()
        await activity.suspendDurableCommands()
        await connection.disconnect()
        _ = await starting?.result
        for loop in ownedLoops { await loop.value }
    }

    private func startBackgroundTasks(for taskGeneration: UInt64, connectionID: UUID?) {
        policyRecoveryTask?.cancel()
        policyRecoveryTask = Task { [weak self, activity] in
            do { try await activity.runPolicyRecoveryLoop() }
            catch is CancellationError { return }
            catch { await self?.handleBackgroundFailure(generation: taskGeneration) }
        }
        roomSubscriptionTask?.cancel()
        roomSubscriptionTask = Task { [weak self, activity] in
            do { try await activity.runRoomSubscriptionLoop(connectionID: connectionID) }
            catch is CancellationError { return }
            catch { await self?.handleBackgroundFailure(generation: taskGeneration) }
        }
        availabilityTask?.cancel()
        heartbeatTask?.cancel()
        commandRetryTask?.cancel()
        roomCatchUpTask?.cancel()
        roomCatchUpTask = Task { [weak self, activity] in
            do { try await activity.runRoomCatchUpLoop() }
            catch is CancellationError { return }
            catch { await self?.handleBackgroundFailure(generation: taskGeneration) }
        }
        commandRetryTask = Task { [weak self, activity] in
            do { try await activity.runCommandRetryLoop() }
            catch is CancellationError { return }
            catch { await self?.handleBackgroundFailure(generation: taskGeneration) }
        }
        availabilityTask = Task { [weak self, activity] in
            do {
                try await activity.runAvailabilityLoop()
            } catch is CancellationError {
                return
            } catch {
                await self?.handleBackgroundFailure(generation: taskGeneration)
            }
        }
        heartbeatTask = Task { [weak self, activity] in
            do {
                try await activity.runHeartbeatLoop()
            } catch is CancellationError {
                return
            } catch {
                await self?.handleBackgroundFailure(generation: taskGeneration)
            }
        }
    }

    private func handleBackgroundFailure(generation failedGeneration: UInt64) async {
        guard generation == failedGeneration, case .running = state else { return }
        generation &+= 1
        availabilityTask?.cancel()
        availabilityTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        commandRetryTask?.cancel()
        commandRetryTask = nil
        roomCatchUpTask?.cancel()
        roomCatchUpTask = nil
        roomSubscriptionTask?.cancel()
        roomSubscriptionTask = nil
        policyRecoveryTask?.cancel()
        policyRecoveryTask = nil
        state = .stopped
        resumeStopWaiters()
        await activity.suspendDurableCommands()
        await connection.disconnect()
    }

    private func cancelStopWaiter(_ waiterID: UUID) {
        stopWaiters.removeValue(forKey: waiterID)?.resume()
    }

    private func resumeStopWaiters() {
        let waiters = stopWaiters.values
        stopWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }
}

private struct StartAttempt {
    let id: UUID
    let generation: UInt64
    let task: Task<V2AuthenticatedClientSession, Error>
}
