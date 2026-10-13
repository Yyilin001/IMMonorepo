import IMV2ServerContracts
import IMV2ServerApplication
import Foundation
import NIOCore
import Synchronization

public enum V2PhysicalDatabaseLoanClass: String, CaseIterable, Sendable { case ordinary, sync, activation, renewal }
public enum V2PhysicalDatabaseLoanFailure: Error, Equatable, Sendable, V2SafeOperationalErrorCodeProviding {
    case invalidPolicy, queueFull, timedOut, cancelled, closed
    public var safeOperationalErrorCode: V2SafeOperationalErrorCode {
        switch self {
        case .invalidPolicy: .databaseLoanInvalidPolicy
        case .queueFull: .databaseLoanQueueFull
        case .timedOut: .databaseLoanTimedOut
        case .cancelled: .databaseLoanCancelled
        case .closed: .databaseLoanClosed
        }
    }
}
public struct V2PhysicalDatabaseLoanPolicy: Sendable {
    public let maximumConnections: Int
    public let reservedRenewalConnections: Int
    /// Idle renewal slots may serve ordinary work; queued renewals get the next return.
    public let lendsIdleRenewalConnections: Bool
    /// Cold lifecycle work shares ordinary capacity and has its own smaller ceiling.
    public let maximumActivationConnections: Int
    public let maximumQueued: Int
    public let maximumWait: Duration
    public init(maximumConnections: Int, reservedRenewalConnections: Int, maximumQueued: Int,
                maximumWait: Duration, maximumActivationConnections: Int? = nil,
                lendsIdleRenewalConnections: Bool = false) throws {
        guard maximumConnections > 0, reservedRenewalConnections >= 0,
              reservedRenewalConnections < maximumConnections, maximumQueued >= 0,
              maximumWait > .zero else { throw V2PhysicalDatabaseLoanFailure.invalidPolicy }
        let ordinaryLimit = maximumConnections - reservedRenewalConnections
        let activationLimit = maximumActivationConnections ?? min(2, ordinaryLimit)
        guard activationLimit > 0, activationLimit <= ordinaryLimit else {
            throw V2PhysicalDatabaseLoanFailure.invalidPolicy
        }
        self.maximumActivationConnections = activationLimit
        self.maximumConnections = maximumConnections
        self.reservedRenewalConnections = reservedRenewalConnections
        self.lendsIdleRenewalConnections = lendsIdleRenewalConnections
        self.maximumQueued = maximumQueued
        self.maximumWait = maximumWait
    }
}
public struct V2PhysicalDatabaseLoanClassSnapshot: Equatable, Sendable {
    public var inFlight = 0
    public var queued = 0
    public var granted: UInt64 = 0
    public var rejected: UInt64 = 0
    public init() {}
}
public struct V2PhysicalDatabaseLoanMetricsSnapshot: Equatable, Sendable {
    public var observations = Dictionary(uniqueKeysWithValues: V2DatabaseLoanSource.allCases.map {
        ($0, V2DatabaseLoanSourceSnapshot())
    })
    public var classes = Dictionary(uniqueKeysWithValues: V2PhysicalDatabaseLoanClass.allCases.map {
        ($0, V2PhysicalDatabaseLoanClassSnapshot())
    })
    public init() {}
}

/// Immutable timestamps carried by the winning loan. No Future callback or
/// scheduling hop is added for diagnosis; losing peer grants are not counted.
package struct V2PhysicalDatabaseLoanTiming: Sendable {
    let requestedAt: ContinuousClock.Instant
    let lockRequestedAt: ContinuousClock.Instant
    let lockEnteredAt: ContinuousClock.Instant
    let admittedAt: ContinuousClock.Instant
    let grantedAt: ContinuousClock.Instant
    let promiseSubmittedAt: ContinuousClock.Instant
    let wasQueued: Bool
    let grantedOnEventLoop: Bool
}

