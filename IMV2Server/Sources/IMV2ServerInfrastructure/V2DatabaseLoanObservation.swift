import Foundation
import Synchronization

/// Closed business vocabulary captured synchronously at loan admission.
public enum V2DatabaseLoanSource: String, CaseIterable, Sendable {
    case durableOwner = "durable_owner"
    case roomSendInitialization = "room_send_initialization"
    case preparationOwnerRead = "preparation_owner_read"
    case controlReservation = "control_reservation"
    case policySnapshot = "policy_snapshot"
    case lifecycle, renewal, presence
    case roomWake = "room_wake"
    case routeLookup = "route_lookup"
    case realtimePartitionControl = "realtime_partition_control"
    case realtimeOwnerSnapshot = "realtime_owner_snapshot"
    case realtimeRecoveryHead = "realtime_recovery_head"
    case groupEventPull = "group_event_pull"
    case groupEventSubscribe = "group_event_subscribe"
    case roomRecovery = "room_recovery"
    case sync
    case userStateProjection = "user_state_projection"
    case query, maintenance, other
}

public enum V2DatabaseLoanStage: String, CaseIterable, Sendable {
    case gateQueued = "gate_queued"
    case awaitingDriver = "awaiting_driver"
    case betweenSQL = "between_sql"
    case sql, settled
}

/// Semantic phase captured at the SQL API call, without inspecting SQL text.
public enum V2DatabaseLoanSQLPhase: String, CaseIterable, Sendable {
    case fence
    case readBody = "read_body"
    case transactionControl = "transaction_control"
    case other
}

public struct V2DatabaseLoanSQLPhaseSnapshot: Equatable, Sendable {
    public var count: UInt64 = 0
    public var totalMilliseconds: Double = 0
    public var maxMilliseconds: Double = 0
    public init() {}
}

public enum V2DatabaseLoanObservationContext {
    @TaskLocal public static var source: V2DatabaseLoanSource = .other
}

public struct V2DatabaseLoanStageSnapshot: Equatable, Sendable {
    public var active = 0
    public var oldestMilliseconds: Double = 0
    public var count: UInt64 = 0
    public var totalMilliseconds: Double = 0
    public var maxMilliseconds: Double = 0
    public init() {}
}

public struct V2DatabaseLoanSourceSnapshot: Equatable, Sendable {
    public var stages = Dictionary(uniqueKeysWithValues: V2DatabaseLoanStage.allCases.map {
        ($0, V2DatabaseLoanStageSnapshot())
    })
    /// SQL API invocation until its actual future completion, including driver,
    /// network and database waiting. Concurrent queries may overlap; this is
    /// neither PostgreSQL CPU time nor a partition of the held interval.
    public var sqlPhases = Dictionary(uniqueKeysWithValues: V2DatabaseLoanSQLPhase.allCases.map {
        ($0, V2DatabaseLoanSQLPhaseSnapshot())
    })
    /// Grant until actual loan return; includes driver acquisition waiting.
    public var actualHeldCount: UInt64 = 0
    public var actualHeldTotalMilliseconds: Double = 0
    public var actualHeldMaxMilliseconds: Double = 0
    public init() {}

    public mutating func merge(_ other: Self) {
        for stage in V2DatabaseLoanStage.allCases {
            let item = other.stages[stage, default: .init()]
            var result = stages[stage, default: .init()]
            result.active += item.active
            result.oldestMilliseconds = max(result.oldestMilliseconds, item.oldestMilliseconds)
            result.count = v2LoanObservationAdd(result.count, item.count)
            result.totalMilliseconds += item.totalMilliseconds
            result.maxMilliseconds = max(result.maxMilliseconds, item.maxMilliseconds)
            stages[stage] = result
        }
        for phase in V2DatabaseLoanSQLPhase.allCases {
            let item = other.sqlPhases[phase, default: .init()]
            var result = sqlPhases[phase, default: .init()]
            result.count = v2LoanObservationAdd(result.count, item.count)
            result.totalMilliseconds += item.totalMilliseconds
            result.maxMilliseconds = max(result.maxMilliseconds, item.maxMilliseconds)
            sqlPhases[phase] = result
        }
        actualHeldCount = v2LoanObservationAdd(actualHeldCount, other.actualHeldCount)
        actualHeldTotalMilliseconds += other.actualHeldTotalMilliseconds
        actualHeldMaxMilliseconds = max(actualHeldMaxMilliseconds, other.actualHeldMaxMilliseconds)
    }
}

/// One actual loan, including its bounded queued admission. SQL completion is
/// not loan return. Multiple concurrent SQL futures share a single SQL stage.
public final class V2DatabaseLoanObservation: Sendable {
    public let source: V2DatabaseLoanSource

