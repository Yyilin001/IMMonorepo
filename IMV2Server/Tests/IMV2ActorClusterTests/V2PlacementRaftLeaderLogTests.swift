import Crypto
import Foundation
import IMV2ActorContracts
import Testing
@testable import IMV2ActorCluster

@Suite("Leader placement log requires fresh quorum")
struct V2PlacementRaftLeaderLogTests {
    private func fixture() async throws -> (V2PlacementRaftLeaderLog, RaftLogTestTransport, [V2PlacementRaftVoter], V2ActorPlacementSnapshot) {
        let ids = (0..<3).map { _ in V2ActorHostID(uuid: UUID()) }, group = UUID(), roster = Set(ids)
        var nodes: [V2PlacementRaftVoter] = []
        for id in ids {
            nodes.append(try await .open(id: id, groupID: group, voters: roster,
                storage: RaftTestStorage(.init(groupID: group, voterID: id, voters: roster))))
        }
        let request = try await nodes[0].campaign()
        let vote = try await nodes[1].vote(request, from: ids[0])
        try await nodes[0].receivedVote(vote, from: ids[1])
        let transport = RaftLogTestTransport(source: ids[0], nodes: Dictionary(uniqueKeysWithValues: zip(ids, nodes)))
        let log = try V2PlacementRaftLeaderLog(voter: nodes[0], id: ids[0], groupID: group, voters: roster,
            transport: transport, timeout: .milliseconds(100))
        let initial = try V2ActorPlacementSnapshot(clusterID: group, revision: 1, slots: [.init(owner:
            .init(host: .init(hostID: ids[0], incarnationID: UUID()), epoch: 1), transfer: nil)])
        return (log, transport, nodes, initial)
    }

