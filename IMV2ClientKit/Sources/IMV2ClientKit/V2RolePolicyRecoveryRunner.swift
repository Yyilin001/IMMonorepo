import Foundation

/// 角色策略基线恢复运行器。
///
/// 它负责一轮有界读取：传输失败会按房间持久化为重试，而取消会直接向上传播，
/// 绝不会被写成持久化重试或拒绝。
public actor V2RolePolicyRecoveryRunner {
    private let store: GRDBV2LocalSyncStore
    private let transport: any V2ClientGroupRolePolicyBaselineTransport
    private let batchSize: Int
    private let now: @Sendable () -> Date
    private var isRecovering = false
    private var runID: UUID?

    /// 组合本地存储、基线传输与批量参数。
    ///
    /// - Parameters:
    ///   - store: 本地同步存储。
    ///   - transport: 角色策略基线读取实现。
    ///   - batchSize: 单轮最多处理的房间数，需落在 `1...100`，默认 16。
    ///   - now: 可注入的当前时刻读取函数。
    ///
    /// 批量大小越界时直接失败，避免出现无界读取。
    public init(store: GRDBV2LocalSyncStore, transport: any V2ClientGroupRolePolicyBaselineTransport, batchSize: Int = 16, now: @escaping @Sendable () -> Date = Date.init) {
        precondition((1 ... 100).contains(batchSize))
        self.store = store
        self.transport = transport
        self.batchSize = batchSize
        self.now = now
    }

    /// 启动按调度节奏持续恢复的循环。
    ///
    /// 已有循环在运行时本次调用直接返回，避免重复启动。
    ///
    /// - Throws: 任务取消时抛出 `CancellationError`；其余错误来自调度与存储。
    public func run() async throws {
        guard runID == nil else { return }
        let id = UUID()
        runID = id
        defer { if runID == id { runID = nil } }
        try await V2CommandRetryScheduler(schedule: store.rolePolicyRecoverySchedule(), flush: { [self] in _ = try await recoverOnce() }, now: now).run()
    }

    /// 执行一轮有界恢复，返回本轮处理的房间数。
    ///
    /// 已有恢复在进行时返回零，避免同一运行器内并发进入。
    ///
    /// - Returns: 本轮处理的房间数。
    /// - Throws: 任务取消时抛出 `CancellationError`；其余错误来自存储或传输。
    @discardableResult
    func recoverOnce() async throws -> Int {
        try Task.checkCancellation()
        guard !isRecovering else { return 0 }
        isRecovering = true
        defer { isRecovering = false }
        do { _ = try await store.enqueueMissingRolePolicyBaselines(limit: batchSize) }
        catch V2ClientSyncError.resetPending { return 0 }
        let requests: [V2RolePolicyRecoveryRequest]
        do { requests = try await store.dueRolePolicyBaselineRequests(at: now(), limit: batchSize) }
        catch V2ClientSyncError.resetPending { return 0 }
        var attempted = 0
        for candidate in requests {
            try Task.checkCancellation()
            let request: V2RolePolicyRecoveryRequest
            do { request = try await store.requestRolePolicyBaseline(roomID: candidate.roomID) }
            catch V2ClientSyncError.resetPending { return attempted }
            catch V2RolePolicyRecoveryError.roomUnauthorized { continue }
            try Task.checkCancellation()
            attempted += 1
            let disposition: V2RolePolicyRecoveryDisposition
            do {
                let baseline = try await transport.fetchRolePolicyBaseline(roomID: request.roomID)
                try Task.checkCancellation()
                if try await store.completeRolePolicyBaseline(baseline, for: request) { continue }
                disposition = .retry(at: try retryDate(after: 1))
            } catch is CancellationError { throw CancellationError() }
            catch V2ClientSyncError.resetPending { return attempted }
            catch let error as V2RealtimeTransportError {
                try Task.checkCancellation()
                if case .server(let code, let retryable, let delay, _) = error {
                    if ["UNAUTHENTICATED", "SESSION_REVOKED", "DEVICE_REVOKED"].contains(code) { throw error }
                    if ["FORBIDDEN", "NOT_FOUND"].contains(code) { disposition = .unauthorized }
                    else if retryable { disposition = .retry(at: try retryDate(request: request, minimumDelay: Double(delay))) }
                    else { disposition = .pause }
                } else { disposition = .pause }
            } catch V2RolePolicyRecoveryError.invalidDate { throw V2RolePolicyRecoveryError.invalidDate }
            catch V2RolePolicyRecoveryError.invalidBaseline { disposition = .pause }
            catch {
                try Task.checkCancellation()
                disposition = .retry(at: try retryDate(request: request, minimumDelay: 0))
            }
            try Task.checkCancellation()
            do { _ = try await store.recordRolePolicyRecoveryFailure(disposition, for: request) }
            catch V2ClientSyncError.resetPending { return attempted }
        }
        return attempted
    }

    private func retryDate(request: V2RolePolicyRecoveryRequest, minimumDelay: TimeInterval) throws -> Date {
        let backoff = min(60.0, pow(2.0, Double(min(request.attemptCount, 6))))
        return try retryDate(after: max(backoff, minimumDelay))
    }
    private func retryDate(after delay: TimeInterval) throws -> Date {
        do { return try v2CommandRetryDate(now: now(), delay: delay) }
        catch { throw V2RolePolicyRecoveryError.invalidDate }
    }
}
