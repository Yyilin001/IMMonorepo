import Foundation

/// 由应用持有、供场景与推送调用方共用的会话恢复协调器。
///
/// 各调用方可独立离开；持有者拥有自己的工作截止时间，并会一直保留到真正排空为止，
/// 因此迟到的磁盘回调不会与第二个持有者重叠。
@MainActor
final class V2SessionRestoration {
    /// 恢复失败原因。
    enum Failure: Error { case deadlineReached }
    private var owner: (id: UUID, task: Task<Void, Never>)?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var timer: Task<Void, Never>?
    private var expired = false
    private let workDuration: Duration

    /// 是否正在恢复。
    var isRestoring: Bool { owner != nil }

    /// 以工作时长构造协调器。
    ///
    /// - Parameter workDuration: 单个持有者允许的最长工作时长，默认 25 秒。
    init(workDuration: Duration = .seconds(25)) { self.workDuration = workDuration }

    /// 释放时取消持有者任务与计时器。
    deinit { owner?.task.cancel(); timer?.cancel() }

    /// 执行一次会话恢复，可选择带上调用方截止时间。
    ///
    /// 已有持有者时本次调用只作为等待者加入；否则创建新的持有者并启动工作时长计时。
    /// 给出截止时间时，等待与该截止时间竞速，先到者决定结果。
    ///
    /// - Parameters:
    ///   - deadline: 调用方截止时间；为空表示只受持有者工作时长限制。
    ///   - operation: 实际执行的恢复操作。
    /// - Throws: 任务已取消时抛出 `CancellationError`；截止时间已过或工作时长耗尽时抛出
    ///   ``Failure/deadlineReached``。
    func run(until deadline: ContinuousClock.Instant? = nil,
             operation: @escaping @MainActor @Sendable () async -> Void) async throws {
        try Task.checkCancellation()
        if let deadline, deadline <= .now { throw Failure.deadlineReached }
        if owner == nil {
            let id = UUID()
            expired = false
            owner = (id, Task { [weak self] in
                await operation()
                self?.finish(id)
            })
            timer = Task { [weak self, workDuration] in
                do { try await Task.sleep(for: workDuration) } catch { return }
                self?.expire(id)
            }
        }
        if expired { throw Failure.deadlineReached }
        if let deadline {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.wait() }
                group.addTask {
                    try await ContinuousClock().sleep(until: deadline)
                    throw Failure.deadlineReached
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } else { try await wait() }
    }

    /// 作为等待者等待当前持有者结束。
    ///
    /// 无持有者时立即返回；取消会移除本等待者并以取消错误恢复。
    ///
    /// - Throws: 已过期时抛出 ``Failure/deadlineReached``；取消时抛出 `CancellationError`。
    private func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if expired { throw Failure.deadlineReached }
            guard owner != nil else { return }
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }

    /// 让指定持有者因超时而失败。
    ///
    /// - Parameter id: 持有者标识；不匹配时忽略。
    private func expire(_ id: UUID) {
        guard owner?.id == id else { return }
        expired = true
        owner?.task.cancel()
        resolve(.failure(Failure.deadlineReached))
    }
    /// 结束指定持有者并唤醒全部等待者。
    ///
    /// - Parameter id: 持有者标识；不匹配时忽略。
    private func finish(_ id: UUID) {
        guard owner?.id == id else { return }
        timer?.cancel(); timer = nil
        owner = nil
        resolve(expired ? .failure(Failure.deadlineReached) : .success(()))
    }
    /// 以给定结果唤醒全部等待者并清空等待列表。
    ///
    /// - Parameter result: 要广播的结果。
    private func resolve(_ result: Result<Void, Error>) {
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume(with: result) }
    }
}
