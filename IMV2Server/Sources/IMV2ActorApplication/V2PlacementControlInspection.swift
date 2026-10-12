import Foundation
import IMV2ActorCluster

/// Operational output from fresh quorum reads. Shards are read independently.
/// These values describe committed ownership; they are not drain certificates.
public struct V2PlacementControlInspection: Encodable, Sendable {
    public let shardID: String
    public let clusterID: UUID
    public let revision: UInt64
    public let hosts: [Host]
    public let partitions: [Partition]
    public let archive: Archive

    public struct Archive: Encodable, Sendable {
        public let receipts: Int
        public let bytes: Int
        public let reservedReceipts: Int
        public let reservedBytes: Int
        public let maximumReceipts: Int
        public let maximumBytes: Int
        public let availableReceipts: Int
        public let availableBytes: Int
        /// Includes capacity already promised to terminal operations.
        public let nearCapacity: Bool
    }

    public struct Identity: Encodable, Sendable {
        public let hostID: String
        public let incarnationID: UUID
    }
    public struct Host: Encodable, Sendable {
        public let identity: Identity
        public let retired: Bool
    }
    public struct Transfer: Encodable, Sendable {
        public let id: UUID
        public let successor: Identity
    }
    public struct Partition: Encodable, Sendable {
        public let partition: Int
        public let owner: Identity
        public let epoch: UInt64
        public let retired: Bool
        public let transfer: Transfer?
    }

    package init(shardID: String, inspection: V2ActorPlacementInspection) {
        let snapshot = inspection.snapshot, usage = inspection.archiveUsage
        let maximumReceipts = V2PlacementRaftCheckpoint.maximumReceipts
        let maximumBytes = V2PlacementRaftCheckpoint.maximumBytes
        archive = .init(receipts: usage.receipts, bytes: usage.bytes,
            reservedReceipts: usage.reservedReceipts, reservedBytes: usage.reservedBytes,
            maximumReceipts: maximumReceipts, maximumBytes: maximumBytes,
            availableReceipts: maximumReceipts - usage.receipts - usage.reservedReceipts,
            availableBytes: maximumBytes - usage.bytes - usage.reservedBytes,
            nearCapacity: usage.receipts + usage.reservedReceipts >= maximumReceipts * 4 / 5
                || usage.bytes + usage.reservedBytes >= maximumBytes * 4 / 5)
        self.shardID = shardID; clusterID = snapshot.clusterID; revision = snapshot.revision
        hosts = snapshot.hosts.map {
            .init(identity: .init(hostID: $0.host.hostID.rawValue, incarnationID: $0.host.incarnationID),
                  retired: $0.retired)
        }
        partitions = snapshot.slots.enumerated().map { partition, slot in
            .init(partition: partition,
                  owner: .init(hostID: slot.owner.host.hostID.rawValue, incarnationID: slot.owner.host.incarnationID),
                  epoch: slot.owner.epoch, retired: slot.retired,
                  transfer: slot.transfer.map {
                      .init(id: $0.id, successor: .init(hostID: $0.successor.hostID.rawValue,
                                                       incarnationID: $0.successor.incarnationID))
                  })
        }
    }
}
