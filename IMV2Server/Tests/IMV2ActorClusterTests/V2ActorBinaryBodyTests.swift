import Crypto
import Foundation
import IMV2ActorContracts
import IMV2Core
import Testing
@testable import IMV2ActorCluster

@Suite("Authenticated Protobuf boundary")
struct V2ActorBinaryBodyTests {
    @Test(arguments: [false, true])
    func signedRoundTrip(userPrincipal: Bool) throws {
        let key = Curve25519.Signing.PrivateKey(), service = try V2ActorServiceID("binary-body")
        let host = V2ActorHostIdentity(hostID: try .init("owner"), incarnationID: UUID())
        let token = V2RoomActivationToken(roomID: .init(uuid: UUID()), owner: try .init(shardID: "owner", epoch: 1),
            activationEpoch: try .init(1), host: host)
        let call = V2ActorAuthenticatedCall(serviceID: service, callerIncarnation: UUID(), recipient: host,
            sessionID: UUID(), sequence: UInt64.max, attemptID: UUID(), traceID: UUID(),
            remainingBudget: try .init(V2ActorMilliseconds.maximum),
            principal: userPrincipal ? .user(.init(uuid: UUID())) : .service, request: .lookup(token))
        let signer = try V2ActorSigningIdentity(serviceID: service, privateKey: key.rawRepresentation)
        let trust = try V2ActorTrustStore(services: [.init(serviceID: service,
            publicKey: key.publicKey.rawRepresentation, permissions: [], hostedIDs: [host.hostID])])
        for binary in [false, true] {
            let packet = try signer.sign(call, maximumBytes: 65_536)
            #expect(try V2ActorProtobuf.decode(V2ActorAuthenticatedCall.self, from: packet.body) == call)
            #expect(try trust.verify(packet, as: V2ActorAuthenticatedCall.self, maximumBytes: 65_536).0 == call)
            let reply = V2ActorAuthenticatedReply(call: call, response: .acknowledged)
            let response = try signer.sign(reply, maximumBytes: 65_536)
            #expect(try trust.verify(response, as: V2ActorAuthenticatedReply.self, maximumBytes: 65_536).0 == reply)
            #expect(try trust.verifyReply(response, for: call, maximumBytes: 65_536) == .acknowledged)
            let wrong = V2ActorAuthenticatedReply(version: 1, host: host, sessionID: call.sessionID,
                sequence: call.sequence, attemptID: UUID(), response: .acknowledged)
            #expect(throws: V2ActorAuthenticationError.wrongRecipient) {
                try trust.verifyReply(signer.sign(wrong, maximumBytes: 65_536),
                    for: call, maximumBytes: 65_536)
            }
        }
        let encoded = try V2ActorProtobuf.encode(call)
        var prefixed = Data([0]); prefixed.append(encoded)
        #expect(try V2ActorProtobuf.decode(V2ActorAuthenticatedCall.self, from: prefixed.dropFirst()) == call)
        var trailing = encoded; trailing.append(0)
        #expect(throws: (any Error).self) { try V2ActorProtobuf.decode(V2ActorAuthenticatedCall.self, from: trailing) }
        let packet = try signer.sign(call, maximumBytes: 65_536)
        var altered = packet.body; altered[6] ^= 1
        #expect(throws: V2ActorAuthenticationError.invalidSignature) {
            try trust.verify(.init(signerID: service, body: altered, signature: packet.signature),
                as: V2ActorAuthenticatedCall.self, maximumBytes: 65_536)
        }
        // A valid signature cannot choose another declared authenticated type.
        #expect(throws: V2ActorAuthenticationError.invalidRequest) {
            try trust.verify(packet, as: V2ActorSessionHello.self, maximumBytes: 65_536)
        }
        #expect(throws: V2ActorAuthenticationError.oversized) {
            try signer.sign(call, maximumBytes: encoded.count - 1)
        }
        let version = V2ActorAuthenticatedReply(version: -1, host: host, sessionID: call.sessionID,
            sequence: 0, attemptID: call.attemptID, response: .acknowledged)
        #expect(try V2ActorProtobuf.decode(V2ActorAuthenticatedReply.self, from: V2ActorProtobuf.encode(version)) == version)
    }
}
