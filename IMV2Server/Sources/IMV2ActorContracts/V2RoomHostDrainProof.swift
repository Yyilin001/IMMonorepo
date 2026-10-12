import Foundation

/// Native lifecycle evidence, never decoded from a request or RPC payload.
/// The Host issues it only after restoration, accepted turns, reservations and
/// executor close have actually settled. Composition must also stop its other
/// producers before committing process retirement to the placement log.
public struct V2RoomHostDrainProof: Sendable {
    public let host: V2ActorHostIdentity
    package init(host: V2ActorHostIdentity) { self.host = host }
}
