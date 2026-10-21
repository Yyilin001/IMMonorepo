import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ServerInfrastructure
import NIOPosix

/// The three fixed voters run as independent processes. Room applications are
/// clients and can all retire without removing the control quorum underneath.
public actor V2PlacementControlService {
    private let runtime: V2PlacementControlRuntime
    public init(configuration: V2RoomActorApplicationConfiguration) throws {
        guard configuration.hostIdentity == nil, configuration.placementControl.identity != nil,
              configuration.policyPlacement == nil else { throw V2RoomActorApplicationError.invalidRole }
        runtime = .init(configuration: configuration)
    }
    public func start() async throws {
        do { _ = try await runtime.start() }
        catch {
            let startupError = error
            guard try await runtime.stop(deadline: .now + .seconds(30)) else {
                throw V2RoomActorApplicationError.incompleteShutdown
            }
            throw startupError
        }
    }
    public func stop(deadline: ContinuousClock.Instant) async throws -> Bool {
        try await runtime.stop(deadline: deadline)
    }

    /// A dedicated authenticated caller configuration is required. Inspection
    /// cannot open voter storage, register a room Host or bootstrap a group.
    public static func inspect(configuration: V2RoomActorApplicationConfiguration,
                               deadline: ContinuousClock.Instant = .now + .seconds(30))
        async throws -> [V2PlacementControlInspection] {
        guard configuration.hostIdentity == nil, configuration.placementControl.identity == nil else {
            throw V2RoomActorApplicationError.invalidRole
        }
        let runtime = V2PlacementControlRuntime(configuration: configuration)
        let output: [V2PlacementControlInspection]
        do {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw V2ActorPlacementError.unavailable }
            let placement = try await runtime.start()
            let snapshots = try await placement.committedInspections(deadline: deadline)
            output = snapshots.keys.sorted().map { .init(shardID: $0, inspection: snapshots[$0]!) }
        } catch {
            let inspectionError = error
            guard try await runtime.stop(deadline: .now + .seconds(30)) else {
                throw V2RoomActorApplicationError.incompleteShutdown
            }
            throw inspectionError
        }
        guard try await runtime.stop(deadline: .now + .seconds(30)) else {
            throw V2RoomActorApplicationError.incompleteShutdown
        }
        return output
    }

    /// Validate authority before an exclusion backend can stop any process.
    package static func exclusionShards(configuration: V2RoomActorApplicationConfiguration,
                                        host: V2ActorHostIdentity) throws -> Set<String> {
        guard configuration.hostIdentity == nil, configuration.placementControl.identity == nil,
              configuration.policyPlacement == nil,
              try configuration.trust.configuredService(configuration.signer.serviceID).permissions ==
                Set([.placementRead, .placementWrite, .placementExclude]),
              let target = configuration.discovery.peers.first(where: { $0.hostID == host.hostID }),
              !target.accessibleShardIDs.isEmpty else {
            throw V2RoomActorApplicationError.invalidRole
        }
        return target.accessibleShardIDs
    }
    /// Explicit provisioning creates only fresh voting files. Normal startup
    /// always opens existing history; it never invokes this operation.
    public static func provision(configuration: V2RoomActorApplicationConfiguration) async throws {
        let control = configuration.placementControl
        guard configuration.hostIdentity == nil, configuration.policyPlacement == nil, let identity = control.identity else {
            throw V2RoomActorApplicationError.invalidRole
        }
        let pool = NIOThreadPool(numberOfThreads: 2); pool.start()
        do {
            for shard in control.shards.sorted() {
                let initial = try V2RoomActorPlacementRuntime.initialSnapshot(deploymentID: control.clusterID, shard: shard, peers: configuration.discovery.peers)
                guard let path = control.storagePaths[shard] else { throw V2PlacementRaftError.invalidConfiguration }
                let store = try await V2PlacementRaftFileStorage.bootstrap(at: path,
                    initial: .init(groupID: initial.clusterID, voterID: identity.hostID, voters: Set(control.roles.values)), pool: pool)
                try await store.close()
            }
            try await pool.shutdownGracefully()
        } catch {
            try? await pool.shutdownGracefully()
            throw error
        }
    }
}

/// The supervisor serially owns this session and drains all operations before
/// close. Failed startup is
/// drained before retry; completed operations do not churn cluster identities.
package actor V2RoomHostControlSession {
    private let configuration: V2RoomActorApplicationConfiguration
    private var runtime: V2PlacementControlRuntime?
    private var placement: V2RoomActorPlacementRuntime?
    private var closed = false

    package init(configuration: V2RoomActorApplicationConfiguration) throws {
        guard configuration.hostIdentity == nil, configuration.placementControl.identity == nil,
              configuration.policyPlacement == nil else { throw V2RoomActorApplicationError.invalidRole }
        self.configuration = configuration
    }
    private func connection() async throws -> V2RoomActorPlacementRuntime {
        guard !closed else { throw V2PlacementRaftError.closed }
        if let placement { return placement }
        let candidate = V2PlacementControlRuntime(configuration: configuration)
        runtime = candidate
        do {
            let value = try await candidate.start()
            placement = value
            return value
        } catch {
            let failure = error
            guard try await candidate.stop(deadline: .now + .seconds(30)) else {
                throw V2RoomActorApplicationError.incompleteShutdown
            }
            runtime = nil
            throw failure
        }
    }
    package func inspect(deadline: ContinuousClock.Instant) async throws -> [V2PlacementControlInspection] {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw V2ActorPlacementError.unavailable }
        let connection = try await connection()
        let snapshots = try await connection.committedInspections(deadline: deadline)
        return snapshots.keys.sorted().map { .init(shardID: $0, inspection: snapshots[$0]!) }
    }
    package func apply(_ proof: V2RoomHostExclusionProof, takeOver: Bool,
                       deadline: ContinuousClock.Instant) async throws -> [V2PlacementControlInspection] {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline,
              proof.settledShardIDs == (try V2PlacementControlService.exclusionShards(configuration: configuration, host: proof.host)) else {
            throw V2ActorPlacementError.unavailable
        }
        let connection = try await connection()
        try await connection.retireAfterExclusion(proof, deadline: deadline)
        if takeOver {
            try await connection.takeOverRetiredHost(proof.host, shards: proof.settledShardIDs,
                operationID: proof.operationID, eligibleHosts: configuration.placementControl.roomHosts, deadline: deadline)
        }
        return try await inspect(deadline: deadline)
    }
    package func close() async throws {
        closed = true
        if let runtime {
            guard try await runtime.stop(deadline: .now + .seconds(30)) else {
                throw V2RoomActorApplicationError.incompleteShutdown
            }
        }
        runtime = nil; placement = nil
    }
}