    @Test("Bootstrap, CAS and exact lost-ACK replay use the certified log with one voter unavailable")
    func quorumReplay() async throws {
        let (log, transport, nodes, initial) = try await fixture()
        await transport.isolateOnePeer()
        #expect(try await log.bootstrap(initial) == initial)
        #expect(try await log.load() == initial)
        let initialInspection = try await log.inspect(deadline: .now + .seconds(1))
        #expect(initialInspection.snapshot == initial)
        #expect(initialInspection.archiveUsage.receipts == 0 && initialInspection.archiveUsage.reservedReceipts == 1)
        let owner = initial.slots[0].owner, id = UUID()
        let command = V2ActorPlacementCommand.retireHost(owner.host)
        let retired = try await log.append(command, expected: initial, requestID: id)
        #expect(retired.revision == 2 && retired.slots[0].retired)
        let before = await nodes[0].inspection().state.log.count
        #expect(try await log.append(command, expected: initial, requestID: id) == retired)
        #expect(await nodes[0].inspection().state.log.count == before)
        await #expect(throws: V2ActorPlacementError.staleRevision) {
            _ = try await log.append(command, expected: initial, requestID: UUID())
        }
        #expect(try await log.load() == retired)
        let retiredInspection = try await log.inspect(deadline: .now + .seconds(1))
        #expect(retiredInspection.snapshot == retired)
        #expect(retiredInspection.archiveUsage.receipts == 1 && retiredInspection.archiveUsage.reservedReceipts == 0)
        let startupIndex = await nodes[0].inspection().state.log.count
        #expect(try await log.bootstrap(initial) == retired)
        #expect(await nodes[0].inspection().state.log.count == startupIndex)
        for node in nodes { await node.stop() }
    }

    @Test("A slow third voter does not extend a successful majority wait")
    func slowThird() async throws {
        let (log, transport, nodes, initial) = try await fixture()
        await transport.delayOnePeer()
        #expect(try await log.bootstrap(initial) == initial)
        #expect(try await log.load() == initial)
        #expect(await transport.cancelledDelays > 0)
        for node in nodes { await node.stop() }
    }

    @Test("An isolated old leader cannot serve local snapshots or even successful receipt replays")
    func isolatedRead() async throws {
        let (log, transport, nodes, initial) = try await fixture()
        _ = try await log.bootstrap(initial)
        let id = UUID(), command = V2ActorPlacementCommand.retireHost(initial.slots[0].owner.host)
        _ = try await log.append(command, expected: initial, requestID: id)
        await transport.isolateAllPeers()
        await #expect(throws: V2ActorPlacementError.unavailable) { _ = try await log.bootstrap(initial) }
        await #expect(throws: V2ActorPlacementError.unavailable) { _ = try await log.load() }
        await #expect(throws: V2ActorPlacementError.unavailable) { _ = try await log.inspect(deadline: .now + .milliseconds(100)) }
        await #expect(throws: V2ActorPlacementError.unavailable) {
            _ = try await log.append(command, expected: initial, requestID: id)
        }
        await transport.reconnect()
        #expect(try await log.load().revision == 2)
        for node in nodes { await node.stop() }
    }

    @Test("A persisted higher-term reply makes the old leader stop serving reads")
    func staleLeader() async throws {
        let (log, transport, nodes, initial) = try await fixture()
        _ = try await log.bootstrap(initial)
        let ids = await transport.identities(nodes)
        let election = try await nodes[1].campaign()
        let vote = try await nodes[2].vote(election, from: ids[1])
        try await nodes[1].receivedVote(vote, from: ids[2])
        await #expect(throws: V2PlacementRaftError.notLeader) { _ = try await log.load() }
        #expect(await nodes[0].inspection().state.term == election.term)
        #expect(await nodes[0].inspection().role == .follower)
        for node in nodes { await node.stop() }
    }
    @Test("Exclusion requires dedicated authority; old proof replay cannot retire a successor")
    func exclusionAuthorityBoundary() async throws {
        let (log, transport, nodes, seed) = try await fixture()
        let ids = await transport.identities(nodes)
        let old = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let initial = try V2ActorPlacementSnapshot(clusterID: seed.clusterID, revision: 1,
            slots: [.init(owner: .init(host: old, epoch: 1), transfer: nil)])
        _ = try await log.bootstrap(initial)
        let supervisor = try V2ActorServiceID("exclusion-supervisor"), caller = try V2ActorServiceID("ordinary-writer")
        let hostService = try V2ActorServiceID("room-host")
        let key = Curve25519.Signing.PrivateKey(), callerKey = Curve25519.Signing.PrivateKey()
        var roles: [V2ActorServiceID: V2ActorHostID] = [:], services: [V2ActorTrustedService] = []
        for (index, id) in ids.enumerated() {
            let service = try V2ActorServiceID("voter-\(index)"); roles[service] = id
            services.append(try .init(serviceID: service, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                permissions: [.placementVote, .placementRead], hostedIDs: [id]))
        }
        services.append(try .init(serviceID: hostService, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            permissions: [.placementWrite], hostedIDs: [old.hostID]))
        services.append(try .init(serviceID: supervisor, publicKey: key.publicKey.rawRepresentation,
            permissions: [.placementRead, .placementWrite, .placementExclude]))
        services.append(try .init(serviceID: caller, publicKey: callerKey.publicKey.rawRepresentation,
            permissions: [.placementRead, .placementWrite]))
        let trust = try V2ActorTrustStore(services: services)
        let endpoint = try await V2PlacementRaftEndpoint.open(voters: ["room-a": nodes[0]], localID: ids[0], roles: roles,
            readers: [supervisor: ["room-a"], caller: ["room-a"]],
            writers: [supervisor: ["room-a"], caller: ["room-a"], hostService: ["room-a"]], roomHosts: [old.hostID: ["room-a"]])
        try await endpoint.bind(["room-a": log]); try await endpoint.validateTrust(trust)
        let operation = UUID(), signer = try V2ActorSigningIdentity(serviceID: supervisor, privateKey: key.rawRepresentation)
        let proof = V2RoomHostExclusionProof(host: old, operationID: operation, settledShardIDs: ["room-a"])
        let certificate = try V2PlacementDrainCertificate.signExclusion(proof, shard: "room-a", groupID: initial.clusterID, signer: signer)
        let impostor = try V2ActorSigningIdentity(serviceID: caller, privateKey: callerKey.rawRepresentation)
        let forged = try V2PlacementDrainCertificate.signExclusion(proof, shard: "room-a", groupID: initial.clusterID, signer: impostor)
        #expect(throws: V2ActorAuthenticationError.forbidden) {
            try V2PlacementDrainCertificate.verify(forged, shard: "room-a", groupID: initial.clusterID, trust: trust)
        }
        #expect(throws: V2ActorAuthenticationError.forbidden) {
            try V2PlacementDrainCertificate.signExclusion(proof, shard: "room-b", groupID: initial.clusterID, signer: signer)
        }
        func wire(_ id: UUID, _ packet: V2ActorSignedPacket?) throws -> V2PlacementRaftWire {
            try V2PlacementRaftWriteCodec.request(.init(command: .retireHost(old), expected: initial,
                requestID: id, certificate: packet), shard: "room-a")
        }
        for (service, id, packet) in [(caller, operation, Optional(certificate)),
                                      (supervisor, UUID(), Optional(certificate)), (supervisor, operation, nil)] {
            await #expect(throws: V2ActorAuthenticationError.forbidden) {
                try await endpoint.writePlacement(wire(id, packet), serviceID: service,
                    callerIncarnation: UUID(), deadline: .now + .seconds(2))
            }
        }
        let reply = try await endpoint.writePlacement(wire(operation, certificate), serviceID: supervisor,
            callerIncarnation: UUID(), deadline: .now + .seconds(2))
        guard case .ready(let retired) = try V2PlacementRaftWriteCodec.decode(reply, groupID: initial.clusterID, shard: "room-a") else {
            throw V2ActorPlacementError.unavailable
        }
        #expect(retired.registration(for: old.hostID)?.retired == true)
        let successor = V2ActorHostIdentity(hostID: old.hostID, incarnationID: UUID())
        let registration = try V2PlacementRaftWriteCodec.request(.init(command: .registerHost(previous: old, successor: successor),
            expected: retired, requestID: UUID(), certificate: nil), shard: "room-a")
        _ = try await endpoint.writePlacement(registration, serviceID: hostService,
            callerIncarnation: successor.incarnationID, deadline: .now + .seconds(2))
        _ = try await endpoint.writePlacement(wire(operation, certificate), serviceID: supervisor,
            callerIncarnation: UUID(), deadline: .now + .seconds(2))
        #expect(try await log.load().registration(for: old.hostID) == .init(host: successor, retired: false))
        for node in nodes { await node.stop() }
    }
    @Test("Retired Host partitions recover without old drain RPC and cancel a dead pending successor")
    func retiredHostAutomaticTakeover() async throws {
        let (log, _, nodes, seed) = try await fixture()
        let old = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let first = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let second = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let dead = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let initial = try V2ActorPlacementSnapshot(clusterID: seed.clusterID, revision: 1,
            slots: (0..<4).map { .init(owner: .init(host: old, epoch: 3),
                transfer: $0 == 0 ? .init(id: UUID(), successor: dead) : nil) },
            hosts: [old, first, second, dead].map { .init(host: $0, retired: false) })
        _ = try await log.bootstrap(initial)
        let runtime = try V2RoomActorPlacementRuntime(logs: ["room-a": log], snapshots: ["room-a": initial])
        let eligible: [V2ActorHostID: Set<String>] = [first.hostID: ["room-a"], second.hostID: ["room-a"], dead.hostID: ["room-a"]]
        let operation = UUID()
        await #expect(throws: V2ActorPlacementError.staleOwner) {
            try await runtime.takeOverRetiredHost(old, shards: ["room-a"], operationID: operation,
                eligibleHosts: eligible, deadline: .now + .seconds(2))
        }
        let withoutDead = try await log.append(.retireHost(dead), expected: initial, requestID: UUID())
        _ = try await log.append(.retireHost(old), expected: withoutDead, requestID: UUID())
        try await runtime.takeOverRetiredHost(old, shards: ["room-a"], operationID: operation,
            eligibleHosts: eligible, deadline: .now + .seconds(2))
        let recovered = try await log.load()
        #expect(recovered.slots.allSatisfy {
            ($0.owner.host == first || $0.owner.host == second) &&
                $0.owner.epoch == 4 && !$0.retired && $0.transfer == nil
        })
        #expect(recovered.slots.filter { $0.owner.host == first }.count == 2)
        #expect(recovered.slots.filter { $0.owner.host == second }.count == 2)
        try await runtime.takeOverRetiredHost(old, shards: ["room-a"], operationID: operation,
            eligibleHosts: eligible, deadline: .now + .seconds(2))
        #expect(try await log.load() == recovered)
        let restarted = V2ActorHostIdentity(hostID: old.hostID, incarnationID: UUID())
        let registered = try await log.append(.registerHost(previous: old, successor: restarted),
            expected: recovered, requestID: UUID())
        let proof = V2RoomHostExclusionProof(host: old, operationID: operation, settledShardIDs: ["room-a"])
        let count = await nodes[0].inspection().state.log.count
        try await runtime.retireAfterExclusion(proof, deadline: .now + .seconds(2))
        try await runtime.takeOverRetiredHost(old, shards: ["room-a"], operationID: operation,
            eligibleHosts: eligible, deadline: .now + .seconds(2))
        #expect(try await log.load() == registered)
        #expect(registered.registration(for: restarted.hostID) == .init(host: restarted, retired: false))
        #expect(await nodes[0].inspection().state.log.count == count)
        for node in nodes { await node.stop() }
    }
}

