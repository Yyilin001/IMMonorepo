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

/// Non-Codable proof constructed only after signature, identity, role and replay
/// checks. Native and remote adapters must both pass through this boundary.
public struct V2ActorVerifiedCall: Sendable {
    public let call: V2ActorAuthenticatedCall
    public let deadline: ContinuousClock.Instant
}

/// Host-issued session nonces give replay protection without trusting remote
/// wall clocks or retaining every historical attempt. Once expired, a nonce is
/// no longer valid even after its replay window has been removed from memory.
public actor V2ActorSessionAuthenticator {
    private let host: V2ActorHostIdentity
    private let trust: V2ActorTrustStore
    private let limits: V2ActorAuthenticationLimits
    private let now: @Sendable () -> ContinuousClock.Instant
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
        guard hello.version == V2ActorSessionHello.protocolVersion else { throw V2ActorAuthenticationError.unsupportedVersion }
        guard hello.serviceID == peer.serviceID else { throw V2ActorAuthenticationError.forbidden }
        guard hello.recipient == host else { throw V2ActorAuthenticationError.wrongRecipient }
        guard !peer.permissions.isEmpty else { throw V2ActorAuthenticationError.forbidden }
        let instant = now()
        prune(at: instant)
        let key = HelloKey(serviceID: peer.serviceID, incarnation: hello.callerIncarnation, handshake: hello.handshakeID)
        if let id = helloSessions[key], let session = sessions[id] {
            return try grant(session, id: id, at: instant)
        }
        guard sessions.count < limits.maximumSessions,
              serviceCounts[peer.serviceID, default: 0] < limits.maximumSessionsPerService
        else { throw V2ActorAuthenticationError.overloaded }
        let id = UUID()
        let session = Session(key: key, expires: instant + limits.sessionLifetime.duration, window: limits.replayWindow)
        sessions[id] = session
        helloSessions[key] = id
        serviceCounts[peer.serviceID, default: 0] += 1
        nextExpiry = min(nextExpiry ?? session.expires, session.expires)
        return try grant(session, id: id, at: instant)
    }

    public func accept(_ packet: V2ActorSignedPacket) throws -> V2ActorVerifiedCall {
        let receivedAt = now()
        let (call, peer) = try trust.verify(packet, as: V2ActorAuthenticatedCall.self,
                                           maximumBytes: limits.maximumRequestBytes)
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
        return V2ActorVerifiedCall(call: call, deadline: receivedAt + call.remainingBudget.duration)
    }

    public func sessionCount() -> Int {
        prune(at: now())
        return sessions.count
    }

    private func authorize(_ call: V2ActorAuthenticatedCall, peer: V2ActorTrustedService) throws {
        switch call.request {
        case .activate, .lookup:
            guard call.principal == .service, !peer.permissions.isEmpty else { throw V2ActorAuthenticationError.forbidden }
        case .invoke(let token, let request):
            guard token.host == host, token.roomID == request.roomID else { throw V2ActorAuthenticationError.wrongRecipient }
            switch request {
            case .administration(.trustedSafety):
                guard call.principal == .service, peer.permissions.contains(.trustedSafety) else { throw V2ActorAuthenticationError.forbidden }
            case .specialAccountAudit:
                guard call.principal == .service, peer.permissions.contains(.specialAccountAudit) else { throw V2ActorAuthenticationError.forbidden }
            case .invitation(.create):
                // Secret issuance and the durable creation intent belong to
                // the control coordinator, never a direct room invocation.
                throw V2ActorAuthenticationError.forbidden
            case .invitation(.commitCreation), .invitation(.submitReserved),
                 .invitationQuery(.preflightCreation), .invitationQuery(.reservedSubmissionResponse):
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
                     remainingLifetime: try .init(milliseconds))
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
        let expires: ContinuousClock.Instant
        var highest: UInt64 = 0
        var slots: [(sequence: UInt64, attemptID: UUID)?]
        var attempts: [UUID: UInt64] = [:]

        init(key: HelloKey, expires: ContinuousClock.Instant, window: Int) {
            self.key = key
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