public final class V2PhysicalDatabaseLoanLease: Sendable {
    public let deadline: ContinuousClock.Instant
    public let observation: V2DatabaseLoanObservation
    package let timing: V2PhysicalDatabaseLoanTiming?
    private let released = Mutex(false)
    private let completion: @Sendable () -> Void
    fileprivate init(deadline: ContinuousClock.Instant, observation: V2DatabaseLoanObservation,
                     timing: V2PhysicalDatabaseLoanTiming? = nil, completion: @escaping @Sendable () -> Void) {
        self.deadline = deadline; self.observation = observation; self.timing = timing; self.completion = completion
    }
    public func release() {
        let shouldRelease = released.withLock { value in
            guard !value else { return false }; value = true; return true
        }
        if shouldRelease { completion() }
    }
}
public struct V2PhysicalDatabaseLoanRequest: Sendable {
    public let future: EventLoopFuture<V2PhysicalDatabaseLoanLease>
    package let immediateFailure: V2PhysicalDatabaseLoanFailure?
    private let immediateDelivery: ImmediateDelivery?
    private let cancellation: @Sendable () -> Void
    private let transferCancellation: @Sendable () -> Void
    fileprivate init(future: EventLoopFuture<V2PhysicalDatabaseLoanLease>, cancellation: @escaping @Sendable () -> Void, transferCancellation: (@Sendable () -> Void)? = nil, immediateFailure: V2PhysicalDatabaseLoanFailure? = nil, immediateDelivery: ImmediateDelivery? = nil) {
        self.immediateDelivery = immediateDelivery
        self.future = future; self.cancellation = cancellation
        self.transferCancellation = transferCancellation ?? cancellation
        self.immediateFailure = immediateFailure
    }
    /// Registers after borrower state is installed. Immediate grants combine
    /// Promise completion and delivery in one job on the actual pool loop.
    package func whenComplete(_ callback: @escaping @Sendable (Result<V2PhysicalDatabaseLoanLease, any Error>) -> Void) {
        if let immediateDelivery { immediateDelivery.register(callback) }
        else { future.whenComplete(callback) }
    }
    fileprivate final class ImmediateDelivery: Sendable {
        let eventLoop: any EventLoop
        let promise: EventLoopPromise<V2PhysicalDatabaseLoanLease>
        let lease: V2PhysicalDatabaseLoanLease
        private let registered = Mutex(false)
        init(eventLoop: any EventLoop, promise: EventLoopPromise<V2PhysicalDatabaseLoanLease>, lease: V2PhysicalDatabaseLoanLease) {
            self.eventLoop = eventLoop; self.promise = promise; self.lease = lease
        }
        func register(_ callback: @escaping @Sendable (Result<V2PhysicalDatabaseLoanLease, any Error>) -> Void) {
            let first = registered.withLock { value in
                if value { return false }; value = true; return true
            }
            guard first else { promise.futureResult.whenComplete(callback); return }
            // Always enqueue: selection may still have a borrower lock on its
            // stack. Neither completion nor a lease return may re-enter it.
            eventLoop.execute { [self] in
                promise.succeed(lease)
                callback(.success(lease))
            }
        }
    }
    /// Cancels only a queued request. An already granted loan belongs to its actual operation.
    public func cancel() { cancellation() }
    package func cancelForTransfer() { transferCancellation() }
}

