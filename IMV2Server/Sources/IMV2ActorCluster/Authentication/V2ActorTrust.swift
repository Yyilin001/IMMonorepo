import Crypto
import Foundation
import IMV2ActorContracts
import Synchronization

public struct V2ActorTrustedService: Sendable {
    public let serviceID: V2ActorServiceID
    public let permissions: Set<V2ActorServicePermission>
    public let hostedIDs: Set<V2ActorHostID>
    public let gatewayNodeIDs: Set<String>
    public let sourceIDs: Set<String>
    let publicKey: Curve25519.Signing.PublicKey

    public init(serviceID: V2ActorServiceID, publicKey: Data,
                permissions: Set<V2ActorServicePermission>, hostedIDs: Set<V2ActorHostID> = [],
                gatewayNodeIDs: Set<String> = [], sourceIDs: Set<String> = []) throws {
        guard sourceIDs.count <= 513, sourceIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              hostedIDs.count <= 256, gatewayNodeIDs.count <= 64, gatewayNodeIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
            throw V2ActorAuthenticationError.invalidConfiguration
        }
        self.serviceID = serviceID
        self.permissions = permissions
        self.hostedIDs = hostedIDs
        self.gatewayNodeIDs = gatewayNodeIDs
        self.sourceIDs = sourceIDs
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
        let bytes = try V2ActorProtobuf.encode(body)
        guard bytes.count <= maximumBytes else { throw V2ActorAuthenticationError.oversized }
        return .init(signerID: serviceID, body: bytes, signature: try privateKey.signature(for: bytes))
    }


}

public struct V2ActorTrustStore: Sendable {
    private final class State: Sendable {
        struct Entries: Sendable {
            var services: [V2ActorServiceID: V2ActorTrustedService]
            var admitted: Set<V2ActorServiceID> = []
        }
        let entries: Mutex<Entries>
        init(_ services: [V2ActorServiceID: V2ActorTrustedService]) { entries = Mutex(Entries(services: services)) }
    }
    private let state: State
    private let admissionAuthority: V2ActorTrustAdmissionAuthority?
    private var services: [V2ActorServiceID: V2ActorTrustedService] { state.entries.withLock { $0.services } }

    public init(services: [V2ActorTrustedService], admissionAuthority: V2ActorTrustAdmissionAuthority? = nil) throws {
        try Self.validate(services)
        if let admissionAuthority {
            guard let authority = services.first(where: { $0.serviceID == admissionAuthority.serviceID }),
                  authority.hostedIDs.isEmpty, authority.gatewayNodeIDs.isEmpty, authority.permissions.isEmpty else {
                throw V2ActorAuthenticationError.invalidConfiguration
            }
        }
        state = State(Dictionary(uniqueKeysWithValues: services.map { ($0.serviceID, $0) }))
        self.admissionAuthority = admissionAuthority
    }

    private static func validate(_ services: [V2ActorTrustedService]) throws {
        guard !services.isEmpty, services.count <= 256, Set(services.map(\.serviceID)).count == services.count else {
            throw V2ActorAuthenticationError.invalidConfiguration
        }
        var hosts = Set<V2ActorHostID>()
        var gateways = Set<String>()
        for service in services {
            guard hosts.isDisjoint(with: service.hostedIDs) else { throw V2ActorAuthenticationError.invalidConfiguration }
            hosts.formUnion(service.hostedIDs)
            if service.permissions.contains(.realtimeReceive) {
                let nodes = service.gatewayNodeIDs.union([service.serviceID.rawValue])
                guard gateways.isDisjoint(with: nodes) else { throw V2ActorAuthenticationError.invalidConfiguration }
                gateways.formUnion(nodes)
            }
        }
    }

    /// Add-only signed authorization. The authority and deployment binding come
    /// from local bootstrap configuration, never from the incoming document.
    /// This changes identity and source scopes, not membership or placement.
    package func admitAuthorizedServices(_ packet: V2ActorSignedPacket) throws {
        guard let authority = admissionAuthority, packet.signerID == authority.serviceID else {
            throw V2ActorAuthenticationError.forbidden
        }
        let (authorization, _) = try verify(packet, as: V2ActorTrustAdmission.self, maximumBytes: 262_144)
        guard authorization.deploymentID == authority.deploymentID,
              !authorization.services.isEmpty, authorization.services.count <= 64,
              Set(authorization.services.map(\.serviceID)).count == authorization.services.count else {
            throw V2ActorAuthenticationError.invalidRequest
        }
        let additions = try authorization.services.map { try $0.trustedService() }
        try state.entries.withLock { installed in
            var next = installed.services
            var admitted = installed.admitted
            for service in additions {
                if let current = next[service.serviceID] {
                    guard current.publicKey.rawRepresentation == service.publicKey.rawRepresentation,
                          current.permissions == service.permissions, current.hostedIDs == service.hostedIDs,
                          current.gatewayNodeIDs == service.gatewayNodeIDs, current.sourceIDs == service.sourceIDs else {
                        throw V2ActorAuthenticationError.forbidden
                    }
                } else { next[service.serviceID] = service; admitted.insert(service.serviceID) }
            }
            try Self.validate(Array(next.values))
            installed.services = next; installed.admitted = admitted
        }
    }

