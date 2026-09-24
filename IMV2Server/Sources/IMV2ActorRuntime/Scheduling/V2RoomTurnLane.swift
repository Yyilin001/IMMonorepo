import Foundation
import IMV2ActorContracts

/// Only contiguous send requests may share a turn. Every other capability is a
/// barrier, including reads: an await in a handler never admits a second turn.
public enum V2RoomTurnSchedulingClass: Sendable {
    case send
    case barrier
}

/// Local, runtime-created execution authority. It is never decoded from RPC.
public struct V2RoomTurnContext: Sendable {
    public let token: V2RoomActivationToken
    public let turnID: UUID
    /// A shared database batcher consumes the remaining part of this budget;
    /// it must not begin another independent batching delay.
    public let batchDeadline: ContinuousClock.Instant
}

public struct V2RoomTurnItem<Request: Sendable>: Sendable {
    public let ordinal: UInt64
    public let request: Request
    public let deadline: ContinuousClock.Instant
}

public struct V2RoomTurn<Request: Sendable>: Sendable {
    public let context: V2RoomTurnContext
    public let items: [V2RoomTurnItem<Request>]
}

public struct V2RoomTurnLaneSnapshot: Sendable {
    public let phase: V2RoomActivationPhase
    public let queuedCount: Int
    public let executingCount: Int
    public let unresolvedCount: Int
    public let hasReservation: Bool
    public let lastActivity: ContinuousClock.Instant
    public var isIdle: Bool { queuedCount == 0 && executingCount == 0 && unresolvedCount == 0 && !hasReservation }
}

