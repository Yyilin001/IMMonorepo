import IMV2ActorContracts
import Crypto
import Distributed
@testable import DistributedCluster
import Foundation
import Testing
@testable import IMV2ActorCluster

@Suite("Signed packet binary arguments", .serialized)
struct V2ActorBinaryArgumentTests {
    @Test func unchangedSignedBodyAndMalformedFrames() throws {
        struct Body: Codable, Equatable { let text: String }
        let key = Curve25519.Signing.PrivateKey(), id = try V2ActorServiceID("binary-argument")
        let signer = try V2ActorSigningIdentity(serviceID: id, privateKey: key.rawRepresentation)
        let trust = try V2ActorTrustStore(services: [.init(serviceID: id,
            publicKey: key.publicKey.rawRepresentation, permissions: [])])
        let packet = try signer.sign(Body(text: "消息 / original bytes"), maximumBytes: 1024)
        let encoded = try packet.encodeClusterInvocationArgument()
        #expect(try V2ActorSignedPacket.decodeClusterInvocationArgument(encoded) == packet)
        #expect(try trust.verify(try #require(try V2ActorSignedPacket.decodeClusterInvocationArgument(encoded)),
            as: Body.self, maximumBytes: 1024).0 == Body(text: "消息 / original bytes"))
        #expect(try V2ActorSignedPacket.decodeClusterInvocationArgument(JSONEncoder().encode(packet)) == nil)
        for size in 4..<encoded.count {
            #expect(throws: (any Error).self) { try V2ActorSignedPacket.decodeClusterInvocationArgument(Data(encoded.prefix(size))) }
        }
        var trailing = encoded; trailing.append(0)
        #expect(throws: (any Error).self) { try V2ActorSignedPacket.decodeClusterInvocationArgument(trailing) }
        var oversized = encoded
        oversized.replaceSubrange(9..<13, with: [255,255,255,255])
        #expect(throws: (any Error).self) { try V2ActorSignedPacket.decodeClusterInvocationArgument(oversized) }
        var version = encoded; version[4] = 2
        #expect(throws: V2ActorAuthenticationError.unsupportedVersion) { try V2ActorSignedPacket.decodeClusterInvocationArgument(version) }
        var altered = encoded; altered[17 + id.rawValue.utf8.count] ^= 1
        let changed = try #require(try V2ActorSignedPacket.decodeClusterInvocationArgument(altered))
        #expect(throws: V2ActorAuthenticationError.invalidSignature) { try trust.verify(changed, as: Body.self, maximumBytes: 1024) }
        let shortSignature = V2ActorSignedPacket(signerID: id, body: packet.body, signature: Data([1]))
        let short = try #require(try V2ActorSignedPacket.decodeClusterInvocationArgument(shortSignature.encodeClusterInvocationArgument()))
        #expect(throws: V2ActorAuthenticationError.invalidSignature) { try trust.verify(short, as: Body.self, maximumBytes: 1024) }
        let largest = V2ActorSignedPacket(signerID: try .init(String(repeating: "s", count: 128)),
            body: Data(repeating: 0, count: 16_777_216), signature: Data(repeating: 1, count: 64))
        #expect(try V2ActorSignedPacket.decodeClusterInvocationArgument(largest.encodeClusterInvocationArgument()) == largest)
        let tooLarge = V2ActorSignedPacket(signerID: id, body: Data(repeating: 0, count: 16_777_217), signature: Data())
        #expect(throws: V2ActorAuthenticationError.oversized) { try tooLarge.encodeClusterInvocationArgument() }
    }

    @Test("real invocation encoder selects binary only on opt-in and receiver accepts legacy", arguments: [false, true])
    func invocationSelection(binary: Bool) async throws {
        var settings = ClusterSystemSettings(name: "packet-argument-\(binary)", host: "127.0.0.1", port: Int.random(in: 30000...44999))
        settings.threadPoolSize = 1; settings.downingStrategy = .none; settings.onDownAction = .none
        settings.serialization.binaryDistributedInvocations = binary
        let system = await ClusterSystem("packet-argument-\(binary)", settings: settings)
        do {
            let packet = V2ActorSignedPacket(signerID: try .init("sender"), body: Data([1,2,3]), signature: Data(repeating: 4, count: 64))
            var encoder = system.makeInvocationEncoder()
            try encoder.recordArgument(RemoteCallArgument(label: nil, name: "packet", value: packet))
            #expect(encoder.arguments.count == 1)
            #expect(encoder.arguments[0].starts(with: [73,77,86,80]) == binary)
            if !binary { #expect(try JSONDecoder().decode(V2ActorSignedPacket.self, from: encoder.arguments[0]) == packet) }
            let encoded = [try packet.encodeClusterInvocationArgument(), try JSONEncoder().encode(packet)]
            for bytes in encoded {
                let message = InvocationMessage(callID: UUID(), targetIdentifier: "test", genericSubstitutions: [], arguments: [bytes])
                var decoder = ClusterInvocationDecoder(system: system, message: message)
                let decoded: V2ActorSignedPacket = try decoder.decodeNextArgument()
                #expect(decoded == packet)
                var wrong = ClusterInvocationDecoder(system: system, message: message)
                #expect(throws: (any Error).self) { let value: V2ActorSessionHello = try wrong.decodeNextArgument(); return value.version }
            }
            try await system.shutdown().wait()
        } catch { try? await system.shutdown().wait(); throw error }
    }
}
