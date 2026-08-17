import Foundation

public enum V2DatabaseWorkClass: String, CaseIterable, Sendable {
    case foreground
    case sync
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
    public let maximumForegroundInFlight: Int
    public let maximumSyncInFlight: Int
    public let maximumForegroundQueued: Int
    public let maximumSyncQueued: Int
    public let timeout: Duration

    public init(
        maximumForegroundInFlight: Int,
        maximumSyncInFlight: Int,
        maximumForegroundQueued: Int,
        maximumSyncQueued: Int,
        timeout: Duration
    ) {
        precondition(maximumForegroundInFlight > 0)
        precondition(maximumSyncInFlight > 0)
        precondition(maximumForegroundQueued > 0)
        precondition(maximumSyncQueued > 0)
        precondition(timeout > .zero)
        self.maximumForegroundInFlight = maximumForegroundInFlight
        self.maximumSyncInFlight = maximumSyncInFlight
        self.maximumForegroundQueued = maximumForegroundQueued
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

    public var rejectedRequests: UInt64 {
        let sum = queueFullRejections.addingReportingOverflow(timeoutRejections)
        return sum.overflow ? .max : sum.partialValue
    }
}

public struct V2DatabaseWorkAdmissionSnapshot: Equatable, Sendable {
    public let foreground: V2DatabaseWorkAdmissionClassSnapshot
    public let sync: V2DatabaseWorkAdmissionClassSnapshot

    public var foregroundInFlight: Int { foreground.inFlight }
    public var syncInFlight: Int { sync.inFlight }
    public var foregroundQueued: Int { foreground.queued }
    public var syncQueued: Int { sync.queued }
    public var queued: Int { foreground.queued + sync.queued }
    public var rejectedRequests: UInt64 {
        let sum = foreground.rejectedRequests.addingReportingOverflow(sync.rejectedRequests)
        return sum.overflow ? .max : sum.partialValue
    }

    public func value(
        for workClass: V2DatabaseWorkClass
    ) -> V2DatabaseWorkAdmissionClassSnapshot {
        switch workClass {
        case .foreground: foreground
        case .sync: sync
        }
    }
}

/// A bounded process-local queue in front of the more expensive Fluent pool
/// wait. Foreground and Sync own independent in-flight and queue budgets, so a
/// reconnect storm cannot consume the foreground queue reservation.
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
    }

    private let policy: V2DatabaseWorkAdmissionPolicy
    private var foreground = Lane()
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
            foreground: snapshot(foreground),
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
        case .foreground:
            foreground.inFlight < policy.maximumForegroundInFlight
        case .sync:
            sync.inFlight < policy.maximumSyncInFlight
        }
    }

    private func maximumQueued(for workClass: V2DatabaseWorkClass) -> Int {
        switch workClass {
        case .foreground: policy.maximumForegroundQueued
        case .sync: policy.maximumSyncQueued
        }
    }

    private func lane(for workClass: V2DatabaseWorkClass) -> Lane {
        switch workClass {
        case .foreground: foreground
        case .sync: sync
        }
    }

    private func mutateLane(
        for workClass: V2DatabaseWorkClass,
        _ mutation: (inout Lane) -> Void
    ) {
        switch workClass {
        case .foreground: mutation(&foreground)
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
            cancelledRequests: lane.cancelledRequests
        )
    }

    private func saturatingIncrement(_ value: UInt64) -> UInt64 {
        value == .max ? .max : value + 1
    }
}
