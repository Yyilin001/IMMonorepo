import Crypto
import Synchronization
import Distributed
import DistributedCluster
import Foundation
import IMV2ActorContracts

struct RealtimeHello: Codable, Sendable {
    let serviceID: V2ActorServiceID
    let version: Int
    let callerIncarnation: UUID
    let recipient: V2GatewayRealtimeIdentity
    let handshakeID: UUID
    let endpointDigest: Data
    var agreementKey: Data? = nil
}
struct RealtimeGrant: Codable, Sendable {
    let hello: RealtimeHello
    let sessionID: UUID
    let remainingMilliseconds: Int64
    var agreementKey: Data? = nil
}
struct RealtimeCall: Codable, Sendable {
    let serviceID: V2ActorServiceID
    let version: Int
    let callerIncarnation: UUID
    let recipient: V2GatewayRealtimeIdentity
    let sessionID: UUID
    let sequence: UInt64
    let attemptID: UUID
    let batch: V2RealtimeBatch
}
struct RealtimeReply: Codable, Sendable {
    let recipient: V2GatewayRealtimeIdentity
    let sessionID: UUID
    let sequence: UInt64
    let attemptID: UUID
    let acceptance: V2RealtimeAcceptance
}

struct JournalProjectionCall: Codable, Sendable {
    let serviceID: V2ActorServiceID
    let version: Int
    let callerIncarnation: UUID
    let recipient: V2GatewayRealtimeIdentity
    let sessionID: UUID
    let sequence: UInt64
    let attemptID: UUID
    let batch: V2RealtimeJournalProjectionBatch
}
struct JournalProjectionReply: Codable, Sendable {
    let recipient: V2GatewayRealtimeIdentity
    let sessionID: UUID
    let sequence: UInt64
    let attemptID: UUID
    let result: V2RealtimeJournalProjectionResult
}

struct RoomSubscriptionCall: Codable, Sendable {
    let serviceID: V2ActorServiceID
    let version: Int
    let callerIncarnation: UUID
    let recipient: V2GatewayRealtimeIdentity
    let sessionID: UUID
    let sequence: UInt64
    let attemptID: UUID
    let sourceShardID: String
    let delivery: V2RoomSubscriptionDelivery
}
struct RoomSubscriptionReply: Codable, Sendable {
    let recipient: V2GatewayRealtimeIdentity
    let sessionID: UUID
    let sequence: UInt64
    let attemptID: UUID
    let result: V2RoomSubscriptionDeliveryResult
}

struct RoomSubscriptionBatchCall: Codable, Sendable {
    let serviceID: V2ActorServiceID
    let version: Int
    let callerIncarnation: UUID
    let recipient: V2GatewayRealtimeIdentity
    let sessionID: UUID
    let sequence: UInt64
    let attemptID: UUID
    let sourceShardID: String
    let batch: V2RoomSubscriptionDeliveryBatch

}
struct RoomSubscriptionBatchReply: Codable, Sendable {
    let recipient: V2GatewayRealtimeIdentity
    let sessionID: UUID
    let sequence: UInt64
    let attemptID: UUID
    let result: V2RoomSubscriptionBatchResult
}

struct RoomDeliverySessionCall: Codable, Equatable, Sendable {
    let serviceID: V2ActorServiceID
    let version: Int
    let callerIncarnation: UUID
    let recipient: V2GatewayRealtimeIdentity
    let sessionID: UUID
    let sequence: UInt64
    let attemptID: UUID
    let sourceShardID: String
    let pulse: V2RoomDeliverySessionPulse
}
struct RoomDeliverySessionReply: Codable, Equatable, Sendable {
    let recipient: V2GatewayRealtimeIdentity
    let sessionID: UUID
    let sequence: UInt64
    let attemptID: UUID
    let result: V2RoomDeliverySessionResult
}

public distributed actor V2GatewayRealtimeEndpoint {
    public typealias ActorSystem = ClusterSystem
    private let service: V2GatewayRealtimeInbound
    init(actorSystem: ClusterSystem, service: V2GatewayRealtimeInbound) {
        self.actorSystem = actorSystem; self.service = service
    }
    public distributed func openSession(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        try await service.openSession(packet)
    }
    public distributed func deliverySession(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        try await service.deliverySession(packet)
    }
    public distributed func projectJournal(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        try await service.projectJournal(packet)
    }
    public distributed func deliverRoomSubscriptionBatch(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        try await service.deliverRoomSubscriptionBatch(packet)
    }
    public distributed func deliverRoomSubscription(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        try await service.deliverRoomSubscription(packet)
    }
    public distributed func exchange(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        try await service.exchange(packet)
    }
}

