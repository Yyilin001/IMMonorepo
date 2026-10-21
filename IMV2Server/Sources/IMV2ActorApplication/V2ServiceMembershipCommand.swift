import Foundation
import IMV2ActorCluster

package struct V2ServiceMembershipCommand: Decodable {
    package let deploymentID: UUID
    package let shardID: String
    package let requestID: UUID
    package let originRevision: UInt64
    package let membership: V2ActorServiceMembershipRecord

    package func validate(configuration: V2RoomActorApplicationConfiguration) throws {
        guard deploymentID == configuration.placementControl.clusterID,
              shardID == configuration.serviceMembershipShard, originRevision > 0,
              configuration.hostIdentity == nil, configuration.placementControl.identity == nil,
              configuration.policyPlacement == nil,
              try configuration.trust.configuredService(configuration.signer.serviceID).permissions ==
                Set([.placementRead, .placementWrite, .placementMembership]) else {
            throw V2RoomActorApplicationError.invalidRole
        }
    }
}

extension V2PlacementControlService {
    /// Input is a saved immutable request. Callers retry these exact bytes after
    /// an unknown result; this API never invents a replacement request identity.
    public static func installServiceMembership(configuration: V2RoomActorApplicationConfiguration,
        request: Data, deadline: ContinuousClock.Instant = .now + .seconds(30)) async throws -> Data {
        guard request.count <= 65536 else { throw V2RoomActorApplicationConfigurationError.invalidConfiguration }
        let command = try JSONDecoder().decode(V2ServiceMembershipCommand.self, from: request)
        try command.validate(configuration: configuration)
        let runtime = V2PlacementControlRuntime(configuration: configuration)
        let result: V2ActorPlacementSnapshot
        do {
            guard ContinuousClock.now < deadline else { throw V2ActorPlacementError.unavailable }
            let placement = try await runtime.start()
            result = try await placement.installServiceMembership(command.membership, shard: command.shardID,
                requestID: command.requestID, originRevision: command.originRevision, deadline: deadline)
        } catch {
            let failure = error
            guard try await runtime.stop(deadline: .now + .seconds(30)) else {
                throw V2RoomActorApplicationError.incompleteShutdown
            }
            throw failure
        }
        guard try await runtime.stop(deadline: .now + .seconds(30)) else {
            throw V2RoomActorApplicationError.incompleteShutdown
        }
        struct Receipt: Encodable {
            let requestID: UUID
            let controlRevision: UInt64
            let membership: V2ActorServiceMembershipRecord?
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Receipt(requestID: command.requestID, controlRevision: result.revision,
            membership: result.serviceMembership))
    }
}
