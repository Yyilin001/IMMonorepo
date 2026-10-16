import Testing
@testable import IMV2LoadGeneratorSupport

struct V2LoadRoomAcceptedSequencesTests {
    @Test func outOfOrderReceiptsRemainKnownUntilTheirPredecessorArrives() throws {
        var tracker = V2LoadRoomAcceptedSequences()
        #expect(try tracker.accepted(2, after: 0).cursor == 0)
        #expect(try tracker.accepted(3, after: 0).cursor == 0)
        let result = try tracker.accepted(1, after: 0)
        #expect(result.cursor == 3)
        #expect(result.appliedAcceptedCount == 3)
    }
    @Test func peerBodyClosesOnlyKnownContiguousAcceptedPrefix() throws {
        var tracker = V2LoadRoomAcceptedSequences()
        #expect(try tracker.accepted(3, after: 0).cursor == 0)
        #expect(try tracker.accepted(5, after: 0).cursor == 0)
        #expect(tracker.applied(through: 1).cursor == 1)
        #expect(tracker.applied(through: 2).cursor == 3)
        #expect(tracker.applied(through: 4).cursor == 5)
    }
    @Test func duplicatesAndPageOvertakesNeverAdvanceAnUnknownSequence() throws {
        var tracker = V2LoadRoomAcceptedSequences()
        _ = try tracker.accepted(3, after: 0)
        _ = try tracker.accepted(3, after: 0)
        #expect(tracker.applied(through: 8).cursor == 8)
        #expect(try tracker.accepted(3, after: 8).appliedAcceptedCount == 0)
        #expect(tracker.applied(through: 8).cursor == 8)
    }
    @Test func boundedBufferAcceptsItsMissingPredecessorEvenWhenFull() throws {
        var tracker = V2LoadRoomAcceptedSequences(maximumPending: 2)
        _ = try tracker.accepted(2, after: 0)
        _ = try tracker.accepted(3, after: 0)
        #expect(throws: V2LoadRoomAcceptedSequences.Failure.capacityExceeded) {
            _ = try tracker.accepted(4, after: 0)
        }
        #expect(try tracker.accepted(1, after: 0).cursor == 3)
    }
}
