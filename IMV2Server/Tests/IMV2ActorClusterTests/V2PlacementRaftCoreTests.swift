import Foundation
import IMV2ActorContracts
import Testing
@testable import IMV2ActorCluster

@Suite("Fixed three-voter placement Raft transitions")
struct V2PlacementRaftCoreTests {
    private let a = V2ActorHostID(uuid: UUID()), b = V2ActorHostID(uuid: UUID()), c = V2ActorHostID(uuid: UUID())
    private let group = UUID()
    private var roster: Set<V2ActorHostID> { [a, b, c] }
    private func core(_ id: V2ActorHostID, term: UInt64 = 0, log: [V2PlacementRaftEntry] = [], commit: UInt64 = 0) throws -> V2PlacementRaftCore {
        try .init(id: id, groupID: group, voters: roster,
            persisted: .init(groupID: group, voterID: id, voters: roster, term: term, log: log, commitIndex: commit))
    }
    private func entry(_ term: UInt64, _ text: String) -> V2PlacementRaftEntry { .init(term: term, payload: Data(text.utf8)) }
    private func elect(_ leader: inout V2PlacementRaftCore, _ follower: inout V2PlacementRaftCore) throws {
        let request = try leader.campaign()
        try leader.receivedVote(follower.vote(request, from: leader.id), from: follower.id)
    }
    private func replicate(_ leader: inout V2PlacementRaftCore, _ follower: inout V2PlacementRaftCore,
                           limit: Int = 16, read: UUID? = nil) throws {
        let request = try leader.appendRequest(to: follower.id, maximumEntries: limit, readID: read)
        let reply = try follower.append(request, from: leader.id)
        try leader.receivedAppend(reply, from: follower.id, for: request)
    }

    @Test("Replication bounds bytes as well as count and eventually copies every large entry")
    func replicationPacketBudget() throws {
        var leader = try core(a), follower = try core(b)
        try elect(&leader, &follower)
        let payload = Data(repeating: 42, count: V2PlacementRaftCore.maximumPayloadBytes)
        _ = try leader.propose(payload); _ = try leader.propose(payload)
        let first = try leader.appendRequest(to: b)
        #expect(first.entries.count == 2)
        let packet = try V2PlacementRaftWireCodec.encode(.append(first), shard: "room-a")
        #expect(packet.isBounded)
        #expect(try V2PlacementRaftWireCodec.decodeRequest(packet) == .append(first))
        try leader.receivedAppend(follower.append(first, from: a), from: b, for: first)
        let second = try leader.appendRequest(to: b)
        #expect(second.entries.count == 1)
        #expect(try V2PlacementRaftWireCodec.encode(.append(second), shard: "room-a").isBounded)
        try replicate(&leader, &follower)
        #expect(leader.state.commitIndex == 3)
        #expect(follower.state.log == leader.state.log)
    }

