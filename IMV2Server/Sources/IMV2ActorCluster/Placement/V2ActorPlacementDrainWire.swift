import Foundation
import IMV2ActorContracts

/// A signed control request carries the fixed-field PB committed snapshot.
/// The receiver independently loads its authoritative log before closing admission.
public struct V2ActorPlacementDrainWire: Codable, Equatable, Sendable {
    public let shardID: String
    public let partition: Int
    public let committedSnapshot: Data
    public init(shardID: String, partition: Int, committedSnapshot: Data) {
        self.shardID = shardID; self.partition = partition; self.committedSnapshot = committedSnapshot
    }
    package var isBounded: Bool {
        !shardID.isEmpty && shardID.utf8.count <= 256 && (0..<4096).contains(partition) &&
            !committedSnapshot.isEmpty && committedSnapshot.count <= 1_048_576
    }
}

/// Only a signed reply from the exact previous process may certify this cut.
public struct V2ActorPlacementDrainedWire: Codable, Equatable, Sendable {
    package var certificate: V2ActorSignedPacket? = nil
    public let shardID: String
    public let clusterID: UUID
    public let partition: Int
    public let host: V2ActorHostIdentity
    public let epoch: UInt64
    public let transferID: UUID
    package init(shardID: String, receipt: V2ActorPlacementDrainReceipt) {
        self.shardID = shardID; clusterID = receipt.clusterID; partition = receipt.partition
        host = receipt.owner.host; epoch = receipt.owner.epoch; transferID = receipt.transferID
    }
    package func matches(_ request: V2ActorPlacementDrainWire, host: V2ActorHostIdentity) throws -> Bool {
        let snapshot = try V2ActorPlacementProtobuf.decode(request.committedSnapshot)
        guard request.isBounded, snapshot.slots.indices.contains(request.partition),
              let transfer = snapshot.slots[request.partition].transfer else { return false }
        return shardID == request.shardID && clusterID == snapshot.clusterID && partition == request.partition &&
            self.host == host && snapshot.slots[partition].owner == .init(host: host, epoch: epoch) &&
            transferID == transfer.id
    }
    package var receipt: V2ActorPlacementDrainReceipt {
        .init(clusterID: clusterID, partition: partition, owner: .init(host: host, epoch: epoch), transferID: transferID, certificate: certificate)
    }
}

public protocol V2ActorPlacementDraining: Sendable {
    func drainPlacement(_ request: V2ActorPlacementDrainWire,
                        deadline: ContinuousClock.Instant) async throws -> V2ActorPlacementDrainedWire
}
