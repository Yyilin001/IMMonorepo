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

    @Test("delivery concurrency scales gradually and sheds immediately for foreground pressure")
    func adaptiveDeliveryConcurrency() {
        var controller = V2AdaptiveFanoutDeliveryConcurrency(
            configuredMaximum: 8,
            foregroundSafeMaximum: 4,
            saturatedPassesBeforeScaleUp: 2
        )

        #expect(controller.concurrencyForPass(isIdle: false, foregroundQueued: 0) == 4)
        controller.observePass(
            selectedConcurrency: 4,
            claimedCount: 512,
            perLaneSaturationCount: 128,
            foregroundQueued: 0
        )
        #expect(controller.activeConcurrency == 4)
        controller.observePass(
            selectedConcurrency: 4,
            claimedCount: 512,
            perLaneSaturationCount: 128,
            foregroundQueued: 0
        )
        #expect(controller.activeConcurrency == 5)

        #expect(controller.concurrencyForPass(isIdle: true, foregroundQueued: 0) == 1)
        #expect(controller.activeConcurrency == 5)
        #expect(controller.concurrencyForPass(isIdle: false, foregroundQueued: 1) == 4)
        #expect(controller.activeConcurrency == 4)
    }

    @Test("delivery concurrency does not scale on sparse, idle-probe, or failed passes")
    func adaptiveDeliveryConcurrencyRejectsWeakEvidence() {
        var controller = V2AdaptiveFanoutDeliveryConcurrency(
            configuredMaximum: 6,
            foregroundSafeMaximum: 4,
            saturatedPassesBeforeScaleUp: 2
        )

        controller.observePass(
            selectedConcurrency: 4,
            claimedCount: 511,
            perLaneSaturationCount: 128,
            foregroundQueued: 0
        )
        controller.observePass(
            selectedConcurrency: 1,
            claimedCount: 128,
            perLaneSaturationCount: 128,
            foregroundQueued: 0
        )
        controller.observePass(
            selectedConcurrency: 4,
            claimedCount: 512,
            perLaneSaturationCount: 128,
            foregroundQueued: 0,
            failed: true
        )

        #expect(controller.activeConcurrency == 4)
    }

    @Test("delivery concurrency respects a deployment ceiling below the safe default")
    func adaptiveDeliveryConcurrencyRespectsSmallCeiling() {
        var controller = V2AdaptiveFanoutDeliveryConcurrency(configuredMaximum: 2)

        #expect(controller.activeConcurrency == 2)
        #expect(controller.concurrencyForPass(isIdle: false, foregroundQueued: 7) == 2)
    }
}
