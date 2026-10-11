import Crypto
import Synchronization
import Distributed
import DistributedCluster
import Foundation
import IMV2ActorContracts

enum ShardOperation: Codable, Sendable {
    case control(V2RealtimeShardControlRequest)
    case publish(V2RealtimeShardPublishRequest)
}
enum ShardResult: Codable, Sendable {
    case control(V2RealtimeShardControlReply)
    case publish(V2RealtimeShardPublishReply)
}
struct ShardCall: Codable, Sendable {
    let serviceID: V2ActorServiceID
    let version: Int
    let callerIncarnation: UUID
    let recipient: V2GatewayRealtimeIdentity
    let sessionID: UUID
    let sequence: UInt64
    let attemptID: UUID
    let operation: ShardOperation
}
struct ShardReply: Codable, Sendable {
    let recipient: V2GatewayRealtimeIdentity
    let sessionID: UUID
    let sequence: UInt64
    let attemptID: UUID
    let result: ShardResult
}

public distributed actor V2RealtimeShardEndpoint {
    public typealias ActorSystem = ClusterSystem
    private let service: V2RealtimeShardInbound
    init(actorSystem: ClusterSystem, service: V2RealtimeShardInbound) {
        self.actorSystem = actorSystem; self.service = service
    }
    public distributed func openSession(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        try await service.openSession(packet)
    }
    public distributed func exchange(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        try await service.exchange(packet)
    }
}

