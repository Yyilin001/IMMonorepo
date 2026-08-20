import Foundation

public enum V2DatabaseWorkClass: String, CaseIterable, Sendable {
    /// Mutations that make durable state visible to clients. This lane is
    /// intentionally independent from interactive reads so a burst of room
    /// log pulls cannot consume every send permit.
    case foregroundWrite = "foreground_write"
    /// Foreground reads whose response is needed for an already-open UI, such
    /// as a room-log pull. They remain bounded so they cannot turn a delayed
    /// client into unbounded PostgreSQL work.
    case interactiveRead = "interactive_read"
    case sync
}

public enum V2DatabaseWorkAdmissionWaitBucket: Int, CaseIterable, Sendable {
    case milliseconds1 = 1
    case milliseconds5 = 5
    case milliseconds10 = 10
    case milliseconds25 = 25
    case milliseconds50 = 50
    case milliseconds100 = 100
    case milliseconds250 = 250
    case milliseconds500 = 500
    case milliseconds1_000 = 1_000
    case milliseconds5_000 = 5_000
}

public struct V2DatabaseWorkAdmissionWaitSnapshot: Equatable, Sendable {
    public let samples: UInt64
    public let sumMilliseconds: UInt64
    private let cumulativeBuckets: [V2DatabaseWorkAdmissionWaitBucket: UInt64]

    public init(
        samples: UInt64,
        sumMilliseconds: UInt64,
        cumulativeBuckets: [V2DatabaseWorkAdmissionWaitBucket: UInt64]
    ) {
        self.samples = samples
        self.sumMilliseconds = sumMilliseconds
        self.cumulativeBuckets = cumulativeBuckets
    }

    public func count(atOrBelow bucket: V2DatabaseWorkAdmissionWaitBucket) -> UInt64 {
        cumulativeBuckets[bucket, default: 0]
    }
}

public enum V2DatabaseWorkRejectionReason: String, CaseIterable, Sendable {
    case queueFull = "queue_full"
    case timeout
}

public enum V2DatabaseWorkAdmissionResult: Equatable, Sendable {
    case admitted
    case rejected(V2DatabaseWorkRejectionReason)
    case cancelled
}

public struct V2DatabaseWorkAdmissionPolicy: Equatable, Sendable {
    public let maximumForegroundWriteInFlight: Int
    public let maximumInteractiveReadInFlight: Int
    public let maximumSyncInFlight: Int
    public let maximumForegroundWriteQueued: Int
    public let maximumInteractiveReadQueued: Int
    public let maximumSyncQueued: Int
    public let timeout: Duration

    public init(
        maximumForegroundWriteInFlight: Int,
        maximumInteractiveReadInFlight: Int,
        maximumSyncInFlight: Int,
        maximumForegroundWriteQueued: Int,
        maximumInteractiveReadQueued: Int,
        maximumSyncQueued: Int,
        timeout: Duration
    ) {
        precondition(maximumForegroundWriteInFlight > 0)
        precondition(maximumInteractiveReadInFlight > 0)
        precondition(maximumSyncInFlight > 0)
        precondition(maximumForegroundWriteQueued > 0)
        precondition(maximumInteractiveReadQueued > 0)
        precondition(maximumSyncQueued > 0)
        precondition(timeout > .zero)
        self.maximumForegroundWriteInFlight = maximumForegroundWriteInFlight
        self.maximumInteractiveReadInFlight = maximumInteractiveReadInFlight
        self.maximumSyncInFlight = maximumSyncInFlight
        self.maximumForegroundWriteQueued = maximumForegroundWriteQueued
        self.maximumInteractiveReadQueued = maximumInteractiveReadQueued
        self.maximumSyncQueued = maximumSyncQueued
        self.timeout = timeout
    }
}

public struct V2DatabaseWorkAdmissionClassSnapshot: Equatable, Sendable {
    public let inFlight: Int
    public let queued: Int
    public let admittedRequests: UInt64
    public let queueFullRejections: UInt64
    public let timeoutRejections: UInt64
    public let cancelledRequests: UInt64
    public let queueWait: V2DatabaseWorkAdmissionWaitSnapshot

