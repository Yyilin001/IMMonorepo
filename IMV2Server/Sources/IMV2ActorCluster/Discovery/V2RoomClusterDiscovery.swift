import Distributed
import DistributedCluster
import Foundation
import IMV2ActorContracts

/// A fixed deployment entry. The receptionist only supplies candidate ActorIDs;
/// it cannot grant host identity, service role, shard access or capacity.
public struct V2RoomDiscoveryPeer: Sendable {
    public let hostID: V2ActorHostID
    public let serviceID: V2ActorServiceID
    public let address: String
    public let port: Int
    public let accessibleShardIDs: Set<String>
    public let maximumRooms: Int

    public init(hostID: V2ActorHostID, serviceID: V2ActorServiceID,
                address: String, port: Int, accessibleShardIDs: Set<String>,
                maximumRooms: Int) throws {
        guard !address.isEmpty, (1...65_535).contains(port),
              !accessibleShardIDs.isEmpty, (1...65_536).contains(maximumRooms)
        else { throw V2ActorAuthenticationError.invalidConfiguration }
        self.hostID = hostID
        self.serviceID = serviceID
        self.address = address
        self.port = port
        self.accessibleShardIDs = accessibleShardIDs
        self.maximumRooms = maximumRooms
    }
}

public struct V2RoomDiscoveryConfiguration: Sendable {
    public let peers: [V2RoomDiscoveryPeer]
    public let pollInterval: Duration
    public let probeTimeout: Duration
    public let failedHostGrace: Duration
    public let maximumCandidatesPerHost: Int
    public let maximumConcurrentProbes: Int

    public init(peers: [V2RoomDiscoveryPeer], pollInterval: Duration = .seconds(1),
                probeTimeout: Duration = .seconds(2), failedHostGrace: Duration = .seconds(5),
                maximumCandidatesPerHost: Int = 4,
                maximumConcurrentProbes: Int = 8) throws {
        guard !peers.isEmpty, peers.count <= 64,
              Set(peers.map(\.hostID)).count == peers.count,
              pollInterval >= .milliseconds(100), pollInterval <= .seconds(60),
              probeTimeout >= .milliseconds(50), probeTimeout <= .seconds(10),
              failedHostGrace >= .seconds(2), failedHostGrace <= .seconds(60),
              (1...8).contains(maximumCandidatesPerHost),
              (1...64).contains(maximumConcurrentProbes)
        else { throw V2ActorAuthenticationError.invalidConfiguration }
        self.peers = peers
        self.pollInterval = pollInterval
        self.probeTimeout = probeTimeout
        self.failedHostGrace = failedHostGrace
        self.maximumCandidatesPerHost = maximumCandidatesPerHost
        self.maximumConcurrentProbes = maximumConcurrentProbes
    }
}

/// A fresh challenge prevents replay of an old host advertisement after a
/// process restart. The signed endpoint and beacon must belong to one node.
public struct V2RoomDiscoveryAdvertisement: Codable, Sendable {
    public static let version = 1
    public let version: Int
    public let challenge: UUID
    public let identity: V2ActorHostIdentity
    public let beaconID: ClusterSystem.ActorID
    public let endpointID: ClusterSystem.ActorID
    public let availableRooms: Int
    public let isHealthy: Bool

    public init(challenge: UUID, identity: V2ActorHostIdentity,
                beaconID: ClusterSystem.ActorID, endpointID: ClusterSystem.ActorID,
                availableRooms: Int, isHealthy: Bool) {
        self.version = Self.version
        self.challenge = challenge
        self.identity = identity
        self.beaconID = beaconID
        self.endpointID = endpointID
        self.availableRooms = availableRooms
        self.isHealthy = isHealthy
    }
}

/// One local publisher per ClusterSystem. It is checked in under a key derived
/// from the configured stable host ID, never once per room activation.
public actor V2RoomDiscoveryPublisherState {
    private var accepting = true

    public init() {}
    public func beginDrain() { accepting = false }
    public func isAccepting() -> Bool { accepting }
}

