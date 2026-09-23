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
    private var handshakeWaiters: [V2ActorHostIdentity: [UUID: HandshakeWaiter]] = [:]
    private var handshakeWaiterCount = 0
    private var descriptorGenerations: [V2ActorHostIdentity: UInt64] = [:]
    private var roomActors: [V2RoomActivationToken: V2RoomClusterActor] = [:]
    private var roomOrder: [V2RoomActivationToken] = []
    private var pinnedReservations: [V2RoomActivationToken: [UUID: ContinuousClock.Instant]] = [:]
    private var pendingReservationSlots: Set<UUID> = []
    private var uncertainReservationSlots: [UUID: ContinuousClock.Instant] = [:]
    private var dispatchedCalls: [UUID: DispatchedCall] = [:]
    private var activeExchanges = 0
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
            failHandshakeWaiters(host: old, reason: .staleActivation)
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
        for host in Array(handshakeWaiters.keys) {
            failHandshakeWaiters(host: host, reason: .retired)
        }
        finishStopIfIdle()
    }

    /// A timed-out caller stops waiting; its already dispatched RPC remains
    /// tracked until the native/remote invocation actually returns. An
    /// incomplete result keeps Cluster resources alive for a later stop retry.
    public func quiesce(deadline: ContinuousClock.Instant) async -> Bool {
        stop()
        while !isQuiescent && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { break }
        }
        if isQuiescent {
            clearStoppedState()
            return true
        }
        return false
    }

    private func clearStoppedState() {
        sessions.removeAll()
        roomActors.removeAll()
        roomOrder.removeAll()
        pinnedReservations.removeAll()
        pendingReservationSlots.removeAll()
        uncertainReservationSlots.removeAll()
    }

    private var isQuiescent: Bool {
        handshakes.isEmpty && dispatchedCalls.isEmpty && activeExchanges == 0 &&
            pendingReservationSlots.isEmpty
    }

    private func finishStopIfIdle() {
        if !accepting && isQuiescent { clearStoppedState() }
    }

    public func sessionCount() -> Int { sessions.count }
    public func handshakeWaiterSnapshot() -> Int { handshakeWaiterCount }
    public func physicalReferenceCount() -> Int { roomActors.count }
    public func dispatchedCallCount() -> Int { dispatchedCalls.count }
    func reservationSlotSnapshot() -> Int {
        pruneReservations()
        return pinnedReservations.values.reduce(0, { $0 + $1.count }) +
            pendingReservationSlots.count + uncertainReservationSlots.count
    }

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
        guard try await roomActor(for: token, deadline: deadline) != nil else {
            throw V2RoomCallFailure.notAccepted(.notReady)
        }
        pruneReservations()
        let used = pinnedReservations.values.reduce(0, { $0 + $1.count }) +
            pendingReservationSlots.count + uncertainReservationSlots.count
        guard used < configuration.maximumConcurrentReservations else {
            throw V2RoomCallFailure.notAccepted(.overloaded)
        }
        let slot = UUID()
        pendingReservationSlots.insert(slot)
        defer {
            pendingReservationSlots.remove(slot)
            finishStopIfIdle()
        }
        let response: V2ActorRPCResponse
        do {
            response = try await exchange(.reserve(token: token, requestID: requestID), on: token.host,
                                          principal: .service, deadline: deadline, roomToken: token)
        } catch {
            if (error as? V2RoomCallFailure) == .outcomeUnknown {
                uncertainReservationSlots[slot] = .now + configuration.reservationTimeout.duration
            }
            throw error
        }
        switch response {
        case .reserved(let grant) where grant.token == token && grant.requestID == requestID:
            pinnedReservations[token, default: [:]][grant.reservationID] =
                .now + configuration.reservationTimeout.duration
            return grant
        case .failure(let failure):
            if failure == .outcomeUnknown {
                uncertainReservationSlots[slot] = .now + configuration.reservationTimeout.duration
            }
            throw failure
        default:
            uncertainReservationSlots[slot] = .now + configuration.reservationTimeout.duration
            throw V2RoomCallFailure.outcomeUnknown
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
        guard activeExchanges < configuration.maximumActivationWaitersPerHost else {
            throw V2RoomCallFailure.notAccepted(.overloaded)
        }
        activeExchanges += 1
        defer {
            activeExchanges -= 1
            finishStopIfIdle()
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
            let timeout = boundedTimeout(deadline)
            if let roomToken {
                guard let actor = roomActors[roomToken] else {
                    throw V2RoomCallFailure.notAccepted(.notReady)
                }
                responsePacket = try await boundedDispatch(deadline: deadline, request: request) {
                    try await RemoteCall.with(timeout: timeout) { try await actor.exchange(packet) }
                }
            } else {
                let endpoint = try V2RoomHostEndpoint.resolve(id: descriptor.endpointID, using: system)
                responsePacket = try await boundedDispatch(deadline: deadline, request: request) {
                    try await RemoteCall.with(timeout: timeout) { try await endpoint.exchange(packet) }
                }
            }
        } catch let failure as V2RoomCallFailure { throw failure }
        catch {
            // Activation also writes the lease. Once either write-capable RPC
            // starts, network failure cannot prove it did not commit.
            throw transportFailure(for: request)
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
            throw transportFailure(for: request)
        }
    }

    private func transportFailure(for request: V2ActorRPCRequest) -> V2RoomCallFailure {
        if case .lookup = request { return .notAccepted(.unavailable) }
        return .outcomeUnknown
    }

    private func boundedDispatch(
        deadline: ContinuousClock.Instant, request: V2ActorRPCRequest,
        operation: @escaping @Sendable () async throws -> V2ActorSignedPacket
    ) async throws -> V2ActorSignedPacket {
        guard accepting, ContinuousClock.now < deadline else {
            throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
        }
        guard !Task.isCancelled else { throw V2RoomCallFailure.notAccepted(.cancelled) }
        guard handshakes.count + dispatchedCalls.count < configuration.maximumActivationWaitersPerHost else {
            throw V2RoomCallFailure.notAccepted(.overloaded)
        }
        let id = UUID()
        let failure = transportFailure(for: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled || ContinuousClock.now >= deadline {
                    continuation.resume(throwing: V2RoomCallFailure.notAccepted(
                        Task.isCancelled ? .cancelled : .deadlineExceeded
                    ))
                    return
                }
                let operationTask = Task { try await operation() }
                let timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) }
                    catch { return }
                    await self?.timeoutDispatch(id: id)
                }
                dispatchedCalls[id] = .init(continuation: continuation, timer: timer,
                                             timeoutFailure: failure)
                Task { [weak self] in
                    let result = await operationTask.result
                    await self?.completeDispatch(id: id, result: result)
                }
            }
        } onCancel: {
            Task { await self.timeoutDispatch(id: id) }
        }
    }

    private func timeoutDispatch(id: UUID) {
        guard var call = dispatchedCalls[id], let continuation = call.continuation else { return }
        call.continuation = nil
        dispatchedCalls[id] = call
        continuation.resume(throwing: call.timeoutFailure)
    }

    private func completeDispatch(id: UUID, result: Result<V2ActorSignedPacket, any Error>) {
        guard let call = dispatchedCalls.removeValue(forKey: id) else { return }
        call.timer.cancel()
        call.continuation?.resume(with: result)
        finishStopIfIdle()
    }

    private func session(for descriptor: V2RoomClusterHostDescriptor,
                         deadline: ContinuousClock.Instant) async throws -> Session {
        guard ContinuousClock.now < deadline else {
            throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
        }
        guard !Task.isCancelled else { throw V2RoomCallFailure.notAccepted(.cancelled) }
        let host = descriptor.identity
        sessions = sessions.filter { $0.value.expires > .now + .milliseconds(100) }
        if let current = sessions[host], current.expires > .now + .milliseconds(100) {
            return current
        }
        guard handshakeWaiterCount < configuration.maximumActivationWaitersPerHost else {
            throw V2RoomCallFailure.notAccepted(.overloaded)
        }
        let generation = descriptorGenerations[host, default: 0]
        let handshakeID: UUID
        if let currentID = handshakeIDs[host] {
            handshakeID = currentID
        } else {
            guard handshakes.count < limits.maximumSessions,
                  sessions.count < limits.maximumSessions else {
                throw V2RoomCallFailure.notAccepted(.overloaded)
            }
            handshakeID = UUID()
            let task = Task { [weak self] () throws -> Session in
                guard let self else { throw V2RoomCallFailure.notAccepted(.retired) }
                return try await self.openSession(descriptor, deadline: deadline)
            }
            handshakes[host] = task
            handshakeIDs[host] = handshakeID
            Task { [weak self] in
                let result = await task.result
                await self?.finishHandshake(host: host, id: handshakeID,
                                            generation: generation, result: result)
            }
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: V2RoomCallFailure.notAccepted(.cancelled))
                    return
                }
                let timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) }
                    catch { return }
                    await self?.removeHandshakeWaiter(host: host, id: handshakeID,
                                                      waiterID: waiterID, reason: .deadlineExceeded)
                }
                handshakeWaiters[host, default: [:]][waiterID] =
                    .init(continuation: continuation, timer: timer)
                handshakeWaiterCount += 1
            }
        } onCancel: {
            Task { await self.removeHandshakeWaiter(host: host, id: handshakeID,
                                                    waiterID: waiterID, reason: .cancelled) }
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
            guard !Task.isCancelled else { throw V2RoomCallFailure.notAccepted(.retired) }
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
        uncertainReservationSlots = uncertainReservationSlots.filter { $0.value > now }
        pinnedReservations = pinnedReservations.compactMapValues { reservations in
            let live = reservations.filter { $0.value > now }
            return live.isEmpty ? nil : live
        }
    }

    private func finishHandshake(host: V2ActorHostIdentity, id: UUID,
                                 generation: UInt64, result: Result<Session, any Error>) {
        guard handshakeIDs[host] == id else { return }
        handshakes.removeValue(forKey: host)
        handshakeIDs.removeValue(forKey: host)
        let waiters = handshakeWaiters.removeValue(forKey: host) ?? [:]
        handshakeWaiterCount -= waiters.count
        let delivered: Result<Session, any Error>
        if !accepting || descriptorGenerations[host] != generation {
            delivered = .failure(V2RoomCallFailure.notAccepted(.retired))
        } else {
            if case .success(let opened) = result { sessions[host] = opened }
            delivered = result
        }
        for waiter in waiters.values {
            waiter.timer.cancel()
            waiter.continuation.resume(with: delivered)
        }
        finishStopIfIdle()
    }

    private func removeHandshakeWaiter(host: V2ActorHostIdentity, id: UUID,
                                       waiterID: UUID, reason: V2RoomFailureReason) {
        guard handshakeIDs[host] == id,
              let waiter = handshakeWaiters[host]?.removeValue(forKey: waiterID) else { return }
        handshakeWaiterCount -= 1
        if handshakeWaiters[host]?.isEmpty == true { handshakeWaiters.removeValue(forKey: host) }
        waiter.timer.cancel()
        waiter.continuation.resume(throwing: V2RoomCallFailure.notAccepted(reason))
    }

    private func failHandshakeWaiters(host: V2ActorHostIdentity, reason: V2RoomFailureReason) {
        let waiters = handshakeWaiters.removeValue(forKey: host) ?? [:]
        handshakeWaiterCount -= waiters.count
        for waiter in waiters.values {
            waiter.timer.cancel()
            waiter.continuation.resume(throwing: V2RoomCallFailure.notAccepted(reason))
        }
    }

    private struct Session: Sendable {
        let grant: V2ActorSessionGrant
        let expires: ContinuousClock.Instant
        var nextSequence: UInt64
    }

    private struct HandshakeWaiter {
        let continuation: CheckedContinuation<Session, any Error>
        let timer: Task<Void, Never>
    }

    private struct DispatchedCall {
        var continuation: CheckedContinuation<V2ActorSignedPacket, any Error>?
        let timer: Task<Void, Never>
        let timeoutFailure: V2RoomCallFailure
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
