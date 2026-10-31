import Crypto
import Foundation
import IMV2ActorContracts
import Synchronization

public struct V2ActorAuthenticationLimits: Sendable {
    public let maximumRequestBytes: Int
    public let maximumReplyBytes: Int
    public let maximumSessions: Int
    public let maximumSessionsPerService: Int
    public let replayWindow: Int
    public let sessionLifetime: V2ActorMilliseconds

    public init(maximumRequestBytes: Int = 1_048_576, maximumReplyBytes: Int = 8_388_608,
                maximumSessions: Int = 256, maximumSessionsPerService: Int = 8,
                replayWindow: Int = 1_024, sessionLifetimeMilliseconds: Int64 = 300_000) throws {
        guard (1...16_777_216).contains(maximumRequestBytes),
              (1...16_777_216).contains(maximumReplyBytes),
              (1...4_096).contains(maximumSessions),
              (1...maximumSessions).contains(maximumSessionsPerService),
              (1...8_192).contains(replayWindow)
        else { throw V2ActorAuthenticationError.invalidConfiguration }
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumReplyBytes = maximumReplyBytes
        self.maximumSessions = maximumSessions
        self.maximumSessionsPerService = maximumSessionsPerService
        self.replayWindow = replayWindow
        self.sessionLifetime = try .init(sessionLifetimeMilliseconds)
    }
}

/// 仅在报文认证、身份、角色与重放检查后创建的非 Codable 证明。
/// 原生与远程适配器都必须经过此边界。
public struct V2ActorVerifiedCall: Sendable {
    public let call: V2ActorAuthenticatedCall
    public let deadline: ContinuousClock.Instant
    // Diagnostic monotonic boundaries only; never used to grant authority.
    var sessionMAC: V2ActorSessionMAC? = nil
    var authenticationEnteredAt: ContinuousClock.Instant? = nil
    var authenticationReturnedAt: ContinuousClock.Instant? = nil
}

/// 宿主签发的进程内证明，对应远程会话使用的同一已签名握手消息。
/// 调用方不能序列化或构造它。
final class V2ActorLocalCapability: Sendable {
    let issuer: UUID
    let generation: UUID
    let sessionID: UUID
    let serviceID: V2ActorServiceID
    let callerIncarnation: UUID
    let host: V2ActorHostIdentity
    let peer: V2ActorTrustedService

    fileprivate init(issuer: UUID, generation: UUID, sessionID: UUID,
                     serviceID: V2ActorServiceID, callerIncarnation: UUID,
                     host: V2ActorHostIdentity, peer: V2ActorTrustedService) {
        self.issuer = issuer
        self.generation = generation
        self.sessionID = sessionID
        self.serviceID = serviceID
        self.callerIncarnation = callerIncarnation
        self.host = host
        self.peer = peer
    }
}

/// 宿主签发的会话随机数提供重放保护，无须信任远程墙上时钟，
/// 也无须保留每次历史尝试。随机数过期后即失效，
/// 即使其重放窗口已从内存移除也不会重新有效。
public final class V2ActorSessionAuthenticator: Sendable {
    private let host: V2ActorHostIdentity
    private let trust: V2ActorTrustStore
    private let limits: V2ActorAuthenticationLimits
    private let now: @Sendable () -> ContinuousClock.Instant
    private let localIssuer = UUID()
    private struct Catalog: Sendable {
        var sessions: [UUID: Session] = [:]
        var helloSessions: [HelloKey: UUID] = [:]
        var serviceCounts: [V2ActorServiceID: Int] = [:]
        var nextExpiry: ContinuousClock.Instant?

        mutating func prune(at instant: ContinuousClock.Instant) {
            guard let nextExpiry, nextExpiry <= instant else { return }
            for (id, session) in sessions where session.expires <= instant {
                sessions.removeValue(forKey: id)
                helloSessions.removeValue(forKey: session.key)
                let remaining = serviceCounts[session.key.serviceID, default: 1] - 1
                if remaining == 0 { serviceCounts.removeValue(forKey: session.key.serviceID) }
                else { serviceCounts[session.key.serviceID] = remaining }
            }
            self.nextExpiry = sessions.values.map(\.expires).min()
        }
    }
    private let catalog = Mutex(Catalog())

    public init(host: V2ActorHostIdentity, trust: V2ActorTrustStore,
                limits: V2ActorAuthenticationLimits,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.host = host
        self.trust = trust
        self.limits = limits
        self.now = now
    }

