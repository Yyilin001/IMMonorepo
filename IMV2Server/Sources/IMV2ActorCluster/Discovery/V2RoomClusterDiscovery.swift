import Distributed
import DistributedCluster
import Foundation
import IMV2ActorContracts

/// 经授权的部署条目。接待员只提供候选 ActorID，
/// 不能授予宿主身份、服务角色、分片访问权或容量。
public struct V2RoomDiscoveryPeer: Codable, Equatable, Sendable {
    public let hostID: V2ActorHostID
    public let serviceID: V2ActorServiceID
    public let address: String
    public let port: Int
    public let accessibleShardIDs: Set<String>
    public let maximumRooms: Int

    public init(hostID: V2ActorHostID, serviceID: V2ActorServiceID,
                address: String, port: Int, accessibleShardIDs: Set<String>,
                maximumRooms: Int) throws {
        guard !address.isEmpty, address.utf8.count <= 253, address != "0.0.0.0", address != "::",
              (1...65_535).contains(port), !accessibleShardIDs.isEmpty, accessibleShardIDs.count <= 256,
              accessibleShardIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              (1...65_536).contains(maximumRooms)
        else { throw V2ActorAuthenticationError.invalidConfiguration }
        self.hostID = hostID
        self.serviceID = serviceID
        self.address = address
        self.port = port
        self.accessibleShardIDs = accessibleShardIDs
        self.maximumRooms = maximumRooms
    }
    private enum CodingKeys: CodingKey { case hostID, serviceID, address, port, accessibleShardIDs, maximumRooms }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let shards = try values.decode([String].self, forKey: .accessibleShardIDs)
        guard Set(shards).count == shards.count else { throw V2ActorAuthenticationError.invalidConfiguration }
        try self.init(hostID: values.decode(V2ActorHostID.self, forKey: .hostID),
            serviceID: values.decode(V2ActorServiceID.self, forKey: .serviceID),
            address: values.decode(String.self, forKey: .address), port: values.decode(Int.self, forKey: .port),
            accessibleShardIDs: Set(shards), maximumRooms: values.decode(Int.self, forKey: .maximumRooms))
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(hostID, forKey: .hostID); try values.encode(serviceID, forKey: .serviceID)
        try values.encode(address, forKey: .address); try values.encode(port, forKey: .port)
        try values.encode(accessibleShardIDs.sorted(), forKey: .accessibleShardIDs)
        try values.encode(maximumRooms, forKey: .maximumRooms)
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

/// 新的挑战值可防止进程重启后重放旧的宿主通告。
/// 已签名的端点和信标必须属于同一节点。
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

/// 每个 ClusterSystem 只有一个本地发布者，使用由配置的稳定宿主 ID
/// 推导出的键登记，绝非每次房间激活都登记一次。
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

/// 使用一个轮询任务和数量有界、可追踪的探测。
/// 供应商的 GuestListing 使用无界 AsyncStream，因此这里有意不采用。
public actor V2RoomClusterDiscovery {
    private let system: ClusterSystem
    private let client: V2RoomClusterClient
    private let trust: V2ActorTrustStore
    private let configuration: V2RoomDiscoveryConfiguration
    private var peers: [V2RoomDiscoveryPeer]
    private var peerRevision: UInt64 = 0
    private var updatingPeers = false
    private var authorizationSuspended = false
    private var active: [V2ActorHostID: V2RoomClusterHostDescriptor] = [:]
    private var activeBeaconIDs: [V2ActorHostID: ClusterSystem.ActorID] = [:]
    private var lastVerifiedAt: [V2ActorHostID: ContinuousClock.Instant] = [:]
    private var failedNodesSuspended: [V2ActorHostID: Cluster.Node] = [:]
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
        self.peers = configuration.peers
    }

