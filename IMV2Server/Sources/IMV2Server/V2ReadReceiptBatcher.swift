import Foundation

public protocol V2ReadReceiptAdmission: Sendable {
    var managesForegroundWriteAdmission: Bool { get }

    func accept(
        _ request: V2ReadReceiptRecordRequest
    ) async throws -> V2ReadReceiptOutcome
}

/// Bounded process-local micro-batching for monotonic read cursors.
///
/// The actor changes neither the acknowledgement boundary nor durability: a
/// continuation resumes only after its operation row and resulting cursor
/// commit. It merely lets independent receipts share one PostgreSQL
/// transaction and one set-based validation statement.
public actor V2ReadReceiptBatcher: V2ReadReceiptAdmission {
    public struct Configuration: Equatable, Sendable {
        public let maximumBatchSize: Int
        public let maximumDelay: Duration
        public let maximumInFlightBatches: Int
        public let maximumPendingRequests: Int

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

    public struct Snapshot: Equatable, Sendable {
        public let pendingRequests: Int
        public let inFlightBatches: Int
        public let completedBatches: UInt64
        public let completedRequests: UInt64
        public let maximumObservedBatchSize: Int
        public let queueFullRejections: UInt64
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

public enum V2ReadReceiptBatcherError: Error, Equatable, Sendable {
    case serverBusy
}
