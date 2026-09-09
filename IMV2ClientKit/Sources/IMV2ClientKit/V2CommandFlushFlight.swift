import Foundation

/// 控制账户所属命令刷新的暂停与恢复。
///
/// 生命周期由运行时管理。取消某个界面等待者，不等于取消账户共享的刷新任务。
public protocol V2CommandFlushControlling: Sendable {
    /// 暂停命令刷新。
    ///
    /// 具体实现负责定义取消与收尾时机；调用者不能仅凭此协议推断返回时所有在途任务均已退出。
    func suspendCommandFlushing() async
    /// 恢复命令刷新，具体实现负责协调上一轮任务与新连接之间的交接。
    func resumeCommandFlushing() async
}

/// 让同一命令通道的并发调用共享一个刷新任务。
///
/// 共享任务覆盖命令选择、网络发送和持久化完成的整个过程，避免 actor 在挂起点重入后重复选择同一条命令。
/// 单个等待者的取消不会向共享任务传播；运行时通过暂停操作请求取消共享任务。
actor V2CommandFlushFlight<Value: Sendable> {
    /// 一次共享刷新及其身份，用于避免旧等待者清除后来建立的任务。
    private struct Flight {
        /// 本轮刷新的唯一标识。
        let id: UUID
        /// 由账户生命周期拥有、可被多个调用者等待的任务。
        let task: Task<Value, any Error>
    }
    /// 当前共享任务；结束后由匹配其身份的等待者清除。
    private var flight: Flight?
    /// 是否拒绝新的刷新请求。
    private var isSuspended = false
    /// 暂停周期标识，防止较早发起的恢复覆盖后续暂停。
    private var lifecycleID = UUID()

    /// 发起一次刷新，或等待已有刷新并共享其结果。
    ///
    /// - Parameter operation: 仅在没有共享任务时执行的完整刷新操作；已有任务时不会执行此闭包。
    /// - Returns: 共享任务的执行结果。
    /// - Throws: 暂停状态或等待结束后发现调用者已取消时抛出 `CancellationError`；否则传播共享任务的错误。
    ///
    /// 等待者取消不会立即结束等待，也不会取消共享任务。取消检查发生在共享任务返回之后。
    func run(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        guard !isSuspended else { throw CancellationError() }
        let current: Flight
        if let flight {
            current = flight
        } else {
            current = .init(id: UUID(), task: Task { try await operation() })
            flight = current
        }
        // An individual caller cannot cancel the account-owned shared task.
        let result = await current.task.result
        if flight?.id == current.id { flight = nil }
        try Task.checkCancellation()
        return try result.get()
    }

    /// 拒绝新的刷新，并向当前共享任务发出取消请求。
    ///
    /// 此方法不等待在途任务退出。任务需主动响应取消；恢复操作负责等待旧任务结束后再开放通道。
    func suspend() {
        lifecycleID = UUID()
        isSuspended = true
        flight?.task.cancel()
    }

    /// 等待旧共享任务结束后重新开放刷新通道。
    ///
    /// 等待期间若发生新的暂停，本次恢复失效。旧任务的错误在此被忽略，其结果仍由原来的等待者处理。
    func resume() async {
        let resumingID = lifecycleID
        // Drain any task cancelled by the previous connection before another
        // connection can select the same pending command.
        if let current = flight {
            _ = await current.task.result
            if flight?.id == current.id { flight = nil }
        }
        guard resumingID == lifecycleID else { return }
        isSuspended = false
    }
}
