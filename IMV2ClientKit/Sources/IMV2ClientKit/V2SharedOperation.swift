import Foundation

/// 立即启动、由所有者控制的共享异步操作。
///
/// 多个 value 等待者独立取消，不会因一个消费者超时而取消其他调用者仍需要的刷新或读取。
/// 整体取消由所有者调用 cancel，result 则用于等待实际任务结束。
final class V2SharedOperation<Value: Sendable>: Sendable {
    /// 缓存最终结果并管理可独立取消的等待者。
    private let completion: Completion
    /// 实际执行操作的所有者任务。
    private let task: Task<Value, Error>

    /// 立即启动共享任务并在成功或失败后发布唯一结果。
    ///
    /// - Parameter operation: 可发送的异步工作，错误作为共享结果保存并交付等待者。
    ///
    /// 初始化后任务已运行，不需要先读取 value；此类型没有自动在析构时取消任务的逻辑。
    init(_ operation: @escaping @Sendable () async throws -> Value) {
        let completion = Completion()
        self.completion = completion
        task = Task {
            let result: Result<Value, Error>
            do { result = .success(try await operation()) }
            catch { result = .failure(error) }
            await completion.resolve(result)
            return try result.get()
        }
    }

    /// 等待共享结果，当前等待者可通过取消独立退出；操作完成与取消同时到达时，以 actor 实际处理顺序决定结果。
    var value: Value { get async throws { try await completion.wait() } }
    /// 等待底层任务终结并返回成功或失败，用于排空；不使用独立等待者取消路径。
    var result: Result<Value, Error> { get async { await task.result } }
    /// 向底层共享任务发出取消请求，不同步结束任务或直接恢复等待者；操作需响应取消，结束后才发布结果。
    func cancel() { task.cancel() }

    /// 串行管理一次结果发布和多个等待者的注册、取消与恢复。
    private actor Completion {
        /// 首次发布后保留的最终结果，供后来等待者立即读取。
        private var result: Result<Value, Error>?
        /// 尚未获得结果的独立等待者，使用内部 UUID 区分取消目标。
        private var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]

        /// 先检查取消，再返回已有结果或登记等待。
        ///
        /// 取消处理只移除本次 UUID 对应等待者；不取消共享操作。登记后没有额外的返回前取消检查，
        /// 若结果先完成等待，则可能返回结果而不是取消错误。
        func wait() async throws -> Value {
            let id = UUID()
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                if let result { return try result.get() }
                return try await withCheckedThrowingContinuation { waiters[id] = $0 }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }
        /// 移除并取消指定等待者，已完成或不存在时无操作。
        private func cancel(_ id: UUID) {
            waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }
        /// 只接受第一次结果，先清空等待集合，再逐一恢复所有待处理 continuation；重复发布被忽略。
        func resolve(_ result: Result<Value, Error>) {
            guard self.result == nil else { return }
            self.result = result
            let pending = waiters.values
            waiters.removeAll()
            for waiter in pending { waiter.resume(with: result) }
        }
    }
}
