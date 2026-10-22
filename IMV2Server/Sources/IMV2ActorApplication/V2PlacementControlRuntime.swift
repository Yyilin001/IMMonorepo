import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ServerInfrastructure
import NIOPosix

/// Owns the control network, durable voters and election tasks independently
/// of room services. It remains alive through room registration and retirement.
package actor V2PlacementControlRuntime {
    private enum Node: Sendable {
        case voter(V2PlacementRaftNode)
        case caller(V2RoomClusterClientNode)
    }
    private let configuration: V2RoomActorApplicationConfiguration
    private var node: Node?
    private var pool: NIOThreadPool?
    private var stores: [V2PlacementRaftFileStorage] = []
    private var voters: [String: V2PlacementRaftVoter] = [:]
    private var drivers: [Task<Void, any Error>] = []
    private var starting = false
    private var started = false
    private var closing = false
    private var stopping = false
    private var trustAdmissions: V2ActorTrustAdmissionSource?

    package init(configuration: V2RoomActorApplicationConfiguration) { self.configuration = configuration }

    package func start() async throws -> V2RoomActorPlacementRuntime {
        guard !started, !closing else { throw V2PlacementRaftError.closed }
        started = true; starting = true
        defer { starting = false }
        if let directory = configuration.trustAdmissionDirectory {
            let source = try V2ActorTrustAdmissionSource(directory: directory, trust: configuration.trust)
            trustAdmissions = source
            try await source.start()
            guard !closing else { throw V2PlacementRaftError.closed }
        }
        let control = configuration.placementControl
        let roster = Set(control.roles.values)
        var initial: [String: V2ActorPlacementSnapshot] = [:]
        for shard in control.shards {
            initial[shard] = try V2RoomActorPlacementRuntime.initialSnapshot(deploymentID: control.clusterID, shard: shard, peers: configuration.discovery.peers)
        }
        let client: V2RoomClusterClient
        var leaders: [String: V2PlacementRaftLeaderLog] = [:]
        if let identity = control.identity {
            let pool = NIOThreadPool(numberOfThreads: 2); pool.start(); self.pool = pool
            for shard in control.shards.sorted() {
                guard let path = control.storagePaths[shard], let snapshot = initial[shard] else {
                    throw V2PlacementRaftError.invalidConfiguration
                }
                let storage = try await V2PlacementRaftFileStorage.open(at: path, pool: pool)
                stores.append(storage)
                voters[shard] = try await V2PlacementRaftVoter.open(id: identity.hostID, groupID: snapshot.clusterID,
                                                                  voters: roster, storage: storage)
            }
            let endpoint = try await V2PlacementRaftEndpoint.open(voters: voters, localID: identity.hostID,
                roles: control.roles, readers: control.readers, writers: control.writers, roomHosts: control.roomHosts)
            let node = try V2PlacementRaftNode(configuration: control.node, identity: identity,
                signer: configuration.signer, trust: configuration.trust, limits: configuration.authentication,
                endpoint: endpoint, shards: control.shards)
            self.node = .voter(node)
            client = try await node.start(discovery: control.discovery).client
            for shard in control.shards.sorted() {
                let transport = Self.transport(shard: shard, client: client)
                let voter = voters[shard]!
                leaders[shard] = try .init(voter: voter, id: identity.hostID, groupID: initial[shard]!.clusterID,
                                          voters: roster, transport: transport)
            }
            try await node.bind(leaders)
            for shard in control.shards.sorted() {
                let driver = try V2PlacementRaftDriver(voter: voters[shard]!, id: identity.hostID,
                    voters: roster, transport: Self.transport(shard: shard, client: client))
                drivers.append(Task { try await driver.run() })
            }
        } else {
            let node = V2RoomClusterClientNode(configuration: control.node, signer: configuration.signer,
                trust: configuration.trust, authenticationLimits: configuration.authentication,
                runtimeConfiguration: configuration.runtime, callerIncarnation: control.processIncarnation)
            self.node = .caller(node)
            client = try await node.start(discovery: control.discovery)
        }
        var logs: [String: any V2ActorPlacementLog] = [:], snapshots: [String: V2ActorPlacementSnapshot] = [:]
        let deadline = ContinuousClock.now + .seconds(30)
        for shard in control.shards.sorted() {
            let transport = Self.transport(shard: shard, client: client), genesis = initial[shard]!
            let reader = try V2PlacementRaftReader(groupID: genesis.clusterID, peers: roster, transport: transport)
            let remote = try V2PlacementRaftRemoteLog(groupID: genesis.clusterID, shardID: shard, peers: roster,
                reader: reader, transport: transport, signer: configuration.signer)
            while snapshots[shard] == nil {
                try Task.checkCancellation()
                guard !closing, ContinuousClock.now < deadline else { throw V2ActorPlacementError.unavailable }
                if let leader = leaders[shard], await voters[shard]!.inspection().role == .leader {
                    do { _ = try await leader.open(genesis) }
                    catch V2PlacementRaftError.notLeader {} catch V2PlacementRaftError.notReady {} catch V2ActorPlacementError.unavailable {}
                }
                // Allow one bounded contact per fixed voter. A 500 ms outer
                // window could repeatedly expire on the first slow peer.
                do { snapshots[shard] = try await reader.load(deadline: min(deadline, .now + .seconds(3))) }
                catch V2ActorPlacementError.unavailable {}
            }
            logs[shard] = remote
        }
        return try .init(logs: logs, snapshots: snapshots)
    }

    private static func transport(shard: String, client: V2RoomClusterClient) -> V2PlacementRaftClusterTransport {
        .init(shardID: shard, client: client, resolve: { peer, _ in
            try client.resolvePolicyHost(hostID: peer, endpoint: shard)
        })
    }

    package func stop(deadline: ContinuousClock.Instant) async throws -> Bool {
        closing = true
        // TERM cancels the supervisor's monitor before it closes this runtime.
        // Cleanup must still join trust scans, RPC work and physical resources.
        // The caller owns and awaits this task; its explicit deadline, rather
        // than the caller's cancellation flag, bounds the drain.
        let drain = Task { try await self.stopOwned(deadline: deadline) }
        return try await drain.value
    }

    private func stopOwned(deadline: ContinuousClock.Instant) async throws -> Bool {
        while (starting || stopping) && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return false }
        }
        guard !starting, !stopping else { return false }
        stopping = true
        defer { stopping = false }
        if let trustAdmissions {
            guard try await trustAdmissions.stop(deadline: deadline) else { return false }
            self.trustAdmissions = nil
        }
        for task in drivers { task.cancel() }
        // The RPC transport bounds cancellation while native remote persistence
        // remains owned by the receiving voter until it actually settles.
        for task in drivers { _ = await task.result }
        drivers.removeAll()
        if let node {
            let stopped: Bool
            switch node {
            case .voter(let voter): stopped = try await voter.stop(deadline: deadline)
            case .caller(let caller): stopped = try await caller.stop(deadline: deadline)
            }
            guard stopped else { return false }
            self.node = nil
        }
        for voter in voters.values { await voter.stop() }
        voters.removeAll()
        for store in stores { try await store.close() }
        stores.removeAll()
        if let pool { try await pool.shutdownGracefully(); self.pool = nil }
        return true
    }
}