public distributed actor V2RoomDiscoveryBeacon {
    public typealias ActorSystem = ClusterSystem
    private let descriptor: V2RoomClusterHostDescriptor
    private let signer: V2ActorSigningIdentity
    private let state: V2RoomDiscoveryPublisherState

    public static func key(for hostID: V2ActorHostID) -> DistributedReception.Key<V2RoomDiscoveryBeacon> {
        .init(V2RoomDiscoveryBeacon.self, id: "imv2/room-host/v1/\(hostID.rawValue)")
    }

    public init(actorSystem: ClusterSystem, descriptor: V2RoomClusterHostDescriptor,
                signer: V2ActorSigningIdentity, state: V2RoomDiscoveryPublisherState) {
        self.actorSystem = actorSystem
        self.descriptor = descriptor
        self.signer = signer
        self.state = state
    }

    public distributed func advertise(_ challenge: UUID) async throws -> V2ActorSignedPacket {
        try signer.sign(V2RoomDiscoveryAdvertisement(
            challenge: challenge, identity: descriptor.identity,
            beaconID: id, endpointID: descriptor.endpointID,
            availableRooms: descriptor.availableRooms,
            isHealthy: await state.isAccepting() && descriptor.isHealthy
        ), maximumBytes: 16_384)
    }
}

public struct V2RoomDiscoverySnapshot: Sendable {
    public let activeHosts: Int
    public let pendingRetiredNodes: Int
    public let oversizedLookups: UInt64
    public let completedPolls: UInt64
    public let inFlightProbes: Int
    public let isPolling: Bool
    public let isStopped: Bool
}

