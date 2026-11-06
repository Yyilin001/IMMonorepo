import Crypto
import Foundation
import IMActorSystem
import IMV2ActorContracts
import NIOCore
import Testing
@testable import IMV2ActorCluster

@Suite("Native actor wire preserves authenticated bytes")
struct V2ActorBinaryArgumentTests {
    @Test func signedPacketRoundTripAndBounds() throws {
        struct Body: Codable, Equatable { let text: String }
        let key = Curve25519.Signing.PrivateKey(), id = try V2ActorServiceID("binary-argument")
        let signer = try V2ActorSigningIdentity(serviceID: id, privateKey: key.rawRepresentation)
        let trust = try V2ActorTrustStore(services: [.init(serviceID: id,
            publicKey: key.publicKey.rawRepresentation, permissions: [])])
        let packet = try signer.sign(Body(text: "消息 / original bytes"), maximumBytes: 1024)
        var bytes = ByteBuffer(); try packet.encodeWire(into: &bytes)
        #expect(packet.wireByteCount == bytes.readableBytes)
        var input = bytes
        let decoded = try V2ActorSignedPacket.decodeWire(from: &input)
        try input.imRequireEnd()
        #expect(decoded == packet)
        #expect(try trust.verify(decoded, as: Body.self, maximumBytes: 1024).0 == Body(text: "消息 / original bytes"))
        for length in [0, 3, bytes.readableBytes - 1] {
            var truncated = try #require(bytes.getSlice(at: 0, length: length))
            #expect(throws: (any Error).self) { try V2ActorSignedPacket.decodeWire(from: &truncated) }
        }
        let oversized = V2ActorSignedPacket(signerID: id, body: Data(), signature: Data(repeating: 1, count: 65))
        #expect(throws: V2ActorAuthenticationError.oversized) { try oversized.encodeWire(into: &input) }
    }
}
