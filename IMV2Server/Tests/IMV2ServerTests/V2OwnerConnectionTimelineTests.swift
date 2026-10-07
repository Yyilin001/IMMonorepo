import Foundation
import Testing
@testable import IMV2ServerApplication
@testable import IMV2ServerInfrastructure
import IMV2ServerContracts

@Suite("Owner connection diagnostic timing")
struct V2OwnerConnectionTimelineTests {
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
