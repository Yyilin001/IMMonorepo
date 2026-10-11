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
    public nonisolated let directory: V2RoomDirectory
    public nonisolated let reservations: V2RoomReservationCoordinator
    public nonisolated let configuration: V2RoomRuntimeConfiguration
    public nonisolated let serviceQualification: V2ActorServiceQualification?
    private let policyPlacement: V2PolicyOwnerPlacement?
    private let forwardPairs: V2RoomForwardPairService?
    private let client: V2RoomClusterClient
    private let trust: V2ActorTrustStore
    private let node: Node
    private let leases: V2RoomServerLeaseStore
    private let qualificationChanged: @Sendable () async -> Void
    private let metrics: @Sendable () async -> V2RoomRuntimeMetricsSnapshot

    private enum Node: Sendable {
        case host(V2RoomClusterNode)
        case caller(V2RoomClusterClientNode)
    }

    private init(policyPlacement: V2PolicyOwnerPlacement?, forwardPairs: V2RoomForwardPairService?, client: V2RoomClusterClient, trust: V2ActorTrustStore, callerIncarnation: UUID, directory: V2RoomDirectory, reservations: V2RoomReservationCoordinator,
                 configuration: V2RoomRuntimeConfiguration, node: Node, leases: V2RoomServerLeaseStore,
                 qualificationChanged: @escaping @Sendable () async -> Void,
                 serviceQualification: V2ActorServiceQualification?,
                 metrics: @escaping @Sendable () async -> V2RoomRuntimeMetricsSnapshot) {
        self.policyPlacement = policyPlacement
        self.forwardPairs = forwardPairs
        self.client = client
        self.trust = trust
        self.callerIncarnation = callerIncarnation
        self.directory = directory
        self.reservations = reservations
        self.configuration = configuration
        self.node = node
        self.leases = leases
        self.qualificationChanged = qualificationChanged
        self.serviceQualification = serviceQualification
        self.metrics = metrics
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
                             physicalRegistrationKeys: [String: String]? = nil,
                             qualification: V2ActorServiceQualification? = nil,
                             policyServices: V2PolicyHostedServices? = nil) async throws -> V2RoomActorApplication {
        if let services = policyServices {
            guard configuration.hostIdentity != nil, configuration.policyPlacement == services.placement,
                  factory != nil else { throw V2RoomActorApplicationError.invalidRole }
        } else if configuration.hostIdentity != nil, configuration.policyPlacement != nil {
            throw V2RoomActorApplicationError.invalidRole
        }
        let policyPlacement = try configuration.policyPlacement.map(V2PolicyOwnerPlacement.init)
        let leases = try V2RoomServerLeaseStore(databases: roomDatabases,
            physicalRegistrationKeys: physicalRegistrationKeys,
            sqlContinuationMetricsByOwner: factory?.sqlContinuationMetricsByOwner ?? [:])
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
            let host = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(identity: identity,
                leaseStore: leases, configuration: runtime, budget: budget,
                classify: { $0.turnSchedulingClass }, factory: factory.runtimeFactory(validation: {
                    try await leases.validate(token: $0)
                }), qualification: qualification)
            runtimeHost = host
            runtimeBudget = budget
            let hostNode = V2RoomClusterNode(configuration: try .init(name: configuration.name,
                host: configuration.address, port: configuration.port, tls: configuration.tls,
                threadPoolSize: configuration.threadPoolSize, allowedShards: configuration.allowedShards,
                serviceShardAccess: configuration.serviceShardAccess), identity: identity, host: host,
                signer: configuration.signer, trust: configuration.trust,
                authenticationLimits: configuration.authentication, runtimeConfiguration: runtime,
                policyOwnership: policyServices?.ownership, policyMutations: policyServices?.mutations,
                forwardPairs: policyServices?.forwardPairs)
            do {
                _ = try await hostNode.start()
                client = try await hostNode.makeClient(signer: configuration.signer,
                    trust: configuration.trust, limits: configuration.authentication)
                _ = try await hostNode.startDiscovery(client: client, configuration: configuration.discovery)
                try await policyServices?.clientBinding?.bind(client)
                directory = V2RoomDirectory(owners: V2RoomServerOwnerResolver(router: ownerRouter),
                    leases: leases, hosts: client, transport: client, configuration: configuration.runtime)
                reservations = V2RoomReservationCoordinator(operations: await directory.reservationOperations(),
                    configuration: configuration.runtime)
                try await policyServices?.forwardPairs?.bind(reservations)
                node = .host(hostNode)
            } catch {
                let startupError = error
                let stopped: Bool
                do {
                    stopped = try await hostNode.stop(deadline: .now + runtime.drainTimeout.duration).completed
                } catch {
                    throw V2RoomActorApplicationError.incompleteShutdown
                }
                guard stopped else { throw V2RoomActorApplicationError.incompleteShutdown }
                await leases.shutdownLifecycle()
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
                client = try await caller.start(discovery: configuration.discovery)
                directory = V2RoomDirectory(owners: V2RoomServerOwnerResolver(router: ownerRouter),
                    leases: leases, hosts: client, transport: client, configuration: configuration.runtime)
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
                await leases.shutdownLifecycle()
                throw startupError
            }
        }
        return .init(policyPlacement: policyPlacement, forwardPairs: policyServices?.forwardPairs, client: client, trust: configuration.trust, callerIncarnation: client.callerIncarnation, directory: directory, reservations: reservations,
                     configuration: configuration.runtime, node: node, leases: leases, qualificationChanged: { await runtimeHost?.qualificationDidChange() },
                     serviceQualification: qualification, metrics: {
                         let location = await directory.snapshot()
                         return await .init(host: runtimeHost?.snapshot(), commands: runtimeBudget?.snapshot(),
                             cachedLocations: location.cached, pendingResolutions: location.pending,
                             activeResolutions: location.active, resolutionWaiters: location.waiters,
                             directoryCalls: directory.callMetricsSnapshot(),
                             transportCalls: client.callMetricsSnapshot())
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

    public func renewRoomSubscriptions(on host: V2ActorHostIdentity, items: [V2RoomSubscriptionRenewBatchItem],
        deadline: ContinuousClock.Instant) async throws -> [V2RoomSubscriptionRenewBatchOutcome] {
        try await client.renewRoomSubscriptions(on: host, items: items, deadline: deadline)
    }

    public func unsubscribeRoom(_ command: V2RoomSubscriptionUnsubscribeCommand, token: V2RoomActivationToken,
                                deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult {
        try await client.unsubscribeRoom(command, token: token, deadline: deadline)
    }

    /// Creates a callback endpoint without granting the process room-host authority.
    public func makeRealtimeShardTransport(identity: V2GatewayRealtimeIdentity,
        serving: any V2RealtimeShardServing,
        serviceOwnerAccess: [V2ActorServiceID: Set<String>],
        discoveryPeers: [V2RealtimeShardDiscoveryPeer],
        limits: V2RealtimeTransportLimits = .init(),
        serviceQualification: V2ActorServiceQualification? = nil) async throws -> V2RealtimeShardTransportHandle {
        switch node {
        case .host(let host):
            return try await host.makeRealtimeShardTransport(identity: identity, serving: serving,
                serviceOwnerAccess: serviceOwnerAccess, discoveryPeers: discoveryPeers, limits: limits,
                serviceQualification: serviceQualification)
        case .caller(let caller):
            return try await caller.makeRealtimeShardTransport(identity: identity, serving: serving,
                serviceOwnerAccess: serviceOwnerAccess, discoveryPeers: discoveryPeers, limits: limits,
                serviceQualification: serviceQualification)
        }
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
        await metrics()
    }

    public func readiness() async -> Bool {
        switch node {
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
        do {
            switch node {
            case .host(let host): nodeStopped = try await host.stop(deadline: deadline).completed
            case .caller(let caller): nodeStopped = try await caller.stop(deadline: deadline)
            }
        } catch {
            _ = await directoryStopped
            throw error
        }
        let resolutionsStopped = await directoryStopped
        guard nodeStopped && resolutionsStopped else { return false }
        await forwardPairs?.close()
        // Host retirement can be followed by another Host using the same Store.
        // Only the owning application's final stop closes lifecycle admission,
        // after Directory work and every Host lease release have settled.
        await leases.shutdownLifecycle()
        return true
    }
}
