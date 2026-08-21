import Foundation
import IMV2Core

/// Bounded, FIFO batching boundary for command acceptance.
///
/// The batcher owns no room state and never acknowledges a command before its
/// durable path reports that command complete. A compatible subset may share
/// one `V2AtomicRoomWriteBatchStore` transaction while preclassified,
/// independent rooms use the ordinary path. A PostgreSQL implementation must
/// retain per-room order inside the SQL batch. Independent rooms may run in
/// parallel, but no room is admitted to a second in-flight batch until the
/// first has committed or failed.
public actor V2SendMessageAdmissionBatcher {
    public struct Snapshot: Equatable, Sendable {
        public let pendingRequests: Int
        public let inFlightBatches: Int
        public let activeRooms: Int
        public let stagingQueueFullRejections: UInt64
        public let cancelledPendingRequests: UInt64
        /// Delayed flushes that used the normal interactive latency budget.
        /// This is deliberately a count of timers that actually fired, not
        /// requests, so operational telemetry cannot mistake cancellations or
        /// full-batch flushes for additional queued latency.
        public let baseDelayFlushes: UInt64
        /// Delayed flushes that used the explicitly configured high-activity
        /// budget after the bounded arrival-rate detector was satisfied.
        public let highActivityDelayFlushes: UInt64
        /// Whether the currently staged first request is waiting under the
        /// high-activity budget. It is diagnostic only; the hard delay cap is
        /// still owned by the scheduled timer.
        public let highActivityDelayScheduled: Bool
        /// Atomic append attempts containing two or more independent rooms.
        /// These counters intentionally distinguish a successful set write
        /// from a shape fallback, so an operator can measure actual SQL
        /// coalescing rather than infer it from staging delay alone.
        public let atomicBatchAttempts: UInt64
        public let atomicBatchCommitted: UInt64
        public let atomicBatchFallbacks: UInt64
        public let atomicBatchCommittedRequests: UInt64
        public let atomicBatchFallbackRequests: UInt64
        /// Requests known before the atomic attempt to require the ordinary
        /// durable path.  They do not make an otherwise compatible batch
        /// abandon its shared transaction.
        public let atomicPreclassifiedIndividualRequests: UInt64
        /// A delayed underfilled batch is dispatched directly, without first
        /// throwing the expected unsupported-shape error from the store.
        public let singletonDispatches: UInt64

        public init(
            pendingRequests: Int,
            inFlightBatches: Int,
            activeRooms: Int,
            stagingQueueFullRejections: UInt64,
            cancelledPendingRequests: UInt64,
            baseDelayFlushes: UInt64,
            highActivityDelayFlushes: UInt64,
            highActivityDelayScheduled: Bool,
            atomicBatchAttempts: UInt64 = 0,
            atomicBatchCommitted: UInt64 = 0,
            atomicBatchFallbacks: UInt64 = 0,
            atomicBatchCommittedRequests: UInt64 = 0,
            atomicBatchFallbackRequests: UInt64 = 0,
            atomicPreclassifiedIndividualRequests: UInt64 = 0,
            singletonDispatches: UInt64 = 0
        ) {
            self.pendingRequests = pendingRequests
            self.inFlightBatches = inFlightBatches
            self.activeRooms = activeRooms
            self.stagingQueueFullRejections = stagingQueueFullRejections
            self.cancelledPendingRequests = cancelledPendingRequests
            self.baseDelayFlushes = baseDelayFlushes
            self.highActivityDelayFlushes = highActivityDelayFlushes
            self.highActivityDelayScheduled = highActivityDelayScheduled
            self.atomicBatchAttempts = atomicBatchAttempts
            self.atomicBatchCommitted = atomicBatchCommitted
            self.atomicBatchFallbacks = atomicBatchFallbacks
            self.atomicBatchCommittedRequests = atomicBatchCommittedRequests
            self.atomicBatchFallbackRequests = atomicBatchFallbackRequests
            self.atomicPreclassifiedIndividualRequests = atomicPreclassifiedIndividualRequests
            self.singletonDispatches = singletonDispatches
        }
    }

    public struct Configuration: Equatable, Sendable {
        /// A bounded, process-local detector that permits a slightly longer
        /// wait only after sustained arrivals. It never changes FIFO, room
        /// serialization, the staging bound, or the durable write contract.
        public struct AdaptiveDelayPolicy: Equatable, Sendable {
            public let highActivityMaximumDelay: Duration
            public let minimumRequestsInWindow: Int
            public let observationWindow: Duration

            public init(
                highActivityMaximumDelay: Duration,
                minimumRequestsInWindow: Int,
                observationWindow: Duration
            ) {
                precondition(highActivityMaximumDelay > .zero)
                precondition(minimumRequestsInWindow > 0)
                precondition(observationWindow > .zero)
                self.highActivityMaximumDelay = highActivityMaximumDelay
                self.minimumRequestsInWindow = minimumRequestsInWindow
                self.observationWindow = observationWindow
            }
        }

        public let maximumBatchSize: Int
        public let maximumDelay: Duration
        /// `nil` retains the exact fixed-delay behaviour used before this
        /// policy was introduced. A configured high-activity delay must be
        /// strictly longer than the base delay, otherwise it is misleading
        /// configuration with no batching benefit.
        public let adaptiveDelayPolicy: AdaptiveDelayPolicy?
        public let maximumInFlightBatches: Int
        /// Commands waiting to form a batch are still retained in gateway
        /// memory. Keep this independently bounded: moving database
        /// admission to the batch boundary must not replace one bounded queue
        /// with an unbounded one.
        public let maximumPendingRequests: Int

        public init(
            maximumBatchSize: Int,
            maximumDelay: Duration,
            adaptiveDelayPolicy: AdaptiveDelayPolicy? = nil,
            maximumInFlightBatches: Int = 1,
            maximumPendingRequests: Int = 1_024
        ) {
            precondition((2 ... 128).contains(maximumBatchSize))
            precondition(maximumDelay > .zero)
            precondition((1 ... 128).contains(maximumInFlightBatches))
            precondition(maximumPendingRequests > 0)
            if let adaptiveDelayPolicy {
                precondition(adaptiveDelayPolicy.highActivityMaximumDelay > maximumDelay)
                precondition(adaptiveDelayPolicy.minimumRequestsInWindow <= maximumPendingRequests)
            }
            self.maximumBatchSize = maximumBatchSize
            self.maximumDelay = maximumDelay
            self.adaptiveDelayPolicy = adaptiveDelayPolicy
            self.maximumInFlightBatches = maximumInFlightBatches
            self.maximumPendingRequests = maximumPendingRequests
        }
    }

    private struct Pending {
        let id: UUID
        let request: V2RoomWriteRequest
        let continuation: CheckedContinuation<V2SendMessageOutcome, any Error>
    }

    private enum ScheduledDelay: Equatable, Sendable {
        case base
        case highActivity
    }

    private let store: any V2AtomicRoomWriteBatchStore
    private let configuration: Configuration
    private var pending: [Pending] = []
    private var flushTask: Task<Void, Never>?
    private var inFlightBatchCount = 0
    private var activeRoomIDs: Set<RoomID> = []
    private var stagingQueueFullRejections: UInt64 = 0
    private var cancelledPendingRequests: UInt64 = 0
    private var baseDelayFlushes: UInt64 = 0
    private var highActivityDelayFlushes: UInt64 = 0
    private var scheduledDelay: ScheduledDelay?
    private var atomicBatchAttempts: UInt64 = 0
    private var atomicBatchCommitted: UInt64 = 0
    private var atomicBatchFallbacks: UInt64 = 0
    private var atomicBatchCommittedRequests: UInt64 = 0
    private var atomicBatchFallbackRequests: UInt64 = 0
    private var atomicPreclassifiedIndividualRequests: UInt64 = 0
    private var singletonDispatches: UInt64 = 0
    /// Use a monotonic clock so a wall-clock correction cannot accidentally
    /// put the batcher into high-activity mode or keep it there forever.
    private let clock = ContinuousClock()
    private var recentArrivalInstants: [ContinuousClock.Instant] = []

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
            cancelledPendingRequests: cancelledPendingRequests,
            baseDelayFlushes: baseDelayFlushes,
            highActivityDelayFlushes: highActivityDelayFlushes,
            highActivityDelayScheduled: scheduledDelay == .highActivity,
            atomicBatchAttempts: atomicBatchAttempts,
            atomicBatchCommitted: atomicBatchCommitted,
            atomicBatchFallbacks: atomicBatchFallbacks,
            atomicBatchCommittedRequests: atomicBatchCommittedRequests,
            atomicBatchFallbackRequests: atomicBatchFallbackRequests,
            atomicPreclassifiedIndividualRequests: atomicPreclassifiedIndividualRequests,
            singletonDispatches: singletonDispatches
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
                recordArrival()
                if pending.count == 1 {
                    scheduleDelayedFlush()
                }
                if pending.count >= configuration.maximumBatchSize {
                    flushTask?.cancel()
                    flushTask = nil
                    scheduledDelay = nil
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
        let selectedDelay: ScheduledDelay
        let delay: Duration
        if isHighActivity() {
            selectedDelay = .highActivity
            delay = configuration.adaptiveDelayPolicy!.highActivityMaximumDelay
        } else {
            selectedDelay = .base
            delay = configuration.maximumDelay
        }
        scheduledDelay = selectedDelay
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
        switch scheduledDelay {
        case .base: baseDelayFlushes &+= 1
        case .highActivity: highActivityDelayFlushes &+= 1
        case nil:
            // A cancelled timer cannot safely initiate a second batch. This
            // guard also keeps a stale task from corrupting diagnostics.
            return
        }
        scheduledDelay = nil
        startAvailableBatchesIfPossible()
    }

    private func recordArrival() {
        guard configuration.adaptiveDelayPolicy != nil else { return }
        recentArrivalInstants.append(clock.now)
        pruneArrivalHistory()
    }

    private func isHighActivity() -> Bool {
        guard let policy = configuration.adaptiveDelayPolicy else { return false }
        pruneArrivalHistory()
        return recentArrivalInstants.count >= policy.minimumRequestsInWindow
    }

    private func pruneArrivalHistory() {
        guard let policy = configuration.adaptiveDelayPolicy else {
            recentArrivalInstants.removeAll(keepingCapacity: false)
            return
        }
        let cutoff = clock.now - policy.observationWindow
        if let firstRetained = recentArrivalInstants.firstIndex(where: { $0 >= cutoff }) {
            if firstRetained > 0 {
                recentArrivalInstants.removeFirst(firstRetained)
            }
        } else {
            recentArrivalInstants.removeAll(keepingCapacity: true)
        }
        // Once the threshold is met, older in-window samples no longer alter
        // the decision. Retaining only the most recent threshold keeps memory
        // bounded even if a gateway is intentionally driven very hard.
        let maximumSamples = policy.minimumRequestsInWindow
        if recentArrivalInstants.count > maximumSamples {
            recentArrivalInstants.removeFirst(recentArrivalInstants.count - maximumSamples)
        }
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
            let disposition: BatchDisposition
            if batch.count == 1 {
                // A single request cannot satisfy the atomic-store contract.
                // Dispatch it directly instead of deliberately paying for an
                // exception-driven fallback on every underfilled timer flush.
                results = await acceptIndividually(batch)
                disposition = .singleton
            } else {
                let eligibility = await store.atomicBatchEligibility(
                    requests: batch.map(\.request)
                )
                guard eligibility.count == batch.count else {
                    results = Array(
                        repeating: .failure(V2RoomWriteStoreError.corruptPersistenceState),
                        count: batch.count
                    )
                    disposition = .atomicFailed
                    self.complete(
                        batch: batch,
                        roomIDs: roomIDs,
                        results: results,
                        disposition: disposition
                    )
                    return
                }
                let partitioned = await executePartitioned(
                    batch: batch,
                    eligibility: eligibility
                )
                results = partitioned.results
                disposition = partitioned.disposition
            }
            self.complete(
                batch: batch,
                roomIDs: roomIDs,
                results: results,
                disposition: disposition
            )
        }
    }

    /// Preserves the atomic-store contract for the compatible subset while
    /// independently admitting requests that were already known to need the
    /// normal path.  The batcher has already selected distinct, inactive room
    /// IDs, so splitting cannot reorder commands within a room.  An atomic
    /// attempt that is rejected by a durable revision check still rolls back
    /// as a unit and falls back only for that compatible subset.
    private func executePartitioned(
        batch: [Pending],
        eligibility: [Bool]
    ) async -> PartitionedExecution {
        let eligibleIndices = eligibility.indices.filter { eligibility[$0] }
        let individualIndices = eligibility.indices.filter { !eligibility[$0] }
        let eligible = eligibleIndices.map { batch[$0] }
        let individual = individualIndices.map { batch[$0] }

        guard eligible.count >= 2 else {
            return .init(
                results: await acceptIndividually(batch),
                disposition: .preclassified(
                    requestCount: individual.count
                )
            )
        }

        async let atomic = executeAtomic(eligible)
        async let individualResults = acceptIndividually(individual)
        let (atomicExecution, independentlyAccepted) = await (atomic, individualResults)

        var results = Array<Result<V2SendMessageOutcome, any Error>?>(
            repeating: nil,
            count: batch.count
        )
        for (index, result) in zip(eligibleIndices, atomicExecution.results) {
            results[index] = result
        }
        for (index, result) in zip(individualIndices, independentlyAccepted) {
            results[index] = result
        }
        return .init(
            results: results.map {
                $0 ?? .failure(V2RoomWriteStoreError.corruptPersistenceState)
            },
            disposition: atomicExecution.disposition.withPreclassifiedRequests(
                individual.count
            )
        )
    }

    private func executeAtomic(_ batch: [Pending]) async -> AtomicExecution {
        do {
            let outcomes = try await withForegroundWriteAdmission {
                try await self.store.acceptAtomically(requests: batch.map(\.request))
            }
            guard outcomes.count == batch.count else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return .init(
                results: outcomes.map(Result.success),
                disposition: .atomicCommitted(requestCount: batch.count)
            )
        } catch V2AtomicRoomWriteBatchError.unsupportedRequestShape {
            // The transaction rolled back before committing anything. Only
            // this compatible subset retries individually; requests rejected
            // by the advisory classifier are already using that same path.
            return .init(
                results: await acceptIndividually(batch),
                disposition: .fallback(requestCount: batch.count)
            )
        } catch {
            return .init(
                results: Array(repeating: .failure(error), count: batch.count),
                disposition: .atomicFailed
            )
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
        results: [Result<V2SendMessageOutcome, any Error>],
        disposition: BatchDisposition
    ) {
        precondition(inFlightBatchCount > 0)
        inFlightBatchCount -= 1
        activeRoomIDs.subtract(roomIDs)
        switch disposition {
        case .atomicCommitted(let requestCount):
            atomicBatchAttempts &+= 1
            atomicBatchCommitted &+= 1
            atomicBatchCommittedRequests &+= UInt64(requestCount)
        case .fallback(let requestCount):
            atomicBatchAttempts &+= 1
            atomicBatchFallbacks &+= 1
            atomicBatchFallbackRequests &+= UInt64(requestCount)
        case .preclassified(let requestCount):
            atomicPreclassifiedIndividualRequests &+= UInt64(requestCount)
        case .partitioned(let atomic, let preclassifiedRequestCount):
            applyAtomicDisposition(atomic)
            atomicPreclassifiedIndividualRequests &+= UInt64(preclassifiedRequestCount)
        case .atomicFailed:
            atomicBatchAttempts &+= 1
        case .singleton:
            singletonDispatches &+= 1
        }
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

    private enum BatchDisposition: Sendable {
        case atomicCommitted(requestCount: Int)
        case fallback(requestCount: Int)
        case preclassified(requestCount: Int)
        case partitioned(atomic: AtomicBatchDisposition, preclassifiedRequestCount: Int)
        case atomicFailed
        case singleton

        func withPreclassifiedRequests(_ count: Int) -> BatchDisposition {
            guard count > 0 else { return self }
            switch self {
            case .atomicCommitted(let requestCount):
                return .partitioned(
                    atomic: .committed(requestCount: requestCount),
                    preclassifiedRequestCount: count
                )
            case .fallback(let requestCount):
                return .partitioned(
                    atomic: .fallback(requestCount: requestCount),
                    preclassifiedRequestCount: count
                )
            case .atomicFailed, .singleton, .preclassified, .partitioned:
                return self
            }
        }
    }

    private enum AtomicBatchDisposition: Sendable {
        case committed(requestCount: Int)
        case fallback(requestCount: Int)
    }

    private struct AtomicExecution: Sendable {
        let results: [Result<V2SendMessageOutcome, any Error>]
        let disposition: BatchDisposition
    }

    private struct PartitionedExecution: Sendable {
        let results: [Result<V2SendMessageOutcome, any Error>]
        let disposition: BatchDisposition
    }

    private func applyAtomicDisposition(_ disposition: AtomicBatchDisposition) {
        switch disposition {
        case .committed(let requestCount):
            atomicBatchAttempts &+= 1
            atomicBatchCommitted &+= 1
            atomicBatchCommittedRequests &+= UInt64(requestCount)
        case .fallback(let requestCount):
            atomicBatchAttempts &+= 1
            atomicBatchFallbacks &+= 1
            atomicBatchFallbackRequests &+= UInt64(requestCount)
        }
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
            scheduledDelay = nil
        }
    }
}

public enum V2SendMessageAdmissionBatcherError: Error, Sendable, Equatable {
    /// The batch staging queue or its owned database-admission queue is full
    /// (or its bounded wait elapsed). The protocol maps this to retryable
    /// `SERVER_BUSY`, never to a persistence failure.
    case serverBusy
}
