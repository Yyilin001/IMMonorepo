import Testing
@testable import IMV2ServerApplication

@Suite("Durable send operation metrics")
struct V2SendOperationBatchMetricsTests {
    @Test("physical owners aggregate actual durable turn sizes and completion outcomes")
    func durableTurnMetrics() {
        let first = V2SendOperationBatchMetrics(), second = V2SendOperationBatchMetrics()
        first.begin(commandCount: 3)
        second.begin(commandCount: 1)
        let aggregate = V2AggregatedSendOperationBatchMetrics(owners: [first, second])
        #expect(aggregate.sendOperationBatchMetricsSnapshot().inFlightBatches == 2)
        first.finish(commandCount: 3, outcome: .committed, duration: .milliseconds(12))
        second.finish(commandCount: 1, outcome: .outcomeUnknown, duration: .milliseconds(5))
        first.begin(commandCount: 2)
        first.finish(commandCount: 2, outcome: .rolledBack, duration: .milliseconds(2))
        let result = aggregate.sendOperationBatchMetricsSnapshot()
        #expect(result.inFlightBatches == 0)
        #expect(result.attemptedBatches == 3 && result.submittedCommands == 6)
        #expect(result.committedBatches == 1 && result.committedCommands == 3)
        #expect(result.rolledBackBatches == 1 && result.outcomeUnknownBatches == 1)
        #expect(result.singletonBatches == 1 && result.largestBatch == 3)
        #expect(result.executionMillisecondsTotal == 19 && result.executionMillisecondsMax == 12)
    }
}
