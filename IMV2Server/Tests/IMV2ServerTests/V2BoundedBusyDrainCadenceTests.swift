import IMV2ServerApplication
import IMV2ServerContracts
import IMV2Server
import IMV2ServerInfrastructure
import Testing

@Suite("Bounded busy-drain cadence")
struct V2BoundedBusyDrainCadenceTests {
    @Test("busy passes drain immediately and yield at the pass budget")
    func busyPassBudget() {
        var cadence = V2BoundedBusyDrainCadence(
            minimumIdleIntervalMilliseconds: 100,
            maximumIdleIntervalMilliseconds: 800,
            maximumConsecutiveBusyPasses: 3,
            maximumConsecutiveBusyDurationMilliseconds: 1_000
        )

        #expect(cadence.decisionAfterPass(
            didWork: true, passDuration: .milliseconds(10)
        ) == .continueImmediately)
        #expect(cadence.decisionAfterPass(
            didWork: true, passDuration: .milliseconds(10)
        ) == .continueImmediately)
        #expect(cadence.decisionAfterPass(
            didWork: true, passDuration: .milliseconds(10)
        ) == .yield)
        #expect(cadence.decisionAfterPass(
            didWork: true, passDuration: .milliseconds(10)
        ) == .continueImmediately)
    }

    @Test("busy wall-time budget yields independently of pass count")
    func busyDurationBudget() {
        var cadence = V2BoundedBusyDrainCadence(
            minimumIdleIntervalMilliseconds: 100,
            maximumConsecutiveBusyPasses: 100,
            maximumConsecutiveBusyDurationMilliseconds: 50
        )

        #expect(cadence.decisionAfterPass(
            didWork: true, passDuration: .milliseconds(30)
        ) == .continueImmediately)
        #expect(cadence.decisionAfterPass(
            didWork: true, passDuration: .milliseconds(20)
        ) == .yield)
    }

    @Test("empty passes retain capped backoff and work resets it")
    func idleBackoff() {
        var cadence = V2BoundedBusyDrainCadence(
            minimumIdleIntervalMilliseconds: 100,
            maximumIdleIntervalMilliseconds: 400,
            maximumConsecutiveBusyPasses: 4,
            maximumConsecutiveBusyDurationMilliseconds: 50
        )

        #expect(cadence.decisionAfterPass(
            didWork: false, passDuration: .milliseconds(1)
        ) == .sleep(.milliseconds(100)))
        #expect(cadence.decisionAfterPass(
            didWork: false, passDuration: .milliseconds(1)
        ) == .sleep(.milliseconds(200)))
        #expect(cadence.decisionAfterPass(
            didWork: true, passDuration: .milliseconds(1)
        ) == .continueImmediately)
        #expect(cadence.decisionAfterPass(
            didWork: false, passDuration: .milliseconds(1)
        ) == .sleep(.milliseconds(100)))
    }
}
