import Foundation
import IMV2Core
import Synchronization

/// One memory bound shared by room-keyed admission lanes.
///
/// Per-lane FIFO actors still own ordering and batch selection. Sharing only
/// the retained-request count prevents an uneven but valid room hash
/// distribution from rejecting work while sibling lanes leave most of the
/// configured process budget unused.
final class V2SharedSendMessagePendingCapacity: Sendable {
    private let maximum: Int
    /// This counter is only a capacity token; it does not publish or protect
    /// request memory. Relaxed operations are therefore sufficient. A CAS
    /// loop preserves the hard upper bound without putting every lane through
    /// a contended sleeping mutex on both enqueue and dequeue.
    private let reserved = Atomic<Int>(0)

    init(maximum: Int) {
        precondition(maximum > 0)
        self.maximum = maximum
    }

    func tryReserve() -> Bool {
        var current = reserved.load(ordering: .relaxed)
        while current < maximum {
            let result = reserved.compareExchange(
                expected: current,
                desired: current + 1,
                ordering: .relaxed
            )
            if result.exchanged { return true }
            current = result.original
        }
        return false
    }

    func release() {
        let result = reserved.wrappingSubtract(1, ordering: .relaxed)
        precondition(result.oldValue > 0, "shared pending capacity released twice")
    }
}

