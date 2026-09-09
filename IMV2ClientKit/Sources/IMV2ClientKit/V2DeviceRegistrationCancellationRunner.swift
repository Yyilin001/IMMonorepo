import Foundation

/// 执行器生命周期错误；alreadyRunning 表示已有运行循环，不能重复启动。
public enum V2DeviceRegistrationCancellationRunnerError: Error, Equatable, Sendable { case alreadyRunning }

/// 独立于账户凭证的注册取消任务执行器，由应用持有运行任务。
///
/// 取消后需等待当前网络调用退出，运行循环才释放排他标记；尚未确认完成的持久化任务保留供后续恢复。
public actor V2DeviceRegistrationCancellationRunner {
    /// 持久化注册取消任务及重试计划的唯一所有者。
    private let store: V2DeviceRegistrationStore
    /// 仅使用注册取消材料的传输。
    private let client: any V2DeviceRegistrationCancellationClient
    /// 选择到期任务与计算下次尝试时间的可注入时钟。
    private let now: @Sendable () -> Date
    /// 防止重复运行的标记，循环退出时才清除。
    private var running = false

    /// 注入注册队列、取消客户端及调度时钟，不立即启动。
    ///
    /// - Parameters:
    ///   - store: 注册状态及取消任务的持久化所有者。
    ///   - client: 执行目的受限取消请求的客户端。
    ///   - now: 默认读取当前日期的墙上时钟。
    public init(store: V2DeviceRegistrationStore, client: any V2DeviceRegistrationCancellationClient,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.client = client; self.now = now
    }

    /// 持续根据持久化取消计划执行任务，直到取消或调度失败。
    ///
    /// - Throws: 任务取消、alreadyRunning 或存储与调度错误。
    ///
    /// 同一实例只允许一个循环，取消不会删除队列；调用方需等待循环返回再启动下一次运行。
    public func run() async throws {
        try Task.checkCancellation()
        guard !running else { throw V2DeviceRegistrationCancellationRunnerError.alreadyRunning }
        running = true
        defer { running = false }
        try await V2CommandRetryScheduler(schedule: store.cancellationRetrySchedule(), flush: { [self] in
            try await flushOnce()
        }, now: now).run()
    }

    /// 顺序处理当前到期的取消任务，以服务端结果为完成依据。
    ///
    /// 成功结果包括 cancelled 和 expired；调用者取消时，即使收到迟到成功也不提交本地完成，留待恢复重试。
    /// 暂时错误采用从 2 秒起、最高 300 秒的指数退避，与最多一天的服务端等待提示取较大值；不可重试响应暂停任务。
    /// - Throws: 取消或队列持久化失败；普通传输错误记录后继续下一项。
    ///
    /// 本地签发截止时间已过，不能证明已绑定会话终结。
    func flushOnce() async throws {
        for job in try await store.dueCancellations(at: now()) {
            try Task.checkCancellation()
            do {
                // The local issue deadline cannot settle a bound session;
                // only the server can confirm cancellation or session expiry.
                _ = try await client.cancel(job.cancellation)
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                let failure = classify(error)
                let delay = max(min(300, pow(2, Double(min(job.attempts, 8) + 1))), failure.retryAfter)
                try await store.recordCancellationFailure(job, retryAt: now().addingTimeInterval(delay), pauseReason: failure.pause)
                continue
            }
            try Task.checkCancellation()
            try await store.completeCancellationJob(job)
        }
    }

    /// 将错误转换为暂停原因及服务端建议等待秒数。
    ///
    /// 网络与未知错误、HTTP 408 或大于等于 500 的状态可重试；无效响应暂停为 invalidResponse，其余端点及状态错误暂停为 invalidRequest。
    /// 限流秒数限制在 0 到 86400，最终延迟仍需与本地退避比较。
    private func classify(_ error: any Error) -> (pause: V2DeviceRegistrationCancellationJob.PauseReason?, retryAfter: Double) {
        guard let error = error as? V2DeviceRegistrationCancellationClientError else { return (nil, 0) }
        switch error {
        case .networkFailure: return (nil, 0)
        case .rateLimited(let seconds): return (nil, min(86_400, max(0, Double(seconds ?? 0))))
        case .invalidResponse: return (.invalidResponse, 0)
        case .invalidEndpoint: return (.invalidRequest, 0)
        case .serverStatus(let status): return status >= 500 || status == 408 ? (nil, 0) : (.invalidRequest, 0)
        }
    }
}