    /// Immutable identity and phase for one SQL future. A private completion
    /// guard permits repeated callbacks without retaining a per-loan token list.
    public final class SQLToken: Sendable {
        public let phase: V2DatabaseLoanSQLPhase
        fileprivate let owner: V2DatabaseLoanObservation
        fileprivate let startedAt: ContinuousClock.Instant
        fileprivate let admitted: Bool
        fileprivate let finished = Mutex(false)
        fileprivate let timeline = V2OwnerConnectionTimeline.current
        fileprivate let label = V2OwnerConnectionTimeline.sqlLabel

        fileprivate init(owner: V2DatabaseLoanObservation, phase: V2DatabaseLoanSQLPhase,
            startedAt: ContinuousClock.Instant, admitted: Bool) {
            self.owner = owner
            self.phase = phase
            self.startedAt = startedAt
            self.admitted = admitted
        }
    }
    private struct State: Sendable {
        var stage: V2DatabaseLoanStage = .gateQueued
        var enteredAt: ContinuousClock.Instant
        var grantedAt: ContinuousClock.Instant?
        var queries = 0
        var sqlPhase: V2DatabaseLoanSQLPhase = .other
        var closed = false
        var completed = V2DatabaseLoanSourceSnapshot()
    }
    private let state: Mutex<State>
    private let sqlCompletion: @Sendable (V2DatabaseLoanSQLPhase, Duration) -> Void
    private let completion: @Sendable (V2DatabaseLoanSourceSnapshot) -> Void

    fileprivate init(source: V2DatabaseLoanSource, at: ContinuousClock.Instant,
        sqlCompletion: @escaping @Sendable (V2DatabaseLoanSQLPhase, Duration) -> Void,
        completion: @escaping @Sendable (V2DatabaseLoanSourceSnapshot) -> Void) {
        self.source = source
        state = Mutex(.init(enteredAt: at))
        self.completion = completion
        self.sqlCompletion = sqlCompletion
    }

    func granted(at: ContinuousClock.Instant) {
        state.withLock { state in
            guard !state.closed, state.stage == .gateQueued else { return }
            transition(&state, to: .awaitingDriver, at: at)
            state.grantedAt = at
        }
    }

    /// The underlying driver's borrowed callback has been entered. A Fluent
    /// transaction callback may already include BEGIN; this is not SQL start.
    public func driverEntered() {
        state.withLock { state in
            guard !state.closed, state.stage == .awaitingDriver else { return }
            transition(&state, to: .betweenSQL, at: .now)
        }
    }

    /// Changes only the default for subsequently started SQL. Concurrent
    /// semantic operations should provide an explicit startSQL phase instead.
    public func setSQLPhase(_ phase: V2DatabaseLoanSQLPhase) {
        state.withLock { state in
            guard !state.closed else { return }
            state.sqlPhase = phase
        }
    }

    public func startSQL(phase: V2DatabaseLoanSQLPhase? = nil) -> SQLToken {
        let now = ContinuousClock.now
        V2OwnerConnectionTimeline.current?.sqlStarted(at: now)
        let (capturedPhase, admitted) = state.withLock { state in
            let captured = phase ?? state.sqlPhase
            guard !state.closed, state.stage == .betweenSQL || state.stage == .sql else {
                return (captured, false)
            }
            if state.queries == 0 { transition(&state, to: .sql, at: now) }
            state.queries += 1
            return (captured, true)
        }
        return SQLToken(owner: self, phase: capturedPhase, startedAt: now, admitted: admitted)
    }

    /// Called by the actual SQL future callback on either success or failure.
    /// Caller cancellation never substitutes for this completion. The phase
    /// counter survives a late callback after the loan has actually returned.
    public func finishSQL(_ token: SQLToken) {
        guard token.owner === self, token.admitted else { return }
        let firstCompletion = token.finished.withLock { finished in
            guard !finished else { return false }
            finished = true
            return true
        }
        guard firstCompletion else { return }
        let now = ContinuousClock.now
        state.withLock { state in
            guard !state.closed, state.queries > 0 else { return }
            state.queries -= 1
            if state.queries == 0 { transition(&state, to: .betweenSQL, at: now) }
        }
        // Registry counters are separate from the terminal ticket report;
        // recording outside the ticket lock avoids lock order inversion.
        token.timeline?.sqlFinished(label: token.label, startedAt: token.startedAt, at: now)
        sqlCompletion(token.phase, token.startedAt.duration(to: now))
    }

    public func queryStarted() {
        state.withLock { state in
            guard !state.closed, state.stage == .betweenSQL || state.stage == .sql else { return }
            if state.queries == 0 { transition(&state, to: .sql, at: .now) }
            state.queries += 1
        }
    }

