import IMV2ActorContracts
import IMV2Core

/// Fixed committed placement for transport-only tests. The control-log suites
/// exercise withdrawal, epoch changes and registration with the real runtime.
struct PlacementFixedHostFixture: V2RoomActorPlacementRouting {
    let host: V2ActorHostIdentity
    func grant(roomID: RoomID, owner: V2RoomDataOwner) throws -> V2RoomActorPlacementGrant {
        try .init(host: host, epoch: 1)
    }
    func admission(for token: V2RoomActivationToken) throws -> @Sendable () -> Bool {
        guard try V2RoomActorPlacementGrant(host: host, epoch: 1).matches(token) else {
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        return { true }
    }
}