/// No SQL, client authorization, or socket waits occur on admission.
actor V2GatewayRealtimeInbound {
    let identity: V2GatewayRealtimeIdentity
    let signer: V2ActorSigningIdentity
    let trust: V2ActorTrustStore
    let ingress: any V2RealtimeIngress
    let limits: V2RealtimeTransportLimits
    let serviceOwnerAccess: [V2ActorServiceID: Set<String>]
    private nonisolated let endpointDigest = Mutex<Data?>(nil)
    private var sessions: [UUID: Session] = [:]
    private var accepting = true
    private var roomSubscriptionHandler: (any V2RoomSubscriptionHandler)?
    private var projectionHandler: (any V2RealtimeJournalProjectionHandler)?
    // Actor-confined reference state avoids copying the replay window on every RPC.
    private final class Session {
        let service: V2ActorServiceID
        let incarnation: UUID
        let handshake: UUID
        let helloDigest: Data
        let expires: ContinuousClock.Instant
        let mac: V2ActorSessionMAC?
        let agreementKey: Data?
        var highest: UInt64 = 0
        var slots: [(sequence: UInt64, attemptID: UUID)?] = Array(repeating: nil, count: 1_024)
        var attempts: [UUID: UInt64] = [:]

        init(service: V2ActorServiceID, incarnation: UUID, handshake: UUID, helloDigest: Data, mac: V2ActorSessionMAC?, agreementKey: Data?, expires: ContinuousClock.Instant) {
            self.service = service; self.incarnation = incarnation; self.handshake = handshake; self.helloDigest = helloDigest; self.mac = mac; self.agreementKey = agreementKey; self.expires = expires
        }
        func accept(sequence: UInt64, attemptID: UUID) throws {
            let window = UInt64(slots.count)
            let lower = highest >= window ? highest - window + 1 : 1
            guard sequence > 0, sequence >= lower else { throw V2ActorAuthenticationError.replay }
            if let old = attempts[attemptID], old >= lower { throw V2ActorAuthenticationError.replay }
            let index = Int(sequence % window)
            guard slots[index]?.sequence != sequence else { throw V2ActorAuthenticationError.replay }
            if let old = slots[index], attempts[old.attemptID] == old.sequence { attempts.removeValue(forKey: old.attemptID) }
            highest = max(highest, sequence)
            slots[index] = (sequence, attemptID)
            attempts[attemptID] = sequence
        }
    }
    init(identity: V2GatewayRealtimeIdentity, signer: V2ActorSigningIdentity, trust: V2ActorTrustStore,
         ingress: any V2RealtimeIngress, serviceOwnerAccess: [V2ActorServiceID: Set<String>],
         limits: V2RealtimeTransportLimits) {
        self.identity = identity; self.signer = signer; self.trust = trust; self.ingress = ingress
        self.serviceOwnerAccess = serviceOwnerAccess; self.limits = limits
    }
    nonisolated func bindEndpointReference(_ bytes: Data) {
        endpointDigest.withLock { digest in
            precondition(digest == nil)
            digest = Data(SHA256.hash(data: bytes))
        }
    }
    func stop() { accepting = false; sessions.removeAll() }
    func openSession(_ packet: V2ActorSignedPacket) throws -> V2ActorSignedPacket {
        guard accepting else { throw V2ActorAuthenticationError.overloaded }
        let (hello, peer) = try trust.verify(packet, as: RealtimeHello.self, maximumBytes: 16_384)
        guard hello.serviceID == peer.serviceID else { throw V2ActorAuthenticationError.forbidden }
        guard hello.version == 1, hello.recipient == identity,
              endpointDigest.withLock({ $0 == hello.endpointDigest }) else { throw V2ActorAuthenticationError.wrongRecipient }
        guard peer.permissions.contains(.realtimePublish), serviceOwnerAccess[peer.serviceID] != nil else {
            throw V2ActorAuthenticationError.forbidden
        }
        let now = ContinuousClock.now
        sessions = sessions.filter { $0.value.expires > now }
        let transcript = try V2ActorProtobuf.encode(hello)
        let helloDigest = Data(SHA256.hash(data: transcript))
        let id: UUID
        if let existing = sessions.first(where: { $0.value.service == peer.serviceID && $0.value.incarnation == hello.callerIncarnation && $0.value.handshake == hello.handshakeID }) {
            guard existing.value.helloDigest == helloDigest else { throw V2ActorAuthenticationError.invalidRequest }
            id = existing.key
        } else {
            guard sessions.count < 256, sessions.values.filter({ $0.service == peer.serviceID }).count < 8 else { throw V2ActorAuthenticationError.overloaded }
            id = UUID()
            let agreement = hello.agreementKey.map { _ in Curve25519.KeyAgreement.PrivateKey() }
            let mac = try agreement.map { try V2ActorSessionMAC(privateKey: $0, peerKey: hello.agreementKey!,
                transcript: transcript, sessionID: id, client: peer.serviceID, server: signer.serviceID) }
            sessions[id] = Session(service: peer.serviceID, incarnation: hello.callerIncarnation, handshake: hello.handshakeID, helloDigest: helloDigest, mac: mac, agreementKey: agreement?.publicKey.rawRepresentation, expires: now + .seconds(300))
        }
        let duration = now.duration(to: sessions[id]!.expires).components
        let remaining = duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000
        return try signer.sign(RealtimeGrant(hello: hello, sessionID: id, remainingMilliseconds: remaining, agreementKey: sessions[id]!.agreementKey), maximumBytes: 16_384)
    }
    private func verifySessionPacket<Body: Decodable & V2ActorSessionBoundCall & V2ActorMACBody>(_ packet: V2ActorSignedPacket,
        as type: Body.Type) throws -> (Body, V2ActorTrustedService) {
        if packet.signature.count == 32 {
            let id = try V2ActorSessionMAC.packetSessionID(packet)
            guard let session = sessions[id], session.expires > .now, let mac = session.mac else {
                throw V2ActorAuthenticationError.sessionExpired
            }
            let body = try mac.open(packet, as: type, reply: false, maximumBytes: limits.maximumPacketBytes)
            guard body.sessionID == id else { throw V2ActorAuthenticationError.wrongRecipient }
            return (body, try trust.configuredService(packet.signerID))
        }
        let (body, peer) = try trust.verify(packet, as: type, maximumBytes: limits.maximumPacketBytes)
        guard sessions[body.sessionID]?.mac == nil else { throw V2ActorAuthenticationError.invalidSignature }
        return (body, peer)
    }
    private func sessionReply<Body: Encodable & V2ActorMACBody>(_ body: Body, session: Session, maximumBytes: Int) throws -> V2ActorSignedPacket {
        if let mac = session.mac { return try mac.seal(body, reply: true, maximumBytes: maximumBytes) }
        return try signer.sign(body, maximumBytes: maximumBytes)
    }
    func configureJournalProjection(_ handler: any V2RealtimeJournalProjectionHandler) throws {
        guard accepting, projectionHandler == nil else { throw V2ActorAuthenticationError.invalidConfiguration }
        projectionHandler = handler
    }
    func configureRoomSubscription(_ handler: any V2RoomSubscriptionHandler) throws {
        guard accepting, roomSubscriptionHandler == nil else { throw V2ActorAuthenticationError.invalidConfiguration }
        roomSubscriptionHandler = handler
    }
    func deliverRoomSubscriptionBatch(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        guard accepting else { throw V2ActorAuthenticationError.overloaded }
        let (call, peer) = try verifySessionPacket(packet, as: RoomSubscriptionBatchCall.self)
        guard call.serviceID == peer.serviceID, peer.permissions.contains(.realtimePublish),
              serviceOwnerAccess[peer.serviceID]?.contains(call.sourceShardID) == true else {
            throw V2ActorAuthenticationError.forbidden
        }
        guard call.version == 1, call.recipient == identity else { throw V2ActorAuthenticationError.wrongRecipient }
        guard let session = sessions[call.sessionID], session.expires > .now,
              session.service == peer.serviceID, session.incarnation == call.callerIncarnation else {
            throw V2ActorAuthenticationError.sessionExpired
        }
        let validated = try validateRoomSubscriptionBatch(call.batch, sourceShardID: call.sourceShardID, limits: limits)
        try session.accept(sequence: call.sequence, attemptID: call.attemptID)
        let result = await roomSubscriptionHandler?.applyRoomSubscriptionBatch(validated,
            authenticatedServiceID: peer.serviceID.rawValue, sourceShardID: call.sourceShardID)
            ?? V2RoomSubscriptionBatchResult(receipts: validated.rooms.map(\.fence).map { .init(fence: $0, result: .stale) })
        try validateRoomSubscriptionBatchReceipt(result, validated: validated)
        return try sessionReply(RoomSubscriptionBatchReply(recipient: identity, sessionID: call.sessionID,
            sequence: call.sequence, attemptID: call.attemptID, result: result), session: session, maximumBytes: limits.maximumPacketBytes)
    }
    func deliverySession(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        guard accepting else { throw V2ActorAuthenticationError.overloaded }
        let (call, peer) = try verifySessionPacket(packet, as: RoomDeliverySessionCall.self)
        guard call.serviceID == peer.serviceID, peer.permissions.contains(.realtimePublish),
              serviceOwnerAccess[peer.serviceID]?.contains(call.sourceShardID) == true,
              call.pulse.session.gateway == identity else { throw V2ActorAuthenticationError.forbidden }
        guard call.version == 1, call.recipient == identity else { throw V2ActorAuthenticationError.wrongRecipient }
        guard let session = sessions[call.sessionID], session.expires > .now,
              session.service == peer.serviceID, session.incarnation == call.callerIncarnation else {
            throw V2ActorAuthenticationError.sessionExpired
        }
        try call.pulse.session.validate()
        guard call.pulse.sequence > 0 else { throw V2ActorAuthenticationError.invalidConfiguration }
        try session.accept(sequence: call.sequence, attemptID: call.attemptID)
        let result = await roomSubscriptionHandler?.applyDeliverySession(call.pulse,
            authenticatedServiceID: peer.serviceID.rawValue) ?? .stale
        return try sessionReply(RoomDeliverySessionReply(recipient: identity, sessionID: call.sessionID,
            sequence: call.sequence, attemptID: call.attemptID, result: result), session: session, maximumBytes: 16_384)
    }
    func deliverRoomSubscription(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        guard accepting else { throw V2ActorAuthenticationError.overloaded }
        let (call, peer) = try verifySessionPacket(packet, as: RoomSubscriptionCall.self)
        guard call.serviceID == peer.serviceID, peer.permissions.contains(.realtimePublish),
              serviceOwnerAccess[peer.serviceID]?.contains(call.sourceShardID) == true else {
            throw V2ActorAuthenticationError.forbidden
        }
        guard call.version == 1, call.recipient == identity else { throw V2ActorAuthenticationError.wrongRecipient }
        guard let session = sessions[call.sessionID], session.expires > .now,
              session.service == peer.serviceID, session.incarnation == call.callerIncarnation else {
            throw V2ActorAuthenticationError.sessionExpired
        }
        try validateRoomSubscriptionDelivery(call.delivery, sourceShardID: call.sourceShardID, limits: limits)
        try session.accept(sequence: call.sequence, attemptID: call.attemptID)
        // Session authentication grants a transport call only. Exact room fence,
        // member authority and trusted lease deadlines belong to this handler.
        let result = await roomSubscriptionHandler?.applyRoomSubscription(call.delivery,
            authenticatedServiceID: peer.serviceID.rawValue, sourceShardID: call.sourceShardID) ?? .stale
        try validateRoomSubscriptionReceipt(result, delivery: call.delivery)
        return try sessionReply(RoomSubscriptionReply(recipient: identity, sessionID: call.sessionID,
            sequence: call.sequence, attemptID: call.attemptID, result: result), session: session, maximumBytes: 16_384)
    }
    func projectJournal(_ packet: V2ActorSignedPacket) throws -> V2ActorSignedPacket {
        guard accepting else { throw V2ActorAuthenticationError.overloaded }
        let (call, peer) = try verifySessionPacket(packet, as: JournalProjectionCall.self)
        guard call.serviceID == peer.serviceID, peer.permissions.contains(.realtimePublish),
              serviceOwnerAccess[peer.serviceID]?.contains(call.batch.source.sourceID) == true else {
            throw V2ActorAuthenticationError.forbidden
        }
        guard call.version == 1, call.recipient == identity,
              call.batch.fence.gatewayIncarnationID == identity.incarnationID else { throw V2ActorAuthenticationError.wrongRecipient }
        guard let session = sessions[call.sessionID], session.expires > .now,
              session.service == peer.serviceID, session.incarnation == call.callerIncarnation else {
            throw V2ActorAuthenticationError.sessionExpired
        }
        try validateJournalProjectionBatch(call.batch, limits: limits)
        try session.accept(sequence: call.sequence, attemptID: call.attemptID)
        // The trusted handler owns exact-token/cold-cut authorization and commits
        // synchronously. No publisher grant or queue acceptance creates authority.
        let result = projectionHandler?.applyJournalProjection(call.batch, authenticatedServiceID: peer.serviceID.rawValue) ?? .stale
        return try sessionReply(JournalProjectionReply(recipient: identity, sessionID: call.sessionID,
            sequence: call.sequence, attemptID: call.attemptID, result: result), session: session, maximumBytes: 16_384)
    }
    func exchange(_ packet: V2ActorSignedPacket) throws -> V2ActorSignedPacket {
        guard accepting else { throw V2ActorAuthenticationError.overloaded }
        let (call, peer) = try verifySessionPacket(packet, as: RealtimeCall.self)
        guard call.serviceID == peer.serviceID else { throw V2ActorAuthenticationError.forbidden }
        guard call.version == 1, call.recipient == identity, call.batch.recipient == identity else { throw V2ActorAuthenticationError.wrongRecipient }
        guard peer.permissions.contains(.realtimePublish), let owners = serviceOwnerAccess[peer.serviceID],
              call.batch.deliveries.allSatisfy({ owners.contains($0.topic.owner.shardID) }) else { throw V2ActorAuthenticationError.forbidden }
        guard let session = sessions[call.sessionID], session.expires > .now,
              session.service == peer.serviceID, session.incarnation == call.callerIncarnation else { throw V2ActorAuthenticationError.sessionExpired }
        do { try call.batch.validate(limits: limits) }
        catch { throw V2ActorAuthenticationError.invalidRequest }
        try session.accept(sequence: call.sequence, attemptID: call.attemptID)
        let acceptance = ingress.offer(call.batch)
        return try sessionReply(RealtimeReply(recipient: identity, sessionID: call.sessionID, sequence: call.sequence,
                                              attemptID: call.attemptID, acceptance: acceptance), session: session, maximumBytes: 16_384)
    }
}

