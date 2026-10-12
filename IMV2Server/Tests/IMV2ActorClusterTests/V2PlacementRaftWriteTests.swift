import Crypto
import Foundation
import IMV2ActorContracts
import Testing
@testable import IMV2ActorCluster

@Suite("Placement commands and portable drain proof boundaries")
struct V2PlacementRaftWriteTests {
    @Test("Signed drain proof binds host, shard, group and transfer")
    func certificateBindings() throws {
        let key = Curve25519.Signing.PrivateKey(), other = Curve25519.Signing.PrivateKey()
        let service = try V2ActorServiceID("old-room-host"), otherService = try V2ActorServiceID("other-host")
        let signer = try V2ActorSigningIdentity(serviceID: service, privateKey: key.rawRepresentation)
        let impostor = try V2ActorSigningIdentity(serviceID: otherService, privateKey: other.rawRepresentation)
        let host = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let trust = try V2ActorTrustStore(services: [
            .init(serviceID: service, publicKey: key.publicKey.rawRepresentation, permissions: [.placementWrite], hostedIDs: [host.hostID]),
            .init(serviceID: otherService, publicKey: other.publicKey.rawRepresentation, permissions: [.placementWrite], hostedIDs: [.init(uuid: UUID())])])
        let group = UUID(), receipt = V2ActorPlacementDrainReceipt(clusterID: group, partition: 0,
            owner: .init(host: host, epoch: 3), transferID: UUID())
        let packet = try V2PlacementDrainCertificate.signPartition(receipt, shard: "room-a", signer: signer)
        guard case .partition(let verified) = try V2PlacementDrainCertificate.verify(packet, shard: "room-a", groupID: group, trust: trust) else {
            throw V2PlacementRaftError.invalidMessage
        }
        #expect(verified.owner == receipt.owner && verified.transferID == receipt.transferID && verified.certificate == packet)
        #expect(throws: V2PlacementRaftError.wrongGroup) {
            try V2PlacementDrainCertificate.verify(packet, shard: "room-a", groupID: UUID(), trust: trust)
        }
        #expect(throws: (any Error).self) {
            try V2PlacementDrainCertificate.verify(packet, shard: "room-b", groupID: group, trust: trust)
        }
        let forged = try V2PlacementDrainCertificate.signPartition(receipt, shard: "room-a", signer: impostor)
        #expect(throws: V2ActorAuthenticationError.forbidden) {
            try V2PlacementDrainCertificate.verify(forged, shard: "room-a", groupID: group, trust: trust)
        }
        let negative = V2ActorPlacementDrainReceipt(clusterID: group, partition: -1, owner: receipt.owner, transferID: receipt.transferID)
        #expect(throws: V2PlacementRaftError.invalidMessage) {
            try V2PlacementDrainCertificate.signPartition(negative, shard: "room-a", signer: signer)
        }
    }

    @Test("Commands round-trip without accepting raw genesis or mixed replies")
    func protobufBoundaries() throws {
        let group = UUID(), host = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let snapshot = try V2ActorPlacementSnapshot(clusterID: group, revision: 1,
            slots: [.init(owner: .init(host: host, epoch: 1), transfer: nil)])
        let requestID = UUID(), command = V2ActorPlacementCommand.retireHost(host)
        let request = V2PlacementRaftWriteCodec.Request(command: command, expected: snapshot, requestID: requestID, certificate: nil)
        let decoded = try V2PlacementRaftWriteCodec.decodeRequest(V2PlacementRaftWriteCodec.request(request, shard: "room-a"))
        #expect(decoded.command == command && decoded.requestID == requestID && decoded.expected == snapshot)
        var genesis = Im_Actor_V1_PlacementRaftWriteRequest()
        genesis.operation = try V2PlacementRaftApplication.encode(.bootstrap(snapshot))
        #expect(throws: V2ActorAuthenticationError.forbidden) {
            try V2PlacementRaftWriteCodec.decodeRequest(.init(shardID: "room-a", payload: genesis.serializedData()))
        }
        let rejected = try V2PlacementRaftWriteCodec.encode(.rejected(.staleRevision), groupID: group, shard: "room-a")
        #expect(try V2PlacementRaftWriteCodec.decode(rejected, groupID: group, shard: "room-a") == .rejected(.staleRevision))
        #expect(throws: V2PlacementRaftError.wrongGroup) {
            try V2PlacementRaftWriteCodec.decode(rejected, groupID: UUID(), shard: "room-a")
        }
        var mixed = Im_Actor_V1_PlacementRaftWriteReply()
        mixed.groupID = V2HotPB.bytes(group); mixed.snapshot = try V2ActorPlacementProtobuf.encode(snapshot); mixed.rejection = 2
        #expect(throws: V2PlacementRaftError.invalidMessage) {
            try V2PlacementRaftWriteCodec.decode(.init(shardID: "room-a", payload: mixed.serializedData()), groupID: group, shard: "room-a")
        }
    }
}
