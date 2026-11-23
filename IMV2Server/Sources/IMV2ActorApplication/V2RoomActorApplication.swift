import Foundation
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Server
import IMV2ServerInfrastructure

public enum V2RoomActorApplicationError: Error, Sendable {
    case invalidRole
    case incompleteShutdown
}

/// Policy hosting binds room construction and mutation endpoints as one configuration.
public struct V2PolicyHostedServices: Sendable {
    package var clientBinding: V2PolicyClusterClientBinding? = nil
    package var forwardPairs: V2RoomForwardPairService? = nil
    public let placement: V2PolicyOwnerPlacementConfiguration
    public let ownership: any V2PolicyOwnershipServing
    public let mutations: any V2PolicyMutationServing
    public init(placement: V2PolicyOwnerPlacementConfiguration, ownership: any V2PolicyOwnershipServing,
        mutations: any V2PolicyMutationServing) {
        self.placement = placement; self.ownership = ownership; self.mutations = mutations
    }
    package func bindingClient(_ binding: V2PolicyClusterClientBinding) -> Self {
        var copy = self; copy.clientBinding = binding; return copy
    }
    package func servingForwardPairs(_ service: V2RoomForwardPairService) -> Self {
        var copy = self; copy.forwardPairs = service; return copy
    }
}