public actor V2RealtimeClusterSender {
    private let system: ClusterSystem
    private let signer: V2ActorSigningIdentity
    private let trust: V2ActorTrustStore
    private let limits: V2RealtimeTransportLimits
    private let incarnation = UUID()
    private var stopped = false
    private var active = 0
    private var sessionCalls = 0
    private var sessionPeers: Set<V2GatewayRealtimeIdentity> = []
    private var authorizationCalls = 0
    private var authorizationPeers: [V2GatewayRealtimeIdentity: Int] = [:]
    private var peerActive: [V2GatewayRealtimeIdentity: Int] = [:]
    private var sessions: [V2GatewayRealtimeDescriptor: Session] = [:]
    private var openings: [V2GatewayRealtimeDescriptor: Task<Session, Error>] = [:]
    private struct Session: Sendable {
        let endpoint: V2GatewayRealtimeEndpoint
        let id: UUID
        let mac: V2ActorSessionMAC
        let expires: ContinuousClock.Instant
        var sequence: UInt64
    }
    init(system: ClusterSystem, signer: V2ActorSigningIdentity, trust: V2ActorTrustStore, limits: V2RealtimeTransportLimits) {
        self.system = system; self.signer = signer; self.trust = trust; self.limits = limits
    }
    public func send(_ batch: V2RealtimeBatch, to target: V2GatewayRealtimeDescriptor) async throws -> V2RealtimeAcceptance {
        try Task.checkCancellation()
        try target.validate(); try batch.validate(limits: limits)
        // Reject unknown service/node destinations before ActorID resolution or network association.
        try trust.validateRealtimeReceiver(target.identity)
        guard target.identity == batch.recipient else { throw V2ActorAuthenticationError.wrongRecipient }
        try acquireCallback(to: target.identity)
        defer { releaseCallback(to: target.identity) }
        var session = try await session(for: target)
        try Task.checkCancellation()
        guard !stopped, session.expires > .now else { throw V2ActorAuthenticationError.sessionExpired }
        guard session.sequence < UInt64.max else { throw V2ActorAuthenticationError.sessionExpired }
        // Obtain the current counter after the handshake suspension; concurrent sends must not reuse it.
        session = sessions[target] ?? session
        guard session.sequence < UInt64.max else { throw V2ActorAuthenticationError.sessionExpired }
        session.sequence += 1; sessions[target] = session
        let call = RealtimeCall(serviceID: signer.serviceID, version: 1, callerIncarnation: incarnation, recipient: target.identity,
                                sessionID: session.id, sequence: session.sequence, attemptID: UUID(), batch: batch)
        let packet = try session.mac.seal(call, reply: false, maximumBytes: limits.maximumPacketBytes)
        do {
            let endpoint = session.endpoint
            let response = try await RemoteCall.with(timeout: limits.callTimeout) { try await endpoint.exchange(packet) }
            let peer = try trust.configuredService(try V2ActorServiceID(target.identity.serviceID))
            let reply = try session.mac.open(response, as: RealtimeReply.self, reply: true, maximumBytes: 16_384)
            try validatePeer(peer, target: target)
            guard reply.recipient == target.identity, reply.sessionID == call.sessionID,
                  reply.sequence == call.sequence, reply.attemptID == call.attemptID else { throw V2ActorAuthenticationError.wrongRecipient }
            return reply.acceptance
        } catch {
            if let auth = error as? V2ActorAuthenticationError,
               auth == .sessionExpired || auth == .wrongRecipient, sessions[target]?.id == session.id {
                sessions.removeValue(forKey: target)
            }
            throw error
        }
    }
    public func sendJournalProjection(_ batch: V2RealtimeJournalProjectionBatch,
                                      to target: V2GatewayRealtimeDescriptor) async throws -> V2RealtimeJournalProjectionResult {
        try Task.checkCancellation()
        try target.validate()
        try validateJournalProjectionBatch(batch, limits: limits)
        try trust.validateRealtimeReceiver(target.identity)
        guard batch.fence.gatewayIncarnationID == target.identity.incarnationID else { throw V2ActorAuthenticationError.wrongRecipient }
        try acquireCallback(to: target.identity)
        defer { releaseCallback(to: target.identity) }
        var session = try await session(for: target)
        try Task.checkCancellation()
        guard !stopped, session.expires > .now else { throw V2ActorAuthenticationError.sessionExpired }
        session = sessions[target] ?? session
        guard session.sequence < UInt64.max else { throw V2ActorAuthenticationError.sessionExpired }
        session.sequence += 1; sessions[target] = session
        let call = JournalProjectionCall(serviceID: signer.serviceID, version: 1, callerIncarnation: incarnation,
            recipient: target.identity, sessionID: session.id, sequence: session.sequence, attemptID: UUID(), batch: batch)
        let packet = try session.mac.seal(call, reply: false, maximumBytes: limits.maximumPacketBytes)
        do {
            let endpoint = session.endpoint
            let response = try await RemoteCall.with(timeout: limits.callTimeout) { try await endpoint.projectJournal(packet) }
            let peer = try trust.configuredService(try V2ActorServiceID(target.identity.serviceID))
            let reply = try session.mac.open(response, as: JournalProjectionReply.self, reply: true, maximumBytes: 16_384)
            try validatePeer(peer, target: target)
            guard reply.recipient == target.identity, reply.sessionID == call.sessionID,
                  reply.sequence == call.sequence, reply.attemptID == call.attemptID else { throw V2ActorAuthenticationError.wrongRecipient }
            try validateJournalProjectionReceipt(reply.result, batch: batch)
            return reply.result
        } catch {
            if let auth = error as? V2ActorAuthenticationError,
               auth == .sessionExpired || auth == .wrongRecipient, sessions[target]?.id == session.id {
                sessions.removeValue(forKey: target)
            }
            throw error
        }
    }
    public func sendRoomSubscription(_ delivery: V2RoomSubscriptionDelivery, sourceShardID: String,
                                     to target: V2GatewayRealtimeDescriptor) async throws -> V2RoomSubscriptionDeliveryResult {
        try Task.checkCancellation()
        try target.validate()
        try validateRoomSubscriptionDelivery(delivery, sourceShardID: sourceShardID, limits: limits)
        try trust.validateRealtimeReceiver(target.identity)
        try acquireCallback(to: target.identity)
        defer { releaseCallback(to: target.identity) }
        var session = try await session(for: target)
        try Task.checkCancellation()
        guard !stopped, session.expires > .now else { throw V2ActorAuthenticationError.sessionExpired }
        session = sessions[target] ?? session
        guard session.sequence < UInt64.max else { throw V2ActorAuthenticationError.sessionExpired }
        session.sequence += 1; sessions[target] = session
        let call = RoomSubscriptionCall(serviceID: signer.serviceID, version: 1, callerIncarnation: incarnation,
            recipient: target.identity, sessionID: session.id, sequence: session.sequence, attemptID: UUID(),
            sourceShardID: sourceShardID, delivery: delivery)
        let packet = try session.mac.seal(call, reply: false, maximumBytes: limits.maximumPacketBytes)
        do {
            let endpoint = session.endpoint
            let response = try await RemoteCall.with(timeout: limits.callTimeout) { try await endpoint.deliverRoomSubscription(packet) }
            let peer = try trust.configuredService(try V2ActorServiceID(target.identity.serviceID))
            let reply = try session.mac.open(response, as: RoomSubscriptionReply.self, reply: true, maximumBytes: 16_384)
            try validatePeer(peer, target: target)
            guard reply.recipient == target.identity, reply.sessionID == call.sessionID,
                  reply.sequence == call.sequence, reply.attemptID == call.attemptID else { throw V2ActorAuthenticationError.wrongRecipient }
            try validateRoomSubscriptionReceipt(reply.result, delivery: delivery)
            return reply.result
        } catch {
            if let auth = error as? V2ActorAuthenticationError,
               auth == .sessionExpired || auth == .wrongRecipient, sessions[target]?.id == session.id {
                sessions.removeValue(forKey: target)
            }
            throw error
        }
    }
    public func sendRoomSubscriptionBatch(_ batch: V2RoomSubscriptionDeliveryBatch, sourceShardID: String,
                                          to target: V2GatewayRealtimeDescriptor) async throws -> V2RoomSubscriptionBatchResult {
        try Task.checkCancellation()
        try target.validate()
        let validated = try validateRoomSubscriptionBatch(batch, sourceShardID: sourceShardID, limits: limits)
        try trust.validateRealtimeReceiver(target.identity)
        let authorization = batch.deliveries.allSatisfy { $0.payload.isAuthorizationControl }
        if authorization { try acquireAuthorization(to: target.identity) }
        else { try acquireCallback(to: target.identity) }
        defer {
            if authorization { releaseAuthorization(to: target.identity) }
            else { releaseCallback(to: target.identity) }
        }
        var session = try await session(for: target)
        try Task.checkCancellation()
        guard !stopped, session.expires > .now else { throw V2ActorAuthenticationError.sessionExpired }
        session = sessions[target] ?? session
        guard session.sequence < UInt64.max else { throw V2ActorAuthenticationError.sessionExpired }
        session.sequence += 1; sessions[target] = session
        let call = RoomSubscriptionBatchCall(serviceID: signer.serviceID, version: 1, callerIncarnation: incarnation,
            recipient: target.identity, sessionID: session.id, sequence: session.sequence, attemptID: UUID(),
            sourceShardID: sourceShardID, batch: batch)
        let packet = try session.mac.seal(call, reply: false, maximumBytes: limits.maximumPacketBytes)
        do {
            let endpoint = session.endpoint
            let response = try await RemoteCall.with(timeout: limits.callTimeout) { try await endpoint.deliverRoomSubscriptionBatch(packet) }
            let peer = try trust.configuredService(try V2ActorServiceID(target.identity.serviceID))
            let reply = try session.mac.open(response, as: RoomSubscriptionBatchReply.self, reply: true, maximumBytes: limits.maximumPacketBytes)
            try validatePeer(peer, target: target)
            guard reply.recipient == target.identity, reply.sessionID == call.sessionID,
                  reply.sequence == call.sequence, reply.attemptID == call.attemptID else { throw V2ActorAuthenticationError.wrongRecipient }
            try validateRoomSubscriptionBatchReceipt(reply.result, validated: validated)
            return reply.result
        } catch {
            if let auth = error as? V2ActorAuthenticationError,
               auth == .sessionExpired || auth == .wrongRecipient, sessions[target]?.id == session.id {
                sessions.removeValue(forKey: target)
            }
            throw error
        }
    }
    public func sendDeliverySession(_ pulse: V2RoomDeliverySessionPulse, sourceShardID: String,
                                    to target: V2GatewayRealtimeDescriptor) async throws -> V2RoomDeliverySessionResult {
        try Task.checkCancellation(); try target.validate(); try pulse.session.validate()
        guard pulse.session.gateway == target.identity,
              pulse.sequence > 0, !sourceShardID.isEmpty else { throw V2ActorAuthenticationError.invalidConfiguration }
        try trust.validateRealtimeReceiver(target.identity)
        guard !stopped, sessionCalls < 8, !sessionPeers.contains(target.identity) else { throw V2ActorAuthenticationError.overloaded }
        sessionCalls += 1; sessionPeers.insert(target.identity)
        defer { sessionCalls -= 1; sessionPeers.remove(target.identity) }
        var session = try await session(for: target)
        try Task.checkCancellation()
        guard !stopped, session.expires > .now else { throw V2ActorAuthenticationError.sessionExpired }
        session = sessions[target] ?? session
        guard session.sequence < UInt64.max else { throw V2ActorAuthenticationError.sessionExpired }
        session.sequence += 1; sessions[target] = session
        let call = RoomDeliverySessionCall(serviceID: signer.serviceID, version: 1, callerIncarnation: incarnation,
            recipient: target.identity, sessionID: session.id, sequence: session.sequence, attemptID: UUID(),
            sourceShardID: sourceShardID, pulse: pulse)
        let packet = try session.mac.seal(call, reply: false, maximumBytes: 16_384)
        do {
        let endpoint = session.endpoint
        let response = try await RemoteCall.with(timeout: .seconds(2)) { try await endpoint.deliverySession(packet) }
        let peer = try trust.configuredService(try V2ActorServiceID(target.identity.serviceID))
        try validatePeer(peer, target: target)
        let reply = try session.mac.open(response, as: RoomDeliverySessionReply.self, reply: true, maximumBytes: 16_384)
        guard reply.recipient == target.identity, reply.sessionID == call.sessionID,
              reply.sequence == call.sequence, reply.attemptID == call.attemptID else { throw V2ActorAuthenticationError.wrongRecipient }
        return reply.result
        } catch {
            if let auth = error as? V2ActorAuthenticationError,
               auth == .sessionExpired || auth == .wrongRecipient, sessions[target]?.id == session.id {
                sessions.removeValue(forKey: target)
            }
            throw error
        }
    }
    // Every callback type shares these actual invocation counters. Admission
    // precedes handshake suspension; release belongs to the invocation's defer.
    func acquireCallback(to peer: V2GatewayRealtimeIdentity) throws {
        guard !stopped, active < limits.maximumConcurrentCalls,
              peerActive[peer, default: 0] < 2 else { throw V2ActorAuthenticationError.overloaded }
        active += 1; peerActive[peer, default: 0] += 1
    }
    func releaseCallback(to peer: V2GatewayRealtimeIdentity) {
        precondition(active > 0 && peerActive[peer, default: 0] > 0)
        active -= 1; peerActive[peer, default: 0] -= 1
        if peerActive[peer] == 0 { peerActive.removeValue(forKey: peer) }
    }
    private func acquireAuthorization(to peer: V2GatewayRealtimeIdentity) throws {
        guard !stopped, authorizationCalls < 8, authorizationPeers[peer, default: 0] < 2 else { throw V2ActorAuthenticationError.overloaded }
        authorizationCalls += 1; authorizationPeers[peer, default: 0] += 1
    }
    private func releaseAuthorization(to peer: V2GatewayRealtimeIdentity) {
        precondition(authorizationCalls > 0 && authorizationPeers[peer, default: 0] > 0)
        authorizationCalls -= 1; authorizationPeers[peer, default: 0] -= 1
        if authorizationPeers[peer] == 0 { authorizationPeers.removeValue(forKey: peer) }
    }
    private func session(for target: V2GatewayRealtimeDescriptor) async throws -> Session {
        if let cached = sessions[target], cached.expires > .now { return cached }
        if let opening = openings[target] { return try await opening.value }
        // A restarted stable node gets a new physical actor. Old in-flight calls
        // retain their captured session; retired cached generations must not
        // consume the whole 64-peer cache for five minutes.
        sessions = sessions.filter {
            $0.value.expires > .now && ($0.key.identity.nodeID != target.identity.nodeID || $0.key.identity == target.identity)
        }
        guard sessions.count + openings.count < limits.maximumPeers else { throw V2ActorAuthenticationError.overloaded }
        let system = self.system; let signer = self.signer; let trust = self.trust
        let limits = self.limits; let incarnation = self.incarnation
        let started = ContinuousClock.now
        let task = Task<Session, Error> {
            let id = try V2ActorProtobuf.decode(ClusterSystem.ActorID.self, from: target.endpointReference)
            guard id.node.endpoint.host == target.address, id.node.endpoint.port == target.port else { throw V2ActorAuthenticationError.wrongRecipient }
            let endpoint = try V2GatewayRealtimeEndpoint.resolve(id: id, using: system)
            let agreement = Curve25519.KeyAgreement.PrivateKey()
            let hello = RealtimeHello(serviceID: signer.serviceID, version: 1, callerIncarnation: incarnation, recipient: target.identity, handshakeID: UUID(),
                                      endpointDigest: Data(SHA256.hash(data: target.endpointReference)), agreementKey: agreement.publicKey.rawRepresentation)
            let packet = try signer.sign(hello, maximumBytes: 16_384)
            let response = try await RemoteCall.with(timeout: limits.callTimeout) { try await endpoint.openSession(packet) }
            let (grant, peer) = try trust.verify(response, as: RealtimeGrant.self, maximumBytes: 16_384)
            guard peer.serviceID.rawValue == target.identity.serviceID, peer.permissions.contains(.realtimeReceive),
                  peer.gatewayNodeIDs.contains(target.identity.nodeID) || peer.serviceID.rawValue == target.identity.nodeID,
                  grant.hello.serviceID == signer.serviceID, grant.hello.version == 1, grant.hello.callerIncarnation == incarnation,
                  grant.hello.recipient == target.identity, grant.hello.handshakeID == hello.handshakeID,
                  grant.hello.endpointDigest == hello.endpointDigest, grant.hello.agreementKey == hello.agreementKey,
                  (1...300_000).contains(grant.remainingMilliseconds) else { throw V2ActorAuthenticationError.wrongRecipient }
            let mac = try V2ActorSessionMAC(privateKey: agreement, peerKey: grant.agreementKey ?? Data(),
                transcript: V2ActorProtobuf.encode(hello), sessionID: grant.sessionID,
                client: signer.serviceID, server: peer.serviceID)
            return Session(endpoint: endpoint, id: grant.sessionID, mac: mac, expires: started + .milliseconds(grant.remainingMilliseconds), sequence: 0)
        }
        openings[target] = task
        do {
            let result = try await task.value
            openings.removeValue(forKey: target)
            guard !stopped else { throw V2ActorAuthenticationError.overloaded }
            if let installed = sessions[target], installed.id == result.id { return installed }
            sessions[target] = result
            return result
        } catch { openings.removeValue(forKey: target); throw error }
    }
    private func validatePeer(_ peer: V2ActorTrustedService, target: V2GatewayRealtimeDescriptor) throws {
        guard peer.serviceID.rawValue == target.identity.serviceID, peer.permissions.contains(.realtimeReceive),
              peer.gatewayNodeIDs.contains(target.identity.nodeID) || peer.serviceID.rawValue == target.identity.nodeID else { throw V2ActorAuthenticationError.wrongRecipient }
    }
    public func stop(deadline: ContinuousClock.Instant) async -> Bool {
        stopped = true
        while (active > 0 || authorizationCalls > 0 || sessionCalls > 0) && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
        }
        guard active == 0, authorizationCalls == 0, sessionCalls == 0 else { return false }
        sessions.removeAll(); openings.removeAll()
        return true
    }
}

