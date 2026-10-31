import Foundation
import IMV2ServerContracts
import Synchronization

/// Fixed-cardinality observations of completed reads. No identity, request,
/// response, error text or authorization result is retained by this owner.
public final class V2ProfilePresentationReadDiagnostics: Sendable {
    public enum Stage: String, CaseIterable, Sendable {
        case initialControl = "initial_control", initialRoom = "initial_room"
        case finalControl = "final_control", avatar = "avatar"
        case deliveryControl = "delivery_control", deliveryRoom = "delivery_room"
        case roomRPC = "room_rpc"
        case roomOwnerQueue = "room_owner_queue", roomOwnerRead = "room_owner_read"
        case roomOwnerExecution = "room_owner_execution"
        case dispatchQueue = "dispatch_queue", dispatchTask = "dispatch_task"
        case dispatchEncode = "dispatch_encode", dispatchWriteQueue = "dispatch_write_queue"
        case dispatchWrite = "dispatch_write"
    }
    public enum Outcome: String, CaseIterable, Sendable {
        case controlDeadline = "control_deadline", controlOverloaded = "control_overloaded"
        case controlCancelled = "control_cancelled", controlFailure = "control_failure"
        case roomDeadline = "room_deadline", roomOverloaded = "room_overloaded"
        case roomCancelled = "room_cancelled", roomOwnershipChanged = "room_ownership_changed"
        case roomDependencyUnavailable = "room_dependency_unavailable", roomRejected = "room_rejected"
        case roomFailure = "room_failure", roomUnavailable = "room_unavailable"
        case roomRecheckUnavailable = "room_recheck_unavailable"
        case roomFactsChanged = "room_facts_changed", controlFactsChanged = "control_facts_changed"
        case workExpired = "work_expired", leaseExpired = "lease_expired"
        case writeDeferred = "write_deferred"
        case presentation, denial, retryable
    }
    public struct Measurement: Sendable {
        public fileprivate(set) var calls = 0
        public fileprivate(set) var failures = 0
        public fileprivate(set) var totalMilliseconds = 0.0
        public fileprivate(set) var maximumMilliseconds = 0.0
    }
    public struct Snapshot: Sendable {
        public fileprivate(set) var stages: [Stage: Measurement] = [:]
        public fileprivate(set) var outcomes: [Outcome: Int] = [:]
        public init() {}
        public func merging(_ other: Self) -> Self {
            var result = self
            for (stage, value) in other.stages {
                var merged = result.stages[stage, default: .init()]
                merged.calls += value.calls; merged.failures += value.failures
                merged.totalMilliseconds += value.totalMilliseconds
                merged.maximumMilliseconds = max(merged.maximumMilliseconds, value.maximumMilliseconds)
                result.stages[stage] = merged
            }
            for (outcome, count) in other.outcomes { result.outcomes[outcome, default: 0] += count }
            return result
        }
    }
    private let state = Mutex(Snapshot())
    public init() {}
    public func snapshot() -> Snapshot { state.withLock { $0 } }

    package func record(_ outcome: Outcome, count: Int = 1) {
        state.withLock { $0.outcomes[outcome, default: 0] += count }
    }

    package func measure<Value: Sendable>(_ stage: Stage,
        operation: @Sendable () async throws -> Value) async rethrows -> Value {
        let started = ContinuousClock.now
        do {
            let value = try await operation()
            recordElapsed(stage, started: started)
            return value
        } catch {
            switch stage {
            case .initialControl, .finalControl, .deliveryControl:
                if error is CancellationError { record(.controlCancelled) }
                else if error as? V2ProfileControlBatchError == .deadlineExceeded { record(.controlDeadline) }
                else if case .throttled = error as? V2ResourceProviderError { record(.controlOverloaded) }
                else { record(.controlFailure) }
            case .initialRoom, .avatar, .deliveryRoom, .roomRPC,
                 .roomOwnerQueue, .roomOwnerRead, .roomOwnerExecution,
                 .dispatchQueue, .dispatchTask, .dispatchEncode, .dispatchWriteQueue, .dispatchWrite: break
            }
            recordElapsed(stage, started: started, failed: true)
            throw error
        }
    }

    package func recordElapsed(_ stage: Stage, started: ContinuousClock.Instant, failed: Bool = false) {
        recordDuration(stage, duration: started.duration(to: .now), failed: failed)
    }

    package func recordDuration(_ stage: Stage, duration: Duration, failed: Bool = false) {
        let elapsed = duration.components
        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        state.withLock { value in
            var measurement = value.stages[stage, default: .init()]
            measurement.calls += 1
            if failed { measurement.failures += 1 }
            measurement.totalMilliseconds += milliseconds
            measurement.maximumMilliseconds = max(measurement.maximumMilliseconds, milliseconds)
            value.stages[stage] = measurement
        }
    }
}
