import Synchronization
import Testing
@testable import IMV2ServerInfrastructure

@Suite("Scheduled send physical return ownership")
struct V2ScheduledSendLoanReturnTests {
    @Test("nested borrowing cannot notify an outer loan before its actual return")
    func nestedBorrowDoesNotReleaseOuter() throws {
        let returned = Mutex(0)
        let notifier = V2ScheduledSendLoanReturn { returned.withLock { $0 += 1 } }
        try V2ScheduledSendLoanReturn.$current.withValue(notifier) {
            let outerReturn = try #require(V2ScheduledSendLoanReturn.current?.takeCallback())
            #expect(V2ScheduledSendLoanReturn.current?.takeCallback() == nil)
            V2ScheduledSendLoanReturn.current?.notify()
            #expect(returned.withLock { $0 } == 0)
            outerReturn()
            #expect(returned.withLock { $0 } == 1)
        }
    }
}
