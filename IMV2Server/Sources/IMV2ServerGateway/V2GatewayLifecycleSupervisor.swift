import Foundation
import Synchronization
import IMV2ServerContracts

private enum V2GatewayLifecycleWorkerContext {
    @TaskLocal static var ownerID: UUID?
}

/// Sole owner of retired physical writer roots. Synchronous retention closes
/// the gap between Directory operation reservation and shutdown admission.
/// The Registry reserves one operation for each exact retired lifecycle;
/// that reservation bounds this mailbox by its existing connection budget.
final class V2GatewayLifecycleSupervisor: Sendable {
    private struct Receipt: Hashable, Sendable {
        let connectionID: UUID
        let lifecycle: UInt64
    }
    private struct Work: Sendable {
        let connectionID: UUID
        let lifecycle: UInt64
        let stream: V2GatewayByteStream
        let began: ContinuousClock.Instant
        let completion: @Sendable (UUID, UInt64) async -> Void
    }
    private struct State {
        var retained: [Receipt: Work] = [:]
        var queue: [Receipt] = []
        var offset = 0
        var workers: [UUID: Task<Void, Never>] = [:]
        var actual: [Receipt: ContinuousClock.Instant] = [:]
    }
    private let state = Mutex(State())
    private let ownerID = UUID()
    private let maximumRetained: Int
    private let maximumWorkers: Int

    init(maximumRetained: Int, maximumWorkers: Int = 16) {
        precondition(maximumRetained > 0 && maximumWorkers > 0)
        self.maximumRetained = maximumRetained
        self.maximumWorkers = maximumWorkers
    }

    /// The caller has already revoked the stream and reserved the exact
    /// Directory retirement operation. Already-owned cleanup is never refused.
    func retain(connectionID: UUID, lifecycle: UInt64, stream: V2GatewayByteStream,
        completion: @escaping @Sendable (UUID, UInt64) async -> Void) {
        state.withLock { value in
            let receipt = Receipt(connectionID: connectionID, lifecycle: lifecycle)
            precondition(lifecycle > 0 && value.retained[receipt] == nil)
            precondition(value.retained.count < maximumRetained)
            value.retained[receipt] = .init(connectionID: connectionID, lifecycle: lifecycle,
                stream: stream, began: .now, completion: completion)
            value.queue.append(receipt)
            let pending = value.queue.count - value.offset
            while value.workers.count < maximumWorkers,
                  value.workers.count - value.actual.count < pending {
                let workerID = UUID()
                // An unregister can originate inside the very writer being
                // joined. These roots must not inherit that TaskLocal identity.
                value.workers[workerID] = Task.detached {
                    await V2GatewayLifecycleWorkerContext.$ownerID.withValue(self.ownerID) {
                        await self.run(workerID)
                    }
                }
            }
        }
    }

    private func next(_ workerID: UUID) -> Work? {
        state.withLock { value in
            guard value.offset < value.queue.count else {
                value.workers.removeValue(forKey: workerID)
                return nil
            }
            let id = value.queue[value.offset]
            value.offset += 1
            guard let work = value.retained[id] else { preconditionFailure("retired writer ownership") }
            if value.offset >= 256 && value.offset >= value.queue.count / 2 {
                value.queue.removeFirst(value.offset)
                value.offset = 0
            }
            value.actual[id] = .now
            return work
        }
    }

    private func run(_ workerID: UUID) async {
        while let work = next(workerID) {
            await work.stream.drainRecoveryWork()
            // The Registry completion performs synchronous settlement before
            // returning the exact Directory position, with no admission gap.
            await work.completion(work.connectionID, work.lifecycle)
            let receipt = Receipt(connectionID: work.connectionID, lifecycle: work.lifecycle)
            precondition(state.withLock { $0.retained[receipt] == nil })
        }
    }

    /// Called only inside the Registry's exact completion critical section,
    /// immediately before Directory operation release. Neither step suspends.
    func settle(connectionID: UUID, lifecycle: UInt64) {
        let receipt = Receipt(connectionID: connectionID, lifecycle: lifecycle)
        state.withLock { value in
            precondition(value.retained[receipt] != nil && value.actual[receipt] != nil)
            value.actual.removeValue(forKey: receipt)
            value.retained.removeValue(forKey: receipt)
            if value.offset == value.queue.count {
                value.queue.removeAll(keepingCapacity: true)
                value.offset = 0
            }
        }
    }

    func metricsSnapshot() -> [V2RetiredRecoveryWriterStage: V2RegistryRecoveryStageSnapshot] {
        let now = ContinuousClock.now
        return state.withLock { value in
            func stage(_ starts: [ContinuousClock.Instant]) -> V2RegistryRecoveryStageSnapshot {
                guard let began = starts.min() else { return .init() }
                let age = began.duration(to: now).components
                return .init(count: starts.count,
                    oldestMilliseconds: max(0, Double(age.seconds) * 1000 + Double(age.attoseconds) / 1e15))
            }
            return [.retainedStreams: stage(value.retained.values.map(\.began)),
                    .actualDrains: stage(Array(value.actual.values))]
        }
    }

    /// Cancellation does not release physical ownership. The independent
    /// shutdown root joins handles; a worker callback cannot join itself.
    func finish() async {
        guard V2GatewayLifecycleWorkerContext.ownerID != ownerID else { return }
        while true {
            let worker = state.withLock { value -> Task<Void, Never>? in
                if let owned = value.workers.values.first { return owned }
                precondition(value.retained.isEmpty && value.actual.isEmpty)
                return nil
            }
            guard let worker else { return }
            await worker.value
        }
    }
}
