import IMV2ServerContracts
import Foundation
import IMV2ServerApplication
import NIOCore
import Synchronization

/// Keeps the existing bounded pool waiter as the queue ticket, but lets a
/// Sendable operation borrow from a peer pool when that peer returns capacity.
/// No extra queue allowance, connection, waiting task or driver call is created.
final class V2PhysicalDatabasePoolBorrower: Sendable {
    struct Assignment: Sendable {
        let index: Int
        let lease: V2PhysicalDatabaseLoanLease
    }
    struct Request: Sendable {
        let future: EventLoopFuture<Assignment>
        let cancel: @Sendable () -> Void
    }
    private struct Pending: Sendable {
        let id: UUID
        let index: Int
        let loanClass: V2PhysicalDatabaseLoanClass
        let deadline: ContinuousClock.Instant
        let source: V2DatabaseLoanSource
        let timeline: V2OwnerConnectionTimeline?
        let original: V2PhysicalDatabaseLoanRequest
        let promise: EventLoopPromise<Assignment>
        let onAssignment: (@Sendable (Result<Assignment, any Error>) -> Void)?
        var transferring = false
    }
    private struct State: Sendable {
        var cursor = 0
        var pending = V2IndexedFIFO<UUID, Pending>()
        var closed = false
        var drains: [CheckedContinuation<Void, Never>] = []
    }
    private let gates: [V2PhysicalDatabaseLoanGate]
    private let eventLoop: any EventLoop
    private let state = Mutex(State())
    private let pumpScheduled = Mutex(false)

    init(gates: [V2PhysicalDatabaseLoanGate], eventLoop: any EventLoop) {
        precondition(!gates.isEmpty)
        self.gates = gates; self.eventLoop = eventLoop
        for gate in gates { gate.observeCapacityReturns { [weak self] in self?.schedulePump() } }
    }

    func request(loanClass: V2PhysicalDatabaseLoanClass,
        deadline: ContinuousClock.Instant?,
        onAssignment: (@Sendable (Result<Assignment, any Error>) -> Void)? = nil) -> Request {
        let id = UUID(), source = V2DatabaseLoanObservationContext.source
        let wait = gates.map(\.maximumWait).min()!
        let boundedDeadline = min(deadline ?? .now + wait, .now + wait)
        let promise = eventLoop.makePromise(of: Assignment.self)
        let timeline = V2OwnerConnectionTimeline.current
        let admission = state.withLock { value -> Result<Pending, V2PhysicalDatabaseLoanFailure> in
            guard !value.closed else { return .failure(.closed) }
            var selected: (Int, V2PhysicalDatabaseLoanRequest)?
            for offset in 0..<gates.count {
                let index = (value.cursor + offset) % gates.count
                if let request = gates[index].requestIfAvailable(loanClass: loanClass, deadline: boundedDeadline,
                    diagnoseAcquisition: timeline != nil, combineImmediateDelivery: true) {
                    selected = (index, request); break
                }
            }
            let (index, original) = selected ??
                (value.cursor, gates[value.cursor].request(loanClass: loanClass, deadline: boundedDeadline,
                    diagnoseAcquisition: timeline != nil))
            value.cursor = (index + 1) % gates.count
            if let failure = original.immediateFailure { return .failure(failure) }
            let pending = Pending(id: id, index: index, loanClass: loanClass, deadline: boundedDeadline,
                source: source, timeline: timeline,
                original: original, promise: promise, onAssignment: onAssignment, transferring: selected != nil)
            value.pending.append(pending, key: id)
            return .success(pending)
        }
        let pending: Pending
        switch admission {
        case .success(let value): pending = value
        case .failure(let failure):
            onAssignment?(.failure(failure))
            promise.fail(failure)
            return .init(future: promise.futureResult, cancel: {})
        }
        let registeredAt = ContinuousClock.now
        pending.original.whenComplete { [self] result in
            complete(id, index: pending.index, result: result, transferred: false, registeredAt: registeredAt)
        }
        // A capacity return may have raced original registration.
        schedulePump()
        return .init(future: promise.futureResult, cancel: { pending.original.cancel() })
    }