/// Bounded, FIFO batching boundary for command acceptance.
///
/// The batcher owns no room state and never acknowledges a command before its
/// durable path reports that command complete. A compatible subset may share
/// one `V2AtomicRoomWriteBatchStore` transaction while preclassified,
/// independent rooms use the ordinary path. A PostgreSQL implementation must
/// retain per-room order inside the SQL batch. Independent rooms may run in
/// parallel, but no room is admitted to a second in-flight batch until the
/// first has committed or failed.
public actor V2SendMessageAdmissionBatcher: V2SendMessageAdmission {
    public struct Snapshot: Equatable, Sendable {
        public let pendingRequests: Int
        public let inFlightBatches: Int
        public let activeRooms: Int
        /// Number of independently isolated batching lanes represented by
        /// this snapshot. A single actor reports one; a keyed router sums its
        /// lanes and also reports the busiest lane below.
        public let laneCount: Int
        public let busiestLanePendingRequests: Int
        public let busiestLaneInFlightBatches: Int
        /// Monotonic phase timings expose whether latency accumulates before
        /// dequeue or after a batch starts its durable execution path.
        public let dequeuedRequests: UInt64
        public let queueWaitMillisecondsTotal: UInt64
        public let queueWaitMillisecondsMax: UInt64
        public let completedBatches: UInt64
        public let batchExecutionMillisecondsTotal: UInt64
        public let batchExecutionMillisecondsMax: UInt64
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
        /// Bounded reasons reported by the authoritative store when an
        /// attempted atomic subset rolled back before any durable commit.
        public let atomicBatchFallbackReasons: [V2AtomicRoomWriteBatchError.Reason: UInt64]
        /// Later commands for a room that were deliberately kept behind the
        /// first command and executed in a subsequent unique-room wave.
        public let sameRoomDeferredRequests: UInt64
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
            laneCount: Int = 1,
            busiestLanePendingRequests: Int? = nil,
            busiestLaneInFlightBatches: Int? = nil,
            dequeuedRequests: UInt64 = 0,
            queueWaitMillisecondsTotal: UInt64 = 0,
            queueWaitMillisecondsMax: UInt64 = 0,
            completedBatches: UInt64 = 0,
            batchExecutionMillisecondsTotal: UInt64 = 0,
            batchExecutionMillisecondsMax: UInt64 = 0,
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
            atomicBatchFallbackReasons: [V2AtomicRoomWriteBatchError.Reason: UInt64] = [:],
            sameRoomDeferredRequests: UInt64 = 0,
            atomicPreclassifiedIndividualRequests: UInt64 = 0,
            singletonDispatches: UInt64 = 0
        ) {
            self.pendingRequests = pendingRequests
            self.inFlightBatches = inFlightBatches
            self.activeRooms = activeRooms
            self.laneCount = laneCount
            self.busiestLanePendingRequests = busiestLanePendingRequests ?? pendingRequests
            self.busiestLaneInFlightBatches = busiestLaneInFlightBatches ?? inFlightBatches
            self.dequeuedRequests = dequeuedRequests
            self.queueWaitMillisecondsTotal = queueWaitMillisecondsTotal
            self.queueWaitMillisecondsMax = queueWaitMillisecondsMax
            self.completedBatches = completedBatches
            self.batchExecutionMillisecondsTotal = batchExecutionMillisecondsTotal
            self.batchExecutionMillisecondsMax = batchExecutionMillisecondsMax
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
            self.atomicBatchFallbackReasons = atomicBatchFallbackReasons
            self.sameRoomDeferredRequests = sameRoomDeferredRequests
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
        let id: UInt64
        let request: V2RoomWriteRequest
        let continuation: CheckedContinuation<V2SendMessageOutcome, any Error>
        let enqueuedAt: ContinuousClock.Instant
        var previousID: UInt64?
        var nextID: UInt64?
    }

    private enum ScheduledDelay: Equatable, Sendable {
        case base
        case highActivity
    }

    private let store: any V2AtomicRoomWriteBatchStore
    private let configuration: Configuration
    private let sharedPendingCapacity: V2SharedSendMessagePendingCapacity?
    /// Intrusive FIFO storage keeps enqueue and cancellation O(1). Batch
    /// selection still walks the staged requests in arrival order, but it no
    /// longer copies the whole queue once or twice for every transaction.
    private var pendingByID: [UInt64: Pending] = [:]
    private var pendingHeadID: UInt64?
    private var pendingTailID: UInt64?
    /// Queue node identities never leave this actor or survive a restart.
    /// A monotonic value is sufficient and avoids asking the OS for secure
    /// entropy once per message merely to support O(1) cancellation.
    private var nextPendingID: UInt64 = 0
    private var pendingCount = 0
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
    private var atomicBatchFallbackReasons: [V2AtomicRoomWriteBatchError.Reason: UInt64] = [:]
    private var sameRoomDeferredRequests: UInt64 = 0
    private var atomicPreclassifiedIndividualRequests: UInt64 = 0
    private var singletonDispatches: UInt64 = 0
    private var dequeuedRequests: UInt64 = 0
    private var queueWaitMillisecondsTotal: UInt64 = 0
    private var queueWaitMillisecondsMax: UInt64 = 0
    private var completedBatches: UInt64 = 0
    private var batchExecutionMillisecondsTotal: UInt64 = 0
    private var batchExecutionMillisecondsMax: UInt64 = 0
    /// Use a monotonic clock so a wall-clock correction cannot accidentally
    /// put the batcher into high-activity mode or keep it there forever.
    private let clock = ContinuousClock()
    private var recentArrivalInstants: [ContinuousClock.Instant] = []
    /// Logical head for the bounded arrival window. Advancing it is O(1);
    /// occasional compaction replaces `Array.removeFirst` on every hot append.
    private var recentArrivalHead = 0

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
        sharedPendingCapacity = nil
        managesForegroundWriteAdmission = databaseWorkAdmission != nil
    }

    /// Internal construction path for a room-keyed router. Keeping the
    /// shared limiter out of the public API makes it impossible for callers
    /// to accidentally couple otherwise independent batchers.
    init(
        store: any V2AtomicRoomWriteBatchStore,
        configuration: Configuration,
        databaseWorkAdmission: V2DatabaseWorkAdmissionController?,
        sharedPendingCapacity: V2SharedSendMessagePendingCapacity
    ) {
        self.store = store
        self.configuration = configuration
        self.databaseWorkAdmission = databaseWorkAdmission
        self.sharedPendingCapacity = sharedPendingCapacity
        managesForegroundWriteAdmission = databaseWorkAdmission != nil
    }

    deinit {
        flushTask?.cancel()
    }

    public func snapshot() async -> Snapshot {
        .init(
            pendingRequests: pendingCount,
            inFlightBatches: inFlightBatchCount,
            activeRooms: activeRoomIDs.count,
            dequeuedRequests: dequeuedRequests,
            queueWaitMillisecondsTotal: queueWaitMillisecondsTotal,
            queueWaitMillisecondsMax: queueWaitMillisecondsMax,
            completedBatches: completedBatches,
            batchExecutionMillisecondsTotal: batchExecutionMillisecondsTotal,
            batchExecutionMillisecondsMax: batchExecutionMillisecondsMax,
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
            atomicBatchFallbackReasons: atomicBatchFallbackReasons,
            sameRoomDeferredRequests: sameRoomDeferredRequests,
            atomicPreclassifiedIndividualRequests: atomicPreclassifiedIndividualRequests,
            singletonDispatches: singletonDispatches
        )
    }

    public func accept(_ request: V2RoomWriteRequest) async throws -> V2SendMessageOutcome {
        try Task.checkCancellation()
        nextPendingID &+= 1
        precondition(nextPendingID != 0, "pending request identity exhausted")
        let pendingID = nextPendingID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let reserved = if let sharedPendingCapacity {
                    sharedPendingCapacity.tryReserve()
                } else {
                    pendingCount < configuration.maximumPendingRequests
                }
                guard reserved else {
                    stagingQueueFullRejections &+= 1
                    continuation.resume(throwing: V2SendMessageAdmissionBatcherError.serverBusy)
                    return
                }
                enqueuePending(.init(
                    id: pendingID,
                    request: request,
                    continuation: continuation,
                    enqueuedAt: clock.now,
                    previousID: nil,
                    nextID: nil
                ))
                recordArrival()
                if pendingCount == 1 {
                    scheduleDelayedFlush()
                }
                if pendingCount >= configuration.maximumBatchSize {
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
        return recentArrivalInstants.count - recentArrivalHead
            >= policy.minimumRequestsInWindow
    }

    private func pruneArrivalHistory() {
        guard let policy = configuration.adaptiveDelayPolicy else {
            recentArrivalInstants.removeAll(keepingCapacity: false)
            recentArrivalHead = 0
            return
        }
        let cutoff = clock.now - policy.observationWindow
        while recentArrivalHead < recentArrivalInstants.count,
              recentArrivalInstants[recentArrivalHead] < cutoff {
            recentArrivalHead += 1
        }
        // Once the threshold is met, older in-window samples no longer alter
        // the decision. Retaining only the most recent threshold keeps memory
        // bounded even if a gateway is intentionally driven very hard.
        let maximumSamples = policy.minimumRequestsInWindow
        let retainedCount = recentArrivalInstants.count - recentArrivalHead
        if retainedCount > maximumSamples {
            recentArrivalHead += retainedCount - maximumSamples
        }
        // Bound stale storage without shifting the array on every arrival.
        if recentArrivalHead >= 256,
           recentArrivalHead * 2 >= recentArrivalInstants.count {
            recentArrivalInstants.removeFirst(recentArrivalHead)
            recentArrivalHead = 0
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

    /// A command cannot overtake an earlier command for the same room.  The
    /// first pass gives independent, inactive rooms priority, then the second
    /// pass uses spare batch capacity for later commands from those same
    /// rooms.  This is important for a hot direct conversation: a strictly
    /// one-room-per-batch selector leaves the very write lane that needs
    /// amortisation permanently on single-command transactions.  Conversely,
    /// filling the first batch slot-by-slot with a hot room would starve
    /// unrelated conversations behind it.
    ///
    /// The PostgreSQL batch store serializes equal room IDs in arrival order
    /// and advances their room sequences in one transaction.  A room already
    /// owned by an in-flight batch remains in `remaining`, preserving the
    /// existing no-overtake rule across transactions.
    private func dequeueNextBatch() -> [Pending]? {
        guard pendingCount > 0 else { return nil }

        var selected: [Pending] = []
        defer { recordDequeued(selected) }
        var selectedRoomIDs = activeRoomIDs
        selected.reserveCapacity(configuration.maximumBatchSize)

        // Fairness pass: pick at most one command per inactive room first.
        var cursor = pendingHeadID
        while let itemID = cursor,
              let item = pendingByID[itemID],
              selected.count < configuration.maximumBatchSize
        {
            cursor = item.nextID
            if selectedRoomIDs.insert(item.request.command.roomID).inserted,
               let removed = removePending(itemID)
            {
                selected.append(removed)
            }
        }
        // Hot-room pass: after every selected room has had an opportunity to
        // enter this transaction, fill spare capacity only with commands for
        // those rooms.  Keeping commands for a newly seen room in
        // `remaining` gives it first-pass priority in the next transaction.
        guard selected.count < configuration.maximumBatchSize else { return selected }
        let batchRoomIDs = Set(selected.map(\.request.command.roomID))
        cursor = pendingHeadID
        while let itemID = cursor,
              let item = pendingByID[itemID],
              selected.count < configuration.maximumBatchSize
        {
            cursor = item.nextID
            if batchRoomIDs.contains(item.request.command.roomID),
               let removed = removePending(itemID)
            {
                selected.append(removed)
            }
        }
        guard !selected.isEmpty else { return nil }
        return selected
    }

    private func enqueuePending(_ item: Pending) {
        var item = item
        item.previousID = pendingTailID
        if let tailID = pendingTailID, var tail = pendingByID[tailID] {
            tail.nextID = item.id
            pendingByID[tailID] = tail
        } else {
            pendingHeadID = item.id
        }
        pendingTailID = item.id
        pendingByID[item.id] = item
        pendingCount += 1
    }

    @discardableResult
    private func removePending(_ id: UInt64) -> Pending? {
        guard let item = pendingByID.removeValue(forKey: id) else { return nil }
        if let previousID = item.previousID, var previous = pendingByID[previousID] {
            previous.nextID = item.nextID
            pendingByID[previousID] = previous
        } else {
            pendingHeadID = item.nextID
        }
        if let nextID = item.nextID, var next = pendingByID[nextID] {
            next.previousID = item.previousID
            pendingByID[nextID] = next
        } else {
            pendingTailID = item.previousID
        }
        pendingCount -= 1
        sharedPendingCapacity?.release()
        var detached = item
        detached.previousID = nil
        detached.nextID = nil
        return detached
    }

    private func start(batch: [Pending], roomIDs: Set<RoomID>) {
        sameRoomDeferredRequests &+= UInt64(batch.count - roomIDs.count)
        let executionStartedAt = clock.now
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
                let partitions = await store.atomicBatchPartitions(
                    requests: batch.map(\.request)
                )
                guard partitions.count == batch.count else {
                    results = Array(
                        repeating: .failure(V2RoomWriteStoreError.corruptPersistenceState),
                        count: batch.count
                    )
                    disposition = .atomicFailed
                    self.complete(
                        batch: batch,
                        roomIDs: roomIDs,
                        results: results,
                        disposition: disposition,
                        executionStartedAt: executionStartedAt
                    )
                    return
                }
                let partitioned = await executePartitioned(
                    batch: batch,
                    partitions: partitions
                )
                results = partitioned.results
                disposition = partitioned.disposition
            }
            self.complete(
                batch: batch,
                roomIDs: roomIDs,
                results: results,
                disposition: disposition,
                executionStartedAt: executionStartedAt
            )
        }
    }

    /// Preserves the atomic-store contract for each compatible subset.
    ///
    /// PostgreSQL's room-log statements advance one durable cursor per room,
    /// so one store call must never contain the same room twice.  The staging
    /// selector may nevertheless include later commands for a hot room to
    /// avoid starving it behind colder traffic.  Execute those commands as
    /// ordered, unique-room waves: a later command from one room cannot begin
    /// before its predecessor has completed, while unrelated rooms still
    /// retain set-based transaction amortisation inside every wave.
    ///
    /// Compatibility partitions execute serially inside a wave because they
    /// can still contend on shared shard-admission rows. An atomic attempt
    /// rejected by a durable revision check rolls back as a unit and falls
    /// back only for that compatible subset.
    private func executePartitioned(
        batch: [Pending],
        partitions: [V2AtomicRoomWriteBatchPartition?]
    ) async -> PartitionedExecution {
        var results = Array<Result<V2SendMessageOutcome, any Error>?>(
            repeating: nil,
            count: batch.count
        )
        var dispositions: [BatchDisposition] = []
        var preclassifiedRequestCount = 0
        var remainingIndices = Array(batch.indices)

        while !remainingIndices.isEmpty {
            var waveRoomIDs: Set<RoomID> = []
            var waveIndices: [Int] = []
            var deferredIndices: [Int] = []
            waveIndices.reserveCapacity(remainingIndices.count)
            deferredIndices.reserveCapacity(remainingIndices.count)
            for index in remainingIndices {
                let roomID = batch[index].request.command.roomID
                if waveRoomIDs.insert(roomID).inserted {
                    waveIndices.append(index)
                } else {
                    deferredIndices.append(index)
                }
            }
            remainingIndices = deferredIndices

            // Retain first-seen partition order instead of relying on
            // Dictionary iteration. This keeps lock acquisition and test
            // behaviour deterministic across processes and Swift versions.
            var orderedPartitions: [V2AtomicRoomWriteBatchPartition] = []
            var indicesByPartition: [V2AtomicRoomWriteBatchPartition: [Int]] = [:]
            var individualIndices: [Int] = []
            for index in waveIndices {
                guard let partition = partitions[index] else {
                    individualIndices.append(index)
                    continue
                }
                if indicesByPartition[partition] == nil {
                    orderedPartitions.append(partition)
                }
                indicesByPartition[partition, default: []].append(index)
            }

            for partition in orderedPartitions {
                guard let indices = indicesByPartition[partition] else { continue }
                if indices.count == 1 {
                    individualIndices.append(indices[0])
                    continue
                }
                let execution = await executeAtomic(indices.map { batch[$0] })
                for (index, result) in zip(indices, execution.results) {
                    results[index] = result
                }
                dispositions.append(execution.disposition)
            }

            if !individualIndices.isEmpty {
                let independentlyAccepted = await acceptIndividually(
                    individualIndices.map { batch[$0] }
                )
                for (index, result) in zip(individualIndices, independentlyAccepted) {
                    results[index] = result
                }
                preclassifiedRequestCount += individualIndices.count
            }
        }

        return .init(
            results: results.map {
                $0 ?? .failure(V2RoomWriteStoreError.corruptPersistenceState)
            },
            disposition: .multiplePartitions(
                atomic: dispositions,
                preclassifiedRequestCount: preclassifiedRequestCount
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
        } catch let batchError as V2AtomicRoomWriteBatchError {
            if let isolated = validatedIsolatedRequestIndices(
                batchError.isolatedRequestIndices,
                batchCount: batch.count
            ) {
                let isolatedSet = Set(isolated)
                let compatibleIndices = batch.indices.filter {
                    !isolatedSet.contains($0)
                }
                // Retrying one remaining request atomically is impossible and
                // provides no batching benefit. In that degenerate case the
                // existing scalar fallback remains the bounded behavior.
                if compatibleIndices.count >= 2 {
                    let compatibleExecution = await executeAtomic(
                        compatibleIndices.map { batch[$0] }
                    )
                    let isolatedResults = await acceptIndividually(
                        isolated.map { batch[$0] }
                    )
                    var results = Array<Result<V2SendMessageOutcome, any Error>?>(
                        repeating: nil,
                        count: batch.count
                    )
                    for (index, result) in zip(
                        compatibleIndices,
                        compatibleExecution.results
                    ) {
                        results[index] = result
                    }
                    for (index, result) in zip(isolated, isolatedResults) {
                        results[index] = result
                    }
                    return .init(
                        results: results.map {
                            $0 ?? .failure(V2RoomWriteStoreError.corruptPersistenceState)
                        },
                        disposition: .multiplePartitions(
                            atomic: [
                                .fallback(
                                    requestCount: batch.count,
                                    reason: batchError.reason
                                ),
                                compatibleExecution.disposition,
                            ],
                            preclassifiedRequestCount: isolated.count
                        )
                    )
                }
            }
            // The transaction rolled back before committing anything. Only
            // this compatible subset retries individually; requests rejected
            // by the advisory classifier are already using that same path.
            return .init(
                results: await acceptIndividually(batch),
                disposition: .fallback(
                    requestCount: batch.count,
                    reason: batchError.reason
                )
            )
        } catch {
            return .init(
                results: Array(repeating: .failure(error), count: batch.count),
                disposition: .atomicFailed
            )
        }
    }

    private func validatedIsolatedRequestIndices(
        _ indices: [Int],
        batchCount: Int
    ) -> [Int]? {
        guard !indices.isEmpty, indices.count < batchCount else { return nil }
        let unique = Set(indices)
        guard unique.count == indices.count,
              unique.allSatisfy({ (0..<batchCount).contains($0) })
        else { return nil }
        return unique.sorted()
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
        disposition: BatchDisposition,
        executionStartedAt: ContinuousClock.Instant
    ) {
        precondition(inFlightBatchCount > 0)
        let executionMilliseconds = elapsedMilliseconds(since: executionStartedAt)
        completedBatches &+= 1
        batchExecutionMillisecondsTotal = saturatingAdd(
            batchExecutionMillisecondsTotal,
            executionMilliseconds
        )
        batchExecutionMillisecondsMax = max(
            batchExecutionMillisecondsMax,
            executionMilliseconds
        )
        inFlightBatchCount -= 1
        activeRoomIDs.subtract(roomIDs)
        switch disposition {
        case .atomicCommitted(let requestCount):
            atomicBatchAttempts &+= 1
            atomicBatchCommitted &+= 1
            atomicBatchCommittedRequests &+= UInt64(requestCount)
        case .fallback(let requestCount, let reason):
            atomicBatchAttempts &+= 1
            atomicBatchFallbacks &+= 1
            atomicBatchFallbackRequests &+= UInt64(requestCount)
            atomicBatchFallbackReasons[reason, default: 0] &+= 1
        case .preclassified(let requestCount):
            atomicPreclassifiedIndividualRequests &+= UInt64(requestCount)
        case .partitioned(let atomic, let preclassifiedRequestCount):
            applyAtomicDisposition(atomic)
            atomicPreclassifiedIndividualRequests &+= UInt64(preclassifiedRequestCount)
        case .multiplePartitions(let atomic, let preclassifiedRequestCount):
            for disposition in atomic { applyDisposition(disposition) }
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
        case fallback(requestCount: Int, reason: V2AtomicRoomWriteBatchError.Reason)
        case preclassified(requestCount: Int)
        case partitioned(atomic: AtomicBatchDisposition, preclassifiedRequestCount: Int)
        case multiplePartitions(atomic: [BatchDisposition], preclassifiedRequestCount: Int)
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
            case .fallback(let requestCount, let reason):
                return .partitioned(
                    atomic: .fallback(requestCount: requestCount, reason: reason),
                    preclassifiedRequestCount: count
                )
            case .atomicFailed, .singleton, .preclassified, .partitioned,
                 .multiplePartitions:
                return self
            }
        }
    }

    private enum AtomicBatchDisposition: Sendable {
        case committed(requestCount: Int)
        case fallback(requestCount: Int, reason: V2AtomicRoomWriteBatchError.Reason)
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
        case .fallback(let requestCount, let reason):
            atomicBatchAttempts &+= 1
            atomicBatchFallbacks &+= 1
            atomicBatchFallbackRequests &+= UInt64(requestCount)
            atomicBatchFallbackReasons[reason, default: 0] &+= 1
        }
    }

    private func applyDisposition(_ disposition: BatchDisposition) {
        switch disposition {
        case .atomicCommitted(let requestCount):
            atomicBatchAttempts &+= 1
            atomicBatchCommitted &+= 1
            atomicBatchCommittedRequests &+= UInt64(requestCount)
        case .fallback(let requestCount, let reason):
            atomicBatchAttempts &+= 1
            atomicBatchFallbacks &+= 1
            atomicBatchFallbackRequests &+= UInt64(requestCount)
            atomicBatchFallbackReasons[reason, default: 0] &+= 1
        case .preclassified(let requestCount):
            atomicPreclassifiedIndividualRequests &+= UInt64(requestCount)
        case .partitioned(let atomic, let preclassifiedRequestCount):
            applyAtomicDisposition(atomic)
            atomicPreclassifiedIndividualRequests &+= UInt64(preclassifiedRequestCount)
        case .multiplePartitions(let dispositions, let preclassifiedRequestCount):
            for nested in dispositions { applyDisposition(nested) }
            atomicPreclassifiedIndividualRequests &+= UInt64(preclassifiedRequestCount)
        case .atomicFailed:
            atomicBatchAttempts &+= 1
        case .singleton:
            singletonDispatches &+= 1
        }
    }

    private func cancelPendingRequest(_ pendingID: UInt64) {
        guard let removed = removePending(pendingID) else {
            // The batch is already executing. Its durable operation keeps the
            // normal at-least-once/idempotent semantics; it cannot safely be
            // cancelled after dequeue.
            return
        }
        cancelledPendingRequests &+= 1
        removed.continuation.resume(throwing: CancellationError())
        if pendingCount == 0 {
            flushTask?.cancel()
            flushTask = nil
            scheduledDelay = nil
        }
    }

    private func recordDequeued(_ batch: [Pending]) {
        guard !batch.isEmpty else { return }
        let now = clock.now
        dequeuedRequests &+= UInt64(batch.count)
        for item in batch {
            let milliseconds = elapsedMilliseconds(from: item.enqueuedAt, to: now)
            queueWaitMillisecondsTotal = saturatingAdd(
                queueWaitMillisecondsTotal,
                milliseconds
            )
            queueWaitMillisecondsMax = max(queueWaitMillisecondsMax, milliseconds)
        }
    }

    private func elapsedMilliseconds(since instant: ContinuousClock.Instant) -> UInt64 {
        elapsedMilliseconds(from: instant, to: clock.now)
    }

    private func elapsedMilliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> UInt64 {
        let components = start.duration(to: end).components
        guard components.seconds > 0 || components.attoseconds > 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let wholeMilliseconds = seconds.multipliedReportingOverflow(by: 1_000)
        guard !wholeMilliseconds.overflow else { return .max }
        let fractionalMilliseconds = UInt64(
            components.attoseconds / 1_000_000_000_000_000
        )
        return saturatingAdd(wholeMilliseconds.partialValue, fractionalMilliseconds)
    }

    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}

public enum V2SendMessageAdmissionBatcherError: Error, Sendable, Equatable {
    /// The batch staging queue or its owned database-admission queue is full
    /// (or its bounded wait elapsed). The protocol maps this to retryable
    /// `SERVER_BUSY`, never to a persistence failure.
    case serverBusy
}
