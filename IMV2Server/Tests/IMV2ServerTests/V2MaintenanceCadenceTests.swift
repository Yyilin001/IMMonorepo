import Foundation
@testable import IMV2Server
import Testing

@Suite("V2 maintenance cadence")
struct V2MaintenanceCadenceTests {
    @Test("a new worker runs maintenance immediately then only at the configured deadline")
    func schedulesBoundedMaintenanceWithoutFollowingRealtimePollRate() throws {
        let cadence = try V2MaintenanceCadence(intervalMilliseconds: 60_000)
        let start = Date(timeIntervalSince1970: 1_750_300_000)
        let next = cadence.nextScheduledAt(after: start)

        #expect(cadence.isDue(now: start, nextScheduledAt: nil))
        #expect(!cadence.isDue(now: start.addingTimeInterval(59.999), nextScheduledAt: next))
        #expect(cadence.isDue(now: next, nextScheduledAt: next))
    }

    @Test("maintenance cadence rejects a nonpositive interval")
    func rejectsInvalidInterval() {
        #expect(throws: V2MaintenanceCadenceError.invalidInterval) {
            _ = try V2MaintenanceCadence(intervalMilliseconds: 0)
        }
    }
}