    /// Only the last actually completed query leaves the SQL stage. Releasing
    /// a caller or cancelling it must not stand in for query completion.
    public func queryFinished() {
        state.withLock { state in
            guard !state.closed, state.queries > 0 else { return }
            state.queries -= 1
            if state.queries == 0 { transition(&state, to: .betweenSQL, at: .now) }
        }
    }

    func finish() {
        let report: V2DatabaseLoanSourceSnapshot? = state.withLock { state in
            guard !state.closed else { return nil }
            let now = ContinuousClock.now
            transition(&state, to: .settled, at: now)
            state.closed = true
            if let granted = state.grantedAt {
                let elapsed = v2LoanObservationMilliseconds(granted.duration(to: now))
                state.completed.actualHeldCount = 1
                state.completed.actualHeldTotalMilliseconds = elapsed
                state.completed.actualHeldMaxMilliseconds = elapsed
            }
            return state.completed
        }
        // Never call the registry while holding a ticket mutex. Registry
        // snapshot also copies tickets before inspecting them, avoiding cycles.
        if let report { completion(report) }
    }

    fileprivate func snapshot(at now: ContinuousClock.Instant) -> V2DatabaseLoanSourceSnapshot {
        state.withLock { state in
            var result = state.completed
            if !state.closed, state.stage != .settled {
                var item = result.stages[state.stage, default: .init()]
                item.active = 1
                item.oldestMilliseconds = v2LoanObservationMilliseconds(state.enteredAt.duration(to: now))
                result.stages[state.stage] = item
            }
            return result
        }
    }

    private func transition(_ state: inout State, to next: V2DatabaseLoanStage, at now: ContinuousClock.Instant) {
        var item = state.completed.stages[state.stage, default: .init()]
        let elapsed = v2LoanObservationMilliseconds(state.enteredAt.duration(to: now))
        item.count = v2LoanObservationAdd(item.count, 1)
        item.totalMilliseconds += elapsed
        item.maxMilliseconds = max(item.maxMilliseconds, elapsed)
        state.completed.stages[state.stage] = item
        state.stage = next
        state.enteredAt = now
    }
}

/// Retains only requests already bounded by the gate and actual held slots.
/// Completed IDs are removed; only fixed source/stage counters remain.
final class V2DatabaseLoanObservationRegistry: Sendable {
    private struct State: Sendable {
        var active: [UUID: V2DatabaseLoanObservation] = [:]
        var completed = Dictionary(uniqueKeysWithValues: V2DatabaseLoanSource.allCases.map {
            ($0, V2DatabaseLoanSourceSnapshot())
        })
    }
    private let state = Mutex(State())

    func make(source: V2DatabaseLoanSource, at: ContinuousClock.Instant) -> V2DatabaseLoanObservation {
        let id = UUID()
        let observation = V2DatabaseLoanObservation(source: source, at: at, sqlCompletion: { [self] phase, duration in
            let elapsed = v2LoanObservationMilliseconds(duration)
            state.withLock { state in
                var item = state.completed[source, default: .init()].sqlPhases[phase, default: .init()]
                item.count = v2LoanObservationAdd(item.count, 1)
                item.totalMilliseconds += elapsed
                item.maxMilliseconds = max(item.maxMilliseconds, elapsed)
                state.completed[source, default: .init()].sqlPhases[phase] = item
            }
        }) { [self] report in
            state.withLock { state in
                guard state.active.removeValue(forKey: id) != nil else { return }
                state.completed[source, default: .init()].merge(report)
            }
        }
        state.withLock { $0.active[id] = observation }
        return observation
    }

    func rejected(source: V2DatabaseLoanSource, startedAt: ContinuousClock.Instant) {
        let elapsed = v2LoanObservationMilliseconds(startedAt.duration(to: .now))
        state.withLock { state in
            var report = V2DatabaseLoanSourceSnapshot()
            var stage = V2DatabaseLoanStageSnapshot()
            stage.count = 1; stage.totalMilliseconds = elapsed; stage.maxMilliseconds = elapsed
            report.stages[.gateQueued] = stage
            state.completed[source, default: .init()].merge(report)
        }
    }

    func snapshot() -> [V2DatabaseLoanSource: V2DatabaseLoanSourceSnapshot] {
        let (active, completed) = state.withLock { (Array($0.active.values), $0.completed) }
        var result = completed
        let now = ContinuousClock.now
        for observation in active {
            result[observation.source, default: .init()].merge(observation.snapshot(at: now))
        }
        return result
    }
}

private func v2LoanObservationMilliseconds(_ duration: Duration) -> Double {
    let value = duration.components
    return max(0, Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15)
}
private func v2LoanObservationAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let sum = lhs.addingReportingOverflow(rhs)
    return sum.overflow ? .max : sum.partialValue
}