/// Node ownership keeps the local distributed actor alive until actual calls drain.
public final class V2RealtimeTransportHandle: Sendable {
    public let descriptor: V2GatewayRealtimeDescriptor
    public let sender: V2RealtimeClusterSender
    private let endpoint: V2GatewayRealtimeEndpoint
    private let inbound: V2GatewayRealtimeInbound
    init(descriptor: V2GatewayRealtimeDescriptor, sender: V2RealtimeClusterSender,
         endpoint: V2GatewayRealtimeEndpoint, inbound: V2GatewayRealtimeInbound) {
        self.descriptor = descriptor; self.sender = sender; self.endpoint = endpoint; self.inbound = inbound
    }
    public func send(_ batch: V2RealtimeBatch, to target: V2GatewayRealtimeDescriptor) async throws -> V2RealtimeAcceptance {
        try await sender.send(batch, to: target)
    }
    public func sendDeliverySession(_ pulse: V2RoomDeliverySessionPulse, sourceShardID: String,
                                    to target: V2GatewayRealtimeDescriptor) async throws -> V2RoomDeliverySessionResult {
        try await sender.sendDeliverySession(pulse, sourceShardID: sourceShardID, to: target)
    }
    public func configureRoomSubscription(_ handler: any V2RoomSubscriptionHandler) async throws {
        try await inbound.configureRoomSubscription(handler)
    }
    public func sendRoomSubscriptionBatch(_ batch: V2RoomSubscriptionDeliveryBatch, sourceShardID: String,
                                          to target: V2GatewayRealtimeDescriptor) async throws -> V2RoomSubscriptionBatchResult {
        try await sender.sendRoomSubscriptionBatch(batch, sourceShardID: sourceShardID, to: target)
    }
    public func sendRoomSubscription(_ delivery: V2RoomSubscriptionDelivery, sourceShardID: String,
                                     to target: V2GatewayRealtimeDescriptor) async throws -> V2RoomSubscriptionDeliveryResult {
        try await sender.sendRoomSubscription(delivery, sourceShardID: sourceShardID, to: target)
    }
    public func configureJournalProjection(_ handler: any V2RealtimeJournalProjectionHandler) async throws {
        try await inbound.configureJournalProjection(handler)
    }
    public func sendJournalProjection(_ batch: V2RealtimeJournalProjectionBatch,
                                      to target: V2GatewayRealtimeDescriptor) async throws -> V2RealtimeJournalProjectionResult {
        try await sender.sendJournalProjection(batch, to: target)
    }
    public func stop(deadline: ContinuousClock.Instant) async -> Bool {
        await inbound.stop()
        return await sender.stop(deadline: deadline)
    }
}

