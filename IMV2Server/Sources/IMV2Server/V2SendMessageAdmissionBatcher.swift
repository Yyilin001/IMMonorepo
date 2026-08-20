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
    public struct Configuration: Equatable, Sendable {
        public let maximumBatchSize: Int
        public let maximumDelay: Duration
        public let maximumInFlightBatches: Int

        public init(
            maximumBatchSize: Int,
            maximumDelay: Duration,
            maximumInFlightBatches: Int = 1
        ) {
            precondition((2 ... 128).contains(maximumBatchSize))
            precondition(maximumDelay > .zero)
            precondition((1 ... 128).contains(maximumInFlightBatches))
            self.maximumBatchSize = maximumBatchSize
            self.maximumDelay = maximumDelay
            self.maximumInFlightBatches = maximumInFlightBatches
        }
    }

    private struct Pending {
        let request: V2RoomWriteRequest
        let continuation: CheckedContinuation<V2SendMessageOutcome, any Error>
    }

    private let store: any V2AtomicRoomWriteBatchStore
    private let configuration: Configuration
    private var pending: [Pending] = []
    private var flushTask: Task<Void, Never>?
    private var inFlightBatchCount = 0
    private var activeRoomIDs: Set<RoomID> = []

    public init(
        store: any V2AtomicRoomWriteBatchStore,
        configuration: Configuration
    ) {
        self.store = store
        self.configuration = configuration
    }

    deinit {
        flushTask?.cancel()
    }

    public func accept(_ request: V2RoomWriteRequest) async throws -> V2SendMessageOutcome {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(.init(request: request, continuation: continuation))
            if pending.count == 1 {
                scheduleDelayedFlush()
            }
            if pending.count >= configuration.maximumBatchSize {
                flushTask?.cancel()
                flushTask = nil
                startAvailableBatchesIfPossible()
            }
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
        Task { [store] in
            let result: Result<[V2SendMessageOutcome], any Error>
            do {
                result = .success(try await store.acceptAtomically(requests: batch.map(\.request)))
            } catch V2AtomicRoomWriteBatchError.unsupportedRequestShape {
                // The durable batch has rolled back before committing any
                // record.  Preserve normal per-command behavior for a rich or
                // policy-changing request rather than turning an optimisation
                // miss into a client-visible failure for unrelated commands.
                do {
                    result = .success(try await batch.asyncMap { pending in
                        try await store.accept(
                            command: pending.request.command,
                            capacityProfile: pending.request.capacityProfile,
                            identifiers: pending.request.identifiers,
                            now: pending.request.now
                        )
                    })
                } catch {
                    result = .failure(error)
                }
            } catch {
                result = .failure(error)
            }
            self.complete(batch: batch, roomIDs: roomIDs, result: result)
        }
    }

    private func complete(
        batch: [Pending],
        roomIDs: Set<RoomID>,
        result: Result<[V2SendMessageOutcome], any Error>
    ) {
        precondition(inFlightBatchCount > 0)
        inFlightBatchCount -= 1
        activeRoomIDs.subtract(roomIDs)
        switch result {
        case .success(let outcomes):
            guard outcomes.count == batch.count else {
                let error = V2RoomWriteStoreError.corruptPersistenceState
                batch.forEach { $0.continuation.resume(throwing: error) }
                startAvailableBatchesIfPossible()
                return
            }
            zip(batch, outcomes).forEach { pending, outcome in
                pending.continuation.resume(returning: outcome)
            }
        case .failure(let error):
            batch.forEach { $0.continuation.resume(throwing: error) }
        }
        startAvailableBatchesIfPossible()
    }
}

private extension Array {
    func asyncMap<Result: Sendable>(
        _ transform: (Element) async throws -> Result
    ) async throws -> [Result] {
        var values: [Result] = []
        values.reserveCapacity(count)
        for value in self {
            values.append(try await transform(value))
        }
        return values
    }
}
