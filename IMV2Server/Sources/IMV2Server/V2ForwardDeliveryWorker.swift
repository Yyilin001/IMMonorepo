import Foundation
import IMV2ActorContracts
import IMV2Core

/// 受信的目标归属边界。
///
/// 返回 `nil` 只表示目标侧的持久化工作仍未完成，绝不表示已拒绝、已完成或可以释放源端置顶占用。
public protocol V2ForwardExportDelivering: Sendable {
    // Implementations must propagate cancellation and bound underlying I/O;
    // the worker cancels and drains this call before releasing its claim.
    func deliver(_ export: V2ForwardExport) async throws -> V2ForwardTerminalReceipt?
}

/// 转发投递错误。
public enum V2ForwardDeliveryError: Error, Equatable, Sendable {
    /// 投递配置参数非法。
    case invalidConfiguration
    /// 目标归属当前不可用。
    case targetUnavailable
    /// 媒体导入已暂停，需等待运维重放。
    case mediaPaused
    /// 目标返回的回执与本次导出不一致。
    case receiptMismatch
    /// 目标投递超出允许时长。
    case timedOut
}

/// 单轮投递统计。
public struct V2ForwardDeliveryReport: Equatable, Sendable {
    /// 本轮认领数量。
    public var claimed = 0
    /// 完成数量。
    public var completed = 0
    /// 因目标仍在处理而延后的数量。
    public var deferred = 0
    /// 安排重试的数量。
    public var retried = 0
    /// 暂停等待运维重放的数量。
    public var paused = 0
    /// 因租约被取代而放弃的数量。
    public var superseded = 0
}

/// 转发投递工作器。
///
/// 每次调用只处理一个有界并发批次；循环与取消由运行时负责，
/// 不产生游离的投递任务，也不会在持有数据库锁时进行远程 I/O。
public struct V2ForwardDeliveryWorker: Sendable {
    private let store: PostgresV2ForwardDeliveryStore
    private let receipts: PostgresV2ForwardReceiptStore
    private var recordReceipt: @Sendable (V2ForwardTerminalReceipt, V2ForwardExport, Date) async throws -> Void
    private let target: any V2ForwardExportDelivering
    private let leaseDuration: TimeInterval
    private let deliveryTimeout: TimeInterval
    private let pendingDelay: TimeInterval
    private let maximumConcurrency: Int
    private let retryPolicy: V2DurableRetryPolicy
    private let now: @Sendable () -> Date

    /// 组合投递存储、回执存储与目标边界。
    ///
    /// - Parameters:
    ///   - store: 投递任务存储。
    ///   - receipts: 源端回执存储。
    ///   - target: 目标归属投递实现。
    ///   - leaseDuration: 租约时长秒数，需大于零且不超过 3600。
    ///   - deliveryTimeout: 单次投递超时秒数；为 `nil` 时取租约时长的八成。
    ///   - pendingDelay: 目标仍在处理时的延后重试间隔秒数。
    ///   - maximumConcurrency: 单批最大并发数，需落在 `1...1024`。
    ///   - retryPolicy: 失败退避策略。
    ///   - now: 可注入的当前时刻读取函数。
    /// - Throws: 任一参数越界，或超时不小于租约时长时抛出
    ///   ``V2ForwardDeliveryError/invalidConfiguration``。
    public init(store: PostgresV2ForwardDeliveryStore, receipts: PostgresV2ForwardReceiptStore,
                target: any V2ForwardExportDelivering, leaseDuration: TimeInterval = 300,
                deliveryTimeout: TimeInterval? = nil, pendingDelay: TimeInterval = 1, maximumConcurrency: Int = 4,
                retryPolicy: V2DurableRetryPolicy = .standard, now: @escaping @Sendable () -> Date = Date.init) throws {
        let timeout = deliveryTimeout ?? leaseDuration * 0.8
        guard leaseDuration.isFinite, leaseDuration > 0, leaseDuration <= 3_600,
              timeout.isFinite, timeout > 0, timeout < leaseDuration,
              pendingDelay.isFinite, pendingDelay > 0, (1...1_024).contains(maximumConcurrency)
        else { throw V2ForwardDeliveryError.invalidConfiguration }
        self.store = store; self.receipts = receipts; self.target = target
        self.recordReceipt = { receipt, _, at in try await receipts.record(receipt, now: at) }
        self.leaseDuration = leaseDuration; self.pendingDelay = pendingDelay
        self.deliveryTimeout = timeout
        self.maximumConcurrency = maximumConcurrency; self.retryPolicy = retryPolicy; self.now = now
    }

