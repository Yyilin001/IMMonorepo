import Crypto
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import NIOSSL
import Testing
@testable import IMV2ActorCluster

@Suite("Independent mTLS Raft nodes", .serialized)
struct V2PlacementRaftNodeTests {
    private func wait(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw V2PlacementRaftError.notReady }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func withNodes(_ body: ([V2PlacementRaftNode], [V2PlacementRaftVoter], [V2PlacementRaftClusterTransport],
                                   [V2ActorHostIdentity], UUID, [V2ActorSigningIdentity]) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("raft-node-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let certificate = folder.appendingPathComponent("cert.pem"), privateKey = folder.appendingPathComponent("key.pem")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
            "-nodes", "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
            "-keyout", privateKey.path, "-out", certificate.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); try #require(process.terminationStatus == 0)
        let chain = try NIOSSLCertificate.fromPEMFile(certificate.path)
        var tls = TLSConfiguration.makeServerConfiguration(certificateChain: chain.map { .certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(file: privateKey.path, format: .pem)))
        tls.minimumTLSVersion = .tlsv13; tls.maximumTLSVersion = .tlsv13
        tls.certificateVerification = .fullVerification; tls.trustRoots = .certificates(chain)
        let identities = (0..<3).map { _ in V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID()) }
        let ids = identities.map(\.hostID), roster = Set(ids), groupID = UUID()
        let keys = (0..<4).map { _ in Curve25519.Signing.PrivateKey() }
        let services = try (0..<4).map { try V2ActorServiceID("raft-voter-\($0)") }
        let trust = try V2ActorTrustStore(services: (0..<4).map {
            try .init(serviceID: services[$0], publicKey: keys[$0].publicKey.rawRepresentation,
                permissions: $0 == 3 ? [.placementRead] : [.placementVote, .placementRead, .placementWrite], hostedIDs: $0 == 3 ? [] : [ids[$0]])
        })
        let roles = Dictionary(uniqueKeysWithValues: zip(services.prefix(3), ids))
        let ports = Array(Set((0..<12).map { _ in Int.random(in: 30_000...60_000) }).prefix(4))
        try #require(ports.count == 4)
        let peers = try (0..<3).map { try V2RoomDiscoveryPeer(hostID: ids[$0], serviceID: services[$0],
            address: "localhost", port: ports[$0], accessibleShardIDs: ["room-a"], maximumRooms: 1) }
        let discovery = try V2RoomDiscoveryConfiguration(peers: peers, pollInterval: .milliseconds(100),
            probeTimeout: .milliseconds(300), failedHostGrace: .seconds(2), maximumConcurrentProbes: 3)
        var voters: [V2PlacementRaftVoter] = [], nodes: [V2PlacementRaftNode] = [], transports: [V2PlacementRaftClusterTransport] = []
        var readNode: V2RoomClusterClientNode?
        var failure: (any Error)?
        do {
            for index in 0..<3 {
                let voter = try await V2PlacementRaftVoter.open(id: ids[index], groupID: groupID, voters: roster,
                    storage: RaftTestStorage(.init(groupID: groupID, voterID: ids[index], voters: roster)))
                voters.append(voter)
                let endpoint = try await V2PlacementRaftEndpoint.open(voters: ["room-a": voter], localID: ids[index], roles: roles, readers: Dictionary(uniqueKeysWithValues: services.map { ($0, Set(["room-a"])) }), writers: Dictionary(uniqueKeysWithValues: services.prefix(3).map { ($0, Set(["room-a"])) }), roomHosts: Dictionary(uniqueKeysWithValues: ids.map { ($0, Set(["room-a"])) }))
                let configuration = try V2RoomClusterClientNodeConfiguration(name: "raft-node-\(index)-\(UUID())",
                    host: "localhost", port: ports[index], tls: tls, threadPoolSize: 1)
                let signer = try V2ActorSigningIdentity(serviceID: services[index], privateKey: keys[index].rawRepresentation)
                nodes.append(try V2PlacementRaftNode(configuration: configuration, identity: identities[index], signer: signer,
                    trust: trust, limits: .init(), endpoint: endpoint, shards: ["room-a"]))
            }
            for node in nodes {
                let started = try await node.start(discovery: discovery), client = started.client
                transports.append(.init(shardID: "room-a", client: client, resolve: { peer, _ in
                    try client.resolvePolicyHost(hostID: peer, endpoint: "room-a")
                }))
            }
            let readerConfiguration = try V2RoomClusterClientNodeConfiguration(name: "raft-reader-\(UUID())",
                host: "localhost", port: ports[3], tls: tls, threadPoolSize: 1)
            let readerSigner = try V2ActorSigningIdentity(serviceID: services[3], privateKey: keys[3].rawRepresentation)
            let caller = V2RoomClusterClientNode(configuration: readerConfiguration, signer: readerSigner, trust: trust,
                authenticationLimits: try .init(), runtimeConfiguration: try .init(maximumConcurrentResolutions: 8))
            readNode = caller
            let readerClient = try await caller.start(discovery: discovery)
            transports.append(.init(shardID: "room-a", client: readerClient, resolve: { peer, _ in
                try readerClient.resolvePolicyHost(hostID: peer, endpoint: "room-a")
            }))
            try await body(nodes, voters, transports, identities, groupID, try (0..<3).map { try V2ActorSigningIdentity(serviceID: services[$0], privateKey: keys[$0].rawRepresentation) })
        } catch { failure = error }
        if let readNode { #expect(try await readNode.stop(deadline: .now + .seconds(8))) }
        for node in nodes {
            #expect(try await node.stop(deadline: .now + .seconds(8)))
        }
        for voter in voters { await voter.stop() }
        if let failure { throw failure }
    }

