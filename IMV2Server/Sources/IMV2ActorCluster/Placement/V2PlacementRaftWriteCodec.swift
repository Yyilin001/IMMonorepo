import Foundation
import IMV2ActorContracts
import SwiftProtobuf

package enum V2PlacementRaftWriteCodec {
    package struct Request: Sendable {
        package let command: V2ActorPlacementCommand
        package let expected: V2ActorPlacementSnapshot
        package let requestID: UUID
        package let certificate: V2ActorSignedPacket?
        package let originRevision: UInt64
        package init(command: V2ActorPlacementCommand, expected: V2ActorPlacementSnapshot,
                     requestID: UUID, certificate: V2ActorSignedPacket?, originRevision: UInt64? = nil) {
            self.command = command; self.expected = expected; self.requestID = requestID; self.certificate = certificate
            self.originRevision = originRevision ?? expected.revision
        }
    }
    package enum Reply: Equatable, Sendable {
        case ready(V2ActorPlacementSnapshot), retry(V2ActorHostID?), rejected(V2ActorPlacementError)
    }
    package static func request(_ value: Request, shard: String) throws -> V2PlacementRaftWire {
        var pb = Im_Actor_V1_PlacementRaftWriteRequest()
        pb.operation = try V2PlacementRaftApplication.encode(.command(value.command, expected: value.expected, requestID: value.requestID, originRevision: value.originRevision))
        if let certificate = value.certificate {
            var evidence = Im_Actor_V1_PlacementSignedCertificate()
            evidence.signerID = certificate.signerID.rawValue; evidence.body = certificate.body; evidence.signature = certificate.signature
            pb.evidence = evidence
        }
        return try bounded(shard, pb.serializedData())
    }
    package static func decodeRequest(_ wire: V2PlacementRaftWire) throws -> Request {
        guard wire.isBounded else { throw V2PlacementRaftError.invalidMessage }
        let pb = try Im_Actor_V1_PlacementRaftWriteRequest(serializedBytes: wire.payload)
        try V2HotPB.check(pb)
        guard case .command(let command, let expected, let id, let originRevision) = try V2PlacementRaftApplication.decode(pb.operation) else {
            throw V2ActorAuthenticationError.forbidden
        }
        let evidence: V2ActorSignedPacket?
        if pb.hasEvidence {
            try V2HotPB.check(pb.evidence, pb.evidence.body.count <= 8192 && pb.evidence.signature.count == 64)
            evidence = try .init(signerID: V2ActorServiceID(pb.evidence.signerID), body: pb.evidence.body, signature: pb.evidence.signature)
        } else { evidence = nil }
        return .init(command: command, expected: expected, requestID: id, certificate: evidence, originRevision: originRevision)
    }
    package static func encode(_ value: Reply, groupID: UUID, shard: String) throws -> V2PlacementRaftWire {
        var pb = Im_Actor_V1_PlacementRaftWriteReply(); pb.groupID = V2HotPB.bytes(groupID)
        switch value {
        case .ready(let snapshot):
            guard snapshot.clusterID == groupID else { throw V2PlacementRaftError.wrongGroup }
            pb.snapshot = try V2ActorPlacementProtobuf.encode(snapshot)
        case .retry(let hint): pb.leaderHint = hint?.rawValue ?? ""
        case .rejected(let error): pb.rejection = rejection(error)
        }
        return try bounded(shard, pb.serializedData())
    }
    package static func decode(_ wire: V2PlacementRaftWire, groupID: UUID, shard: String) throws -> Reply {
        guard wire.isBounded, wire.shardID == shard else { throw V2PlacementRaftError.invalidMessage }
        let pb = try Im_Actor_V1_PlacementRaftWriteReply(serializedBytes: wire.payload)
        try V2HotPB.check(pb)
        guard try V2HotPB.uuid(pb.groupID) == groupID else { throw V2PlacementRaftError.wrongGroup }
        if !pb.snapshot.isEmpty {
            guard pb.leaderHint.isEmpty, pb.rejection == 0 else { throw V2PlacementRaftError.invalidMessage }
            let snapshot = try V2ActorPlacementProtobuf.decode(pb.snapshot)
            guard snapshot.clusterID == groupID else { throw V2PlacementRaftError.wrongGroup }
            return .ready(snapshot)
        }
        if pb.rejection != 0 {
            guard pb.leaderHint.isEmpty, let error = rejection(pb.rejection) else { throw V2PlacementRaftError.invalidMessage }
            return .rejected(error)
        }
        return try .retry(pb.leaderHint.isEmpty ? nil : V2ActorHostID(pb.leaderHint))
    }
    private static func bounded(_ shard: String, _ payload: Data) throws -> V2PlacementRaftWire {
        let wire = V2PlacementRaftWire(shardID: shard, payload: payload)
        guard wire.isBounded else { throw V2PlacementRaftError.invalidMessage }
        return wire
    }
    private static func rejection(_ error: V2ActorPlacementError) -> UInt32 {
        switch error {
        case .invalidConfiguration: 1; case .staleRevision: 2; case .conflictingSnapshot: 3; case .staleOwner: 4
        case .unavailable: 5; case .retiring: 6; case .invalidTransition: 7; case .epochExhausted: 8
        case .archiveCapacity: 9; case .requestExpired: 10
        }
    }
    private static func rejection(_ code: UInt32) -> V2ActorPlacementError? {
        switch code {
        case 1: .invalidConfiguration; case 2: .staleRevision; case 3: .conflictingSnapshot; case 4: .staleOwner
        case 5: .unavailable; case 6: .retiring; case 7: .invalidTransition; case 8: .epochExhausted
        case 9: .archiveCapacity; case 10: .requestExpired; default: nil
        }
    }
}
