import Foundation
import IMV2Core

/// 把相互独立的心跳续租合并为有界的数据库语句。
///
/// 准入与移除仍保持即时执行，因为它们需要确立连接归属；只有续租会被批量合并，
/// 因为对应行已经归属于该连接。
public actor V2LivePresenceRenewalBatcher {
    /// actor 内部的代数标识。
    ///
    /// 它只用于区分 actor 内的等待续期与延迟刷新，既不是公开标识也不是授权令牌，
    /// 因此使用单调计数器即可满足唯一性，无需为每次心跳打开平台随机源。
    private typealias Generation = UInt64

    /// 批量续租配置。
    public struct Configuration: Equatable, Sendable {
        /// 单批最大连接数。
        public let maximumBatchSize: Int
        /// 攒批的最长等待时长。
        public let maximumDelay: Duration

        /// 构造配置。
        ///
        /// - Parameters:
        ///   - maximumBatchSize: 单批最大连接数，需大于零。
        ///   - maximumDelay: 攒批等待时长，需非负。
        ///
        /// 参数越界时直接失败，避免出现无界批量或负延迟。
        public init(
            maximumBatchSize: Int = 256,
            maximumDelay: Duration = .milliseconds(2)
        ) {
            precondition(maximumBatchSize > 0)
            precondition(maximumDelay >= .zero)
            self.maximumBatchSize = maximumBatchSize
            self.maximumDelay = maximumDelay
        }
    }

    /// 批量续租的运行快照。
    public struct Snapshot: Equatable, Sendable {
        /// 当前待刷新连接数。
        public let pendingConnections: Int
        /// 累计提交的续租请求数。
        public let submittedRequests: UInt64
        /// 已执行的批次数。
        public let executedBatches: UInt64
        /// 失败的批次数。
        public let failedBatches: UInt64
        /// 历史最大批次规模。
        public let largestBatch: Int

        /// 保存快照。
        ///
        /// - Parameters:
        ///   - pendingConnections: 待刷新连接数。
        ///   - submittedRequests: 累计请求数。
        ///   - executedBatches: 已执行批次数。
        ///   - failedBatches: 失败批次数。
        ///   - largestBatch: 历史最大批次规模。
        public init(
            pendingConnections: Int,
            submittedRequests: UInt64,
            executedBatches: UInt64,
            failedBatches: UInt64,
            largestBatch: Int
        ) {
            self.pendingConnections = pendingConnections
            self.submittedRequests = submittedRequests
            self.executedBatches = executedBatches
            self.failedBatches = failedBatches
            self.largestBatch = largestBatch
        }
    }

    /// 单个连接上未完成的续租请求。
    private struct PendingRenewal {
        /// 当前保留的续租请求，取时间较新者。
        var request: V2LivePresenceLeaseRenewalRequest
        /// 等待本次结果的多个续期。
        var continuations: [Generation: CheckedContinuation<V2LivePresenceLeaseRefresh, any Error>]
    }

    private let leases: any V2LivePresenceLeaseManaging
    private let configuration: Configuration
    private var pending: [UUID: PendingRenewal] = [:]
    private var scheduledFlushID: Generation?
    private var scheduledFlush: Task<Void, Never>?
    private var scheduledFlushIsImmediate = false
    private var nextGeneration: Generation = 0
    private var submittedRequests: UInt64 = 0
    private var executedBatches: UInt64 = 0
    private var failedBatches: UInt64 = 0
    private var largestBatch = 0

    /// 组合租约管理与配置。
    ///
    /// - Parameters:
    ///   - leases: 实际执行续租的租约管理实现。
    ///   - configuration: 攒批配置。
    public init(
        leases: any V2LivePresenceLeaseManaging,
        configuration: Configuration = .init()
    ) {
        self.leases = leases
        self.configuration = configuration
    }

    /// 请求刷新一条连接租约。
    ///
    /// 同一连接的多次请求会合并到一批：保留时间较新的请求内容，
    /// 但为每个调用者单独保留续期，使每个等待者都能收到结果。
    /// 达到批量上限时立即触发刷新，否则在配置的延迟后触发。
    ///
    /// - Parameters:
    ///   - identity: 已认证连接身份。
    ///   - connectionID: 连接标识。
    ///   - now: 本次续租时刻。
    /// - Returns: 该连接的续租结果。
    /// - Throws: 时刻不可编码时抛出
    ///   ``V2LiveActivityStoreError/corruptPersistenceState``；
    ///   任务取消时抛出 `CancellationError`；批量执行失败时抛出底层错误。
    public func renew(
        identity: V2AuthenticatedConnection,
        connectionID: UUID,
        now: Date
    ) async throws -> V2LivePresenceLeaseRefresh {
        try Task.checkCancellation()
        guard v2PostgresTimestampCanEncode(now) else { throw V2LiveActivityStoreError.corruptPersistenceState }
        let continuationID = makeGeneration()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                submittedRequests &+= 1
                let request = V2LivePresenceLeaseRenewalRequest(
                    identity: identity,
                    connectionID: connectionID,
                    now: now
                )
                if var existing = pending[connectionID] {
                    if existing.request.now <= now { existing.request = request }
                    existing.continuations[continuationID] = continuation
                    pending[connectionID] = existing
                } else {
                    pending[connectionID] = .init(
                        request: request,
                        continuations: [continuationID: continuation]
                    )
                }
                if pending.count >= configuration.maximumBatchSize {
                    if !scheduledFlushIsImmediate { scheduleFlush(after: .zero) }
                } else if scheduledFlush == nil {
                    scheduleFlush(after: configuration.maximumDelay)
                }
            }
        } onCancel: {
            Task { await self.cancelPending(connectionID: connectionID, continuationID: continuationID) }
        }
    }

    /// 读取当前运行快照。
    ///
    /// - Returns: 待刷新连接数与各项累计计数。
    public func snapshot() -> Snapshot {
        .init(
            pendingConnections: pending.count,
            submittedRequests: submittedRequests,
            executedBatches: executedBatches,
            failedBatches: failedBatches,
            largestBatch: largestBatch
        )
    }

    /// 结束批处理并以取消错误结束全部等待者。
    ///
    /// 用于进程关闭：取消已安排的刷新任务，并把所有未完成的等待者全部唤醒为取消状态，
    /// 避免关闭过程中出现悬挂的续租调用。
    public func finish() {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        scheduledFlushID = nil
        scheduledFlushIsImmediate = false
        let remaining = pending.values.flatMap { $0.continuations.values }
        pending.removeAll(keepingCapacity: false)
        for continuation in remaining { continuation.resume(throwing: CancellationError()) }
    }

    /// 安排一次延迟或立即刷新。
    ///
    /// 新的安排会取消上一次尚未执行的刷新，并以代数标识保证只有最新安排生效。
    ///
    /// - Parameter delay: 延迟时长；为零表示立即刷新。
    private func scheduleFlush(after delay: Duration) {
        scheduledFlush?.cancel()
        let flushID = makeGeneration()
        scheduledFlushID = flushID
        scheduledFlushIsImmediate = delay == .zero
        scheduledFlush = Task {
            do { try await v2Sleep(for: delay) }
            catch { return }
            await self.flush(scheduledID: flushID)
        }
    }

    /// 执行一次刷新。
    ///
    /// 取出至多一个批量的待刷新连接后提交给租约管理实现；仍有剩余时立即安排下一批。
    /// 存储未返回某个连接的结果时按拒绝处理，避免过期或身份不符的租约被不完整的实现复活。
    ///
    /// - Parameter scheduledID: 触发本次刷新的代数标识。
    private func flush(scheduledID: Generation) async {
        guard scheduledFlushID == scheduledID else { return }
        scheduledFlushID = nil
        scheduledFlush = nil
        scheduledFlushIsImmediate = false
        let connectionIDs = Array(pending.keys.prefix(configuration.maximumBatchSize))
        var batch: [UUID: PendingRenewal] = [:]
        batch.reserveCapacity(connectionIDs.count)
        for connectionID in connectionIDs {
            batch[connectionID] = pending.removeValue(forKey: connectionID)
        }
        if !pending.isEmpty { scheduleFlush(after: .zero) }
        guard !batch.isEmpty else { return }

        executedBatches &+= 1
        largestBatch = max(largestBatch, batch.count)
        do {
            let results = try await leases.renewConnections(batch.values.map(\.request))
            for (connectionID, item) in batch {
                // 行缺失表示续租遭拒。此处采用保守拒绝，避免不完整的存储实现
                // 使过期或身份不匹配的租约重新生效。
                let refresh = results[connectionID] ?? .init(
                    outcome: .rejected,
                    allowsOnlinePresence: false
                )
                for continuation in item.continuations.values {
                    continuation.resume(returning: refresh)
                }
            }
        } catch {
            failedBatches &+= 1
            for item in batch.values {
                for continuation in item.continuations.values {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 取消某个连接上的一次等待续期。
    ///
    /// 仅移除该续期本身；若该连接已无等待者，则一并清理其待刷新请求。
    ///
    /// - Parameters:
    ///   - connectionID: 连接标识。
    ///   - continuationID: 等待续期的代数标识。
    private func cancelPending(connectionID: UUID, continuationID: Generation) {
        guard var item = pending[connectionID],
              let continuation = item.continuations.removeValue(forKey: continuationID)
        else { return }
        if item.continuations.isEmpty {
            pending.removeValue(forKey: connectionID)
        } else {
            pending[connectionID] = item
        }
        continuation.resume(throwing: CancellationError())
    }

    /// 生成下一个内部代数标识。
    ///
    /// - Returns: 非零的单调递增标识。
    ///
    /// 计数耗尽时直接失败，避免代际回绕导致刷新安排错配。
    private func makeGeneration() -> Generation {
        nextGeneration &+= 1
        precondition(nextGeneration != 0, "live presence renewal generation exhausted")
        return nextGeneration
    }
}
