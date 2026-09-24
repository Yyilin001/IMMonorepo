import Crypto
import Foundation
import IMV2ActorContracts

public struct V2ActorTrustedService: Sendable {
    public let serviceID: V2ActorServiceID
    public let permissions: Set<V2ActorServicePermission>
    public let hostedIDs: Set<V2ActorHostID>
    let publicKey: Curve25519.Signing.PublicKey

    public init(serviceID: V2ActorServiceID, publicKey: Data,
                permissions: Set<V2ActorServicePermission>, hostedIDs: Set<V2ActorHostID> = []) throws {
        self.serviceID = serviceID
        self.permissions = permissions
        self.hostedIDs = hostedIDs
        do { self.publicKey = try .init(rawRepresentation: publicKey) }
        catch { throw V2ActorAuthenticationError.invalidConfiguration }
    }
}

public struct V2ActorSigningIdentity: Sendable {
    public let serviceID: V2ActorServiceID
    private let privateKey: Curve25519.Signing.PrivateKey

    public init(serviceID: V2ActorServiceID, privateKey: Data) throws {
        self.serviceID = serviceID
        do { self.privateKey = try .init(rawRepresentation: privateKey) }
        catch { throw V2ActorAuthenticationError.invalidConfiguration }
    }

    public func sign<Body: Encodable>(_ body: Body, maximumBytes: Int) throws -> V2ActorSignedPacket {
        guard maximumBytes > 0 else { throw V2ActorAuthenticationError.invalidConfiguration }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(body)
        guard bytes.count <= maximumBytes else { throw V2ActorAuthenticationError.oversized }
        return .init(signerID: serviceID, body: bytes, signature: try privateKey.signature(for: bytes))
    }
}

public struct V2ActorTrustStore: Sendable {
    private let services: [V2ActorServiceID: V2ActorTrustedService]

    public init(services: [V2ActorTrustedService]) throws {
        guard !services.isEmpty, Set(services.map(\.serviceID)).count == services.count else {
            throw V2ActorAuthenticationError.invalidConfiguration
        }
        var hosts = Set<V2ActorHostID>()
        for service in services {
            guard hosts.isDisjoint(with: service.hostedIDs) else { throw V2ActorAuthenticationError.invalidConfiguration }
            hosts.formUnion(service.hostedIDs)
        }
        self.services = Dictionary(uniqueKeysWithValues: services.map { ($0.serviceID, $0) })
    }

    func verify<Body: Decodable>(_ packet: V2ActorSignedPacket, as type: Body.Type,
                                maximumBytes: Int) throws -> (Body, V2ActorTrustedService) {
        guard maximumBytes > 0, !packet.body.isEmpty, packet.body.count <= maximumBytes else {
            throw V2ActorAuthenticationError.oversized
        }
        guard let service = services[packet.signerID] else { throw V2ActorAuthenticationError.unknownService }
        guard packet.signature.count == 64,
              service.publicKey.isValidSignature(packet.signature, for: packet.body)
        else { throw V2ActorAuthenticationError.invalidSignature }
        do { return (try JSONDecoder().decode(type, from: packet.body), service) }
        catch { throw V2ActorAuthenticationError.invalidRequest }
    }

    public func verifySessionGrant(_ packet: V2ActorSignedPacket, for hello: V2ActorSessionHello,
                                   maximumBytes: Int) throws -> V2ActorSessionGrant {
        let (grant, peer) = try verify(packet, as: V2ActorSessionGrant.self, maximumBytes: maximumBytes)
        guard peer.hostedIDs.contains(hello.recipient.hostID),
              grant.host == hello.recipient, grant.version == V2ActorSessionHello.protocolVersion,
              grant.serviceID == hello.serviceID, grant.callerIncarnation == hello.callerIncarnation,
              grant.handshakeID == hello.handshakeID
        else { throw V2ActorAuthenticationError.wrongRecipient }
        return grant
    }

    public func verifyReply(_ packet: V2ActorSignedPacket, for call: V2ActorAuthenticatedCall,
                            maximumBytes: Int) throws -> V2ActorRPCResponse {
        let (reply, peer) = try verify(packet, as: V2ActorAuthenticatedReply.self, maximumBytes: maximumBytes)
        guard peer.hostedIDs.contains(call.recipient.hostID) else {
            throw V2ActorAuthenticationError.wrongRecipient
        }
        return try verifyReplyBinding(reply, for: call)
    }

    func verifyLocalReply(_ payload: V2ActorLocalPayload<V2ActorAuthenticatedReply>,
                          for call: V2ActorAuthenticatedCall, from host: V2ActorHostIdentity,
                          maximumBytes: Int) throws -> V2ActorRPCResponse {
        guard maximumBytes > 0, payload.byteCount > 0, payload.byteCount <= maximumBytes else {
            throw V2ActorAuthenticationError.oversized
        }
        guard host == call.recipient else { throw V2ActorAuthenticationError.wrongRecipient }
        return try verifyReplyBinding(payload.body, for: call)
    }

    private func verifyReplyBinding(_ reply: V2ActorAuthenticatedReply,
                                    for call: V2ActorAuthenticatedCall) throws -> V2ActorRPCResponse {
        guard reply.host == call.recipient, reply.version == V2ActorSessionHello.protocolVersion,
              reply.sessionID == call.sessionID, reply.sequence == call.sequence,
              reply.attemptID == call.attemptID
        else { throw V2ActorAuthenticationError.wrongRecipient }
        return reply.response
    }
}
