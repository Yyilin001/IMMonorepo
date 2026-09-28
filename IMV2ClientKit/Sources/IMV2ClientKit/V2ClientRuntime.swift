import Foundation

/// Connection-owned sync and live activity. Account operation dispatch is independent.
public protocol V2ClientRuntimeActivity: Sendable {
    func synchronizeAfterConnection() async throws
    func runAvailabilityLoop() async throws
    func runHeartbeatLoop() async throws
    func runRoomSubscriptionLoop(connectionID: UUID?) async throws
    func runRoomCatchUpLoop() async throws
    func runPolicyRecoveryLoop() async throws
}

extension V2ClientRuntimeActivity {
    public func runRoomCatchUpLoop() async throws {}
    public func runPolicyRecoveryLoop() async throws {}
    public func runRoomSubscriptionLoop(connectionID: UUID?) async throws {}
}

/// Owns sync, heartbeat, room subscriptions and post-sync projection maintenance.
/// Business mutations are dispatched by the account runtime's durable work executor.
public struct V2DefaultClientRuntimeActivity: V2ClientRuntimeActivity, Sendable {
    private let syncEngine: any V2SyncDriving
    private let availabilityRunner: V2AvailabilityDrivenSyncRunner
    private let heartbeatScheduler: V2HeartbeatScheduler
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
        afterDurableSynchronization: @escaping @Sendable () async throws -> Void = {},
        roomSubscriptionLoop: @escaping @Sendable (UUID?) async throws -> Void = { _ in },
        roomCatchUpLoop: @escaping @Sendable () async throws -> Void = {},
        policyRecoveryLoop: @escaping @Sendable () async throws -> Void = {},
        onProjectionSynchronized: @escaping @Sendable () async -> Void = {}
    ) {
        self.syncEngine = syncEngine
        self.availabilityRunner = .init(source: availabilitySource, syncEngine: syncEngine,
            afterSynchronization: {
                try await afterDurableSynchronization()
                await onProjectionSynchronized()
            })
        self.heartbeatScheduler = .init(sender: heartbeatSender, interval: heartbeatInterval)
        self.afterDurableSynchronization = afterDurableSynchronization
        self.roomCatchUpLoop = roomCatchUpLoop
        self.policyRecoveryLoop = policyRecoveryLoop
        self.roomSubscriptionLoop = roomSubscriptionLoop
        self.onProjectionSynchronized = onProjectionSynchronized
    }

    public func synchronizeAfterConnection() async throws {
        _ = try await syncEngine.synchronizeIncludingResets()
        try Task.checkCancellation()
        try await afterDurableSynchronization()
        await onProjectionSynchronized()
    }
    public func runAvailabilityLoop() async throws { try await availabilityRunner.run() }
    public func runHeartbeatLoop() async throws { try await heartbeatScheduler.run() }
    public func runPolicyRecoveryLoop() async throws { try await policyRecoveryLoop() }
    public func runRoomCatchUpLoop() async throws { try await roomCatchUpLoop() }
    public func runRoomSubscriptionLoop(connectionID: UUID?) async throws {
        try await roomSubscriptionLoop(connectionID)
    }
}

/// 运行时对外状态；stopped 表示逻辑阶段，不单独证明全部资源已排空。
public enum V2ClientRuntimeState: Equatable, Sendable {
    /// 当前未处于启动或运行阶段；清理操作可能仍在异步执行。
    case stopped
    /// 共享的认证连接任务正在执行。
    case starting
    /// 启动完成，携带认证会话；运行时拥有后续 live 循环。
    case running(V2AuthenticatedClientSession)
}