    public init(
        inFlight: Int,
        queued: Int,
        admittedRequests: UInt64,
        queueFullRejections: UInt64,
        timeoutRejections: UInt64,
        cancelledRequests: UInt64,
        queueWait: V2DatabaseWorkAdmissionWaitSnapshot = .init(
            samples: 0,
            sumMilliseconds: 0,
            cumulativeBuckets: [:]
        )
    ) {
        self.inFlight = inFlight
        self.queued = queued
        self.admittedRequests = admittedRequests
        self.queueFullRejections = queueFullRejections
        self.timeoutRejections = timeoutRejections
        self.cancelledRequests = cancelledRequests
        self.queueWait = queueWait
    }

    public var rejectedRequests: UInt64 {
        let sum = queueFullRejections.addingReportingOverflow(timeoutRejections)
        return sum.overflow ? .max : sum.partialValue
    }
}

public struct V2DatabaseWorkAdmissionSnapshot: Equatable, Sendable {
    public let foregroundWrite: V2DatabaseWorkAdmissionClassSnapshot
    public let interactiveRead: V2DatabaseWorkAdmissionClassSnapshot
    public let sync: V2DatabaseWorkAdmissionClassSnapshot

    public var foregroundWriteInFlight: Int { foregroundWrite.inFlight }
    public var interactiveReadInFlight: Int { interactiveRead.inFlight }
    public var syncInFlight: Int { sync.inFlight }
    public var foregroundWriteQueued: Int { foregroundWrite.queued }
    public var interactiveReadQueued: Int { interactiveRead.queued }
    public var syncQueued: Int { sync.queued }
    /// Aggregate foreground pressure used by durable workers to back off. It
    /// intentionally includes both client-visible write and interactive-read
    /// lanes: either consumes the shared PostgreSQL foreground pool.
    public var foregroundInFlight: Int {
        foregroundWrite.inFlight + interactiveRead.inFlight
    }
    public var foregroundQueued: Int {
        foregroundWrite.queued + interactiveRead.queued
    }
    public var queued: Int { foregroundWrite.queued + interactiveRead.queued + sync.queued }
    public var rejectedRequests: UInt64 {
        let foreground = foregroundWrite.rejectedRequests.addingReportingOverflow(
            interactiveRead.rejectedRequests
        )
        guard !foreground.overflow else { return .max }
        let total = foreground.partialValue.addingReportingOverflow(sync.rejectedRequests)
        return total.overflow ? .max : total.partialValue
    }

    public func value(
        for workClass: V2DatabaseWorkClass
    ) -> V2DatabaseWorkAdmissionClassSnapshot {
        switch workClass {
        case .foregroundWrite: foregroundWrite
        case .interactiveRead: interactiveRead
        case .sync: sync
        }
    }
}

