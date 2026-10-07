import Distributed
import DistributedCluster
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core

/// Implementations return only after the room's actual revocation transaction
/// commits. The Cluster layer authenticates callers and exact signed replies.
public protocol V2RoomPolicyRevocationServing: Sendable {
    func revokePolicyAuthorization(_ target: V2RoomPolicyRevocationWire, deadline: ContinuousClock.Instant) async throws -> V2RoomPolicyRevocationWire
}

public enum V2PolicyMutationServiceError: Error, Sendable { case identityConflict }

public protocol V2PolicyMutationServing: Sendable {
    func mutatePolicy(_ request: V2PolicyMutationWire, deadline: ContinuousClock.Instant) async throws -> V2PolicyMutationReceiptWire
}

public protocol V2PolicyOwnershipServing: Sendable {
    func policySnapshots(_ request: V2PolicySnapshotRequestWire, deadline: ContinuousClock.Instant) async throws -> [V2PolicySnapshotWire]
    func updatePolicySnapshot(_ request: V2PolicySnapshotUpdateWire, deadline: ContinuousClock.Instant) async throws
    func claimPolicyOwnership(_ request: V2PolicyOwnershipClaimWire, deadline: ContinuousClock.Instant) async throws -> [V2PolicyOwnerStateWire]
    func invalidatePolicyCache(_ request: V2PolicyCacheInvalidationWire, deadline: ContinuousClock.Instant) async throws
}
extension V2PolicyOwnershipServing {
    public func policySnapshots(_ request: V2PolicySnapshotRequestWire, deadline: ContinuousClock.Instant) async throws -> [V2PolicySnapshotWire] {
        throw V2RoomCallFailure.notAccepted(.unavailable)
    }
    public func updatePolicySnapshot(_ request: V2PolicySnapshotUpdateWire, deadline: ContinuousClock.Instant) async throws {
        throw V2RoomCallFailure.notAccepted(.unavailable)
    }
    public func invalidatePolicyCache(_ request: V2PolicyCacheInvalidationWire, deadline: ContinuousClock.Instant) async throws {
        throw V2RoomCallFailure.notAccepted(.unavailable)
    }
}

/// The host owns reservations and their physical SQL completion. Callers never
/// provide reservation grants or classify the remote transaction's outcome.
public protocol V2RoomForwardPairServing: Sendable {
    func forwardPair(_ pair: V2ActorForwardPairWire, token: V2RoomActivationToken,
        deadline: ContinuousClock.Instant) async throws -> V2ActorForwardMessageResultWire
}

/// 房间激活前唯一的分布式入口。其 ActorID 通过已认证的配置带外分发。
public distributed actor V2RoomHostEndpoint {
    public typealias ActorSystem = ClusterSystem
    private let service: V2RoomClusterInboundService

    public init(actorSystem: ClusterSystem, service: V2RoomClusterInboundService) {
        self.actorSystem = actorSystem
        self.service = service
    }

    public distributed func openSession(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        try await service.openSession(packet)
    }

    public distributed func exchange(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        try await service.exchange(packet, boundToken: nil)
    }
}

/// 每个本地就绪的激活对应一个物理分布式 Actor。
/// 精确令牌退役后，其身份不再拥有权限，
/// 即使远程进程仍保留该 ActorID。
public distributed actor V2RoomClusterActor {
    public typealias ActorSystem = ClusterSystem
    private let token: V2RoomActivationToken
    private let service: V2RoomClusterInboundService

    public init(actorSystem: ClusterSystem, token: V2RoomActivationToken,
                service: V2RoomClusterInboundService) {
        self.actorSystem = actorSystem
        self.token = token
        self.service = service
    }

    public distributed func exchange(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        try await service.exchange(packet, boundToken: token)
    }
}

