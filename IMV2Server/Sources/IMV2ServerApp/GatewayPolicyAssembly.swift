import Foundation
import IMV2ActorApplication
import IMV2ActorContracts
import IMV2Server
import IMV2ServerApplication
import IMV2ServerInfrastructure
import Logging

/// One host's policy dependencies, constructed before its RPC client exists.
/// The Actor application attaches that client before startup returns.
struct GatewayPolicyAssembly: Sendable {
    let hosted: V2PolicyHostedServices
    let ownerResources: [String: V2RoomServerOwnerResources]
    let physicalResources: [V2RoomServerOwnerResources]
    private let binding: V2PolicyClusterClientBinding
    private let cache: V2NodePolicyStateCache
    private let owners: PostgresV2PolicyOwnerDirectory
    private let worker: V2PolicyMaintenanceWorker
    private let pairService: V2RoomForwardPairService
    private let snapshots: V2PolicySnapshotPublisher

    static func build(prepared: GatewayPreparedAssembly, logger: Logger) throws -> Self? {
        let configuration = prepared.roomOwners.actorConfiguration
        guard let document = configuration.policyPlacement, let identity = configuration.hostIdentity else { return nil }
        guard let hostID = identity.hostID.uuidValue else { throw V2RoomActorApplicationError.invalidRole }
        let placement = try V2PolicyOwnerPlacement(document), binding = V2PolicyClusterClientBinding()
        // Cold state and policy mutations use the existing policy-control
        // pool. Current-state authorization has no room registrations or
        // revocation RPC dependency.
        let database = prepared.topology.directSendControlPool.database
        // Record node-owned state SQL exactly once in the existing aggregate,
        // regardless of how many logical room aliases share these resources.
        let stateMetrics = prepared.roomOwners.physicalResources.sorted { $0.key < $1.key }
            .first?.value.sendOperationMetrics
        let journal = PostgresV2PolicyAuthorizationJournal(database: database,
            stateReadAdmission: nil, stateMetrics: stateMetrics)
        let dispatcher = PostgresV2PolicyMutationDispatcher(database: database,
            projectionDelivery: prepared.projection.userShardProjectionDelivery)
        let endpoint = document.owners.first(where: { $0.hostID == hostID })?.endpoint
            ?? configuration.allowedShards.sorted()[0]
        let subscriber = try V2PolicySnapshotSubscriberWire(host: identity, endpoint: endpoint)
        let snapshotCapacity = try V2NodePolicyStateCache.capacityForActiveRooms(configuration.runtime.maximumActiveRooms)
        let cache = V2NodePolicyStateCache(maximumEntries: snapshotCapacity, identity: identity, subscriber: subscriber, releaseInterests: { request in
            let client = try binding.client()
            try await client.releasePolicyInterests(request, on: request.source, deadline: .now + .seconds(2))
        }, observe: { event in
            switch event {
            case .capacityEviction: stateMetrics?.recordPolicyMemoryEvent(.nodeSnapshotEviction)
            case .releaseReset: stateMetrics?.recordPolicyMemoryEvent(.snapshotReleaseReset)
            }
        })
        let snapshots = V2PolicySnapshotPublisher(targets: try configuration.discovery.peers.map { peer in
            try .init(hostID: peer.hostID,
                endpoint: document.owners.first { $0.hostID == peer.hostID.uuidValue }?.endpoint
                    ?? peer.accessibleShardIDs.sorted()[0])
        }, identity: identity, cache: cache, maximumScopesPerRecipient: snapshotCapacity, authorizeAdditionalTarget: { target in
            let service = try configuration.trust.configuredHostServiceID(for: target.hostID,
                requiring: [.policyRegistration])
            let configured = configuration.discovery.peers.first { $0.hostID == target.hostID }?.accessibleShardIDs
            return configuration.trust.authorizedSources(for: service, configured: configured,
                requiring: [.policyRegistration]).contains(target.endpoint)
        }, validateRecipient: { target in
            let client = try binding.client()
            guard try await client.resolvePolicyHost(hostID: target.hostID, endpoint: target.endpoint) == target.host else {
                throw V2PolicyAuthorizationLifecycleError.ownerChanged
            }
        }, send: { request, target in
            let client = try binding.client()
            let host = try await client.resolvePolicyHost(hostID: target.hostID, endpoint: target.endpoint)
            guard host == target.host else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
            try await client.updatePolicySnapshot(request, on: host, deadline: .now + .seconds(2))
        })
        let owners = PostgresV2PolicyOwnerDirectory(journal: journal, dispatcher: dispatcher,
            ownerID: identity.incarnationID,
            snapshotPublisher: snapshots,
            snapshotMaximumEntries: snapshotCapacity,
            snapshotObservation: { event in
                if case .capacityEviction = event { stateMetrics?.recordPolicyMemoryEvent(.ownerSnapshotEviction) }
            },
            ownsScope: { placement.owns($0, hostID: hostID) })
        let remote = PostgresV2RemotePolicyOwners(clientProvider: { try binding.client() }, localOwners: owners, stateCache: cache, subscriber: subscriber, resolveBatch: { keys in
            let client = try binding.client()
            return try PostgresV2PolicyDeploymentRoutes(placement: placement, client: client).resolveScopes(keys)
        }, resolve: { key in
            let client = try binding.client()
            return try PostgresV2PolicyDeploymentRoutes(placement: placement, client: client).resolveScope(key)
        })
        var resources: [String: V2RoomServerOwnerResources] = [:]
        var physical: [V2RoomServerOwnerResources] = []
        var forwardPairs: [String: V2ActorForwardPairDomainExecutor] = [:]
        let groups = Dictionary(grouping: prepared.roomOwners.physicalStoreKeyByShard.keys,
            by: { prepared.roomOwners.physicalStoreKeyByShard[$0]! })
        for aliases in groups.values {
            let ordered = aliases.sorted()
            let alias = ordered.first(where: { configuration.allowedShards.contains($0) }) ?? ordered[0]
            guard let database = prepared.topology.roomShardDatabases[alias],
                  let original = prepared.roomOwners.ownerResources[alias] else { throw V2RoomActorApplicationError.invalidRole }
            let locator = try V2RoomPolicyEndpointLocator(hostID: hostID, shardID: alias)
            let service = V2RoomPolicyAuthorizationService(roomDatabase: database,
                policyOwners: remote,
                locator: locator, maximumRooms: configuration.runtime.maximumActiveRooms,
                sendOperationMetrics: original.sendOperationMetrics)
            let bound = try original.usingPolicyAuthorizations(service)
            physical.append(bound)
            for alias in ordered {
                guard let pair = prepared.roomOwners.forwardPairs[alias] else { throw V2RoomActorApplicationError.invalidRole }
                resources[alias] = bound
                forwardPairs[alias] = pair.usingPolicyAuthorizations(service)
            }
        }
        let pairService = V2RoomForwardPairService(executors: forwardPairs)
        let hosted = V2PolicyHostedServices(placement: document,
            ownership: V2PolicyOwnershipService(owners: owners, endpoint: endpoint, cache: cache),
            mutations: V2PolicyMutationService(owners: owners, endpoint: endpoint))
            .bindingClient(binding).servingForwardPairs(pairService)
        let effects = PostgresV2PolicyCommittedEffectsPublisher(journal: journal,
            delivery: prepared.projection.maintenanceUserShardProjectionDelivery)
        let publisher = PostgresV2PolicyOutboxPublisher(journal: journal,
            ownsScope: { placement.owns($0, hostID: hostID) }, deliver: {
                try await owners.publishSnapshot(scopeKey: $0.scopeKey)
                try await effects.publish($0)
            })
        return .init(hosted: hosted, ownerResources: resources, physicalResources: physical,
            binding: binding, cache: cache, owners: owners,
            worker: .init(owners: owners, publisher: publisher, report: { value in
                if value.failed {
                    logger.warning("IM V2 policy maintenance has unfinished work", metadata: [
                        "worker": "policy_maintenance",
                        "recovery_failed": .stringConvertible(value.recovery?.failed ?? -1),
                        "publication_failed": .stringConvertible(value.publication?.failed ?? -1)
                    ])
                }
            }), pairService: pairService, snapshots: snapshots)
    }

    func startMaintenance() async throws {
        await cache.startInterestReleases()
        try await snapshots.start(qualified: { await binding.isQualified() })
        try await worker.start()
    }
    func shutdown() async {
        await pairService.close()
        await worker.shutdown()
        await snapshots.shutdown()
        await cache.shutdown()
        await owners.shutdown()
        await binding.close()
    }
}