/// This scheduler is generic over a closed, typed request family; it does not
/// dispatch method names or accept an arbitrary payload bag. Decode always uses
/// the exact immutable bytes charged to the host's admission budget.
public actor V2RoomTurnLane<Request: Decodable & Sendable, Response: Sendable> {
    public typealias Execute = @Sendable (V2RoomTurn<Request>) async -> V2RoomTransactionCompletion<[Response]>

    public let token: V2RoomActivationToken
    private let configuration: V2RoomRuntimeConfiguration
    private let budget: V2RoomCommandBudget
    private let classify: @Sendable (Request) -> V2RoomTurnSchedulingClass
    private let execute: Execute
    private let onUncertain: @Sendable (V2RoomActivationToken) async -> Void
    private let clock = ContinuousClock()
    private var phase: V2RoomActivationPhase = .ready
    private var nextOrdinal: UInt64 = 0
    private var queue: [Entry] = []
    private var executing: [Entry] = []
    private var unresolved: [V2RoomCommandPermit] = []
    private var reservation: HeldReservation?
    private var consumer: Task<Void, Never>?
    private var lastActivity: ContinuousClock.Instant

    public init(
        token: V2RoomActivationToken,
        configuration: V2RoomRuntimeConfiguration,
        budget: V2RoomCommandBudget,
        classify: @escaping @Sendable (Request) -> V2RoomTurnSchedulingClass,
        execute: @escaping Execute,
        onUncertain: @escaping @Sendable (V2RoomActivationToken) async -> Void
    ) {
        self.token = token
        self.configuration = configuration
        self.budget = budget
        self.classify = classify
        self.execute = execute
        self.onUncertain = onUncertain
        self.lastActivity = ContinuousClock.now
    }

    public func submit(
        encodedRequest: Data,
        deadline: ContinuousClock.Instant
    ) async throws -> Response {
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            guard phase == .ready else { throw rejection() }
            guard !Task.isCancelled else { throw V2RoomCallFailure.notAccepted(.cancelled) }
            guard clock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
            let permit = try await budget.acquire(roomID: token.roomID, encodedRequest: encodedRequest)
            // Admission awaited another actor. Recheck every local condition.
            guard phase == .ready, !Task.isCancelled, clock.now < deadline else {
                let failure = phase != .ready ? rejection() : V2RoomCallFailure.notAccepted(
                    Task.isCancelled ? .cancelled : .deadlineExceeded
                )
                await budget.release(permit)
                throw failure
            }
            let request: Request
            do { request = try JSONDecoder().decode(Request.self, from: permit.encodedRequest) }
            catch {
                await budget.release(permit)
                throw V2RoomCallFailure.notAccepted(.invalidRequest)
            }
            guard nextOrdinal < UInt64.max else {
                await budget.release(permit)
                throw V2RoomCallFailure.notAccepted(.overloaded)
            }
            nextOrdinal += 1
            let ordinal = nextOrdinal
            let admittedAt = clock.now
            return try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) }
                    catch { return }
                    await self?.withdraw(requestID, reason: .deadlineExceeded)
                }
                queue.append(Entry(
                    id: requestID, permit: permit, request: request, ordinal: ordinal,
                    admittedAt: admittedAt, deadline: deadline, continuation: continuation,
                    reservationGrant: nil, reservationContinuation: nil, timer: timer
                ))
                lastActivity = admittedAt
                startConsumerIfNeeded()
            }
        } onCancel: {
            Task { await self.withdraw(requestID, reason: .cancelled) }
        }
    }

    /// Atomically closes admission. Already accepted requests keep their place
    /// and lease until completion; the hosting lifecycle owns the drain deadline.
    public func beginDrain() {
        if phase == .ready { phase = .draining }
    }

    /// Enqueues a barrier from a coordinator running outside ordinary turns.
    /// The deadline covers both waiting and holding; a granted expiry never
    /// silently unlocks the same activation for subsequent commands.
    public func reserve(requestID: UUID, deadline: ContinuousClock.Instant) async throws -> V2RoomReservation {
        let grant = V2RoomReservation(token: token, requestID: requestID, reservationID: UUID())
        return try await withTaskCancellationHandler {
            guard phase == .ready else { throw rejection() }
            guard !Task.isCancelled else { throw V2RoomCallFailure.notAccepted(.cancelled) }
            let boundedDeadline = min(deadline, clock.now + configuration.reservationTimeout.duration)
            guard clock.now < boundedDeadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
            let bytes = try JSONEncoder().encode(grant)
            let permit = try await budget.acquireReservation(roomID: token.roomID, encodedRequest: bytes)
            guard phase == .ready, !Task.isCancelled, clock.now < boundedDeadline, nextOrdinal < UInt64.max else {
                let failure = phase != .ready ? rejection() : V2RoomCallFailure.notAccepted(
                    Task.isCancelled ? .cancelled : .deadlineExceeded
                )
                await budget.release(permit)
                throw failure
            }
            nextOrdinal += 1
            let admittedAt = clock.now
            return try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: boundedDeadline) }
                    catch { return }
                    await self?.withdraw(grant.reservationID, reason: .deadlineExceeded)
                }
                queue.append(Entry(
                    id: grant.reservationID, permit: permit, request: nil, ordinal: nextOrdinal,
                    admittedAt: admittedAt, deadline: boundedDeadline, continuation: nil,
                    reservationGrant: grant, reservationContinuation: continuation, timer: timer
                ))
                lastActivity = admittedAt
                startConsumerIfNeeded()
            }
        } onCancel: {
            Task { await self.withdraw(grant.reservationID, reason: .cancelled) }
        }
    }

    /// Required acknowledgement before dispatch. Late or forged grants fail;
    /// a caller cannot start SQL after a reservation expired or was retired.
    public func markReservationDispatched(_ grant: V2RoomReservation) throws {
        guard phase == .ready || phase == .draining,
              reservation?.entry.reservationGrant == grant,
              let held = reservation, held.entry.deadline > clock.now,
              !held.dispatched
        else { throw V2RoomCallFailure.notAccepted(.staleActivation) }
        reservation?.dispatched = true
    }

    /// A coordinator can safely abandon a grant only before dispatch. Once
    /// acknowledged, it must report a durable completion or retire both rooms.
    @discardableResult
    public func abortReservation(_ grant: V2RoomReservation) async -> Bool {
        guard let held = reservation, held.entry.reservationGrant == grant,
              !held.dispatched, phase == .ready || phase == .draining
        else { return false }
        reservation = nil
        held.entry.timer.cancel()
        lastActivity = clock.now
        await budget.release(held.entry.permit)
        startConsumerIfNeeded()
        return true
    }

    /// Hosting first updates/invalidates executor state while this barrier is
    /// still held, then completes it. External callers cannot skip that step.
    @discardableResult
    func finishReservation(_ grant: V2RoomReservation, completion: V2RoomReservationCompletion) async -> Bool {
        guard let held = reservation, held.entry.reservationGrant == grant,
              held.dispatched, phase == .ready || phase == .draining
        else { return false }
        held.entry.timer.cancel()
        reservation = nil
        lastActivity = clock.now
        if completion == .outcomeUnknown {
            phase = .uncertain
            unresolved.append(held.entry.permit)
            await rejectQueued(reason: .leaseLost)
            await onUncertain(token)
        } else {
            await budget.release(held.entry.permit)
            startConsumerIfNeeded()
        }
        return true
    }

    public func snapshot() -> V2RoomTurnLaneSnapshot {
        .init(
            phase: phase, queuedCount: queue.count, executingCount: executing.count,
            unresolvedCount: unresolved.count, hasReservation: reservation != nil,
            lastActivity: lastActivity
        )
    }

    /// Lease loss closes admission independently of the business consumer. An
    /// already dispatched transaction retains its completion and charged permit.
    public func loseLease() async {
        guard phase != .stopped, phase != .uncertain else { return }
        phase = .uncertain
        quarantineReservation()
        await rejectQueued(reason: .leaseLost)
        await onUncertain(token)
    }

    /// Only Hosting may call this after the old token is fenced out in the DB
    /// and its executor has stopped. Never frees an executing transaction.
    func completeRetirement() async -> Bool {
        guard executing.isEmpty else { return false }
        phase = .stopped
        consumer?.cancel()
        quarantineReservation()
        await rejectQueued(reason: .retired)
        let permits = unresolved
        unresolved.removeAll()
        for permit in permits { await budget.release(permit) }
        return true
    }

    private func rejection() -> V2RoomCallFailure {
        .notAccepted(phase == .uncertain ? .leaseLost : .retired)
    }

    private func startConsumerIfNeeded() {
        guard consumer == nil, reservation == nil, !queue.isEmpty,
              phase == .ready || phase == .draining else { return }
        consumer = Task { await self.consume() }
    }

    private func consume() async {
        while phase == .ready || phase == .draining {
            guard !queue.isEmpty else { break }
            // Grant already queued contiguous sends immediately. The shared
            // physical-owner batcher owns the only collection delay, bounded
            // by the first request's original admission time. Sleeping here
            // first would consume that window before other rooms can join it.
            guard phase == .ready || phase == .draining else { break }
            // A timer callback may not have run yet. Do not dispatch an expired
            // request simply because the executor won the scheduling race.
            while let entry = queue.first, entry.deadline <= clock.now {
                await withdraw(entry.id, reason: .deadlineExceeded)
            }
            guard let head = queue.first else { continue }
            if let grant = head.reservationGrant {
                var entry = queue.removeFirst()
                let continuation = entry.reservationContinuation
                entry.reservationContinuation = nil
                reservation = HeldReservation(entry: entry, dispatched: false)
                continuation?.resume(returning: grant)
                break
            }
            let canBatch = isSend(head)
            var count = 1
            var bytes = head.permit.byteCount
            if canBatch {
                for entry in queue.dropFirst() {
                    guard isSend(entry),
                          entry.deadline > clock.now,
                          count < configuration.maximumCommandsPerTurn,
                          entry.permit.byteCount <= configuration.maximumBytesPerTurn - bytes
                    else { break }
                    count += 1
                    bytes += entry.permit.byteCount
                }
            }
            executing = Array(queue.prefix(count))
            queue.removeFirst(count)
            let turn = V2RoomTurn(
                context: V2RoomTurnContext(
                    token: token, turnID: UUID(),
                    batchDeadline: min(head.admittedAt + configuration.batchWait.duration, head.deadline)
                ),
                items: executing.compactMap { entry in
                    entry.request.map { .init(ordinal: entry.ordinal, request: $0, deadline: entry.deadline) }
                }
            )
            let completion = await V2RoomTurnScope.$roomID.withValue(token.roomID) {
                await execute(turn)
            }
            await finish(completion)
        }
        consumer = nil
    }

    private func finish(_ completion: V2RoomTransactionCompletion<[Response]>) async {
        let entries = executing
        executing.removeAll()
        lastActivity = clock.now
        var uncertain = false
        switch completion {
        case .committed(let values) where values.count == entries.count:
            for (entry, value) in zip(entries, values) {
                entry.timer.cancel()
                entry.continuation?.resume(returning: value)
            }
        case .rolledBack(let reason):
            for entry in entries {
                entry.timer.cancel()
                entry.continuation?.resume(throwing: V2RoomCallFailure.rolledBack(reason))
            }
            if reason == .leaseLost || reason == .staleActivation { uncertain = true }
        case .outcomeUnknown, .committed:
            // A malformed executor result cannot be aligned to callers safely.
            uncertain = true
            for entry in entries {
                entry.timer.cancel()
                entry.continuation?.resume(throwing: V2RoomCallFailure.outcomeUnknown)
            }
        }
        if uncertain {
            phase = .uncertain
            unresolved.append(contentsOf: entries.map(\.permit))
            await rejectQueued(reason: .leaseLost)
            await onUncertain(token)
        } else {
            for entry in entries { await budget.release(entry.permit) }
        }
    }

    private func withdraw(_ id: UUID, reason: V2RoomFailureReason) async {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            let entry = queue.remove(at: index)
            entry.timer.cancel()
            entry.continuation?.resume(throwing: V2RoomCallFailure.notAccepted(reason))
            entry.reservationContinuation?.resume(throwing: V2RoomCallFailure.notAccepted(reason))
            await budget.release(entry.permit)
        } else if let index = executing.firstIndex(where: { $0.id == id }) {
            // Detach the caller, not the SQL. Keep the permit and the exclusive
            // turn until the executor reports the actual transaction result.
            let continuation = executing[index].continuation
            executing[index].continuation = nil
            executing[index].timer.cancel()
            continuation?.resume(throwing: V2RoomCallFailure.outcomeUnknown)
        } else if reservation?.entry.id == id {
            // After a grant was returned, coordinator loss is conservative:
            // retire this epoch even if its dispatch acknowledgement was lost.
            phase = .uncertain
            quarantineReservation()
            await rejectQueued(reason: .leaseLost)
            await onUncertain(token)
        }
    }

    private func rejectQueued(reason: V2RoomFailureReason) async {
        let rejected = queue
        queue.removeAll()
        for entry in rejected {
            entry.timer.cancel()
            entry.continuation?.resume(throwing: V2RoomCallFailure.notAccepted(reason))
            entry.reservationContinuation?.resume(throwing: V2RoomCallFailure.notAccepted(reason))
            await budget.release(entry.permit)
        }
    }

    private func isSend(_ entry: Entry) -> Bool {
        entry.request.map { classify($0) == .send } ?? false
    }

    private func quarantineReservation() {
        guard let held = reservation else { return }
        reservation = nil
        held.entry.timer.cancel()
        unresolved.append(held.entry.permit)
    }

    private struct HeldReservation: Sendable {
        let entry: Entry
        var dispatched: Bool
    }

    private struct Entry: Sendable {
        let id: UUID
        let permit: V2RoomCommandPermit
        let request: Request?
        let ordinal: UInt64
        let admittedAt: ContinuousClock.Instant
        let deadline: ContinuousClock.Instant
        var continuation: CheckedContinuation<Response, any Error>?
        let reservationGrant: V2RoomReservation?
        var reservationContinuation: CheckedContinuation<V2RoomReservation, any Error>?
        let timer: Task<Void, Never>
    }
}
