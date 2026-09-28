import Foundation
import IMV2Core

/// One account's owner of durable execution. Domain steps own their semantics;
/// leaf transports independently acquire network permits. No parent permit is
/// held while a step waits for authentication or a child request.
public actor V2OperationWorkDispatcher {
    public struct Handler: Sendable {
        public let kind: V2OperationKind
        public let execute: @Sendable (V2OperationWorkClaim) async throws -> Void
        public init(kind: V2OperationKind, execute: @escaping @Sendable (V2OperationWorkClaim) async throws -> Void) {
            self.kind = kind; self.execute = execute
        }
    }
    private let store: GRDBV2LocalSyncStore
    private let handlers: [V2OperationKind: Handler]
    private let maximumInFlight: Int
    private let ownerID: UUID
    private let now: @Sendable () -> Date
    private let diagnostics: V2NetworkDiagnostics?
    private let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var flights: [UUID: Task<Void, Never>] = [:]
    private var recoveryFlights: Set<UUID> = []
    private var admissionCursor = 0
    private let admissionWheel = [true, true, true, false]
    // Only a fresh first attempt receives short-lived interactive preference.
    // Old unsent backlog and explicit resume retain recovery priority. Reserving
    // one domain slot costs 1/N pure-recovery throughput but keeps a blackhole
    // recovery step from preventing a newly submitted independent interaction.
    private static let interactiveFirstAttemptWindow: TimeInterval = 60
    private var running = false
    private var stopped = false
    private var failure: (any Error)?

    public init(store: GRDBV2LocalSyncStore, handlers: [Handler], maximumInFlight: Int = 6,
                ownerID: UUID = UUID(), now: @escaping @Sendable () -> Date = Date.init, diagnostics: V2NetworkDiagnostics? = nil) {
        precondition((1...32).contains(maximumInFlight))
        precondition(Set(handlers.map(\.kind)).count == handlers.count)
        self.store = store; self.handlers = Dictionary(uniqueKeysWithValues: handlers.map { ($0.kind, $0) })
        self.maximumInFlight = maximumInFlight; self.ownerID = ownerID; self.now = now; self.diagnostics = diagnostics
    }

    public func wake() { events.continuation.yield(()) }

    /// Call only after the previous owner has drained. Cancellation stops and
    /// awaits every physical domain step before this owner relinquishes claims.
    public func run() async throws {
        guard !running, !stopped else { throw V2OperationWorkError.invalidTransition }
        running = true
        let schedule = store.operationWorkRetrySchedule(kinds: Set(handlers.keys))
        let changes = await schedule.updates()
        let observer = Task { [weak self] in
            do {
                for try await _ in changes { await self?.wake() }
            } catch { await self?.recordFailure(error) }
        }
        var timer: Task<Void, Never>?
        do {
            try await store.recoverOperationClaims(forNewOwner: ownerID, now: now())
            wake()
            var iterator = events.stream.makeAsyncIterator()
            while let _ = await iterator.next() {
                try Task.checkCancellation()
                if let failure { throw failure }
                timer?.cancel(); timer = nil
                // Indexed, bounded maintenance shares the existing wake; it does
                // not create a periodic full-queue scan or touch unresolved work.
                let removed = try await store.pruneCompletedOperationHistory(now: now())
                try await launchReadySteps()
                if removed == 32 { wake(); await Task.yield() }
                let recoveryLimit = max(1, maximumInFlight - 1)
                let due = recoveryFlights.count >= recoveryLimit && maximumInFlight > 1
                    ? try await store.nextInteractiveOperationAttemptAt(kinds: Set(handlers.keys), since: now().addingTimeInterval(-Self.interactiveFirstAttemptWindow))
                    : try await schedule.nextAttemptAt()
                if flights.count < maximumInFlight, let due {
                    let delay = min(60, max(0.001, due.timeIntervalSince(now())))
                    timer = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(delay)); await self?.wake() } catch { }
                    }
                }
            }
            try Task.checkCancellation()
        } catch {
            observer.cancel(); timer?.cancel()
            await stopAndDrain()
            throw error
        }
        observer.cancel(); timer?.cancel()
        await stopAndDrain()
    }

    public func stopAndDrain() async {
        stopped = true
        events.continuation.finish()
        let pending = Array(flights.values)
        for task in pending { task.cancel() }
        for task in pending { await task.value }
        flights.removeAll()
        recoveryFlights.removeAll()
        running = false
    }

    private func launchReadySteps() async throws {
        guard !stopped else { return }
        let room = maximumInFlight - flights.count
        guard room > 0 else { return }
        let timestamp = now()
        let recent = timestamp.addingTimeInterval(-Self.interactiveFirstAttemptWindow)
        let recoveryRoom = min(room, max(0, max(1, maximumInFlight - 1) - recoveryFlights.count))
        // Both SQL result sets together are bounded by 32, including the
        // maximum configured concurrency. Leave recovery representation in the
        // candidate batch so the persistent wheel can advance even under a
        // continuous stream of first attempts. Small/default batches are unchanged.
        let recoveryCandidateBudget = min(recoveryRoom, room > 16 ? max(1, room / 4) : recoveryRoom)
        let interactiveCandidateBudget = min(room, 32 - recoveryCandidateBudget)
        var interactive = try await store.dueOperationWork(now: timestamp, limit: interactiveCandidateBudget,
            kinds: Set(handlers.keys), firstAttemptSince: recent)
        var recovery = recoveryCandidateBudget > 0 ? try await store.dueOperationWork(now: timestamp, limit: recoveryCandidateBudget,
            kinds: Set(handlers.keys), excludingFirstAttemptsSince: recent) : []
        var candidates: [(work: V2OperationWork, interactive: Bool)] = []
        while candidates.count < room && (!interactive.isEmpty || !recovery.isEmpty) {
            let preferInteractive = admissionWheel[admissionCursor]
            admissionCursor = (admissionCursor + 1) % admissionWheel.count
            if !interactive.isEmpty && (preferInteractive || recovery.isEmpty) {
                candidates.append((interactive.removeFirst(), true))
            } else if !recovery.isEmpty { candidates.append((recovery.removeFirst(), false)) }
        }
        let candidatesObserved = ContinuousClock.now
        for candidate in candidates {
            let work = candidate.work
            try Task.checkCancellation()
            guard !stopped, let handler = handlers[work.identity.kind] else { return }
            // A conservative write-ahead claim precedes any domain I/O. A crash
            // during subsequent permit acquisition therefore reconciles safely.
            let action = work.nextAction
            let result = try await store.claimOperationWork(id: work.id, ownerID: ownerID, action: action, now: now())
            guard case .claimed(let claim) = result else { continue }
            if stopped || Task.isCancelled {
                try await store.deferOperationWork(claim, until: now(), code: "OWNER_CANCELLED")
                throw CancellationError()
            }
            if !candidate.interactive { recoveryFlights.insert(work.id) }
            let isInteractive = candidate.interactive
            flights[work.id] = Task { [weak self, store, now, diagnostics] in
                let handlerStart = ContinuousClock.now
                var handlerEnd: ContinuousClock.Instant?
                var completion = V2OperationStepMetric.Completion.returned
                var observed: V2OperationWork?
                let priority: V2NetworkWorkPriority = isInteractive ? .interactive : .recovery
                do {
                    try Task.checkCancellation()
                    try await V2NetworkWorkScope.$context.withValue(.init(
                        service: "durableOperations", priority: priority,
                        orderingKey: claim.work.orderingKey,
                        isRetry: claim.work.attemptCount > 1 && claim.work.lastErrorCode != nil
                    )) {
                        try await handler.execute(claim)
                    }
                    handlerEnd = .now
                    // Returning without changing the durable claim is an adapter
                    // defect, not grounds to spin or immediately re-execute.
                    observed = try await store.operationWork(id: work.id)
                    if let current = observed, current.scheduling == .claimed,
                       current.revision == claim.work.revision {
                        try await store.deferOperationWork(claim, until: now(), code: "STEP_DID_NOT_SETTLE", scheduling: .needsAttention)
                        observed = try await store.operationWork(id: work.id)
                    }
                } catch {
                    handlerEnd = handlerEnd ?? .now
                    completion = error is CancellationError ? .cancelled : .threw
                    observed = nil
                    do {
                        try await store.deferOperationWork(claim, until: now(),
                            code: error is CancellationError ? "OWNER_CANCELLED" : "STEP_FAILED",
                            scheduling: error is CancellationError ? .backingOff : .needsAttention)
                        observed = try await store.operationWork(id: work.id)
                    } catch { await self?.recordFailure(error) }
                }
                let queued = candidatesObserved.duration(to: handlerStart).components
                let elapsed = handlerStart.duration(to: handlerEnd ?? .now).components
                diagnostics?.record(.init(kind: claim.work.identity.kind, action: claim.action,
                    attempt: claim.work.attemptCount, priority: priority,
                    candidateWait: Double(queued.seconds) + Double(queued.attoseconds) / 1e18,
                    handlerElapsed: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                    completion: completion, execution: observed?.execution, scheduling: observed?.scheduling))
                await self?.didFinish(work.id)
            }
        }
    }
    private func didFinish(_ id: UUID) { flights[id] = nil; recoveryFlights.remove(id); wake() }
    private func recordFailure(_ error: any Error) { failure = error; wake() }
}