    private func schedulePump() {
        // Capacity callbacks may arrive on an SQL completion stack, including
        // while selection holds state. Coalesce them onto the facade loop:
        // peer grants must not synchronously re-enter loan completion.
        let schedule = pumpScheduled.withLock { scheduled in
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        guard schedule else { return }
        eventLoop.execute { [self] in
            pumpScheduled.withLock { $0 = false }
            pump()
        }
    }

    private func pump() {
        let transfers = state.withLock { value -> [(Pending, Int, V2PhysicalDatabaseLoanRequest)] in
            guard !value.closed, gates.count > 1 else { return [] }
            var result: [(Pending, Int, V2PhysicalDatabaseLoanRequest)] = []
            for var pending in value.pending.values where !pending.transferring {
                for offset in 0..<gates.count {
                    let index = (value.cursor + offset) % gates.count
                    guard index != pending.index else { continue }
                    let request = V2DatabaseLoanObservationContext.$source.withValue(pending.source) {
                        gates[index].requestIfAvailable(loanClass: pending.loanClass, deadline: pending.deadline,
                            diagnoseAcquisition: pending.timeline != nil, combineImmediateDelivery: true)
                    }
                    guard let request else { continue }
                    // Replacing the record in place must preserve FIFO order.
                    pending.transferring = true
                    value.pending.update(pending, key: pending.id)
                    value.cursor = (index + 1) % gates.count
                    result.append((pending, index, request))
                    break
                }
            }
            return result
        }
        for (pending, index, request) in transfers {
            let registeredAt = ContinuousClock.now
            request.whenComplete { [self] result in
                complete(pending.id, index: index, result: result, transferred: true, registeredAt: registeredAt)
            }
        }
    }

    private func complete(_ id: UUID, index: Int,
        result: Result<V2PhysicalDatabaseLoanLease, any Error>, transferred: Bool,
        registeredAt: ContinuousClock.Instant) {
        let callbackAt = ContinuousClock.now
        let (pending, drains) = state.withLock { value -> (Pending?, [CheckedContinuation<Void, Never>]) in
            let pending = value.pending.remove(id)
            let drains = value.closed && value.pending.isEmpty ? value.drains : []
            if !drains.isEmpty { value.drains.removeAll() }
            return (pending, drains)
        }
        guard let pending else {
            // Original grant and peer grant may both win their gate races.
            // Exactly one is exposed; the other's real loan is returned here.
            if case .success(let lease) = result { lease.release() }
            return
        }
        if transferred { pending.original.cancelForTransfer() }
        switch result {
        case .success(let lease):
            let now = ContinuousClock.now
            pending.timeline?.mark("pool_assignment_published", at: now)
            if let started = pending.timeline?.marker("pool_request_started") {
                pending.timeline?.record(.ownerPoolAssignmentWait, from: started, to: now)
            }
            pending.timeline?.deferAssignmentTiming(lease.timing, registeredAt: registeredAt,
                callbackAt: callbackAt, publishedAt: now, transferred: transferred)
            let assignment = Assignment(index: index, lease: lease)
            // The winning gate's callback runs on its own pool loop. Scheduled
            // Sendable work enters that pool directly, outside borrower locks.
            pending.onAssignment?(.success(assignment))
            pending.promise.succeed(assignment)
        case .failure(let error):
            pending.onAssignment?(.failure(error))
            pending.promise.fail(error)
        }
        for drain in drains { drain.resume() }
    }

    var pendingCount: Int { state.withLock { $0.pending.count } }

    func close() { state.withLock { $0.closed = true } }
    func waitUntilSettled() async {
        await withCheckedContinuation { continuation in
            let done = state.withLock { value in
                if value.pending.isEmpty { return true }
                value.drains.append(continuation); return false
            }
            if done { continuation.resume() }
        }
    }
}
