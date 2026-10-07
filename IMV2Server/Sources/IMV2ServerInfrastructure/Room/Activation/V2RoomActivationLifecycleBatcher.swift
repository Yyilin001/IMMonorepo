import IMV2ServerApplication
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core

/// Physical Store copies share this bounded queue. A submitted room and its
/// budget remain owned until the actual transaction settles, including unknown.
package actor V2RoomActivationLifecycleBatcher {
    private struct Pending: Sendable {
        let id: UUID
        let roomKey: UUID
        let input: V2RoomActivationLifecycleInput
        let deadline: ContinuousClock.Instant
        let enqueuedAt: ContinuousClock.Instant
        let bytes: Int
        let continuation: CheckedContinuation<V2RoomActivationLifecycleValue, any Error>
    }
    package typealias Executor = @Sendable ([V2RoomActivationLifecycleInput], ContinuousClock.Instant) async throws -> [Result<V2RoomActivationLifecycleValue, any Error>]
    private let executor: Executor
    private let timeouts: V2RoomActivationSQLTimeouts
    private var queue: [Pending] = []
    private var occupied: Set<UUID> = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var retained = 0
    private var retainedBytes = 0
    private var closed = false
    private var timer: Task<Void, Never>?
    private var timerID: UUID?
    private var timerWake: ContinuousClock.Instant?
    private var drains: [CheckedContinuation<Void, Never>] = []

    package init(database: any Database, schema: String, timeouts: V2RoomActivationSQLTimeouts, sqlContinuationMetrics: V2SendOperationBatchMetrics? = nil) {
        self.timeouts = timeouts
        self.executor = { inputs, deadline in
            try await V2RoomSQLContinuationObservation.$metrics.withValue(sqlContinuationMetrics) {
                try await V2RoomSQLDeadline.withSelectedDeadline(deadline) {
                    try await V2RoomActivationLifecycleSQL.commit(inputs, database: database, schema: schema, timeouts: timeouts)
                }
            }
        }
    }

    /// Exercises scheduling with an owned actual executor, without replacing
    /// the immutable input or teaching the collector when SQL has settled.
    package init(timeouts: V2RoomActivationSQLTimeouts = .default, executor: @escaping Executor) {
        self.timeouts = timeouts; self.executor = executor
    }

    package nonisolated func execute(_ input: V2RoomActivationLifecycleInput) async throws -> V2RoomActivationLifecycleValue {
        try Task.checkCancellation()
        guard let roomKey = input.roomID.uuidValue else { throw V2CoreError.invalidIdentifier }
        // Capture before waiting to enter this actor, never reset queue time.
        let deadline = min(V2RoomSQLDeadline.boundedTransactionDeadline(),
                           .now + .milliseconds(timeouts.statementMilliseconds))
        return try await enqueue(input, roomKey: roomKey, deadline: deadline)
    }

    private func enqueue(_ input: V2RoomActivationLifecycleInput, roomKey: UUID,
                         deadline: ContinuousClock.Instant) async throws -> V2RoomActivationLifecycleValue {
        try Task.checkCancellation()
        guard !closed else { throw V2RoomCallFailure.notAccepted(.retired) }
        guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        // Includes fixed-size token fields and exact retained string bytes.
        let bytes = Self.retainedSize(input)
        guard retained < 1_024, bytes <= 1_048_576 - retainedBytes else {
            throw V2RoomCallFailure.notAccepted(.overloaded)
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: V2RoomCallFailure.notAccepted(.cancelled)); return
                }
                queue.append(.init(id: id, roomKey: roomKey, input: input, deadline: deadline, enqueuedAt: .now,
                                   bytes: bytes, continuation: continuation))
                retained += 1; retainedBytes += bytes
                schedule()
            }
        } onCancel: {
            Task { await self.cancelQueued(id) }
        }
    }

    private static func retainedSize(_ input: V2RoomActivationLifecycleInput) -> Int {
        let owner: V2RoomDataOwner
        let host: V2ActorHostIdentity?
        switch input.operation {
        case .locate(let value): owner = value; host = nil
        case .acquire(let value, let identity, _): owner = value; host = identity
        case .release(let token), .validate(let token): owner = token.owner; host = token.host
        }
        return 256 + input.roomID.rawValue.utf8.count + owner.shardID.utf8.count
            + (host?.hostID.rawValue.utf8.count ?? 0)
    }

    private func cancelQueued(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let pending = queue.remove(at: index)
        release(pending)
        pending.continuation.resume(throwing: V2RoomCallFailure.notAccepted(.cancelled))
        schedule()
    }

    private func release(_ pending: Pending) {
        retained -= 1; retainedBytes -= pending.bytes
    }

    private func prune(_ now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        var earliest: ContinuousClock.Instant?
        var remaining: [Pending] = []
        for pending in queue {
            if pending.deadline <= now {
                release(pending)
                pending.continuation.resume(throwing: V2RoomCallFailure.notAccepted(.deadlineExceeded))
            } else {
                remaining.append(pending)
                earliest = earliest.map { min($0, pending.deadline) } ?? pending.deadline
            }
        }
        queue = remaining
        return earliest
    }

    private func availableHeads() -> [Pending] {
        var seen = occupied
        return queue.filter { seen.insert($0.roomKey).inserted }
    }

    private func schedule() {
        guard !closed else { return }
        let now = ContinuousClock.now
        var wake = prune(now)
        if tasks.count < 2 {
            let heads = availableHeads()
            if let age = heads.map({ min($0.enqueuedAt + .milliseconds(2), $0.deadline) }).min() {
                if heads.count >= 128 || age <= now {
                    cancelTimer()
                    flush()
                    return
                }
                wake = wake.map { min($0, age) } ?? age
            }
        }
        // All busy/full slots retain deadline-only wakes, never coalescing polling.
        guard let wake else { cancelTimer(); return }
        if timer != nil, let timerWake, timerWake <= wake { return }
        cancelTimer()
        let id = UUID(); timerID = id; timerWake = wake
        timer = Task.detached {
            do { try await Task.sleep(until: wake, clock: .continuous) }
            catch { return }
            await self.woke(id)
        }
    }

    private func woke(_ id: UUID) {
        guard timerID == id else { return }
        timer = nil; timerID = nil; timerWake = nil
        schedule()
    }

    private func cancelTimer() {
        timer?.cancel(); timer = nil; timerID = nil; timerWake = nil
    }

    private func flush() {
        while tasks.count < 2 {
            var selected: [Pending] = []
            var remaining: [Pending] = []
            var seen = occupied
            for pending in queue {
                if selected.count < 128, seen.insert(pending.roomKey).inserted {
                    selected.append(pending)
                } else { remaining.append(pending) }
            }
            guard !selected.isEmpty else { break }
            queue = remaining
            occupied.formUnion(selected.map { $0.roomKey })
            let id = UUID()
            let executor = self.executor
            let deadline = selected.map(\.deadline).min()!
            tasks[id] = Task.detached {
                let result: Result<[Result<V2RoomActivationLifecycleValue, any Error>], any Error>
                do {
                    let values = try await V2RoomSQLDeadline.withSelectedDeadline(deadline) {
                        try await executor(selected.map(\.input), deadline)
                    }
                    guard values.count == selected.count else { throw V2RoomActivationLeaseError.outcomeUnknown }
                    result = .success(values)
                } catch { result = .failure(error) }
                await self.completed(id, selected, result)
            }
        }
        schedule()
    }

    private func completed(_ id: UUID, _ selected: [Pending],
                           _ result: Result<[Result<V2RoomActivationLifecycleValue, any Error>], any Error>) {
        guard tasks.removeValue(forKey: id) != nil else { return }
        for (index, pending) in selected.enumerated() {
            occupied.remove(pending.roomKey)
            release(pending)
            switch result {
            case .success(let values): pending.continuation.resume(with: values[index])
            case .failure(let error): pending.continuation.resume(throwing: error)
            }
        }
        if closed, tasks.isEmpty {
            let waiters = drains; drains.removeAll()
            for waiter in waiters { waiter.resume() }
        } else { schedule() }
    }

    package func shutdown() async {
        closed = true; cancelTimer()
        let pending = queue; queue.removeAll()
        for item in pending {
            release(item)
            item.continuation.resume(throwing: V2RoomCallFailure.notAccepted(.retired))
        }
        if !tasks.isEmpty { await withCheckedContinuation { drains.append($0) } }
    }
}