/// A bounded process-local queue in front of the more expensive Fluent pool
/// wait. Foreground writes, interactive reads and Sync own independent
/// in-flight and queue budgets, so a room-log pull or reconnect storm cannot
/// consume the send queue reservation.
///
/// Each lane is an intrusive doubly linked FIFO stored inside the actor. Grant,
/// timeout and cancellation are therefore O(1), including under the 2,000+
/// waiter load-test ceiling. A waiter owns one checked continuation and one
/// cancellable timeout task; every terminal path removes it before resuming,
/// mechanically preventing double resume or permit overspend.
public actor V2DatabaseWorkAdmissionController {
    private struct Waiter: Sendable {
        let workClass: V2DatabaseWorkClass
        let continuation: CheckedContinuation<V2DatabaseWorkAdmissionResult, Never>
        let enqueuedAt: ContinuousClock.Instant
        var previous: UUID?
        var next: UUID?
        var timeoutTask: Task<Void, Never>?
    }

    private struct Lane: Sendable {
        var inFlight = 0
        var head: UUID?
        var tail: UUID?
        var queued = 0
        var admittedRequests: UInt64 = 0
        var queueFullRejections: UInt64 = 0
        var timeoutRejections: UInt64 = 0
        var cancelledRequests: UInt64 = 0
        var queueWaitSamples: UInt64 = 0
        var queueWaitMillisecondsSum: UInt64 = 0
        var queueWaitBuckets: [V2DatabaseWorkAdmissionWaitBucket: UInt64] = [:]
    }

    private let policy: V2DatabaseWorkAdmissionPolicy
    private let clock = ContinuousClock()
    private var foregroundWrite = Lane()
    private var interactiveRead = Lane()
    private var sync = Lane()
    private var waiters: [UUID: Waiter] = [:]

    public init(policy: V2DatabaseWorkAdmissionPolicy) {
        self.policy = policy
    }

    public func acquire(
        _ workClass: V2DatabaseWorkClass
    ) async -> V2DatabaseWorkAdmissionResult {
        if canAcquire(workClass), lane(for: workClass).queued == 0 {
            mutateLane(for: workClass) { lane in
                lane.inFlight += 1
                lane.admittedRequests = saturatingIncrement(lane.admittedRequests)
            }
            return .admitted
        }
        guard lane(for: workClass).queued < maximumQueued(for: workClass) else {
            mutateLane(for: workClass) { lane in
                lane.queueFullRejections = saturatingIncrement(lane.queueFullRejections)
            }
            return .rejected(.queueFull)
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(waiterID, workClass: workClass, continuation: continuation)
            }
        } onCancel: {
            // Cancellation handlers are synchronous. This bounded task only
            // forwards one message to the owning actor and has no independent
            // lifecycle or side effect.
            Task { await self.cancel(waiterID) }
        }
    }

    public func release(_ workClass: V2DatabaseWorkClass) {
        precondition(lane(for: workClass).inFlight > 0)
        mutateLane(for: workClass) { $0.inFlight -= 1 }
        grantNextIfPossible(workClass)
    }

    public func snapshot() -> V2DatabaseWorkAdmissionSnapshot {
        .init(
            foregroundWrite: snapshot(foregroundWrite),
            interactiveRead: snapshot(interactiveRead),
            sync: snapshot(sync)
        )
    }

    private func enqueue(
        _ waiterID: UUID,
        workClass: V2DatabaseWorkClass,
        continuation: CheckedContinuation<V2DatabaseWorkAdmissionResult, Never>
    ) {
        let previous = lane(for: workClass).tail
        waiters[waiterID] = .init(
            workClass: workClass,
            continuation: continuation,
            enqueuedAt: clock.now,
            previous: previous,
            next: nil,
            timeoutTask: nil
        )
        if let previous {
            waiters[previous]?.next = waiterID
        }
        mutateLane(for: workClass) { lane in
            if lane.head == nil { lane.head = waiterID }
            lane.tail = waiterID
            lane.queued += 1
        }
        let timeout = policy.timeout
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.timeOut(waiterID)
        }
        waiters[waiterID]?.timeoutTask = timeoutTask
        if Task.isCancelled {
            cancel(waiterID)
        }
    }

    private func grantNextIfPossible(_ workClass: V2DatabaseWorkClass) {
        guard canAcquire(workClass), let waiterID = lane(for: workClass).head,
              let waiter = removeWaiter(waiterID)
        else { return }
        mutateLane(for: workClass) { lane in
            lane.inFlight += 1
            lane.admittedRequests = saturatingIncrement(lane.admittedRequests)
        }
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(returning: .admitted)
    }

    private func timeOut(_ waiterID: UUID) {
        guard let waiter = removeWaiter(waiterID) else { return }
        mutateLane(for: waiter.workClass) { lane in
            lane.timeoutRejections = saturatingIncrement(lane.timeoutRejections)
        }
        waiter.continuation.resume(returning: .rejected(.timeout))
    }

    private func cancel(_ waiterID: UUID) {
        guard let waiter = removeWaiter(waiterID) else { return }
        mutateLane(for: waiter.workClass) { lane in
            lane.cancelledRequests = saturatingIncrement(lane.cancelledRequests)
        }
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(returning: .cancelled)
    }

    private func removeWaiter(_ waiterID: UUID) -> Waiter? {
        guard let waiter = waiters.removeValue(forKey: waiterID) else { return nil }
        recordQueueWait(for: waiter)
        if let previous = waiter.previous {
            waiters[previous]?.next = waiter.next
        } else {
            mutateLane(for: waiter.workClass) { $0.head = waiter.next }
        }
        if let next = waiter.next {
            waiters[next]?.previous = waiter.previous
        } else {
            mutateLane(for: waiter.workClass) { $0.tail = waiter.previous }
        }
        mutateLane(for: waiter.workClass) { lane in
            precondition(lane.queued > 0)
            lane.queued -= 1
        }
        return waiter
    }

    private func canAcquire(_ workClass: V2DatabaseWorkClass) -> Bool {
        switch workClass {
        case .foregroundWrite:
            foregroundWrite.inFlight < policy.maximumForegroundWriteInFlight
        case .interactiveRead:
            interactiveRead.inFlight < policy.maximumInteractiveReadInFlight
        case .sync:
            sync.inFlight < policy.maximumSyncInFlight
        }
    }

    private func maximumQueued(for workClass: V2DatabaseWorkClass) -> Int {
        switch workClass {
        case .foregroundWrite: policy.maximumForegroundWriteQueued
        case .interactiveRead: policy.maximumInteractiveReadQueued
        case .sync: policy.maximumSyncQueued
        }
    }

    private func lane(for workClass: V2DatabaseWorkClass) -> Lane {
        switch workClass {
        case .foregroundWrite: foregroundWrite
        case .interactiveRead: interactiveRead
        case .sync: sync
        }
    }

    private func mutateLane(
        for workClass: V2DatabaseWorkClass,
        _ mutation: (inout Lane) -> Void
    ) {
        switch workClass {
        case .foregroundWrite: mutation(&foregroundWrite)
        case .interactiveRead: mutation(&interactiveRead)
        case .sync: mutation(&sync)
        }
    }

    private func snapshot(_ lane: Lane) -> V2DatabaseWorkAdmissionClassSnapshot {
        .init(
            inFlight: lane.inFlight,
            queued: lane.queued,
            admittedRequests: lane.admittedRequests,
            queueFullRejections: lane.queueFullRejections,
            timeoutRejections: lane.timeoutRejections,
            cancelledRequests: lane.cancelledRequests,
            queueWait: .init(
                samples: lane.queueWaitSamples,
                sumMilliseconds: lane.queueWaitMillisecondsSum,
                cumulativeBuckets: lane.queueWaitBuckets
            )
        )
    }

    private func recordQueueWait(for waiter: Waiter) {
        let milliseconds = queueWaitMilliseconds(since: waiter.enqueuedAt)
        mutateLane(for: waiter.workClass) { lane in
            lane.queueWaitSamples = saturatingIncrement(lane.queueWaitSamples)
            lane.queueWaitMillisecondsSum = saturatingAdd(
                lane.queueWaitMillisecondsSum,
                milliseconds
            )
            for bucket in V2DatabaseWorkAdmissionWaitBucket.allCases where milliseconds <= UInt64(bucket.rawValue) {
                lane.queueWaitBuckets[bucket] = saturatingIncrement(
                    lane.queueWaitBuckets[bucket, default: 0]
                )
            }
        }
    }

    private func queueWaitMilliseconds(since instant: ContinuousClock.Instant) -> UInt64 {
        let components = instant.duration(to: clock.now).components
        guard components.seconds > 0 || components.attoseconds > 0 else { return 0 }
        let wholeSeconds = UInt64(components.seconds)
        let secondsMilliseconds = wholeSeconds.multipliedReportingOverflow(by: 1_000)
        guard !secondsMilliseconds.overflow else { return .max }
        let fractionalMilliseconds = UInt64(components.attoseconds / 1_000_000_000_000_000)
        return saturatingAdd(secondsMilliseconds.partialValue, fractionalMilliseconds)
    }

    private func saturatingIncrement(_ value: UInt64) -> UInt64 {
        value == .max ? .max : value + 1
    }

    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let sum = lhs.addingReportingOverflow(rhs)
        return sum.overflow ? .max : sum.partialValue
    }
}
