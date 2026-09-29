import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core


/// One owner per control database, shared by all copies of the presentation
/// service. Coalescing reduces SQL work; no authorization result is cached.
actor V2ProfileControlBatcher {
    struct Configuration: Sendable {
        let maximumKeys: Int
        let maximumBytes: Int
        let maximumPendingKeys: Int
        let maximumPendingBytes: Int
        let maximumInFlight: Int
        let delay: Duration
        let maximumQueueWait: Duration

        init(maximumKeys: Int = 100, maximumBytes: Int = 64 * 1024,
             maximumPendingKeys: Int = 400, maximumPendingBytes: Int = 256 * 1024,
             maximumInFlight: Int = 4, delay: Duration = .milliseconds(3),
             maximumQueueWait: Duration = .milliseconds(5)) {
            precondition((1...100).contains(maximumKeys) && (256...65_536).contains(maximumBytes))
            precondition(maximumPendingKeys >= maximumKeys && maximumPendingKeys <= 400)
            precondition(maximumPendingBytes >= maximumBytes && maximumPendingBytes <= 262_144)
            precondition((1...4).contains(maximumInFlight) && delay >= .zero && delay <= .milliseconds(5))
            precondition(maximumQueueWait >= delay && maximumQueueWait <= .milliseconds(5))
            self.maximumKeys = maximumKeys; self.maximumBytes = maximumBytes
            self.maximumPendingKeys = maximumPendingKeys; self.maximumPendingBytes = maximumPendingBytes
            self.maximumInFlight = maximumInFlight; self.delay = delay; self.maximumQueueWait = maximumQueueWait
        }
    }

    struct Statistics: Sendable {
        let pendingKeys: Int; let pendingBytes: Int; let inFlightBatches: Int; let waiters: Int
        let executedBatches: Int; let executedRequests: Int; let executedKeys: Int; let rejected: Int
    }
    private struct Entry: Sendable {
        let id: UUID; let request: V2ProfileControlRequest; let bytes: Int
        let deadline: ContinuousClock.Instant; let readyAt: ContinuousClock.Instant; let queueExpiresAt: ContinuousClock.Instant
    }
    typealias Execute = @Sendable ([V2ProfileControlRequest], ContinuousClock.Instant) async throws -> [Result<V2ProfileControlSnapshot, any Error>]
    private let execute: Execute
    private let configuration: Configuration
    private var pending: [Entry] = []
    private var pendingKeys = 0, pendingBytes = 0
    private var waiters: [UUID: CheckedContinuation<V2ProfileControlSnapshot, any Error>] = [:]
    private var activeEntries: [UUID: Entry] = [:]
    private var flights: [UUID: Task<Void, Never>] = [:]
    private var timer: Task<Void, Never>?
    private var timerID: UUID?
    private var closed = false
    private var executedBatches = 0, executedRequests = 0, executedKeys = 0, rejected = 0

    init(database: any Database) {
        configuration = .init()
        let reader = PostgresV2ProfileControlReader(database: database)
        execute = { try await reader.read($0, deadline: $1) }
    }

    // The production initializer always installs the authoritative SQL reader.
    init(configuration: Configuration, execute: @escaping Execute) {
        self.configuration = configuration; self.execute = execute
    }

    func read(_ request: V2ProfileControlRequest, deadline: ContinuousClock.Instant) async throws -> V2ProfileControlSnapshot {
        try request.validate()
        let bytes = try PostgresV2ProfileControlReader.payload([request]).count
        // Ordinals gain at most two decimal digits when this request is merged.
        let chargedBytes = bytes + request.keys.count * 2
        guard request.keys.count <= configuration.maximumKeys, chargedBytes <= configuration.maximumBytes
        else { throw V2ProfileViewReadError.invalidRequest }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let now = ContinuousClock.now
                guard !closed else { continuation.resume(throwing: V2ProfileControlBatchError.closed); return }
                guard now < deadline else { continuation.resume(throwing: V2ProfileControlBatchError.deadlineExceeded); return }
                expirePending(now)
                guard pendingKeys <= configuration.maximumPendingKeys - request.keys.count,
                      pendingBytes <= configuration.maximumPendingBytes - chargedBytes else {
                    rejected += 1
                    continuation.resume(throwing: V2ResourceProviderError.throttled(retryAfter: 1)); return
                }
                waiters[id] = continuation
                pending.append(.init(id: id, request: request, bytes: chargedBytes, deadline: deadline,
                    readyAt: now + configuration.delay, queueExpiresAt: min(deadline, now + configuration.maximumQueueWait)))
                pendingKeys += request.keys.count; pendingBytes += chargedBytes
                drain()
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    func statistics() -> Statistics {
        .init(pendingKeys: pendingKeys, pendingBytes: pendingBytes, inFlightBatches: flights.count, waiters: waiters.count,
            executedBatches: executedBatches, executedRequests: executedRequests, executedKeys: executedKeys, rejected: rejected)
    }

    func close() async {
        closed = true
        timer?.cancel(); timer = nil; timerID = nil
        pending.removeAll(); pendingKeys = 0; pendingBytes = 0
        activeEntries.removeAll()
        for continuation in waiters.values { continuation.resume(throwing: V2ProfileControlBatchError.closed) }
        waiters.removeAll()
        let running = Array(flights.values)
        for task in running { task.cancel() }
        // Cancellation cannot release SQL capacity or the database lifetime.
        // Concurrent close callers all wait for the same actual work to finish.
        for task in running { await task.value }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        activeEntries.removeValue(forKey: id)
        if let index = pending.firstIndex(where: { $0.id == id }) {
            let removed = pending.remove(at: index)
            pendingKeys -= removed.request.keys.count; pendingBytes -= removed.bytes
        }
        // A running batch can serve other callers. Its slot remains occupied
        // even if this was the final interested caller.
        drain()
    }

    private func expirePending(_ now: ContinuousClock.Instant) {
        pending.removeAll { item in
            guard item.queueExpiresAt <= now else { return false }
            pendingKeys -= item.request.keys.count; pendingBytes -= item.bytes
            if item.deadline <= now {
                waiters.removeValue(forKey: item.id)?.resume(throwing: V2ProfileControlBatchError.deadlineExceeded)
            } else {
                rejected += 1
                waiters.removeValue(forKey: item.id)?.resume(throwing: V2ResourceProviderError.throttled(retryAfter: 1))
            }
            return true
        }
    }

    private func drain() {
        timer?.cancel(); timer = nil; timerID = nil
        guard !closed else { return }
        let now = ContinuousClock.now
        expirePending(now)
        let expired = activeEntries.values.filter { $0.deadline <= now }.map(\.id)
        for id in expired {
            activeEntries.removeValue(forKey: id)
            waiters.removeValue(forKey: id)?.resume(throwing: V2ProfileControlBatchError.deadlineExceeded)
        }
        while flights.count < configuration.maximumInFlight, let first = pending.first {
            var count = 0, keys = 0, bytes = 0
            for item in pending {
                guard keys + item.request.keys.count <= configuration.maximumKeys,
                      bytes + item.bytes <= configuration.maximumBytes else { break }
                count += 1; keys += item.request.keys.count; bytes += item.bytes
            }
            guard first.readyAt <= now || keys == configuration.maximumKeys || count < pending.count else { break }
            let batch = Array(pending.prefix(count))
            pending.removeFirst(count); pendingKeys -= keys; pendingBytes -= bytes
            let flight = UUID(), deadline = batch.map(\.deadline).min()!, execute = self.execute
            executedBatches += 1; executedRequests += count; executedKeys += keys
            for item in batch { activeEntries[item.id] = item }
            flights[flight] = Task {
                let result: Result<[Result<V2ProfileControlSnapshot, any Error>], any Error>
                do { result = .success(try await execute(batch.map(\.request), deadline)) }
                catch { result = .failure(error) }
                complete(flight, batch: batch, result: result)
            }
        }
        var deadlines = activeEntries.values.map(\.deadline) + pending.map(\.queueExpiresAt)
        if flights.count < configuration.maximumInFlight, let first = pending.first { deadlines.append(first.readyAt) }
        guard let wake = deadlines.min() else { return }
        let generation = UUID(); timerID = generation
        timer = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: wake) }
            catch { return }
            await self?.wake(generation)
        }
    }

    private func wake(_ generation: UUID) {
        guard timerID == generation else { return }
        drain()
    }

    private func complete(_ flight: UUID, batch: [Entry], result: Result<[Result<V2ProfileControlSnapshot, any Error>], any Error>) {
        flights.removeValue(forKey: flight)
        let now = ContinuousClock.now
        for (index, item) in batch.enumerated() {
            activeEntries.removeValue(forKey: item.id)
            guard let continuation = waiters.removeValue(forKey: item.id) else { continue }
            guard now < item.deadline else { continuation.resume(throwing: V2ProfileControlBatchError.deadlineExceeded); continue }
            switch result {
            case .success(let values) where values.count == batch.count: continuation.resume(with: values[index])
            case .success: continuation.resume(throwing: V2ProfileControlBatchError.corruptResult)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
        drain()
    }
}

extension V2ProfileControlBatcher: V2ProfileControlReading {}