    /// The actor composition routes source receipt commits through RoomRef.
    /// Legacy direct-store construction remains available during cutover.
    public init(store: PostgresV2ForwardDeliveryStore, receipts: PostgresV2ForwardReceiptStore,
                target: any V2ForwardExportDelivering,
                sourceCommand: @escaping @Sendable (V2RoomForwardCommand, ContinuousClock.Instant) async throws -> V2RoomForwardResult,
                deadline: @escaping @Sendable () -> ContinuousClock.Instant,
                leaseDuration: TimeInterval = 300, deliveryTimeout: TimeInterval? = nil,
                pendingDelay: TimeInterval = 1, maximumConcurrency: Int = 4,
                retryPolicy: V2DurableRetryPolicy = .standard,
                now: @escaping @Sendable () -> Date = Date.init) throws {
        try self.init(store: store, receipts: receipts, target: target,
                      leaseDuration: leaseDuration, deliveryTimeout: deliveryTimeout,
                      pendingDelay: pendingDelay, maximumConcurrency: maximumConcurrency,
                      retryPolicy: retryPolicy, now: now)
        self.recordReceipt = { receipt, export, _ in
            let input = V2ActorRecordForwardReceiptWire(
                sourceRoomID: .init(uuid: export.intent.sourceRoomID),
                actorUserID: .init(uuid: export.intent.actorUserID),
                exportID: receipt.exportID, payloadDigest: receipt.payloadDigest,
                outcome: .init(domain: receipt.outcome))
            guard case .receiptRecorded = try await sourceCommand(.recordReceipt(input), deadline()) else {
                throw V2ForwardDeliveryError.receiptMismatch
            }
        }
    }

    /// 认领并投递一批任务。
    ///
    /// - Parameters:
    ///   - sourceShardID: 源逻辑分片标识。
    ///   - limit: 本轮最多处理的任务数，需大于零。
    /// - Returns: 本轮投递统计。
    /// - Throws: 上限非正或认领参数非法时抛出
    ///   ``V2ForwardDeliveryError/invalidConfiguration``；任务取消时抛出 `CancellationError`。
    public func runOnce(sourceShardID: String, limit: Int) async throws -> V2ForwardDeliveryReport {
        guard limit > 0 else { throw V2ForwardDeliveryError.invalidConfiguration }
        try Task.checkCancellation()
        let leases = try await store.claim(sourceShardID: sourceShardID, now: now(), leaseDuration: leaseDuration, limit: min(limit, maximumConcurrency))
        return try await withThrowingTaskGroup(of: Result.self) { group in
            for lease in leases { group.addTask { try await deliver(lease) } }
            var report = V2ForwardDeliveryReport()
            report.claimed = leases.count
            for try await result in group {
                switch result {
                case .completed: report.completed += 1
                case .deferred: report.deferred += 1
                case .retried: report.retried += 1
                case .paused: report.paused += 1
                case .superseded: report.superseded += 1
                }
            }
            return report
        }
    }

    /// 单次投递的处置结果。
    private enum Result: Sendable { case completed, deferred, retried, paused, superseded }

