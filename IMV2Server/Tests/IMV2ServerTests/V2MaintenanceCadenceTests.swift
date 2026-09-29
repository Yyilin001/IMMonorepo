@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 maintenance cadence")
struct V2MaintenanceCadenceTests {
    @Test("a new worker runs maintenance immediately then only at the monotonic deadline")
    func schedulesBoundedMaintenanceWithoutFollowingRealtimePollRate() throws {
        let cadence = try V2MaintenanceCadence(intervalMilliseconds: 60_000)
        let start = ContinuousClock.now
        let next = cadence.nextScheduledAt(after: start)

        #expect(cadence.isDue(now: start, nextScheduledAt: nil))
        #expect(!cadence.isDue(now: next.advanced(by: .nanoseconds(-1)), nextScheduledAt: next))
        #expect(cadence.isDue(now: next, nextScheduledAt: next))
    }

    @Test("maintenance intervals retain exact milliseconds without floating-point conversion", arguments: [1, 60_000, Int.max])
    func exactIntervalBounds(milliseconds: Int) throws {
        let cadence = try V2MaintenanceCadence(intervalMilliseconds: milliseconds)
        let start = ContinuousClock.now
        let next = cadence.nextScheduledAt(after: start)
        #expect(start.duration(to: next) == .milliseconds(milliseconds))
        #expect(!cadence.isDue(now: start, nextScheduledAt: next))
        #expect(!cadence.isDue(now: next.advanced(by: .nanoseconds(-1)), nextScheduledAt: next))
        #expect(cadence.isDue(now: next, nextScheduledAt: next))
    }

    @Test("a delayed pass schedules from its actual start without replaying missed intervals")
    func delayedPassDoesNotCatchUpMissedIntervals() throws {
        let cadence = try V2MaintenanceCadence(intervalMilliseconds: 60_000)
        let start = ContinuousClock.now
        let originalDeadline = cadence.nextScheduledAt(after: start)
        let delayedStart = start.advanced(by: .seconds(185))
        #expect(cadence.isDue(now: delayedStart, nextScheduledAt: originalDeadline))
        let next = cadence.nextScheduledAt(after: delayedStart)
        #expect(next == start.advanced(by: .seconds(245)))
        #expect(!cadence.isDue(now: delayedStart, nextScheduledAt: next))
        #expect(!cadence.isDue(now: start.advanced(by: .seconds(240)), nextScheduledAt: next))
        #expect(cadence.isDue(now: next, nextScheduledAt: next))
    }

    @Test("maintenance cadence rejects nonpositive intervals", arguments: [Int.min, -1, 0])
    func rejectsInvalidInterval(milliseconds: Int) {
        #expect(throws: V2MaintenanceCadenceError.invalidInterval) {
            _ = try V2MaintenanceCadence(intervalMilliseconds: milliseconds)
        }
    }
}
