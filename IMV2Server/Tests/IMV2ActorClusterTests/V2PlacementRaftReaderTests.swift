import Foundation
import IMV2ActorContracts
import Testing
@testable import IMV2ActorCluster

@Suite("Read-only placement routing never promotes hints into authority")
struct V2PlacementRaftReaderTests {
    @Test("A slow first voter leaves time to read the healthy leader")
    func slowFirstPeerDoesNotStarveLeader() async throws {
        let peers = Set((1...3).map { V2ActorHostID(uuid: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!) })
        let first = try #require(peers.sorted { $0.rawValue < $1.rawValue }.first)
        let group = UUID(), host = V2ActorHostIdentity(hostID: first, incarnationID: UUID())
        let snapshot = try V2ActorPlacementSnapshot(clusterID: group, revision: 1,
            slots: [.init(owner: .init(host: host, epoch: 1), transfer: nil)])
        let reader = try V2PlacementRaftReader(groupID: group, peers: peers,
            transport: SlowFirstVoterTransport(first: first, snapshot: snapshot))
        #expect(try await reader.load(deadline: .now + .milliseconds(500)) == snapshot)
    }
    @Test("A fourth-node hint and a different group's snapshot cannot install placement")
    func foreignAuthority() async throws {
        let peers: Set<V2ActorHostID> = [.init(uuid: UUID()), .init(uuid: UUID()), .init(uuid: UUID())], group = UUID()
        let redirect = RaftReaderTestTransport(reply: .retry(.init(uuid: UUID())))
        let reader = try V2PlacementRaftReader(groupID: group, peers: peers, transport: redirect)
        await #expect(throws: V2PlacementRaftError.unauthorizedVoter) { _ = try await reader.load(deadline: .now + .seconds(1)) }
        let snapshot = try V2ActorPlacementSnapshot(clusterID: UUID(), revision: 1, slots: [.init(owner:
            .init(host: .init(hostID: .init(uuid: UUID()), incarnationID: UUID()), epoch: 1), transfer: nil)])
        let wrong = try V2PlacementRaftReader(groupID: group, peers: peers, transport: RaftReaderTestTransport(reply: .ready(snapshot)))
        await #expect(throws: V2PlacementRaftError.wrongGroup) { _ = try await wrong.load(deadline: .now + .seconds(1)) }
    }