func buildRealtimeTransport(system: ClusterSystem, identity: V2GatewayRealtimeIdentity,
                           address: String, port: Int, signer: V2ActorSigningIdentity,
                           trust: V2ActorTrustStore, ingress: any V2RealtimeIngress,
                           serviceOwnerAccess: [V2ActorServiceID: Set<String>],
                           limits: V2RealtimeTransportLimits) throws -> V2RealtimeTransportHandle {
    guard identity.serviceID == signer.serviceID.rawValue, !serviceOwnerAccess.isEmpty else { throw V2ActorAuthenticationError.invalidConfiguration }
    try trust.validateRealtimeReceiver(identity)
    let inbound = V2GatewayRealtimeInbound(identity: identity, signer: signer, trust: trust, ingress: ingress,
                                           serviceOwnerAccess: serviceOwnerAccess, limits: limits)
    let endpoint = V2GatewayRealtimeEndpoint(actorSystem: system, service: inbound)
    let descriptor = V2GatewayRealtimeDescriptor(identity: identity, endpointReference: try V2ActorProtobuf.encode(endpoint.id), address: address, port: port)
    try descriptor.validate()
    inbound.bindEndpointReference(descriptor.endpointReference)
    return V2RealtimeTransportHandle(descriptor: descriptor,
                                    sender: V2RealtimeClusterSender(system: system, signer: signer, trust: trust, limits: limits),
                                    endpoint: endpoint, inbound: inbound)
}

