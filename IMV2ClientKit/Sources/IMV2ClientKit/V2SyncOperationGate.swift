import Foundation

/// 串行执行写入同一本地存储的完整同步操作。
///
/// 多个同步引擎必须共享同一个实例，才能把拉取、应用、确认和快照激活跨越挂起点的过程纳入同一许可。
/// 排队调用者取消时仅移除自己的等待，不取消当前持有者。操作不能递归进入同一个门，否则会等待自身释放许可。
public actor V2SyncOperationGate {
    /// 当前许可持有者；没有操作执行时为 `nil`。
    private var owner: UUID?
    /// 按入队顺序等待许可的调用者及其 continuation。
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    /// 创建空闲的同步操作门；写入同一本地存储的引擎应复用此实例。
    public init() {}

    /// 尚未获得许可的操作数量，不包含当前持有者。
    var waitingOperationCount: Int { waiters.count }

    /// 获得独占许可后执行同步操作，并在成功或失败时释放许可。
    ///
    /// - Parameter operation: 需要覆盖所有挂起点的同步工作，不得递归进入此实例。
    /// - Returns: 操作返回的结果。
    /// - Throws: 等待或开始执行前检查到取消时抛出 `CancellationError`，否则传播操作错误。
    ///
    /// 开始执行后由操作本身响应取消；本方法不会在成功返回前额外检查取消。
    func run<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        let id = UUID()
        try await acquire(id)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            release(id)
            return result
        } catch {
            release(id)
            throw error
        }
    }

    /// 取得许可，或按顺序排队并允许调用者取消等待。
    ///
    /// - Parameter id: 本次操作的唯一身份。
    /// - Throws: 入队前或排队期间发现取消时抛出 `CancellationError`。
    private func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if owner == nil { owner = id; return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWait(id) }
        }
    }

    /// 移除指定排队者并以取消错误唤醒；若已获得许可或不在队列中则不操作。
    private func cancelWait(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// 仅允许当前持有者释放许可，并把许可交给最早的剩余等待者。
    private func release(_ id: UUID) {
        guard owner == id else { return }
        guard !waiters.isEmpty else { owner = nil; return }
        let next = waiters.removeFirst()
        owner = next.id
        next.continuation.resume()
    }
}
