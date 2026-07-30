import Foundation
@testable import IMV2ClientKit
import Testing

@Suite("V2 fair durable command scheduler")
struct V2FairDurableCommandSchedulerTests {
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