func validateRoomSubscriptionDelivery(_ delivery: V2RoomSubscriptionDelivery, sourceShardID: String,
                                      limits: V2RealtimeTransportLimits) throws {
    guard !sourceShardID.isEmpty, sourceShardID.utf8.count <= 128,
          sourceShardID == delivery.fence.activation.owner.shardID else { throw V2ActorAuthenticationError.invalidRequest }
    do { try delivery.validate(maximumPayloadBytes: limits.maximumPacketBytes) }
    catch { throw V2ActorAuthenticationError.invalidRequest }
}

func validateRoomSubscriptionReceipt(_ result: V2RoomSubscriptionDeliveryResult,
                                     delivery: V2RoomSubscriptionDelivery) throws {
    if case .appliedThrough(let sequence) = result, sequence != delivery.deliverySequence {
        throw V2ActorAuthenticationError.wrongRecipient
    }
}

func roomSubscriptionBatchFences(_ batch: V2RoomSubscriptionDeliveryBatch) -> [V2RoomSubscriptionFence] {
    var seen: Set<V2RoomSubscriptionFence> = []
    return batch.deliveries.compactMap { seen.insert($0.fence).inserted ? $0.fence : nil }
}

@discardableResult
func validateRoomSubscriptionBatch(_ batch: V2RoomSubscriptionDeliveryBatch, sourceShardID: String,
                                   limits: V2RealtimeTransportLimits) throws -> V2ValidatedRoomSubscriptionBatch {
    guard !sourceShardID.isEmpty, sourceShardID.utf8.count <= 128 else { throw V2ActorAuthenticationError.invalidRequest }
    let validated: V2ValidatedRoomSubscriptionBatch
    do { validated = try batch.validated(maximumItems: limits.maximumBatchItems, maximumBytes: limits.maximumPacketBytes) }
    catch { throw V2ActorAuthenticationError.invalidRequest }
    guard validated.rooms.allSatisfy({ $0.fence.activation.owner.shardID == sourceShardID }) else {
        throw V2ActorAuthenticationError.invalidRequest
    }
    return validated
}

func validateRoomSubscriptionBatchReceipt(_ result: V2RoomSubscriptionBatchResult,
                                          batch: V2RoomSubscriptionDeliveryBatch) throws {
    try validateRoomSubscriptionBatchReceipt(result, validated: batch.validated())
}

private func validateRoomSubscriptionBatchReceipt(_ result: V2RoomSubscriptionBatchResult,
                                                 validated: V2ValidatedRoomSubscriptionBatch) throws {
    guard validated.accepts(result) else { throw V2ActorAuthenticationError.wrongRecipient }
}
