import Foundation

/// 由运行时持有的房间日志追赶工作器。
///
/// 唤醒会被合并，包括在循环启动之前或页面提交期间收到的唤醒。
/// 每次重连都会从持久化游标继续；对于已经发现积压的场景，页与页之间不再需要界面或可用性提示。
public actor V2RoomLogCatchUpWorker {
    private let engine: V2GroupEventSyncEngine
    private let maximumPagesPerRound: Int
    private let onProgress: @Sendable (V2GroupEventBackgroundSyncProgress) async -> Void
    private var requested = false
    private var runID: UUID?
    private var waiter: (id: UUID, continuation: CheckedContinuation<Void, Never>)?

    /// 组合同步引擎与单轮页数上限。
    ///
    /// - Parameters:
    ///   - engine: 执行房间日志同步的引擎。
    ///   - maximumPagesPerRound: 单轮最多处理的页数，需落在 `1...10000`。
    ///   - onProgress: 进度回调，默认忽略。
    ///
    /// 页数上限越界时直接失败，避免出现无界追赶。
    public init(
        engine: V2GroupEventSyncEngine,
        maximumPagesPerRound: Int = 12,
        onProgress: @escaping @Sendable (V2GroupEventBackgroundSyncProgress) async -> Void = { _ in }
    ) {
        precondition(maximumPagesPerRound > 0 && maximumPagesPerRound <= 10_000)
        self.engine = engine
        self.maximumPagesPerRound = maximumPagesPerRound
        self.onProgress = onProgress
    }

    /// 请求一次追赶；已有等待者会被立即唤醒。
    public func requestCatchUp() {
        requested = true
        waiter?.continuation.resume()
        waiter = nil
    }

    /// 持续运行追赶循环，直到任务被取消。
    ///
    /// 启动时会先自行请求一次追赶，使替换后的运行时总是重新检查其持久化目录；
    /// 被取消的旧一轮由引擎的串行轮次所有权负责排空。
    ///
    /// - Throws: 任务取消时抛出 `CancellationError`；其余错误来自同步引擎。
    public func run() async throws {
        let id = UUID()
        runID = id
        // A replacement runtime always rechecks its durable directory. Its
        // old cancelled pass is drained by the engine's serialized pass owner.
        requestCatchUp()
        defer { if runID == id { runID = nil } }
        while true {
            try Task.checkCancellation()
            guard runID == id else { throw CancellationError() }
            if !requested { await waitForRequest() }
            try Task.checkCancellation()
            guard runID == id else { throw CancellationError() }
            requested = false
            var remaining = false
            repeat {
                try Task.checkCancellation()
                guard runID == id else { throw CancellationError() }
                let progress: V2GroupEventBackgroundSyncProgress
                do {
                    progress = try await engine.synchronizeBackgroundKnownRooms(maximumPages: maximumPagesPerRound)
                } catch V2ClientSyncError.resetPending {
                    // Snapshot activation temporarily fences projections.
                    // The personal-sync completion requests the next pass;
                    // keep its connection and staged reset alive meanwhile.
                    break
                }
                try Task.checkCancellation()
                guard runID == id else { throw CancellationError() }
                await onProgress(progress)
                remaining = progress.mayHaveRemainingWork
                await Task.yield()
            } while remaining
        }
    }

    private func waitForRequest() async {
        let id = UUID()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if requested || Task.isCancelled { continuation.resume() }
                else { waiter = (id, continuation) }
            }
        }, onCancel: { Task { await self.cancelWaiter(id) } })
    }

    private func cancelWaiter(_ id: UUID) {
        guard waiter?.id == id else { return }
        waiter?.continuation.resume()
        waiter = nil
    }
}