private actor RaftLogTestTransport: V2PlacementRaftTransport {
    let source: V2ActorHostID
    let nodes: [V2ActorHostID: V2PlacementRaftVoter]
    var isolated: Set<V2ActorHostID> = []
    var delayed: V2ActorHostID?
    var cancelledDelays = 0
    init(source: V2ActorHostID, nodes: [V2ActorHostID: V2PlacementRaftVoter]) { self.source = source; self.nodes = nodes }
    func identities(_ voters: [V2PlacementRaftVoter]) async -> [V2ActorHostID] {
        var result: [V2ActorHostID] = []
        for voter in voters { result.append(await voter.inspection().state.voterID) }
        return result
    }
    func delayOnePeer() { delayed = nodes.keys.first { $0 != source } }
    func isolateOnePeer() { isolated = [nodes.keys.first { $0 != source }!] }
    func isolateAllPeers() { isolated = Set(nodes.keys.filter { $0 != source }) }
    func reconnect() { isolated.removeAll() }
    func append(_ request: V2PlacementRaftAppendRequest, to peer: V2ActorHostID,
                deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftAppendReply {
        guard ContinuousClock.now < deadline, request.leader == source,
              !isolated.contains(peer), let node = nodes[peer] else { throw V2ActorPlacementError.unavailable }
        if peer == delayed {
            do { try await Task.sleep(for: .seconds(2)) }
            catch { cancelledDelays += 1; throw error }
        }
        return try await node.append(request, from: source)
    }
    func snapshot(_ request: V2PlacementRaftSnapshotChunk, to peer: V2ActorHostID,
                  deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftSnapshotReply {
        guard ContinuousClock.now < deadline, request.leader == source,
              !isolated.contains(peer), let node = nodes[peer] else { throw V2ActorPlacementError.unavailable }
        if peer == delayed {
            do { try await Task.sleep(for: .seconds(2)) }
            catch { cancelledDelays += 1; throw error }
        }
        return try await node.snapshot(request, from: source)
    }

}
