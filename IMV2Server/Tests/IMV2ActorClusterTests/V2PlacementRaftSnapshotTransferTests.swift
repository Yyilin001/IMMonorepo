import Foundation
import Crypto
import IMV2ActorContracts
import Synchronization
import Testing
@testable import IMV2ActorCluster

@Suite("Placement snapshot catch-up installs only a verified durable checkpoint")
struct V2PlacementRaftSnapshotTransferTests {
    private struct Fixture {
        let a = V2ActorHostID(uuid: UUID()), b = V2ActorHostID(uuid: UUID()), c = V2ActorHostID(uuid: UUID())
        let group = UUID()
        var roster: Set<V2ActorHostID> { [a, b, c] }
        let hostIncarnation = UUID(), requestID = UUID()
        var host: V2ActorHostIdentity { .init(hostID: a, incarnationID: hostIncarnation) }
        func state(for id: V2ActorHostID, committed: UInt64 = 3) throws -> V2PlacementRaftPersistentState {
            let initial = try V2ActorPlacementSnapshot(clusterID: group, revision: 1,
                slots: [.init(owner: .init(host: host, epoch: 1), transfer: nil)])
            return try .init(groupID: group, voterID: id, voters: roster, term: 1,
                log: [.init(term: 1, payload: V2PlacementRaftApplication.encode(.bootstrap(initial))),
                      .init(term: 1, payload: Data()),
                      .init(term: 1, payload: V2PlacementRaftApplication.encode(.command(.retireHost(host), expected: initial, requestID: requestID)))],
                commitIndex: committed)
        }
        func transfer() throws -> V2PlacementRaftSnapshotTransfer {
            let state = try state(for: a)
            var application = V2PlacementRaftApplication(groupID: group); try application.apply(state)
            return try .init(groupID: group, leader: a, term: 2,
                snapshot: .init(index: 3, term: 1, application: application.checkpoint()))
        }
    }
    private func smallChunk(_ transfer: V2PlacementRaftSnapshotTransfer, at offset: Int) -> V2PlacementRaftSnapshotChunk {
        let end = min(offset + 64, transfer.snapshot.application.count)
        return .init(groupID: transfer.groupID, leader: transfer.leader, term: transfer.term,
            transferID: transfer.transferID, snapshotIndex: transfer.snapshot.index, snapshotTerm: transfer.snapshot.term,
            digest: transfer.digest, totalBytes: transfer.snapshot.application.count, offset: offset,
            chunk: transfer.snapshot.application.subdata(in: offset..<end))
    }

