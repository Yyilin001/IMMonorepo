import Testing
@testable import IMV2LoadGeneratorSupport

struct V2LoadRoomLiveSequencesTests {
    @Test func laterBodyWaitsForItsMissingPredecessor() {
        var live = V2LoadRoomLiveSequences()
        #expect(live.receive(10, after: 7) == 7)
        #expect(live.receive(8, after: 7) == 8)
        #expect(live.applied(through: 8).cursor == 8)
        #expect(live.receive(9, after: 8) == 9)
        let drained = live.applied(through: 9)
        #expect(drained.cursor == 10 && drained.count == 1)
        #expect(live.pendingCount == 0)
    }
    @Test func ackAndBodyKnowledgeCloseAlternatingGaps() throws {
        var live = V2LoadRoomLiveSequences(), accepted = V2LoadRoomAcceptedSequences()
        _ = live.receive(10, after: 7)
        _ = try accepted.accepted(9, after: 7)
        let body = live.receive(8, after: 7)
        let ack = accepted.applied(through: body)
        #expect(live.applied(through: ack.cursor).cursor == 10)
    }
    @Test func overflowAndRecoveryNeverInventMissingBodies() {
        var live = V2LoadRoomLiveSequences(maximumPending: 2)
        _ = live.receive(3, after: 0); _ = live.receive(4, after: 0)
        _ = live.receive(5, after: 0)
        #expect(live.pendingCount == 2)
        #expect(live.receive(1, after: 0) == 1)
        #expect(live.applied(through: 2).cursor == 4)
        #expect(live.applied(through: 4).cursor == 4)
        #expect(live.applied(through: 9).cursor == 9)
        #expect(live.receive(3, after: 9) == 9)
    }
}
