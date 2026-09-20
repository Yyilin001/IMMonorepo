import Foundation

/// 握手成功后运行的可靠同步、命令与实时循环能力。
///
/// runtime 负责创建和取消循环。实现者应响应取消，并区分可靠落盘工作与可丢失提示。
/// 部分能力提供空默认实现；采用默认实现不代表对应恢复或订阅能力已经启用。
public protocol V2ClientRuntimeActivity: Sendable {
    /// 完成首次可靠同步和必要 reset，再允许 runtime 启动实时循环。
    ///
    /// - Throws: 同步、存储、恢复或取消错误；失败阻止启动进入 running。
    func synchronizeAfterConnection() async throws
    /// 执行启动后的有界命令处理与适用维护。
    ///
    /// - Throws: 处理或取消错误；不得把队列未排空等同于所有用户操作完成。
    func flushDurableCommands() async throws
    /// 恢复各持久命令 lane 的 flush 准入；不改变原命令身份。
    func resumeDurableCommands() async
    /// 暂停各持久命令 lane，并按其生命周期合同收尾正在执行的 flush。
    func suspendDurableCommands() async
    /// 消费实时可用提示并触发可靠同步；提示本身不是投递确认。
    func runAvailabilityLoop() async throws
    /// 运行连接心跳；未处理的非取消错误交由 runtime 结束本代连接。
    func runHeartbeatLoop() async throws
    /// 按持久到期时间运行命令重试循环，不能只等待新消息提示。
    func runCommandRetryLoop() async throws
    /// 维持本代连接的房间兴趣订阅。
    ///
    /// - Parameter connectionID: 实际连接代次，供拒绝旧连接的迟到状态使用。
    func runRoomSubscriptionLoop(connectionID: UUID?) async throws
    /// 运行房间历史追赶；每轮预算耗尽后由具体实现安排后续有限轮次。
    func runRoomCatchUpLoop() async throws
    /// 执行权限策略恢复循环；取消与失败应沿调用链返回。
    func runPolicyRecoveryLoop() async throws
}

extension V2ClientRuntimeActivity {
    /// 可选能力的空默认实现；生产组装需要此能力时必须显式提供实现。
    public func runCommandRetryLoop() async throws {}
    /// 可选能力的空默认实现；生产组装需要此能力时必须显式提供实现。
    public func runRoomCatchUpLoop() async throws {}
    /// 可选能力的空默认实现；生产组装需要此能力时必须显式提供实现。
    public func runPolicyRecoveryLoop() async throws {}
    /// 可选能力的空默认实现；生产组装需要此能力时必须显式提供实现。
    public func runRoomSubscriptionLoop(connectionID: UUID?) async throws {}
    /// 可选能力的空默认实现；生产组装需要此能力时必须显式提供实现。
    public func resumeDurableCommands() async {}
    /// 可选能力的空默认实现；生产组装需要此能力时必须显式提供实现。
    public func suspendDurableCommands() async {}
}