    public func start() {
        guard accepting, worker == nil else { return }
        for peer in peers {
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

    /// Only a certified control-state consumer may call this entry point.
    /// Endpoint, shard scopes and capacity must come from that authorized state;
    /// authenticated advertisements alone cannot enlarge them.
    package func installAuthorizedPeers(_ proposed: [V2RoomDiscoveryPeer], revision: UInt64) async throws {
        guard accepting, !updatingPeers else { throw V2ActorAuthenticationError.overloaded }
        guard revision > 0, proposed.count <= 64,
              Set(proposed.map(\.hostID)).count == proposed.count else {
            throw V2ActorAuthenticationError.invalidConfiguration
        }
        let normalized = proposed.sorted { $0.hostID.rawValue < $1.hostID.rawValue }
        guard revision >= peerRevision else { throw V2ActorPlacementError.staleRevision }
        if revision == peerRevision {
            guard normalized == peers.sorted(by: { $0.hostID.rawValue < $1.hostID.rawValue }) else {
                throw V2ActorPlacementError.invalidTransition
            }
            if !authorizationSuspended { return }
        }
        for peer in normalized {
            guard try trust.configuredHostServiceID(for: peer.hostID) == peer.serviceID else {
                throw V2ActorAuthenticationError.forbidden
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: normalized.map { ($0.hostID, $0) })
        // Retained identities cannot silently move endpoints or gain scope.
        guard peers.allSatisfy({ byID[$0.hostID] == nil || byID[$0.hostID] == $0 }) else {
            throw V2ActorPlacementError.invalidTransition
        }
        updatingPeers = true
        defer { updatingPeers = false }
        // Join the old poll, including any awaited directory publication. This
        // prevents an old successful probe from resurrecting a removed route.
        while polling {
            try Task.checkCancellation()
            guard accepting else { throw V2ActorAuthenticationError.overloaded }
            try await Task.sleep(for: .milliseconds(5))
        }
        try Task.checkCancellation()
        guard accepting else { throw V2ActorAuthenticationError.overloaded }
        for peer in peers where byID[peer.hostID] == nil {
            if let descriptor = active[peer.hostID] {
                // Close new admission but allow existing grants to settle.
                // Removal is not proof of process death: never down its Node.
                _ = await client.suspendUnreachableHost(descriptor.identity)
            }
            active.removeValue(forKey: peer.hostID)
            activeBeaconIDs.removeValue(forKey: peer.hostID)
            lastVerifiedAt.removeValue(forKey: peer.hostID)
            failedNodesSuspended.removeValue(forKey: peer.hostID)
            nextJoinAllowed.removeValue(forKey: peer.hostID)
        }
        peers = normalized
        peerRevision = revision
        authorizationSuspended = false
        guard accepting else { return }
        for peer in peers where nextJoinAllowed[peer.hostID] == nil {
            system.cluster.join(host: peer.address, port: peer.port)
            nextJoinAllowed[peer.hostID] = .now + .seconds(5)
        }
    }

    package func suspendAuthorization() async {
        authorizationSuspended = true
        while polling {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
        }
        for peer in peers {
            await markUnhealthy(peer)
            if let descriptor = active[peer.hostID] {
                _ = await client.suspendUnreachableHost(descriptor.identity)
            }
        }
    }

    public func pollOnce() async {
        guard accepting, !polling, !updatingPeers, !authorizationSuspended else { return }
        polling = true
        defer {
            polling = false
            completedPolls &+= 1
        }
        await reapRetiredNodes()
        for peer in peers {
            guard accepting, !Task.isCancelled else { return }
            let found = await system.receptionist.lookup(V2RoomDiscoveryBeacon.key(for: peer.hostID))
            // 在排序、探测或创建子任务前先检查数量上限。
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
                    failedNodesSuspended.removeValue(forKey: peer.hostID)
                    if let replaced { pendingDown.append(replaced) }
                } catch {
                    await markUnhealthy(peer)
                }
            } else {
                await markUnhealthy(peer)
                await suspendFailedNodeIfSafe(peer)
                // Cluster.Node 包含进程实例标识。旧进程消失后，
                // 重新加入配置的端点。
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

    /// 调用方超时后，真实的远程调用任务仍留在此有界注册表中，直至实际退出。
    /// 新的轮询不能通过无限创建替代任务掩盖卡住的调用。
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
                    // 传输自身的截止时间略晚于等待中的调用方，
                    // 避免超时让仍在运行的 RPC 从注册表中消失。
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

    private func suspendFailedNodeIfSafe(_ peer: V2RoomDiscoveryPeer) async {
        guard let descriptor = active[peer.hostID],
              let oldNode = activeBeaconIDs[peer.hostID]?.node,
              failedNodesSuspended[peer.hostID] != oldNode,
              let verifiedAt = lastVerifiedAt[peer.hostID],
              verifiedAt.duration(to: .now) >= configuration.failedHostGrace,
              await client.suspendUnreachableHost(descriptor.identity) else { return }
        // Missing health is reversible, not evidence that this live process
        // died. Close local admission and discard sessions only after actual
        // work settles; authenticated discovery may resume this exact UID.
        failedNodesSuspended[peer.hostID] = oldNode

    }

    private func reapRetiredNodes() async {
        guard !pendingDown.isEmpty else { return }
        var stillPending: [RetiredNode] = []
        for retired in pendingDown {
            if await client.retiredIdentityIsDrained(retired.identity) {
                // 构造旧 Node 的精确标识。仅凭端点的重载方法
                // 可能意外地把新实例标记为下线。
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
        while (worker != nil || polling || updatingPeers || !probes.isEmpty) && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { break }
        }
        return worker == nil && !polling && !updatingPeers && probes.isEmpty
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
