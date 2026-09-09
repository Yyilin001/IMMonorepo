import Foundation

/// 撤销执行器的生命周期错误；alreadyRunning 表示已有运行循环，不能重复启动。
public enum V2DeviceRevocationRunnerError: Error, Equatable, Sendable { case alreadyRunning }

/// 独立于登录账户、由应用生命周期拥有的设备撤销执行器。
///
/// 调用方持有并取消 run 任务。运行循环串行发送撤销请求，取消后等待当前调用退出才释放运行标记；持久化任务保留供下次启动恢复。
public actor V2DeviceRevocationRunner {
    /// 保存跨账户撤销任务及重试计划的持久化队列。
    private let store: V2DeviceRevocationStore
    /// 仅使用撤销凭证的服务端客户端。
    private let client: any V2DeviceRevocationClient
    /// 选择到期任务并计算下次重试时间的可注入时钟。
    private let now: @Sendable () -> Date
    /// 运行循环的排他标记，在循环完全返回后释放。
    private var running = false

    /// 配置应用级撤销执行器，不立即读取队列或发送请求。
    ///
    /// - Parameters:
    ///   - store: 该凭证命名空间唯一的撤销队列所有者。
    ///   - client: 执行撤销请求的传输。
    ///   - now: 可注入的墙上时钟，默认读取当前日期。
    public init(store: V2DeviceRevocationStore, client: any V2DeviceRevocationClient,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.client = client; self.now = now
    }

    /// 持续按持久化重试计划执行撤销，直到取消或调度失败。
    ///
    /// - Throws: 任务取消、alreadyRunning，或队列读取、保存及调度错误。
    ///
    /// 内部网络调用返回并退出循环前不允许再次启动；取消不删除尚未确认完成的任务。
    public func run() async throws {
        try Task.checkCancellation()
        guard !running else { throw V2DeviceRevocationRunnerError.alreadyRunning }
        running = true
        defer { running = false }
        try await V2CommandRetryScheduler(schedule: store.retrySchedule(), flush: { [self] in
            try await flushOnce()
        }, now: now).run()
    }

    // Only run() is exposed publicly; a second foreground activation cannot
    // bypass its owner and send the same job concurrently.
    /// 顺序处理当前最多四个到期任务，每次请求及写回前检查取消。
    ///
    /// 网络暂时失败使用指数退避，基础延迟从 2 秒增长至最多 300 秒；服务端 Retry-After 可延长等待至最多一天。
    /// 撤销成功或服务端确认过期后删除任务，无效凭证与操作冲突则暂停。任务快照过时导致的条件写入失败不会覆盖新状态。
    /// - Throws: 取消或队列操作错误；普通网络错误转为持久化失败状态后继续下一项。
    func flushOnce() async throws {
        for job in try await store.due(at: now()) {
            try Task.checkCancellation()
            let result: V2DeviceRevocationResult
            do {
                result = try await client.revoke(credential: job.intent.credential, operationID: job.intent.operationID)
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                let failure = classify(error)
                let backoff = min(300, pow(2, Double(min(job.attempts, 8) + 1)))
                let delay = max(backoff, failure.retryAfter)
                try await store.recordFailure(job, retryAt: now().addingTimeInterval(delay), pauseReason: failure.pause)
                continue
            }
            try Task.checkCancellation()
            switch result {
            case .revoked, .expired:
                // Expiry is a recognized server deadline, not a claim that a
                // revoke transaction committed. Both settle this capability.
                try await store.complete(job)
            case .invalidCredential:
                try await store.recordFailure(job, retryAt: now(), pauseReason: .invalidCredential)
            case .operationConflict:
                try await store.recordFailure(job, retryAt: now(), pauseReason: .operationConflict)
            }
        }
    }

    /// 将传输错误转换为暂停原因和最小重试等待秒数。
    ///
    /// 网络失败、未知错误、HTTP 408 和 5xx 可重试；无效响应暂停，端点错误及其余 HTTP 状态暂停为无效请求。
    /// 限流等待被约束在 0 到 86400 秒，最终仍需与本地退避取较大值。
    private func classify(_ error: any Error) -> (pause: V2DeviceRevocationJob.PauseReason?, retryAfter: Double) {
        guard let error = error as? V2DeviceRevocationClientError else { return (nil, 0) }
        switch error {
        case .networkFailure: return (nil, 0)
        case .rateLimited(let seconds): return (nil, min(86_400, max(0, Double(seconds ?? 0))))
        case .invalidResponse: return (.invalidResponse, 0)
        case .invalidEndpoint: return (.invalidRequest, 0)
        case .serverStatus(let status):
            return status >= 500 || status == 408 ? (nil, 0) : (.invalidRequest, 0)
        }
    }
}