    package func authorizedSources(for serviceID: V2ActorServiceID, configured: Set<String>?) -> Set<String> {
        trust.authorizedSources(for: serviceID, configured: configured)
    }

    public func openSession(_ packet: V2ActorSignedPacket) throws -> V2ActorSessionGrant {
        let (hello, peer) = try trust.verify(packet, as: V2ActorSessionHello.self,
                                            maximumBytes: min(16_384, limits.maximumRequestBytes))
        return try openVerifiedSession(hello, peer: peer)
    }

    func openLocalSession(_ packet: V2ActorSignedPacket, generation: UUID) throws
        -> (V2ActorSessionGrant, V2ActorLocalCapability) {
        let (hello, peer) = try trust.verify(packet, as: V2ActorSessionHello.self,
                                            maximumBytes: min(16_384, limits.maximumRequestBytes))
        let grant = try openVerifiedSession(hello, peer: peer)
        return (grant, V2ActorLocalCapability(issuer: localIssuer, generation: generation,
            sessionID: grant.sessionID, serviceID: peer.serviceID,
            callerIncarnation: hello.callerIncarnation, host: host, peer: peer))
    }

    private func openVerifiedSession(_ hello: V2ActorSessionHello,
                                     peer: V2ActorTrustedService) throws -> V2ActorSessionGrant {
        guard hello.version == V2ActorSessionHello.protocolVersion else { throw V2ActorAuthenticationError.unsupportedVersion }
        guard hello.serviceID == peer.serviceID else { throw V2ActorAuthenticationError.forbidden }
        guard hello.recipient == host else { throw V2ActorAuthenticationError.wrongRecipient }
        guard !peer.permissions.isEmpty else { throw V2ActorAuthenticationError.forbidden }
        let instant = now()
        let key = HelloKey(serviceID: peer.serviceID, incarnation: hello.callerIncarnation, handshake: hello.handshakeID)
        let transcript = try V2ActorProtobuf.encode(hello)
        let helloDigest = Data(SHA256.hash(data: transcript))
        if let existing = try catalog.withLock({ value -> V2ActorSessionGrant? in
            value.prune(at: instant)
            if let id = value.helloSessions[key], let session = value.sessions[id] {
                guard session.helloDigest == helloDigest else { throw V2ActorAuthenticationError.invalidRequest }
                return try grant(session, id: id, at: instant)
            }
            guard value.sessions.count < limits.maximumSessions,
                  value.serviceCounts[peer.serviceID, default: 0] < limits.maximumSessionsPerService else {
                throw V2ActorAuthenticationError.overloaded
            }
            return nil
        }) { return existing }
        // Cryptography never holds the catalog or replay lock. A concurrent
        // hello may win; recheck its exact transcript and both quotas below.
        let id = UUID()
        let agreement = hello.agreementKey.map { _ in Curve25519.KeyAgreement.PrivateKey() }
        let mac = try agreement.map { try V2ActorSessionMAC(privateKey: $0, peerKey: hello.agreementKey!,
            transcript: transcript, sessionID: id, client: peer.serviceID,
            server: trust.configuredHostServiceID(for: host.hostID)) }
        let session = Session(key: key, helloDigest: helloDigest, agreementKey: agreement?.publicKey.rawRepresentation, mac: mac, expires: instant + limits.sessionLifetime.duration, window: limits.replayWindow)
        return try catalog.withLock { value in
            value.prune(at: instant)
            if let existingID = value.helloSessions[key], let existing = value.sessions[existingID] {
                guard existing.helloDigest == helloDigest else { throw V2ActorAuthenticationError.invalidRequest }
                return try grant(existing, id: existingID, at: instant)
            }
            guard value.sessions.count < limits.maximumSessions,
                  value.serviceCounts[peer.serviceID, default: 0] < limits.maximumSessionsPerService else {
                throw V2ActorAuthenticationError.overloaded
            }
            value.sessions[id] = session
            value.helloSessions[key] = id
            value.serviceCounts[peer.serviceID, default: 0] += 1
            value.nextExpiry = min(value.nextExpiry ?? session.expires, session.expires)
            return try grant(session, id: id, at: instant)
        }
    }