/// No SQL, client authorization, or socket waits occur on admission.
actor V2RealtimeShardInbound {
    let identity: V2GatewayRealtimeIdentity
    let signer: V2ActorSigningIdentity
    let trust: V2ActorTrustStore
    let serving: any V2RealtimeShardServing
    let limits: V2RealtimeTransportLimits
    let serviceOwnerAccess: [V2ActorServiceID: Set<String>]
    private let diagnostic: @Sendable (String) -> Void
    private nonisolated let endpointDigest = Mutex<Data?>(nil)
    private var sessions: [UUID: Session] = [:]
    private var accepting = true
    private var activeControl = 0
    private var activePublish = 0
    // Actor-confined reference state avoids copying the replay window on every RPC.
    private final class Session {
        let service: V2ActorServiceID
        let incarnation: UUID
        let handshake: UUID
        let expires: ContinuousClock.Instant
        var highest: UInt64 = 0
        var slots: [(sequence: UInt64, attemptID: UUID)?] = Array(repeating: nil, count: 1_024)
        var attempts: [UUID: UInt64] = [:]

        init(service: V2ActorServiceID, incarnation: UUID, handshake: UUID, expires: ContinuousClock.Instant) {
            self.service = service; self.incarnation = incarnation; self.handshake = handshake; self.expires = expires
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
         serving: any V2RealtimeShardServing, serviceOwnerAccess: [V2ActorServiceID: Set<String>],
         limits: V2RealtimeTransportLimits, diagnostic: @escaping @Sendable (String) -> Void = { _ in }) {
        self.diagnostic = diagnostic
        self.identity = identity; self.signer = signer; self.trust = trust; self.serving = serving
        self.serviceOwnerAccess = serviceOwnerAccess; self.limits = limits
    }
    nonisolated func bindEndpointReference(_ bytes: Data) {
        endpointDigest.withLock { digest in
            precondition(digest == nil)
            digest = Data(SHA256.hash(data: bytes))
        }
    }
    func stop(deadline: ContinuousClock.Instant) async -> Bool {
        accepting = false
        while activeControl + activePublish > 0 && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
        }
        guard activeControl + activePublish == 0 else { return false }
        sessions.removeAll(); return true
    }
    func openSession(_ packet: V2ActorSignedPacket) throws -> V2ActorSignedPacket {
        guard accepting else { throw V2ActorAuthenticationError.overloaded }
        let (hello, peer) = try trust.verify(packet, as: RealtimeHello.self, maximumBytes: 16_384)
        guard hello.serviceID == peer.serviceID else { throw V2ActorAuthenticationError.forbidden }
        guard hello.version == 1 else { diagnostic("hello_version"); throw V2ActorAuthenticationError.wrongRecipient }
        guard hello.recipient == identity else { diagnostic("hello_recipient"); throw V2ActorAuthenticationError.wrongRecipient }
        guard endpointDigest.withLock({ $0 == hello.endpointDigest }) else {
            diagnostic("hello_endpoint_digest"); throw V2ActorAuthenticationError.wrongRecipient
        }
        guard peer.permissions.contains(.realtimePublish), serviceOwnerAccess[peer.serviceID] != nil else {
            throw V2ActorAuthenticationError.forbidden
        }
        let now = ContinuousClock.now
        sessions = sessions.filter { $0.value.expires > now }
        let id: UUID
        if let existing = sessions.first(where: { $0.value.service == peer.serviceID && $0.value.incarnation == hello.callerIncarnation && $0.value.handshake == hello.handshakeID }) {
            id = existing.key
        } else {
            guard sessions.count < 256, sessions.values.filter({ $0.service == peer.serviceID }).count < 8 else { throw V2ActorAuthenticationError.overloaded }
            id = UUID()
            sessions[id] = Session(service: peer.serviceID, incarnation: hello.callerIncarnation, handshake: hello.handshakeID, expires: now + .seconds(300))
        }
        let duration = now.duration(to: sessions[id]!.expires).components
        let remaining = duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000
        return try signer.sign(RealtimeGrant(hello: hello, sessionID: id, remainingMilliseconds: remaining), maximumBytes: 16_384)
    }
    func exchange(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        guard accepting else { throw V2ActorAuthenticationError.overloaded }
        let (call, peer) = try trust.verify(packet, as: ShardCall.self, maximumBytes: limits.maximumPacketBytes)
        guard call.serviceID == peer.serviceID, peer.permissions.contains(.realtimePublish) else { throw V2ActorAuthenticationError.forbidden }
        guard call.version == 1, call.recipient == identity else { throw V2ActorAuthenticationError.wrongRecipient }
        guard let session = sessions[call.sessionID], session.expires > .now,
              session.service == peer.serviceID, session.incarnation == call.callerIncarnation else { throw V2ActorAuthenticationError.sessionExpired }
        let result: ShardResult
        switch call.operation {
        case .control(let request):
            guard request.token.host == identity, request.session.gateway.identity.serviceID == peer.serviceID.rawValue,
                  request.session.gateway.identity.incarnationID == call.callerIncarnation else { throw V2ActorAuthenticationError.wrongRecipient }
            try trust.validateRealtimeReceiver(request.session.gateway.identity)
            try request.session.gateway.validate()
            guard activeControl < 4 else { throw V2ActorAuthenticationError.overloaded }
            try session.accept(sequence: call.sequence, attemptID: call.attemptID)
            activeControl += 1
            defer { activeControl -= 1 }
            result = .control(try await serving.control(request))
        case .publish(let request):
            guard request.token.host == identity,
                  V2RealtimeTopicKey(request.topic).partitionID() == request.token.partitionID else { throw V2ActorAuthenticationError.wrongRecipient }
            guard serviceOwnerAccess[peer.serviceID]?.contains(request.topic.owner.shardID) == true else { throw V2ActorAuthenticationError.forbidden }
            do {
                try V2RealtimeBatch(recipient: identity, deliveries: [.init(topic: request.topic,
                    partitionID: request.token.partitionID, partitionEpoch: request.token.epoch, sessionID: request.token.leaseToken,
                    interestGeneration: 1, gatewayIncarnation: identity.incarnationID, payload: request.payload)]).validate(limits: limits)
            } catch { throw V2ActorAuthenticationError.invalidRequest }
            guard activePublish < 12 else { throw V2ActorAuthenticationError.overloaded }
            try session.accept(sequence: call.sequence, attemptID: call.attemptID)
            activePublish += 1
            defer { activePublish -= 1 }
            result = .publish(try await serving.publish(request))
        }
        return try signer.sign(ShardReply(recipient: identity, sessionID: call.sessionID,
            sequence: call.sequence, attemptID: call.attemptID, result: result), maximumBytes: 16_384)
    }
}

