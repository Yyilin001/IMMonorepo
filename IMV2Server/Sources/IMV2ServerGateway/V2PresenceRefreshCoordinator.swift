import Foundation
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts

struct V2PresenceRefreshTargetKey: Hashable, Sendable {
    let connection: UUID
    let lifecycle: UInt64
    let generation: UInt64
}

/// A work snapshot, never a second connection or subscription directory.
struct V2PresenceRefreshTarget: Sendable {
    var key: V2PresenceRefreshTargetKey { .init(connection: connection, lifecycle: lifecycle, generation: scopeGeneration) }
    let connection: UUID
    let lifecycle: UInt64
    let scopeGeneration: UInt64
    let request: V2PresenceObservationRequest
    let stream: V2GatewayByteStream
}

/// Owns coalesced observations, query positions and exact outbound settlement.
/// Identity/interest authority remains in Registry; socket permits never call it.
actor V2PresenceRefreshCoordinator {
    typealias Target = V2PresenceRefreshTarget
    typealias TargetKey = V2PresenceRefreshTargetKey
    enum Failure: Error { case closed, capacity, denied, malformed, stale }
    struct Snapshot: Sendable {
        let positions: Int
        let queued: Int
        let actualQueries: Int
        let resultPositions: Int
        let ownedJobs: Int
        let waiters: Int
        let handoffTickets: Int
        let settling: Int
        let closed: Bool
    }
    private struct PresenceRefreshEntry: Sendable {
        let enqueued = ContinuousClock.now
        var targets: [TargetKey: Target] = [:]
        var waiters: Set<UUID> = []
        var preparations: Set<UUID> = []
    }
    private struct PresenceRefreshWaiter {
        let enqueued = ContinuousClock.now
        var remaining: Set<V2PresenceObservationRequest>
        var targets: [V2PresenceObservationRequest: Set<TargetKey>]
        let strict: Bool
        var failure: (any Error)?
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct PrepareWaiter {
        let enqueued = ContinuousClock.now
        let target: Target
        let continuation: CheckedContinuation<V2PreparedPresenceHandoff, any Error>
        var cancelled = false
    }
    private struct Ticket: Hashable, Sendable {
        let batch: UUID
        let request: V2PresenceObservationRequest
        let target: TargetKey
    }
    private struct ResultPosition: Hashable, Sendable {
        let batch: UUID
        let request: V2PresenceObservationRequest
    }
    private var reader: (any V2LiveActivityStore)?
    private let recoveryCoordinator: V2RealtimeRecoveryCoordinator
    private let isCurrent: @Sendable (Target) async -> Bool
    private let presenceObservationExecutor = V2PresenceObservationExecutor()
    private var presenceRefreshPending: [V2PresenceObservationRequest: PresenceRefreshEntry] = [:]
    private var presenceRefreshOrder: [V2PresenceObservationRequest] = []
    private var presenceRefreshActive: Set<V2PresenceObservationRequest> = []
    private var presenceRefreshWaiters: [UUID: PresenceRefreshWaiter] = [:]
    private var prepareWaiters: [UUID: PrepareWaiter] = [:]
    private var presenceRefreshJobs: [UUID: Task<Void, Never>] = [:]
    private var querying: [UUID: ContinuousClock.Instant] = [:]
    private var ownedJobBegan: [UUID: ContinuousClock.Instant] = [:]
    private var handoffTickets: [Ticket: ContinuousClock.Instant] = [:]
    private var handoffCounts: [ResultPosition: Int] = [:]
    private var resultPositions: [ResultPosition: ContinuousClock.Instant] = [:]
    private var settling: [Ticket: ContinuousClock.Instant] = [:]
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var presenceRefreshClosed = false
    private var finishTask: Task<Void, Never>?
    private let maximumPresenceRefreshJobs = 4
    private let maximumPresenceRefreshKeys = 1_024

    init(reader: any V2LiveActivityStore, recoveryCoordinator: V2RealtimeRecoveryCoordinator,
        isCurrent: @escaping @Sendable (Target) async -> Bool) {
        self.reader = reader; self.recoveryCoordinator = recoveryCoordinator; self.isCurrent = isCurrent
    }

    func configure(reader: any V2LiveActivityStore) { self.reader = reader }

    func snapshot() -> Snapshot {
        .init(positions: presenceRefreshPending.count + presenceRefreshActive.count + resultPositions.count,
            queued: presenceRefreshPending.count, actualQueries: querying.count,
            resultPositions: resultPositions.count,
            ownedJobs: presenceRefreshJobs.count,
            waiters: presenceRefreshWaiters.count + prepareWaiters.count,
            handoffTickets: handoffTickets.count, settling: settling.count, closed: presenceRefreshClosed)
    }

    func metricsSnapshot() -> [V2PresenceObservationStage: V2RegistryRecoveryStageSnapshot] {
        let now = ContinuousClock.now
        func stage(_ values: [ContinuousClock.Instant]) -> V2RegistryRecoveryStageSnapshot {
            guard let oldest = values.min() else { return .init() }
            let age = oldest.duration(to: now).components
            return .init(count: values.count,
                oldestMilliseconds: max(0, Double(age.seconds) * 1_000 + Double(age.attoseconds) / 1e15))
        }
        let retired: [ContinuousClock.Instant] = (Array(handoffTickets) + Array(settling)).compactMap { entry in
            let (ticket, began) = entry
            let key = V2RealtimeRecoveryKey(connection: ticket.target.connection,
                kind: .userPresence, id: ticket.request.targetUserID.rawValue)
            return recoveryCoordinator.generation(for: key) == ticket.target.generation ? nil : began
        }
        return [
            .queuedKeys: stage(presenceRefreshPending.values.map(\.enqueued)),
            .actualQueries: stage(Array(querying.values)),
            .resultPositions: stage(Array(resultPositions.values)),
            .resultTickets: stage(Array(handoffTickets.values)),
            .settlingTickets: stage(Array(settling.values)),
            .retiredTickets: stage(retired),
            .ownedJobs: stage(Array(ownedJobBegan.values)),
            .waiters: stage(presenceRefreshWaiters.values.map(\.enqueued) + prepareWaiters.values.map(\.enqueued))
        ]
    }

    func prepare(_ target: Target) async throws -> V2PreparedPresenceHandoff {
        guard !presenceRefreshClosed, reader != nil else { throw Failure.closed }
        guard await isCurrent(target) else { throw Failure.stale }
        if let proof = await recoveryCoordinator.preparedPresence(
            .init(connection: target.connection, kind: .userPresence, id: target.request.targetUserID.rawValue),
            lifecycle: target.lifecycle, generation: target.scopeGeneration), proof.request == target.request,
            await isCurrent(target), proof.deadline > .now { return proof }
        guard !presenceRefreshClosed else { throw Failure.closed }
        let additional = presenceRefreshPending[target.request] == nil ? 1 : 0
        guard presenceRefreshPending.count + presenceRefreshActive.count + resultPositions.count + additional <= maximumPresenceRefreshKeys,
              presenceRefreshWaiters.count + prepareWaiters.count < maximumPresenceRefreshKeys else { throw Failure.capacity }
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                prepareWaiters[id] = .init(target: target, continuation: continuation)
                if presenceRefreshPending[target.request] == nil { presenceRefreshOrder.append(target.request) }
                var entry = presenceRefreshPending[target.request] ?? .init()
                entry.targets[target.key] = target; entry.preparations.insert(id)
                presenceRefreshPending[target.request] = entry
                pumpPresenceRefresh()
            }
        } onCancel: { Task { await self.cancelPreparation(id) } }
    }

    private func cancelPreparation(_ id: UUID) {
        guard var waiter = prepareWaiters[id] else { return }
        let request = waiter.target.request
        if var pending = presenceRefreshPending[request], pending.preparations.remove(id) != nil {
            prepareWaiters.removeValue(forKey: id)
            waiter.continuation.resume(throwing: CancellationError())
            if pending.waiters.isEmpty && pending.preparations.isEmpty { presenceRefreshPending.removeValue(forKey: request) }
            else { presenceRefreshPending[request] = pending }
            presenceRefreshOrder.removeAll { presenceRefreshPending[$0] == nil }
        } else { waiter.cancelled = true; prepareWaiters[id] = waiter }
    }

    func finish() async {
        if let finishTask { await finishTask.value; return }
        presenceRefreshClosed = true
        for (request, entry) in presenceRefreshPending {
            finishPresenceRefreshEntry(request, entry: entry, failure: Failure.closed)
            for id in entry.preparations { prepareWaiters.removeValue(forKey: id)?.continuation.resume(throwing: Failure.closed) }
        }
        presenceRefreshPending.removeAll(); presenceRefreshOrder.removeAll()
        let task = Task { await self.finishOwnedWork() }
        finishTask = task
        await task.value
    }

    private func finishOwnedWork() async {
        await presenceObservationExecutor.finish()
        while let task = presenceRefreshJobs.values.first { await task.value }
        guard !handoffCounts.isEmpty || !settling.isEmpty else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    private func signalDrain() {
        guard handoffCounts.isEmpty, settling.isEmpty else { return }
        let waiters = drainWaiters; drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func refresh(_ targets: [Target], strict: Bool) async throws {
        let grouped = Dictionary(grouping: targets, by: \.request)
        let keys = grouped.keys.sorted {
            ($0.roomID.rawValue, $0.viewerUserID.rawValue, $0.targetUserID.rawValue) <
                ($1.roomID.rawValue, $1.viewerUserID.rawValue, $1.targetUserID.rawValue)
        }
        for start in stride(from: 0, to: keys.count, by: 128) {
            let chunk = Array(keys[start..<min(start + 128, keys.count)])
            guard !presenceRefreshClosed, reader != nil else { throw Failure.closed }
            let additional = chunk.filter { presenceRefreshPending[$0] == nil }.count
            guard presenceRefreshPending.count + presenceRefreshActive.count + resultPositions.count + additional <= maximumPresenceRefreshKeys,
                  presenceRefreshWaiters.count + prepareWaiters.count < maximumPresenceRefreshKeys else { throw Failure.capacity }
            try Task.checkCancellation()
            let id = UUID()
            try await withTaskCancellationHandler(operation: { () async throws -> Void in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    let requestedTargets = Dictionary(uniqueKeysWithValues: chunk.map {
                        ($0, Set((grouped[$0] ?? []).map(\.key)))
                    })
                    presenceRefreshWaiters[id] = .init(remaining: Set(chunk), targets: requestedTargets,
                        strict: strict, continuation: continuation)
                    for request in chunk {
                        if presenceRefreshPending[request] == nil { presenceRefreshOrder.append(request) }
                        var entry = presenceRefreshPending[request] ?? .init()
                        for target in grouped[request] ?? [] { entry.targets[target.key] = target }
                        entry.waiters.insert(id); presenceRefreshPending[request] = entry
                    }
                    pumpPresenceRefresh()
                }
            }, onCancel: {
                Task { await self.cancelPresenceRefreshWaiter(id) }
            })
        }
    }

    private func cancelPresenceRefreshWaiter(_ id: UUID) {
        guard var waiter = presenceRefreshWaiters[id] else { return }
        waiter.failure = CancellationError()
        for request in Array(presenceRefreshPending.keys) {
            guard var entry = presenceRefreshPending[request], entry.waiters.remove(id) != nil else { continue }
            waiter.remaining.remove(request); waiter.targets.removeValue(forKey: request)
            if entry.waiters.isEmpty && entry.preparations.isEmpty { presenceRefreshPending.removeValue(forKey: request) }
            else { presenceRefreshPending[request] = entry }
        }
        presenceRefreshOrder.removeAll { presenceRefreshPending[$0] == nil }
        if waiter.remaining.isEmpty {
            presenceRefreshWaiters.removeValue(forKey: id)
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            // Submitted work retains this waiter until its actual SQL settles.
            presenceRefreshWaiters[id] = waiter
        }
    }

    private func pumpPresenceRefresh() {
        guard !presenceRefreshClosed, let reader else { return }
        while querying.count < maximumPresenceRefreshJobs {
            // Active keys remain queued for a fresh successor SQL snapshot.
            // Inspect the bounded queue once; all-busy does not poll.
            var selected: [V2PresenceObservationRequest: PresenceRefreshEntry] = [:]
            var remaining: [V2PresenceObservationRequest] = []
            for request in presenceRefreshOrder {
                guard presenceRefreshPending[request] != nil else { continue }
                if selected.count < 128, !presenceRefreshActive.contains(request),
                   let entry = presenceRefreshPending.removeValue(forKey: request) {
                    selected[request] = entry; presenceRefreshActive.insert(request)
                } else { remaining.append(request) }
            }
            presenceRefreshOrder = remaining
            guard !selected.isEmpty else { return }
            let id = UUID(), entries = selected
            querying[id] = .now
            ownedJobBegan[id] = .now
            presenceRefreshJobs[id] = Task {
                let result: Result<PreparedPresenceObservationBatch, any Error>
                do {
                    result = .success(try await self.presenceObservationExecutor.execute(
                        attemptID: id, requests: Array(entries.keys), reader: reader))
                } catch { result = .failure(error) }
                await self.completePresenceRefresh(id: id, entries: entries, result: result)
            }
        }
    }

    func revoke(connection: UUID, lifecycle: UInt64? = nil, generation: UInt64? = nil) {
        for request in Array(presenceRefreshPending.keys) {
            guard var entry = presenceRefreshPending[request] else { continue }
            let removed = entry.targets.filter { $0.key.connection == connection
                && (lifecycle == nil || $0.key.lifecycle == lifecycle)
                && (generation == nil || $0.key.generation == generation) }
            for (key, target) in removed {
                for id in entry.preparations where prepareWaiters[id]?.target.key == key {
                    prepareWaiters.removeValue(forKey: id)?.continuation.resume(throwing: Failure.stale)
                    entry.preparations.remove(id)
                }
                entry.targets.removeValue(forKey: key)
                finishTarget(target, entry: entry, failure: nil)
            }
            if entry.targets.isEmpty {
                presenceRefreshPending.removeValue(forKey: request)
                finishPresenceRefreshEntry(request, entry: entry, failure: nil)
            } else { presenceRefreshPending[request] = entry }
        }
        presenceRefreshOrder.removeAll { presenceRefreshPending[$0] == nil }
    }

    private func completePresenceRefresh(id: UUID,
        entries: [V2PresenceObservationRequest: PresenceRefreshEntry],
        result: Result<PreparedPresenceObservationBatch, any Error>) async {
        guard presenceRefreshJobs[id] != nil else { return }
        querying.removeValue(forKey: id)
        pumpPresenceRefresh()
        defer { presenceRefreshJobs.removeValue(forKey: id); ownedJobBegan.removeValue(forKey: id); signalDrain() }
        let batch: PreparedPresenceObservationBatch?
        let batchFailure: (any Error)?
        switch result {
        case .success(let value): batch = value; batchFailure = nil
        case .failure(let error): batch = nil; batchFailure = error
        }
        for (request, entry) in entries {
            let outcome = batch?.outcomes[request]
            for id in entry.preparations {
                guard let waiter = prepareWaiters.removeValue(forKey: id) else { continue }
                if waiter.cancelled { waiter.continuation.resume(throwing: CancellationError()); continue }
                guard !presenceRefreshClosed, await isCurrent(waiter.target) else {
                    waiter.continuation.resume(throwing: Failure.stale); continue
                }
                guard let batch, batch.deadline > .now, case .observed(let state) = outcome else {
                    waiter.continuation.resume(throwing: batchFailure ?? Failure.denied); continue
                }
                let proof = makeProof(waiter.target, state: state, deadline: batch.deadline)
                await recoveryCoordinator.recordPreparedPresence(proof)
                waiter.continuation.resume(returning: proof)
            }
            guard batchFailure == nil, let batch, batch.deadline > .now else {
                finishPresenceRefreshEntry(request, entry: entry, failure: batchFailure ?? Failure.stale)
                presenceRefreshActive.remove(request); continue
            }
            guard case .observed(let state) = outcome else {
                for target in entry.targets.values {
                    finishTarget(target, entry: entry,
                        failure: (await isCurrent(target)) ? Failure.denied : nil)
                }
                presenceRefreshActive.remove(request); continue
            }
            var handoffs: [(Target, Ticket)] = []
            for target in entry.targets.values {
                // Prepare-only waiters receive proofs, not duplicate socket writes.
                let needed = entry.waiters.contains { presenceRefreshWaiters[$0]?.targets[request]?.contains(target.key) == true }
                guard needed else { continue }
                guard !presenceRefreshClosed, await isCurrent(target) else {
                    finishTarget(target, entry: entry, failure: nil); continue
                }
                let ticket = Ticket(batch: id, request: request, target: target.key)
                handoffTickets[ticket] = .now
                handoffs.append((target, ticket))
            }
            if handoffs.isEmpty { presenceRefreshActive.remove(request); continue }
            // Transfer the original key position before the first offer await.
            // A successor query can now use the same request, while every old
            // result batch retains its own bounded responsibility until drain.
            let position = ResultPosition(batch: id, request: request)
            handoffCounts[position] = handoffs.count
            resultPositions[position] = .now
            presenceRefreshActive.remove(request)
            pumpPresenceRefresh()
            for (target, ticket) in handoffs {
                let deadline = batch.deadline
                await recoveryCoordinator.recordPreparedPresence(makeProof(target, state: state, deadline: deadline))
                let accepted = await target.stream.offerRecoveryOperation(scope: .presence,
                    scopeID: target.request.targetUserID.rawValue, scopeGeneration: target.scopeGeneration,
                    operation: { await self.handoffPresence(target, state: state, authorizationDeadline: deadline) },
                    onSettled: { accepted in await self.settle(ticket, target: target, entry: entry, accepted: accepted) })
                if !accepted { await settle(ticket, target: target, entry: entry, accepted: false) }
            }
        }
        pumpPresenceRefresh()
    }

    private func makeProof(_ target: Target, state: V2PresenceState,
        deadline: ContinuousClock.Instant) -> V2PreparedPresenceHandoff {
        .init(connection: target.connection, lifecycle: target.lifecycle, generation: target.scopeGeneration,
            request: target.request, stream: target.stream, state: state, deadline: deadline)
    }

    private func settle(_ ticket: Ticket, target: Target, entry: PresenceRefreshEntry, accepted: Bool) async {
        // Consume the exact target before the first await. Duplicate callbacks
        // can neither consume a sibling's position nor release a successor query.
        guard let began = handoffTickets.removeValue(forKey: ticket) else { return }
        settling[ticket] = began
        let current = await isCurrent(target)
        finishTarget(target, entry: entry,
            failure: !accepted && current ? V2RealtimePublicationBackpressure.receiverQueue : nil)
        let position = ResultPosition(batch: ticket.batch, request: ticket.request)
        let remaining = (handoffCounts[position] ?? 1) - 1
        if remaining == 0 {
            handoffCounts.removeValue(forKey: position)
            resultPositions.removeValue(forKey: position)
        } else { handoffCounts[position] = remaining }
        settling.removeValue(forKey: ticket)
        pumpPresenceRefresh(); signalDrain()
    }

    private func handoffPresence(_ target: Target, state: V2PresenceState,
        authorizationDeadline: ContinuousClock.Instant) async -> Bool {
        guard authorizationDeadline > .now, await isCurrent(target) else { return false }
        let key = V2RealtimeRecoveryKey(connection: target.connection, kind: .userPresence, id: target.request.targetUserID.rawValue)
        let retained = await target.stream.retainPresenceState(state,
            enqueueIfCurrent: recoveryCoordinator.recoveryWritePermit(key, generation: target.scopeGeneration,
                authorizationDeadline: authorizationDeadline))
        guard retained, await isCurrent(target), authorizationDeadline > .now else { return false }
        await recoveryCoordinator.recordScopeRetention(key, lifecycle: target.lifecycle, generation: target.scopeGeneration,
            highWatermark: 0, observedPresence: true, presenceDeadline: authorizationDeadline)
        return true
    }

    private func finishTarget(_ target: Target,
        entry: PresenceRefreshEntry, failure: (any Error)?) {
        for id in entry.waiters {
            guard var waiter = presenceRefreshWaiters[id],
                  waiter.targets[target.request]?.remove(target.key) != nil else { continue }
            if waiter.strict, waiter.failure == nil { waiter.failure = failure }
            if waiter.targets[target.request]?.isEmpty == true {
                waiter.targets.removeValue(forKey: target.request); waiter.remaining.remove(target.request)
            }
            if waiter.remaining.isEmpty {
                presenceRefreshWaiters.removeValue(forKey: id)
                if let failure = waiter.failure { waiter.continuation.resume(throwing: failure) }
                else { waiter.continuation.resume() }
            } else { presenceRefreshWaiters[id] = waiter }
        }
    }

    private func finishPresenceRefreshEntry(_ request: V2PresenceObservationRequest,
        entry: PresenceRefreshEntry, failure: (any Error)?) {
        for id in entry.waiters {
            guard var waiter = presenceRefreshWaiters[id], waiter.remaining.remove(request) != nil else { continue }
            waiter.targets.removeValue(forKey: request)
            if waiter.strict, waiter.failure == nil { waiter.failure = failure }
            if waiter.remaining.isEmpty {
                presenceRefreshWaiters.removeValue(forKey: id)
                if let error = waiter.failure { waiter.continuation.resume(throwing: error) }
                else { waiter.continuation.resume() }
            } else { presenceRefreshWaiters[id] = waiter }
        }
    }


}