    @Test("Repeated follower redirects time out; cancellation remains cancellation")
    func noLeader() async throws {
        let peers: Set<V2ActorHostID> = [.init(uuid: UUID()), .init(uuid: UUID()), .init(uuid: UUID())], group = UUID()
        let reader = try V2PlacementRaftReader(groupID: group, peers: peers, transport: RaftReaderTestTransport(reply: .retry(nil)))
        await #expect(throws: V2ActorPlacementError.unavailable) { _ = try await reader.load(deadline: .now + .milliseconds(50)) }
        let task = Task { try await reader.load(deadline: .now + .seconds(30)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test("Read reply PB binds logical shard and group; snapshots cannot also claim a redirect")
    func protobufBindings() throws {
        let group = UUID(), peer = V2ActorHostID(uuid: UUID())
        let request = try V2PlacementRaftReadCodec.request(groupID: group, shard: "room-a")
        #expect(try V2PlacementRaftReadCodec.decodeRequest(request).groupID == group)
        let redirect = try V2PlacementRaftReadCodec.encode(.retry(peer), shard: "room-a", groupID: group)
        #expect(try V2PlacementRaftReadCodec.decode(redirect, shard: "room-a", groupID: group) == .retry(peer))
        #expect(throws: V2PlacementRaftError.wrongGroup) { try V2PlacementRaftReadCodec.decode(redirect, shard: "room-a", groupID: UUID()) }
        #expect(throws: V2PlacementRaftError.invalidMessage) { try V2PlacementRaftReadCodec.decode(redirect, shard: "room-b", groupID: group) }
        let snapshot = try V2ActorPlacementSnapshot(clusterID: group, revision: 1, slots: [.init(owner:
            .init(host: .init(hostID: peer, incarnationID: UUID()), epoch: 1), transfer: nil)])
        var wire = Im_Actor_V1_PlacementRaftReadReply()
        wire.groupID = V2HotPB.bytes(group); wire.snapshot = try V2ActorPlacementProtobuf.encode(snapshot); wire.leaderHint = peer.rawValue
        let mixed = try V2PlacementRaftWire(shardID: "room-a", payload: wire.serializedData())
        #expect(throws: V2PlacementRaftError.invalidMessage) { try V2PlacementRaftReadCodec.decode(mixed, shard: "room-a", groupID: group) }
    }

    @Test("Inspection requires capacity paired with the certified snapshot; normal reads stay separate")
    func archiveInspectionBindings() async throws {
        let group = UUID(), peers: Set<V2ActorHostID> = [.init(uuid: UUID()), .init(uuid: UUID()), .init(uuid: UUID())]
        let host = V2ActorHostIdentity(hostID: try #require(peers.first), incarnationID: UUID())
        let snapshot = try V2ActorPlacementSnapshot(clusterID: group, revision: 1,
            slots: [.init(owner: .init(host: host, epoch: 1), transfer: nil)])
        let usage = try V2PlacementArchiveCapacity.usage(snapshot: snapshot, receipts: 0,
            bytes: V2PlacementArchiveCapacity.headerBytes(snapshot))
        let request = try V2PlacementRaftReadCodec.request(groupID: group, shard: "rooms", includeArchiveUsage: true)
        #expect(try V2PlacementRaftReadCodec.decodeRequest(request).includeArchiveUsage)
        let reply = V2PlacementRaftReadCodec.Reply.inspected(snapshot, usage)
        let wire = try V2PlacementRaftReadCodec.encode(reply, shard: "rooms", groupID: group)
        #expect(try V2PlacementRaftReadCodec.decode(wire, shard: "rooms", groupID: group) == reply)
        let reader = try V2PlacementRaftReader(groupID: group, peers: peers, transport: RaftReaderTestTransport(reply: reply))
        let inspected = try await reader.inspect(deadline: .now + .seconds(1))
        #expect(inspected.snapshot == snapshot && inspected.archiveUsage == usage)
        await #expect(throws: V2PlacementRaftError.invalidMessage) { _ = try await reader.load(deadline: .now + .seconds(1)) }
        let missing = try V2PlacementRaftReader(groupID: group, peers: peers,
            transport: RaftReaderTestTransport(reply: .ready(snapshot)))
        await #expect(throws: V2PlacementRaftError.invalidMessage) { _ = try await missing.inspect(deadline: .now + .seconds(1)) }

        var malformed = try Im_Actor_V1_PlacementRaftReadReply(serializedBytes: wire.payload)
        malformed.archiveUsage.reservedReceipts = 0
        let invalid = try V2PlacementRaftWire(shardID: "rooms", payload: malformed.serializedData())
        #expect(throws: V2PlacementRaftError.invalidMessage) { try V2PlacementRaftReadCodec.decode(invalid, shard: "rooms", groupID: group) }
        malformed = try Im_Actor_V1_PlacementRaftReadReply(serializedBytes: wire.payload)
        malformed.snapshot = Data()
        let noSnapshot = try V2PlacementRaftWire(shardID: "rooms", payload: malformed.serializedData())
        #expect(throws: V2PlacementRaftError.invalidMessage) { try V2PlacementRaftReadCodec.decode(noSnapshot, shard: "rooms", groupID: group) }
    }
}
private struct SlowFirstVoterTransport: V2PlacementRaftReadTransport {
    let first: V2ActorHostID
    let snapshot: V2ActorPlacementSnapshot
    func read(groupID: UUID, includeArchiveUsage: Bool, from peer: V2ActorHostID,
              deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftReadCodec.Reply {
        if peer == first {
            try await ContinuousClock().sleep(until: deadline)
            throw V2ActorPlacementError.unavailable
        }
        return .ready(snapshot)
    }
}
private struct RaftReaderTestTransport: V2PlacementRaftReadTransport {
    let reply: V2PlacementRaftReadCodec.Reply
    func read(groupID: UUID, includeArchiveUsage: Bool, from peer: V2ActorHostID, deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftReadCodec.Reply {
        try Task.checkCancellation()
        return reply
    }
}
