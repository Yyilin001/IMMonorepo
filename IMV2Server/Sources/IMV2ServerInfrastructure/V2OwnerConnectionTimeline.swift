import Foundation
import Synchronization
import IMV2ActorContracts
import IMV2ServerApplication
import IMV2ServerContracts

/// One unbound physical ticket. Records timings without changing scheduling.
/// Ticket spans before the selected request are clipped in its request trace.
final class V2OwnerConnectionTimeline: Sendable {
    enum SQLLabel: Sendable { case begin, write, commit }
    @TaskLocal static var current: V2OwnerConnectionTimeline?
    @TaskLocal static var sqlLabel: SQLLabel = .write
    let requestedAt = ContinuousClock.now
    private struct Span: Sendable { let stage: V2SendOperationStage; let start: ContinuousClock.Instant; let end: ContinuousClock.Instant }
    private struct State: Sendable {
        var metrics: V2SendOperationBatchMetrics?
        var markers: [String: ContinuousClock.Instant] = [:]
        var lastSQL: (SQLLabel, ContinuousClock.Instant)?
        var spans: [Span] = []
        var trace: V2SendPathTrace?
        var enqueuedAt: ContinuousClock.Instant?
        var assignmentTiming: AssignmentTiming?
    }
    private struct AssignmentTiming: Sendable {
        let loan: V2PhysicalDatabaseLoanTiming
        let registeredAt: ContinuousClock.Instant
        let callbackAt: ContinuousClock.Instant
        let publishedAt: ContinuousClock.Instant
        let transferred: Bool
    }
    private let state = Mutex(State())
    func configure(_ metrics: V2SendOperationBatchMetrics?) {
        let pending = state.withLock { s in s.metrics = metrics; return s.spans }
        for span in pending { metrics?.recordCompletedStage(span.stage, duration: span.start.duration(to: span.end)) }
    }
    func mark(_ name: String, at: ContinuousClock.Instant = .now) { state.withLock { $0.markers[name] = at } }
    func marker(_ name: String) -> ContinuousClock.Instant? { state.withLock { $0.markers[name] } }
    func deferAssignmentTiming(_ timing: V2PhysicalDatabaseLoanTiming?,
        registeredAt: ContinuousClock.Instant, callbackAt: ContinuousClock.Instant,
        publishedAt: ContinuousClock.Instant, transferred: Bool) {
        guard let timing else { return }
        state.withLock { $0.assignmentTiming = .init(loan: timing, registeredAt: registeredAt,
            callbackAt: callbackAt, publishedAt: publishedAt, transferred: transferred) }
    }
    /// Emit counters after the SQL loan settles, off the assignment/driver path.
    /// All intervals use original instants, so late reporting does not inflate them.
    func flushAssignmentTiming() {
        let context = state.withLock { s in
            let value = (s.assignmentTiming, s.markers["pool_request_started"])
            s.assignmentTiming = nil
            return value
        }
        guard let d = context.0, let start = context.1 else { return }
        let t = d.loan
        record(.ownerPoolBeforeWinningGate, from: start, to: t.requestedAt)
        record(.ownerGateRequestPreparation, from: t.requestedAt, to: t.lockRequestedAt)
        record(.ownerGateLockWait, from: t.lockRequestedAt, to: t.lockEnteredAt)
        record(.ownerGateAdmission, from: t.lockEnteredAt, to: t.admittedAt)
        record(.ownerGateCapacityWait, from: t.admittedAt, to: t.grantedAt)
        record(.ownerGateGrantToPromise, from: t.grantedAt, to: t.promiseSubmittedAt)
        record(.ownerGateDeliveryWait, from: t.promiseSubmittedAt, to: d.callbackAt)
        record(.ownerPoolPublishWork, from: d.callbackAt, to: d.publishedAt)
        record(t.grantedOnEventLoop ? .ownerGateOnLoopDelivery : .ownerGateOffLoopDelivery,
            from: t.promiseSubmittedAt, to: d.callbackAt)
        let registered = min(d.callbackAt, max(t.promiseSubmittedAt, d.registeredAt))
        record(.ownerGateCallbackRegistration, from: t.promiseSubmittedAt, to: registered)
        record(.ownerGateRegisteredToCallback, from: registered, to: d.callbackAt)
        if t.wasQueued { record(.ownerGateQueuedCapacityWait, from: t.admittedAt, to: t.grantedAt) }
        if d.transferred { record(.ownerPoolPeerBeforeGate, from: start, to: t.requestedAt) }
    }
    func resourceWindow() -> V2OwnerResourceWaitDiagnosis.Window {
        state.withLock { .init(created: requestedAt, borrowed: $0.markers["driver_entered"],
            returned: $0.markers["pool_returned"], released: $0.markers["scheduler_release_entered"],
            taskStarted: $0.markers["ticket_entry_started"] ?? $0.markers["ticket_task_started"], poolRequested: $0.markers["pool_request_started"],
            assignmentPublished: $0.markers["pool_assignment_published"],
            assignmentCallback: $0.markers["pool_assignment_callback_entered"], hasAcquisitionMarkers: true) }
    }
    func record(_ stage: V2SendOperationStage, from start: ContinuousClock.Instant, to end: ContinuousClock.Instant = .now) {
        let span = Span(stage: stage, start: start, end: max(start, end))
        let context = state.withLock { s in
            if s.spans.count < 128 { s.spans.append(span) }
            return (s.metrics, s.trace, s.enqueuedAt)
        }
        context.0?.recordCompletedStage(stage, duration: span.start.duration(to: span.end))
        if let trace = context.1, let queued = context.2, span.end >= queued {
            trace.record(stage.rawValue, from: max(span.start, queued), to: span.end)
        }
    }
    func attach(trace: V2SendPathTrace?, enqueuedAt: ContinuousClock.Instant) {
        let spans = state.withLock { s in s.trace = trace; s.enqueuedAt = enqueuedAt; return s.spans }
        for span in spans where span.end >= enqueuedAt { trace?.record(span.stage.rawValue, from: max(span.start, enqueuedAt), to: span.end) }
    }
    func sqlStarted(at now: ContinuousClock.Instant) {
        let prior = state.withLock { ($0.lastSQL, $0.markers["driver_entered"]) }
        if let (label, ended) = prior.0 {
            record(label == .begin ? .ownerAfterBeginGap : .ownerAfterWriteGap, from: ended, to: now)
        } else if let entered = prior.1 { record(.ownerBeforeFirstSQL, from: entered, to: now) }
    }
    func sqlFinished(label: SQLLabel, startedAt: ContinuousClock.Instant, at now: ContinuousClock.Instant) {
        state.withLock { $0.lastSQL = (label, now) }
        record(label == .begin ? .ownerBeginFuture : label == .commit ? .ownerCommitFuture : .ownerWriteFuture, from: startedAt, to: now)
        mark(label == .begin ? "begin_future_completed" : label == .commit ? "commit_future_completed" : "write_future_completed", at: now)
    }
}
