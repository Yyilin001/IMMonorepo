import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2Core
import IMV2ServerContracts

/// Saved immutable command. Keep every field unchanged after a lost response;
/// the control log, not a matching current owner, certifies successful replay.
package struct V2RoomPartitionTransferCommand: Codable, Sendable {
    package let deploymentID: UUID
    package let shardID: String
    package let partition: Int
    package let expectedHost: V2ActorHostIdentity
    package let expectedEpoch: UInt64
    package let successor: V2ActorHostIdentity
    package let transferID: UUID
    package let originRevision: UInt64

    package func validate(configuration: V2RoomActorApplicationConfiguration) throws {
        guard deploymentID == configuration.placementControl.clusterID,
              configuration.serviceMembershipShard != nil,
              configuration.hostIdentity == nil, configuration.placementControl.identity == nil,
              configuration.policyPlacement == nil,
              try configuration.trust.configuredService(configuration.signer.serviceID).permissions ==
                Set([.placementRead, .placementWrite, .roomCoordination]),
              configuration.transferShardIDs.contains(shardID), (0..<4096).contains(partition),
              expectedHost.hostID != successor.hostID, originRevision > 0,
              expectedEpoch > 0, expectedEpoch < V2RoomActorPlacementGrant.maximumEpoch else {
            throw V2RoomActorApplicationError.invalidRole
        }
    }
}

extension V2PlacementControlService {
    public static func transferRoomPartition(configuration: V2RoomActorApplicationConfiguration,
        request: Data, deadline: ContinuousClock.Instant = .now + .seconds(60)) async throws -> Data {
        guard request.count <= 16_384 else { throw V2RoomActorApplicationConfigurationError.invalidConfiguration }
        let command = try JSONDecoder().decode(V2RoomPartitionTransferCommand.self, from: request)
        try command.validate(configuration: configuration)
        guard ContinuousClock.now < deadline else { throw V2ActorPlacementError.unavailable }
        let application = try await V2RoomActorApplication.start(configuration: configuration,
            ownerRouter: TransferOnlyRouter(), roomDatabases: [:])
        do {
            while true {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw V2ActorPlacementError.unavailable }
                do {
                    try await application.transferRoomPartition(shardID: command.shardID, partition: command.partition,
                        expectedHost: command.expectedHost, expectedEpoch: command.expectedEpoch,
                        successor: command.successor, transferID: command.transferID,
                        originRevision: command.originRevision, deadline: deadline)
                    break
                } catch V2ActorPlacementError.staleRevision {
                    // Concurrent control changes may refresh CAS, never the
                    // command's expected owner, transfer ID or origin revision.
                } catch V2ActorPlacementError.unavailable {
                } catch V2RoomCallFailure.notAccepted(.unavailable) {
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            let failure = error
            guard try await application.stop(deadline: .now + .seconds(30)) else {
                throw V2RoomActorApplicationError.incompleteShutdown
            }
            throw failure
        }
        guard try await application.stop(deadline: .now + .seconds(30)) else {
            throw V2RoomActorApplicationError.incompleteShutdown
        }
        struct Receipt: Encodable {
            let status: String
            let command: V2RoomPartitionTransferCommand
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Receipt(status: "completed", command: command))
    }
}

/// This command routes only through certified placement and signed discovery.
/// It must never fall through to room/database ownership lookups.
private struct TransferOnlyRouter: V2RoomShardRouting {
    func route(for roomID: RoomID) async throws -> V2RoomShardRoute {
        throw V2RoomActorApplicationError.invalidRole
    }
}
