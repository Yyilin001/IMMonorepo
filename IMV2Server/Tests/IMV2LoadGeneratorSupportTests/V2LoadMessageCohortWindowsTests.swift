import Testing
import IMV2LoadGeneratorSupport

struct V2LoadMessageCohortWindowsTests {
    @Test func lateAcknowledgementKeepsOriginalPhaseAcrossQueueAndReconnect() throws {
        var windows = V2LoadMessageCohortWindows()
        try windows.register(name: "warmup", start: 100, end: 200)
        try windows.register(name: "measurement", start: 220, end: 300)
        let retainedScheduledTime: UInt64 = 199
        #expect(windows.cohort(scheduledAt: retainedScheduledTime) == "warmup")
        #expect(windows.cohort(scheduledAt: 220) == "measurement")
        #expect(windows.cohort(scheduledAt: 299) == "measurement")
        #expect(windows.cohort(scheduledAt: 99) == nil)
        #expect(windows.cohort(scheduledAt: 200) == nil)
        #expect(windows.cohort(scheduledAt: 300) == nil)
    }
    @Test func rejectsAmbiguousOrOverlappingPhases() throws {
        var windows = V2LoadMessageCohortWindows()
        try windows.register(name: "measurement", start: 100, end: 200)
        #expect(throws: V2LoadMessageCohortWindows.Failure.invalidWindow) {
            try windows.register(name: "other", start: 199, end: 300)
        }
        #expect(throws: V2LoadMessageCohortWindows.Failure.invalidWindow) {
            try windows.register(name: "measurement", start: 200, end: 300)
        }
    }
}