/// One polling task and bounded, tracked probes. The vendor's
/// GuestListing uses an unbounded AsyncStream, so it is deliberately unused.
public actor V2RoomClusterDiscovery {
    private let system: ClusterSystem
    private let client: V2RoomClusterClient
    private let trust: V2ActorTrustStore
    private let configuration: V2RoomDiscoveryConfiguration
    private var active: [V2ActorHostID: V2RoomClusterHostDescriptor] = [:]
    private var activeBeaconIDs: [V2ActorHostID: ClusterSystem.ActorID] = [:]
    private var lastVerifiedAt: [V2ActorHostID: ContinuousClock.Instant] = [:]
    private var failedNodesDowned: [V2ActorHostID: Cluster.Node] = [:]
    private var pendingDown: [RetiredNode] = []
    private var nextJoinAllowed: [V2ActorHostID: ContinuousClock.Instant] = [:]
    private var polling = false
    private var accepting = true
    private var worker: Task<Void, Never>?
    private var oversizedLookups: UInt64 = 0
    private var completedPolls: UInt64 = 0
    private var probes: [UUID: ProbeCall] = [:]

    public init(system: ClusterSystem, client: V2RoomClusterClient,
                trust: V2ActorTrustStore, configuration: V2RoomDiscoveryConfiguration) {
        self.system = system
        self.client = client
        self.trust = trust
        self.configuration = configuration
    }

    public func start() {
        guard accepting, worker == nil else { return }
        for peer in configuration.peers {
            system.cluster.join(host: peer.address, port: peer.port)
            nextJoinAllowed[peer.hostID] = .now + .seconds(5)
        }
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollOnce()
                do { try await Task.sleep(for: self.configuration.pollInterval) }
                catch { break }
            }
            await self.workerFinished()
        }
    }

    public func pollOnce() async {
        guard accepting, !polling else { return }
        polling = true
        defer {
            polling = false
            completedPolls &+= 1
        }
        await reapRetiredNodes()
        for peer in configuration.peers {
            guard accepting, !Task.isCancelled else { return }
            let found = await system.receptionist.lookup(V2RoomDiscoveryBeacon.key(for: peer.hostID))
            // Check cardinality before sorting, probing, or creating a child task.
            guard found.count <= configuration.maximumCandidatesPerHost else {
                oversizedLookups &+= 1
                await markUnhealthy(peer)
                continue
            }
            let previousBeaconID = activeBeaconIDs[peer.hostID]
            let candidates = found.sorted {
                if $0.id == previousBeaconID { return true }
                if $1.id == previousBeaconID { return false }
                return $0.id < $1.id
            }
            var accepted: V2RoomClusterHostDescriptor?
            var acceptedBeaconID: ClusterSystem.ActorID?
            for beacon in candidates {
                guard accepting, !Task.isCancelled else { return }
                do {
                    accepted = try await probe(beacon, peer: peer)
                    acceptedBeaconID = beacon.id
                    break
                } catch { continue }
            }
            if let accepted {
                guard accepting else { return }
                do {
                    let replaced: RetiredNode?
                    if let previous = active[peer.hostID],
                       previous.identity != accepted.identity,
                       let oldBeacon = activeBeaconIDs[peer.hostID] {
                        replaced = .init(identity: previous.identity, node: oldBeacon.node)
                    } else {
                        replaced = nil
                    }
                    guard pendingDown.count < 512 || replaced == nil else {
                        await markUnhealthy(peer)
                        continue
                    }
                    try await client.installDiscovered(accepted)
                    active[peer.hostID] = accepted
                    activeBeaconIDs[peer.hostID] = acceptedBeaconID
                    lastVerifiedAt[peer.hostID] = .now
                    failedNodesDowned.removeValue(forKey: peer.hostID)
                    if let replaced { pendingDown.append(replaced) }
                } catch {
                    await markUnhealthy(peer)
                }
            } else {
                await markUnhealthy(peer)
                await downFailedNodeIfSafe(peer)
                // Cluster.Node includes a process incarnation. Rejoin the
                // configured endpoint when the old process disappears.
                if ContinuousClock.now >= nextJoinAllowed[peer.hostID, default: .now] {
                    system.cluster.join(host: peer.address, port: peer.port)
                    nextJoinAllowed[peer.hostID] = .now + .seconds(5)
                }
            }
        }
        await reapRetiredNodes()
    }

    private func probe(_ beacon: V2RoomDiscoveryBeacon,
                       peer: V2RoomDiscoveryPeer) async throws -> V2RoomClusterHostDescriptor {
        let node = beacon.id.node.endpoint
        guard node.host == peer.address, node.port == peer.port else {
            throw V2ActorAuthenticationError.wrongRecipient
        }
        let challenge = UUID()
        let packet = try await boundedAdvertisement(beacon, challenge: challenge)
        let (body, signer) = try trust.verify(packet,
            as: V2RoomDiscoveryAdvertisement.self, maximumBytes: 16_384)
        guard body.version == V2RoomDiscoveryAdvertisement.version,
              body.challenge == challenge, body.beaconID == beacon.id,
              body.endpointID.node == beacon.id.node,
              body.identity.hostID == peer.hostID,
              packet.signerID == peer.serviceID,
              signer.hostedIDs.contains(peer.hostID),
              body.availableRooms >= 0
        else { throw V2ActorAuthenticationError.wrongRecipient }
        return try V2RoomClusterHostDescriptor(
            identity: body.identity, endpointID: body.endpointID,
            address: peer.address, port: peer.port,
            accessibleShardIDs: peer.accessibleShardIDs,
            availableRooms: min(body.availableRooms, peer.maximumRooms),
            isHealthy: body.isHealthy
        )
    }

    /// A timed-out caller leaves the real remote-call task in this bounded
    /// registry until it actually exits. No new poll can hide a hung call by
    /// starting unbounded replacement tasks.
    private func boundedAdvertisement(_ beacon: V2RoomDiscoveryBeacon,
                                      challenge: UUID) async throws -> V2ActorSignedPacket {
        guard probes.count < configuration.maximumConcurrentProbes else {
            throw V2ActorAuthenticationError.overloaded
        }
        let callID = UUID()
        let transportTimeout = configuration.probeTimeout + .seconds(1)
        return try await withCheckedThrowingContinuation { continuation in
            let operation = Task { [weak self] in
                let result: Result<V2ActorSignedPacket, any Error>
                do {
                    // Keep the transport's own bound slightly beyond the
                    // waiting caller's deadline so timeout never makes the
                    // still-running RPC disappear from the registry.
                    result = .success(try await RemoteCall.with(
                        timeout: transportTimeout) {
                        try await beacon.advertise(challenge)
                    })
                }
                catch { result = .failure(error) }
                await self?.completeProbe(callID, result: result)
            }
            let timer = Task { [weak self, timeout = configuration.probeTimeout] in
                do { try await Task.sleep(for: timeout) }
                catch { return }
                await self?.expireProbe(callID)
            }
            probes[callID] = .init(operation: operation, timer: timer,
                                   continuation: continuation)
        }
    }

    private func expireProbe(_ callID: UUID) {
        guard var probe = probes[callID], let continuation = probe.continuation else { return }
        probe.continuation = nil
        probes[callID] = probe
        continuation.resume(throwing: V2ActorAuthenticationError.overloaded)
    }

    private func completeProbe(_ callID: UUID,
                               result: Result<V2ActorSignedPacket, any Error>) {
        guard let probe = probes.removeValue(forKey: callID) else { return }
        probe.timer.cancel()
        probe.continuation?.resume(with: result)
    }

    private func markUnhealthy(_ peer: V2RoomDiscoveryPeer) async {
        guard let previous = active[peer.hostID], previous.isHealthy else { return }
        guard let unhealthy = try? V2RoomClusterHostDescriptor(
            identity: previous.identity, endpointID: previous.endpointID,
            address: peer.address, port: peer.port,
            accessibleShardIDs: peer.accessibleShardIDs,
            availableRooms: 0, isHealthy: false
        ) else { return }
        try? await client.installDiscovered(unhealthy)
        active[peer.hostID] = unhealthy
    }

    private func downFailedNodeIfSafe(_ peer: V2RoomDiscoveryPeer) async {
        guard let descriptor = active[peer.hostID],
              let oldNode = activeBeaconIDs[peer.hostID]?.node,
              failedNodesDowned[peer.hostID] != oldNode,
              let verifiedAt = lastVerifiedAt[peer.hostID],
              verifiedAt.duration(to: .now) >= configuration.failedHostGrace,
              await client.suspendUnreachableHost(descriptor.identity) else { return }
        // This retires only Cluster's old physical association after a grace
        // period with no authenticated response or outstanding application
        // work. It never releases or steals a room's DB activation lease.
        failedNodesDowned[peer.hostID] = oldNode
        system.cluster.down(member: .init(node: oldNode, status: .up))
        system.cluster.join(host: peer.address, port: peer.port)
        nextJoinAllowed[peer.hostID] = .now + .seconds(5)
    }

    private func reapRetiredNodes() async {
        guard !pendingDown.isEmpty else { return }
        var stillPending: [RetiredNode] = []
        for retired in pendingDown {
            if await client.retiredIdentityIsDrained(retired.identity) {
                // Construct the exact old Node identity. The endpoint-only
                // overload could accidentally down its new incarnation.
                system.cluster.down(member: .init(node: retired.node, status: .up))
            } else {
                stillPending.append(retired)
            }
        }
        pendingDown = stillPending
    }

    public func stop() {
        accepting = false
        worker?.cancel()
        for callID in probes.keys {
            expireProbe(callID)
            probes[callID]?.operation.cancel()
        }
    }

    public func quiesce(deadline: ContinuousClock.Instant) async -> Bool {
        stop()
        while (worker != nil || polling || !probes.isEmpty) && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { break }
        }
        return worker == nil && !polling && probes.isEmpty
    }

    private func workerFinished() { worker = nil }

    public func snapshot() -> V2RoomDiscoverySnapshot {
        .init(activeHosts: active.values.filter(\.isHealthy).count,
              pendingRetiredNodes: pendingDown.count,
              oversizedLookups: oversizedLookups, completedPolls: completedPolls,
              inFlightProbes: probes.count,
              isPolling: polling, isStopped: !accepting)
    }

    private struct RetiredNode: Sendable {
        let identity: V2ActorHostIdentity
        let node: Cluster.Node
    }

    private struct ProbeCall {
        let operation: Task<Void, Never>
        let timer: Task<Void, Never>
        var continuation: CheckedContinuation<V2ActorSignedPacket, any Error>?
    }
}
