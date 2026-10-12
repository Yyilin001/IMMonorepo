import Crypto
import Foundation
import IMV2ActorContracts

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
public actor V2ActorSessionAuthenticator {
    private let host: V2ActorHostIdentity
    private let trust: V2ActorTrustStore
    private let limits: V2ActorAuthenticationLimits
    private let now: @Sendable () -> ContinuousClock.Instant
    private let localIssuer = UUID()
    private var sessions: [UUID: Session] = [:]
    private var helloSessions: [HelloKey: UUID] = [:]
    private var serviceCounts: [V2ActorServiceID: Int] = [:]
    private var nextExpiry: ContinuousClock.Instant?

    public init(host: V2ActorHostIdentity, trust: V2ActorTrustStore,
                limits: V2ActorAuthenticationLimits,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.host = host
        self.trust = trust
        self.limits = limits
        self.now = now
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
        prune(at: instant)
        let key = HelloKey(serviceID: peer.serviceID, incarnation: hello.callerIncarnation, handshake: hello.handshakeID)
        let transcript = try V2ActorProtobuf.encode(hello)
        let helloDigest = Data(SHA256.hash(data: transcript))
        if let id = helloSessions[key], let session = sessions[id] {
            guard session.helloDigest == helloDigest else { throw V2ActorAuthenticationError.invalidRequest }
            return try grant(session, id: id, at: instant)
        }
        guard sessions.count < limits.maximumSessions,
              serviceCounts[peer.serviceID, default: 0] < limits.maximumSessionsPerService
        else { throw V2ActorAuthenticationError.overloaded }
        let id = UUID()
        let agreement = hello.agreementKey.map { _ in Curve25519.KeyAgreement.PrivateKey() }
        let mac = try agreement.map { try V2ActorSessionMAC(privateKey: $0, peerKey: hello.agreementKey!,
            transcript: transcript, sessionID: id, client: peer.serviceID,
            server: trust.configuredHostServiceID(for: host.hostID)) }
        let session = Session(key: key, helloDigest: helloDigest, agreementKey: agreement?.publicKey.rawRepresentation, mac: mac, expires: instant + limits.sessionLifetime.duration, window: limits.replayWindow)
        sessions[id] = session
        helloSessions[key] = id
        serviceCounts[peer.serviceID, default: 0] += 1
        nextExpiry = min(nextExpiry ?? session.expires, session.expires)
        return try grant(session, id: id, at: instant)
    }

    public func accept(_ packet: V2ActorSignedPacket) throws -> V2ActorVerifiedCall {
        let enteredAt = ContinuousClock.now
        let receivedAt = now()
        let call: V2ActorAuthenticatedCall
        let peer: V2ActorTrustedService
        if packet.signature.count == 32 {
            let id = try V2ActorSessionMAC.packetSessionID(packet)
            guard let session = sessions[id], session.expires > receivedAt, let mac = session.mac else {
                throw V2ActorAuthenticationError.sessionExpired
            }
            call = try mac.open(packet, as: V2ActorAuthenticatedCall.self, reply: false, maximumBytes: limits.maximumRequestBytes)
            guard call.sessionID == id else { throw V2ActorAuthenticationError.wrongRecipient }
            peer = try trust.configuredService(packet.signerID)
        } else {
            (call, peer) = try trust.verify(packet, as: V2ActorAuthenticatedCall.self, maximumBytes: limits.maximumRequestBytes)
            guard sessions[call.sessionID]?.mac == nil else { throw V2ActorAuthenticationError.invalidSignature }
        }
        var verified = try acceptVerified(call, peer: peer, receivedAt: receivedAt)
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
        var verified = try acceptVerified(call, peer: capability.peer, receivedAt: receivedAt)
        verified.authenticationEnteredAt = enteredAt
        verified.authenticationReturnedAt = .now
        return verified
    }

    private func acceptVerified(_ call: V2ActorAuthenticatedCall, peer: V2ActorTrustedService,
                                receivedAt: ContinuousClock.Instant) throws -> V2ActorVerifiedCall {
        guard call.version == V2ActorSessionHello.protocolVersion else { throw V2ActorAuthenticationError.unsupportedVersion }
        guard call.serviceID == peer.serviceID else { throw V2ActorAuthenticationError.forbidden }
        guard call.recipient == host else { throw V2ActorAuthenticationError.wrongRecipient }
        prune(at: receivedAt)
        guard let session = sessions[call.sessionID], session.expires > receivedAt,
              session.key.serviceID == peer.serviceID,
              session.key.incarnation == call.callerIncarnation
        else { throw V2ActorAuthenticationError.sessionExpired }
        try authorize(call, peer: peer)
        try session.accept(sequence: call.sequence, attemptID: call.attemptID)
        return V2ActorVerifiedCall(call: call, deadline: receivedAt + call.remainingBudget.duration, sessionMAC: session.mac)
    }

    public func sessionCount() -> Int {
        prune(at: now())
        return sessions.count
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
        case .mutatePolicy, .updatePolicySnapshot:
            guard call.principal == .service, peer.permissions.contains(.policyMutation) else {
                throw V2ActorAuthenticationError.forbidden
            }
        case .policySnapshots(let request):
            guard call.principal == .service, peer.permissions.contains(.policyRegistration),
                  peer.hostedIDs.contains(request.subscriber.hostID) else { throw V2ActorAuthenticationError.forbidden }
        case .activate, .lookup:
            guard call.principal == .service, !peer.permissions.subtracting([.policyRegistration, .policyMutation]).isEmpty else {
                throw V2ActorAuthenticationError.forbidden
            }
        case .subscriptionRenewBatch(let items):
            guard call.principal == .service, peer.permissions.contains(.userRoomCalls),
                  peer.permissions.contains(.realtimeReceive), !items.isEmpty, items.count <= 64,
                  Set(items.map { $0.token.roomID }).count == items.count else {
                throw V2ActorAuthenticationError.forbidden
            }
            for item in items {
                let command = item.command
                guard item.token.host == host, item.token.roomID == command.roomID,
                      command.expectedFence.activation == item.token else { throw V2ActorAuthenticationError.wrongRecipient }
                guard command.gatewayDescriptor.identity.serviceID == peer.serviceID.rawValue,
                      command.gatewayDescriptor.identity.incarnationID == call.callerIncarnation,
                      peer.gatewayNodeIDs.contains(command.gatewayDescriptor.identity.nodeID)
                        || peer.serviceID.rawValue == command.gatewayDescriptor.identity.nodeID else {
                    throw V2ActorAuthenticationError.forbidden
                }
                do { try V2RoomSubscriptionCommand.renew(command).validate() }
                catch { throw V2ActorAuthenticationError.invalidRequest }
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
                if case .renew(let value) = command, value.expectedFence.activation != token {
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

    private func prune(at instant: ContinuousClock.Instant) {
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

    private struct HelloKey: Hashable {
        let serviceID: V2ActorServiceID
        let incarnation: UUID
        let handshake: UUID
    }

    private final class Session {
        let key: HelloKey
        let helloDigest: Data
        let expires: ContinuousClock.Instant
        let agreementKey: Data?
        let mac: V2ActorSessionMAC?
        var highest: UInt64 = 0
        var slots: [(sequence: UInt64, attemptID: UUID)?]
        var attempts: [UUID: UInt64] = [:]

        init(key: HelloKey, helloDigest: Data, agreementKey: Data?, mac: V2ActorSessionMAC?, expires: ContinuousClock.Instant, window: Int) {
            self.key = key
            self.helloDigest = helloDigest
            self.agreementKey = agreementKey; self.mac = mac
            self.expires = expires
            self.slots = Array(repeating: nil, count: window)
        }

        func accept(sequence: UInt64, attemptID: UUID) throws {
            let window = UInt64(slots.count)
            let lowerBound = highest >= window ? highest - window + 1 : 1
            guard sequence > 0, sequence >= lowerBound else { throw V2ActorAuthenticationError.replay }
            if let previous = attempts[attemptID], previous >= lowerBound { throw V2ActorAuthenticationError.replay }
            let index = Int(sequence % window)
            if slots[index]?.sequence == sequence { throw V2ActorAuthenticationError.replay }
            if let old = slots[index], attempts[old.attemptID] == old.sequence {
                attempts.removeValue(forKey: old.attemptID)
            }
            highest = max(highest, sequence)
            slots[index] = (sequence, attemptID)
            attempts[attemptID] = sequence
        }
    }
}
