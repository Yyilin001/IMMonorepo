import Distributed
import DistributedCluster
import Foundation
import Synchronization
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core

/// Implementations return only after the room's actual revocation transaction
/// commits. The Cluster layer authenticates callers and exact signed replies.
public enum V2PolicyMutationServiceError: Error, Sendable { case identityConflict }

public protocol V2PolicyMutationServing: Sendable {
    func mutatePolicy(_ request: V2PolicyMutationWire, deadline: ContinuousClock.Instant) async throws -> V2PolicyMutationReceiptWire
}

public protocol V2PolicyOwnershipServing: Sendable {
    func policySnapshots(_ request: V2PolicySnapshotRequestWire, deadline: ContinuousClock.Instant) async throws -> V2PolicySnapshotBatchWire
    func updatePolicySnapshot(_ request: V2PolicySnapshotUpdateWire, deadline: ContinuousClock.Instant) async throws
    func releasePolicyInterests(_ request: V2PolicyInterestReleaseWire, deadline: ContinuousClock.Instant) async throws
}
extension V2PolicyOwnershipServing {
    public func policySnapshots(_ request: V2PolicySnapshotRequestWire, deadline: ContinuousClock.Instant) async throws -> V2PolicySnapshotBatchWire {
        throw V2RoomCallFailure.notAccepted(.unavailable)
    }
    public func releasePolicyInterests(_ request: V2PolicyInterestReleaseWire, deadline: ContinuousClock.Instant) async throws {
        throw V2RoomCallFailure.notAccepted(.unavailable)
    }
    public func updatePolicySnapshot(_ request: V2PolicySnapshotUpdateWire, deadline: ContinuousClock.Instant) async throws {
        throw V2RoomCallFailure.notAccepted(.unavailable)
    }

}

/// The host owns reservations and their physical SQL completion. Callers never
/// provide reservation grants or classify the remote transaction's outcome.
public protocol V2RoomForwardPairServing: Sendable {
    func forwardPair(_ pair: V2ActorForwardPairWire, token: V2RoomActivationToken,
        deadline: ContinuousClock.Instant) async throws -> V2ActorForwardMessageResultWire
}

