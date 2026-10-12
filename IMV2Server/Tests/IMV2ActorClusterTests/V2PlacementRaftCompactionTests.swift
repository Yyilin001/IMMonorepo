import Foundation
import IMV2ActorContracts
import Testing
@testable import IMV2ActorCluster

@Suite("Raft absolute indexes survive local prefix compaction")
struct V2PlacementRaftCompactionTests {
    @Test("Restart, old receipts, uncommitted suffix and next-term election survive two checkpoints")
    func restartAndElection() throws {
        let a = V2ActorHostID(uuid: UUID()), b = V2ActorHostID(uuid: UUID()), c = V2ActorHostID(uuid: UUID())
        let group = UUID(), roster: Set<V2ActorHostID> = [a, b, c]
        let host = V2ActorHostIdentity(hostID: a, incarnationID: UUID())
        let initial = try V2ActorPlacementSnapshot(clusterID: group, revision: 1,
            slots: [.init(owner: .init(host: host, epoch: 1), transfer: nil)])
        let retireID = UUID(), retire = V2ActorPlacementCommand.retireHost(host)
        var state = try V2PlacementRaftPersistentState(groupID: group, voterID: a, voters: roster, term: 1,
            log: [.init(term: 1, payload: V2PlacementRaftApplication.encode(.bootstrap(initial))),
                  .init(term: 1, payload: V2PlacementRaftApplication.encode(.command(retire, expected: initial, requestID: retireID))),
                  .init(term: 1, payload: Data())], commitIndex: 3)
        var application = V2PlacementRaftApplication(groupID: group); try application.apply(state)
        let retired = try #require(application.snapshot), registerID = UUID()
        let successor = V2ActorHostIdentity(hostID: a, incarnationID: UUID())
        let register = V2ActorPlacementCommand.registerHost(previous: host, successor: successor)
        state.log.append(try .init(term: 1, payload: V2PlacementRaftApplication.encode(.command(register, expected: retired, requestID: registerID))))
        var core = try V2PlacementRaftCore(id: a, groupID: group, voters: roster, persisted: state)
        try core.compact(application.checkpoint(), through: 3)
        #expect(core.state.baseIndex == 3 && core.lastIndex == 4 && core.state.log.count == 1 && core.state.commitIndex == 3)
        try state.validateLocalSuccessor(core.state)
        #expect(try V2PlacementRaftProtobuf.decodeFile(V2PlacementRaftProtobuf.encodeFile(core.state)) == core.state)
        try application.apply(core.state)
        #expect(application.snapshot == retired && application.appliedIndex == 3)
        #expect(try application.receipt(for: retire, requestID: retireID) == retired)
        var reopened = V2PlacementRaftApplication(groupID: group); try reopened.apply(core.state)
        #expect(reopened.snapshot == retired)
        #expect(try reopened.result(at: 4) == nil)
        let other = V2PlacementRaftPersistentState(groupID: group, voterID: b, voters: roster, term: 1,
            log: core.state.log, commitIndex: 3, snapshot: core.state.snapshot)
        var follower = try V2PlacementRaftCore(id: b, groupID: group, voters: roster, persisted: other)
        core = try .init(id: a, groupID: group, voters: roster, persisted: core.state)
        let campaign = try core.campaign()
        #expect(campaign.lastIndex == 4 && campaign.lastTerm == 1)
        try core.receivedVote(follower.vote(campaign, from: a), from: b)
        let request = try core.appendRequest(to: b)
        #expect(request.previousIndex == 4 && request.previousTerm == 1 && request.entries.count == 1)
        try core.receivedAppend(follower.append(request, from: a), from: b, for: request)
        #expect(core.state.commitIndex == 5 && core.lastIndex == 5)
        try reopened.apply(core.state)
        let registered = try #require(reopened.snapshot)
        #expect(registered.revision == 3 && registered.slots[0].owner.host == successor)
        #expect(try reopened.receipt(for: retire, requestID: retireID) == retired)
        #expect(try reopened.receipt(for: register, requestID: registerID) == registered)
        let old = core.state
        try core.compact(reopened.checkpoint(), through: 5)
        try old.validateLocalSuccessor(core.state)
        try reopened.apply(core.state)
        #expect(core.state.log.isEmpty && core.lastIndex == 5 && core.state.baseIndex == 5)
        let heartbeat = try core.appendRequest(to: b)
        #expect(heartbeat.previousIndex == 5 && heartbeat.previousTerm == 2 && heartbeat.entries.isEmpty)
        #expect(try follower.append(heartbeat, from: a).accepted)
        var final = V2PlacementRaftApplication(groupID: group); try final.apply(core.state)
        #expect(final.snapshot == registered && final.appliedIndex == 5)
        #expect(try final.receipt(for: retire, requestID: retireID) == retired)
    }

    @Test("Storage rejects a forged checkpoint and committed overlap rewrites")
    func forgedCheckpoint() throws {
        let a = V2ActorHostID(uuid: UUID()), group = UUID(), roster: Set<V2ActorHostID> = [a, .init(uuid: UUID()), .init(uuid: UUID())]
        let initial = try V2ActorPlacementSnapshot(clusterID: group, revision: 1,
            slots: [.init(owner: .init(host: .init(hostID: a, incarnationID: UUID()), epoch: 1), transfer: nil)])
        let state = try V2PlacementRaftPersistentState(groupID: group, voterID: a, voters: roster, term: 1,
            log: [.init(term: 1, payload: V2PlacementRaftApplication.encode(.bootstrap(initial))), .init(term: 1, payload: Data())], commitIndex: 2)
        var app = V2PlacementRaftApplication(groupID: group); try app.apply(state)
        var core = try V2PlacementRaftCore(id: a, groupID: group, voters: roster, persisted: state)
        #expect(throws: V2PlacementRaftError.invalidState) { try core.compact(app.checkpoint(), through: 1) }
        var wrong = state
        let forgedInitial = try V2ActorPlacementSnapshot(clusterID: group, revision: 1,
            slots: [.init(owner: .init(host: .init(hostID: a, incarnationID: UUID()), epoch: 1), transfer: nil)])
        wrong.log = []
        wrong.snapshot = try .init(index: 2, term: 1, application:
            V2PlacementRaftCheckpoint(groupID: group, appliedIndex: 2, genesis: forgedInitial, receipts: []).encode())
        #expect(throws: V2PlacementRaftError.invalidState) { try state.validateLocalSuccessor(wrong) }
        #expect(throws: V2PlacementRaftError.invalidState) { try app.apply(wrong) }
        #expect(app.snapshot == initial && app.appliedIndex == 2)
        wrong = state; wrong.log[0] = .init(term: 1, payload: Data())
        #expect(throws: V2PlacementRaftError.invalidState) { try state.validateLocalSuccessor(wrong) }
    }
}
