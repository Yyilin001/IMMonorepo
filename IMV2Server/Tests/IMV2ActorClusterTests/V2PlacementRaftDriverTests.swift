import Foundation
import IMV2ActorContracts
import Testing
@testable import IMV2ActorCluster

@Suite("Raft lifecycle automatically elects and replicates")
struct V2PlacementRaftDriverTests {
    private func wait(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw V2PlacementRaftError.notReady }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    @Test("Three running voters elect, certify barriers and recover after a leader partition")
    func automaticElectionAndPartition() async throws {
        let ids = (0..<3).map { _ in V2ActorHostID(uuid: UUID()) }, roster = Set(ids), group = UUID()
        var voters: [V2PlacementRaftVoter] = []
        for id in ids {
            voters.append(try await .open(id: id, groupID: group, voters: roster,
                storage: RaftTestStorage(.init(groupID: group, voterID: id, voters: roster))))
        }
        let network = RaftDriverTestNetwork(nodes: Dictionary(uniqueKeysWithValues: zip(ids, voters)))
        var tasks: [Task<Void, any Error>] = []
        for (index, voter) in voters.enumerated() {
            let driver = try V2PlacementRaftDriver(voter: voter, id: ids[index], voters: roster,
                transport: RaftDriverTestTransport(source: ids[index], network: network), heartbeatMilliseconds: 10,
                electionMilliseconds: index == 0 ? 60...85 : 250...400, tickMilliseconds: 2)
            tasks.append(Task { try await driver.run() })
        }
        var failure: (any Error)?
        do {
            let a = voters[0], b = voters[1], c = voters[2]
            try await wait { let state = await a.inspection(); return state.role == .leader && state.state.commitIndex > 0 }
            let initial = try V2ActorPlacementSnapshot(clusterID: group, revision: 1, slots: [.init(owner:
                .init(host: .init(hostID: ids[0], incarnationID: UUID()), epoch: 1), transfer: nil)])
            let oldLog = try V2PlacementRaftLeaderLog(voter: a, id: ids[0], groupID: group, voters: roster,
                transport: RaftDriverTestTransport(source: ids[0], network: network), timeout: .milliseconds(100))
            #expect(try await oldLog.bootstrap(initial) == initial)
            await network.isolate(ids[0])
            try await wait {
                let first = await b.inspection(), second = await c.inspection()
                return (first.role == .leader && first.state.commitIndex > 0 && first.state.term >= 2 &&
                    first.state.log[Int(first.state.commitIndex) - 1].term == first.state.term) ||
                    (second.role == .leader && second.state.commitIndex > 0 && second.state.term >= 2 &&
                    second.state.log[Int(second.state.commitIndex) - 1].term == second.state.term)
            }
            await #expect(throws: V2ActorPlacementError.unavailable) { _ = try await oldLog.load() }
            let leaderIndex = await b.inspection().role == .leader ? 1 : 2
            let newLog = try V2PlacementRaftLeaderLog(voter: voters[leaderIndex], id: ids[leaderIndex], groupID: group,
                voters: roster, transport: RaftDriverTestTransport(source: ids[leaderIndex], network: network), timeout: .milliseconds(200))
            #expect(try await newLog.load() == initial)
            await network.reconnect()
            try await wait { let state = await a.inspection(); return state.role == .follower && state.state.term >= 2 }
            await #expect(throws: V2PlacementRaftError.notLeader) { _ = try await oldLog.load() }
        } catch { failure = error }
        for task in tasks { task.cancel() }
        for task in tasks {
            if case .failure(let error) = await task.result, !(error is CancellationError) {
                Issue.record("Unexpected driver failure: \(error)")
            }
        }
        for voter in voters { await voter.stop() }
        if let failure { throw failure }
    }

    @Test("An isolated voter can campaign but cannot commit a barrier or publish placement")
    func isolatedCandidate() async throws {
        let id = V2ActorHostID(uuid: UUID()), group = UUID()
        let roster: Set<V2ActorHostID> = [id, .init(uuid: UUID()), .init(uuid: UUID())]
        let voter = try await V2PlacementRaftVoter.open(id: id, groupID: group, voters: roster,
            storage: RaftTestStorage(.init(groupID: group, voterID: id, voters: roster)))
        let network = RaftDriverTestNetwork(nodes: [id: voter])
        let driver = try V2PlacementRaftDriver(voter: voter, id: id, voters: roster,
            transport: RaftDriverTestTransport(source: id, network: network), heartbeatMilliseconds: 10,
            electionMilliseconds: 40...60, tickMilliseconds: 2)
        let task = Task { try await driver.run() }
        var failure: (any Error)?
        do {
            try await wait { await voter.inspection().state.term >= 2 }
            let state = await voter.inspection()
            #expect(state.role == .candidate && state.state.commitIndex == 0 && state.state.log.isEmpty)
        } catch { failure = error }
        task.cancel(); _ = await task.result; await voter.stop()
        if let failure { throw failure }
    }
}

private actor RaftDriverTestNetwork {
    let nodes: [V2ActorHostID: V2PlacementRaftVoter]
    var isolated: Set<V2ActorHostID> = []
    init(nodes: [V2ActorHostID: V2PlacementRaftVoter]) { self.nodes = nodes }
    func isolate(_ id: V2ActorHostID) { isolated.insert(id) }
    func reconnect() { isolated.removeAll() }
    private func target(source: V2ActorHostID, peer: V2ActorHostID, deadline: ContinuousClock.Instant) throws -> V2PlacementRaftVoter {
        guard ContinuousClock.now < deadline, !isolated.contains(source), !isolated.contains(peer), let node = nodes[peer] else {
            throw V2ActorPlacementError.unavailable
        }
        return node
    }
    func vote(_ request: V2PlacementRaftVoteRequest, source: V2ActorHostID, peer: V2ActorHostID,
              deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftVoteReply {
        try await target(source: source, peer: peer, deadline: deadline).vote(request, from: source)
    }
    func append(_ request: V2PlacementRaftAppendRequest, source: V2ActorHostID, peer: V2ActorHostID,
                deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftAppendReply {
        try await target(source: source, peer: peer, deadline: deadline).append(request, from: source)
    }
    func snapshot(_ request: V2PlacementRaftSnapshotChunk, source: V2ActorHostID, peer: V2ActorHostID,
                  deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftSnapshotReply {
        try await target(source: source, peer: peer, deadline: deadline).snapshot(request, from: source)
    }

}
private struct RaftDriverTestTransport: V2PlacementRaftElectionTransport {
    let source: V2ActorHostID
    let network: RaftDriverTestNetwork
    func vote(_ request: V2PlacementRaftVoteRequest, to peer: V2ActorHostID,
              deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftVoteReply {
        try await network.vote(request, source: source, peer: peer, deadline: deadline)
    }
    func append(_ request: V2PlacementRaftAppendRequest, to peer: V2ActorHostID,
                deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftAppendReply {
        try await network.append(request, source: source, peer: peer, deadline: deadline)
    }
    func snapshot(_ request: V2PlacementRaftSnapshotChunk, to peer: V2ActorHostID,
                  deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftSnapshotReply {
        try await network.snapshot(request, source: source, peer: peer, deadline: deadline)
    }

}
