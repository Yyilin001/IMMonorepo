import Foundation
import IMV2Core

/// Fixed partition placement is independent of the room's database owner.
/// A grant has no wall-clock expiry and is never refreshed per room.
public struct V2RoomActorPlacementGrant: Equatable, Sendable {
    public static let maximumEpoch = UInt64(Int64.max) >> 32
    public let host: V2ActorHostIdentity
    public let epoch: UInt64
    public init(host: V2ActorHostIdentity, epoch: UInt64) throws {
        guard epoch > 0, epoch <= Self.maximumEpoch else { throw V2ActorContractError.invalidEpoch }
        self.host = host; self.epoch = epoch
    }
    /// Placement epoch dominates the process-local monotonically increasing
    /// activation counter. Reopening a room cannot revive a previous reference.
    public func activationEpoch(counter: UInt32) throws -> V2ActorEpoch {
        guard counter > 0 else { throw V2ActorContractError.invalidEpoch }
        return try .init(Int64((epoch << 32) | UInt64(counter)))
    }
    public func matches(_ token: V2RoomActivationToken) -> Bool {
        host == token.host && UInt64(token.activationEpoch.rawValue) >> 32 == epoch &&
            UInt64(token.activationEpoch.rawValue) & UInt64(UInt32.max) != 0
    }
}

/// Synchronous immutable snapshot access only. Implementations never perform
/// database/network work here; lifecycle owns loading committed control state.
public protocol V2RoomActorPlacementRouting: Sendable {
    func grant(roomID: RoomID, owner: V2RoomDataOwner) throws -> V2RoomActorPlacementGrant
    /// Capture the room's partition once; warm calls only compare current owner.
    func admission(for token: V2RoomActivationToken) throws -> @Sendable () -> Bool
}
