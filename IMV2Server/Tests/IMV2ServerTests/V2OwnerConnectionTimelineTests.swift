import Foundation
import Testing
@testable import IMV2ServerApplication
@testable import IMV2ServerInfrastructure
import IMV2ServerContracts

@Suite("Owner connection diagnostic timing")
struct V2OwnerConnectionTimelineTests {
    @Test("assignment partition closes and deferred diagnostics flush once")
    func assignmentPartition() {
        let metrics = V2SendOperationBatchMetrics(), timeline = V2OwnerConnectionTimeline()
        timeline.configure(metrics)
        let start = ContinuousClock.now
        timeline.mark("pool_request_started", at: start)
        timeline.deferAssignmentTiming(.init(requestedAt: start + .milliseconds(2),
            lockRequestedAt: start + .milliseconds(2), lockEnteredAt: start + .milliseconds(3), admittedAt: start + .milliseconds(4),
            grantedAt: start + .milliseconds(9), promiseSubmittedAt: start + .milliseconds(10),
            wasQueued: true, grantedOnEventLoop: false), registeredAt: start + .milliseconds(12),
            callbackAt: start + .milliseconds(18), publishedAt: start + .milliseconds(20), transferred: true)
        #expect(metrics.sendOperationBatchMetricsSnapshot().stages[.ownerGateDeliveryWait]?.count == 0)
        timeline.flushAssignmentTiming(); timeline.flushAssignmentTiming()
        let stages = metrics.sendOperationBatchMetricsSnapshot().stages
        let parts: [V2SendOperationStage] = [.ownerPoolBeforeWinningGate, .ownerGateRequestPreparation, .ownerGateLockWait,
            .ownerGateAdmission, .ownerGateCapacityWait, .ownerGateGrantToPromise,
            .ownerGateDeliveryWait, .ownerPoolPublishWork]
        #expect(parts.allSatisfy { stages[$0]?.count == 1 })
        #expect(parts.reduce(0.0) { $0 + (stages[$1]?.totalMilliseconds ?? 0) } == 20)
        #expect(stages[.ownerGateCapacityWait]?.totalMilliseconds == 5)
        #expect(stages[.ownerGateOffLoopDelivery]?.totalMilliseconds == 8)
        #expect(stages[.ownerGateOnLoopDelivery]?.count == 0)
        #expect(stages[.ownerGateCallbackRegistration]?.totalMilliseconds == 2)
        #expect(stages[.ownerGateRegisteredToCallback]?.totalMilliseconds == 6)
        #expect(stages[.ownerGateQueuedCapacityWait]?.totalMilliseconds == 5)
        #expect(stages[.ownerPoolPeerBeforeGate]?.totalMilliseconds == 2)
    }
    @Test("late recorder binding preserves ticket time and SQL gaps are distinct from future time")
    func completedIntervals() {
        let metrics = V2SendOperationBatchMetrics(), timeline = V2OwnerConnectionTimeline()
        let start = ContinuousClock.now
        timeline.record(.ownerTicketTaskWait, from: start, to: start + .milliseconds(2))
        timeline.configure(metrics)
        timeline.mark("driver_entered", at: start)
        timeline.sqlStarted(at: start + .milliseconds(3))
        timeline.sqlFinished(label: .begin, startedAt: start + .milliseconds(3), at: start + .milliseconds(5))
        timeline.sqlStarted(at: start + .milliseconds(9))
        timeline.sqlFinished(label: .write, startedAt: start + .milliseconds(9), at: start + .milliseconds(12))
        timeline.sqlStarted(at: start + .milliseconds(17))
        timeline.sqlFinished(label: .commit, startedAt: start + .milliseconds(17), at: start + .milliseconds(18))
        let s = metrics.sendOperationBatchMetricsSnapshot().stages
        #expect(s[.ownerTicketTaskWait]?.count == 1 && s[.ownerTicketTaskWait]?.totalMilliseconds == 2)
        #expect(s[.ownerBeforeFirstSQL]?.totalMilliseconds == 3)
        #expect(s[.ownerAfterBeginGap]?.totalMilliseconds == 4)
        #expect(s[.ownerAfterWriteGap]?.totalMilliseconds == 5)
        #expect(s[.ownerBeginFuture]?.totalMilliseconds == 2)
        #expect(s[.ownerWriteFuture]?.totalMilliseconds == 3)
        #expect(s[.ownerCommitFuture]?.totalMilliseconds == 1)
        #expect(s.values.allSatisfy { $0.inFlight == 0 })
    }
}