    /// A caller signs its exact issued grant to retire that session. Closing
    /// an old session is idempotent and cannot revoke a newer incarnation.
    public func closeSession(_ packet: V2ActorSignedPacket) throws {
        let (grant, peer) = try trust.verify(packet, as: V2ActorSessionGrant.self, maximumBytes: 16_384)
        guard grant.version == V2ActorSessionHello.protocolVersion, grant.host == host,
              grant.serviceID == peer.serviceID else { throw V2ActorAuthenticationError.forbidden }
        try catalog.withLock { value in
            guard let session = value.sessions[grant.sessionID] else { return }
            guard session.key.serviceID == peer.serviceID,
                  session.key.incarnation == grant.callerIncarnation,
                  session.key.handshake == grant.handshakeID else { throw V2ActorAuthenticationError.forbidden }
            value.sessions.removeValue(forKey: grant.sessionID)
            value.helloSessions.removeValue(forKey: session.key)
            let remaining = value.serviceCounts[peer.serviceID, default: 1] - 1
            if remaining == 0 { value.serviceCounts.removeValue(forKey: peer.serviceID) }
            else { value.serviceCounts[peer.serviceID] = remaining }
            value.nextExpiry = value.sessions.values.map(\.expires).min()
        }
    }

    public func accept(_ packet: V2ActorSignedPacket) throws -> V2ActorVerifiedCall {
        let enteredAt = ContinuousClock.now
        let receivedAt = now()
        let call: V2ActorAuthenticatedCall
        let peer: V2ActorTrustedService
        let session: Session?
        if packet.signature.count == 32 {
            let id = try V2ActorSessionMAC.packetSessionID(packet)
            session = catalog.withLock { $0.sessions[id] }
            guard let session, session.expires > receivedAt, let mac = session.mac else {
                throw V2ActorAuthenticationError.sessionExpired
            }
            call = try mac.open(packet, as: V2ActorAuthenticatedCall.self, reply: false, maximumBytes: limits.maximumRequestBytes)
            guard call.sessionID == id else { throw V2ActorAuthenticationError.wrongRecipient }
            peer = try trust.configuredService(packet.signerID)
        } else {
            (call, peer) = try trust.verify(packet, as: V2ActorAuthenticatedCall.self, maximumBytes: limits.maximumRequestBytes)
            session = catalog.withLock { $0.sessions[call.sessionID] }
            guard session?.mac == nil else { throw V2ActorAuthenticationError.invalidSignature }
        }
        var verified = try acceptVerified(call, peer: peer, session: session, receivedAt: receivedAt)
        verified.authenticationEnteredAt = enteredAt
        verified.authenticationReturnedAt = .now
        return verified
    }

    func acceptLocal(_ payload: V2ActorLocalPayload<V2ActorAuthenticatedCall>,
                     capability: V2ActorLocalCapability, generation: UUID) throws -> V2ActorVerifiedCall {
        let enteredAt = ContinuousClock.now
        let receivedAt = now()
        let call = payload.body
        guard capability.issuer == localIssuer, capability.generation == generation,
              capability.host == host, capability.sessionID == call.sessionID,
              capability.serviceID == call.serviceID,
              capability.callerIncarnation == call.callerIncarnation else {
            throw V2ActorAuthenticationError.wrongRecipient
        }
        guard payload.byteCount > 0, payload.byteCount <= limits.maximumRequestBytes else {
            throw V2ActorAuthenticationError.oversized
        }
        let session = catalog.withLock { $0.sessions[call.sessionID] }
        var verified = try acceptVerified(call, peer: capability.peer, session: session, receivedAt: receivedAt)
        verified.authenticationEnteredAt = enteredAt
        verified.authenticationReturnedAt = .now
        return verified
    }

    private func acceptVerified(_ call: V2ActorAuthenticatedCall, peer: V2ActorTrustedService, session: Session?,
                                receivedAt: ContinuousClock.Instant) throws -> V2ActorVerifiedCall {
        guard call.version == V2ActorSessionHello.protocolVersion else { throw V2ActorAuthenticationError.unsupportedVersion }
        guard call.serviceID == peer.serviceID else { throw V2ActorAuthenticationError.forbidden }
        guard call.recipient == host else { throw V2ActorAuthenticationError.wrongRecipient }
        guard let session, session.expires > receivedAt,
              session.key.serviceID == peer.serviceID,
              session.key.incarnation == call.callerIncarnation
        else { throw V2ActorAuthenticationError.sessionExpired }
        try authorize(call, peer: peer)
        try session.accept(sequence: call.sequence, attemptID: call.attemptID)
        return V2ActorVerifiedCall(call: call, deadline: receivedAt + call.remainingBudget.duration, sessionMAC: session.mac)
    }

    public func sessionCount() -> Int {
        let instant = now()
        return catalog.withLock { value in value.prune(at: instant); return value.sessions.count }
    }

