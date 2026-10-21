import Foundation
import Testing
@testable import IMV2LoadGeneratorSupport

struct V2LoadVisibilityObservationTests {
    let domain = UUID(), run = UUID()
    func stamp(at time: UInt64 = 1_000_000) -> V2LoadVisibilityStamp {
        V2LoadVisibilityStamp(clockDomain: domain, runID: run, scheduledNanoseconds: time, cohort: "measured")!
    }
    @Test func payloadKeepsSizeAndRejectsMalformedMetadata() {
        let original = stamp(), text = original.text(byteCount: 128)!
        #expect(text.utf8.count == 128)
        #expect(V2LoadVisibilityStamp(text: text) == original)
        #expect(original.text(byteCount: 16) == nil)
        #expect(V2LoadVisibilityStamp(text: text + "!") == nil)
        #expect(V2LoadVisibilityStamp(clockDomain: domain, runID: run,
            scheduledNanoseconds: 1, cohort: "bad|phase") == nil)
    }
    @Test func laterBodyWaitsForContiguousApplicationAndCountsOnlyOnce() {
        var observed = V2LoadVisibilityObservation(clockDomain: domain, runID: run)
        #expect(observed.remember(stamp(), sequence: 3, after: 0, at: 2_000_000, source: .realtimePush) == .remembered)
        #expect(observed.remember(stamp(), sequence: 3, after: 0, at: 4_000_000, source: .recoveryPage) == .duplicate)
        #expect(observed.applied(through: 1, at: 2_000_000).samples.isEmpty)
        let applied = observed.applied(through: 3, at: 5_000_000)
        #expect(applied.samples.count == 1 && applied.samples[0].milliseconds == 4)
        #expect(applied.samples[0].cohort == "measured")
        #expect(applied.samples[0].sequence == 3)
        #expect(applied.samples[0].receivedNanoseconds == 2_000_000)
        #expect(applied.samples[0].bodySource == .realtimePush)
        #expect(applied.samples[0].appliedNanoseconds == 5_000_000)
        #expect(applied.samples[0].bodyArrivalMilliseconds == 1)
        #expect(applied.samples[0].contiguousApplicationWaitMilliseconds == 3)
        #expect(observed.applied(through: 3, at: 6_000_000).samples.isEmpty)
        #expect(observed.remember(stamp(), sequence: 3, after: 3, at: 6_000_000, source: .realtimePush) == .alreadyApplied)
    }
    @Test func requiresPeerMessageBodyAndMatchingRoomSequence() throws {
        let room = UUID(), sender = UUID(), receiver = UUID()
        let payload = try JSONSerialization.data(withJSONObject: [
            "event_type": "message.accepted", "room_id": room.uuidString,
            "room_sequence": 3, "sender_user_id": sender.uuidString,
            "text": stamp().text(byteCount: 128)!])
        #expect(V2LoadVisibilityStamp.fromMessagePayload(payload, roomID: room.uuidString,
            sequence: 3, excludingSender: receiver.uuidString) == stamp())
        #expect(V2LoadVisibilityStamp.fromMessagePayload(payload, roomID: room.uuidString,
            sequence: 3, excludingSender: sender.uuidString) == nil)
        #expect(V2LoadVisibilityStamp.fromMessagePayload(payload, roomID: room.uuidString,
            sequence: 4, excludingSender: receiver.uuidString) == nil)
        #expect(V2LoadVisibilityStamp.fromMessagePayload(payload, roomID: UUID().uuidString,
            sequence: 3, excludingSender: receiver.uuidString) == nil)
    }
    @Test func clocksAndHistoryCannotPolluteTheCurrentRun() {
        var observed = V2LoadVisibilityObservation(clockDomain: domain, runID: run)
        let otherClock = V2LoadVisibilityStamp(clockDomain: UUID(), runID: run, scheduledNanoseconds: 1, cohort: "measured")!
        let oldRun = V2LoadVisibilityStamp(clockDomain: domain, runID: UUID(), scheduledNanoseconds: 1, cohort: "measured")!
        #expect(observed.remember(otherClock, sequence: 1, after: 0, at: 2_000_000, source: .realtimePush) == .foreignClock)
        #expect(observed.remember(oldRun, sequence: 1, after: 0, at: 2_000_000, source: .realtimePush) == .foreignRun)
        #expect(observed.pendingCount == 0)
        #expect(observed.remember(stamp(), sequence: 1, after: 0, at: 2_000_000, source: .realtimePush) == .remembered)
        let applied = observed.applied(through: 1, at: 0)
        #expect(applied.samples.isEmpty && applied.invalidClockSamples == 1)
    }
    @Test func boundedObservationReportsLossWithoutInventingSamples() {
        var observed = V2LoadVisibilityObservation(clockDomain: domain, runID: run, maximumPending: 1)
        #expect(observed.remember(stamp(), sequence: 2, after: 0, at: 2_000_000, source: .realtimePush) == .remembered)
        #expect(observed.remember(stamp(at: 2), sequence: 2, after: 0, at: 2_000_000, source: .realtimePush) == .conflictingBody)
        #expect(observed.remember(stamp(), sequence: 3, after: 0, at: 2_000_000, source: .realtimePush) == .capacityExceeded)
        #expect(observed.applied(through: 3, at: 2_000_000).samples.count == 1)
    }
    @Test func arrivalBeforeScheduledTimeIsRejectedEvenWhenApplicationTimeIsValid() {
        var observed = V2LoadVisibilityObservation(clockDomain: domain, runID: run)
        #expect(observed.remember(stamp(), sequence: 1, after: 0, at: 500_000, source: .realtimePush) == .remembered)
        let applied = observed.applied(through: 1, at: 5_000_000)
        #expect(applied.samples.isEmpty)
        #expect(applied.invalidClockSamples == 1)
        #expect(observed.pendingCount == 0)
    }
    @Test func firstRecoveryBodyKeepsItsSourceWhenRealtimeDuplicateArrives() throws {
        var observed = V2LoadVisibilityObservation(clockDomain: domain, runID: run)
        #expect(observed.remember(stamp(), sequence: 1, after: 0, at: 2_000_000,
            source: .recoveryPage) == .remembered)
        #expect(observed.remember(stamp(), sequence: 1, after: 0, at: 3_000_000,
            source: .realtimePush) == .duplicate)
        let sample = try #require(observed.applied(through: 1, at: 4_000_000).samples.first)
        #expect(sample.bodySource == .recoveryPage)
        #expect(sample.receivedNanoseconds == 2_000_000)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        #expect(encoded["bodySource"] as? String == "recoveryPage")
    }
}