    @Test("Interrupted and duplicate chunks never publish partial state; matching suffix survives installation")
    func partialAndRestart() throws {
        let f = Fixture(), transfer = try f.transfer()
        var state = try f.state(for: f.b, committed: 1)
        state.log.append(.init(term: 1, payload: Data()))
        var follower = try V2PlacementRaftCore(id: f.b, groupID: f.group, voters: f.roster, persisted: state)
        let first = smallChunk(transfer, at: 0)
        #expect(try V2PlacementRaftWireCodec.decodeRequest(V2PlacementRaftWireCodec.encode(.snapshot(first), shard: "room-a")) == .snapshot(first))
        let reply = try follower.snapshot(first, from: f.a)
        #expect(reply.accepted && !reply.installed && reply.nextOffset == first.chunk.count)
        #expect(follower.state.baseIndex == 0 && follower.state.commitIndex == 1 && follower.state.term == 2)
        try state.validateLocalSuccessor(follower.state)
        #expect(try follower.snapshot(first, from: f.a) == reply)
        // Restart has only the stable term/log; the partial receive buffer is gone.
        follower = try .init(id: f.b, groupID: f.group, voters: f.roster, persisted: follower.state)
        #expect(try !follower.snapshot(smallChunk(transfer, at: reply.nextOffset), from: f.a).accepted)
        var offset = 0
        while offset < transfer.snapshot.application.count {
            let before = follower.state
            let request = smallChunk(transfer, at: offset)
            let result = try follower.snapshot(request, from: f.a)
            try before.validateLocalSuccessor(follower.state)
            #expect(result.accepted)
            if result.installed { #expect(follower.state.baseIndex == 3 && follower.state.commitIndex == 3) }
            else { #expect(follower.state.baseIndex == 0 && follower.state.commitIndex == 1) }
            offset = result.nextOffset
        }
        #expect(follower.lastIndex == 4 && follower.state.log.count == 1)
        var application = V2PlacementRaftApplication(groupID: f.group); try application.apply(follower.state)
        #expect(application.snapshot?.registration(for: f.a)?.retired == true)
        #expect(try application.receipt(for: .retireHost(f.host), requestID: f.requestID) == application.snapshot)
        #expect(try follower.snapshot(first, from: f.a).installed)
    }

    @Test("Final installation waits for physical persistence even when caller cancels")
    func durableAcknowledgement() async throws {
        let f = Fixture(), transfer = try f.transfer()
        let storage = RaftTestStorage(try f.state(for: f.b, committed: 1))
        let voter = try await V2PlacementRaftVoter.open(id: f.b, groupID: f.group, voters: f.roster, storage: storage)
        let finished = Mutex(false)
        await storage.block()
        let request = try transfer.chunk(at: 0)
        let install = Task {
            let reply = try await voter.snapshot(request, from: f.a)
            finished.withLock { $0 = true }
            return reply
        }
        try await storage.waitForWrite()
        #expect(finished.withLock { !$0 })
        #expect(await voter.inspection().state.baseIndex == 0)
        install.cancel()
        await storage.unblock()
        #expect(try await install.value.installed)
        let persisted = await storage.load()
        #expect(persisted.baseIndex == 3 && persisted.commitIndex == 3)
        let reopened = try await V2PlacementRaftVoter.open(id: f.b, groupID: f.group, voters: f.roster, storage: storage)
        #expect(await reopened.inspection().state.snapshot == transfer.snapshot)
        await voter.stop(); await reopened.stop()
    }

    @Test("Compacted leader catches up an empty peer, then confirms a fresh quorum read")
    func leaderCatchUp() async throws {
        let f = Fixture()
        let a = try await V2PlacementRaftVoter.open(id: f.a, groupID: f.group, voters: f.roster, storage: RaftTestStorage(try f.state(for: f.a)))
        let b = try await V2PlacementRaftVoter.open(id: f.b, groupID: f.group, voters: f.roster, storage: RaftTestStorage(.init(groupID: f.group, voterID: f.b, voters: f.roster)))
        let c = try await V2PlacementRaftVoter.open(id: f.c, groupID: f.group, voters: f.roster, storage: RaftTestStorage(try f.state(for: f.c)))
        let transport = SnapshotTestTransport(source: f.a, nodes: [f.b: b, f.c: c])
        let campaign = try await a.campaign()
        try await a.receivedVote(c.vote(campaign, from: f.a), from: f.c)
        let append = try await a.appendRequest(to: f.c)
        try await a.receivedAppend(c.append(append, from: f.a), from: f.c, for: append)
        var application = V2PlacementRaftApplication(groupID: f.group)
        try await application.apply(a.committedState())
        try await a.compact(application.checkpoint(), through: 4)
        // Rejections move nextIndex into the compacted prefix, selecting snapshot.
        for _ in 0..<8 {
            try await V2PlacementRaftReplicationRound.run(a.replication(to: f.b), to: f.b, voter: a, transport: transport, deadline: .now + .seconds(1))
            if await b.inspection().state.baseIndex == 4 { break }
        }
        #expect(await b.inspection().state.baseIndex == 4)
        let read = try await a.beginRead()
        #expect(try await a.confirmedRead(read) == nil)
        try await V2PlacementRaftReplicationRound.run(a.replication(to: f.b, readID: read), to: f.b, voter: a, transport: transport, deadline: .now + .seconds(1))
        #expect(try await a.confirmedRead(read) == 4)
        await a.stop(); await b.stop(); await c.stop()
    }

    @Test("Automatic compaction waits for pending replies and preserves an uncommitted suffix")
    func automaticCompactionBoundary() async throws {
        let f = Fixture()
        let a = try await V2PlacementRaftVoter.open(id: f.a, groupID: f.group, voters: f.roster, storage: RaftTestStorage(try f.state(for: f.a)))
        let c = try await V2PlacementRaftVoter.open(id: f.c, groupID: f.group, voters: f.roster, storage: RaftTestStorage(try f.state(for: f.c)))
        let campaign = try await a.campaign()
        try await a.receivedVote(c.vote(campaign, from: f.a), from: f.c)
        let append = try await a.appendRequest(to: f.c)
        try await a.receivedAppend(c.append(append, from: f.a), from: f.c, for: append)
        var application = V2PlacementRaftApplication(groupID: f.group)
        try await application.apply(a.committedState())
        let retired = try #require(application.snapshot)
        let command = V2ActorPlacementCommand.registerHost(previous: f.host,
            successor: .init(hostID: f.a, incarnationID: UUID()))
        let payload = try V2PlacementRaftApplication.encode(.command(command, expected: retired, requestID: UUID()))
        let index = try await a.proposeForReply(payload)
        #expect(index == 5)
        try await a.compactIfNeeded(minimumCommittedEntries: 2)
        #expect(await a.inspection().state.baseIndex == 0)
        await a.finishReply(at: index)
        try await a.compactIfNeeded(minimumCommittedEntries: 2)
        let state = try await a.committedState()
        #expect(state.baseIndex == 4 && state.commitIndex == 4 && state.lastIndex == 5)
        #expect(state.entry(at: 5)?.payload == payload)
        await a.stop(); await c.stop()
    }

    @Test("Higher term, wrong voter, corrupt bytes and contradictory committed facts cannot install")
    func rejectsInvalidSnapshots() throws {
        let f = Fixture(), transfer = try f.transfer()
        var follower = try V2PlacementRaftCore(id: f.b, groupID: f.group, voters: f.roster, persisted: f.state(for: f.b, committed: 1))
        let request = try transfer.chunk(at: 0)
        #expect(throws: V2PlacementRaftError.invalidMessage) { try follower.snapshot(request, from: f.c) }
        var corrupted = request.chunk; corrupted[0] ^= 1
        let wrong = V2PlacementRaftSnapshotChunk(groupID: request.groupID, leader: request.leader, term: request.term,
            transferID: UUID(), snapshotIndex: request.snapshotIndex, snapshotTerm: request.snapshotTerm,
            digest: request.digest, totalBytes: request.totalBytes, offset: 0, chunk: corrupted)
        #expect(throws: V2PlacementRaftError.invalidMessage) { try follower.snapshot(wrong, from: f.a) }
        #expect(follower.state.baseIndex == 0 && follower.state.commitIndex == 1)
        var changed = try f.state(for: f.b, committed: 1)
        let fakeGenesis = try V2ActorPlacementSnapshot(clusterID: f.group, revision: 1,
            slots: [.init(owner: .init(host: .init(hostID: f.a, incarnationID: UUID()), epoch: 1), transfer: nil)])
        changed.term = 2; changed.log = []
        changed.snapshot = try .init(index: 3, term: 1, application:
            V2PlacementRaftCheckpoint(groupID: f.group, appliedIndex: 3, genesis: fakeGenesis, receipts: []).encode())
        changed.commitIndex = 3
        #expect(throws: V2PlacementRaftError.invalidState) { try follower.state.validateLocalSuccessor(changed) }
        _ = try follower.campaign() // advances to term 3; the term-2 snapshot is stale
        #expect(try !follower.snapshot(request, from: f.a).accepted)
    }
}

private struct SnapshotTestTransport: V2PlacementRaftTransport {
    let source: V2ActorHostID
    let nodes: [V2ActorHostID: V2PlacementRaftVoter]
    func append(_ request: V2PlacementRaftAppendRequest, to peer: V2ActorHostID,
                deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftAppendReply {
        let wire = try V2PlacementRaftWireCodec.encode(.append(request), shard: "room-a")
        guard case .append(let decoded) = try V2PlacementRaftWireCodec.decodeRequest(wire), let node = nodes[peer] else { throw V2PlacementRaftError.invalidMessage }
        return try await node.append(decoded, from: source)
    }
    func snapshot(_ request: V2PlacementRaftSnapshotChunk, to peer: V2ActorHostID,
                  deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftSnapshotReply {
        let wire = try V2PlacementRaftWireCodec.encode(.snapshot(request), shard: "room-a")
        guard case .snapshot(let decoded) = try V2PlacementRaftWireCodec.decodeRequest(wire), let node = nodes[peer] else { throw V2PlacementRaftError.invalidMessage }
        let reply = try await node.snapshot(decoded, from: source)
        let encoded = try V2PlacementRaftWireCodec.encode(.snapshot(reply), shard: "room-a")
        guard case .snapshot(let value) = try V2PlacementRaftWireCodec.decodeReply(encoded, shard: "room-a") else { throw V2PlacementRaftError.invalidMessage }
        return value
    }
}
