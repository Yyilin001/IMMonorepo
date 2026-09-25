@testable import IMV2Server
import Testing

@Suite("V2 runtime latency metrics")
struct V2RuntimeLatencyMetricsTests {
    @Test("append stages retain cumulative fixed buckets without dynamic labels")
    func recordsAppendStageHistograms() async {
        let metrics = V2DirectRoomLogAppendStageMetrics()
        await withTaskGroup(of: Void.self) { group in
            for milliseconds in 1 ... 100 {
                group.addTask {
                    metrics.record(.transaction, milliseconds: UInt64(milliseconds))
                }
            }
        }
        metrics.record(.messagePersistence, duration: .milliseconds(12))

        let snapshot = metrics.snapshot()
        let transaction = snapshot.value(for: .transaction)
        #expect(transaction.samples == 100)
        #expect(transaction.sumMilliseconds == 5_050)
        #expect(transaction.maximumMilliseconds == 100)
        #expect(transaction.count(atOrBelow: .milliseconds32) == 32)
        #expect(transaction.count(atOrBelow: .milliseconds128) == 100)

        let persistence = snapshot.value(for: .messagePersistence)
        #expect(persistence.samples == 1)
        #expect(persistence.sumMilliseconds == 12)
        #expect(persistence.count(atOrBelow: .milliseconds8) == 0)
        #expect(persistence.count(atOrBelow: .milliseconds16) == 1)
    }

    @Test("event-loop lag uses the same bounded cumulative histogram")
    func recordsEventLoopLag() {
        let metrics = V2EventLoopLagMetrics()
        metrics.recordLag(milliseconds: 0)
        metrics.recordLag(milliseconds: 7)
        metrics.recordLag(milliseconds: 33)

        let snapshot = metrics.snapshot()
        #expect(snapshot.samples == 3)
        #expect(snapshot.sumMilliseconds == 40)
        #expect(snapshot.maximumMilliseconds == 33)
        #expect(snapshot.count(atOrBelow: .milliseconds1) == 1)
        #expect(snapshot.count(atOrBelow: .milliseconds8) == 2)
        #expect(snapshot.count(atOrBelow: .milliseconds32) == 2)
        #expect(snapshot.count(atOrBelow: .milliseconds64) == 3)
    }
}