    private func authorize(_ call: V2ActorAuthenticatedCall, peer: V2ActorTrustedService) throws {
        switch call.request {
        case .placementWrite(let request):
            guard call.principal == .service, peer.permissions.contains(.placementWrite), request.isBounded else {
                throw V2ActorAuthenticationError.forbidden
            }
        case .placementRead(let request):
            guard call.principal == .service, peer.permissions.contains(.placementRead), request.isBounded else {
                throw V2ActorAuthenticationError.forbidden
            }
        case .placementRaft(let request):
            guard call.principal == .service, peer.permissions.contains(.placementVote), request.isBounded else {
                throw V2ActorAuthenticationError.forbidden
            }
        case .drainPlacement(let request):
            guard call.principal == .service, peer.permissions.contains(.roomCoordination), request.isBounded else {
                throw V2ActorAuthenticationError.forbidden
            }
        case .forwardPair(let token, let pair):
            guard call.principal == .service, peer.permissions.contains(.roomCoordination) else {
                throw V2ActorAuthenticationError.forbidden
            }
            guard token.host == host, token.roomID == pair.targetRoomID else {
                throw V2ActorAuthenticationError.wrongRecipient
            }
            guard pair.actorUserID.uuidValue != nil, pair.operationID.uuidValue != nil,
                  pair.source.roomID.uuidValue != nil, pair.source.messageID.uuidValue != nil,
                  pair.targetRoomID.uuidValue != nil else { throw V2ActorAuthenticationError.invalidRequest }
        case .mutatePolicy:
            guard call.principal == .service, peer.permissions.contains(.policyMutation) else {
                throw V2ActorAuthenticationError.forbidden
            }
        case .updatePolicySnapshot(let request):
            guard call.principal == .service, peer.permissions.contains(.policyMutation),
                  peer.hostedIDs.contains(request.session.source.hostID),
                  request.session.recipient == call.recipient else { throw V2ActorAuthenticationError.forbidden }
        case .releasePolicyInterests(let request):
            guard call.principal == .service, peer.permissions.contains(.policyRegistration),
                  peer.hostedIDs.contains(request.subscriber.hostID), request.source == call.recipient else {
                throw V2ActorAuthenticationError.forbidden
            }
        case .policySnapshots(let request):
            guard call.principal == .service, peer.permissions.contains(.policyRegistration),
                  peer.hostedIDs.contains(request.subscriber.hostID) else { throw V2ActorAuthenticationError.forbidden }
        case .activate, .lookup:
            guard call.principal == .service, !peer.permissions.subtracting([.policyRegistration, .policyMutation]).isEmpty else {
                throw V2ActorAuthenticationError.forbidden
            }
        case .recoveryBatch(let items):
            guard call.principal == .service, peer.permissions.contains(.userRoomCalls),
                  peer.permissions.contains(.roomCoordination) else { throw V2ActorAuthenticationError.forbidden }
            guard !items.isEmpty, items.count <= 100 else { throw V2ActorAuthenticationError.invalidRequest }
            for item in items {
                guard item.token.host == host, item.token.roomID == item.query.roomID,
                      item.query.kind == .state,
                      item.query.roomID.uuidValue != nil,
                      item.query.actorUserID.uuidValue != nil else {
                    throw V2ActorAuthenticationError.invalidRequest
                }
            }
        case .invoke(let token, let request):
            guard token.host == host, token.roomID == request.roomID else { throw V2ActorAuthenticationError.wrongRecipient }
            switch request {
            case .mediaAuthorization(.profileVisibilityCohort(let cohort)):
                guard call.principal == .service, peer.permissions.contains(.userRoomCalls),
                      peer.permissions.contains(.roomCoordination) else { throw V2ActorAuthenticationError.forbidden }
                guard cohort.validatedTargetCount != nil else { throw V2ActorAuthenticationError.invalidRequest }
            case .roomSubscription(let command):
                guard call.principal == .user(command.actorUserID),
                      peer.permissions.contains(.userRoomCalls), peer.permissions.contains(.realtimeReceive),
                      command.gatewayDescriptor.identity.serviceID == peer.serviceID.rawValue,
                      command.gatewayDescriptor.identity.incarnationID == call.callerIncarnation,
                      peer.gatewayNodeIDs.contains(command.gatewayDescriptor.identity.nodeID)
                        || peer.serviceID.rawValue == command.gatewayDescriptor.identity.nodeID else {
                    throw V2ActorAuthenticationError.forbidden
                }
                if case .activate(let value) = command, value.fence.activation != token {
                    throw V2ActorAuthenticationError.wrongRecipient
                }

                if case .reset(let value) = command, value.expectedFence.activation != token {
                    throw V2ActorAuthenticationError.wrongRecipient
                }
                do { try command.validate() }
                catch { throw V2ActorAuthenticationError.invalidRequest }
            case .administration(.trustedSafety):
                guard call.principal == .service, peer.permissions.contains(.trustedSafety) else { throw V2ActorAuthenticationError.forbidden }
            case .forward(.sameOwnerPair):
                throw V2ActorAuthenticationError.forbidden
            case .forward:
                guard call.principal == .service, peer.permissions.contains(.roomCoordination) else { throw V2ActorAuthenticationError.forbidden }
            case .maintenance:
                guard call.principal == .service, peer.permissions.contains(.roomMaintenance) else { throw V2ActorAuthenticationError.forbidden }
            case .specialAccountAudit:
                guard call.principal == .service, peer.permissions.contains(.specialAccountAudit) else { throw V2ActorAuthenticationError.forbidden }
            case .invitationQuery(.preflightCreation), .invitationQuery(.reservedObservation), .invitationQuery(.reservedSubmissionResponse):
                guard call.principal == .service, peer.permissions.contains(.roomCoordination) else { throw V2ActorAuthenticationError.forbidden }
            default:
                guard let user = request.actorUserID, call.principal == .user(user),
                      peer.permissions.contains(.userRoomCalls) else { throw V2ActorAuthenticationError.forbidden }
            }
        case .reserve(let token, _):
            guard token.host == host, call.principal == .service,
                  peer.permissions.contains(.roomCoordination) else { throw V2ActorAuthenticationError.forbidden }
        case .markDispatched(let grant), .abortReservation(let grant), .finishReservation(let grant, _):
            guard grant.token.host == host, call.principal == .service,
                  peer.permissions.contains(.roomCoordination) else { throw V2ActorAuthenticationError.forbidden }
        }
        if case .lookup(let token) = call.request, token.host != host { throw V2ActorAuthenticationError.wrongRecipient }
    }

