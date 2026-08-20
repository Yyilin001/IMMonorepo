import Foundation
import IMV2Core

/// Bounded, FIFO batching boundary for command acceptance.
///
/// The batcher owns no room state and never acknowledges a command before its
/// `V2AtomicRoomWriteBatchStore` reports the whole batch committed.  A future
/// PostgreSQL implementation must retain per-room order inside the SQL batch.
/// Independent rooms may run in parallel, but no room is admitted to a second
/// in-flight batch until the first has committed or failed.
public actor V2SendMessageAdmissionBatcher {
    public struct Snapshot: Equatable, Sendable {
        public let pendingRequests: Int
        public let inFlightBatches: Int
        public let activeRooms: Int
        public let stagingQueueFullRejections: UInt64
        public let cancelledPendingRequests: UInt64
    }

    public struct Configuration: Equatable, Sendable {
        public let maximumBatchSize: Int
        public let maximumDelay: Duration
        public let maximumInFlightBatches: Int
        /// Commands waiting to form a batch are still retained in gateway
        /// memory. Keep this independently bounded: moving database
        /// admission to the batch boundary must not replace one bounded queue
        /// with an unbounded one.
        public let maximumPendingRequests: Int

        public init(
            maximumBatchSize: Int,
            maximumDelay: Duration,
            maximumInFlightBatches: Int = 1,
            maximumPendingRequests: Int = 1_024
        ) {
            precondition((2 ... 128).contains(maximumBatchSize))
            precondition(maximumDelay > .zero)
            precondition((1 ... 128).contains(maximumInFlightBatches))
            precondition(maximumPendingRequests > 0)
            self.maximumBatchSize = maximumBatchSize
            self.maximumDelay = maximumDelay
            self.maximumInFlightBatches = maximumInFlightBatches
            self.maximumPendingRequests = maximumPendingRequests
        }
    }

    private struct Pending {
        let id: UUID
        let request: V2RoomWriteRequest
        let continuation: CheckedContinuation<V2SendMessageOutcome, any Error>
    }

    private let store: any V2AtomicRoomWriteBatchStore
    private let configuration: Configuration
    private var pending: [Pending] = []
    private var flushTask: Task<Void, Never>?
    private var inFlightBatchCount = 0
    private var activeRoomIDs: Set<RoomID> = []
    private var stagingQueueFullRejections: UInt64 = 0
    private var cancelledPendingRequests: UInt64 = 0

    /// The generic gateway command handler must not acquire a second
    /// foreground-write permit around a request that this batcher owns. A
    /// real atomic batch instead acquires exactly one permit immediately
    /// before its database transaction begins.
    nonisolated public let managesForegroundWriteAdmission: Bool
    private let databaseWorkAdmission: V2DatabaseWorkAdmissionController?

    public init(
        store: any V2AtomicRoomWriteBatchStore,
        configuration: Configuration,
        databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil
    ) {
        self.store = store
        self.configuration = configuration
        self.databaseWorkAdmission = databaseWorkAdmission
        managesForegroundWriteAdmission = databaseWorkAdmission != nil
    }

    deinit {
        flushTask?.cancel()
    }

    public func snapshot() -> Snapshot {
        .init(
            pendingRequests: pending.count,
            inFlightBatches: inFlightBatchCount,
            activeRooms: activeRoomIDs.count,
            stagingQueueFullRejections: stagingQueueFullRejections,
            cancelledPendingRequests: cancelledPendingRequests
        )
    }

    public func accept(_ request: V2RoomWriteRequest) async throws -> V2SendMessageOutcome {
        try Task.checkCancellation()
        let pendingID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard pending.count < configuration.maximumPendingRequests else {
                    stagingQueueFullRejections &+= 1
                    continuation.resume(throwing: V2SendMessageAdmissionBatcherError.serverBusy)
                    return
                }
                pending.append(.init(id: pendingID, request: request, continuation: continuation))
                if pending.count == 1 {
                    scheduleDelayedFlush()
                }
                if pending.count >= configuration.maximumBatchSize {
                    flushTask?.cancel()
                    flushTask = nil
                    startAvailableBatchesIfPossible()
                }
                if Task.isCancelled {
                    cancelPendingRequest(pendingID)
                }
            }
        } onCancel: {
            // Cancellation handlers cannot await the actor. This task only
            // asks the owner to remove a request that has not started a
            // durable write; it has no detached business side effect.
            Task { await self.cancelPendingRequest(pendingID) }
        }
    }

    private func scheduleDelayedFlush() {
        let delay = configuration.maximumDelay
        flushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.delayedFlushFired()
        }
    }

    private func delayedFlushFired() {
        flushTask = nil
        startAvailableBatchesIfPossible()
    }

    private func startAvailableBatchesIfPossible() {
        while inFlightBatchCount < configuration.maximumInFlightBatches {
            guard let batch = dequeueNextBatch() else { return }
            let batchRoomIDs = Set(batch.map(\.request.command.roomID))
            inFlightBatchCount += 1
            activeRoomIDs.formUnion(batchRoomIDs)
            start(batch: batch, roomIDs: batchRoomIDs)
        }
    }

    /// A command cannot overtake an earlier command for the same room.  We
    /// may, however, skip a blocked room to fill a batch with independent
    /// rooms; this avoids turning the actor itself into a global write lock.
    private func dequeueNextBatch() -> [Pending]? {
        guard !pending.isEmpty else { return nil }

        var selected: [Pending] = []
        var selectedRoomIDs = activeRoomIDs
        var remaining: [Pending] = []
        selected.reserveCapacity(configuration.maximumBatchSize)
        remaining.reserveCapacity(pending.count)

        for item in pending {
            guard selected.count < configuration.maximumBatchSize,
                  selectedRoomIDs.insert(item.request.command.roomID).inserted
            else {
                remaining.append(item)
                continue
            }
            selected.append(item)
        }
        guard !selected.isEmpty else { return nil }
        pending = remaining
        return selected
    }

    private func start(batch: [Pending], roomIDs: Set<RoomID>) {
        Task {
            let results: [Result<V2SendMessageOutcome, any Error>]
            do {
                let outcomes = try await withForegroundWriteAdmission {
                    try await self.store.acceptAtomically(requests: batch.map(\.request))
                }
                guard outcomes.count == batch.count else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                results = outcomes.map(Result.success)
            } catch V2AtomicRoomWriteBatchError.unsupportedRequestShape {
                // The durable batch rolled back before committing anything.
                // Each fallback is now an independent durable operation, so
                // run independent rooms concurrently and preserve an error
                // for only the affected command.  This is intentionally not
                // a best-effort batch: every individual fallback obtains the
                // same bounded foreground-write admission as a normal send.
                results = await acceptIndividually(batch)
            } catch {
                results = Array(repeating: .failure(error), count: batch.count)
            }
            self.complete(batch: batch, roomIDs: roomIDs, results: results)
        }
    }

    private func acceptIndividually(
        _ batch: [Pending]
    ) async -> [Result<V2SendMessageOutcome, any Error>] {
        await withTaskGroup(
            of: (Int, Result<V2SendMessageOutcome, any Error>).self,
            returning: [Result<V2SendMessageOutcome, any Error>].self
        ) { group in
            for (index, pending) in batch.enumerated() {
                group.addTask {
                    do {
                        let outcome = try await self.withForegroundWriteAdmission {
                            try await self.store.accept(
                                command: pending.request.command,
                                capacityProfile: pending.request.capacityProfile,
                                identifiers: pending.request.identifiers,
                                now: pending.request.now
                            )
                        }
                        return (index, .success(outcome))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var results = Array<Result<V2SendMessageOutcome, any Error>?>(
                repeating: nil,
                count: batch.count
            )
            for await (index, result) in group {
                results[index] = result
            }
            return results.map { $0 ?? .failure(V2RoomWriteStoreError.corruptPersistenceState) }
        }
    }

    private func withForegroundWriteAdmission<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        guard let databaseWorkAdmission else {
            return try await operation()
        }
        switch await databaseWorkAdmission.acquire(.foregroundWrite) {
        case .admitted:
            do {
                let result = try await operation()
                await databaseWorkAdmission.release(.foregroundWrite)
                return result
            } catch {
                await databaseWorkAdmission.release(.foregroundWrite)
                throw error
            }
        case .rejected:
            throw V2SendMessageAdmissionBatcherError.serverBusy
        case .cancelled:
            throw CancellationError()
        }
    }

    private func complete(
        batch: [Pending],
        roomIDs: Set<RoomID>,
        results: [Result<V2SendMessageOutcome, any Error>]
    ) {
        precondition(inFlightBatchCount > 0)
        inFlightBatchCount -= 1
        activeRoomIDs.subtract(roomIDs)
        guard results.count == batch.count else {
            batch.forEach { $0.continuation.resume(throwing: V2RoomWriteStoreError.corruptPersistenceState) }
            startAvailableBatchesIfPossible()
            return
        }
        for (pending, result) in zip(batch, results) {
            switch result {
            case .success(let outcome): pending.continuation.resume(returning: outcome)
            case .failure(let error): pending.continuation.resume(throwing: error)
            }
        }
        startAvailableBatchesIfPossible()
    }

    private func cancelPendingRequest(_ pendingID: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == pendingID }) else {
            // The batch is already executing. Its durable operation keeps the
            // normal at-least-once/idempotent semantics; it cannot safely be
            // cancelled after dequeue.
            return
        }
        let removed = pending.remove(at: index)
        cancelledPendingRequests &+= 1
        removed.continuation.resume(throwing: CancellationError())
        if pending.isEmpty {
            flushTask?.cancel()
            flushTask = nil
        }
    }
}

public enum V2SendMessageAdmissionBatcherError: Error, Sendable, Equatable {
    /// The batch staging queue or its owned database-admission queue is full
    /// (or its bounded wait elapsed). The protocol maps this to retryable
    /// `SERVER_BUSY`, never to a persistence failure.
    case serverBusy
}
