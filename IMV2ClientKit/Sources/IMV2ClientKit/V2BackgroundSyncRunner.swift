import Foundation

/// 后台同步的总页面预算与工作期限，不包含硬性操作系统执行保证。
public struct V2BackgroundSyncBudget: Sendable {
    /// 个人增量与可选房间日志共享的页面预算。
    public let maximumPages: Int
    /// 从本轮工作开始计算的最长工作时长，连接清理与任务收尾可能延后最终返回。
    public let workDuration: Duration
    /// 创建后台预算，默认四页、25 秒；页数须在 1 到 10000 内且时长为正，否则触发前置条件失败。
    public init(maximumPages: Int = 4, workDuration: Duration = .seconds(25)) {
        precondition(maximumPages > 0 && maximumPages <= 10_000 && workDuration > .zero)
        self.maximumPages = maximumPages
        self.workDuration = workDuration
    }
}

/// 后台同步自身的期限错误；deadlineReached 表示工作或等待者期限已到。
public enum V2BackgroundSyncError: Error, Equatable, Sendable { case deadlineReached }

/// 拥有专用后台连接的有界同步执行器。
///
/// 并发推送共享一次操作，前台切换或退出登录通过 stop 取消并排空此执行器。
/// 组装层必须提供专用连接，不能把前台 socket 作为其连接依赖；本地存储由外层在停止后关闭。
public actor V2BackgroundSyncRunner {
    /// 此执行器独占的后台会话连接。
    private let connection: any V2RealtimeSessionConnecting
    /// 处理个人增量的同步引擎。
    private let syncEngine: V2SyncEngine
    /// 可选可靠房间日志引擎，与个人增量共享页面和时间预算。
    private let roomSync: V2GroupEventSyncEngine?
    /// 一次共享后台操作的默认预算。
    private let budget: V2BackgroundSyncBudget
    /// 当前共享后台操作及其身份。
    private var flight: (id: UUID, task: V2SharedOperation<V2IncrementalSyncResult>)?
    /// 可供并发 stop 调用共同等待的排空任务。
    private var stopping: (id: UUID, task: Task<Void, Never>)?

    /// 配置专用后台连接、同步引擎和预算，不启动工作。
    ///
    /// - Parameters:
    ///   - connection: 专用后台会话连接。
    ///   - syncEngine: 个人增量引擎。
    ///   - roomSync: 可选房间日志引擎。
    ///   - budget: 一次共享操作的页面和时间预算。
    public init(connection: any V2RealtimeSessionConnecting, syncEngine: V2SyncEngine, roomSync: V2GroupEventSyncEngine? = nil, budget: V2BackgroundSyncBudget = .init()) {
        self.connection = connection
        self.syncEngine = syncEngine
        self.roomSync = roomSync
        self.budget = budget
    }

    deinit { flight?.task.cancel() }

    /// 发起或加入一轮有界后台同步。
    ///
    /// - Parameter deadline: 调用方可选的单调时钟截止时间；已到期时立即失败。
    /// - Returns: 个人与可选房间日志合并后的处理结果，可能仍需快照恢复或后续页面。
    /// - Throws: 取消、停止中、期限到达、连接或同步错误。
    ///
    /// 发起者的期限参与共享操作截止时间，发起者等待其连接收尾；加入者可使用更早的个人期限退出等待，
    /// 不因此取消其他调用者的共享工作。停止期间拒绝新工作。
    public func run(until deadline: ContinuousClock.Instant? = nil) async throws -> V2IncrementalSyncResult {
        try Task.checkCancellation()
        if let deadline, deadline <= .now { throw V2BackgroundSyncError.deadlineReached }
        guard stopping == nil else { throw CancellationError() }
        let operation: (id: UUID, task: V2SharedOperation<V2IncrementalSyncResult>)
        let joinedFlight: Bool
        if let flight { operation = flight; joinedFlight = true }
        else {
            joinedFlight = false
            let id = UUID()
            operation = (id, V2SharedOperation { [weak self, connection, syncEngine, roomSync, budget] in
                do {
                    let result = try await Self.catchUp(connection: connection, engine: syncEngine, roomSync: roomSync, budget: budget, callerDeadline: deadline)
                    await self?.finishFlight(id)
                    return result
                } catch {
                    await self?.finishFlight(id)
                    throw error
                }
            })
            flight = operation
        }
        // Each caller may have spent a different amount of its budget in
        // restoration. Leaving a shared flight does not cancel other pushes.
        // The initiating caller waits for its owned connection to drain at
        // the shared deadline. Only a joining caller can leave sooner.
        if joinedFlight, let deadline {
            return try await withThrowingTaskGroup(of: V2IncrementalSyncResult.self) { group in
                group.addTask { try await operation.task.value }
                group.addTask {
                    try await ContinuousClock().sleep(until: deadline)
                    throw V2BackgroundSyncError.deadlineReached
                }
                defer { group.cancelAll() }
                let result = try await group.next()!
                return result
            }
        }
        return try await operation.task.value
    }

    /// 只清除身份匹配的已结束操作，避免旧任务清理后来建立的共享操作。
    private func finishFlight(_ id: UUID) {
        if flight?.id == id { flight = nil }
    }

    /// 停止接收新工作，取消当前共享操作并断开专用连接，然后等待操作结束。
    ///
    /// 并发停止调用共享同一排空任务；完成后按身份清理状态，执行器可再次运行。此方法不关闭本地存储。
    public func stop() async {
        let drainingID = flight?.id
        let operation: (id: UUID, task: Task<Void, Never>)
        if let stopping { operation = stopping }
        else {
            let current = flight
            operation = (UUID(), Task { [connection] in
                current?.task.cancel()
                await connection.disconnect()
                _ = await current?.task.result
            })
            stopping = operation
        }
        await operation.task.value
        if stopping?.id == operation.id {
            stopping = nil
            if flight?.id == drainingID { flight = nil }
        }
    }

    /// 在默认期限与发起者期限的较早者之前执行连接和有界补拉。
    ///
    /// 配置房间引擎时先给个人流分配至少一页、约半数总预算，再把剩余预算交给房间日志；
    /// 个人流遇到 resetPending 时不下载快照，也不继续房间补拉。合并结果保留是否新增记录和是否仍有工作。
    ///
    /// 成功、异常或超时均请求取消组内任务并断开连接，任务组退出仍需等待子任务收尾，
    /// 因此工作截止时间不是方法返回的硬性时间上限。
    private static func catchUp(connection: any V2RealtimeSessionConnecting, engine: V2SyncEngine, roomSync: V2GroupEventSyncEngine?, budget: V2BackgroundSyncBudget, callerDeadline: ContinuousClock.Instant?) async throws -> V2IncrementalSyncResult {
        let ownDeadline = ContinuousClock.now.advanced(by: budget.workDuration)
        let deadline = min(ownDeadline, callerDeadline ?? ownDeadline)
        return try await withThrowingTaskGroup(of: V2IncrementalSyncResult.self) { group in
            group.addTask {
                _ = try await connection.connect()
                try Task.checkCancellation()
                // Reserve room-log work so a hot personal stream cannot
                // consume every push budget. Both feeds share the deadline.
                let personalBudget = roomSync == nil ? budget.maximumPages : max(1, budget.maximumPages / 2)
                let personal = try await engine.synchronizeIncrementally(maximumPages: personalBudget)
                guard personal.stopReason != .resetPending, let roomSync,
                      budget.maximumPages > personal.processedPageCount else { return personal }
                try Task.checkCancellation()
                let rooms = try await roomSync.synchronizeBackgroundKnownRooms(maximumPages: budget.maximumPages - personal.processedPageCount)
                return .init(processedPageCount: personal.processedPageCount + rooms.processedPageCount,
                             didCommitNewRecords: personal.didCommitNewRecords || rooms.appliedEventCount > 0,
                             stopReason: personal.stopReason == .pageLimit || rooms.mayHaveRemainingWork ? .pageLimit : .caughtUp)
            }
            group.addTask {
                try await ContinuousClock().sleep(until: deadline)
                throw V2BackgroundSyncError.deadlineReached
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                await connection.disconnect()
                return result
            } catch {
                group.cancelAll()
                // Cancels the owned coordinator handshake and NWConnection
                // so the task group can drain an in-flight send/receive.
                await connection.disconnect()
                throw error
            }
        }
    }
}
