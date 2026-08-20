import Foundation

/// Bounded, FIFO batching boundary for command acceptance.
///
/// The batcher owns no room state and never acknowledges a command before its
/// `V2AtomicRoomWriteBatchStore` reports the whole batch committed.  A future
/// PostgreSQL implementation must retain per-room order inside the SQL batch;
/// this actor retains arrival order between batches and limits the additional
/// queueing delay.
public actor V2SendMessageAdmissionBatcher {
    public struct Configuration: Equatable, Sendable {
        public let maximumBatchSize: Int
        public let maximumDelay: Duration

        public init(maximumBatchSize: Int, maximumDelay: Duration) {
            precondition((2 ... 128).contains(maximumBatchSize))
            precondition(maximumDelay > .zero)
            self.maximumBatchSize = maximumBatchSize
            self.maximumDelay = maximumDelay
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
    private var batchInFlight = false

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
                startNextBatchIfPossible()
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
        startNextBatchIfPossible()
    }

    private func startNextBatchIfPossible() {
        guard !batchInFlight, !pending.isEmpty else { return }
        batchInFlight = true
        let count = min(pending.count, configuration.maximumBatchSize)
        let batch = Array(pending.prefix(count))
        pending.removeFirst(count)
        Task { [store] in
            let result: Result<[V2SendMessageOutcome], any Error>
            do {
                result = .success(try await store.acceptAtomically(requests: batch.map(\.request)))
            } catch {
                result = .failure(error)
            }
            self.complete(batch: batch, result: result)
        }
    }

    private func complete(
        batch: [Pending],
        result: Result<[V2SendMessageOutcome], any Error>
    ) {
        batchInFlight = false
        switch result {
        case .success(let outcomes):
            guard outcomes.count == batch.count else {
                let error = V2RoomWriteStoreError.corruptPersistenceState
                batch.forEach { $0.continuation.resume(throwing: error) }
                startNextBatchIfPossible()
                return
            }
            zip(batch, outcomes).forEach { pending, outcome in
                pending.continuation.resume(returning: outcome)
            }
        case .failure(let error):
            batch.forEach { $0.continuation.resume(throwing: error) }
        }
        startNextBatchIfPossible()
    }
}
