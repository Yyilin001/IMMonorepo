import DistributedCluster
import Foundation
import IMV2ActorContracts

/// A separate mTLS control node. It starts before room registration and owns
/// no room activation, SQL connection or database qualification. Its lifetime
/// ends only after actual inbound and outbound work settles; callers then stop
/// voters and close stable storage. Discovery does not grant a voting role.
package actor V2PlacementRaftNode {
    private let configuration: V2RoomClusterClientNodeConfiguration
    private let identity: V2ActorHostIdentity
    private let signer: V2ActorSigningIdentity
    private let trust: V2ActorTrustStore
    private let limits: V2ActorAuthenticationLimits
    private let endpointService: V2PlacementRaftEndpoint
    private let shards: Set<String>
    private let runtime: V2RoomRuntimeConfiguration
    private var system: ClusterSystem?
    private var inbound: V2PlacementRaftInboundService?
    private var endpoint: V2RoomHostEndpoint?
    private var publisher: V2RoomDiscoveryPublisherState?
    private var beacon: V2RoomDiscoveryBeacon?
    private var discovery: V2RoomClusterDiscovery?
    private var client: V2RoomClusterClient?
    private var starting = false
    private var closing = false
    private var stopping = false

    package init(configuration: V2RoomClusterClientNodeConfiguration, identity: V2ActorHostIdentity,
                 signer: V2ActorSigningIdentity, trust: V2ActorTrustStore, limits: V2ActorAuthenticationLimits,
                 endpoint: V2PlacementRaftEndpoint, shards: Set<String>) throws {
        guard identity.hostID == endpoint.localID, shards == endpoint.shards, !shards.isEmpty, shards.count <= 256,
              shards.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              try trust.configuredHostServiceID(for: identity.hostID, requiring: [.placementVote]) == signer.serviceID else {
            throw V2PlacementRaftError.invalidConfiguration
        }
        self.configuration = configuration; self.identity = identity; self.signer = signer; self.trust = trust
        self.limits = limits; self.endpointService = endpoint; self.shards = shards
        self.runtime = try .init(maximumConcurrentResolutions: 8)
    }
    package func start(discovery configuration: V2RoomDiscoveryConfiguration) async throws
        -> (client: V2RoomClusterClient, descriptor: V2RoomClusterHostDescriptor) {
        guard !closing, !starting, system == nil else { throw V2PlacementRaftError.closed }
        starting = true
        defer { starting = false }
        try await endpointService.validateTrust(trust)
        var settings = ClusterSystemSettings(name: self.configuration.name, host: self.configuration.host,
            port: self.configuration.port, tls: self.configuration.tls)
        settings.threadPoolSize = self.configuration.threadPoolSize
        settings.serialization.binaryDistributedInvocations = true
        settings.downingStrategy = .none; settings.onDownAction = .none
        settings.maximumInboundFrameBytes = try ClusterInboundFrameLimit(
            bytes: max(limits.maximumRequestBytes, limits.maximumReplyBytes) * 2 + 65_536)
        settings.serialization.registerInbound(V2ActorAuthenticationError.self)
        settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [V2ActorAuthenticationError.self])
        let system = await ClusterSystem(self.configuration.name, settings: settings)
        self.system = system
        do {
            guard !closing else { throw V2PlacementRaftError.closed }
            let inbound = try V2PlacementRaftInboundService(identity: identity, signer: signer, trust: trust,
                limits: limits, endpoint: endpointService)
            let endpoint = V2RoomHostEndpoint(actorSystem: system, service: inbound)
            self.inbound = inbound; self.endpoint = endpoint
            let descriptor = try V2RoomClusterHostDescriptor(identity: identity, endpointID: endpoint.id,
                address: self.configuration.host, port: self.configuration.port, accessibleShardIDs: shards,
                availableRooms: 1, isHealthy: true)
            let publisher = V2RoomDiscoveryPublisherState()
            let beacon = V2RoomDiscoveryBeacon(actorSystem: system, descriptor: descriptor, signer: signer, state: publisher)
            self.publisher = publisher; self.beacon = beacon
            await system.receptionist.checkIn(beacon, with: V2RoomDiscoveryBeacon.key(for: identity.hostID))
            guard !closing else { throw V2PlacementRaftError.closed }
            let client = V2RoomClusterClient(system: system, signer: signer, trust: trust, limits: limits,
                configuration: runtime, callerIncarnation: identity.incarnationID)
            self.client = client
            let discovery = V2RoomClusterDiscovery(system: system, client: client, trust: trust, configuration: configuration)
            self.discovery = discovery
            await discovery.start()
            guard !closing else { throw V2PlacementRaftError.closed }
            return (client, descriptor)
        } catch {
            // Cleanup owns real native work, not a synthetic "stopped" flag.
            // Nothing was returned, so no external driver can be dispatching.
            closing = true
            await publisher?.beginDrain()
            await discovery?.stop()
            await inbound?.stop()
            await client?.stop()
            guard await discovery?.quiesce(deadline: .now + .seconds(30)) ?? true,
                  await client?.quiesce(deadline: .now + .seconds(30)) ?? true else {
                throw V2PlacementRaftError.incompleteShutdown
            }
            try await system.shutdown().wait()
            clear()
            throw error
        }
    }
    package func bind(_ logs: [String: V2PlacementRaftLeaderLog]) async throws {
        guard !closing else { throw V2PlacementRaftError.closed }
        try await endpointService.bind(logs)
    }
    package func stop(deadline: ContinuousClock.Instant) async throws -> Bool {
        closing = true
        while (starting || stopping) && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return false }
        }
        guard !starting, !stopping else { return false }
        guard let system else { return true }
        stopping = true
        defer { stopping = false }
        await publisher?.beginDrain()
        await inbound?.beginDrain()
        await discovery?.stop()
        await client?.stop()
        guard await inbound?.quiesce(deadline: deadline) ?? true,
              await discovery?.quiesce(deadline: deadline) ?? true,
              await client?.quiesce(deadline: deadline) ?? true else { return false }
        await inbound?.stop()
        try await system.shutdown().wait()
        clear()
        return true
    }
    private func clear() {
        system = nil; inbound = nil; endpoint = nil; publisher = nil; beacon = nil; discovery = nil; client = nil
    }
}