    /// Explicit local scopes remain authoritative for bootstrap services.
    /// Only newly signed identities can supply scopes absent from that map.
    package func authorizedSources(for serviceID: V2ActorServiceID, configured: Set<String>?,
                                   requiring permissions: Set<V2ActorServicePermission> = []) -> Set<String> {
        if let configured { return configured }
        return state.entries.withLock { entries in
            guard entries.admitted.contains(serviceID), let service = entries.services[serviceID],
                  permissions.isSubset(of: service.permissions) else { return [] }
            return service.sourceIDs
        }
    }

    /// Resolves only explicitly authorized unique host ownership. Discovery,
    /// Actor references and payload-provided service labels cannot add trust.
    public func configuredHostServiceID(for hostID: V2ActorHostID,
                                        requiring permissions: Set<V2ActorServicePermission> = []) throws -> V2ActorServiceID {
        let matches = services.values.filter { $0.hostedIDs.contains(hostID) }
        guard matches.count == 1, let service = matches.first,
              permissions.isSubset(of: service.permissions) else {
            throw V2ActorAuthenticationError.forbidden
        }
        return service.serviceID
    }

    package func validateRoomRoster(_ peers: [V2RoomDiscoveryPeer],
                                   configured: [V2ActorHostID: Set<String>]) throws {
        for peer in peers {
            guard try configuredHostServiceID(for: peer.hostID) == peer.serviceID,
                  peer.accessibleShardIDs.isSubset(of: authorizedSources(for: peer.serviceID,
                      configured: configured[peer.hostID])) else {
                throw V2ActorAuthenticationError.forbidden
            }
        }
    }

    package func configuredService(_ id: V2ActorServiceID) throws -> V2ActorTrustedService {
        guard let peer = services[id] else { throw V2ActorAuthenticationError.unknownService }
        return peer
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
        do {
            return (try V2ActorProtobuf.decode(type, from: packet.body), service)
        }
        catch { throw V2ActorAuthenticationError.invalidRequest }
    }

    func validateRealtimeReceiver(_ identity: V2GatewayRealtimeIdentity) throws {
        guard let serviceID = try? V2ActorServiceID(identity.serviceID), let peer = services[serviceID],
              peer.permissions.contains(.realtimeReceive),
              peer.gatewayNodeIDs.contains(identity.nodeID) || peer.serviceID.rawValue == identity.nodeID else {
            throw V2ActorAuthenticationError.forbidden
        }
    }

    /// The realtime shard roster is explicit; service-name fallbacks do not
    /// create undeclared node identities or allow discovery to expand trust.
    package func validateRealtimeRoster(_ peers: [V2RealtimeShardDiscoveryPeer],
                               local: V2GatewayRealtimeIdentity, address: String, port: Int,
                               requiresLocalMember: Bool = true) throws {
        guard !peers.isEmpty, peers.count <= 64,
              Set(peers.map(\.nodeID)).count == peers.count,
              Set(peers.map { "\($0.address):\($0.port)" }).count == peers.count,
              (peers.contains(where: { $0.nodeID == local.nodeID && $0.serviceID == local.serviceID && $0.address == address && $0.port == port })
               || (!requiresLocalMember && !peers.contains(where: { $0.nodeID == local.nodeID }))) else {
            throw V2ActorAuthenticationError.invalidConfiguration
        }
        for peer in peers {
            guard !peer.nodeID.isEmpty, peer.nodeID.utf8.count <= 128,
                  !peer.address.isEmpty, peer.address.utf8.count <= 253,
                  peer.address != "0.0.0.0", peer.address != "::", (1...65_535).contains(peer.port),
                  let serviceID = try? V2ActorServiceID(peer.serviceID), let service = services[serviceID],
                  service.gatewayNodeIDs.contains(peer.nodeID),
                  service.permissions.contains(.realtimePublish), service.permissions.contains(.realtimeReceive) else {
                throw V2ActorAuthenticationError.invalidConfiguration
            }
        }
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

    func verifyReplyBinding(_ reply: V2ActorAuthenticatedReply,
                                    for call: V2ActorAuthenticatedCall) throws -> V2ActorRPCResponse {
        guard reply.host == call.recipient, reply.version == V2ActorSessionHello.protocolVersion,
              reply.sessionID == call.sessionID, reply.sequence == call.sequence,
              reply.attemptID == call.attemptID
        else { throw V2ActorAuthenticationError.wrongRecipient }
        return reply.response
    }
}
