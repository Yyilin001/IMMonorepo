import Foundation

/// 已读回执的准入接口。
public protocol V2ReadReceiptAdmission: Sendable {
    /// 是否接管前台写入准入。
    var managesForegroundWriteAdmission: Bool { get }

    /// 接受一条已读回执记录请求。
    ///
    /// - Parameter request: 待记录请求。
    /// - Returns: 记录结果。
    /// - Throws: 准入拒绝、取消或存储失败时抛出。
    func accept(
        _ request: V2ReadReceiptRecordRequest
    ) async throws -> V2ReadReceiptOutcome
}

/// 面向单调递增已读游标的有界进程内微批处理。
///
/// 该 actor 既不改变确认边界也不改变持久化语义：等待续期只会在其操作记录与结果游标
/// 提交之后恢复。它的作用只是让相互独立的回执共享一次 PostgreSQL 事务与一条集合式校验语句。
public actor V2ReadReceiptBatcher: V2ReadReceiptAdmission {
    /// 攒批配置。
    public struct Configuration: Equatable, Sendable {
        /// 单批最大请求数。
        public let maximumBatchSize: Int
        /// 攒批最长等待时长。
        public let maximumDelay: Duration
        /// 同时在途的最大批次数。
        public let maximumInFlightBatches: Int
        /// 待处理请求上限。
        public let maximumPendingRequests: Int

        /// 校验并保存配置。
        ///
        /// - Parameters:
        ///   - maximumBatchSize: 单批请求数，需落在 `2...128`。
        ///   - maximumDelay: 攒批等待时长，需大于零且不超过 25 毫秒。
        ///   - maximumInFlightBatches: 在途批次数上限，需落在 `1...128`。
        ///   - maximumPendingRequests: 待处理请求上限，需不小于单批上限。
        ///
        /// 参数越界时直接失败，避免出现无界驻留或超过延迟预算的攒批。
        public init(
            maximumBatchSize: Int,
            maximumDelay: Duration,
            maximumInFlightBatches: Int,
            maximumPendingRequests: Int
        ) {
            precondition((2 ... 128).contains(maximumBatchSize))
            precondition(maximumDelay > .zero && maximumDelay <= .milliseconds(25))
            precondition((1 ... 128).contains(maximumInFlightBatches))
            precondition(maximumPendingRequests >= maximumBatchSize)
            self.maximumBatchSize = maximumBatchSize
            self.maximumDelay = maximumDelay
            self.maximumInFlightBatches = maximumInFlightBatches
            self.maximumPendingRequests = maximumPendingRequests
        }
    }

    /// 批量回执的运行快照。
    public struct Snapshot: Equatable, Sendable {
        /// 当前待处理请求数。
        public let pendingRequests: Int
        /// 当前在途批次数。
        public let inFlightBatches: Int
        /// 已完成批次数。
        public let completedBatches: UInt64
        /// 已完成请求数。
        public let completedRequests: UInt64
        /// 观察到的最大批次规模。
        public let maximumObservedBatchSize: Int
        /// 队列已满导致的拒绝次数。
        public let queueFullRejections: UInt64
        /// 被取消的待处理请求数。
        public let cancelledPendingRequests: UInt64
    }

    private struct OperationKey: Hashable, Sendable {
        let userID: String
        let operationID: String
    }

    private final class Pending: @unchecked Sendable {
        let id: UUID
        let request: V2ReadReceiptRecordRequest
        let continuation: CheckedContinuation<V2ReadReceiptOutcome, any Error>

        init(
            id: UUID,
            request: V2ReadReceiptRecordRequest,
            continuation: CheckedContinuation<V2ReadReceiptOutcome, any Error>
        ) {
            self.id = id
            self.request = request
            self.continuation = continuation
        }
    }

    nonisolated public let managesForegroundWriteAdmission: Bool

    private let store: any V2ReadReceiptBatchStore
    private let configuration: Configuration
    private let databaseWorkAdmission: V2DatabaseWorkAdmissionController?
    private var queue: [UUID] = []
    private var pendingByID: [UUID: Pending] = [:]
    private var flushTask: Task<Void, Never>?
    private var flushGeneration: UInt64 = 0
    private var inFlightBatches = 0
    private var completedBatches: UInt64 = 0
    private var completedRequests: UInt64 = 0
    private var maximumObservedBatchSize = 0
    private var queueFullRejections: UInt64 = 0
    private var cancelledPendingRequests: UInt64 = 0

    public init(
        store: any V2ReadReceiptBatchStore,
        configuration: Configuration,
        databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil
    ) {
        self.store = store
        self.configuration = configuration
        self.databaseWorkAdmission = databaseWorkAdmission
        managesForegroundWriteAdmission = databaseWorkAdmission != nil
    }

    /// 接受并最终完成一条已读回执记录。
    ///
    /// 请求会进入队列等待攒批或立即触发；等待续期只在其操作记录与游标提交后恢复，
    /// 因此调用方观察到的语义与直接写入完全一致。
    ///
    /// - Parameter request: 待记录请求。
    /// - Returns: 记录结果。
    /// - Throws: 队列已满时抛出 ``V2ReadReceiptBatcherError``；任务取消时抛出
    ///   `CancellationError`；其余错误来自存储实现。
    public func accept(
        _ request: V2ReadReceiptRecordRequest
    ) async throws -> V2ReadReceiptOutcome {
        let pendingID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(.init(
                    id: pendingID,
                    request: request,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task { await self.cancel(pendingID) }
        }
    }

    /// 读取当前运行快照。
    ///
    /// - Returns: 待处理与在途数量以及各项累计计数。
    public func snapshot() -> Snapshot {
        .init(
            pendingRequests: pendingByID.count,
            inFlightBatches: inFlightBatches,
            completedBatches: completedBatches,
            completedRequests: completedRequests,
            maximumObservedBatchSize: maximumObservedBatchSize,
            queueFullRejections: queueFullRejections,
            cancelledPendingRequests: cancelledPendingRequests
        )
    }

    private func enqueue(_ pending: Pending) {
        guard !Task.isCancelled else {
            pending.continuation.resume(throwing: CancellationError())
            return
        }
        guard pendingByID.count < configuration.maximumPendingRequests else {
            queueFullRejections &+= 1
            pending.continuation.resume(
                throwing: V2ReadReceiptBatcherError.serverBusy
            )
            return
        }
        pendingByID[pending.id] = pending
        queue.append(pending.id)
        dispatchAvailable(forceUnderfilled: false)
        scheduleFlushIfNeeded()
    }

    private func cancel(_ pendingID: UUID) {
        guard let pending = pendingByID.removeValue(forKey: pendingID) else {
            // Once dispatched, the durable operation is allowed to finish;
            // cancelling it could leave an unknown commit outcome.
            return
        }
        cancelledPendingRequests &+= 1
        pending.continuation.resume(throwing: CancellationError())
        compactQueueIfNeeded()
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard !pendingByID.isEmpty,
              inFlightBatches < configuration.maximumInFlightBatches,
              flushTask == nil
        else { return }
        flushGeneration &+= 1
        let generation = flushGeneration
        let delay = configuration.maximumDelay
        flushTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.flushAfterDelay(generation: generation)
        }
    }

    private func flushAfterDelay(generation: UInt64) {
        guard generation == flushGeneration else { return }
        flushTask = nil
        dispatchAvailable(forceUnderfilled: true)
        scheduleFlushIfNeeded()
    }

    private func dispatchAvailable(forceUnderfilled: Bool) {
        var mayDispatchUnderfilled = forceUnderfilled
        while inFlightBatches < configuration.maximumInFlightBatches {
            let pendingCount = pendingByID.count
            guard pendingCount >= configuration.maximumBatchSize
                    || (mayDispatchUnderfilled && pendingCount > 0)
            else { break }
            mayDispatchUnderfilled = false
            flushTask?.cancel()
            flushTask = nil
            flushGeneration &+= 1

            let batch = takeBatch()
            guard !batch.isEmpty else { break }
            inFlightBatches += 1
            maximumObservedBatchSize = max(maximumObservedBatchSize, batch.count)
            let store = self.store
            let admission = databaseWorkAdmission
            Task {
                let result: Result<[V2ReadReceiptRecordResult], any Error>
                do {
                    let outcomes: [V2ReadReceiptRecordResult]
                    if let admission {
                        switch await admission.acquire(.foregroundWrite) {
                        case .admitted:
                            do {
                                outcomes = try await store.recordBatch(
                                    batch.map(\.request)
                                )
                                await admission.release(.foregroundWrite)
                            } catch {
                                await admission.release(.foregroundWrite)
                                throw error
                            }
                        case .rejected:
                            throw V2ReadReceiptBatcherError.serverBusy
                        case .cancelled:
                            throw CancellationError()
                        }
                    } else {
                        outcomes = try await store.recordBatch(batch.map(\.request))
                    }
                    result = .success(outcomes)
                } catch {
                    result = .failure(error)
                }
                self.complete(batch: batch, result: result)
            }
        }
    }

    private func takeBatch() -> [Pending] {
        var selected: [Pending] = []
        selected.reserveCapacity(configuration.maximumBatchSize)
        var selectedOperations: Set<OperationKey> = []
        var remaining: [UUID] = []
        remaining.reserveCapacity(max(0, queue.count - configuration.maximumBatchSize))
        for pendingID in queue {
            guard let pending = pendingByID[pendingID] else { continue }
            let operation = OperationKey(
                userID: pending.request.command.actorUserID.rawValue,
                operationID: pending.request.command.operationID.rawValue
            )
            if selected.count < configuration.maximumBatchSize,
               selectedOperations.insert(operation).inserted {
                selected.append(pending)
                pendingByID.removeValue(forKey: pendingID)
            } else {
                remaining.append(pendingID)
            }
        }
        queue = remaining
        return selected
    }

    private func complete(
        batch: [Pending],
        result: Result<[V2ReadReceiptRecordResult], any Error>
    ) {
        precondition(inFlightBatches > 0)
        inFlightBatches -= 1
        completedBatches &+= 1
        completedRequests &+= UInt64(batch.count)
        switch result {
        case .success(let outcomes) where outcomes.count == batch.count:
            for (pending, outcome) in zip(batch, outcomes) {
                switch outcome {
                case .success(let value):
                    pending.continuation.resume(returning: value)
                case .failure(let error):
                    pending.continuation.resume(throwing: error)
                }
            }
        case .success:
            for pending in batch {
                pending.continuation.resume(
                    throwing: V2ReadReceiptStoreError.corruptPersistenceState
                )
            }
        case .failure(let error):
            for pending in batch { pending.continuation.resume(throwing: error) }
        }
        dispatchAvailable(forceUnderfilled: false)
        scheduleFlushIfNeeded()
    }

    private func compactQueueIfNeeded() {
        guard queue.count > pendingByID.count * 2 + 64 else { return }
        queue.removeAll { pendingByID[$0] == nil }
    }
}

/// 已读回执批处理错误。
public enum V2ReadReceiptBatcherError: Error, Equatable, Sendable {
    case serverBusy
}