/// 远程报文与节点创建的本地能力共用权限、重放、分片、接收方、
/// 会话、截止时间和精确激活检查。
/// Cluster 成员关系绝不构成授权事实。
public actor V2RoomClusterInboundService {
    private let identity: V2ActorHostIdentity
    private let host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>
    private let authenticator: V2ActorSessionAuthenticator
    private let signer: V2ActorSigningIdentity
    private let limits: V2ActorAuthenticationLimits
    private let allowedShards: Set<String>
    private let serviceShardAccess: [V2ActorServiceID: Set<String>]
    private let policyRevocations: (any V2RoomPolicyRevocationServing)?
    private let policyMutations: (any V2PolicyMutationServing)?
    private let policyOwnership: (any V2PolicyOwnershipServing)?
    private let forwardPairs: (any V2RoomForwardPairServing)?
    private let maximumInboundRequests: Int
    private let localGeneration: UUID
    private let actorSystem: ClusterSystem
    private var roomActors: [V2RoomActivationToken: V2RoomClusterActor] = [:]
    private var watcher: Task<Void, Never>?
    private var accepting = true
    private var activeRequests = 0
    private var batchAdmission: V2RoomBatchAdmission

    public init(identity: V2ActorHostIdentity,
                host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>,
                authenticator: V2ActorSessionAuthenticator,
                signer: V2ActorSigningIdentity,
                limits: V2ActorAuthenticationLimits,
                allowedShards: Set<String>,
                serviceShardAccess: [V2ActorServiceID: Set<String>],
                maximumInboundRequests: Int,
                localGeneration: UUID = UUID(),
                actorSystem: ClusterSystem,
                policyRevocations: (any V2RoomPolicyRevocationServing)? = nil,
                policyOwnership: (any V2PolicyOwnershipServing)? = nil,
                policyMutations: (any V2PolicyMutationServing)? = nil,
                forwardPairs: (any V2RoomForwardPairServing)? = nil) throws {
        guard !allowedShards.isEmpty, !serviceShardAccess.isEmpty,
              maximumInboundRequests > 0,
              serviceShardAccess.values.allSatisfy({ !$0.isEmpty && $0.isSubset(of: allowedShards) })
        else { throw V2ActorAuthenticationError.invalidConfiguration }
        self.identity = identity
        self.host = host
        self.authenticator = authenticator
        self.signer = signer
        self.limits = limits
        self.allowedShards = allowedShards
        self.serviceShardAccess = serviceShardAccess
        self.policyRevocations = policyRevocations
        self.policyOwnership = policyOwnership
        self.policyMutations = policyMutations
        self.forwardPairs = forwardPairs
        self.maximumInboundRequests = maximumInboundRequests
        self.batchAdmission = .init(maximumRenewalBatches: min(maximumInboundRequests, serviceShardAccess.count * 2))
        self.localGeneration = localGeneration
        self.actorSystem = actorSystem
    }

    public func startWatching() async {
        guard watcher == nil else { return }
        let changes = await host.changes()
        guard accepting, watcher == nil else { return }
        watcher = Task { [weak self] in
            for await _ in changes { await self?.reconcileActors() }
        }
    }

    public func stop() {
        accepting = false
        watcher?.cancel()
        watcher = nil
        roomActors.removeAll()
    }

    public func quiesce(deadline: ContinuousClock.Instant) async -> Bool {
        accepting = false
        while activeRequests > 0 && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { break }
        }
        return activeRequests == 0
    }

    public func openSession(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        try beginRequest()
        defer { activeRequests -= 1 }
        let grant = try await authenticator.openSession(packet)
        guard accepting else { throw V2ActorAuthenticationError.overloaded }
        return try signer.sign(grant, maximumBytes: limits.maximumReplyBytes)
    }

    func openLocalSession(_ packet: V2ActorSignedPacket, generation: UUID) async throws
        -> (V2ActorSignedPacket, V2ActorLocalCapability) {
        try beginRequest()
        defer { activeRequests -= 1 }
        guard generation == localGeneration else { throw V2ActorAuthenticationError.wrongRecipient }
        let (grant, capability) = try await authenticator.openLocalSession(packet, generation: generation)
        guard accepting else { throw V2ActorAuthenticationError.overloaded }
        return (try signer.sign(grant, maximumBytes: limits.maximumReplyBytes), capability)
    }

    public func exchange(_ packet: V2ActorSignedPacket,
                         boundToken: V2RoomActivationToken?) async throws -> V2ActorSignedPacket {
        let receivedAt = ContinuousClock.now
        try beginRequest()
        defer { activeRequests -= 1 }
        let verified = try await authenticator.accept(packet)
        if isBoundedBatch(verified.call.request), packet.body.count > 65_536 {
            throw V2ActorAuthenticationError.oversized
        }
        let reply = try await exchangeTracedVerified(verified, boundToken: boundToken, receivedAt: receivedAt)
        let maximumBytes: Int
        if isBoundedBatch(verified.call.request) { maximumBytes = min(262_144, limits.maximumReplyBytes) }
        else { maximumBytes = limits.maximumReplyBytes }
        return try signer.sign(reply, maximumBytes: maximumBytes)
    }

    func exchangeLocal(_ payload: V2ActorLocalPayload<V2ActorAuthenticatedCall>,
                       capability: V2ActorLocalCapability, generation: UUID,
                       boundToken: V2RoomActivationToken?) async throws
        -> V2ActorLocalPayload<V2ActorAuthenticatedReply> {
        let receivedAt = ContinuousClock.now
        try beginRequest()
        defer { activeRequests -= 1 }
        guard generation == localGeneration else { throw V2ActorAuthenticationError.wrongRecipient }
        let verified = try await authenticator.acceptLocal(payload, capability: capability,
                                                           generation: generation)
        if isBoundedBatch(verified.call.request), payload.byteCount > 65_536 {
            throw V2ActorAuthenticationError.oversized
        }
        let reply = try await exchangeTracedVerified(verified, boundToken: boundToken, receivedAt: receivedAt)
        let encoded = try V2ActorLocalPayload(reply)
        let maximumBytes: Int
        if isBoundedBatch(verified.call.request) { maximumBytes = min(262_144, limits.maximumReplyBytes) }
        else { maximumBytes = limits.maximumReplyBytes }
        guard encoded.byteCount <= maximumBytes else { throw V2ActorAuthenticationError.oversized }
        return encoded
    }

    private func exchangeTracedVerified(_ verified: V2ActorVerifiedCall,
        boundToken: V2RoomActivationToken?, receivedAt: ContinuousClock.Instant) async throws -> V2ActorAuthenticatedReply {
        guard V2SendPathTrace.enabled else {
            return try await exchangeVerified(verified, boundToken: boundToken)
        }
        let trace: V2SendPathTrace
        switch verified.call.request {
        case .invoke(_, .messaging(.sendOperation(let command))):
            guard let operation = try? command.identity.operation.rawOperationID else {
                return try await exchangeVerified(verified, boundToken: boundToken)
            }
            trace = V2SendPathTrace(operations: [operation], segment: "room_rpc")
        case .policySnapshots:
            // Correlate to the caller's bounded trace marker using the existing
            // authenticated trace ID; no account or scope identifier is logged.
            trace = V2SendPathTrace(operations: [verified.call.traceID.uuidString], segment: "policy_rpc")
        default:
            return try await exchangeVerified(verified, boundToken: boundToken)
        }
        trace.record("receiver_authentication", from: receivedAt)
        if let enteredAt = verified.authenticationEnteredAt,
           let returnedAt = verified.authenticationReturnedAt {
            trace.record("receiver_auth_actor_entry_wait", from: receivedAt, to: enteredAt)
            trace.record("receiver_auth_body", from: enteredAt, to: returnedAt)
            trace.record("receiver_auth_resume_wait", from: returnedAt)
        }
        defer { trace.finish() }
        return try await V2SendPathTrace.$current.withValue(trace) {
            trace.mark("receiver_dispatch")
            let reply = try await exchangeVerified(verified, boundToken: boundToken)
            trace.mark("receiver_result_ready")
            return reply
        }
    }

    private func exchangeVerified(_ verified: V2ActorVerifiedCall,
                                  boundToken: V2RoomActivationToken?) async throws -> V2ActorAuthenticatedReply {
        guard accepting else { throw V2ActorAuthenticationError.overloaded }
        let request = verified.call.request
        let token = requestToken(request)
        if let boundToken {
            guard token == boundToken, !isHostOnly(request) else {
                throw V2ActorAuthenticationError.wrongRecipient
            }
        } else {
            guard isHostOnly(request) else { throw V2ActorAuthenticationError.wrongRecipient }
        }
        let shards: Set<String>
        if case .subscriptionRenewBatch(let items) = request { shards = Set(items.map { $0.token.owner.shardID }) }
        else if case .recoveryBatch(let items) = request { shards = Set(items.map { $0.token.owner.shardID }) }
        else if case .revokePolicyAuthorization(let target) = request,
                target.endpoint.hasPrefix(V2RoomPolicyEndpointLocator.prefix) {
            guard let locator = try? V2RoomPolicyEndpointLocator(encoded: target.endpoint),
                  identity.hostID == .init(uuid: locator.hostID) else {
                throw V2ActorAuthenticationError.forbidden
            }
            shards = [locator.shardID]
        }
        else { shards = [requestShard(request)] }
        guard shards.isSubset(of: allowedShards),
              shards.isSubset(of: serviceShardAccess[verified.call.serviceID] ?? []) else {
            throw V2ActorAuthenticationError.forbidden
        }
        let batchKind: V2RoomBatchAdmission.Kind?
        switch request {
        case .subscriptionRenewBatch: batchKind = .renewal
        case .recoveryBatch: batchKind = .recovery
        default: batchKind = nil
        }
        if let batchKind {
            guard batchAdmission.acquire(batchKind, peer: verified.call.serviceID) else {
                return .init(call: verified.call, response: .failure(.notAccepted(.overloaded)))
            }
        }
        defer {
            if let batchKind { batchAdmission.release(batchKind, peer: verified.call.serviceID) }
        }
        let response: V2ActorRPCResponse
        do { response = try await dispatch(request, deadline: verified.deadline) }
        catch let failure as V2RoomCallFailure { response = .failure(failure) }
        catch let leaseError as V2RoomActivationLeaseError where leaseError == .roomNotFound {
            response = .failure(.notAccepted(.notFound))
        } catch {
            // 调用可能已进入 SQL。不能依据此处捕获的错误
            // 虚构回滚或确定未被接受的结果。
            if case .lookup = request { response = .failure(.notAccepted(.unavailable)) }
            else { response = .failure(.outcomeUnknown) }
        }
        return V2ActorAuthenticatedReply(call: verified.call, response: response)
    }

    public func reconcileActors() async {
        // Capture installations before yielding. A stale observer must not
        // remove an actor installed for the same token during this await.
        let installed = roomActors.map { (token: $0.key, actorID: $0.value.id) }
        let ready = Set(await host.readyTokens())
        guard accepting else { return }
        for installation in installed where !ready.contains(installation.token) {
            removePhysicalReference(for: installation.token, actorID: installation.actorID)
        }
        // References are created on demand. Reconciliation owns retirement,
        // not business activation or eager recreation from an old snapshot.
    }

    @discardableResult
    func removePhysicalReference(for token: V2RoomActivationToken,
                                 actorID: ClusterSystem.ActorID) -> Bool {
        guard roomActors[token]?.id == actorID else { return false }
        roomActors.removeValue(forKey: token)
        return true
    }

    public func actorCount() -> Int { roomActors.count }

    public func inFlightRequestCount() -> Int { activeRequests }

    private func beginRequest() throws {
        guard accepting, activeRequests < maximumInboundRequests else {
            throw V2ActorAuthenticationError.overloaded
        }
        activeRequests += 1
    }

    func physicalReference(for token: V2RoomActivationToken) async throws -> Data {
        guard accepting, token.host == identity, await host.isReady(token: token), accepting else {
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        if roomActors[token] == nil {
            roomActors[token] = V2RoomClusterActor(actorSystem: actorSystem, token: token, service: self)
        }
        guard let actor = roomActors[token] else {
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        // Retain this precise installation across readiness's actor hop. Even
        // same-token reconstruction must not be deleted by this old attempt.
        let ready = await host.isReady(token: token)
        guard ready, accepting, roomActors[token]?.id == actor.id else {
            removePhysicalReference(for: token, actorID: actor.id)
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        return try JSONEncoder().encode(actor.id)
    }

    private func dispatch(_ request: V2ActorRPCRequest,
                          deadline: ContinuousClock.Instant) async throws -> V2ActorRPCResponse {
        switch request {
        case .forwardPair(let token, let pair):
            guard let forwardPairs else { throw V2RoomCallFailure.notAccepted(.unavailable) }
            guard await host.isReady(token: token) else { throw V2RoomCallFailure.notAccepted(.staleActivation) }
            let result = try await forwardPairs.forwardPair(pair, token: token, deadline: deadline)
            guard result.sourceMessageID == pair.source.messageID, result.targetRoomID == pair.targetRoomID else {
                throw V2RoomCallFailure.outcomeUnknown
            }
            return .forwardPair(result)
        case .mutatePolicy(let mutation):
            guard let policyMutations else { throw V2RoomCallFailure.notAccepted(.unavailable) }
            let receipt: V2PolicyMutationReceiptWire
            do { receipt = try await policyMutations.mutatePolicy(mutation, deadline: deadline) }
            catch V2PolicyMutationServiceError.identityConflict { return .policyMutationIdentityConflict(mutation) }
            guard receipt.matches(mutation) else { throw V2RoomCallFailure.outcomeUnknown }
            return .policyMutationCommitted(receipt)
        case .policySnapshots(let request):
            guard let policyOwnership else { throw V2RoomCallFailure.notAccepted(.unavailable) }
            let states = try await policyOwnership.policySnapshots(request, deadline: deadline)
            guard states.count == request.scopes.count, Set(states.map { $0.scope.key }) == Set(request.scopes.map(\.key)) else {
                throw V2RoomCallFailure.outcomeUnknown
            }
            return .policySnapshots(states)
        case .updatePolicySnapshot(let request):
            guard let policyOwnership else { throw V2RoomCallFailure.notAccepted(.unavailable) }
            try await policyOwnership.updatePolicySnapshot(request, deadline: deadline)
            return .acknowledged
        case .invalidatePolicyCache(let request):
            guard let policyOwnership else { throw V2RoomCallFailure.notAccepted(.unavailable) }
            try await policyOwnership.invalidatePolicyCache(request, deadline: deadline)
            return .acknowledged
        case .claimPolicyOwnership(let claim):
            guard let policyOwnership else { throw V2RoomCallFailure.notAccepted(.unavailable) }
            let leases = try await policyOwnership.claimPolicyOwnership(claim, deadline: deadline)
            if claim.cachedOnly && leases.isEmpty { return .policyOwnership([]) }
            guard leases.count == claim.scopes.count, Set(leases.map { $0.owner.scope.key }) == Set(claim.scopes.map(\.key)) else {
                throw V2RoomCallFailure.outcomeUnknown
            }
            return .policyOwnership(leases)
        case .revokePolicyAuthorization(let target):
            guard let policyRevocations else { throw V2RoomCallFailure.notAccepted(.unavailable) }
            let result = try await policyRevocations.revokePolicyAuthorization(target, deadline: deadline)
            guard result == target else { throw V2RoomCallFailure.outcomeUnknown }
            return .policyAuthorizationRevoked(result)
        case .activate(let roomID, let owner):
            let resolution = try await host.activate(roomID: roomID, owner: owner, deadline: deadline)
            switch resolution {
            case .ready(let token):
                guard token.roomID == roomID, token.owner == owner, token.host == identity else {
                    throw V2RoomCallFailure.notAccepted(.staleActivation)
                }
                return .ready(token: token, physicalReference: try await physicalReference(for: token))
            case .occupied(let lease):
                guard lease.token.roomID == roomID, lease.token.owner == owner else {
                    throw V2RoomCallFailure.notAccepted(.staleActivation)
                }
                return .occupied(lease)
            }
        case .lookup(let token):
            return .ready(token: token, physicalReference: try await physicalReference(for: token))
        case .invoke(let token, let request):
            V2SendPathTrace.current?.mark("receiver_invoke_enter")
            let bytes: Data
            do { bytes = try JSONEncoder().encode(request) }
            catch { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
            V2SendPathTrace.current?.mark("receiver_host_dispatch")
            let result = try await host.invoke(token: token, encodedRequest: bytes, deadline: deadline)
            V2SendPathTrace.current?.mark("receiver_host_return")
            return .result(result)
        case .subscriptionRenewBatch(let items):
            // Bounded same-host fanout enters ordinary room lanes; the physical
            // lease-proof broker coalesces their reads without bypassing fencing.
            let results = await withTaskGroup(of: (Int, V2RoomSubscriptionRenewBatchOutcome).self) { group in
                for (index, item) in items.enumerated() {
                    group.addTask { [host] in
                        do {
                            let bytes = try JSONEncoder().encode(V2RoomRequest.roomSubscription(.renew(item.command)))
                            let reply = try await host.invoke(token: item.token, encodedRequest: bytes, deadline: deadline)
                            guard case .roomSubscription(let result) = reply else { throw V2RoomCallFailure.outcomeUnknown }
                            return (index, .init(token: item.token, outcome: .result(result)))
                        } catch let failure as V2RoomCallFailure {
                            return (index, .init(token: item.token, outcome: .failure(failure)))
                        } catch { return (index, .init(token: item.token, outcome: .failure(.outcomeUnknown))) }
                    }
                }
                var ordered: [(Int, V2RoomSubscriptionRenewBatchOutcome)] = []
                for await result in group { ordered.append(result) }
                return ordered.sorted { $0.0 < $1.0 }.map { $0.1 }
            }
            return .subscriptionRenewBatch(results)
        case .recoveryBatch(let items):
            let local = items.map { V2RoomRecoveryBatchCallItem(token: $0.token, query: $0.query, deadline: deadline) }
            return .recoveryBatch(await host.invokeRecoveryBatch(items: local, deadline: deadline))
        case .reserve(let token, let requestID):
            return .reserved(try await host.reserve(token: token, requestID: requestID, deadline: deadline))
        case .markDispatched(let grant):
            try await host.markReservationDispatched(grant)
            return .acknowledged
        case .abortReservation(let grant):
            return .completed(await host.abortReservation(grant))
        case .finishReservation(let grant, let completion):
            return .completed(await host.finishReservation(grant, completion: completion))
        }
    }

    private func isBoundedBatch(_ request: V2ActorRPCRequest) -> Bool {
        switch request { case .recoveryBatch, .subscriptionRenewBatch: true; default: false }
    }

    private func requestToken(_ request: V2ActorRPCRequest) -> V2RoomActivationToken? {
        switch request {
        case .activate, .recoveryBatch, .subscriptionRenewBatch, .revokePolicyAuthorization, .claimPolicyOwnership, .mutatePolicy, .invalidatePolicyCache, .policySnapshots, .updatePolicySnapshot: nil
        case .lookup(let token), .invoke(let token, _), .reserve(let token, _): token
        case .forwardPair(let token, _): token
        case .markDispatched(let grant), .abortReservation(let grant), .finishReservation(let grant, _): grant.token
        }
    }

    private func requestShard(_ request: V2ActorRPCRequest) -> String {
        switch request {
        case .policySnapshots(let request): request.endpoint
        case .updatePolicySnapshot(let request): request.endpoint
        case .claimPolicyOwnership(let claim): claim.endpoint
        case .invalidatePolicyCache(let request): request.endpoint
        case .forwardPair(let token, _): token.owner.shardID
        case .mutatePolicy(let mutation): mutation.endpoint
        case .revokePolicyAuthorization(let target): target.endpoint
        case .activate(_, let owner): owner.shardID
        case .recoveryBatch, .subscriptionRenewBatch: "" // Handled as the complete shard set before dispatch.
        case .lookup(let token), .invoke(let token, _), .reserve(let token, _): token.owner.shardID
        case .markDispatched(let grant), .abortReservation(let grant), .finishReservation(let grant, _):
            grant.token.owner.shardID
        }
    }

    private func isHostOnly(_ request: V2ActorRPCRequest) -> Bool {
        switch request {
        case .activate, .lookup, .recoveryBatch, .subscriptionRenewBatch, .revokePolicyAuthorization, .claimPolicyOwnership, .mutatePolicy, .invalidatePolicyCache, .policySnapshots, .updatePolicySnapshot, .forwardPair: true
        default: false
        }
    }
}

/// Actor-owned admission. SQL recovery cannot consume lease-maintenance slots.
/// Renewal capacity is bounded by configured authenticated peers and the outer
/// request limit; each peer can hold at most two batches of at most 64 rooms.
struct V2RoomBatchAdmission {
    enum Kind: Hashable { case recovery, renewal }
    private struct Key: Hashable { let kind: Kind; let peer: V2ActorServiceID }
    private let maximumRenewalBatches: Int
    private var active: [Kind: Int] = [:]
    private var peers: [Key: Int] = [:]
    init(maximumRenewalBatches: Int) { self.maximumRenewalBatches = maximumRenewalBatches }
    mutating func acquire(_ kind: Kind, peer: V2ActorServiceID) -> Bool {
        let key = Key(kind: kind, peer: peer)
        let limit = kind == .recovery ? 4 : maximumRenewalBatches
        guard active[kind, default: 0] < limit, peers[key, default: 0] < 2 else { return false }
        active[kind, default: 0] += 1; peers[key, default: 0] += 1
        return true
    }
    mutating func release(_ kind: Kind, peer: V2ActorServiceID) {
        let key = Key(kind: kind, peer: peer)
        precondition(peers[key, default: 0] > 0)
        active[kind, default: 0] -= 1
        let remaining = peers[key, default: 1] - 1
        if remaining == 0 { peers.removeValue(forKey: key) } else { peers[key] = remaining }
    }
}
