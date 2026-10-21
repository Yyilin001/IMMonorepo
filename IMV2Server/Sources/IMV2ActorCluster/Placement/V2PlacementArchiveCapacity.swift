import Foundation
import IMV2ActorContracts
import SwiftProtobuf

/// Successful control history must remain representable by a recoverable
/// checkpoint. Reserve terminal records before starting new lifecycle work.
package enum V2PlacementArchiveCapacity {
    package struct Usage: Equatable, Sendable {
        package let receipts: Int
        package let bytes: Int
        package let reservedReceipts: Int
        package let reservedBytes: Int

        package func requireCapacity(maximumReceipts: Int = V2PlacementRaftCheckpoint.maximumReceipts,
                                     maximumBytes: Int = V2PlacementRaftCheckpoint.maximumBytes) throws {
            guard receipts >= 0, bytes >= 0, reservedReceipts >= 0, reservedBytes >= 0,
                  maximumReceipts >= 0, maximumBytes >= 0 else { throw V2PlacementRaftError.invalidState }
            guard receipts <= maximumReceipts, reservedReceipts <= maximumReceipts - receipts,
                  bytes <= maximumBytes, reservedBytes <= maximumBytes - bytes else {
                throw V2ActorPlacementError.archiveCapacity
            }
        }
    }

    package static func headerBytes(_ genesis: V2ActorPlacementSnapshot) throws -> Int {
        var wire = Im_Actor_V1_PlacementRaftApplicationCheckpoint()
        wire.groupID = V2HotPB.bytes(genesis.clusterID)
        // Log index growth must never consume bytes promised to a terminal
        // record. Its maximum varint width is reserved from genesis onward.
        wire.appliedIndex = UInt64.max
        wire.genesisSnapshot = try V2ActorPlacementProtobuf.encode(genesis)
        wire.bootstrapDigest = Data(repeating: 0, count: 32)
        return try wire.serializedData().count
    }

    package static func recordBytes(_ record: V2PlacementRaftCheckpoint.Record) throws -> Int {
        var wire = Im_Actor_V1_PlacementRaftApplicationCheckpoint()
        var value = Im_Actor_V1_PlacementRaftCheckpointReceipt()
        value.requestID = V2HotPB.bytes(record.requestID)
        value.command = try V2ActorPlacementProtobuf.encode(record.command)
        value.revision = record.revision; value.originRevision = record.originRevision
        wire.receipts = [value]
        return try wire.serializedData().count
    }

    package static func usage(snapshot: V2ActorPlacementSnapshot, receipts: Int, bytes: Int) throws -> Usage {
        var count = 0, reserved = 0
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        func reserve(_ command: V2ActorPlacementCommand) throws -> Int {
            try recordBytes(.init(requestID: id, command: command, revision: UInt64.max, originRevision: UInt64.max - 1))
        }
        if let membership = snapshot.serviceMembership, let target = membership.next {
            let final = try V2ActorServiceMembershipRecord(revision: membership.revision + 1,
                current: target, peers: membership.peers.filter { target.contains($0.nodeID) },
                roomPeers: membership.roomPeers.filter { room in membership.peers.contains {
                    target.contains($0.nodeID) && $0.serviceID == room.serviceID.rawValue
                } })
            count += 1
            reserved += try reserve(.installServiceMembership(final))
        }
        for registration in snapshot.hosts where !registration.retired {
            count += 1
            reserved += try reserve(.retireHost(registration.host))
        }
        for (partition, slot) in snapshot.slots.enumerated() {
            guard let transfer = slot.transfer else { continue }
            count += 1
            reserved += try max(reserve(.completeTransfer(partition: partition,
                expected: slot.owner, transferID: transfer.id)),
                reserve(.cancelTransfer(partition: partition, expected: slot.owner, transferID: transfer.id)))
        }
        return .init(receipts: receipts, bytes: bytes, reservedReceipts: count, reservedBytes: reserved)
    }
}
