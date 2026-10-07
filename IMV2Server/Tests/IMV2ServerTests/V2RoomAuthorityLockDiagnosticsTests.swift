import Testing
@testable import IMV2ServerGateway

struct V2RoomAuthorityLockDiagnosticsTests {
    @Test("authority diagnostic separates waiting from holding and clamps invalid durations")
    func totals() {
        let recorder = V2RoomAuthorityLockDiagnostics()
        recorder.record(operation: "enqueueIfCurrent", wait: .milliseconds(2), held: .milliseconds(3))
        recorder.record(operation: "enqueueIfCurrent", wait: .milliseconds(4), held: .milliseconds(1))
        recorder.record(operation: "apply", wait: .milliseconds(-1), held: .milliseconds(-2))
        let totals = recorder.snapshot()
        #expect(totals["enqueueIfCurrent"]?.count == 2)
        #expect(totals["enqueueIfCurrent"]?.waitMilliseconds == 6)
        #expect(totals["enqueueIfCurrent"]?.heldMilliseconds == 4)
        #expect(totals["enqueueIfCurrent"]?.maximumWaitMilliseconds == 4)
        #expect(totals["enqueueIfCurrent"]?.maximumHeldMilliseconds == 3)
        #expect(totals["apply"]?.waitMilliseconds == 0 && totals["apply"]?.heldMilliseconds == 0)
    }
}