/// 前台连接、共享启动尝试及实时循环的生命周期所有者。
///
/// 同时 start 的调用者共享握手；首次同步独立运行，代次栅栏拒绝旧启动或循环失败影响新运行。
/// 非取消循环错误会断开当前代连接，由 App 决定是否重新连接，不自行把提示当成可靠成功。
/// 逻辑 stopped 与异步 drain 完成是不同边界，资源使用者应等待适当的关闭操作。
public actor V2ClientRuntime {
    private let connection: any V2RealtimeSessionConnecting
    private let activity: any V2ClientRuntimeActivity
    private var state: V2ClientRuntimeState = .stopped
    private var generation: UInt64 = 0
    private var startAttempt: StartAttempt?
    private var stopAttempt: Task<Void, Never>?
    private var availabilityTask: Task<Void, Never>?
    private var retiredTasks: [Task<Void, Never>] = []
    private var initialRecoveryTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var roomCatchUpTask: Task<Void, Never>?
    private var roomSubscriptionTask: Task<Void, Never>?
    private var policyRecoveryTask: Task<Void, Never>?
    private var stopWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// 注入认证连接和握手后的业务活动，不立即启动任务。
    ///
    /// - Parameters:
    ///   - connection: 负责建立认证会话和断开传输的依赖。
    ///   - activity: 可靠同步和实时循环的组合。
    public init(connection: any V2RealtimeSessionConnecting, activity: any V2ClientRuntimeActivity) {
        self.connection = connection
        self.activity = activity
    }

    /// 读取逻辑阶段快照；返回 stopped 不保证之前启动的所有任务已完成退出。
    public func currentState() -> V2ClientRuntimeState { state }

    /// 等待运行时停止通知，或等待者自身被取消。
    ///
    /// 已 stopped 时立即返回。取消仅移除并恢复该 waiter，不主动停止 runtime。
    /// 此方法不抛出 CancellationError，返回后应检查调用任务状态；停止通知也先于
    /// stop() 的全部异步资源收尾，因此不能用它代替等待 stop()。
    /// 启动失败与运行中失败的状态／通知路径应分别审核。
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

    /// 共享认证握手；握手完成即启动心跳、实时循环及独立首次同步。
    ///
    /// 已 running 时返回现有会话。多个调用者等待同一内部任务，单个等待者的取消不会
    /// 自动取消该任务；需要结束运行时生命周期时由所有者调用 stop()。
    ///
    /// - Returns: 当前代启动成功的认证会话。
    /// - Throws: 连接错误；尝试已被后续代次替换时抛出取消错误。首次同步错误归循环生命周期处理。
    ///
    /// 每个阶段间检查的是内部启动任务的取消状态，不能推断所有等待者仍有有效 UI 意图。
    public func start() async throws -> V2AuthenticatedClientSession {
        if let stopAttempt { await stopAttempt.value; try Task.checkCancellation() }
        if !retiredTasks.isEmpty {
            let retiring = retiredTasks; retiredTasks.removeAll()
            for task in retiring { await task.value }
            try Task.checkCancellation()
        }
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
            let task = Task { [connection] in
                let session = try await connection.connect()
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
            await connection.disconnect()
            throw error
        }
    }

    /// 结束当前运行时，取消启动与循环并等待捕获的任务收尾。
    ///
    /// 先提升 generation、摘除任务引用并发布 stopped，再断开连接并等待任务。
    /// 调用者应等待本次调用完成后再关闭依赖的存储。已经 stopped 且没有持有任务时，
    /// 会直接返回；并发 stop 共享同一个排空任务。
    public func stop() async {
        if let stopAttempt { await stopAttempt.value; return }
        guard state != .stopped || startAttempt != nil || availabilityTask != nil || heartbeatTask != nil || roomCatchUpTask != nil || roomSubscriptionTask != nil || policyRecoveryTask != nil || initialRecoveryTask != nil || !retiredTasks.isEmpty else {
            return
        }
        generation &+= 1
        let starting = startAttempt?.task
        let ownedLoops = [availabilityTask, heartbeatTask, roomCatchUpTask, roomSubscriptionTask, policyRecoveryTask, initialRecoveryTask].compactMap { $0 } + retiredTasks
        retiredTasks.removeAll()
        startAttempt?.task.cancel()
        startAttempt = nil
        initialRecoveryTask?.cancel()
        initialRecoveryTask = nil
        availabilityTask?.cancel()
        availabilityTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        roomCatchUpTask?.cancel()
        roomCatchUpTask = nil
        roomSubscriptionTask?.cancel()
        roomSubscriptionTask = nil
        policyRecoveryTask?.cancel()
        policyRecoveryTask = nil
        state = .stopped
        resumeStopWaiters()
        let draining = Task { [connection] in
            await connection.disconnect()
            _ = await starting?.result
            for loop in ownedLoops { await loop.value }
        }
        stopAttempt = draining
        await draining.value
        stopAttempt = nil
    }

    /// 为当前代创建权限恢复、房间订阅／追赶、同步提示和心跳任务。
    ///
    /// 取消错误只结束对应任务；其他错误携带原代次进入统一失败处理，避免旧任务关闭新连接。
    /// 这些是前台 runtime 所有的异步循环，不表示 iOS 系统授予后台执行时间。
    private func startBackgroundTasks(for taskGeneration: UInt64, connectionID: UUID?) {
        initialRecoveryTask?.cancel()
        initialRecoveryTask = Task { [weak self, activity] in
            do {
                try await activity.synchronizeAfterConnection()
                try Task.checkCancellation()
            } catch is CancellationError { return }
            catch { await self?.handleBackgroundFailure(generation: taskGeneration) }
        }
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
        roomCatchUpTask?.cancel()
        roomCatchUpTask = Task { [weak self, activity] in
            do { try await activity.runRoomCatchUpLoop() }
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

    /// 只处理当前 running 代的循环失败，撤下任务、通知停止并断开连接。
    ///
    /// 此路径取消其他循环但不逐一等待它们返回，不能视为与显式 stop 的完整 drain 相同。
    private func handleBackgroundFailure(generation failedGeneration: UInt64) async {
        guard generation == failedGeneration, case .running = state else { return }
        retiredTasks.append(contentsOf: [availabilityTask, heartbeatTask, roomCatchUpTask,
            roomSubscriptionTask, policyRecoveryTask, initialRecoveryTask].compactMap { $0 })
        generation &+= 1
        initialRecoveryTask?.cancel()
        initialRecoveryTask = nil
        availabilityTask?.cancel()
        availabilityTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        roomCatchUpTask?.cancel()
        roomCatchUpTask = nil
        roomSubscriptionTask?.cancel()
        roomSubscriptionTask = nil
        policyRecoveryTask?.cancel()
        policyRecoveryTask = nil
        state = .stopped
        resumeStopWaiters()
        await connection.disconnect()
    }

    /// 仅恢复对应取消等待者，保留其他 waiter 和运行时状态。
    private func cancelStopWaiter(_ waiterID: UUID) {
        stopWaiters.removeValue(forKey: waiterID)?.resume()
    }

    /// 摘除并恢复当前登记的全部停止等待者，每个 continuation 最多恢复一次。
    private func resumeStopWaiters() {
        let waiters = stopWaiters.values
        stopWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }
}

/// 一次共享启动的稳定身份、generation 与任务，供多个 start 调用者比较是否仍属当前尝试。
private struct StartAttempt {
    let id: UUID
    let generation: UInt64
    let task: Task<V2AuthenticatedClientSession, Error>
}