/// 默认同步、心跳和持久命令的运行时组合。
///
/// 首次可靠同步及 reset 完成后再启动 live 循环。命令处理先于可选同步后维护，
/// 但是否启用额外 lane、房间订阅和权限恢复取决于构造时注入的依赖。
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

    /// 组装默认可靠同步和长生命周期活动。
    ///
    /// - Parameters:
    ///   - syncEngine: 增量追赶及 reset 驱动。
    ///   - availabilitySource: 可丢失的同步提示来源。
    ///   - heartbeatSender: 心跳传输能力。
    ///   - heartbeatInterval: 心跳调度间隔，遵守心跳调度器要求。
    ///   - commandOutbox: 可选主命令队列；nil 时只处理额外注入命令。
    ///   - maximumInitialCommandFlushes: 主队列每批最大 flush 次数，必须为正。
    ///   - commandLifecycles: 随 runtime 暂停／恢复的全部命令 lane。
    ///   - commandRetrySchedule: 可选持久到期时间来源；nil 时不启动此重试循环。
    ///   - flushAdditionalDurableCommands: 主队列本轮结束后处理的额外命令。
    ///   - afterDurableSynchronization: 命令处理后的可选维护。
    ///   - roomSubscriptionLoop: 带连接身份的房间订阅循环。
    ///   - roomCatchUpLoop: 房间历史追赶循环。
    ///   - policyRecoveryLoop: 权限恢复循环。
    ///   - onProjectionSynchronized: 可靠投影更新后的通知，不承担数据库提交。
    ///
    /// 多数闭包默认无操作；构造成功不证明相关产品功能已被接入。
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

    /// 顺序恢复所有注入的命令 lane；不自动为未列入的 outbox 提供生命周期管理。
    public func resumeDurableCommands() async {
        for lane in commandLifecycles { await lane.resumeCommandFlushing() }
    }

    /// 顺序暂停所有注入的命令 lane，等待各 lane 自己的暂停合同完成。
    public func suspendDurableCommands() async {
        for lane in commandLifecycles { await lane.suspendCommandFlushing() }
    }

    /// 追赶个人增量；若需 reset，激活快照并追平其后增量，才通知投影已同步。
    ///
    /// 此方法不直接运行无限实时循环；返回后由 runtime 接续命令处理与 live 活动。
    public func synchronizeAfterConnection() async throws {
        _ = try await syncEngine.synchronizeIncludingResets()
        await onProjectionSynchronized()
    }

    /// 处理一批有界主队列和额外命令，然后执行维护并通知投影更新。
    ///
    /// 只限制主队列的次数；额外命令闭包和维护自身仍需提供有限工作与取消合同。
    public func flushDurableCommands() async throws {
        try await Self.flush(
            commandOutbox: commandOutbox,
            maximumFlushes: maximumInitialCommandFlushes,
            flushAdditionalDurableCommands: flushAdditionalDurableCommands
        )
        try await afterDurableSynchronization()
        await onProjectionSynchronized()
    }

    /// 最多处理一批主队列，在 idle 时提前停止；随后检查取消并运行额外命令闭包。
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

    /// 有重试 schedule 时按持久到期时间驱动命令，完成后通知投影；未配置时立即返回。
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

    /// 消费可用提示并运行可靠同步及同步后动作；提示丢失的恢复不由提示本身证明。
    public func runAvailabilityLoop() async throws {
        try await availabilityRunner.run()
    }

    /// 运行注入心跳调度器，错误与取消交由 runtime 的循环所有者处理。
    public func runHeartbeatLoop() async throws {
        try await heartbeatScheduler.run()
    }

    /// 运行注入的权限恢复活动；默认闭包为空，不自动提供恢复实现。
    public func runPolicyRecoveryLoop() async throws { try await policyRecoveryLoop() }

    /// 运行注入的房间追赶活动，其公平性和每轮预算由具体实现负责。
    public func runRoomCatchUpLoop() async throws {
        try await roomCatchUpLoop()
    }

    /// 把当前连接身份交给订阅活动，供重建兴趣及拒绝旧连接结果使用。
    public func runRoomSubscriptionLoop(connectionID: UUID?) async throws {
        try await roomSubscriptionLoop(connectionID)
    }
}

/// 运行时对外状态；stopped 表示逻辑阶段，不单独证明全部资源已排空。
public enum V2ClientRuntimeState: Equatable, Sendable {
    /// 当前未处于启动或运行阶段；清理操作可能仍在异步执行。
    case stopped
    /// 共享的连接与首次同步任务正在执行。
    case starting
    /// 启动完成，携带认证会话；运行时拥有后续 live 循环。
    case running(V2AuthenticatedClientSession)
}

/// 前台连接、共享启动尝试及实时循环的生命周期所有者。
///
/// 同时 start 的调用者共享握手和首次同步；代次栅栏拒绝旧启动或循环失败影响新运行。
/// 非取消循环错误会断开当前代连接，由 App 决定是否重新连接，不自行把提示当成可靠成功。
/// 逻辑 stopped 与异步 drain 完成是不同边界，资源使用者应等待适当的关闭操作。
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

    /// 注入认证连接和握手后的业务活动，不立即启动任务。
    ///
    /// - Parameters:
    ///   - connection: 负责建立认证会话和断开传输的依赖。
    ///   - activity: 可靠同步、命令生命周期和实时循环的组合。
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

    /// 共享启动尝试，依次连接、恢复命令、首次同步和有界 flush，然后启动实时循环。
    ///
    /// 已 running 时返回现有会话。多个调用者等待同一内部任务，单个等待者的取消不会
    /// 自动取消该任务；需要结束运行时生命周期时由所有者调用 stop()。
    ///
    /// - Returns: 当前代启动成功的认证会话。
    /// - Throws: 连接、同步或命令处理错误；尝试已被后续代次替换时抛出取消错误。
    ///
    /// 每个阶段间检查的是内部启动任务的取消状态，不能推断所有等待者仍有有效 UI 意图。
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

    /// 结束当前运行时，取消启动与循环并等待捕获的任务收尾。
    ///
    /// 先提升 generation、摘除任务引用并发布 stopped，再暂停命令、断开连接并等待任务。
    /// 调用者应等待本次调用完成后再关闭依赖的存储。已经 stopped 且没有持有任务时，
    /// 仍会执行命令暂停；该快速路径不额外等待另一次并发 stop 已摘走的任务。
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

    /// 为当前代创建权限恢复、房间订阅／追赶、重试、同步提示和心跳任务。
    ///
    /// 取消错误只结束对应任务；其他错误携带原代次进入统一失败处理，避免旧任务关闭新连接。
    /// 这些是前台 runtime 所有的异步循环，不表示 iOS 系统授予后台执行时间。
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

    /// 只处理当前 running 代的循环失败，撤下任务、通知停止并断开连接。
    ///
    /// 此路径取消其他循环但不逐一等待它们返回，不能视为与显式 stop 的完整 drain 相同。
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