    /// 在超时约束下请求目标投递，并原样保留目标的待处理语义。
    ///
    /// 超时任务与投递任务同组竞速：无论哪一方先结束都会取消另一方。
    ///
    /// - Parameter export: 本次投递的导出。
    /// - Returns: 终态回执；目标仍在处理时返回 `nil`。
    /// - Throws: 超过超时时长抛出 ``V2ForwardDeliveryError/timedOut``；
    ///   任务组无结果时抛出 ``V2ForwardDeliveryError/targetUnavailable``。
    private func requestTarget(_ export: V2ForwardExport) async throws -> V2ForwardTerminalReceipt? {
        try await withThrowingTaskGroup(of: V2ForwardTerminalReceipt?.self) { group in
            group.addTask { try await target.deliver(export) }
            group.addTask {
                try await v2Sleep(for: .seconds(deliveryTimeout))
                throw V2ForwardDeliveryError.timedOut
            }
            defer { group.cancelAll() }
            // The optional result is itself meaningful: unwrap only the
            // group's outer optional, preserving a pending nil from target.
            guard let result = try await group.next() else { throw V2ForwardDeliveryError.targetUnavailable }
            return result
        }
    }

    /// 投递单个租约并按其结果回写任务状态。
    ///
    /// 先确认租约仍然有效；若源端回执已存在（例如上次崩溃发生在回执提交之后），
    /// 直接完成任务而不再做目标 I/O。目标返回的回执必须与本次导出完全一致。
    ///
    /// - Parameter lease: 本次投递租约。
    /// - Returns: 处置结果。
    /// - Throws: 任务取消时重排租约后继续抛出 `CancellationError`；
    ///   回执与导出不一致时抛出 ``V2ForwardDeliveryError/receiptMismatch``；
    ///   延后重试时刻不可编码或重试时刻不晚于当前时刻时抛出
    ///   ``V2ForwardExportError/corruptPersistenceState``。
    private func deliver(_ lease: V2ForwardDeliveryLease) async throws -> Result {
        do {
            try Task.checkCancellation()
            guard try await store.isCurrent(lease, now: now()) else { return .superseded }
            // Recover a crash after source receipt commit without target I/O.
            if try await receipts.status(exportID: lease.export.intent.exportID) != nil {
                return try await store.complete(lease, now: now()) ? .completed : .superseded
            }
            guard let receipt = try await requestTarget(lease.export) else {
                try Task.checkCancellation()
                let time = now()
                guard let retryAt = v2PostgresFutureTimestamp(now: time, interval: pendingDelay) else {
                    throw V2ForwardExportError.corruptPersistenceState
                }
                return try await store.reschedule(lease, disposition: .retry(at: retryAt), resetAttempts: true, now: time) ? .deferred : .superseded
            }
            guard receipt.matches(lease.export) else { throw V2ForwardDeliveryError.receiptMismatch }
            try Task.checkCancellation()
            guard try await store.isCurrent(lease, now: now()) else { return .superseded }
            try await recordReceipt(receipt, lease.export, now())
            return try await store.complete(lease, now: now()) ? .completed : .superseded
        } catch is CancellationError {
            _ = try? await store.reschedule(lease, disposition: .retry(at: now()), resetAttempts: true, now: now())
            throw CancellationError()
        } catch {
            let time = now()
            // mediaPaused is an explicit policy decision and must stay a pause;
            // every other failure is classified so transient dependency errors
            // keep retrying instead of waiting for an operator.
            let disposition: V2DurableRetryDisposition = error as? V2ForwardDeliveryError == .mediaPaused
                ? .pause : retryPolicy.disposition(
                    attempt: lease.attempt,
                    claimToken: lease.claimToken,
                    now: time,
                    kind: v2DurableWorkFailureKind(for: error)
                )
            if case .retry(let retryAt) = disposition, !v2PostgresTimestampPrecedes(time, retryAt) {
                throw V2ForwardExportError.corruptPersistenceState
            }
            guard try await store.reschedule(lease, disposition: disposition, now: time) else { return .superseded }
            if case .pause = disposition { return .paused }
            return .retried
        }
    }
}
