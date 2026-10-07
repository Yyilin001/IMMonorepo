@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import NIOCore
import NIOEmbedded
import Synchronization
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 timeout nanosecond boundaries")
struct V2TimeoutNanosecondsTests {
    @Test("Positive fractional scheduler timeouts expire on the first tick at or after their deadline")
    func positiveSchedulerTicks() throws {
        let cases: [(Double, Int64)] = [
            (.leastNonzeroMagnitude, 1), (0.0000000001, 1), (0.000000001, 1),
            (0.00000000125, 2), (0.0005, 500_000), (0.001, 1_000_000),
            (0.12500000025, 125_000_001), (2, 2_000_000_000), (30, 30_000_000_000)
        ]
        for (seconds, expected) in cases {
            let timeout = try #require(v2TimeoutNanoseconds(seconds))
            #expect(timeout == expected)
            do {
                let loop = EmbeddedEventLoop()
                let fired = Mutex(false)
                _ = loop.scheduleTask(in: .nanoseconds(timeout)) { fired.withLock { $0 = true } }
                loop.advanceTime(by: .nanoseconds(expected - 1))
                #expect(!fired.withLock { $0 })
                loop.advanceTime(by: .nanoseconds(1))
                #expect(fired.withLock { $0 })
                try loop.syncShutdownGracefully()
            }
        }
    }

    @Test("Invalid and overflowing waits remain configuration errors")
    func invalidTimeouts() throws {
        let invalid: [Double] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude,
            -.greatestFiniteMagnitude, 0, -1, Double(Int64.max) / 1_000_000_000]
        for seconds in invalid {
            #expect(v2TimeoutNanoseconds(seconds) == nil)
        }
    }

    @Test("Metrics refresh precision covers submillisecond waits and its full one-day range")
    func metricsTimeoutRange() {
        #expect(v2TimeoutNanoseconds(0.0005) == 500_000)
        #expect(v2TimeoutNanoseconds(4) == 4_000_000_000)
        #expect(v2TimeoutNanoseconds(86_400) == 86_400_000_000_000)
        let largest = (Double(Int64.max) / 1_000_000_000).nextDown
        #expect(v2TimeoutNanoseconds(largest) != nil)
    }
}