    @Test("Bootstrap rejects another group, roster, self and corrupt durable prefixes")
    func bootstrap() throws {
        let state = V2PlacementRaftPersistentState(groupID: group, voterID: c, voters: roster)
        #expect(throws: V2PlacementRaftError.invalidConfiguration) {
            try V2PlacementRaftCore(id: a, groupID: group, voters: [a, b], persisted: state)
        }
        #expect(throws: V2PlacementRaftError.invalidConfiguration) {
            try V2PlacementRaftCore(id: .init(uuid: UUID()), groupID: group, voters: roster, persisted: state)
        }
        #expect(throws: V2PlacementRaftError.invalidState) {
            try V2PlacementRaftCore(id: a, groupID: UUID(), voters: roster, persisted: state)
        }
        for damaged in [
            V2PlacementRaftPersistentState(groupID: group, voterID: c, voters: roster, term: 0, votedFor: a),
            .init(groupID: group, voterID: c, voters: roster, term: 1, log: [entry(2, "future")]),
            .init(groupID: group, voterID: c, voters: roster, term: 2, log: [entry(2, "a"), entry(1, "b")]),
            .init(groupID: group, voterID: c, voters: roster, term: 1, commitIndex: 1)
        ] {
            #expect(throws: V2PlacementRaftError.invalidState) {
                try V2PlacementRaftCore(id: c, groupID: group, voters: roster, persisted: damaged)
            }
        }
    }

    @Test("A voter cannot grant two candidates in one term; restart retains its promise")
    func exclusiveVote() throws {
        var follower = try core(c)
        let first = V2PlacementRaftVoteRequest(groupID: group, candidate: a, term: 1, lastIndex: 0, lastTerm: 0)
        let second = V2PlacementRaftVoteRequest(groupID: group, candidate: b, term: 1, lastIndex: 0, lastTerm: 0)
        #expect(try follower.vote(first, from: a).granted)
        #expect(try follower.vote(first, from: a).granted)
        var restarted = try V2PlacementRaftCore(id: c, groupID: group, voters: roster, persisted: follower.state)
        #expect(try !restarted.vote(second, from: b).granted)
        #expect(try restarted.vote(.init(groupID: group, candidate: b, term: 2, lastIndex: 0, lastTerm: 0), from: b).granted)
        #expect(try !restarted.vote(first, from: a).granted)
    }

    @Test("Log freshness compares last term before last index",
          arguments: [(UInt64(2), UInt64(2), false), (1, 3, false), (2, 3, true), (1, 4, true)])
    func electionFreshness(_ value: (UInt64, UInt64, Bool)) throws {
        var follower = try core(c, term: 4, log: [entry(1, "a"), entry(3, "b")])
        #expect(try follower.vote(.init(groupID: group, candidate: a, term: 5,
            lastIndex: value.0, lastTerm: value.1), from: a).granted == value.2)
    }

    @Test("One node cannot commit; two durable replicas suffice without the third")
    func majority() throws {
        var leader = try core(a), follower = try core(b)
        let request = try leader.campaign()
        #expect(leader.role == .candidate && leader.state.commitIndex == 0)
        try leader.receivedVote(follower.vote(request, from: a), from: b)
        #expect(leader.role == .leader && leader.lastIndex == 1 && leader.state.commitIndex == 0)
        #expect(throws: V2PlacementRaftError.notReady) { try leader.beginRead() }
        try replicate(&leader, &follower)
        #expect(leader.state.commitIndex == 1)
        let index = try leader.propose(Data("placement".utf8))
        #expect(index == 2 && leader.state.commitIndex == 1)
        try replicate(&leader, &follower)
        #expect(leader.state.commitIndex == 2)
        try replicate(&leader, &follower)
        #expect(follower.state.commitIndex == 2)
    }

    @Test("A majority holding only an old-term entry does not certify its commit")
    func oldTermCannotCommitDirectly() throws {
        var leader = try core(a, term: 2, log: [entry(2, "old")]), follower = try core(b)
        try elect(&leader, &follower)
        try replicate(&leader, &follower) // Backtrack: follower lacks previous index 1.
        try replicate(&leader, &follower, limit: 1) // Only old-term index 1 reaches the majority.
        #expect(follower.lastIndex == 1 && leader.state.commitIndex == 0)
        #expect(throws: V2PlacementRaftError.notReady) { try leader.beginRead() }
        try replicate(&leader, &follower)
        #expect(leader.state.commitIndex == 2)
    }

    @Test("Conflicting uncommitted tails are replaced; committed or equal-term conflicts are rejected")
    func logRepair() throws {
        let original = [entry(1, "a"), entry(2, "b"), entry(2, "c")]
        var follower = try core(c, term: 3, log: original, commit: 1)
        let rejected = try follower.append(.init(groupID: group, leader: a, term: 4,
            previousIndex: 0, previousTerm: 0, entries: [entry(4, "wrong")], leaderCommit: 1, readID: nil), from: a)
        #expect(!rejected.accepted && follower.state.log == original && follower.state.commitIndex == 1)
        #expect(try !follower.append(.init(groupID: group, leader: a, term: 4,
            previousIndex: 1, previousTerm: 1, entries: [entry(2, "equivocation")], leaderCommit: 2, readID: nil), from: a).accepted)
        let repaired = try follower.append(.init(groupID: group, leader: a, term: 4,
            previousIndex: 1, previousTerm: 1, entries: [entry(4, "new")], leaderCommit: 3, readID: nil), from: a)
        #expect(repaired.accepted && repaired.matchedIndex == 2)
        #expect(follower.state.log == [entry(1, "a"), entry(4, "new")] && follower.state.commitIndex == 2)
    }

    @Test("A heartbeat cannot commit an unverified local suffix")
    func heartbeatBound() throws {
        var follower = try core(c, term: 3, log: [entry(1, "known"), entry(2, "unknown")])
        #expect(try follower.append(.init(groupID: group, leader: a, term: 3,
            previousIndex: 1, previousTerm: 1, entries: [], leaderCommit: 2, readID: nil), from: a).matchedIndex == 1)
        #expect(follower.state.commitIndex == 1 && follower.lastIndex == 2)
    }

    @Test("A delayed failed append does not undo a newer successful match")
    func reorderedReplies() throws {
        var leader = try core(a), follower = try core(b)
        try elect(&leader, &follower)
        let old = try leader.appendRequest(to: b)
        try replicate(&leader, &follower)
        _ = try leader.propose(Data("next".utf8))
        try replicate(&leader, &follower)
        try leader.receivedAppend(.init(groupID: group, term: leader.state.term, accepted: false,
            matchedIndex: 0, readID: nil), from: b, for: old)
        #expect(try leader.appendRequest(to: b).previousIndex == 2)
    }

    @Test("A read needs a new majority round and is revoked by a higher term")
    func linearizableRead() throws {
        var leader = try core(a), follower = try core(b)
        try elect(&leader, &follower)
        let priorRequest = try leader.appendRequest(to: b), priorReply = try follower.append(priorRequest, from: a)
        try leader.receivedAppend(priorReply, from: b, for: priorRequest)
        let read = try leader.beginRead()
        #expect(leader.confirmedRead(read) == nil)
        try leader.receivedAppend(priorReply, from: b, for: priorRequest)
        #expect(leader.confirmedRead(read) == nil)
        try replicate(&leader, &follower, read: read)
        #expect(leader.confirmedRead(read) == 1)
        let nextRead = try leader.beginRead(), request = try leader.appendRequest(to: c, readID: nextRead)
        try leader.receivedAppend(.init(groupID: group, term: 2, accepted: false,
            matchedIndex: 0, readID: nextRead), from: c, for: request)
        #expect(leader.role == .follower && leader.state.term == 2)
        #expect(leader.confirmedRead(read) == nil && leader.confirmedRead(nextRead) == nil)
        #expect(throws: V2PlacementRaftError.notLeader) { try leader.propose(Data([1])) }
    }

    @Test("Unknown voters, another group and malformed indices cannot advance a term")
    func invalidInputs() throws {
        var follower = try core(c), initial = follower.state
        #expect(throws: V2PlacementRaftError.unauthorizedVoter) {
            let stranger = V2ActorHostID(uuid: UUID())
            try follower.vote(.init(groupID: group, candidate: stranger, term: 100, lastIndex: 0, lastTerm: 0), from: stranger)
        }
        #expect(throws: V2PlacementRaftError.wrongGroup) {
            try follower.vote(.init(groupID: UUID(), candidate: a, term: 100, lastIndex: 0, lastTerm: 0), from: a)
        }
        #expect(throws: V2PlacementRaftError.invalidMessage) {
            try follower.append(.init(groupID: group, leader: a, term: 100, previousIndex: .max,
                previousTerm: 1, entries: [entry(100, "bad")], leaderCommit: 1, readID: nil), from: a)
        }
        #expect(follower.state == initial)
    }
}
