import Foundation
@testable import IMV2ClientKit
import Testing

struct V2CommandRetryDateTests {
    @Test(arguments: [Double.nan, .infinity, -.infinity, 0, -1, .leastNonzeroMagnitude])
    func invalidDelay(delay: Double) {
        #expect(throws: V2CommandRetrySchedulerError.invalidDate) {
            try v2CommandRetryDate(now: Date(timeIntervalSince1970: 1_000), delay: delay)
        }
    }

    @Test(arguments: [-1.0, 0, 1_000])
    func preservesFiniteClock(seconds: Double) throws {
        #expect(try v2CommandRetryDate(now: Date(timeIntervalSince1970: seconds), delay: 1) == Date(timeIntervalSince1970: seconds + 1))
    }
}