actor V2RealtimeShardSender {
    private let system: ClusterSystem
    private let signer: V2ActorSigningIdentity
    private let trust: V2ActorTrustStore
    private let limits: V2RealtimeTransportLimits
    private let incarnation: UUID
    private var stopped = false
    private var active = 0
    private var peerControlActive: [V2GatewayRealtimeIdentity: Int] = [:]
    private var peerPublishActive: [V2GatewayRealtimeIdentity: Int] = [:]
    private var sessions: [V2GatewayRealtimeDescriptor: Session] = [:]
    private var openings: [V2GatewayRealtimeDescriptor: Task<Session, Error>] = [:]
    private struct Session: Sendable {
        let endpoint: V2RealtimeShardEndpoint
        let id: UUID
        let expires: ContinuousClock.Instant
        var sequence: UInt64
    }
    init(system: ClusterSystem, signer: V2ActorSigningIdentity, trust: V2ActorTrustStore, limits: V2RealtimeTransportLimits, incarnation: UUID, initialReference: V2GatewayRealtimeDescriptor? = nil) throws {
        self.system = system; self.signer = signer; self.trust = trust; self.limits = limits; self.incarnation = incarnation
        if let initialReference {
            try initialReference.validate(); try trust.validateRealtimeReceiver(initialReference.identity)
            admissions[initialReference.identity.nodeID] = ReferenceAdmission(initialReference, observation: 0)
        }
    }
    private var controlStarted: UInt64 = 0, controlSettled: UInt64 = 0
    private var publishStarted: UInt64 = 0, publishSettled: UInt64 = 0
    private var capacityRejections: [V2RealtimeRPCAdmissionLane: [V2RealtimeRPCAdmissionRejection: UInt64]] = [:]
    private func reject(_ lane: V2RealtimeRPCAdmissionLane, _ reason: V2RealtimeRPCAdmissionRejection) {
        rejected &+= 1; capacityRejections[lane, default: [:]][reason, default: 0] &+= 1
    }
    private var rejected: UInt64 = 0
    func metrics() -> (UInt64, UInt64, Int, UInt64, UInt64, Int, UInt64, Int, [V2RealtimeRPCAdmissionLane: [V2RealtimeRPCAdmissionRejection: UInt64]]) {
        (controlStarted, controlSettled, activeControl, publishStarted, publishSettled, activePublish, rejected, openings.count, capacityRejections)
    }
    private final class ReferenceAdmission {
        let target: V2GatewayRealtimeDescriptor
        var suspended = false
        var observation: UInt64
        init(_ target: V2GatewayRealtimeDescriptor, observation: UInt64) { self.target = target; self.observation = observation }
    }
    // One current authenticated reference per roster node. Previous calls keep
    // their captured record; old descriptors cannot auto-register on first use.
    private var admissions: [String: ReferenceAdmission] = [:]
    func installAuthenticatedReference(_ target: V2GatewayRealtimeDescriptor, observation: UInt64 = 0) throws {
        guard !stopped else { throw V2ActorAuthenticationError.overloaded }
        try target.validate(); try trust.validateRealtimeReceiver(target.identity)
        if let current = admissions[target.identity.nodeID] {
            guard observation >= current.observation else { throw V2ActorAuthenticationError.sessionExpired }
            if current.target == target, !current.suspended { current.observation = observation; return }
        }
        guard admissions[target.identity.nodeID] != nil || admissions.count < limits.maximumPeers else { throw V2ActorAuthenticationError.overloaded }
        admissions[target.identity.nodeID] = ReferenceAdmission(target, observation: observation)
        sessions = sessions.filter { $0.key.identity.nodeID != target.identity.nodeID || $0.key == target }
    }
    /// Only this exact reference may suspend the current admission. Retiring an
    /// older incarnation must never overwrite its successor's soft gate.
    func beginRetirement(_ identity: V2GatewayRealtimeIdentity, reference: Data) -> Bool {
        if let current = admissions[identity.nodeID], current.target.identity == identity,
           current.target.endpointReference == reference { current.suspended = true }
        guard peerControlActive[identity, default: 0] == 0, peerPublishActive[identity, default: 0] == 0,
              !openings.keys.contains(where: { $0.identity == identity && $0.endpointReference == reference }) else { return false }
        sessions = sessions.filter { $0.key.identity != identity || $0.key.endpointReference != reference }
        return true
    }
    private func admits(_ record: ReferenceAdmission) -> Bool {
        !stopped && !record.suspended && admissions[record.target.identity.nodeID] === record
    }
    private var activeControl = 0
    private var activePublish = 0
    func exchange(_ operation: ShardOperation, to target: V2GatewayRealtimeDescriptor) async throws -> ShardResult {
        try Task.checkCancellation()
        try target.validate()
        try trust.validateRealtimeReceiver(target.identity)
        let isControl: Bool
        switch operation { case .control: isControl = true; case .publish: isControl = false }
        let lane: V2RealtimeRPCAdmissionLane = isControl ? .control : .publish
        guard !stopped else { reject(lane, .stopped); throw V2ActorAuthenticationError.overloaded }
        guard let admission = admissions[target.identity.nodeID], admission.target == target, admits(admission) else { throw V2ActorAuthenticationError.sessionExpired }
        // Each lane reserves peer progress independently. Each peer lane has
        // a ceiling of two; the global control4/publish12 ceilings remain fixed.
        // waiting publication replies cannot spend control's reserved permits.
        let peerCalls = isControl ? peerControlActive[target.identity, default: 0] : peerPublishActive[target.identity, default: 0]
        guard isControl ? activeControl < 4 : activePublish < 12 else {
            reject(lane, .global)
            if !isControl { throw V2RealtimeLocalAdmissionBackpressure.globalRPCs }
            throw V2ActorAuthenticationError.overloaded
        }
        guard peerCalls < 2 else {
            reject(lane, .peer)
            if !isControl { throw V2RealtimeLocalAdmissionBackpressure.peerRPCs }
            throw V2ActorAuthenticationError.overloaded
        }
        if isControl {
            activeControl += 1; controlStarted &+= 1
            peerControlActive[target.identity, default: 0] += 1
        } else {
            activePublish += 1; publishStarted &+= 1
            peerPublishActive[target.identity, default: 0] += 1
        }
        active += 1
        defer {
            active -= 1
            if isControl {
                activeControl -= 1; controlSettled &+= 1
                peerControlActive[target.identity, default: 1] -= 1
                if peerControlActive[target.identity] == 0 { peerControlActive.removeValue(forKey: target.identity) }
            } else {
                activePublish -= 1; publishSettled &+= 1
                peerPublishActive[target.identity, default: 1] -= 1
                if peerPublishActive[target.identity] == 0 { peerPublishActive.removeValue(forKey: target.identity) }
            }
        }
        // This owns the local invocation until its reply/timeout settles. A
        // RemoteCall timeout is NOT confirmation that the remote task stopped.
        var session = try await session(for: target, admission: admission)
        try Task.checkCancellation()
        guard admits(admission), session.expires > .now else { throw V2ActorAuthenticationError.sessionExpired }
        guard session.sequence < UInt64.max else { throw V2ActorAuthenticationError.sessionExpired }
        // Obtain the current counter after the handshake suspension; concurrent sends must not reuse it.
        session = sessions[target] ?? session
        guard session.sequence < UInt64.max else { throw V2ActorAuthenticationError.sessionExpired }
        session.sequence += 1; sessions[target] = session
        let call = ShardCall(serviceID: signer.serviceID, version: 1, callerIncarnation: incarnation, recipient: target.identity,
                                sessionID: session.id, sequence: session.sequence, attemptID: UUID(), operation: operation)
        let packet = try signer.sign(call, maximumBytes: limits.maximumPacketBytes)
        do {
            let endpoint = session.endpoint
            let response = try await RemoteCall.with(timeout: limits.callTimeout) { try await endpoint.exchange(packet) }
            let (reply, peer) = try trust.verify(response, as: ShardReply.self, maximumBytes: 16_384)
            try validatePeer(peer, target: target)
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
    private func session(for target: V2GatewayRealtimeDescriptor, admission: ReferenceAdmission) async throws -> Session {
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
            let endpoint = try V2RealtimeShardEndpoint.resolve(id: id, using: system)
            let hello = RealtimeHello(serviceID: signer.serviceID, version: 1, callerIncarnation: incarnation, recipient: target.identity, handshakeID: UUID(),
                                      endpointDigest: Data(SHA256.hash(data: target.endpointReference)))
            let packet = try signer.sign(hello, maximumBytes: 16_384)
            let response = try await RemoteCall.with(timeout: limits.callTimeout) { try await endpoint.openSession(packet) }
            let (grant, peer) = try trust.verify(response, as: RealtimeGrant.self, maximumBytes: 16_384)
            guard peer.serviceID.rawValue == target.identity.serviceID, peer.permissions.contains(.realtimeReceive),
                  peer.gatewayNodeIDs.contains(target.identity.nodeID) || peer.serviceID.rawValue == target.identity.nodeID,
                  grant.hello.serviceID == signer.serviceID, grant.hello.version == 1, grant.hello.callerIncarnation == incarnation,
                  grant.hello.recipient == target.identity, grant.hello.handshakeID == hello.handshakeID,
                  grant.hello.endpointDigest == hello.endpointDigest,
                  (1...300_000).contains(grant.remainingMilliseconds) else { throw V2ActorAuthenticationError.wrongRecipient }
            return Session(endpoint: endpoint, id: grant.sessionID, expires: started + .milliseconds(grant.remainingMilliseconds), sequence: 0)
        }
        openings[target] = task
        do {
            let result = try await task.value
            openings.removeValue(forKey: target)
            guard admits(admission) else { throw V2ActorAuthenticationError.sessionExpired }
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
        while active > 0 && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
        }
        guard active == 0 else { return false }
        sessions.removeAll(); openings.removeAll(); admissions.removeAll()
        return true
    }
}
