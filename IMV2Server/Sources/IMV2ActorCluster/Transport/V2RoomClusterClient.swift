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

/// 远程调用使用已签名的 Cluster 报文。节点创建的本地端口只有在完成
/// 相同的签名会话准入后，且本地端点和宿主实例仍精确匹配时，
/// 才可省略逐次调用签名。
public actor V2RoomClusterClient: V2RoomClientTransport, V2RoomHostDiscovering {
    private let system: ClusterSystem
    private let signer: V2ActorSigningIdentity
    private let trust: V2ActorTrustStore
    private let limits: V2ActorAuthenticationLimits
    private let configuration: V2RoomRuntimeConfiguration
    private let callerIncarnation: UUID
    private let localPort: V2RoomLocalPort?
    private var descriptors: [V2ActorHostIdentity: V2RoomClusterHostDescriptor] = [:]
    private var retiredDescriptors: [V2ActorHostIdentity: V2RoomClusterHostDescriptor] = [:]
    private var suspendedHosts: Set<V2ActorHostIdentity> = []
    private var activeExchangesByHost: [V2ActorHostIdentity: Int] = [:]
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
    private var pendingReservationHosts: [UUID: V2ActorHostIdentity] = [:]
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
        self.localPort = nil
    }

    init(system: ClusterSystem, signer: V2ActorSigningIdentity,
         trust: V2ActorTrustStore, limits: V2ActorAuthenticationLimits,
         configuration: V2RoomRuntimeConfiguration,
         callerIncarnation: UUID = UUID(), localPort: V2RoomLocalPort) {
        self.system = system
        self.signer = signer
        self.trust = trust
        self.limits = limits
        self.configuration = configuration
        self.callerIncarnation = callerIncarnation
        self.localPort = localPort
    }

    /// 重启会发布新的实例标识和 ActorID。已分发的调用及获准的预留
    /// 在结算前继续保留旧身份。
    public func register(_ descriptor: V2RoomClusterHostDescriptor) throws {
        try installDiscovered(descriptor)
        system.cluster.join(host: descriptor.address, port: descriptor.port)
    }

    public func installDiscovered(_ descriptor: V2RoomClusterHostDescriptor) throws {
        guard accepting else { throw V2RoomCallFailure.notAccepted(.retired) }
        pruneReservations()
        if let current = descriptors[descriptor.identity] {
            guard current.endpointID == descriptor.endpointID else {
                // 新的物理 ActorID 要求新的宿主实例标识。
                throw V2RoomCallFailure.notAccepted(.staleActivation)
            }
            descriptors[descriptor.identity] = descriptor
            if descriptor.isHealthy { suspendedHosts.remove(descriptor.identity) }
            return
        }
        let previous = descriptors.keys.filter { $0.hostID == descriptor.identity.hostID }
        guard descriptors.count - previous.count < limits.maximumSessions else {
            throw V2RoomCallFailure.notAccepted(.overloaded)
        }
        for old in previous {
            let oldDescriptor = descriptors.removeValue(forKey: old)
            suspendedHosts.remove(old)
            // 取消不一定会停止原生握手。在 finishHandshake 观察到实际结果前，
            // 将其 Task 保留在 `handshakes` 中。
            handshakes[old]?.cancel()
            failHandshakeWaiters(host: old, reason: .staleActivation)
            if let oldDescriptor, hasRetiredWork(old) {
                retiredDescriptors[old] = oldDescriptor
            }
            descriptorGenerations[old, default: 0] &+= 1
            pruneRetiredDescriptor(old)
        }
        descriptorGenerations[descriptor.identity, default: 0] &+= 1
        descriptors[descriptor.identity] = descriptor
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

    /// 调用方超时后停止等待；已分发的 RPC 仍被追踪，直到原生或远程调用实际返回。
    /// 结果未完成时保留 Cluster 资源，供之后重试停止操作。
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
        retiredDescriptors.removeAll()
        descriptors.removeAll()
        suspendedHosts.removeAll()
        roomActors.removeAll()
        roomOrder.removeAll()
        pinnedReservations.removeAll()
        pendingReservationSlots.removeAll()
        pendingReservationHosts.removeAll()
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
    public func retiredDescriptorCount() -> Int { retiredDescriptors.count }
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

    /// 供可重试 RoomRef.call 使用的只读提示。已认证调用仍会复查会话、
    /// 能力、重放窗口、绑定令牌和宿主激活；此方法不会分发 RPC。
    public func canInvokeCachedLocally(_ token: V2RoomActivationToken) async -> Bool {
        cachedLocalInvocation(for: token) != nil
    }

    private func cachedLocalInvocation(for token: V2RoomActivationToken)
        -> (port: V2RoomLocalPort, session: Session, capability: V2ActorLocalCapability)? {
        guard accepting, !suspendedHosts.contains(token.host),
              let descriptor = descriptors[token.host],
              descriptor.identity == token.host,
              descriptor.accessibleShardIDs.contains(token.owner.shardID),
              let port = localPort,
              port.identity == descriptor.identity,
              port.endpointID == descriptor.endpointID,
              let session = sessions[token.host],
              session.expires > .now + .milliseconds(100),
              session.grant.host == token.host,
              session.grant.serviceID == signer.serviceID,
              session.grant.callerIncarnation == callerIncarnation,
              let capability = session.localCapability,
              capability.generation == port.generation,
              capability.host == token.host,
              capability.sessionID == session.grant.sessionID,
              capability.serviceID == signer.serviceID,
              capability.callerIncarnation == callerIncarnation,
              roomActors[token] != nil
        else { return nil }
        return (port, session, capability)
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

    public func invokeCachedLocally(_ token: V2RoomActivationToken, request: V2RoomRequest,
                                    principal: V2RoomClientPrincipal,
                                    deadline: ContinuousClock.Instant) async throws -> V2RoomResponse {
        guard request.roomID == token.roomID else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        let response = try await exchange(.invoke(token: token, request: request), on: token.host,
                                          principal: principal.actorPrincipal, deadline: deadline,
                                          roomToken: token, requireCachedLocal: true)
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
        pendingReservationHosts[slot] = token.host
        defer {
            pendingReservationSlots.remove(slot)
            pendingReservationHosts.removeValue(forKey: slot)
            pruneRetiredDescriptor(token.host)
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
                          roomToken: V2RoomActivationToken?,
                          requireCachedLocal: Bool = false) async throws -> V2ActorRPCResponse {
        guard accepting, !suspendedHosts.contains(host),
              let descriptor = descriptors[host] ?? retiredDescriptor(for: request, host: host) else {
            throw V2RoomCallFailure.notAccepted(.unavailable)
        }
        guard activeExchanges < configuration.maximumActivationWaitersPerHost else {
            throw V2RoomCallFailure.notAccepted(.overloaded)
        }
        activeExchanges += 1
        activeExchangesByHost[host, default: 0] += 1
        defer {
            activeExchanges -= 1
            if activeExchangesByHost[host] == 1 {
                activeExchangesByHost.removeValue(forKey: host)
            } else {
                activeExchangesByHost[host, default: 1] -= 1
            }
            pruneRetiredDescriptor(host)
            finishStopIfIdle()
        }
        let generation = descriptorGenerations[host, default: 0]
        let localInvocation = requireCachedLocal ? roomToken.flatMap(cachedLocalInvocation(for:)) : nil
        if requireCachedLocal && localInvocation == nil {
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        // 若精确的本地能力已消失，提示调用不能开启远程握手，
        // 也不能回退为签名报文调用。
        let session: Session
        if let localInvocation { session = localInvocation.session }
        else { session = try await self.session(for: descriptor, deadline: deadline) }
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
        let isLocal = requireCachedLocal || (localPort.map { descriptor.identity == $0.identity &&
                                      descriptor.endpointID == $0.endpointID } == true &&
                      live.localCapability != nil)
        let remotePacket: V2ActorSignedPacket?
        if isLocal {
            remotePacket = nil
        } else {
            do { remotePacket = try signer.sign(call, maximumBytes: limits.maximumRequestBytes) }
            catch { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        }
        let transportReply: TransportReply
        do {
            let timeout = boundedTimeout(deadline)
            if requireCachedLocal {
                guard let roomToken else {
                    throw V2RoomCallFailure.notAccepted(.staleActivation)
                }
                let payload: V2ActorLocalPayload<V2ActorAuthenticatedCall>
                do { payload = try .init(call) }
                catch { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
                guard payload.byteCount > 0, payload.byteCount <= limits.maximumRequestBytes else {
                    throw V2RoomCallFailure.notAccepted(.invalidRequest)
                }
                transportReply = try await boundedDispatch(deadline: deadline, request: request,
                                                           host: host) { [self] in
                    try await dispatchCachedLocal(payload, token: roomToken,
                                                  sessionID: call.sessionID)
                }
            } else if let port = localPort, descriptor.identity == port.identity,
               descriptor.endpointID == port.endpointID,
               let capability = live.localCapability {
                if let roomToken, roomActors[roomToken] == nil {
                    throw V2RoomCallFailure.notAccepted(.notReady)
                }
                let payload: V2ActorLocalPayload<V2ActorAuthenticatedCall>
                do { payload = try .init(call) }
                catch { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
                guard payload.byteCount > 0, payload.byteCount <= limits.maximumRequestBytes else {
                    throw V2RoomCallFailure.notAccepted(.invalidRequest)
                }
                transportReply = try await boundedDispatch(deadline: deadline, request: request,
                                                           host: host) {
                    .local(try await port.inbound.exchangeLocal(payload, capability: capability,
                        generation: port.generation, boundToken: roomToken))
                }
            } else if let roomToken {
                guard let packet = remotePacket else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
                guard let actor = roomActors[roomToken] else {
                    throw V2RoomCallFailure.notAccepted(.notReady)
                }
                transportReply = try await boundedDispatch(deadline: deadline, request: request,
                                                           host: host) {
                    .signed(try await RemoteCall.with(timeout: timeout) { try await actor.exchange(packet) })
                }
            } else {
                guard let packet = remotePacket else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
                let endpoint = try V2RoomHostEndpoint.resolve(id: descriptor.endpointID, using: system)
                transportReply = try await boundedDispatch(deadline: deadline, request: request,
                                                           host: host) {
                    .signed(try await RemoteCall.with(timeout: timeout) { try await endpoint.exchange(packet) })
                }
            }
        } catch let failure as V2RoomCallFailure { throw failure }
        catch {
            // 激活也会写入租约。任一可写 RPC 开始后，
            // 网络故障都不能证明它没有提交。
            throw transportFailure(for: request)
        }
        do {
            let response: V2ActorRPCResponse
            switch transportReply {
            case .signed(let packet):
                response = try trust.verifyReply(packet, for: call,
                                                 maximumBytes: limits.maximumReplyBytes)
            case .local(let reply):
                guard let port = localPort else { throw V2ActorAuthenticationError.wrongRecipient }
                response = try trust.verifyLocalReply(reply, for: call, from: port.identity,
                                                      maximumBytes: limits.maximumReplyBytes)
            }
            // 节点替换不会使已分发调用的正确签名响应失效。
            // 旧令牌不能授权新激活，但调用方必须收到实际结果。
            return response
        }
        catch let failure as V2RoomCallFailure { throw failure }
        catch {
            throw transportFailure(for: request)
        }
    }

    private func dispatchCachedLocal(_ payload: V2ActorLocalPayload<V2ActorAuthenticatedCall>,
                                     token: V2RoomActivationToken,
                                     sessionID: UUID) async throws -> TransportReply {
        guard let current = cachedLocalInvocation(for: token),
              current.session.grant.sessionID == sessionID else {
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        return .local(try await current.port.inbound.exchangeLocal(payload,
            capability: current.capability, generation: current.port.generation,
            boundToken: token))
    }

    private func transportFailure(for request: V2ActorRPCRequest) -> V2RoomCallFailure {
        if case .lookup = request { return .notAccepted(.unavailable) }
        return .outcomeUnknown
    }

    private func boundedDispatch(
        deadline: ContinuousClock.Instant, request: V2ActorRPCRequest,
        host: V2ActorHostIdentity,
        operation: @escaping @Sendable () async throws -> TransportReply
    ) async throws -> TransportReply {
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
                let timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) }
                    catch { return }
                    await self?.timeoutDispatch(id: id)
                }
                dispatchedCalls[id] = .init(host: host, continuation: continuation, timer: timer,
                                             timeoutFailure: failure)
                // 物理调用在启动前就完成登记。唯一的任务负责结算，
                // 并在操作实际返回前持有此客户端，即使调用方已经退出。
                Task { [self] in
                    let result: Result<TransportReply, any Error>
                    do { result = .success(try await operation()) }
                    catch { result = .failure(error) }
                    completeDispatch(id: id, result: result)
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

    private func completeDispatch(id: UUID, result: Result<TransportReply, any Error>) {
        guard let call = dispatchedCalls.removeValue(forKey: id) else { return }
        call.timer.cancel()
        call.continuation?.resume(with: result)
        pruneRetiredDescriptor(call.host)
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
                let reply: V2ActorSignedPacket
                let capability: V2ActorLocalCapability?
                if let port = localPort, descriptor.identity == port.identity,
                   descriptor.endpointID == port.endpointID {
                    (reply, capability) = try await port.inbound.openLocalSession(
                        packet, generation: port.generation)
                } else {
                    let endpoint = try V2RoomHostEndpoint.resolve(id: descriptor.endpointID, using: system)
                    reply = try await RemoteCall.with(timeout: boundedTimeout(deadline)) {
                        try await endpoint.openSession(packet)
                    }
                    capability = nil
                }
                let grant = try trust.verifySessionGrant(reply, for: hello,
                                                         maximumBytes: limits.maximumReplyBytes)
                guard grant.remainingLifetime.rawValue > 100 else {
                    throw V2ActorAuthenticationError.sessionExpired
                }
                return Session(grant: grant,
                               expires: callStarted + grant.remainingLifetime.duration - .milliseconds(100),
                               nextSequence: 0, localCapability: capability)
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
        pruneRetiredDescriptor(grant.token.host)
    }

    private func pruneReservations() {
        let now = ContinuousClock.now
        uncertainReservationSlots = uncertainReservationSlots.filter { $0.value > now }
        pinnedReservations = pinnedReservations.compactMapValues { reservations in
            let live = reservations.filter { $0.value > now }
            return live.isEmpty ? nil : live
        }
        for host in Array(retiredDescriptors.keys) { pruneRetiredDescriptor(host) }
    }

    private func retiredDescriptor(for request: V2ActorRPCRequest,
                                   host: V2ActorHostIdentity) -> V2RoomClusterHostDescriptor? {
        guard let descriptor = retiredDescriptors[host] else { return nil }
        let token: V2RoomActivationToken
        switch request {
        case .invoke(let requested, _): token = requested
        case .markDispatched(let grant), .abortReservation(let grant),
             .finishReservation(let grant, _): token = grant.token
        default: return nil
        }
        guard pinnedReservations[token]?.isEmpty == false else { return nil }
        return descriptor
    }

    private func hasRetiredWork(_ host: V2ActorHostIdentity) -> Bool {
        activeExchangesByHost[host, default: 0] > 0 ||
        handshakes[host] != nil ||
        dispatchedCalls.values.contains(where: { $0.host == host }) ||
        pendingReservationHosts.values.contains(host) ||
        pinnedReservations.keys.contains(where: { $0.host == host })
    }

    /// 发现组件的所有者只有在旧 Cluster.Node 的原生或远程调用、
    /// 握手及预留授权均已结算后，才可将其标记为下线。
    public func retiredIdentityIsDrained(_ host: V2ActorHostIdentity) -> Bool {
        pruneReservations()
        return descriptors[host] == nil && !hasRetiredWork(host)
    }

    /// 原子地阻止新 RPC 与发现组件所有者对旧节点的精确退役竞速。
    /// 后续经认证的通告可以重新开放该节点。
    public func suspendUnreachableHost(_ host: V2ActorHostIdentity) -> Bool {
        pruneReservations()
        guard descriptors[host] != nil, !hasRetiredWork(host) else { return false }
        suspendedHosts.insert(host)
        return true
    }

    private func pruneRetiredDescriptor(_ host: V2ActorHostIdentity) {
        guard retiredDescriptors[host] != nil, !hasRetiredWork(host) else { return }
        retiredDescriptors.removeValue(forKey: host)
        suspendedHosts.remove(host)
        sessions.removeValue(forKey: host)
        descriptorGenerations.removeValue(forKey: host)
        for token in Array(roomActors.keys) where token.host == host {
            roomActors.removeValue(forKey: token)
        }
        roomOrder.removeAll { $0.host == host }
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
        pruneRetiredDescriptor(host)
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
        let localCapability: V2ActorLocalCapability?
    }

    private enum TransportReply: Sendable {
        case signed(V2ActorSignedPacket)
        case local(V2ActorLocalPayload<V2ActorAuthenticatedReply>)
    }

    private struct HandshakeWaiter {
        let continuation: CheckedContinuation<Session, any Error>
        let timer: Task<Void, Never>
    }

    private struct DispatchedCall {
        let host: V2ActorHostIdentity
        var continuation: CheckedContinuation<TransportReply, any Error>?
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
