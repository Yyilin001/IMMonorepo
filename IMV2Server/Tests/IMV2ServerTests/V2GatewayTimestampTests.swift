import Foundation
import Testing
@testable import IMV2Server

struct V2GatewayTimestampTests {
    @Test("Wire timestamp boundaries preserve signed milliseconds and reject overflow")
    func signedMilliseconds() throws {
        for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, Double(Int64.max) / 1_000] {
            #expect(throws: V2GatewayTimestampError.self) { try v2GatewayMilliseconds(Date(timeIntervalSince1970: seconds)) }
        }
        #expect(try v2GatewayMilliseconds(Date(timeIntervalSince1970: 1.25)) == 1_250)
        #expect(try v2GatewayMilliseconds(Date(timeIntervalSince1970: -1.25)) == -1_250)
        #expect(try v2GatewayMilliseconds(Date(timeIntervalSince1970: 0)) == 0)
        let nearUpperBound = Double(Int64.max) / 1_000 - 16
        #expect(try v2GatewayMilliseconds(Date(timeIntervalSince1970: nearUpperBound)) == Int64(exactly: (nearUpperBound * 1_000).rounded(.towardZero)))
    }

    @Test("Elapsed metrics floor monotonic durations and reject negative or overflowing intervals")
    func elapsedMilliseconds() {
        for duration: Duration in [.zero, .nanoseconds(-1), .seconds(-1), .seconds(Int64.min), .seconds(Int64.max)] {
            #expect(v2ElapsedMilliseconds(duration) == 0)
        }
        #expect(v2ElapsedMilliseconds(.microseconds(999)) == 0)
        #expect(v2ElapsedMilliseconds(.microseconds(1_001)) == 1)
        #expect(v2ElapsedMilliseconds(.seconds(1) + .milliseconds(250)) == 1_250)
        let maximum = Duration.seconds(Int64(UInt64.max / 1_000)) + .milliseconds(Int64(UInt64.max % 1_000))
        #expect(v2ElapsedMilliseconds(maximum) == UInt64.max)
        #expect(v2ElapsedMilliseconds(maximum + .milliseconds(1)) == 0)
        let start = ContinuousClock.now
        #expect(v2ElapsedMilliseconds(since: start, now: start.advanced(by: .milliseconds(25))) == 25)
    }
    @Test("Cross-store timing uses bounded monotonic durations and nearest milliseconds")
    func crossStoreElapsedMilliseconds() {
        for duration: Duration in [.zero, .seconds(-1), .seconds(Int64.max), .seconds(Int64.min)] {
            #expect(v2CrossStoreElapsedMilliseconds(duration) == 0)
        }
        #expect(v2CrossStoreElapsedMilliseconds(.microseconds(499)) == 0)
        #expect(v2CrossStoreElapsedMilliseconds(.microseconds(500)) == 1)
        #expect(v2CrossStoreElapsedMilliseconds(.microseconds(1_499)) == 1)
        #expect(v2CrossStoreElapsedMilliseconds(.microseconds(1_500)) == 2)
        #expect(v2CrossStoreElapsedMilliseconds(.microseconds(1_999_500)) == 2_000)
        #expect(v2CrossStoreElapsedMilliseconds(.seconds(1) + .milliseconds(250)) == 1_250)
        let maximum = Duration.seconds(Int64.max / 1_000) + .milliseconds(Int64.max % 1_000)
        #expect(v2CrossStoreElapsedMilliseconds(maximum) == Int.max)
        #expect(v2CrossStoreElapsedMilliseconds(maximum + .microseconds(500)) == 0)
    }

}
