import IMV2Server
import Testing

@Suite("Adaptive durable-worker cadence")
struct V2AdaptiveWorkerCadenceTests {
    @Test("backs off empty passes, caps delay, and resets immediately after work")
    func backoffAndReset() {
        var cadence = V2AdaptiveWorkerCadence(
            minimumIntervalMilliseconds: 100,
            maximumIdleIntervalMilliseconds: 800
        )

        #expect(cadence.isIdle == false)
        #expect(cadence.claimLimit(configuredLimit: 256) == 256)
        #expect(cadence.delayAfterPass(didWork: false) == .milliseconds(100))
        #expect(cadence.isIdle)
        #expect(cadence.claimLimit(configuredLimit: 256) == 1)
        #expect(cadence.delayAfterPass(didWork: false) == .milliseconds(200))
        #expect(cadence.delayAfterPass(didWork: false) == .milliseconds(400))
        #expect(cadence.delayAfterPass(didWork: false) == .milliseconds(800))
        #expect(cadence.delayAfterPass(didWork: false) == .milliseconds(800))
        #expect(cadence.delayAfterPass(didWork: true) == .milliseconds(100))
        #expect(cadence.isIdle == false)
        #expect(cadence.claimLimit(configuredLimit: 256) == 256)
    }
}