    @Test("Three independently discovered TLS nodes elect and commit without constructing any room Host")
    func actualTLSConsensus() async throws {
        try await withNodes { nodes, voters, transports, identities, groupID, signers in
            let ids = identities.map(\.hostID), roster = Set(ids)
            var logs: [V2PlacementRaftLeaderLog] = []
            for index in 0..<3 {
                let log = try V2PlacementRaftLeaderLog(voter: voters[index], id: ids[index], groupID: groupID,
                    voters: roster, transport: transports[index], timeout: .seconds(3))
                logs.append(log)
                try await nodes[index].bind(["room-a": log])
            }
            var tasks: [Task<Void, any Error>] = []
            for index in 0..<3 {
                let driver = try V2PlacementRaftDriver(voter: voters[index], id: ids[index], voters: roster,
                    transport: transports[index], heartbeatMilliseconds: 100,
                    electionMilliseconds: index == 0 ? 700...900 : 1800...2200)
                tasks.append(Task { try await driver.run() })
            }
            var failure: (any Error)?
            do {
                let first = voters[0]
                try await wait {
                    let state = await first.inspection()
                    return state.role == .leader && state.state.commitIndex > 0 &&
                        state.state.log[Int(state.state.commitIndex) - 1].term == state.state.term
                }
                let reserved = V2ActorHostIdentity(hostID: ids[0], incarnationID: UUID())
                let initial = try V2ActorPlacementSnapshot(clusterID: groupID, revision: 1,
                    slots: (0..<2).map { _ in .init(owner: .init(host: reserved, epoch: 1), transfer: nil, retired: true) },
                    hosts: [.init(host: reserved, retired: true), .init(host: identities[1], retired: false)])
                let log = logs[0]
                #expect(try await log.bootstrap(initial) == initial)
                let writerReader = try V2PlacementRaftReader(groupID: groupID, peers: roster, transport: transports[0])
                let writer = try V2PlacementRaftRemoteLog(groupID: groupID, shardID: "room-a", peers: roster,
                    reader: writerReader, transport: transports[0], signer: signers[0])
                let register = V2ActorPlacementCommand.registerHost(previous: reserved, successor: identities[0])
                let registrationID = UUID()
                let registered = try await writer.append(register, expected: initial, requestID: registrationID)
                #expect(registered.revision == 2 && !registered.slots[0].retired)
                #expect(try await writer.append(register, expected: initial, requestID: registrationID) == registered)
                // Another authenticated voter cannot register a different process.
                await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
                    _ = try await transports[1].write(.init(command: register, expected: initial,
                        requestID: UUID(), certificate: nil), to: ids[0], deadline: .now + .seconds(2))
                }
                let owner = registered.slots[0].owner, transferID = UUID()
                let withdrawn = try await writer.append(.beginTransfer(partition: 0, expected: owner,
                    transfer: .init(id: transferID, successor: identities[1])), expected: registered, requestID: transferID)
                let complete = V2ActorPlacementCommand.completeTransfer(partition: 0, expected: owner, transferID: transferID)
                // No terminal operation is admitted merely because its caller
                // is a trusted writer or the old owner is unreachable.
                await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
                    _ = try await transports[0].write(.init(command: complete, expected: withdrawn,
                        requestID: transferID, certificate: nil), to: ids[0], deadline: .now + .seconds(2))
                }
                var forgedSlots = withdrawn.slots
                forgedSlots[0] = .init(owner: owner, transfer: withdrawn.slots[0].transfer, retired: true)
                let forgedRetirement = try V2ActorPlacementSnapshot(clusterID: groupID, revision: withdrawn.revision,
                    slots: forgedSlots, hosts: withdrawn.hosts)
                await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
                    _ = try await transports[0].write(.init(command: complete, expected: forgedRetirement,
                        requestID: transferID, certificate: nil), to: ids[0], deadline: .now + .seconds(2))
                }
                #expect(try await log.load() == withdrawn)
                var receipt = V2ActorPlacementDrainReceipt(clusterID: groupID, partition: 0, owner: owner, transferID: transferID)
                receipt.certificate = try V2PlacementDrainCertificate.signPartition(receipt, shard: "room-a", signer: signers[0])
                let transferred = try await writer.append(complete, evidence: .partition(receipt), expected: withdrawn, requestID: transferID)
                #expect(transferred.revision == 4 && transferred.slots[0].owner.host == identities[1])
                // Losing a commit ACK does not require asking the old Host
                // for another physical drain proof.
                #expect(try await writer.append(complete, expected: withdrawn, requestID: transferID) == transferred)
                #expect(try await writer.load() == transferred)
                let retire = V2ActorPlacementCommand.retireHost(identities[0]), retirementID = UUID()
                await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
                    _ = try await transports[0].write(.init(command: retire, expected: transferred,
                        requestID: retirementID, certificate: nil), to: ids[0], deadline: .now + .seconds(2))
                }
                let runtime = try V2RoomRuntimeConfiguration()
                let emptyHost = V2RoomActivationHost<Int, Int>(identity: identities[0],
                    placement: PlacementFixedHostFixture(host: identities[0]), configuration: runtime,
                    budget: V2RoomCommandBudget(configuration: runtime), classify: { _ in .barrier },
                    factory: .init(pureRoomLogPull: { _, _, _ in .rolledBack(.invalidRequest) }) { _ in
                        .init(restore: { _ in throw V2ActorPlacementError.unavailable },
                              execute: { _ in .rolledBack(.invalidRequest) }, invalidateReservation: { _ in }, close: {})
                    })
                await emptyHost.start()
                let nativeProof = try #require(await emptyHost.stop(deadline: .now + .seconds(2)).proof)
                let wrongStartup = try V2PlacementDrainCertificate.signHost(nativeProof, shard: "room-a", groupID: groupID,
                    previous: reserved, registrationRequestID: UUID(), signer: signers[0])
                await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
                    _ = try await transports[0].write(.init(command: retire, expected: transferred,
                        requestID: retirementID, certificate: wrongStartup), to: ids[0], deadline: .now + .seconds(2))
                }
                let retired = try await writer.append(retire, evidence: .host(nativeProof, previous: reserved,
                    registrationRequestID: registrationID), expected: transferred, requestID: retirementID)
                #expect(retired.revision == 5 && retired.slots[1].retired && !retired.slots[0].retired)
                #expect(try await writer.append(retire, expected: transferred, requestID: retirementID) == retired)
                let takeoverID = UUID(), retiredOwner = retired.slots[1].owner
                let takeover = try await writer.append(.beginTransfer(partition: 1, expected: retiredOwner,
                    transfer: .init(id: takeoverID, successor: identities[1])), expected: retired, requestID: takeoverID)
                let takenOver = try await writer.append(.completeTransfer(partition: 1, expected: retiredOwner,
                    transferID: takeoverID), expected: takeover, requestID: takeoverID)
                #expect(takenOver.revision == 7 && takenOver.slots.allSatisfy { !$0.retired && $0.owner.host == identities[1] })
                let b = voters[1], c = voters[2]
                try await wait {
                    let first = await b.inspection(), second = await c.inspection()
                    return first.state.commitIndex >= 6 && second.state.commitIndex >= 6
                }
                let followerReply = try await transports[3].read(groupID: groupID, includeArchiveUsage: false, from: ids[1], deadline: .now + .seconds(2))
                guard case .retry(let hint) = followerReply else { throw V2PlacementRaftError.invalidState }
                #expect(hint == ids[0])
                let reader = try V2PlacementRaftReader(groupID: groupID, peers: roster, transport: transports[3])
                #expect(try await reader.load(deadline: .now + .seconds(3)) == takenOver)
                await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
                    _ = try await transports[3].vote(.init(groupID: groupID, candidate: ids[0], term: 99,
                        lastIndex: 0, lastTerm: 0), to: ids[1], deadline: .now + .seconds(2))
                }
                await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
                    _ = try await transports[3].write(.init(command: complete, expected: withdrawn,
                        requestID: transferID, certificate: nil), to: ids[0], deadline: .now + .seconds(2))
                }
                #expect(await voters[1].inspection().state.term < 99)
                // Stop room-independent discovery/transport only after the
                // service's owned election tasks have actually exited.
            } catch { failure = error }
            for task in tasks { task.cancel() }
            for task in tasks {
                if case .failure(let error) = await task.result, !(error is CancellationError) {
                    Issue.record("Unexpected driver failure: \(error)")
                }
            }
            if let failure { throw failure }
        }
    }
}