    private func grant(_ session: Session, id: UUID, at instant: ContinuousClock.Instant) throws -> V2ActorSessionGrant {
        let components = instant.duration(to: session.expires).components
        let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
        guard milliseconds > 0 else { throw V2ActorAuthenticationError.sessionExpired }
        return .init(version: V2ActorSessionHello.protocolVersion, host: host,
                     serviceID: session.key.serviceID, callerIncarnation: session.key.incarnation,
                     handshakeID: session.key.handshake, sessionID: id,
                     remainingLifetime: try .init(milliseconds), agreementKey: session.agreementKey)
    }

    private struct HelloKey: Hashable, Sendable {
        let serviceID: V2ActorServiceID
        let incarnation: UUID
        let handshake: UUID
    }

    private final class Session: Sendable {
        let key: HelloKey
        let helloDigest: Data
        let expires: ContinuousClock.Instant
        let agreementKey: Data?
        let mac: V2ActorSessionMAC?
        private struct Replay: Sendable {
            var highest: UInt64 = 0
            var slots: [(sequence: UInt64, attemptID: UUID)?]
            var attempts: [UUID: UInt64] = [:]
        }
        private let replay: Mutex<Replay>

        init(key: HelloKey, helloDigest: Data, agreementKey: Data?, mac: V2ActorSessionMAC?, expires: ContinuousClock.Instant, window: Int) {
            self.key = key
            self.helloDigest = helloDigest
            self.agreementKey = agreementKey; self.mac = mac
            self.expires = expires
            replay = Mutex(Replay(slots: Array(repeating: nil, count: window)))
        }

        func accept(sequence: UInt64, attemptID: UUID) throws {
            try replay.withLock { value in
                let window = UInt64(value.slots.count)
                let lowerBound = value.highest >= window ? value.highest - window + 1 : 1
                guard sequence > 0, sequence >= lowerBound else { throw V2ActorAuthenticationError.replay }
                if let previous = value.attempts[attemptID], previous >= lowerBound { throw V2ActorAuthenticationError.replay }
                let index = Int(sequence % window)
                if value.slots[index]?.sequence == sequence { throw V2ActorAuthenticationError.replay }
                if let old = value.slots[index], value.attempts[old.attemptID] == old.sequence {
                    value.attempts.removeValue(forKey: old.attemptID)
                }
                value.highest = max(value.highest, sequence)
                value.slots[index] = (sequence, attemptID)
                value.attempts[attemptID] = sequence
            }
        }
    }
}
