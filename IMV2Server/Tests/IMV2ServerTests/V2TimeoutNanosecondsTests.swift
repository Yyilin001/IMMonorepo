import Foundation
import NIOCore
import NIOEmbedded
import Synchronization
@testable import IMV2Server
import Testing

@Suite("V2 timeout nanosecond boundaries")
struct V2TimeoutNanosecondsTests {
    @Test("Positive fractional broker timeouts expire on the first tick at or after their deadline")
    func positiveSchedulerTicks() throws {
        let cases: [(Double, Int64)] = [
            (.leastNonzeroMagnitude, 1), (0.0000000001, 1), (0.000000001, 1),
            (0.00000000125, 2), (0.0005, 500_000), (0.001, 1_000_000),
            (0.12500000025, 125_000_001), (2, 2_000_000_000), (30, 30_000_000_000)
        ]
        let url = try #require(URL(string: "nats://127.0.0.1:4222"))
        for (seconds, expected) in cases {
            let group = try V2NATSGroupEventWakeConfiguration(url: url, subjectPrefix: "test.timeout",
                routingKey: Data(repeating: 0x23, count: 32), acknowledgementTimeout: seconds)
            #expect(group.acknowledgementTimeout == seconds)
            for timeout in [group.acknowledgementTimeoutNanoseconds] {
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
        let url = try #require(URL(string: "nats://127.0.0.1:4222"))
        for seconds in invalid {
            #expect(v2TimeoutNanoseconds(seconds) == nil)
            #expect(throws: V2NATSGroupEventWakeBrokerError.invalidConfiguration) {
                try V2NATSGroupEventWakeConfiguration(url: url, subjectPrefix: "test.timeout",
                    routingKey: Data(repeating: 0x23, count: 32), acknowledgementTimeout: seconds)
            }
        }
        for seconds in [(30.0).nextUp, 31, 86_400] {
            #expect(throws: V2NATSGroupEventWakeBrokerError.invalidConfiguration) {
                try V2NATSGroupEventWakeConfiguration(url: url, subjectPrefix: "test.timeout",
                    routingKey: Data(repeating: 0x23, count: 32), acknowledgementTimeout: seconds)
            }
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
