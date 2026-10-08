import Crypto
import Foundation
import IMV2ActorContracts
import IMV2Core
import Testing
@testable import IMV2ActorCluster

@Suite("Authenticated body binary framing")
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
            let packet = try signer.signAuthenticated(call, binary: binary, maximumBytes: 65_536)
            #expect(V2ActorAuthenticatedBodyFraming.recognizes(packet.body) == binary)
            #expect(try trust.verify(packet, as: V2ActorAuthenticatedCall.self, maximumBytes: 65_536).0 == call)
            if !binary { #expect(try JSONDecoder().decode(V2ActorAuthenticatedCall.self, from: packet.body) == call) }
            let reply = V2ActorAuthenticatedReply(call: call, response: .acknowledged)
            let response = try signer.signAuthenticated(reply, binary: binary, maximumBytes: 65_536)
            #expect(try trust.verify(response, as: V2ActorAuthenticatedReply.self, maximumBytes: 65_536).0 == reply)
            #expect(try trust.verifyReply(response, for: call, maximumBytes: 65_536) == .acknowledged)
            if binary {
                for size in 0..<response.body.count {
                    #expect(throws: (any Error).self) {
                        try V2ActorAuthenticatedReply.decodeBinaryAuthenticatedBody(Data(response.body.prefix(size)))
                    }
                }
                var extra = response.body; extra.append(0)
                #expect(throws: (any Error).self) { try V2ActorAuthenticatedReply.decodeBinaryAuthenticatedBody(extra) }
            }
            let wrong = V2ActorAuthenticatedReply(version: 1, host: host, sessionID: call.sessionID,
                sequence: call.sequence, attemptID: UUID(), response: .acknowledged)
            #expect(throws: V2ActorAuthenticationError.wrongRecipient) {
                try trust.verifyReply(signer.signAuthenticated(wrong, binary: binary, maximumBytes: 65_536),
                    for: call, maximumBytes: 65_536)
            }
        }
        let encoded = try call.binaryAuthenticatedBody()
        // A Data slice has a non-zero index; the codec reads relative bytes.
        var prefixed = Data([0]); prefixed.append(encoded)
        #expect(try V2ActorAuthenticatedCall.decodeBinaryAuthenticatedBody(prefixed.dropFirst()) == call)
        for size in 0..<encoded.count {
            #expect(throws: (any Error).self) {
                try V2ActorAuthenticatedCall.decodeBinaryAuthenticatedBody(Data(encoded.prefix(size)))
            }
        }
        var trailing = encoded; trailing.append(0)
        #expect(throws: (any Error).self) { try V2ActorAuthenticatedCall.decodeBinaryAuthenticatedBody(trailing) }
        var future = encoded; future[4] = 2
        #expect(throws: V2ActorAuthenticationError.unsupportedVersion) { try V2ActorAuthenticatedCall.decodeBinaryAuthenticatedBody(future) }
        var badKind = encoded; badKind[5] = 2
        #expect(throws: (any Error).self) { try V2ActorAuthenticatedCall.decodeBinaryAuthenticatedBody(badKind) }
        let payloadSizeOffset = 6 + 8 + 1 + service.rawValue.utf8.count + 16 + 1 + host.hostID.rawValue.utf8.count + 16 + 16 + 8 + 16 + 16 + 8 + 1 + (userPrincipal ? 37 : 0)
        let budgetOffset = 6 + 8 + 1 + service.rawValue.utf8.count + 16 + 1 + host.hostID.rawValue.utf8.count + 16 + 16 + 8 + 16 + 16
        var invalidBudget = encoded
        invalidBudget.replaceSubrange(budgetOffset..<(budgetOffset + 8), with: repeatElement(UInt8(0), count: 8))
        #expect(throws: (any Error).self) { try V2ActorAuthenticatedCall.decodeBinaryAuthenticatedBody(invalidBudget) }
        var invalidPrincipal = encoded; invalidPrincipal[budgetOffset + 8] = 255
        #expect(throws: (any Error).self) { try V2ActorAuthenticatedCall.decodeBinaryAuthenticatedBody(invalidPrincipal) }
        var oversized = encoded
        oversized.replaceSubrange(payloadSizeOffset..<(payloadSizeOffset + 8), with: repeatElement(UInt8(255), count: 8))
        #expect(throws: (any Error).self) { try V2ActorAuthenticatedCall.decodeBinaryAuthenticatedBody(oversized) }
        let packet = try signer.signAuthenticated(call, binary: true, maximumBytes: 65_536)
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
            try signer.signAuthenticated(call, binary: true, maximumBytes: encoded.count - 1)
        }
        let version = V2ActorAuthenticatedReply(version: -1, host: host, sessionID: call.sessionID,
            sequence: 0, attemptID: call.attemptID, response: .acknowledged)
        #expect(try V2ActorAuthenticatedReply.decodeBinaryAuthenticatedBody(version.binaryAuthenticatedBody()) == version)
    }
}