/// Independent control and room services share only the authenticated endpoint
/// shape. A control service owns its own admission and lifecycle budget.
public protocol V2ActorHostInboundServing: Sendable {
    func openSession(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket
    func exchange(_ packet: V2ActorSignedPacket, boundToken: V2RoomActivationToken?) async throws -> V2ActorSignedPacket
}

/// 已认证的控制／房间 RPC 入口。ActorID 通过可信发现或配置分发。
public distributed actor V2RoomHostEndpoint {
    public typealias ActorSystem = ClusterSystem
    private let service: any V2ActorHostInboundServing

    public init(actorSystem: ClusterSystem, service: any V2ActorHostInboundServing) {
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
public actor V2RoomClusterInboundService: V2ActorHostInboundServing {
    private let identity: V2ActorHostIdentity
    private let host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>
    private let authenticator: V2ActorSessionAuthenticator
    private let signer: V2ActorSigningIdentity
    private let limits: V2ActorAuthenticationLimits
    private let allowedShards: Set<String>
    private let serviceShardAccess: [V2ActorServiceID: Set<String>]
    private let policyMutations: (any V2PolicyMutationServing)?
    private let policyOwnership: (any V2PolicyOwnershipServing)?
    private let forwardPairs: (any V2RoomForwardPairServing)?
    private let placementDrain: (any V2ActorPlacementDraining)?
    private let maximumInboundRequests: Int
    private let localGeneration: UUID
    private let actorSystem: ClusterSystem
    private struct RoomActorEntry {
        let token: V2RoomActivationToken
        let actor: V2RoomClusterActor
    }
    private var roomActors: [RoomID: RoomActorEntry] = [:]
    private var changeFeed: V2RoomActivationChangeFeed?
    private var watcherStarting = false
    private var watcherStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var watcher: Task<Void, Never>?
    private var accepting = true
    private struct RequestAdmission: Sendable {
        var accepting = true
        var active = 0
    }
    private nonisolated let requestAdmission = Mutex(RequestAdmission())
    private nonisolated let batchAdmission: Mutex<V2RoomBatchAdmission>

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
                policyOwnership: (any V2PolicyOwnershipServing)? = nil,
                policyMutations: (any V2PolicyMutationServing)? = nil,
                forwardPairs: (any V2RoomForwardPairServing)? = nil,
                placementDrain: (any V2ActorPlacementDraining)? = nil) throws {
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
        self.policyOwnership = policyOwnership
        self.policyMutations = policyMutations
        self.forwardPairs = forwardPairs
        self.placementDrain = placementDrain
        self.maximumInboundRequests = maximumInboundRequests
        self.batchAdmission = Mutex(.init())
        self.localGeneration = localGeneration
        self.actorSystem = actorSystem
    }

    public func startWatching() async {
        guard accepting else { return }
        if watcherStarting {
            await withCheckedContinuation { watcherStartWaiters.append($0) }
            return
        }
        guard watcher == nil else { return }
        watcherStarting = true
        defer {
            watcherStarting = false
            let waiters = watcherStartWaiters; watcherStartWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        let changes = await host.changes()
        guard accepting, watcher == nil else {
            await host.stopObservingChanges(observerID: changes.id)
            return
        }
        changeFeed = changes
        watcher = Task { [weak self] in
            for await _ in changes.wakes { await self?.reconcileChanges(changes) }
        }
    }

    public func stop() async {
        accepting = false
        requestAdmission.withLock { $0.accepting = false }
        if watcherStarting { await withCheckedContinuation { watcherStartWaiters.append($0) } }
        let actual = watcher, feed = changeFeed
        actual?.cancel()
        if let feed { await host.stopObservingChanges(observerID: feed.id) }
        await actual?.value
        watcher = nil; changeFeed = nil
        roomActors.removeAll()
    }

    public func quiesce(deadline: ContinuousClock.Instant) async -> Bool {
        accepting = false
        requestAdmission.withLock { $0.accepting = false }
        while inFlightRequestCount() > 0 && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { break }
        }
        return inFlightRequestCount() == 0
    }

    public func openSession(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        try beginRequest()
        defer { endRequest() }
        let grant = try authenticator.openSession(packet)
        guard accepting else { throw V2ActorAuthenticationError.overloaded }
        return try signer.sign(grant, maximumBytes: limits.maximumReplyBytes)
    }

    func openLocalSession(_ packet: V2ActorSignedPacket, generation: UUID) async throws
        -> (V2ActorSignedPacket, V2ActorLocalCapability) {
        try beginRequest()
        defer { endRequest() }
        guard generation == localGeneration else { throw V2ActorAuthenticationError.wrongRecipient }
        let (grant, capability) = try authenticator.openLocalSession(packet, generation: generation)
        guard accepting else { throw V2ActorAuthenticationError.overloaded }
        return (try signer.sign(grant, maximumBytes: limits.maximumReplyBytes), capability)
    }

    public nonisolated(nonsending) func exchange(_ packet: V2ActorSignedPacket,
                         boundToken: V2RoomActivationToken?) async throws -> V2ActorSignedPacket {
        let receivedAt = ContinuousClock.now
        try beginRequest()
        defer { endRequest() }
        let verified = try authenticator.accept(packet)
        if isBoundedBatch(verified.call.request), packet.body.count > 65_536 {
            throw V2ActorAuthenticationError.oversized
        }
        let reply = try await exchangeTracedVerified(verified, boundToken: boundToken, receivedAt: receivedAt)
        let maximumBytes: Int
        if isBoundedBatch(verified.call.request) { maximumBytes = min(262_144, limits.maximumReplyBytes) }
        else { maximumBytes = limits.maximumReplyBytes }
        if let mac = verified.sessionMAC { return try mac.seal(reply, reply: true, maximumBytes: maximumBytes) }
        return try signer.sign(reply, maximumBytes: maximumBytes)
    }

    nonisolated(nonsending) func exchangeLocal(_ payload: V2ActorLocalPayload<V2ActorAuthenticatedCall>,
                       capability: V2ActorLocalCapability, generation: UUID,
                       boundToken: V2RoomActivationToken?) async throws
        -> V2ActorLocalPayload<V2ActorAuthenticatedReply> {
        let receivedAt = ContinuousClock.now
        try beginRequest()
        defer { endRequest() }
        guard generation == localGeneration else { throw V2ActorAuthenticationError.wrongRecipient }
        let verified = try authenticator.acceptLocal(payload, capability: capability,
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

    private nonisolated(nonsending) func exchangeTracedVerified(_ verified: V2ActorVerifiedCall,
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
            guard V2SendPathTrace.shouldCollect(operations: [operation]) else {
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
            trace.record("receiver_auth_entry_wait", from: receivedAt, to: enteredAt)
            trace.record("receiver_auth_body", from: enteredAt, to: returnedAt)
            trace.record("receiver_auth_return_gap", from: returnedAt)
        }
        defer { trace.finish() }
        return try await V2SendPathTrace.$current.withValue(trace) {
            trace.mark("receiver_dispatch")
            let reply = try await exchangeVerified(verified, boundToken: boundToken)
            trace.mark("receiver_result_ready")
            return reply
        }
    }

    private nonisolated(nonsending) func exchangeVerified(_ verified: V2ActorVerifiedCall,
                                  boundToken: V2RoomActivationToken?) async throws -> V2ActorAuthenticatedReply {
        guard requestAdmission.withLock({ $0.accepting }) else { throw V2ActorAuthenticationError.overloaded }
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
        if case .recoveryBatch(let items) = request { shards = Set(items.map { $0.token.owner.shardID }) }
        else { shards = [requestShard(request)] }
        guard shards.isSubset(of: allowedShards),
              shards.isSubset(of: serviceShardAccess[verified.call.serviceID] ?? []) else {
            throw V2ActorAuthenticationError.forbidden
        }
        let batchKind: V2RoomBatchAdmission.Kind?
        switch request {
        case .recoveryBatch: batchKind = .recovery
        default: batchKind = nil
        }
        if let batchKind {
            guard batchAdmission.withLock({ $0.acquire(batchKind, peer: verified.call.serviceID) }) else {
                return .init(call: verified.call, response: .failure(.notAccepted(.overloaded)))
            }
        }
        defer {
            if let batchKind { batchAdmission.withLock { $0.release(batchKind, peer: verified.call.serviceID) } }
        }
        let response: V2ActorRPCResponse
        do {
            if case .invoke(let token, let invocation) = request {
                response = try await invokeRoom(token: token, request: invocation, deadline: verified.deadline)
            } else {
                response = try await dispatch(request, deadline: verified.deadline)
            }
        }
        catch let failure as V2RoomCallFailure { response = .failure(failure) }
        catch let leaseError as V2RoomActorStateError where leaseError == .roomNotFound {
            response = .failure(.notAccepted(.notFound))
        } catch {
            // 调用可能已进入 SQL。不能依据此处捕获的错误
            // 虚构回滚或确定未被接受的结果。
            if case .lookup = request { response = .failure(.notAccepted(.unavailable)) }
            else { response = .failure(.outcomeUnknown) }
        }
        return V2ActorAuthenticatedReply(call: verified.call, response: response)
    }

    private func reconcileChanges(_ feed: V2RoomActivationChangeFeed) async {
        guard accepting, changeFeed?.id == feed.id,
              let changes = await host.takeChanges(observerID: feed.id),
              accepting, changeFeed?.id == feed.id else { return }
        switch changes {
        case .rooms(let roomIDs): await reconcileActors(roomIDs: roomIDs)
        case .rescan: await reconcileActors(roomIDs: Set(roomActors.keys))
        }
    }

    public func reconcileActors(roomIDs: Set<RoomID>) async {
        // Capture installations before yielding. A stale observer must not
        // remove an actor installed for the same token during this await.
        let installed = roomIDs.compactMap { roomActors[$0] }.map { (token: $0.token, actorID: $0.actor.id) }
        guard accepting, !installed.isEmpty else { return }
        let ready = await host.readyTokens(among: installed.map(\.token))
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
        guard let current = roomActors[token.roomID], current.token == token,
              current.actor.id == actorID else { return false }
        roomActors.removeValue(forKey: token.roomID)
        return true
    }

    public func actorCount() -> Int { roomActors.count }

    public nonisolated func inFlightRequestCount() -> Int { requestAdmission.withLock { $0.active } }

    private nonisolated func beginRequest() throws {
        try requestAdmission.withLock { value in
            guard value.accepting, value.active < maximumInboundRequests else {
                throw V2ActorAuthenticationError.overloaded
            }
            value.active += 1
        }
    }
    private nonisolated func endRequest() {
        requestAdmission.withLock { value in
            precondition(value.active > 0)
            value.active -= 1
        }
    }

    func physicalReference(for token: V2RoomActivationToken) async throws -> Data {
        guard accepting, token.host == identity, await host.isReady(token: token), accepting else {
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        if roomActors[token.roomID]?.token != token {
            // Derive the transient cache ceiling from the actual room budget;
            // a slow observer cannot grow an unbounded retired-reference cache.
            let capacity = host.roomCapacity <= Int.max / 2 ? host.roomCapacity * 2 : Int.max
            guard roomActors[token.roomID] != nil || roomActors.count < capacity else {
                throw V2RoomCallFailure.notAccepted(.overloaded)
            }
            roomActors[token.roomID] = .init(token: token,
                actor: V2RoomClusterActor(actorSystem: actorSystem, token: token, service: self))
        }
        guard let entry = roomActors[token.roomID], entry.token == token else {
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        let actor = entry.actor
        // Retain this precise installation across readiness's actor hop. Even
        // same-token reconstruction must not be deleted by this old attempt.
        let ready = await host.isReady(token: token)
        guard ready, accepting, roomActors[token.roomID]?.token == token,
              roomActors[token.roomID]?.actor.id == actor.id else {
            removePhysicalReference(for: token, actorID: actor.id)
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        return try V2ActorProtobuf.encode(actor.id)
    }

    private func dispatch(_ request: V2ActorRPCRequest,
                          deadline: ContinuousClock.Instant) async throws -> V2ActorRPCResponse {
        switch request {
        case .placementWrite, .placementRead, .placementRaft:
            throw V2ActorAuthenticationError.forbidden
        case .drainPlacement(let request):
            guard request.isBounded, let placementDrain else { throw V2RoomCallFailure.notAccepted(.unavailable) }
            var result = try await placementDrain.drainPlacement(request, deadline: deadline)
            guard try result.matches(request, host: identity) else { throw V2RoomCallFailure.outcomeUnknown }
            result.certificate = try V2PlacementDrainCertificate.signPartition(result.receipt, shard: request.shardID, signer: signer)
            return .placementDrained(result)
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
            let batch = try await policyOwnership.policySnapshots(request, deadline: deadline)
            guard batch.session.source == identity, batch.session.recipient == request.subscriber.host,
                  batch.interestRevision == request.interestRevision,
                  batch.snapshots.count == request.scopes.count,
                  Set(batch.snapshots.map { $0.scope.key }) == Set(request.scopes.map(\.key)) else {
                throw V2RoomCallFailure.outcomeUnknown
            }
            return .policySnapshots(batch)
        case .releasePolicyInterests(let request):
            guard let policyOwnership else { throw V2RoomCallFailure.notAccepted(.unavailable) }
            try await policyOwnership.releasePolicyInterests(request, deadline: deadline)
            return .acknowledged
        case .updatePolicySnapshot(let request):
            guard let policyOwnership else { throw V2RoomCallFailure.notAccepted(.unavailable) }
            try await policyOwnership.updatePolicySnapshot(request, deadline: deadline)
            return .acknowledged
        case .activate(let roomID, let owner):
            let resolution = try await host.activate(roomID: roomID, owner: owner, deadline: deadline)
            switch resolution {
            case .ready(let token):
                guard token.roomID == roomID, token.owner == owner, token.host == identity else {
                    throw V2RoomCallFailure.notAccepted(.staleActivation)
                }
                return .ready(token: token, physicalReference: try await physicalReference(for: token))

            }
        case .lookup(let token):
            return .ready(token: token, physicalReference: try await physicalReference(for: token))
        case .invoke(let token, let request):
            return try await invokeRoom(token: token, request: request, deadline: deadline)
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

    /// A physical room actor keeps its request across authentication and room
    /// execution. It never rejoins the node-wide control actor's mailbox.
    private nonisolated(nonsending) func invokeRoom(token: V2RoomActivationToken, request: V2RoomRequest,
        deadline: ContinuousClock.Instant) async throws -> V2ActorRPCResponse {
        V2SendPathTrace.current?.mark("receiver_invoke_enter")
        V2SendPathTrace.current?.mark("receiver_host_dispatch")
        let result = try await host.invoke(token: token, request: request, deadline: deadline)
        V2SendPathTrace.current?.mark("receiver_host_return")
        return .result(result)
    }

    private nonisolated func isBoundedBatch(_ request: V2ActorRPCRequest) -> Bool {
        switch request { case .recoveryBatch: true; default: false }
    }

    private nonisolated func requestToken(_ request: V2ActorRPCRequest) -> V2RoomActivationToken? {
        switch request {
        case .placementWrite, .placementRead, .placementRaft, .drainPlacement, .activate, .recoveryBatch, .mutatePolicy, .policySnapshots, .updatePolicySnapshot, .releasePolicyInterests: nil
        case .lookup(let token), .invoke(let token, _), .reserve(let token, _): token
        case .forwardPair(let token, _): token
        case .markDispatched(let grant), .abortReservation(let grant), .finishReservation(let grant, _): grant.token
        }
    }

    private nonisolated func requestShard(_ request: V2ActorRPCRequest) -> String {
        switch request {
        case .placementWrite(let request), .placementRead(let request), .placementRaft(let request): request.shardID
        case .drainPlacement(let request): request.shardID
        case .policySnapshots(let request): request.endpoint
        case .updatePolicySnapshot(let request): request.endpoint
        case .releasePolicyInterests(let request): request.endpoint
        case .forwardPair(let token, _): token.owner.shardID
        case .mutatePolicy(let mutation): mutation.endpoint
        case .activate(_, let owner): owner.shardID
        case .recoveryBatch: "" // Handled as the complete shard set before dispatch.
        case .lookup(let token), .invoke(let token, _), .reserve(let token, _): token.owner.shardID
        case .markDispatched(let grant), .abortReservation(let grant), .finishReservation(let grant, _):
            grant.token.owner.shardID
        }
    }

    private nonisolated func isHostOnly(_ request: V2ActorRPCRequest) -> Bool {
        switch request {
        case .placementWrite, .placementRead, .placementRaft, .drainPlacement, .activate, .lookup, .recoveryBatch, .mutatePolicy, .policySnapshots, .updatePolicySnapshot, .releasePolicyInterests, .forwardPair: true
        default: false
        }
    }
}

/// Actor-owned admission. SQL recovery cannot consume lease-maintenance slots.
/// Recovery capacity is bounded by authenticated peers and the outer
/// request limit; each peer can hold at most two batches of at most 64 rooms.
struct V2RoomBatchAdmission {
    enum Kind: Hashable { case recovery }
    private struct Key: Hashable { let kind: Kind; let peer: V2ActorServiceID }
    private var active: [Kind: Int] = [:]
    private var peers: [Key: Int] = [:]
    mutating func acquire(_ kind: Kind, peer: V2ActorServiceID) -> Bool {
        let key = Key(kind: kind, peer: peer)
        let limit = 4
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
