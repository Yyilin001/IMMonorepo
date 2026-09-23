import Distributed
import DistributedCluster
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core

public struct V2RoomClusterHostDescriptor: Sendable {
    public let identity: V2ActorHostIdentity
    public let endpointID: ClusterSystem.ActorID
    public let address: String
    public let port: Int
    public let accessibleShardIDs: Set<String>
    public let availableRooms: Int
    public let isHealthy: Bool

    public init(identity: V2ActorHostIdentity, endpointID: ClusterSystem.ActorID,
                address: String, port: Int, accessibleShardIDs: Set<String>,
                availableRooms: Int, isHealthy: Bool) throws {
        guard !address.isEmpty, (1...65_535).contains(port), !accessibleShardIDs.isEmpty,
              availableRooms >= 0 else { throw V2ActorAuthenticationError.invalidConfiguration }
        self.identity = identity
        self.endpointID = endpointID
        self.address = address
        self.port = port
        self.accessibleShardIDs = accessibleShardIDs
        self.availableRooms = availableRooms
        self.isHealthy = isHealthy
    }
}

/// Calls a real Cluster distributed actor for both same-process and remote
/// traffic. No native shortcut bypasses signed session admission.
public actor V2RoomClusterClient: V2RoomClientTransport, V2RoomHostDiscovering {
    private let system: ClusterSystem
    private let signer: V2ActorSigningIdentity
    private let trust: V2ActorTrustStore
    private let limits: V2ActorAuthenticationLimits
    private let configuration: V2RoomRuntimeConfiguration
    private let callerIncarnation: UUID
    private var descriptors: [V2ActorHostIdentity: V2RoomClusterHostDescriptor] = [:]
    private var sessions: [V2ActorHostIdentity: Session] = [:]
    private var handshakes: [V2ActorHostIdentity: Task<Session, any Error>] = [:]
    private var handshakeIDs: [V2ActorHostIdentity: UUID] = [:]
    private var descriptorGenerations: [V2ActorHostIdentity: UInt64] = [:]
    private var roomActors: [V2RoomActivationToken: V2RoomClusterActor] = [:]
    private var roomOrder: [V2RoomActivationToken] = []
    private var pinnedReservations: [V2RoomActivationToken: [UUID: ContinuousClock.Instant]] = [:]
    private var accepting = true

    public init(system: ClusterSystem, signer: V2ActorSigningIdentity,
                trust: V2ActorTrustStore, limits: V2ActorAuthenticationLimits,
                configuration: V2RoomRuntimeConfiguration,
                callerIncarnation: UUID = UUID()) {
        self.system = system
        self.signer = signer
        self.trust = trust
        self.limits = limits
        self.configuration = configuration
        self.callerIncarnation = callerIncarnation
    }

    /// A restart publishes a new incarnation and ActorID. Old sessions and
    /// physical refs are removed, then Cluster is explicitly joined again.
    public func register(_ descriptor: V2RoomClusterHostDescriptor) throws {
        let previous = descriptors.keys.filter { $0.hostID == descriptor.identity.hostID }
        guard descriptors.count - previous.count < limits.maximumSessions else {
            throw V2RoomCallFailure.notAccepted(.overloaded)
        }
        for old in previous {
            descriptors.removeValue(forKey: old)
            sessions.removeValue(forKey: old)
            handshakes.removeValue(forKey: old)?.cancel()
            handshakeIDs.removeValue(forKey: old)
            for token in roomActors.keys.filter({ $0.host == old }) {
                roomActors.removeValue(forKey: token)
                pinnedReservations.removeValue(forKey: token)
            }
            roomOrder.removeAll { $0.host == old }
            if old != descriptor.identity { descriptorGenerations.removeValue(forKey: old) }
        }
        descriptorGenerations[descriptor.identity, default: 0] &+= 1
        descriptors[descriptor.identity] = descriptor
        system.cluster.join(host: descriptor.address, port: descriptor.port)
    }

    public func candidates(for owner: V2RoomDataOwner) async throws -> [V2RoomHostCandidate] {
        guard accepting else { throw V2RoomCallFailure.notAccepted(.retired) }
        return descriptors.values.map {
            .init(identity: $0.identity, accessibleShardIDs: $0.accessibleShardIDs,
                  availableRooms: $0.availableRooms, isHealthy: $0.isHealthy)
        }
    }

    public func stop() {
        accepting = false
        for task in handshakes.values { task.cancel() }
        handshakes.removeAll()
        handshakeIDs.removeAll()
        sessions.removeAll()
        roomActors.removeAll()
        roomOrder.removeAll()
        pinnedReservations.removeAll()
    }

    public func sessionCount() -> Int { sessions.count }
    public func physicalReferenceCount() -> Int { roomActors.count }

    public func activate(on host: V2ActorHostIdentity, roomID: RoomID, owner: V2RoomDataOwner,
                         deadline: ContinuousClock.Instant) async throws -> V2RoomActivationResolution {
        let response = try await exchange(.activate(roomID: roomID, owner: owner), on: host,
                                          principal: .service, deadline: deadline, roomToken: nil)
        switch response {
        case .ready(let token, let physical):
            guard token.roomID == roomID, token.owner == owner, token.host == host else {
                throw V2RoomCallFailure.notAccepted(.staleActivation)
            }
            try rememberPhysical(physical, token: token)
            return .ready(token)
        case .occupied(let lease):
            guard lease.token.roomID == roomID, lease.token.owner == owner else {
                throw V2RoomCallFailure.notAccepted(.staleActivation)
            }
            return .occupied(lease)
        case .failure(let failure): throw failure
        default: throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
    }

    public func lookup(_ token: V2RoomActivationToken,
                       deadline: ContinuousClock.Instant) async throws -> Bool {
        let response = try await exchange(.lookup(token), on: token.host,
                                          principal: .service, deadline: deadline, roomToken: nil)
        switch response {
        case .ready(let observed, let physical):
            guard observed == token else { throw V2RoomCallFailure.notAccepted(.staleActivation) }
            try rememberPhysical(physical, token: token)
            return true
        case .failure(.notAccepted(.notReady)), .failure(.notAccepted(.staleActivation)),
             .failure(.notAccepted(.retired)):
            return false
        case .failure(let failure): throw failure
        default: throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
    }

    public func invoke(_ token: V2RoomActivationToken, request: V2RoomRequest,
                       principal: V2RoomClientPrincipal,
                       deadline: ContinuousClock.Instant) async throws -> V2RoomResponse {
        guard request.roomID == token.roomID else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        guard try await roomActor(for: token, deadline: deadline) != nil else {
            throw V2RoomCallFailure.notAccepted(.notReady)
        }
        let response = try await exchange(.invoke(token: token, request: request), on: token.host,
                                          principal: principal.actorPrincipal, deadline: deadline,
                                          roomToken: token)
        switch response {
        case .result(let result): return result
        case .failure(let failure): throw failure
        default: throw V2RoomCallFailure.outcomeUnknown
        }
    }

    public func reserve(_ token: V2RoomActivationToken, requestID: UUID,
                        deadline: ContinuousClock.Instant) async throws -> V2RoomReservation {
        pruneReservations()
        guard pinnedReservations.values.reduce(0, { $0 + $1.count }) < configuration.maximumConcurrentReservations else {
            throw V2RoomCallFailure.notAccepted(.overloaded)
        }
        guard try await roomActor(for: token, deadline: deadline) != nil else {
            throw V2RoomCallFailure.notAccepted(.notReady)
        }
        let response = try await exchange(.reserve(token: token, requestID: requestID), on: token.host,
                                          principal: .service, deadline: deadline, roomToken: token)
        switch response {
        case .reserved(let grant) where grant.token == token && grant.requestID == requestID:
            pinnedReservations[token, default: [:]][grant.reservationID] =
                .now + configuration.reservationTimeout.duration
            return grant
        case .failure(let failure): throw failure
        default: throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
    }

    public func markDispatched(_ grant: V2RoomReservation,
                               deadline: ContinuousClock.Instant) async throws {
        let response = try await exchange(.markDispatched(grant), on: grant.token.host,
                                          principal: .service, deadline: deadline,
                                          roomToken: grant.token)
        switch response {
        case .acknowledged: return
        case .failure(let failure): throw failure
        default: throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
    }

    public func abort(_ grant: V2RoomReservation, deadline: ContinuousClock.Instant) async -> Bool {
        guard let response = try? await exchange(.abortReservation(grant), on: grant.token.host,
                                                 principal: .service, deadline: deadline,
                                                 roomToken: grant.token) else { return false }
        if case .completed(let value) = response {
            if value { unpin(grant) }
            return value
        }
        return false
    }

    public func finish(_ grant: V2RoomReservation, completion: V2RoomReservationCompletion,
                       deadline: ContinuousClock.Instant) async -> Bool {
        guard let response = try? await exchange(.finishReservation(grant, completion), on: grant.token.host,
                                                 principal: .service, deadline: deadline,
                                                 roomToken: grant.token) else { return false }
        if case .completed(let value) = response {
            if value { unpin(grant) }
            return value
        }
        return false
    }

    private func roomActor(for token: V2RoomActivationToken,
                           deadline: ContinuousClock.Instant) async throws -> V2RoomClusterActor? {
        if let actor = roomActors[token] { return actor }
        guard try await lookup(token, deadline: deadline) else { return nil }
        return roomActors[token]
    }

    private func exchange(_ request: V2ActorRPCRequest, on host: V2ActorHostIdentity,
                          principal: V2ActorCallPrincipal, deadline: ContinuousClock.Instant,
                          roomToken: V2RoomActivationToken?) async throws -> V2ActorRPCResponse {
        guard accepting, let descriptor = descriptors[host] else {
            throw V2RoomCallFailure.notAccepted(.unavailable)
        }
        let generation = descriptorGenerations[host, default: 0]
        let session = try await session(for: descriptor, deadline: deadline)
        guard descriptorGenerations[host] == generation else {
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        guard var live = sessions[host], live.grant.sessionID == session.grant.sessionID,
              live.nextSequence < UInt64.max else {
            throw V2RoomCallFailure.notAccepted(.unavailable)
        }
        live.nextSequence += 1
        sessions[host] = live
        let budget = try remainingBudget(deadline)
        let call = V2ActorAuthenticatedCall(
            serviceID: signer.serviceID, callerIncarnation: callerIncarnation,
            recipient: host, sessionID: live.grant.sessionID, sequence: live.nextSequence,
            attemptID: UUID(), traceID: UUID(), remainingBudget: budget,
            principal: principal, request: request
        )
        let packet: V2ActorSignedPacket
        do { packet = try signer.sign(call, maximumBytes: limits.maximumRequestBytes) }
        catch { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        let responsePacket: V2ActorSignedPacket
        do {
            if let roomToken {
                guard let actor = roomActors[roomToken] else {
                    throw V2RoomCallFailure.notAccepted(.notReady)
                }
                responsePacket = try await RemoteCall.with(timeout: boundedTimeout(deadline)) {
                    try await actor.exchange(packet)
                }
            } else {
                let endpoint = try V2RoomHostEndpoint.resolve(id: descriptor.endpointID, using: system)
                responsePacket = try await RemoteCall.with(timeout: boundedTimeout(deadline)) {
                    try await endpoint.exchange(packet)
                }
            }
        } catch let failure as V2RoomCallFailure { throw failure }
        catch {
            // Once a room exchange starts, the network cannot prove rollback.
            throw roomToken == nil ? V2RoomCallFailure.notAccepted(.unavailable) : .outcomeUnknown
        }
        do {
            let response = try trust.verifyReply(responsePacket, for: call,
                                                 maximumBytes: limits.maximumReplyBytes)
            guard accepting, descriptorGenerations[host] == generation else {
                throw V2RoomCallFailure.outcomeUnknown
            }
            return response
        }
        catch let failure as V2RoomCallFailure { throw failure }
        catch {
            throw roomToken == nil ? V2RoomCallFailure.notAccepted(.unavailable) : .outcomeUnknown
        }
    }

    private func session(for descriptor: V2RoomClusterHostDescriptor,
                         deadline: ContinuousClock.Instant) async throws -> Session {
        let host = descriptor.identity
        sessions = sessions.filter { $0.value.expires > .now + .milliseconds(100) }
        if let current = sessions[host], current.expires > .now + .milliseconds(100) {
            return current
        }
        let generation = descriptorGenerations[host, default: 0]
        let task: Task<Session, any Error>
        let handshakeID: UUID
        if let current = handshakes[host], let currentID = handshakeIDs[host] {
            task = current
            handshakeID = currentID
        } else {
            guard handshakes.count < limits.maximumSessions,
                  sessions.count < limits.maximumSessions else {
                throw V2RoomCallFailure.notAccepted(.overloaded)
            }
            handshakeID = UUID()
            task = Task { [weak self] () throws -> Session in
                guard let self else { throw V2RoomCallFailure.notAccepted(.retired) }
                return try await self.openSession(descriptor, deadline: deadline)
            }
            handshakes[host] = task
            handshakeIDs[host] = handshakeID
        }
        do {
            let opened = try await task.value
            guard accepting, descriptorGenerations[host] == generation else {
                throw V2RoomCallFailure.notAccepted(.retired)
            }
            if let live = sessions[host], live.grant.sessionID == opened.grant.sessionID {
                clearHandshake(host: host, id: handshakeID)
                return live
            }
            sessions[host] = opened
            clearHandshake(host: host, id: handshakeID)
            return opened
        } catch {
            clearHandshake(host: host, id: handshakeID)
            throw error
        }
    }

    private func openSession(_ descriptor: V2RoomClusterHostDescriptor,
                             deadline: ContinuousClock.Instant) async throws -> Session {
        let hello = V2ActorSessionHello(
            serviceID: signer.serviceID, callerIncarnation: callerIncarnation,
            recipient: descriptor.identity, handshakeID: UUID()
        )
        let packet = try signer.sign(hello, maximumBytes: min(16_384, limits.maximumRequestBytes))
        var last: (any Error)?
        for attempt in 0..<configuration.maximumResolveAttempts {
            guard ContinuousClock.now < deadline else { break }
            let callStarted = ContinuousClock.now
            do {
                let endpoint = try V2RoomHostEndpoint.resolve(id: descriptor.endpointID, using: system)
                let reply = try await RemoteCall.with(timeout: boundedTimeout(deadline)) {
                    try await endpoint.openSession(packet)
                }
                let grant = try trust.verifySessionGrant(reply, for: hello,
                                                         maximumBytes: limits.maximumReplyBytes)
                guard grant.remainingLifetime.rawValue > 100 else {
                    throw V2ActorAuthenticationError.sessionExpired
                }
                return Session(grant: grant,
                               expires: callStarted + grant.remainingLifetime.duration - .milliseconds(100),
                               nextSequence: 0)
            } catch {
                last = error
                if attempt + 1 < configuration.maximumResolveAttempts {
                    try? await Task.sleep(for: min(.milliseconds(50),
                                                   max(.zero, ContinuousClock.now.duration(to: deadline))))
                }
            }
        }
        throw last ?? V2RoomCallFailure.notAccepted(.unavailable)
    }

    private func remainingBudget(_ deadline: ContinuousClock.Instant) throws -> V2ActorMilliseconds {
        let remaining = ContinuousClock.now.duration(to: deadline)
        let components = remaining.components
        let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
        guard milliseconds > 0 else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        return try .init(min(milliseconds, configuration.callTimeout.rawValue))
    }

    private func boundedTimeout(_ deadline: ContinuousClock.Instant) -> Duration {
        max(.milliseconds(1), min(ContinuousClock.now.duration(to: deadline), configuration.callTimeout.duration))
    }

    private func rememberPhysical(_ bytes: Data, token: V2RoomActivationToken) throws {
        pruneReservations()
        guard !bytes.isEmpty, bytes.count <= 16_384 else { throw V2ActorAuthenticationError.oversized }
        let id = try JSONDecoder().decode(ClusterSystem.ActorID.self, from: bytes)
        let actor = try V2RoomClusterActor.resolve(id: id, using: system)
        if roomActors[token] == nil && roomActors.count >= configuration.maximumCachedLocations {
            guard let evicted = roomOrder.first(where: { pinnedReservations[$0]?.isEmpty != false }) else {
                throw V2RoomCallFailure.notAccepted(.overloaded)
            }
            roomActors.removeValue(forKey: evicted)
            roomOrder.removeAll { $0 == evicted }
        }
        roomActors[token] = actor
        roomOrder.removeAll { $0 == token }
        roomOrder.append(token)
    }

    private func unpin(_ grant: V2RoomReservation) {
        pinnedReservations[grant.token]?.removeValue(forKey: grant.reservationID)
        if pinnedReservations[grant.token]?.isEmpty == true {
            pinnedReservations.removeValue(forKey: grant.token)
        }
    }

    private func pruneReservations() {
        let now = ContinuousClock.now
        pinnedReservations = pinnedReservations.compactMapValues { reservations in
            let live = reservations.filter { $0.value > now }
            return live.isEmpty ? nil : live
        }
    }

    private func clearHandshake(host: V2ActorHostIdentity, id: UUID) {
        guard handshakeIDs[host] == id else { return }
        handshakes.removeValue(forKey: host)
        handshakeIDs.removeValue(forKey: host)
    }

    private struct Session: Sendable {
        let grant: V2ActorSessionGrant
        let expires: ContinuousClock.Instant
        var nextSequence: UInt64
    }
}

private extension V2RoomClientPrincipal {
    var actorPrincipal: V2ActorCallPrincipal {
        switch self {
        case .user(let id): .user(id)
        case .service: .service
        }
    }
}
