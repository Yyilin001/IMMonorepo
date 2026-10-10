import Distributed
import DistributedCluster
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
import Synchronization

actor V2RoomClusterPeer: V2RoomClientTransport, V2RoomHostDiscovering {
    package func forwardPair(_ pair: V2ActorForwardPairWire, token: V2RoomActivationToken,
        deadline: ContinuousClock.Instant) async throws -> V2ActorForwardMessageResultWire {
        let response = try await exchange(.forwardPair(token: token, pair: pair), on: token.host,
            principal: .service, deadline: deadline, roomToken: nil)
        if case .failure(let failure) = response { throw failure }
        guard case .forwardPair(let result) = response,
              result.sourceMessageID == pair.source.messageID, result.targetRoomID == pair.targetRoomID else {
            throw V2RoomCallFailure.outcomeUnknown
        }
        return result
    }
    package func mutatePolicy(_ mutation: V2PolicyMutationWire, on host: V2ActorHostIdentity,
        deadline: ContinuousClock.Instant) async throws -> V2PolicyMutationReceiptWire {
        let response = try await exchange(.mutatePolicy(mutation), on: host,
            principal: .service, deadline: deadline, roomToken: nil)
        if case .failure(let failure) = response { throw failure }
        if case .policyMutationIdentityConflict(let original) = response {
            guard original == mutation else { throw V2RoomCallFailure.outcomeUnknown }
            throw V2PolicyMutationServiceError.identityConflict
        }
        guard case .policyMutationCommitted(let receipt) = response, receipt.matches(mutation) else {
            throw V2RoomCallFailure.outcomeUnknown
        }
        return receipt
    }
    package func policySnapshots(_ request: V2PolicySnapshotRequestWire, on host: V2ActorHostIdentity,
        deadline: ContinuousClock.Instant) async throws -> [V2PolicySnapshotWire] {
        V2SendPathTrace.current?.mark("policy_rpc_client_enter")
        defer { V2SendPathTrace.current?.mark("policy_rpc_client_return") }
        let response = try await exchange(.policySnapshots(request), on: host, principal: .service, deadline: deadline, roomToken: nil)
        if case .failure(let failure) = response { throw failure }
        guard case .policySnapshots(let states) = response, states.count == request.scopes.count,
              Set(states.map { $0.scope.key }) == Set(request.scopes.map(\.key)) else { throw V2RoomCallFailure.outcomeUnknown }
        return states
    }
    package func updatePolicySnapshot(_ request: V2PolicySnapshotUpdateWire, on host: V2ActorHostIdentity,
        deadline: ContinuousClock.Instant) async throws {
        let response = try await exchange(.updatePolicySnapshot(request), on: host, principal: .service, deadline: deadline, roomToken: nil)
        if case .failure(let failure) = response { throw failure }
        guard case .acknowledged = response else { throw V2RoomCallFailure.outcomeUnknown }
    }
    private let system: ClusterSystem
    private let signer: V2ActorSigningIdentity
    private let trust: V2ActorTrustStore
    private let limits: V2ActorAuthenticationLimits
    private let configuration: V2RoomRuntimeConfiguration
    public nonisolated let callerIncarnation: UUID
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
    private var nextDescriptorGeneration: UInt64 = 0
    private var descriptorGenerations: [V2ActorHostIdentity: UInt64] = [:]
    private let stableHostID: V2ActorHostID
    private let budget: V2RoomClusterBudget
    private let physicalReferences: V2RoomClusterReferenceCache
    private var referenceGenerations: [V2RoomActivationToken: UInt64] = [:]
    private var nextReferenceGeneration: UInt64 = 0
    private var pendingReferenceInstalls: [V2RoomActivationToken: Int] = [:]
    private var referenceUsers: [UInt64: Int] = [:]
    private var revokedReferences: Set<UInt64> = []
    private var hostRecoveryRevisions: [V2ActorHostIdentity: UInt64] = [:]
    private var hostRecovery: [V2ActorHostIdentity: HostRecovery] = [:]
    private var recoveryProbes: [V2ActorHostIdentity: RecoveryProbe] = [:]
    private var recoveryWaiterCount = 0
    private var pinnedReferences: [V2RoomActivationToken: ReferenceSnapshot] = [:]
    private var pendingReferencePins: [V2RoomActivationToken: Int] = [:]
    private var pinnedGrants: [V2RoomActivationToken: [UUID: V2RoomReservation]] = [:]
    private var pinnedReservations: [V2RoomActivationToken: [UUID: ContinuousClock.Instant]] = [:]
    private var reservationPermits: [UUID: V2RoomClusterBudget.Permit] = [:]
    private var pendingReservationSlots: Set<UUID> = []
    private var pendingReservationHosts: [UUID: V2ActorHostIdentity] = [:]
    private var uncertainReservationSlots: [UUID: ContinuousClock.Instant] = [:]
    private var dispatchedCalls: [UUID: DispatchedCall] = [:]
    private var cachedLocalCalls: UInt64 = 0
    private var cachedRemoteCalls: UInt64 = 0
    private var roomLookups: UInt64 = 0
    private var roomInvocations: UInt64 = 0
    private var referenceMisses: UInt64 = 0
    private var hostRecoveryProbes: UInt64 = 0
    private var hostRecoveryWaits: UInt64 = 0
    private var activeExchanges = 0
    private var activeRecoveryBatches = 0
    private var recoveryStageStates: [V2RoomTransportRecoveryStage: RecoveryStageState] = [:]
    private var renewalFailures: [V2RoomRenewalFailureStage: UInt64] = [:]
    private var batchCallerTimeouts: UInt64 = 0
    private var batchCallerCancellations: UInt64 = 0
    private var batchRejectedGlobal: UInt64 = 0
    private var batchRejectedPeer: UInt64 = 0
    private var recoveryBatchesByHost: [V2ActorHostID: Int] = [:]
    private var renewalBatchesByHost: [V2ActorHostID: Int] = [:]
    private var accepting = true

    init(system: ClusterSystem, signer: V2ActorSigningIdentity,
         trust: V2ActorTrustStore, limits: V2ActorAuthenticationLimits,
         configuration: V2RoomRuntimeConfiguration,
         callerIncarnation: UUID, localPort: V2RoomLocalPort?,
         stableHostID: V2ActorHostID, budget: V2RoomClusterBudget,
         references: V2RoomClusterReferenceCache) {
        self.system = system
        self.signer = signer
        self.trust = trust
        self.limits = limits
        self.configuration = configuration
        self.callerIncarnation = callerIncarnation
        self.localPort = localPort
        self.stableHostID = stableHostID
        self.budget = budget
        self.physicalReferences = references
    }

    /// 重启会发布新的实例标识和 ActorID。已分发的调用及获准的预留
    /// 在结算前继续保留旧身份。
    public func register(_ descriptor: V2RoomClusterHostDescriptor) throws {
        try installDiscovered(descriptor)
        system.cluster.join(host: descriptor.address, port: descriptor.port)
    }

    // Publish within this Peer turn so discovery and suspension cannot overwrite
    // each other's state across a control-Actor await. Directory locks never await.
    func installPublished(_ descriptor: V2RoomClusterHostDescriptor,
                          directory: V2RoomClusterDirectory) throws {
        try installDiscovered(descriptor)
        directory.publish(descriptor, peer: self, suspended: suspendedHosts.contains(descriptor.identity))
    }

    func suspendPublished(_ host: V2ActorHostIdentity, directory: V2RoomClusterDirectory) -> Bool {
        let drained = suspendUnreachableHost(host)
        directory.suspend(host)
        return drained
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
            if descriptor.isHealthy, suspendedHosts.contains(descriptor.identity), !hasRetiredWork(descriptor.identity) {
                sessions.removeValue(forKey: descriptor.identity)
                suspendedHosts.remove(descriptor.identity)
            }
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
            advanceDescriptorGeneration(old)
            pruneRetiredDescriptor(old)
        }
        advanceDescriptorGeneration(descriptor.identity)
        descriptors[descriptor.identity] = descriptor
        hostRecovery.removeValue(forKey: descriptor.identity)
    }

    /// Resolve only the configured stable host. Zero free room slots do not
    /// make a policy owner unavailable or authorize selecting another host.
    package func resolvePolicyHost(hostID: V2ActorHostID, endpoint: String) throws -> V2ActorHostIdentity {
        guard accepting else { throw V2RoomCallFailure.notAccepted(.retired) }
        let matches = descriptors.values.filter {
            $0.identity.hostID == hostID && $0.accessibleShardIDs.contains(endpoint)
                && $0.isHealthy && !suspendedHosts.contains($0.identity)
        }
        guard matches.count == 1, let descriptor = matches.first else { throw V2RoomCallFailure.notAccepted(.unavailable) }
        return descriptor.identity
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
        for probe in recoveryProbes.values { probe.task.cancel() }
        for host in Array(recoveryProbes.keys) { failRecoveryWaiters(host, failure: .notAccepted(.retired)) }
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
        physicalReferences.removeAll(on: stableHostID)
        referenceGenerations.removeAll()
        pendingReferenceInstalls.removeAll()
        revokedReferences.removeAll()
        referenceUsers.removeAll()
        hostRecovery.removeAll()
        hostRecoveryRevisions.removeAll()
        pinnedReferences.removeAll()
        pendingReferencePins.removeAll()
        pinnedGrants.removeAll()
        pinnedReservations.removeAll()
        pendingReservationSlots.removeAll()
        pendingReservationHosts.removeAll()
        uncertainReservationSlots.removeAll()
        reservationPermits.removeAll()
    }

    private var isQuiescent: Bool {
        handshakes.isEmpty && recoveryProbes.isEmpty && dispatchedCalls.isEmpty && activeExchanges == 0 &&
            pendingReservationSlots.isEmpty
    }

    private func finishStopIfIdle() {
        if !accepting && isQuiescent { clearStoppedState() }
    }

    public func callMetricsSnapshot() -> V2RoomTransportCallMetricsSnapshot {
        .init(cachedLocalCalls: cachedLocalCalls, cachedRemoteCalls: cachedRemoteCalls,
              roomLookups: roomLookups, roomInvocations: roomInvocations,
              referenceMisses: referenceMisses, hostRecoveryProbes: hostRecoveryProbes,
              hostRecoveryWaits: hostRecoveryWaits, activeHostRecoveries: recoveryProbes.count,
              recoveryStages: recoveryStageSnapshots(), batchCallerTimeouts: batchCallerTimeouts,
              batchCallerCancellations: batchCallerCancellations, batchRejectedGlobal: batchRejectedGlobal,
              batchRejectedPeer: batchRejectedPeer,
              renewalActualCalls: renewalBatchesByHost.values.reduce(0, +), renewalFailures: renewalFailures)
    }

    public func sessionCount() -> Int { sessions.count }
    public func handshakeWaiterSnapshot() -> Int { handshakeWaiterCount }
    public func physicalReferenceCount() -> Int { physicalReferences.count(on: stableHostID) }
    public func retiredDescriptorCount() -> Int { retiredDescriptors.count }
    public func dispatchedCallCount() -> Int { dispatchedCalls.count }
    func reservationSlotSnapshot() -> Int {
        pruneReservations()
        return pinnedReservations.values.reduce(0, { $0 + $1.count }) +
            pendingReservationSlots.count + uncertainReservationSlots.count
    }

    public func activate(on host: V2ActorHostIdentity, roomID: RoomID, owner: V2RoomDataOwner,
                         deadline: ContinuousClock.Instant) async throws -> V2RoomActivationResolution {
        let generation = descriptorGenerations[host]
        let referenceWatermark = nextReferenceGeneration
        let response = try await exchange(.activate(roomID: roomID, owner: owner), on: host,
                                          principal: .service, deadline: deadline, roomToken: nil)
        switch response {
        case .ready(let token, let physical):
            guard token.roomID == roomID, token.owner == owner, token.host == host else {
                throw V2RoomCallFailure.notAccepted(.staleActivation)
            }
            if accepting, descriptorGenerations[host] == generation, descriptors[host] != nil,
               (referenceGenerations[token] ?? 0) <= referenceWatermark {
                try rememberPhysical(physical, token: token)
            }
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
        let installRevision = beginReferenceInstall(token)
        defer { endReferenceInstall(token) }
        let descriptorRevision = descriptorGenerations[token.host]
        let recovered = try await recoverHostIfNeeded(token: token, deadline: deadline)
        let response: V2ActorRPCResponse
        if let recovered, recovered.token == token { response = recovered.response }
        else {
            response = try await exchange(.lookup(token), on: token.host,
                principal: .service, deadline: deadline, roomToken: nil)
        }
        switch response {
        case .ready(let observed, let physical):
            guard observed == token else { throw V2RoomCallFailure.notAccepted(.staleActivation) }
            guard accepting, descriptors[token.host] != nil,
                  descriptorGenerations[token.host] == descriptorRevision else { return false }
            // The shared probe already installed this exact response under its own CAS.
            if recovered?.token == token { return physicalReferences.actor(for: token) != nil }
            if referenceGenerations[token] == installRevision {
                try rememberPhysical(physical, token: token)
            }
            return physicalReferences.actor(for: token) != nil
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
              physicalReferences.actor(for: token) != nil
        else { return nil }
        return (port, session, capability)
    }

    /// A miss never dispatched a room business RPC and never performs placement lookup.
    public func tryInvokeCached(_ token: V2RoomActivationToken, request: V2RoomRequest,
                                principal: V2RoomClientPrincipal,
                                deadline: ContinuousClock.Instant) async throws -> V2CachedRoomCallResult {
        guard request.permitsCachedCall, request.roomID == token.roomID else { return .cacheMiss }
        guard accepting else { throw V2RoomCallFailure.notAccepted(.retired) }
        guard !suspendedHosts.contains(token.host), descriptors[token.host] != nil,
              physicalReferences.actor(for: token) != nil,
              descriptors[token.host]?.accessibleShardIDs.contains(token.owner.shardID) == true else {
            referenceMisses &+= 1
            return .cacheMiss
        }
        do {
            let reply = try await exchange(.invoke(token: token, request: request), on: token.host,
                principal: principal.actorPrincipal, deadline: deadline, roomToken: token,
                requireCachedReference: true)
            switch reply {
            case .result(let result): return .response(result)
            case .failure(let failure): throw failure
            default: throw V2RoomCallFailure.outcomeUnknown
            }
        } catch CachedReferenceMiss.miss { referenceMisses &+= 1; return .cacheMiss }
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

    public func renewRoom(_ command: V2RoomSubscriptionRenewCommand, token: V2RoomActivationToken,
                          deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult {
        try await roomSubscription(.renew(command), token: token, deadline: deadline)
    }

    public func subscribeRoom(_ command: V2RoomSubscriptionSubscribeCommand, token: V2RoomActivationToken,
                              deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult {
        try await roomSubscription(.subscribe(command), token: token, deadline: deadline)
    }

    public func activateRoomSubscription(_ command: V2RoomSubscriptionActivateCommand, token: V2RoomActivationToken,
                                         deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult {
        try await roomSubscription(.activate(command), token: token, deadline: deadline)
    }

    public func resetRoomSubscription(_ command: V2RoomSubscriptionResetCommand, token: V2RoomActivationToken,
                                      deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult {
        try await roomSubscription(.reset(command), token: token, deadline: deadline)
    }

    public func unsubscribeRoom(_ command: V2RoomSubscriptionUnsubscribeCommand, token: V2RoomActivationToken,
                                deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult {
        try await roomSubscription(.unsubscribe(command), token: token, deadline: deadline)
    }

    private func roomSubscription(_ command: V2RoomSubscriptionCommand, token: V2RoomActivationToken,
                                  deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult {
        do { try command.validate() }
        catch { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        guard command.roomID == token.roomID,
              command.gatewayDescriptor.identity.serviceID == signer.serviceID.rawValue,
              command.gatewayDescriptor.identity.incarnationID == callerIncarnation else {
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
        try trust.validateRealtimeReceiver(command.gatewayDescriptor.identity)
        let request = V2RoomRequest.roomSubscription(command)
        let response: V2RoomResponse
        switch try await tryInvokeCached(token, request: request, principal: .user(command.actorUserID), deadline: deadline) {
        case .response(let value): response = value
        case .cacheMiss: response = try await invoke(token, request: request, principal: .user(command.actorUserID), deadline: deadline)
        }
        guard case .roomSubscription(let result) = response else { throw V2RoomCallFailure.outcomeUnknown }
        switch (command, result) {
        case (.subscribe, .granted(let grant)), (.reset, .granted(let grant)):
            guard grant.fence.activation == token, grant.fence.generation > 0,
                  grant.memberRevision <= UInt64(Int64.max),
                  grant.userBaselineSequence >= grant.fence.baselineSequence,
                  grant.userBaselineSequence <= UInt64(Int64.max),
                  grant.remainingLeaseMilliseconds > 0,
                  grant.remainingLeaseMilliseconds <= 300_000 else { throw V2RoomCallFailure.outcomeUnknown }
            if case .reset(let value) = command {
                guard grant.fence.generation > value.expectedFence.generation,
                      grant.fence.subscriptionID != value.expectedFence.subscriptionID,
                      grant.fence.baselineSequence >= value.expectedFence.baselineSequence else {
                    throw V2RoomCallFailure.outcomeUnknown
                }
            }
        case (.renew(let command), .renewed(let proof)):
            guard proof.fence == command.expectedFence,
                  proof.appliedControlSequence == command.appliedControlSequence,
                  proof.committedRoomSequence >= command.expectedFence.baselineSequence,
                  proof.committedRoomSequence <= UInt64(Int64.max),
                  (1...300_000).contains(proof.remainingLeaseMilliseconds) else {
                throw V2RoomCallFailure.outcomeUnknown
            }
        case (.activate, .activated), (.unsubscribe, .unsubscribed), (_, .failure): break
        default: throw V2RoomCallFailure.outcomeUnknown
        }
        return result
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
        guard let actor = physicalReferences.actor(for: token), let revision = referenceGenerations[token] else {
            throw V2RoomCallFailure.notAccepted(.notReady)
        }
        let reference = ReferenceSnapshot(token: token, actor: actor, generation: revision)
        pendingReferencePins[token, default: 0] += 1
        let reservationPermit = try budget.acquire(.reservation)
        let slot = UUID()
        reservationPermits[slot] = reservationPermit
        physicalReferences.pin(token)
        pendingReservationSlots.insert(slot)
        pendingReservationHosts[slot] = token.host
        defer {
            let remaining = pendingReferencePins[token, default: 1] - 1
            if remaining == 0 { pendingReferencePins.removeValue(forKey: token) }
            else { pendingReferencePins[token] = remaining }
            pendingReservationSlots.remove(slot)
            pendingReservationHosts.removeValue(forKey: slot)
            if uncertainReservationSlots[slot] == nil { reservationPermits[slot] = nil }
            physicalReferences.unpin(token)
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
            reservationPermits[grant.reservationID] = reservationPermit
            physicalReferences.pin(token)
            pinnedReferences[token] = reference
            pinnedGrants[token, default: [:]][grant.reservationID] = grant
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
        if let actor = physicalReferences.actor(for: token) { return actor }
        guard try await lookup(token, deadline: deadline) else { return nil }
        return physicalReferences.actor(for: token)
    }

    public func renewRoomSubscriptions(on host: V2ActorHostIdentity,
        items: [V2RoomSubscriptionRenewBatchItem], deadline: ContinuousClock.Instant) async throws -> [V2RoomSubscriptionRenewBatchOutcome] {
        guard !items.isEmpty, items.count <= 64, Set(items.map { $0.token.roomID }).count == items.count else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        for item in items {
            try V2RoomSubscriptionCommand.renew(item.command).validate()
            guard item.token.host == host, item.token.roomID == item.command.roomID,
                  item.command.expectedFence.activation == item.token,
                  item.command.gatewayDescriptor.identity.serviceID == signer.serviceID.rawValue,
                  item.command.gatewayDescriptor.identity.incarnationID == callerIncarnation else {
                throw V2ActorAuthenticationError.forbidden
            }
            try trust.validateRealtimeReceiver(item.command.gatewayDescriptor.identity)
        }
        // Reserve the largest legal envelope before dispatch. A count-bounded
        // batch can still exceed the wire budget because callback data repeats.
        let template = V2ActorAuthenticatedCall(serviceID: signer.serviceID, callerIncarnation: callerIncarnation,
            recipient: host, sessionID: UUID(), sequence: .max, attemptID: UUID(), traceID: UUID(),
            remainingBudget: try .init(V2ActorMilliseconds.maximum), principal: .service,
            request: .subscriptionRenewBatch([]))
        let batches = try Self.renewalBatches(items, template: template,
            maximumBytes: min(65_536, limits.maximumRequestBytes))
        var results: [V2RoomSubscriptionRenewBatchOutcome] = []
        for batch in batches {
            results += try await renewRoomSubscriptionBatch(on: host, items: batch, deadline: deadline)
        }
        return results
    }

    /// Preflight every batch before any RPC; an oversized single item is an
    /// explicit request failure, never a partially dispatched packing attempt.
    static func renewalBatches(_ items: [V2RoomSubscriptionRenewBatchItem],
        template: V2ActorAuthenticatedCall, maximumBytes: Int) throws -> [[V2RoomSubscriptionRenewBatchItem]] {
        let encoder = JSONEncoder()
        let empty = V2ActorAuthenticatedCall(version: template.version, serviceID: template.serviceID,
            callerIncarnation: template.callerIncarnation, recipient: template.recipient,
            sessionID: template.sessionID, sequence: template.sequence, attemptID: template.attemptID,
            traceID: template.traceID, remainingBudget: template.remainingBudget,
            principal: template.principal, request: .subscriptionRenewBatch([]))
        let overhead = try encoder.encode(empty).count
        var batches: [[V2RoomSubscriptionRenewBatchItem]] = [], pending: [V2RoomSubscriptionRenewBatchItem] = []
        var pendingBytes = overhead
        for item in items {
            let itemBytes = try encoder.encode(item).count
            guard itemBytes <= maximumBytes - overhead else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
            let separator = pending.isEmpty ? 0 : 1
            if pending.count == 64 || pendingBytes + separator + itemBytes > maximumBytes {
                batches.append(pending); pending = []; pendingBytes = overhead
            }
            pendingBytes += itemBytes + (pending.isEmpty ? 0 : 1)
            pending.append(item)
        }
        if !pending.isEmpty { batches.append(pending) }
        return batches
    }

    private func renewRoomSubscriptionBatch(on host: V2ActorHostIdentity,
        items: [V2RoomSubscriptionRenewBatchItem], deadline: ContinuousClock.Instant) async throws -> [V2RoomSubscriptionRenewBatchOutcome] {
        let references = items.compactMap { item -> ReferenceSnapshot? in
            guard let actor = physicalReferences.actor(for: item.token), let generation = referenceGenerations[item.token] else { return nil }
            return .init(token: item.token, actor: actor, generation: generation)
        }
        let response = try await exchange(.subscriptionRenewBatch(items), on: host, principal: .service,
            deadline: deadline, roomToken: nil)
        if case .failure(let failure) = response { throw failure }
        guard case .subscriptionRenewBatch(let results) = response, results.count == items.count else {
            throw invalidRenewalReply()
        }
        for (item, result) in zip(items, results) {
            guard result.token == item.token else { throw invalidRenewalReply() }
            switch result.outcome {
            case .result(.renewed(let proof)):
                guard proof.fence == item.command.expectedFence,
                      proof.appliedControlSequence == item.command.appliedControlSequence,
                      proof.committedRoomSequence >= item.command.expectedFence.baselineSequence,
                      proof.committedRoomSequence <= UInt64(Int64.max),
                      (1...300_000).contains(proof.remainingLeaseMilliseconds) else { throw invalidRenewalReply() }
            case .result(.failure): break
            case .failure(let failure):
                if failure == .outcomeUnknown { recordRenewalFailure(.remoteOutcomeUnknown) }
                if isExplicitlyStale(failure), let reference = references.first(where: { $0.token == item.token }) {
                    invalidateReference(reference)
                }
            default: throw invalidRenewalReply()
            }
        }
        return results
    }

    public func invokeRecoveryBatch(on host: V2ActorHostIdentity, items: [V2RoomRecoveryBatchCallItem],
                                    deadline: ContinuousClock.Instant) async throws -> [V2RoomRecoveryBatchCallOutcome] {
        guard !items.isEmpty, items.count <= 100,
              items.allSatisfy({ $0.token.host == host && $0.token.roomID == $0.query.roomID && $0.query.kind == .state &&
                  $0.query.roomID.uuidValue != nil && $0.query.actorUserID.uuidValue != nil }),
              Set(items.map { $0.query.roomID.rawValue + ":" + $0.query.actorUserID.rawValue }).count == items.count,
              Set(items.map { $0.token.owner }).count == 1 else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        let end = min(deadline, items.map(\.deadline).min()!)
        guard end > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        // Capture installed references before the handshake. Only exact stale
        // replies can revoke these installations; late replies cannot clear a
        // replacement installed during this call.
        let references = items.compactMap { item -> ReferenceSnapshot? in
            guard let actor = physicalReferences.actor(for: item.token), let generation = referenceGenerations[item.token] else { return nil }
            return .init(token: item.token, actor: actor, generation: generation)
        }
        let wire = items.map { V2RoomRecoveryBatchWireItem(token: $0.token, query: $0.query) }
        let response = try await exchange(.recoveryBatch(wire), on: host, principal: .service,
                                          deadline: end, roomToken: nil)
        if case .failure(let failure) = response { throw failure }
        guard case .recoveryBatch(let results) = response, results.count == items.count else {
            throw V2RoomCallFailure.outcomeUnknown
        }
        for (item, result) in zip(items, results) {
            guard result.token == item.token, result.query == item.query else { throw V2RoomCallFailure.outcomeUnknown }
            switch result.outcome {
            case .result(let response):
                switch response {
                case .recovery(.state(.state(let state))):
                    guard state.roomID == item.query.roomID,
                          state.ownerEpoch == UInt64(item.token.owner.epoch) else { throw V2RoomCallFailure.outcomeUnknown }
                case .recovery(.state), .recovery(.failure): break
                default: throw V2RoomCallFailure.outcomeUnknown
                }
            case .failure(let failure):
                if isExplicitlyStale(failure), let reference = references.first(where: { $0.token == item.token }) {
                    invalidateReference(reference)
                }
            }
        }
        return results
    }

    private func exchange(_ request: V2ActorRPCRequest, on host: V2ActorHostIdentity,
                          principal: V2ActorCallPrincipal, deadline: ContinuousClock.Instant,
                          roomToken: V2RoomActivationToken?,
                          requireCachedLocal: Bool = false,
                          requireCachedReference: Bool = false) async throws -> V2ActorRPCResponse {
        let sendTrace: V2SendPathTrace?
        if case .invoke(_, .messaging(.sendOperation(_))) = request { sendTrace = V2SendPathTrace.current }
        else { sendTrace = nil }
        sendTrace?.mark("rpc_exchange_enter")
        defer { sendTrace?.mark("rpc_exchange_return") }
        let permittedSuspendedCleanup = permitsPinnedCleanup(request, host: host)
        let recoveryBatch: Bool
        switch request { case .recoveryBatch, .subscriptionRenewBatch: recoveryBatch = true; default: recoveryBatch = false }
        let requestBytes = recoveryBatch ? min(65_536, limits.maximumRequestBytes) : limits.maximumRequestBytes
        let replyBytes = recoveryBatch ? min(262_144, limits.maximumReplyBytes) : limits.maximumReplyBytes
        guard accepting, (!suspendedHosts.contains(host) || permittedSuspendedCleanup),
              let descriptor = descriptors[host] ?? retiredDescriptor(for: request, host: host) else {
            throw V2RoomCallFailure.notAccepted(.unavailable)
        }
        let exchangePermit = try budget.acquire(.exchange)
        defer { exchangePermit.release() }
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
        let recoveryRevision = hostRecoveryRevisions[host, default: 0]
        // Capture before the first await. Ordinary LRU removal never revokes this snapshot.
        let reservationControl: Bool
        switch request {
        case .markDispatched, .abortReservation, .finishReservation: reservationControl = true
        default: reservationControl = false
        }
        let reference: ReferenceSnapshot? = roomToken.flatMap { token in
            if reservationControl, let pinned = pinnedReferences[token] { return pinned }
            if let actor = physicalReferences.actor(for: token), let revision = referenceGenerations[token] {
                return ReferenceSnapshot(token: token, actor: actor, generation: revision)
            }
            return pinnedReferences[token]
        }
        if requireCachedReference && reference == nil { throw CachedReferenceMiss.miss }
        if let reference { referenceUsers[reference.generation, default: 0] += 1 }
        defer {
            if let reference {
                let remaining = referenceUsers[reference.generation, default: 1] - 1
                if remaining == 0 {
                    referenceUsers.removeValue(forKey: reference.generation)
                    revokedReferences.remove(reference.generation)
                } else { referenceUsers[reference.generation] = remaining }
            }
        }
        let localInvocation = requireCachedLocal ? roomToken.flatMap(cachedLocalInvocation(for:)) : nil
        if requireCachedLocal && localInvocation == nil {
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        // 若精确的本地能力已消失，提示调用不能开启远程握手，
        // 也不能回退为签名报文调用。
        let sessionStartedAt = ContinuousClock.now
        let session: Session
        if let localInvocation { session = localInvocation.session }
        else if recoveryBatch {
            session = try await recoveryBatchSession(for: descriptor, deadline: deadline, request: request)
        } else { session = try await self.session(for: descriptor, deadline: deadline) }
        sendTrace?.record("rpc_session", from: sessionStartedAt)
        guard accepting, (!suspendedHosts.contains(host) || permittedSuspendedCleanup), descriptorGenerations[host] == generation,
              (reservationControl || (reference.map({ !revokedReferences.contains($0.generation) }) ?? true)) else {
            if requireCachedReference { throw CachedReferenceMiss.miss }
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
        if case .policySnapshots = request {
            V2SendPathTrace.current?.mark("policy_rpc_link_" + call.traceID.uuidString)
        }
        let isLocal = requireCachedLocal || (localPort.map { descriptor.identity == $0.identity &&
                                      descriptor.endpointID == $0.endpointID } == true &&
                      live.localCapability != nil)
        let remotePacket: V2ActorSignedPacket?
        if isLocal {
            remotePacket = nil
        } else {
            do { remotePacket = try await signRequest(call, maximumBytes: requestBytes) }
            catch { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        }
        guard accepting, descriptorGenerations[host] == generation,
              !suspendedHosts.contains(host) || permittedSuspendedCleanup else {
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        let transportReply: TransportReply
        sendTrace?.mark("rpc_transport_dispatch")
        sendTrace?.mark(isLocal ? "rpc_transport_local" : "rpc_transport_remote")
        do {
            let timeout = boundedTimeout(deadline)
            if requireCachedLocal {
                guard let roomToken else {
                    throw V2RoomCallFailure.notAccepted(.staleActivation)
                }
                let payload: V2ActorLocalPayload<V2ActorAuthenticatedCall>
                do { payload = try .init(call) }
                catch { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
                guard payload.byteCount > 0, payload.byteCount <= requestBytes else {
                    throw V2RoomCallFailure.notAccepted(.invalidRequest)
                }
                transportReply = try await boundedDispatch(deadline: deadline, request: request,
                                                           host: host, cached: requireCachedReference || requireCachedLocal, local: isLocal) { [self] in
                    try await dispatchCachedLocal(payload, token: roomToken,
                                                  sessionID: call.sessionID)
                }
            } else if let port = localPort, descriptor.identity == port.identity,
               descriptor.endpointID == port.endpointID,
               let capability = live.localCapability {
                if roomToken != nil && reference == nil {
                    throw V2RoomCallFailure.notAccepted(.notReady)
                }
                let payload: V2ActorLocalPayload<V2ActorAuthenticatedCall>
                do { payload = try .init(call) }
                catch { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
                guard payload.byteCount > 0, payload.byteCount <= requestBytes else {
                    throw V2RoomCallFailure.notAccepted(.invalidRequest)
                }
                transportReply = try await boundedDispatch(deadline: deadline, request: request,
                                                           host: host, cached: requireCachedReference || requireCachedLocal, local: isLocal) {
                    .local(try await port.inbound.exchangeLocal(payload, capability: capability,
                        generation: port.generation, boundToken: roomToken))
                }
            } else if let roomToken {
                guard let packet = remotePacket else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
                guard let actor = reference?.actor else {
                    throw V2RoomCallFailure.notAccepted(.notReady)
                }
                transportReply = try await boundedDispatch(deadline: deadline, request: request,
                                                           host: host, cached: requireCachedReference || requireCachedLocal, local: isLocal) {
                    let reply = try await RemoteCall.with(timeout: timeout) { try await actor.exchange(packet) }
                    sendTrace?.mark("rpc_remote_return")
                    return .signed(reply)
                }
            } else {
                guard let packet = remotePacket else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
                let endpoint = try V2RoomHostEndpoint.resolve(id: descriptor.endpointID, using: system)
                transportReply = try await boundedDispatch(deadline: deadline, request: request,
                                                           host: host, cached: requireCachedReference || requireCachedLocal, local: isLocal) {
                    let reply = try await RemoteCall.with(timeout: timeout) { try await endpoint.exchange(packet) }
                    if case .policySnapshots = request { V2SendPathTrace.current?.mark("policy_rpc_remote_return") }
                    return .signed(reply)
                }
            }
        } catch let failure as V2RoomCallFailure {
            if failure == .outcomeUnknown, !Task.isCancelled {
                noteTransportFailure(reference: reference, host: host,
                    descriptorGeneration: generation, recoveryRevision: recoveryRevision)
            }
            throw failure
        }
        catch {
            if case .subscriptionRenewBatch = request { recordRenewalFailure(.transportError) }
            // 激活也会写入租约。任一可写 RPC 开始后，
            // 网络故障都不能证明它没有提交。
            if !(error is V2ActorAuthenticationError), !Task.isCancelled {
                noteTransportFailure(reference: reference, host: host,
                    descriptorGeneration: generation, recoveryRevision: recoveryRevision)
            }
            throw transportFailure(for: request)
        }
        sendTrace?.mark("rpc_transport_return")
        do {
            let response = try await verifyReply(transportReply, for: call, maximumBytes: replyBytes)
            // 节点替换不会使已分发调用的正确签名响应失效。
            // 旧令牌不能授权新激活，但调用方必须收到实际结果。
            if case .failure(let failure) = response {
                if let reference, isExplicitlyStale(failure) { invalidateReference(reference) }
                if roomToken == nil {
                    switch failure {
                    case .notAccepted(.unavailable), .notAccepted(.deadlineExceeded), .outcomeUnknown:
                        markHostSuspect(host, descriptorGeneration: generation, recoveryRevision: recoveryRevision)
                    default: break
                    }
                }
            }
            return response
        }
        catch let failure as V2RoomCallFailure { throw failure }
        catch {
            if case .subscriptionRenewBatch = request { recordRenewalFailure(.replyVerification) }
            throw transportFailure(for: request)
        }
    }

    @concurrent private nonisolated func signRequest(_ call: V2ActorAuthenticatedCall,
        maximumBytes: Int) async throws -> V2ActorSignedPacket {
        try signer.signAuthenticated(call, binary: system.settings.serialization.binaryDistributedInvocations,
            maximumBytes: maximumBytes)
    }
    @concurrent private nonisolated func verifyReply(_ reply: TransportReply,
        for call: V2ActorAuthenticatedCall, maximumBytes: Int) async throws -> V2ActorRPCResponse {
        switch reply {
        case .signed(let packet): return try trust.verifyReply(packet, for: call, maximumBytes: maximumBytes)
        case .local(let payload):
            guard let port = localPort else { throw V2ActorAuthenticationError.wrongRecipient }
            return try trust.verifyLocalReply(payload, for: call, from: port.identity, maximumBytes: maximumBytes)
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

    private func recordRenewalFailure(_ stage: V2RoomRenewalFailureStage) {
        renewalFailures[stage] = Self.increment(renewalFailures[stage, default: 0])
    }
    private func invalidRenewalReply() -> V2RoomCallFailure {
        recordRenewalFailure(.invalidBatchReply)
        return .outcomeUnknown
    }
    private func transportFailure(for request: V2ActorRPCRequest) -> V2RoomCallFailure {
        if case .lookup = request { return .notAccepted(.unavailable) }
        return .outcomeUnknown
    }

    private func boundedDispatch(
        deadline: ContinuousClock.Instant, request: V2ActorRPCRequest,
        host: V2ActorHostIdentity, cached: Bool = false, local: Bool = false,
        operation: @escaping @Sendable () async throws -> TransportReply
    ) async throws -> TransportReply {
        let sendTrace: V2SendPathTrace?
        let tracePrefix: String
        switch request {
        case .invoke(_, .messaging(.sendOperation(_))):
            sendTrace = V2SendPathTrace.current; tracePrefix = "rpc"
        case .policySnapshots:
            sendTrace = V2SendPathTrace.current; tracePrefix = "policy_rpc"
        default:
            sendTrace = nil; tracePrefix = "rpc"
        }
        defer { sendTrace?.mark("\(tracePrefix)_waiter_resumed") }
        guard accepting, ContinuousClock.now < deadline else {
            throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
        }
        guard !Task.isCancelled else { throw V2RoomCallFailure.notAccepted(.cancelled) }
        let dispatchPermit = try budget.acquire(.transport)
        let recoveryBatch: Bool
        switch request { case .recoveryBatch: recoveryBatch = true; default: recoveryBatch = false }
        let renewalBatch: Bool
        switch request { case .subscriptionRenewBatch: renewalBatch = true; default: renewalBatch = false }
        // Maintenance has its own per-host quota. The outer actual-dispatch
        // limit still bounds total transport work, including timed-out callers.
        if renewalBatch, renewalBatchesByHost[host.hostID, default: 0] >= 2 {
            throw V2RoomCallFailure.notAccepted(.overloaded)
        }
        if recoveryBatch {
            guard activeRecoveryBatches < 4 else {
                batchRejectedGlobal = Self.increment(batchRejectedGlobal)
                throw V2RoomCallFailure.notAccepted(.overloaded)
            }
            guard recoveryBatchesByHost[host.hostID, default: 0] < 2 else {
                batchRejectedPeer = Self.increment(batchRejectedPeer)
                throw V2RoomCallFailure.notAccepted(.overloaded)
            }
        }
        let recoveryPermit = recoveryBatch ? try budget.acquire(.recovery) : nil
        let id = UUID()
        let failure = transportFailure(for: request)
        let completion = V2RoomRPCCompletion<TransportReply>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled || ContinuousClock.now >= deadline {
                    continuation.resume(throwing: V2RoomCallFailure.notAccepted(
                        Task.isCancelled ? .cancelled : .deadlineExceeded
                    ))
                    return
                }
                switch request {
                case .lookup: roomLookups &+= 1
                case .invoke:
                    roomInvocations &+= 1
                    if cached {
                        if local { cachedLocalCalls &+= 1 } else { cachedRemoteCalls &+= 1 }
                    }
                default: break
                }
                completion.install(continuation)
                let timer = Task.detached { [self] in
                    do { try await ContinuousClock().sleep(until: deadline) }
                    catch { return }
                    if completion.cancelCaller(with: failure) {
                        await recordDispatchTimeout(recoveryBatch: recoveryBatch,
                            renewalBatch: renewalBatch, cancelled: false)
                    }
                }
                dispatchedCalls[id] = .init(host: host, completion: completion, timer: timer,
                    permit: dispatchPermit, recoveryPermit: recoveryPermit,
                    recoveryBatch: recoveryBatch, renewalBatch: renewalBatch)
                if renewalBatch { renewalBatchesByHost[host.hostID, default: 0] += 1 }
                if recoveryBatch {
                    startRecoveryStage(.actualDispatch, id: id, items: Self.batchItemCount(request))
                    activeRecoveryBatches += 1
                    recoveryBatchesByHost[host.hostID, default: 0] += 1
                }
                // 物理调用在启动前就完成登记。唯一的任务负责结算，
                // 并在操作实际返回前持有此客户端，即使调用方已经退出。
                sendTrace?.mark("\(tracePrefix)_dispatch_registered")
                Task.detached { [self] in
                    sendTrace?.mark("\(tracePrefix)_dispatch_task_enter")
                    let result: Result<TransportReply, any Error>
                    do { result = .success(try await V2SendPathTrace.$current.withValue(sendTrace) { try await operation() }) }
                    catch { result = .failure(error) }
                    sendTrace?.mark("\(tracePrefix)_dispatch_settle")
                    completion.finishPhysical(with: result)
                    timer.cancel()
                    await completeDispatch(id: id)
                }
            }
        } onCancel: {
            if completion.cancelCaller(with: failure) {
                Task { await self.recordDispatchTimeout(recoveryBatch: recoveryBatch,
                    renewalBatch: renewalBatch, cancelled: true) }
            }
        }
    }

    private func recordDispatchTimeout(recoveryBatch: Bool, renewalBatch: Bool, cancelled: Bool) {
        if recoveryBatch {
            if cancelled { batchCallerCancellations = Self.increment(batchCallerCancellations) }
            else { batchCallerTimeouts = Self.increment(batchCallerTimeouts) }
        }
        if renewalBatch { recordRenewalFailure(cancelled ? .callerCancelled : .callerTimeout) }
    }

    private func completeDispatch(id: UUID) {
        guard let call = dispatchedCalls.removeValue(forKey: id) else { return }
        if call.renewalBatch {
            let remaining = renewalBatchesByHost[call.host.hostID, default: 1] - 1
            if remaining == 0 { renewalBatchesByHost.removeValue(forKey: call.host.hostID) }
            else { renewalBatchesByHost[call.host.hostID] = remaining }
        }
        if call.recoveryBatch {
            finishRecoveryStage(.actualDispatch, id: id)
            activeRecoveryBatches -= 1
            let remaining = recoveryBatchesByHost[call.host.hostID, default: 1] - 1
            if remaining == 0 { recoveryBatchesByHost.removeValue(forKey: call.host.hostID) }
            else { recoveryBatchesByHost[call.host.hostID] = remaining }
        }
        call.timer.cancel()
        call.permit.release()
        call.recoveryPermit?.release()
        pruneRetiredDescriptor(call.host)
        finishStopIfIdle()
    }

    // Session caller latency includes joining an existing actual handshake. It
    // is deliberately separate from the independently owned dispatch lifetime.
    private func recoveryBatchSession(for descriptor: V2RoomClusterHostDescriptor,
                                      deadline: ContinuousClock.Instant,
                                      request: V2ActorRPCRequest) async throws -> Session {
        let id = UUID()
        startRecoveryStage(.sessionCallerWait, id: id, items: Self.batchItemCount(request))
        defer { finishRecoveryStage(.sessionCallerWait, id: id) }
        return try await session(for: descriptor, deadline: deadline)
    }

    private static func batchItemCount(_ request: V2ActorRPCRequest) -> Int {
        if case .subscriptionRenewBatch(let items) = request { return items.count }
        if case .recoveryBatch(let items) = request { return items.count }
        return 0
    }

    private static func increment(_ value: UInt64, by amount: UInt64 = 1) -> UInt64 {
        let result = value.addingReportingOverflow(amount)
        return result.overflow ? .max : result.partialValue
    }

    private func startRecoveryStage(_ stage: V2RoomTransportRecoveryStage, id: UUID, items: Int) {
        var state = recoveryStageStates[stage] ?? .init()
        state.starts[id] = .now
        state.started = Self.increment(state.started)
        state.itemsStarted = Self.increment(state.itemsStarted, by: UInt64(items))
        recoveryStageStates[stage] = state
    }

    private func finishRecoveryStage(_ stage: V2RoomTransportRecoveryStage, id: UUID) {
        guard var state = recoveryStageStates[stage], let start = state.starts.removeValue(forKey: id) else { return }
        let elapsed = Self.milliseconds(start.duration(to: .now))
        state.completed = Self.increment(state.completed)
        state.totalMilliseconds += elapsed
        state.maxMilliseconds = max(state.maxMilliseconds, elapsed)
        recoveryStageStates[stage] = state
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return max(0, Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000)
    }

    private func recoveryStageSnapshots() -> [V2RoomTransportRecoveryStage: V2RoomTransportRecoveryStageSnapshot] {
        let now = ContinuousClock.now
        return Dictionary(uniqueKeysWithValues: V2RoomTransportRecoveryStage.allCases.map { stage in
            let state = recoveryStageStates[stage] ?? .init()
            return (stage, .init(active: state.starts.count, started: state.started, completed: state.completed,
                totalMilliseconds: state.totalMilliseconds, maxMilliseconds: state.maxMilliseconds,
                oldestMilliseconds: state.starts.values.min().map { Self.milliseconds($0.duration(to: now)) } ?? 0,
                itemsStarted: state.itemsStarted))
        })
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
        let waiterPermit = try budget.acquire(.waiter)
        defer { waiterPermit.release() }
        let generation = descriptorGenerations[host, default: 0]
        let handshakeID: UUID
        if let currentID = handshakeIDs[host] {
            handshakeID = currentID
        } else {
            guard handshakes.count < limits.maximumSessions,
                  sessions.count < limits.maximumSessions else {
                throw V2RoomCallFailure.notAccepted(.overloaded)
            }
            let handshakePermit = try budget.acquire(.transport)
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
                handshakePermit.release()
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
                let expires = callStarted + grant.remainingLifetime.duration - .milliseconds(100)
                let permit = try budget.acquire(.session, expiresAt: expires)
                return Session(grant: grant, expires: expires,
                    nextSequence: 0, localCapability: capability, permit: permit)
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
        if physicalReferences.actor(for: token)?.id == id { return }
        let actor = try V2RoomClusterActor.resolve(id: id, using: system)
        let previous = physicalReferences.actor(for: token)
        let evicted = try physicalReferences.install(actor, for: token)
        for removed in physicalReferences.takeEvictions(on: stableHostID) {
            if pendingReferenceInstalls[removed] == nil { referenceGenerations.removeValue(forKey: removed) }
        }
        if let previous, previous.id != actor.id,
           let revision = referenceGenerations[token], referenceUsers[revision] != nil {
            revokedReferences.insert(revision)
        }
        advanceReferenceGeneration(token)
        if let evicted, evicted.host.hostID == stableHostID, pendingReferenceInstalls[evicted] == nil {
            referenceGenerations.removeValue(forKey: evicted)
        }
    }

    private func unpin(_ grant: V2RoomReservation) {
        if pinnedReservations[grant.token]?.removeValue(forKey: grant.reservationID) != nil {
            physicalReferences.unpin(grant.token)
        }
        reservationPermits[grant.reservationID] = nil
        pinnedGrants[grant.token]?.removeValue(forKey: grant.reservationID)
        if pinnedReservations[grant.token]?.isEmpty == true {
            pinnedReservations.removeValue(forKey: grant.token)
            pinnedGrants.removeValue(forKey: grant.token)
            pinnedReferences.removeValue(forKey: grant.token)
        }
        pruneRetiredDescriptor(grant.token.host)
    }

    private func pruneReservations() {
        let now = ContinuousClock.now
        for (token, grants) in pinnedReservations {
            for deadline in grants.values where deadline <= now { physicalReferences.unpin(token) }
        }
        uncertainReservationSlots = uncertainReservationSlots.filter { $0.value > now }
        pinnedReservations = pinnedReservations.compactMapValues { reservations in
            let live = reservations.filter { $0.value > now }
            return live.isEmpty ? nil : live
        }
        pinnedGrants = pinnedGrants.compactMapValues { grants in
            let live = grants.filter { pinnedReservations[$0.value.token]?[$0.key] != nil }
            return live.isEmpty ? nil : live
        }
        pinnedReferences = pinnedReferences.filter { pinnedReservations[$0.key]?.isEmpty == false }
        let retained = Set(pinnedReservations.values.flatMap { $0.keys })
            .union(pendingReservationSlots).union(uncertainReservationSlots.keys)
        reservationPermits = reservationPermits.filter { retained.contains($0.key) }
        for host in Array(retiredDescriptors.keys) { pruneRetiredDescriptor(host) }
    }

    private func permitsPinnedCleanup(_ request: V2ActorRPCRequest, host: V2ActorHostIdentity) -> Bool {
        let grant: V2RoomReservation
        switch request {
        case .markDispatched(let value), .abortReservation(let value), .finishReservation(let value, _):
            grant = value
        default: return false
        }
        return grant.token.host == host && pinnedGrants[grant.token]?[grant.reservationID] == grant &&
            pinnedReservations[grant.token]?[grant.reservationID].map { $0 > ContinuousClock.now } == true
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
        handshakes[host] != nil || recoveryProbes[host] != nil ||
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

    /// Close new admission immediately, then report whether actual old work drained.
    /// Exact existing grants may still settle; signed advertisements can reopen admission.
    func directorySuspended(_ host: V2ActorHostIdentity) -> Bool { suspendedHosts.contains(host) }

    public func suspendUnreachableHost(_ host: V2ActorHostIdentity) -> Bool {
        pruneReservations()
        guard descriptors[host] != nil else { return false }
        // Close admission first: repeated recovery calls must not prevent the
        // Discovery owner from ever observing an actually drained old node.
        suspendedHosts.insert(host)
        guard !hasRetiredWork(host) else { return false }
        sessions.removeValue(forKey: host)
        return true
    }

    private func pruneRetiredDescriptor(_ host: V2ActorHostIdentity) {
        guard retiredDescriptors[host] != nil, !hasRetiredWork(host) else { return }
        retiredDescriptors.removeValue(forKey: host)
        suspendedHosts.remove(host)
        sessions.removeValue(forKey: host)
        descriptorGenerations.removeValue(forKey: host)
        hostRecovery.removeValue(forKey: host)
        hostRecoveryRevisions.removeValue(forKey: host)
        for token in physicalReferences.tokens(on: stableHostID) where token.host == host {
            physicalReferences.remove(token)
            referenceGenerations.removeValue(forKey: token)
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

    private enum CachedReferenceMiss: Error { case miss }
    private struct ReferenceSnapshot: Sendable {
        let token: V2RoomActivationToken
        let actor: V2RoomClusterActor
        let generation: UInt64
    }
    private struct HostRecovery {
        let descriptorGeneration: UInt64
        var failures: Int
        var retryAt: ContinuousClock.Instant
    }
    private struct RecoveryResult: Sendable {
        let token: V2RoomActivationToken
        let response: V2ActorRPCResponse
    }
    private struct RecoveryWaiter {
        let continuation: CheckedContinuation<RecoveryResult, any Error>
        let timer: Task<Void, Never>
    }
    private struct RecoveryProbe {
        let id: UUID
        let token: V2RoomActivationToken
        let descriptorGeneration: UInt64
        let task: Task<Void, Never>
        let referenceRevision: UInt64
        var waiters: [UUID: RecoveryWaiter]
    }

    private func advanceDescriptorGeneration(_ host: V2ActorHostIdentity) {
        precondition(nextDescriptorGeneration < UInt64.max)
        nextDescriptorGeneration += 1
        descriptorGenerations[host] = nextDescriptorGeneration
    }

    private func isExplicitlyStale(_ failure: V2RoomCallFailure) -> Bool {
        switch failure {
        case .notAccepted(.staleActivation), .notAccepted(.retired), .notAccepted(.leaseLost),
             .rolledBack(.staleActivation), .rolledBack(.retired), .rolledBack(.leaseLost): true
        default: false
        }
    }

    private func beginReferenceInstall(_ token: V2RoomActivationToken) -> UInt64 {
        if referenceGenerations[token] == nil { advanceReferenceGeneration(token) }
        pendingReferenceInstalls[token, default: 0] += 1
        return referenceGenerations[token]!
    }
    private func endReferenceInstall(_ token: V2RoomActivationToken) {
        let remaining = pendingReferenceInstalls[token, default: 1] - 1
        if remaining == 0 {
            pendingReferenceInstalls.removeValue(forKey: token)
            if physicalReferences.actor(for: token) == nil { referenceGenerations.removeValue(forKey: token) }
        } else { pendingReferenceInstalls[token] = remaining }
    }
    private func advanceReferenceGeneration(_ token: V2RoomActivationToken) {
        precondition(nextReferenceGeneration < UInt64.max)
        nextReferenceGeneration += 1
        referenceGenerations[token] = nextReferenceGeneration
    }

    private func invalidateReference(_ snapshot: ReferenceSnapshot) {
        if referenceUsers[snapshot.generation] != nil { revokedReferences.insert(snapshot.generation) }
        guard referenceGenerations[snapshot.token] == snapshot.generation else { return }
        if pendingReferenceInstalls[snapshot.token] != nil { advanceReferenceGeneration(snapshot.token) }
        else { referenceGenerations.removeValue(forKey: snapshot.token) }
        physicalReferences.remove(snapshot.token)
    }

    private func noteTransportFailure(reference: ReferenceSnapshot?, host: V2ActorHostIdentity,
                                      descriptorGeneration: UInt64, recoveryRevision: UInt64) {
        if let reference {
            // A room proxy failure says nothing about other rooms on its host.
            // This is routing eviction, not revocation of already captured calls.
            guard referenceGenerations[reference.token] == reference.generation else { return }
            physicalReferences.remove(reference.token)
            if pendingReferenceInstalls[reference.token] != nil { advanceReferenceGeneration(reference.token) }
            else { referenceGenerations.removeValue(forKey: reference.token) }
        } else {
            markHostSuspect(host, descriptorGeneration: descriptorGeneration, recoveryRevision: recoveryRevision)
        }
    }

    private func markHostSuspect(_ host: V2ActorHostIdentity, descriptorGeneration: UInt64, recoveryRevision: UInt64) {
        guard accepting, descriptors[host] != nil,
              descriptorGenerations[host] == descriptorGeneration,
              hostRecoveryRevisions[host, default: 0] == recoveryRevision, hostRecovery[host] == nil else { return }
        hostRecovery[host] = .init(descriptorGeneration: descriptorGeneration, failures: 1,
                                   retryAt: .now + .milliseconds(100))
    }

    /// Only a failed business/control transport activates recovery. Healthy calls never probe.
    /// Different rooms share one host probe; their physical references remain token-specific.
    static func recoveryProbeDeadline(for callerDeadline: ContinuousClock.Instant,
                                      now: ContinuousClock.Instant = .now) -> ContinuousClock.Instant {
        min(callerDeadline, now + .seconds(3))
    }

    private func recoverHostIfNeeded(token: V2RoomActivationToken,
                                     deadline: ContinuousClock.Instant) async throws -> RecoveryResult? {
        let host = token.host
        guard let state = hostRecovery[host] else { return nil }
        guard accepting, descriptors[host] != nil, !suspendedHosts.contains(host),
              descriptorGenerations[host] == state.descriptorGeneration else {
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        guard ContinuousClock.now < deadline, !Task.isCancelled else {
            throw V2RoomCallFailure.notAccepted(Task.isCancelled ? .cancelled : .deadlineExceeded)
        }
        guard recoveryWaiterCount < configuration.maximumActivationWaitersPerHost else {
            throw V2RoomCallFailure.notAccepted(.overloaded)
        }
        if recoveryProbes[host] == nil {
            guard ContinuousClock.now >= state.retryAt else {
                throw V2RoomCallFailure.notAccepted(.unavailable)
            }
            let id = UUID()
            let generation = state.descriptorGeneration
            let referenceRevision = beginReferenceInstall(token)
            // A caller's cancellation only removes its waiter. The real probe remains owned.
            // Recovery must not pin an unreachable old Cluster.Node for the business
            // call timeout after its location waiter has already stopped waiting.
            // Native dispatch ownership is still retained through its actual exit.
            let probeDeadline = Self.recoveryProbeDeadline(for: deadline)
            let task = Task { [self] in
                let result: Result<V2ActorRPCResponse, any Error>
                do {
                    result = .success(try await exchange(.lookup(token), on: host,
                        principal: .service, deadline: probeDeadline, roomToken: nil))
                } catch { result = .failure(error) }
                finishRecoveryProbe(host: host, id: id, result: result)
            }
            recoveryProbes[host] = .init(id: id, token: token, descriptorGeneration: generation,
                                         task: task, referenceRevision: referenceRevision, waiters: [:])
            hostRecoveryProbes &+= 1
        } else { hostRecoveryWaits &+= 1 }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RecoveryResult, any Error>) in
                guard !Task.isCancelled, ContinuousClock.now < deadline else {
                    continuation.resume(throwing: V2RoomCallFailure.notAccepted(
                        Task.isCancelled ? .cancelled : .deadlineExceeded)); return
                }
                let timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                    await self?.removeRecoveryWaiter(host, id: waiterID, failure: .notAccepted(.deadlineExceeded))
                }
                recoveryProbes[host]?.waiters[waiterID] = .init(continuation: continuation, timer: timer)
                recoveryWaiterCount += 1
            }
        } onCancel: {
            Task { await self.removeRecoveryWaiter(host, id: waiterID, failure: .notAccepted(.cancelled)) }
        }
    }

    private func removeRecoveryWaiter(_ host: V2ActorHostIdentity, id: UUID, failure: V2RoomCallFailure) {
        guard let waiter = recoveryProbes[host]?.waiters.removeValue(forKey: id) else { return }
        recoveryWaiterCount -= 1; waiter.timer.cancel()
        waiter.continuation.resume(throwing: failure)
    }
    private func failRecoveryWaiters(_ host: V2ActorHostIdentity, failure: V2RoomCallFailure) {
        guard let waiters = recoveryProbes[host]?.waiters else { return }
        recoveryProbes[host]?.waiters.removeAll()
        recoveryWaiterCount -= waiters.count
        for waiter in waiters.values { waiter.timer.cancel(); waiter.continuation.resume(throwing: failure) }
    }
    private func finishRecoveryProbe(host: V2ActorHostIdentity, id: UUID,
                                     result: Result<V2ActorRPCResponse, any Error>) {
        guard let probe = recoveryProbes[host], probe.id == id else { return }
        recoveryProbes.removeValue(forKey: host)
        defer { endReferenceInstall(probe.token) }
        var delivered: Result<RecoveryResult, any Error>
        if !accepting || descriptorGenerations[host] != probe.descriptorGeneration {
            delivered = .failure(V2RoomCallFailure.notAccepted(.staleActivation))
        } else {
            switch result {
            case .success(let response):
                do {
                    if case .ready(let observed, let physical) = response {
                        guard observed == probe.token else { throw V2RoomCallFailure.notAccepted(.staleActivation) }
                        if referenceGenerations[observed] == probe.referenceRevision {
                            try rememberPhysical(physical, token: observed)
                        }
                    }
                    hostRecovery.removeValue(forKey: host)
                    hostRecoveryRevisions[host, default: 0] += 1
                    delivered = .success(.init(token: probe.token, response: response))
                } catch { delivered = .failure(error) }
            case .failure(let error): delivered = .failure(error)
            }
            if case .failure = delivered {
                let failures = min(5, (hostRecovery[host]?.failures ?? 1) + 1)
                hostRecovery[host] = .init(descriptorGeneration: probe.descriptorGeneration,
                    failures: failures, retryAt: .now + .milliseconds(min(1_000, 100 << (failures - 1))))
            }
        }
        recoveryWaiterCount -= probe.waiters.count
        for waiter in probe.waiters.values { waiter.timer.cancel(); waiter.continuation.resume(with: delivered) }
        pruneRetiredDescriptor(host)
        finishStopIfIdle()
    }

    private struct Session: Sendable {
        let grant: V2ActorSessionGrant
        let expires: ContinuousClock.Instant
        var nextSequence: UInt64
        let localCapability: V2ActorLocalCapability?
        let permit: V2RoomClusterBudget.Permit
    }

    private enum TransportReply: Sendable {
        case signed(V2ActorSignedPacket)
        case local(V2ActorLocalPayload<V2ActorAuthenticatedReply>)
    }

    private struct HandshakeWaiter {
        let continuation: CheckedContinuation<Session, any Error>
        let timer: Task<Void, Never>
    }

    private struct RecoveryStageState {
        var starts: [UUID: ContinuousClock.Instant] = [:]
        var started: UInt64 = 0
        var completed: UInt64 = 0
        var totalMilliseconds: Double = 0
        var maxMilliseconds: Double = 0
        var itemsStarted: UInt64 = 0
    }

    private struct DispatchedCall {
        let host: V2ActorHostIdentity
        let completion: V2RoomRPCCompletion<TransportReply>
        let timer: Task<Void, Never>
        let permit: V2RoomClusterBudget.Permit
        let recoveryPermit: V2RoomClusterBudget.Permit?
        let recoveryBatch: Bool
        let renewalBatch: Bool
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
