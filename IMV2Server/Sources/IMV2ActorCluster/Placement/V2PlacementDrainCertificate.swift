import Foundation
import IMV2ActorContracts
import SwiftProtobuf

/// These producers receive native capabilities; wire bytes never construct a
/// Host drain proof. A control leader verifies the old process's signature,
/// exact incarnation/group/shard/operation, and durable startup registration.
package enum V2PlacementDrainCertificate {
    package enum Verified: Sendable {
        case partition(V2ActorPlacementDrainReceipt)
        case host(V2ActorHostIdentity, previous: V2ActorHostIdentity, registrationRequestID: UUID)
        case excludedHost(V2ActorHostIdentity, operationID: UUID)
    }
    package static func signPartition(_ receipt: V2ActorPlacementDrainReceipt, shard: String,
                                      signer: V2ActorSigningIdentity) throws -> V2ActorSignedPacket {
        guard (0..<4096).contains(receipt.partition), receipt.owner.epoch > 0,
              receipt.owner.epoch <= V2RoomActorPlacementGrant.maximumEpoch else { throw V2PlacementRaftError.invalidMessage }
        var pb = Im_Actor_V1_PlacementDrainCertificate()
        pb.kind = .partition; pb.groupID = V2HotPB.bytes(receipt.clusterID); pb.shardID = shard
        pb.host = .init(receipt.owner.host); pb.partition = UInt32(receipt.partition); pb.epoch = receipt.owner.epoch
        pb.transferID = V2HotPB.bytes(receipt.transferID)
        return try signer.sign(pb.serializedData(), maximumBytes: 8192)
    }
    package static func signHost(_ proof: V2RoomHostDrainProof, shard: String, groupID: UUID,
                                previous: V2ActorHostIdentity, registrationRequestID: UUID,
                                signer: V2ActorSigningIdentity) throws -> V2ActorSignedPacket {
        guard previous.hostID == proof.host.hostID, previous != proof.host else { throw V2ActorPlacementError.invalidTransition }
        var pb = Im_Actor_V1_PlacementDrainCertificate()
        pb.kind = .host; pb.groupID = V2HotPB.bytes(groupID); pb.shardID = shard; pb.host = .init(proof.host)
        pb.registrationPrevious = .init(previous); pb.registrationRequestID = V2HotPB.bytes(registrationRequestID)
        return try signer.sign(pb.serializedData(), maximumBytes: 8192)
    }
    package static func signExclusion(_ proof: V2RoomHostExclusionProof, shard: String, groupID: UUID,
                                     signer: V2ActorSigningIdentity) throws -> V2ActorSignedPacket {
        guard proof.settledShardIDs.contains(shard), !shard.isEmpty, shard.utf8.count <= 256 else {
            throw V2ActorAuthenticationError.forbidden
        }
        var pb = Im_Actor_V1_PlacementDrainCertificate()
        pb.kind = .excludedHost; pb.groupID = V2HotPB.bytes(groupID); pb.shardID = shard
        pb.host = .init(proof.host); pb.exclusionRequestID = V2HotPB.bytes(proof.operationID)
        return try signer.sign(pb.serializedData(), maximumBytes: 8192)
    }
    package static func verify(_ packet: V2ActorSignedPacket, shard: String, groupID: UUID,
                               trust: V2ActorTrustStore) throws -> Verified {
        let (bytes, peer) = try trust.verify(packet, as: Data.self, maximumBytes: 8192)
        let pb = try Im_Actor_V1_PlacementDrainCertificate(serializedBytes: bytes)
        try V2HotPB.check(pb, pb.hasHost && pb.shardID == shard)
        guard try V2HotPB.uuid(pb.groupID) == groupID else { throw V2PlacementRaftError.wrongGroup }
        let host = try pb.host.model()
        if pb.kind == .excludedHost {
            guard peer.permissions.contains(.placementExclude), pb.partition == 0, pb.epoch == 0,
                  pb.transferID.isEmpty, !pb.hasRegistrationPrevious, pb.registrationRequestID.isEmpty else {
                throw V2ActorAuthenticationError.forbidden
            }
            // The supervisor signs for a configured target; it does not assume
            // that Host's signing identity or gain room execution authority.
            _ = try trust.configuredHostServiceID(for: host.hostID)
            return try .excludedHost(host, operationID: V2HotPB.uuid(pb.exclusionRequestID))
        }
        guard pb.exclusionRequestID.isEmpty, peer.hostedIDs.contains(host.hostID),
              try trust.configuredHostServiceID(for: host.hostID) == packet.signerID else {
            throw V2ActorAuthenticationError.forbidden
        }
        switch pb.kind {
        case .partition:
            guard pb.partition < 4096, pb.epoch > 0, pb.epoch <= V2RoomActorPlacementGrant.maximumEpoch,
                  !pb.hasRegistrationPrevious, pb.registrationRequestID.isEmpty else { throw V2PlacementRaftError.invalidMessage }
            return try .partition(.init(clusterID: groupID, partition: Int(pb.partition), owner: .init(host: host, epoch: pb.epoch),
                transferID: V2HotPB.uuid(pb.transferID), certificate: packet))
        case .host:
            guard pb.partition == 0, pb.epoch == 0, pb.transferID.isEmpty, pb.hasRegistrationPrevious else {
                throw V2PlacementRaftError.invalidMessage
            }
            let previous = try pb.registrationPrevious.model()
            guard previous.hostID == host.hostID, previous != host else { throw V2ActorPlacementError.invalidTransition }
            return try .host(host, previous: previous, registrationRequestID: V2HotPB.uuid(pb.registrationRequestID))
        default: throw V2PlacementRaftError.invalidMessage
        }
    }
}
