import IMV2ActorContracts
import IMV2Core

/// The caller supplies a durable process epoch after acquiring exclusive Core
/// admission. Room activation and eviction still belong to the existing Host.
struct V2SingleRoomCorePlacement: V2RoomActorPlacementRouting {
    let authority: V2RoomActorPlacementGrant
    let allowedShards: Set<String>
    let qualification: V2ActorServiceQualification

    var sharedAdmissionQualification: V2ActorServiceQualification? { qualification }

    func grant(roomID: RoomID, owner: V2RoomDataOwner) throws -> V2RoomActorPlacementGrant {
        guard allowedShards.contains(owner.shardID), qualification.snapshot() != nil else {
            throw V2RoomCallFailure.notAccepted(.unavailable)
        }
        return authority
    }

    func admission(for token: V2RoomActivationToken) throws -> @Sendable () -> Bool {
        guard allowedShards.contains(token.owner.shardID), authority.matches(token) else {
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        return { qualification.snapshot() != nil }
    }
}