/// Gateway Host 与 Account/Operator 调用方共用的启动和停机组合入口。
/// 领域服务接收 RoomDirectory；集群 ActorID 仅保留在此边界内。
public actor V2RoomActorApplication: V2RoomRuntimeMetricsReading {
    public nonisolated let callerIncarnation: UUID
    public nonisolated let isSingleCore: Bool
    public nonisolated let directory: V2RoomDirectory
    public nonisolated let reservations: V2RoomReservationCoordinator
    public nonisolated let configuration: V2RoomRuntimeConfiguration
    public nonisolated let serviceQualification: V2ActorServiceQualification?
    public nonisolated let realtimeDiscoveryPeers: [V2RealtimeShardDiscoveryPeer]
    private let policyPlacement: V2PolicyOwnerPlacement?
    private let forwardPairs: V2RoomForwardPairService?
    private let client: V2RoomClusterClient
    private let trust: V2ActorTrustStore
    private let node: Node
    private let control: V2PlacementControlRuntime?
    private let placement: V2RoomActorPlacementRuntime?
    private let placementShards: Set<String>
    private let transferShards: Set<String>
    private let placementPeers: [V2RoomDiscoveryPeer]
    private var creatingRealtimeTransport = false
    private let placementRefresh: Task<Void, Never>?
    private let qualificationChanged: @Sendable () async -> Void
    private let metrics: @Sendable () async -> V2RoomRuntimeMetricsSnapshot

    private enum Node: Sendable {
        case host(V2RoomClusterNode)
        case caller(V2RoomClusterClientNode)
    }

    private init(policyPlacement: V2PolicyOwnerPlacement?, forwardPairs: V2RoomForwardPairService?, client: V2RoomClusterClient, trust: V2ActorTrustStore, callerIncarnation: UUID, directory: V2RoomDirectory, reservations: V2RoomReservationCoordinator,
                 configuration: V2RoomRuntimeConfiguration, node: Node, control: V2PlacementControlRuntime?, placement: V2RoomActorPlacementRuntime?, placementShards: Set<String>, transferShards: Set<String>, placementPeers: [V2RoomDiscoveryPeer],
                 qualificationChanged: @escaping @Sendable () async -> Void,
                 serviceQualification: V2ActorServiceQualification?,
                 realtimeDiscoveryPeers: [V2RealtimeShardDiscoveryPeer],
                 metrics: @escaping @Sendable () async -> V2RoomRuntimeMetricsSnapshot) {
        self.policyPlacement = policyPlacement
        self.forwardPairs = forwardPairs
        self.client = client
        self.trust = trust
        self.callerIncarnation = callerIncarnation
        self.control = control
        self.isSingleCore = control == nil
        self.directory = directory
        self.reservations = reservations
        self.configuration = configuration
        self.node = node
        self.placement = placement
        self.placementShards = placementShards
        self.transferShards = transferShards
        self.placementPeers = placementPeers
        self.placementRefresh = placement.map { placement in
            Task {
                while !Task.isCancelled {
                    do {
                        try await ContinuousClock().sleep(for: .seconds(1))
                        try Task.checkCancellation()
                        try await placement.refresh()
                    } catch {
                        if Task.isCancelled { return }
                        // Retain the last committed snapshot. Refresh failure
                        // does not supply exclusion evidence.
                    }
                }
            }
        }
        self.qualificationChanged = qualificationChanged
        self.serviceQualification = serviceQualification
        self.realtimeDiscoveryPeers = realtimeDiscoveryPeers
        self.metrics = metrics
    }

    package func probePolicyOwners(deadline: ContinuousClock.Instant) async throws -> V2AdminPolicyObservation {
        guard let policyPlacement else { throw V2RoomActorApplicationError.invalidRole }
        var closed = false, owners = 0, operations = 0
        for target in policyPlacement.configuration.owners {
            let host = try client.resolvePolicyHost(hostID: .init(uuid: target.hostID), endpoint: target.endpoint)
            let pressure = try await client.policyPressure(endpoint: target.endpoint, on: host, deadline: deadline)
            let (totalOwners, ownerOverflow) = owners.addingReportingOverflow(pressure.owners)
            let (totalOperations, operationOverflow) = operations.addingReportingOverflow(pressure.inFlight)
            guard !ownerOverflow, !operationOverflow else { throw V2RoomActorApplicationError.invalidRole }
            owners = totalOwners; operations = totalOperations; closed = closed || pressure.closed
        }
        return .init(closed: closed, owners: owners, inFlight: operations)
    }

    package func probePlacement(deadline: ContinuousClock.Instant) async throws -> (shards: Int, healthy: Int, expected: Int) {
        guard let placement else {
            let healthy = client.routingSnapshot().healthyHostIDs()
            return (0, healthy.count, placementPeers.count)
        }
        let committed = try await placement.committedInspections(deadline: deadline)
        let routes = client.routingSnapshot()
        let healthy = placementPeers.filter { peer in
            peer.accessibleShardIDs.allSatisfy { shard in
                guard let discovered = try? routes.resolvePolicyHost(hostID: peer.hostID, endpoint: shard),
                      let snapshot = committed[shard]?.snapshot else { return false }
                return snapshot.hosts.contains { !$0.retired && $0.host == discovered }
            }
        }
        return (committed.count, healthy.count, placementPeers.count)
    }

    package func policyMutationExecutor() throws -> PostgresV2RemotePolicyMutations {
        guard let policyPlacement else { throw V2RoomActorApplicationError.invalidRole }
        let routes = PostgresV2PolicyDeploymentRoutes(placement: policyPlacement, client: client)
        return .init(client: client, resolve: { try await routes.resolveScope($0) })
    }

    package func forwardPair(_ pair: V2ActorForwardPairWire,
        deadline: ContinuousClock.Instant) async throws -> V2ActorForwardMessageResultWire {
        guard policyPlacement != nil else { throw V2RoomActorApplicationError.invalidRole }
        return try await directory.callForwardPair(pair, deadline: deadline) { [client] token, pair, deadline in
            try await client.forwardPair(pair, token: token, deadline: deadline)
        }
    }

    /// Forward authenticated qualification changes without consulting membership
    /// or adding per-room database reads.
    public func qualificationDidChange() async {
        await qualificationChanged()
    }

    public static func start(configuration: V2RoomActorApplicationConfiguration,
                             ownerRouter: any V2RoomShardRouting,
                             roomDatabases: [String: any Database],
                             factory: V2RoomServerActivationFactory? = nil,
                             qualification: V2ActorServiceQualification? = nil,
                             policyServices: V2PolicyHostedServices? = nil,
                             singleCoreEpoch: UInt64? = nil) async throws -> V2RoomActorApplication {
        if let services = policyServices {
            guard configuration.hostIdentity != nil, configuration.policyPlacement == services.placement,
                  factory != nil else { throw V2RoomActorApplicationError.invalidRole }
        } else if configuration.hostIdentity != nil, configuration.policyPlacement != nil {
            throw V2RoomActorApplicationError.invalidRole
        }
        let policyPlacement = try configuration.policyPlacement.map(V2PolicyOwnerPlacement.init)
        // Fixed control voters have independent process lifetimes. Stopping
        // room applications must not dismantle quorum before other Hosts retire.
        guard configuration.placementControl?.identity == nil else { throw V2RoomActorApplicationError.invalidRole }
        try await configuration.awaitSupervisedStartup()
        let control = configuration.isSingleCore ? nil : V2PlacementControlRuntime(configuration: configuration)
        do {
        let placement = try await control?.start()
        let roomDiscovery = configuration.discovery
        let client: V2RoomClusterClient
        let node: Node
        let runtimeHost: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>?
        let runtimeBudget: V2RoomCommandBudget?
        let directory: V2RoomDirectory
        let reservations: V2RoomReservationCoordinator
        if let identity = configuration.hostIdentity {
            guard let factory, let qualification,
                  configuration.allowedShards.isSubset(of: Set(roomDatabases.keys)) else {
                throw V2RoomActorApplicationError.invalidRole
            }
            let runtime = configuration.runtime
            let budget = V2RoomCommandBudget(configuration: runtime)
            let roomPlacement: any V2RoomActorPlacementRouting
            if let placement {
                roomPlacement = placement
            } else {
                guard let singleCoreEpoch else { throw V2RoomActorApplicationError.invalidRole }
                roomPlacement = V2SingleRoomCorePlacement(
                    authority: try .init(host: identity, epoch: singleCoreEpoch),
                    allowedShards: configuration.allowedShards, qualification: qualification)
            }
            let host = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(identity: identity,
                placement: roomPlacement, configuration: runtime, budget: budget,
                classify: { $0.turnSchedulingClass }, factory: factory.runtimeFactory(), qualification: qualification)
            runtimeHost = host
            runtimeBudget = budget
            let hostNode = V2RoomClusterNode(configuration: try .init(name: configuration.name,
                host: configuration.address, port: configuration.port, tls: configuration.tls,
                threadPoolSize: configuration.threadPoolSize, allowedShards: configuration.allowedShards,
                serviceShardAccess: configuration.serviceShardAccess), identity: identity, host: host,
                signer: configuration.signer, trust: configuration.trust,
                authenticationLimits: configuration.authentication, runtimeConfiguration: runtime,
                policyOwnership: policyServices?.ownership, policyMutations: policyServices?.mutations,
                forwardPairs: policyServices?.forwardPairs, placementDrain: placement?.drainageService(host: host))
            do {
                try await placement?.register(identity, shards: configuration.allowedShards)
                let descriptor = try await hostNode.start()
                client = try await hostNode.makeClient(signer: configuration.signer,
                    trust: configuration.trust, limits: configuration.authentication)
                if placement != nil {
                    _ = try await hostNode.startDiscovery(client: client, configuration: roomDiscovery)
                } else {
                    try await client.installDiscovered(descriptor)
                }
                try await policyServices?.clientBinding?.bind(client, qualified: { await hostNode.readiness() })
                directory = V2RoomDirectory(owners: V2RoomServerOwnerResolver(router: ownerRouter),
                    placement: roomPlacement, hosts: client, transport: client, configuration: configuration.runtime)
                reservations = V2RoomReservationCoordinator(operations: await directory.reservationOperations(),
                    configuration: configuration.runtime)
                try await policyServices?.forwardPairs?.bind(reservations)
                node = .host(hostNode)
            } catch {
                let startupError = error
                let drained: V2RoomActivationDrainResult
                do {
                    drained = try await hostNode.stop(deadline: .now + runtime.drainTimeout.duration)
                    guard drained.completed, let proof = drained.proof else {
                        throw V2RoomActorApplicationError.incompleteShutdown
                    }
                    try await placement?.retireAfterDrain(proof, shards: configuration.allowedShards)
                } catch { throw V2RoomActorApplicationError.incompleteShutdown }
                throw startupError
            }
        } else {
            runtimeHost = nil
            runtimeBudget = nil
            guard factory == nil else { throw V2RoomActorApplicationError.invalidRole }
            let caller = V2RoomClusterClientNode(configuration: try .init(name: configuration.name,
                host: configuration.address, port: configuration.port, tls: configuration.tls,
                threadPoolSize: configuration.threadPoolSize), signer: configuration.signer,
                trust: configuration.trust, authenticationLimits: configuration.authentication,
                runtimeConfiguration: configuration.runtime)
            do {
                client = try await caller.start(discovery: roomDiscovery)
                let owners = V2RoomServerOwnerResolver(router: ownerRouter)
                if let placement {
                    directory = V2RoomDirectory(owners: owners, placement: placement,
                        hosts: client, transport: client, configuration: configuration.runtime)
                } else {
                    directory = V2RoomDirectory(owners: owners, fixedHostID: roomDiscovery.peers[0].hostID,
                        hosts: client, transport: client, configuration: configuration.runtime)
                }
                reservations = V2RoomReservationCoordinator(operations: await directory.reservationOperations(),
                    configuration: configuration.runtime)
                node = .caller(caller)
            } catch {
                let startupError = error
                let stopped: Bool
                do {
                    stopped = try await caller.stop(deadline: .now + configuration.runtime.drainTimeout.duration)
                } catch {
                    throw V2RoomActorApplicationError.incompleteShutdown
                }
                guard stopped else { throw V2RoomActorApplicationError.incompleteShutdown }
                throw startupError
            }
        }
        let application = V2RoomActorApplication(policyPlacement: policyPlacement, forwardPairs: policyServices?.forwardPairs, client: client, trust: configuration.trust, callerIncarnation: client.callerIncarnation, directory: directory, reservations: reservations,
                     configuration: configuration.runtime, node: node, control: control, placement: placement, placementShards: configuration.allowedShards, transferShards: configuration.transferShardIDs, placementPeers: roomDiscovery.peers, qualificationChanged: { await runtimeHost?.qualificationDidChange() },
                     serviceQualification: qualification, realtimeDiscoveryPeers: configuration.realtimePeers,
                     metrics: {
                         let location = await directory.snapshot()
                         return await .init(host: runtimeHost?.snapshot(), commands: runtimeBudget?.snapshot(),
                             cachedLocations: location.cached, pendingResolutions: location.pending,
                             activeResolutions: location.active, resolutionWaiters: location.waiters,
                             directoryCalls: directory.callMetricsSnapshot(),
                             transportCalls: client.callMetricsSnapshot())
                     })
        return application
        } catch {
            let startupError = error
            guard try await control?.stop(deadline: .now + configuration.runtime.drainTimeout.duration) != false else {
                throw V2RoomActorApplicationError.incompleteShutdown
            }
            throw startupError
        }
    }

    /// Server control-plane entry. The previous process must answer the signed
    /// drain RPC; timeout, discovery loss and gossip never authorize takeover.
    /// Freeze originRevision from the first committed inspection. Every retry
    /// retains that version, transferID and expected owner, including across caller restarts.
    public func transferRoomPartition(shardID: String, partition: Int,
        expectedHost: V2ActorHostIdentity, expectedEpoch: UInt64,
        successor: V2ActorHostIdentity, transferID: UUID, originRevision: UInt64, deadline: ContinuousClock.Instant) async throws {
        guard let placement, transferShards.contains(shardID), expectedEpoch > 0, originRevision > 0,
              expectedEpoch <= V2RoomActorPlacementGrant.maximumEpoch else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        let client = client
        try await placement.transfer(shard: shardID, partition: partition,
            expected: .init(host: expectedHost, epoch: expectedEpoch), successor: successor,
            transferID: transferID, originRevision: originRevision, client: client, deadline: deadline, authorizeSuccessor: { identity in
                try await self.authorizeRoomSuccessor(identity, shardID: shardID)
            })
    }

    /// Uses the actual resolved activation and its unique configured publisher;
    /// neither a caller-provided grant nor discovery metadata can choose service.
    public func resolveRoomSubscription(_ roomID: RoomID, deadline: ContinuousClock.Instant) async throws
        -> (activation: V2RoomActivationToken, authenticatedServiceID: String) {
        let activation = try await directory.resolve(roomID, deadline: deadline)
        let service = try trust.configuredHostServiceID(for: activation.host.hostID, requiring: [.realtimePublish])
        return (activation, service.rawValue)
    }

    public func subscribeRoom(_ command: V2RoomSubscriptionSubscribeCommand, token: V2RoomActivationToken,
                              deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult {
        try await client.subscribeRoom(command, token: token, deadline: deadline)
    }

    public func activateRoomSubscription(_ command: V2RoomSubscriptionActivateCommand, token: V2RoomActivationToken,
                                         deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult {
        try await client.activateRoomSubscription(command, token: token, deadline: deadline)
    }

    public func resetRoomSubscription(_ command: V2RoomSubscriptionResetCommand, token: V2RoomActivationToken,
                                      deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult {
        try await client.resetRoomSubscription(command, token: token, deadline: deadline)
    }



    public func unsubscribeRoom(_ command: V2RoomSubscriptionUnsubscribeCommand, token: V2RoomActivationToken,
                                deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult {
        try await client.unsubscribeRoom(command, token: token, deadline: deadline)
    }

    private func authorizeRoomSuccessor(_ identity: V2ActorHostIdentity, shardID: String) throws {
        guard placementPeers.contains(where: { $0.hostID == identity.hostID && $0.accessibleShardIDs.contains(shardID) }),
              try client.resolvePolicyHost(hostID: identity.hostID, endpoint: shardID) == identity else {
            throw V2RoomCallFailure.notAccepted(.unavailable)
        }
    }

    /// Creates a callback endpoint without granting the process room-host authority.
    public func makeRealtimeShardTransport(identity: V2GatewayRealtimeIdentity,
        serving: any V2RealtimeShardServing,
        serviceOwnerAccess: [V2ActorServiceID: Set<String>],
        discoveryPeers: [V2RealtimeShardDiscoveryPeer],
        limits: V2RealtimeTransportLimits = .init(),
        serviceQualification: V2ActorServiceQualification? = nil,
        fixedOwnerNodeID: String? = nil) async throws -> V2RealtimeShardTransportHandle {
        guard !creatingRealtimeTransport else { throw V2RoomActorApplicationError.invalidRole }
        creatingRealtimeTransport = true
        defer { creatingRealtimeTransport = false }
        let handle: V2RealtimeShardTransportHandle
        switch node {
        case .host(let host):
            handle = try await host.makeRealtimeShardTransport(identity: identity, serving: serving,
                serviceOwnerAccess: serviceOwnerAccess, discoveryPeers: discoveryPeers, limits: limits,
                serviceQualification: serviceQualification, fixedOwnerNodeID: fixedOwnerNodeID)
        case .caller(let caller):
            handle = try await caller.makeRealtimeShardTransport(identity: identity, serving: serving,
                serviceOwnerAccess: serviceOwnerAccess, discoveryPeers: discoveryPeers, limits: limits,
                serviceQualification: serviceQualification, fixedOwnerNodeID: fixedOwnerNodeID)
        }
        return handle
    }

    public func makeRealtimeTransport(identity: V2GatewayRealtimeIdentity,
                                      ingress: any V2RealtimeIngress,
                                      serviceOwnerAccess: [V2ActorServiceID: Set<String>],
                                      limits: V2RealtimeTransportLimits = .init(),
                                      journalProjectionHandler: (any V2RealtimeJournalProjectionHandler)? = nil) async throws -> V2RealtimeTransportHandle {
        let handle: V2RealtimeTransportHandle
        switch node {
        case .host(let host):
            handle = try await host.makeRealtimeTransport(identity: identity, ingress: ingress,
                serviceOwnerAccess: serviceOwnerAccess, limits: limits)
        case .caller(let caller):
            handle = try await caller.makeRealtimeTransport(identity: identity, ingress: ingress,
                serviceOwnerAccess: serviceOwnerAccess, limits: limits)
        }
        if let journalProjectionHandler { try await handle.configureJournalProjection(journalProjectionHandler) }
        return handle
    }

    public func roomRuntimeMetricsSnapshot() async -> V2RoomRuntimeMetricsSnapshot {
        let base = await metrics()
        return .init(host: base.host, commands: base.commands, cachedLocations: base.cachedLocations,
            pendingResolutions: base.pendingResolutions, activeResolutions: base.activeResolutions,
            resolutionWaiters: base.resolutionWaiters, directoryCalls: base.directoryCalls,
            transportCalls: base.transportCalls, membership: nil)
    }

    public func roomAuthorityInvalidations() async -> AsyncStream<Void> {
        switch node {
        case .host(let host): return await host.roomAuthorityInvalidations()
        case .caller: return AsyncStream { $0.finish() }
        }
    }

    public func readiness() async -> Bool {
        return switch node {
        case .host(let host): await host.readiness()
        case .caller(let caller): await caller.readiness()
        }
    }

    /// 返回 false 表示共享数据库和传输资源仍须保持存活。
    /// 实际操作结束后，调用方可用更晚的期限重试。
    public func stop(deadline: ContinuousClock.Instant) async throws -> Bool {
        await directory.drain()
        async let directoryStopped = directory.quiesce(deadline: deadline)
        let nodeStopped: Bool
        var proof: V2RoomHostDrainProof?
        do {
            switch node {
            case .host(let host):
                let result = try await host.stop(deadline: deadline)
                nodeStopped = result.completed
                proof = result.proof
            case .caller(let caller): nodeStopped = try await caller.stop(deadline: deadline)
            }
        } catch {
            _ = await directoryStopped
            throw error
        }
        let resolutionsStopped = await directoryStopped
        guard nodeStopped && resolutionsStopped else { return false }
        await forwardPairs?.close()
        if let proof { try await placement?.retireAfterDrain(proof, shards: placementShards) }
        placementRefresh?.cancel()
        await placementRefresh?.value
        return try await control?.stop(deadline: deadline) ?? true
    }
}