/// One gate per actual EventLoop pool. No pool URL or logical owner enters its state.
public final class V2PhysicalDatabaseLoanGate: Sendable {
    private struct Waiter: Sendable {
        let id: UUID
        let loanClass: V2PhysicalDatabaseLoanClass
        let deadline: ContinuousClock.Instant
        let promise: EventLoopPromise<V2PhysicalDatabaseLoanLease>
        let observation: V2DatabaseLoanObservation
        let admissionTiming: AdmissionTiming?
    }
    private struct AdmissionTiming: Sendable {
        let requestedAt: ContinuousClock.Instant
        let lockRequestedAt: ContinuousClock.Instant
        let lockEnteredAt: ContinuousClock.Instant
        let admittedAt: ContinuousClock.Instant
        let wasQueued: Bool
    }
    private struct State: Sendable {
        var metrics = V2PhysicalDatabaseLoanMetricsSnapshot()
        var queue: [Waiter] = []
        var nextSync = true
        var closed = false
        var drains: [CheckedContinuation<Void, Never>] = []
    }
    private let observations = V2DatabaseLoanObservationRegistry()
    private let state = Mutex(State())
    private final class CapacityObserver: Sendable {
        let notify: @Sendable () -> Void
        init(_ notify: @escaping @Sendable () -> Void) { self.notify = notify }
    }
    // Keep the callback in an immutable reference. Repeatedly extracting a
    // Sendable function through Mutex's sending result can accumulate function
    // reabstraction thunks in optimized builds; the reference has no such ABI
    // conversion and notification remains outside the gate lock.
    private let capacityObserver = Mutex<CapacityObserver?>(nil)
    package func observeCapacityReturns(_ observer: @escaping @Sendable () -> Void) {
        capacityObserver.withLock { $0 = CapacityObserver(observer) }
    }
    private let eventLoop: any EventLoop
    private let policy: V2PhysicalDatabaseLoanPolicy
    package var maximumWait: Duration { policy.maximumWait }
    package var ordinaryConnectionCapacity: Int { policy.maximumConnections - policy.reservedRenewalConnections }
    public init(eventLoop: any EventLoop, policy: V2PhysicalDatabaseLoanPolicy) {
        self.eventLoop = eventLoop; self.policy = policy
    }
    public func acquire(loanClass: V2PhysicalDatabaseLoanClass,
                        deadline: ContinuousClock.Instant? = nil) -> EventLoopFuture<V2PhysicalDatabaseLoanLease> {
        request(loanClass: loanClass, deadline: deadline).future
    }
    public func request(loanClass: V2PhysicalDatabaseLoanClass,
                        deadline: ContinuousClock.Instant? = nil,
                        diagnoseAcquisition: Bool = false) -> V2PhysicalDatabaseLoanRequest {
        let startedAt = ContinuousClock.now
        let source = V2DatabaseLoanObservationContext.source
        let limit = startedAt + policy.maximumWait
        let selectedDeadline = deadline.map { min($0, limit) } ?? limit
        let id = UUID(), promise = eventLoop.makePromise(of: V2PhysicalDatabaseLoanLease.self)
        enum Admission { case granted(Waiter, ContinuousClock.Instant), queued(Waiter), rejected(V2PhysicalDatabaseLoanFailure) }
        let lockRequestedAt = diagnoseAcquisition ? ContinuousClock.now : nil
        let admission: Admission = state.withLock { value in
            let lockEnteredAt = diagnoseAcquisition ? ContinuousClock.now : nil
            let failure: V2PhysicalDatabaseLoanFailure?
            let immediate = canGrantImmediately(loanClass, value)
            if value.closed { failure = .closed }
            else if selectedDeadline <= .now { failure = .timedOut }
            else if !immediate && value.queue.count >= policy.maximumQueued { failure = .queueFull }
            else { failure = nil }
            if let failure {
                reject(loanClass, &value)
                return .rejected(failure)
            }
            // Only admitted bounded requests obtain live observation tickets.
            // This registry never acquires the gate mutex in the reverse order.
            let waiter = Waiter(id: id, loanClass: loanClass, deadline: selectedDeadline, promise: promise,
                                observation: observations.make(source: source, at: startedAt),
                admissionTiming: lockEnteredAt.map { .init(requestedAt: startedAt,
                    lockRequestedAt: lockRequestedAt ?? startedAt, lockEnteredAt: $0, admittedAt: .now, wasQueued: !immediate) })
            if immediate {
                grant(loanClass, &value)
                return .granted(waiter, .now)
            }
            value.queue.append(waiter)
            value.metrics.classes[loanClass, default: .init()].queued += 1
            return .queued(waiter)
        }
        switch admission {
        case .granted(let waiter, let at): succeed(waiter, at: at)
        case .rejected(let failure):
            observations.rejected(source: source, startedAt: startedAt)
            promise.fail(failure)
        case .queued(let waiter):
            let duration = ContinuousClock.now.duration(to: waiter.deadline).components
            let nanoseconds = max(0, Double(duration.seconds) * 1e9 + Double(duration.attoseconds) / 1e9)
            let scheduled = eventLoop.scheduleTask(in: .nanoseconds(Int64(min(nanoseconds, Double(Int64.max - 1024))))) { [self] in
                remove(waiter.id, failure: .timedOut)
            }
            waiter.promise.futureResult.whenComplete { _ in scheduled.cancel() }
            pump()
        }
        let immediateFailure: V2PhysicalDatabaseLoanFailure?
        if case .rejected(let failure) = admission { immediateFailure = failure } else { immediateFailure = nil }
        return .init(future: promise.futureResult, cancellation: { [self] in remove(id, failure: .cancelled) },
            transferCancellation: { [self] in remove(id, failure: .cancelled, recordRejection: false) },
            immediateFailure: immediateFailure)
    }
    /// Atomically claims existing capacity without registering a waiter.
    /// Used when selecting among this database's EventLoop pools; a failed
    /// candidate probe consumes neither a ticket nor a rejection counter.
    package func requestIfAvailable(loanClass: V2PhysicalDatabaseLoanClass,
        deadline: ContinuousClock.Instant? = nil,
        diagnoseAcquisition: Bool = false, combineImmediateDelivery: Bool = false) -> V2PhysicalDatabaseLoanRequest? {
        let startedAt = ContinuousClock.now
        let selectedDeadline = min(deadline ?? startedAt + policy.maximumWait, startedAt + policy.maximumWait)
        let source = V2DatabaseLoanObservationContext.source
        let lockRequestedAt = diagnoseAcquisition ? ContinuousClock.now : nil
        let admitted = state.withLock { value -> (Waiter, ContinuousClock.Instant)? in
            let lockEnteredAt = diagnoseAcquisition ? ContinuousClock.now : nil
            guard !value.closed, selectedDeadline > .now, canGrantImmediately(loanClass, value) else { return nil }
            let waiter = Waiter(id: UUID(), loanClass: loanClass, deadline: selectedDeadline,
                promise: eventLoop.makePromise(of: V2PhysicalDatabaseLoanLease.self),
                observation: observations.make(source: source, at: startedAt),
                admissionTiming: lockEnteredAt.map { .init(requestedAt: startedAt,
                    lockRequestedAt: lockRequestedAt ?? startedAt, lockEnteredAt: $0, admittedAt: .now, wasQueued: false) })
            grant(loanClass, &value)
            return (waiter, .now)
        }
        guard let (waiter, grantedAt) = admitted else { return nil }
        if combineImmediateDelivery {
            let lease = makeLease(waiter, at: grantedAt)
            return .init(future: waiter.promise.futureResult, cancellation: {},
                immediateDelivery: .init(eventLoop: eventLoop, promise: waiter.promise, lease: lease))
        }
        succeed(waiter, at: grantedAt)
        return .init(future: waiter.promise.futureResult, cancellation: {})
    }

