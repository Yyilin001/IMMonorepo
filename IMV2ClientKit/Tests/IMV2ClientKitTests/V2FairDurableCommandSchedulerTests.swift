import Foundation
@testable import IMV2ClientKit
import Testing

@Suite("V2 fair durable command scheduler")
struct V2FairDurableCommandSchedulerTests {
    @Test("bounded batches retain their position across flush calls", arguments: [1, 2, 4])
    func partialBatchesDoNotRestartAtFirstLane(budget: Int) async throws {
        let trace = SchedulerTrace()
        let scheduler = V2FairDurableCommandScheduler(lanes: [
            .init { await trace.append("messages"); return true },
            .init { await trace.append("withdrawal"); return true },
            .init { await trace.append("receipts"); return true },
        ])
        for _ in 0..<3 {
            #expect(try await scheduler.flush(maximumWorkItems: budget) == budget)
        }
        let expected = (0..<(budget * 3)).map { ["messages", "withdrawal", "receipts"][$0 % 3] }
        #expect(await trace.values() == expected)
    }

    @Test("a busy lane cannot starve a later control lane")
    func busyLaneDoesNotStarveLaterLane() async throws {
        let trace = SchedulerTrace()
        let scheduler = V2FairDurableCommandScheduler(lanes: [
            .init { await trace.append("messages"); return true },
            .init { await trace.append("withdrawal"); return true },
            .init { await trace.append("receipts"); return false },
        ])
        #expect(try await scheduler.flush(maximumWorkItems: 4) == 4)
        #expect(await trace.values() == ["messages", "withdrawal", "receipts", "messages", "withdrawal"])
    }
}

private actor SchedulerTrace {
    private var entries: [String] = []
    func append(_ value: String) { entries.append(value) }
    func values() -> [String] { entries }
}
