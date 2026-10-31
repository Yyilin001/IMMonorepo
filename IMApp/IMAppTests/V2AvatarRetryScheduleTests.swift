import Foundation
import Testing
@testable import IMApp

struct V2AvatarRetryScheduleTests {
    @Test func retriesAreBoundedAndRespectBackoffWithoutExtendingDisplay() {
        let start = ContinuousClock.now, deadline = start + .seconds(100)
        var schedule = V2AvatarRetrySchedule()
        for delay in [2, 4, 8, 16] {
            #expect(schedule.next(retryAt: start, deadline: deadline, now: start) == start + .seconds(delay))
        }
        #expect(schedule.next(retryAt: start, deadline: deadline, now: start) == nil)
        var throttled = V2AvatarRetrySchedule()
        #expect(throttled.next(retryAt: start + .seconds(50), deadline: deadline, now: start) == start + .seconds(50))
        #expect(throttled.next(retryAt: deadline + .seconds(50), deadline: deadline, now: start) == deadline)
        #expect(throttled.next(retryAt: nil, deadline: deadline, now: start) == nil)
        #expect(throttled.next(retryAt: start, deadline: start, now: start) == nil)
    }
}