    private func canGrantImmediately(_ loanClass: V2PhysicalDatabaseLoanClass, _ value: State) -> Bool {
        let queuedCompetitor = value.queue.contains { waiter in
            if loanClass == .renewal { return waiter.loanClass == .renewal }
            return waiter.loanClass != .renewal && canGrant(waiter.loanClass, value)
        }
        return !queuedCompetitor && !value.queue.contains(where: { $0.loanClass == loanClass })
            && canGrant(loanClass, value)
    }

    public func snapshot() -> V2PhysicalDatabaseLoanMetricsSnapshot {
        var result = state.withLock { $0.metrics }
        result.observations = observations.snapshot()
        return result
    }
    public func shutdown() async {
        let queued = state.withLock { value in
            value.closed = true
            let queued = value.queue; value.queue.removeAll()
            for waiter in queued {
                value.metrics.classes[waiter.loanClass, default: .init()].queued -= 1
                reject(waiter.loanClass, &value)
            }
            return queued
        }
        for waiter in queued { waiter.observation.finish(); waiter.promise.fail(V2PhysicalDatabaseLoanFailure.closed) }
        await withCheckedContinuation { continuation in
            let complete = state.withLock { value in
                guard totalInFlight(value) != 0 else { return true }
                value.drains.append(continuation); return false
            }
            if complete { continuation.resume() }
        }
    }
    private func totalInFlight(_ value: State) -> Int {
        value.metrics.classes.values.reduce(0) { $0 + $1.inFlight }
    }
    private func canGrant(_ loanClass: V2PhysicalDatabaseLoanClass, _ value: State) -> Bool {
        guard totalInFlight(value) < policy.maximumConnections else { return false }
        if loanClass == .renewal {
            let limit = policy.reservedRenewalConnections == 0
                ? policy.maximumConnections : policy.reservedRenewalConnections
            return value.metrics.classes[.renewal, default: .init()].inFlight < limit
        }
        let ordinary = value.metrics.classes[.ordinary, default: .init()].inFlight
        let activation = value.metrics.classes[.activation, default: .init()].inFlight
        let sync = value.metrics.classes[.sync, default: .init()].inFlight
        let renewalWaiting = value.metrics.classes[.renewal, default: .init()].queued > 0
        let ordinaryLimit = policy.lendsIdleRenewalConnections && !renewalWaiting
            ? policy.maximumConnections : policy.maximumConnections - policy.reservedRenewalConnections
        guard ordinary + activation + sync < ordinaryLimit else {
            return false
        }
        return loanClass != .activation || activation < policy.maximumActivationConnections
    }
    private func grant(_ loanClass: V2PhysicalDatabaseLoanClass, _ value: inout State) {
        value.metrics.classes[loanClass, default: .init()].inFlight += 1
        if loanClass != .renewal { value.nextSync = loanClass != .sync }
        let old = value.metrics.classes[loanClass, default: .init()].granted
        value.metrics.classes[loanClass, default: .init()].granted = old == .max ? old : old + 1
    }
    private func reject(_ loanClass: V2PhysicalDatabaseLoanClass, _ value: inout State) {
        let old = value.metrics.classes[loanClass, default: .init()].rejected
        value.metrics.classes[loanClass, default: .init()].rejected = old == .max ? old : old + 1
    }
    private func succeed(_ waiter: Waiter, at: ContinuousClock.Instant) {
        waiter.promise.succeed(makeLease(waiter, at: at))
    }
    private func makeLease(_ waiter: Waiter, at: ContinuousClock.Instant) -> V2PhysicalDatabaseLoanLease {
        waiter.observation.granted(at: at)
        let timing = waiter.admissionTiming.map { admission in
            V2PhysicalDatabaseLoanTiming(requestedAt: admission.requestedAt,
                lockRequestedAt: admission.lockRequestedAt, lockEnteredAt: admission.lockEnteredAt, admittedAt: admission.admittedAt,
                grantedAt: at, promiseSubmittedAt: .now, wasQueued: admission.wasQueued,
                grantedOnEventLoop: eventLoop.inEventLoop)
        }
        return .init(deadline: waiter.deadline, observation: waiter.observation, timing: timing, completion: { [self] in
            waiter.observation.finish()
            release(waiter.loanClass)
        })
    }
    private func remove(_ id: UUID, failure: V2PhysicalDatabaseLoanFailure, recordRejection: Bool = true) {
        let removed = state.withLock { value -> Waiter? in
            guard let index = value.queue.firstIndex(where: { $0.id == id }) else { return nil }
            let waiter = value.queue.remove(at: index)
            value.metrics.classes[waiter.loanClass, default: .init()].queued -= 1
            if recordRejection { reject(waiter.loanClass, &value) }
            return waiter
        }
        removed?.observation.finish()
        removed?.promise.fail(failure)
        pump()
        capacityObserver.withLock { $0 }?.notify()
    }
    private func release(_ loanClass: V2PhysicalDatabaseLoanClass) {
        state.withLock {
            precondition($0.metrics.classes[loanClass, default: .init()].inFlight > 0)
            $0.metrics.classes[loanClass, default: .init()].inFlight -= 1
        }
        pump()
        // Gate and observation mutexes are released before notifying the
        // physical-pool coordinator; its selection may re-enter any gate.
        capacityObserver.withLock { $0 }?.notify()
    }
    private func pump() {
        var grants: [(Waiter, ContinuousClock.Instant)] = [], expired: [Waiter] = [], drains: [CheckedContinuation<Void, Never>] = []
        state.withLock { value in
            // Expiry is independent of capacity and of the preferred purpose.
            var live: [Waiter] = []
            for waiter in value.queue {
                if waiter.deadline <= .now {
                    value.metrics.classes[waiter.loanClass, default: .init()].queued -= 1
                    reject(waiter.loanClass, &value); expired.append(waiter)
                } else { live.append(waiter) }
            }
            value.queue = live
            while !value.closed {
                // Renewal retains its existing separate capacity. General and
                // Sync share the original ordinary capacity, alternating only
                // when both have eligible heads. A capped activation head cannot
                // obstruct an ordinary head; each class retains FIFO.
                let renewal = value.queue.firstIndex { $0.loanClass == .renewal && canGrant(.renewal, value) }
                let sync = value.queue.firstIndex { $0.loanClass == .sync && canGrant(.sync, value) }
                let general = value.queue.firstIndex {
                    $0.loanClass != .sync && $0.loanClass != .renewal && canGrant($0.loanClass, value)
                }
                let family = value.nextSync ? (sync ?? general) : (general ?? sync)
                let index: Int?
                if policy.lendsIdleRenewalConnections, let renewal { index = renewal }
                else if let renewal, let family { index = min(renewal, family) }
                else { index = renewal ?? family }
                guard let index else { break }
                let waiter = value.queue.remove(at: index)
                value.metrics.classes[waiter.loanClass, default: .init()].queued -= 1
                grant(waiter.loanClass, &value); grants.append((waiter, .now))
            }
            if value.closed, totalInFlight(value) == 0 { drains = value.drains; value.drains.removeAll() }
        }
        for waiter in expired { waiter.observation.finish(); waiter.promise.fail(V2PhysicalDatabaseLoanFailure.timedOut) }
        for (waiter, at) in grants { succeed(waiter, at: at) }
        for continuation in drains { continuation.resume() }
    }
}
