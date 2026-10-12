import Foundation
import IMV2Core

/// Native control-plane capability. Construction belongs to the committed
/// placement adapter; this is deliberately neither Codable nor an RPC model.
package struct V2RoomPlacementWithdrawal: Sendable {
    package let host: V2ActorHostIdentity
    package let clusterID: UUID
    package let shardID: String
    package let partition: Int
    package let epoch: UInt64
    package let transferID: UUID
    package let isCurrent: @Sendable () -> Bool
    package let contains: @Sendable (RoomID) -> Bool
    /// Keeps the entire shard bound to current control ownership after the
    /// transfer completes or is cancelled. A timeout never reopens admission.
    package let admits: @Sendable (RoomID) -> Bool
    package init(host: V2ActorHostIdentity, clusterID: UUID, shardID: String, partition: Int,
                 epoch: UInt64, transferID: UUID, isCurrent: @escaping @Sendable () -> Bool,
                 contains: @escaping @Sendable (RoomID) -> Bool,
                 admits: @escaping @Sendable (RoomID) -> Bool) {
        self.host = host; self.clusterID = clusterID; self.shardID = shardID
        self.partition = partition; self.epoch = epoch; self.transferID = transferID
        self.isCurrent = isCurrent; self.contains = contains; self.admits = admits
    }
}

/// Issued by the production Host after every matching physical instance has
/// completed restoration, accepted work, reservations and executor close.
package struct V2RoomPlacementDrainProof: Equatable, Sendable {
    package let host: V2ActorHostIdentity
    package let clusterID: UUID
    package let shardID: String
    package let partition: Int
    package let epoch: UInt64
    package let transferID: UUID
    package init(host: V2ActorHostIdentity, clusterID: UUID, shardID: String, partition: Int,
                 epoch: UInt64, transferID: UUID) {
        self.host = host; self.clusterID = clusterID; self.shardID = shardID
        self.partition = partition; self.epoch = epoch; self.transferID = transferID
    }
}
