import Foundation
import Crypto
import IMV2ActorContracts
import IMV2Core

public enum V2RoomClientPrincipal: Sendable {
    case user(UserID)
    case service
}

/// 已配置且经过认证的物理候选节点。仅发现 Cluster ActorID
/// 不会产生宿主房间或读取其所有者数据库的权限。
public struct V2RoomHostCandidate: Sendable {
    public let identity: V2ActorHostIdentity
    public let accessibleShardIDs: Set<String>
    public let availableRooms: Int
    public let isHealthy: Bool

    public init(identity: V2ActorHostIdentity, accessibleShardIDs: Set<String>,
                availableRooms: Int, isHealthy: Bool) {
        self.identity = identity
        self.accessibleShardIDs = accessibleShardIDs
        self.availableRooms = availableRooms
        self.isHealthy = isHealthy
    }
}

public protocol V2RoomHostDiscovering: Sendable {
    func candidates(for owner: V2RoomDataOwner) async throws -> [V2RoomHostCandidate]
}

/// Cluster 通过签名报文实现此端口，供本地与远程调用共用。
/// 分发后的传输错误表示 outcomeUnknown，绝不表示已回滚。
public enum V2CachedRoomCallResult: Sendable {
    /// No room business RPC was dispatched. Transport errors are never misses.
    case cacheMiss
    case response(V2RoomResponse)
}

public extension V2RoomRequest {
    var permitsCachedCall: Bool {
        // Cached location and replay permission are independent. Subscription
        // reconciliation owns retries; a warm call needs no existence probe.
        if case .roomSubscription = self { return true }
        if replayPolicy == .readOnly { return true }
        guard replayPolicy == .durableIdempotent, hasStableOperationID else { return false }
        switch self {
        case .messaging(.sendOperation), .messaging(.recoverSendOperation): return true
        default: return false
        }
    }
}

public protocol V2RoomClientTransport: Sendable {
    func invokeRecoveryBatch(on host: V2ActorHostIdentity, items: [V2RoomRecoveryBatchCallItem],
                             deadline: ContinuousClock.Instant) async throws -> [V2RoomRecoveryBatchCallOutcome]
    func tryInvokeCached(_ token: V2RoomActivationToken, request: V2RoomRequest,
                         principal: V2RoomClientPrincipal,
                         deadline: ContinuousClock.Instant) async throws -> V2CachedRoomCallResult
    func activate(on host: V2ActorHostIdentity, roomID: RoomID, owner: V2RoomDataOwner,
                  deadline: ContinuousClock.Instant) async throws -> V2RoomActivationResolution
    func lookup(_ token: V2RoomActivationToken, deadline: ContinuousClock.Instant) async throws -> Bool
    /// 仅供调用使用的推测性提示。它既不能认证请求，
    /// 也不能替代公开解析所需的物理查询。
    func canInvokeCachedLocally(_ token: V2RoomActivationToken) async -> Bool
    /// 仅在当前精确的同进程能力上执行。默认传输必须安全地拒绝，
    /// 不能悄然将提示路由到远端。
    func invokeCachedLocally(_ token: V2RoomActivationToken, request: V2RoomRequest,
                             principal: V2RoomClientPrincipal,
                             deadline: ContinuousClock.Instant) async throws -> V2RoomResponse
    func invoke(_ token: V2RoomActivationToken, request: V2RoomRequest,
                principal: V2RoomClientPrincipal, deadline: ContinuousClock.Instant) async throws -> V2RoomResponse
    func reserve(_ token: V2RoomActivationToken, requestID: UUID,
                 deadline: ContinuousClock.Instant) async throws -> V2RoomReservation
    func markDispatched(_ grant: V2RoomReservation, deadline: ContinuousClock.Instant) async throws
    func abort(_ grant: V2RoomReservation, deadline: ContinuousClock.Instant) async -> Bool
    func finish(_ grant: V2RoomReservation, completion: V2RoomReservationCompletion,
                deadline: ContinuousClock.Instant) async -> Bool
}

public extension V2RoomClientTransport {
    // Test transports must opt in explicitly; never disguise N scalar RPCs as
    // the production batch capability.
    func invokeRecoveryBatch(on host: V2ActorHostIdentity, items: [V2RoomRecoveryBatchCallItem],
                             deadline: ContinuousClock.Instant) async throws -> [V2RoomRecoveryBatchCallOutcome] {
        throw V2RoomCallFailure.notAccepted(.invalidRequest)
    }
    func tryInvokeCached(_ token: V2RoomActivationToken, request: V2RoomRequest,
                         principal: V2RoomClientPrincipal,
                         deadline: ContinuousClock.Instant) async throws -> V2CachedRoomCallResult { .cacheMiss }
    func canInvokeCachedLocally(_ token: V2RoomActivationToken) async -> Bool { false }
    func invokeCachedLocally(_ token: V2RoomActivationToken, request: V2RoomRequest,
                             principal: V2RoomClientPrincipal,
                             deadline: ContinuousClock.Instant) async throws -> V2RoomResponse {
        throw V2RoomCallFailure.notAccepted(.staleActivation)
    }
}

public struct V2RoomRef: Sendable {
    public let roomID: RoomID
    private let directory: V2RoomDirectory

    init(roomID: RoomID, directory: V2RoomDirectory) {
        self.roomID = roomID
        self.directory = directory
    }

    /// 重试不会重新生成请求值，包括其操作 ID；
    /// 只会创建新的传输尝试和会话序号。
    public func call(_ request: V2RoomRequest, principal: V2RoomClientPrincipal,
                     deadline: ContinuousClock.Instant) async throws -> V2RoomResponse {
        V2SendPathTrace.current?.mark("directory_call_enter")
        defer { V2SendPathTrace.current?.mark("directory_call_return") }
        guard request.roomID == roomID else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        return try await directory.call(request, principal: principal, deadline: deadline)
    }
}

public actor V2RoomDirectory {
    // 位置检查是只读调用。若旧物理引用无响应，
    // 在解析时间预算内返回所有者数据库查找当前租约。
    // 可写调用仍保留完整截止时间和结果未知处理。
    private static let locationLookupTimeout: Duration = .seconds(3)
    private let owners: any V2RoomDataOwnerResolving
    private let leases: any V2RoomActivationLeaseStore
    private let hosts: any V2RoomHostDiscovering
    private let transport: any V2RoomClientTransport
    private let configuration: V2RoomRuntimeConfiguration
    private let clock = ContinuousClock()
    private var cache: V2RoomLocationCache<RoomID, Cached>
    private var nextCacheRevision: UInt64 = 0
    private var pending: [RoomID: Pending] = [:]
    private var pendingQueue: [RoomID] = []
    private var activeResolutions = 0
    private var activeCalls = 0
    // All recovery callers share this physical RPC budget; nested batches do
    // not multiply the Gateway authorization window by the host fanout window.
    private let maximumRecoveryHostCalls = 4
    private var recoveryHostCalls: Set<UUID> = []
    private struct RecoveryHostWaiter {
        let continuation: CheckedContinuation<Void, any Error>
        let deadline: ContinuousClock.Instant
        let timer: Task<Void, Never>
    }
    private var recoveryHostWaiters: [UUID: RecoveryHostWaiter] = [:]
    private var recoveryHostOrder: [UUID] = []
    private var waiterCount = 0
    private var accepting = true
    private var cachedCalls: UInt64 = 0
    private var cachedResponses: UInt64 = 0
    private var cacheMisses: UInt64 = 0
    private var locationInvalidations: UInt64 = 0
    private var recoveryAttempts: UInt64 = 0
    private var recoveryWaits: UInt64 = 0
    private var recoveryWarmItems: UInt64 = 0
    private var recoveryColdItems: UInt64 = 0
    private var recoveryHostCohorts: UInt64 = 0
    private var recoveryHostItems: UInt64 = 0
    private var recoveryStages: [V2RoomDirectoryRecoveryStage: V2RoomDirectoryRecoveryStageSnapshot] = [:]
    // Only currently entered existing caller/owned-job lifetimes, removed on
    // their actual scope exit; no per-observation Task or historical identity.
    private var recoveryMailboxes: [UUID: RecoveryMailbox] = [:]
    private var recoveryStageStarts: [V2RoomDirectoryRecoveryStage: [ContinuousClock.Instant: Int]] = [:]

    public init(owners: any V2RoomDataOwnerResolving, leases: any V2RoomActivationLeaseStore,
                hosts: any V2RoomHostDiscovering, transport: any V2RoomClientTransport,
                configuration: V2RoomRuntimeConfiguration) {
        self.owners = owners
        self.leases = leases
        self.hosts = hosts
        self.transport = transport
        self.configuration = configuration
        self.cache = .init(maximumCount: configuration.maximumCachedLocations)
    }

    public nonisolated func room(_ roomID: RoomID) -> V2RoomRef {
        .init(roomID: roomID, directory: self)
    }

    public func snapshot() -> (cached: Int, pending: Int, active: Int, waiters: Int) {
        (cache.count, pending.count, activeResolutions, waiterCount)
    }

    public func callMetricsSnapshot() -> V2RoomDirectoryCallMetricsSnapshot {
        .init(cachedCalls: cachedCalls, cachedResponses: cachedResponses,
            cacheMisses: cacheMisses, locationInvalidations: locationInvalidations,
            recoveryAttempts: recoveryAttempts, recoveryWaits: recoveryWaits,
            recoveringRooms: pending.values.filter { $0.demandRecovery && $0.started && $0.recoveryPhase == .recovering }.count,
            waitingForLeaseRooms: pending.values.filter { $0.demandRecovery && $0.started && $0.recoveryPhase == .waitingForLease }.count,
            recoveryWarmItems: recoveryWarmItems, recoveryColdItems: recoveryColdItems,
            recoveryHostCohorts: recoveryHostCohorts, recoveryHostItems: recoveryHostItems,
            recoveryStages: recoveryStageSnapshot())
    }

    private func count(_ counter: inout UInt64) {
        if counter < UInt64.max { counter += 1 }
    }

    private func add(_ value: Int, to counter: inout UInt64) {
        let sum = counter.addingReportingOverflow(UInt64(value))
        counter = sum.overflow ? .max : sum.partialValue
    }

    private func beginRecoveryStage(_ stage: V2RoomDirectoryRecoveryStage, items: Int) -> ContinuousClock.Instant {
        var value = recoveryStages[stage] ?? .init()
        value.active += 1; count(&value.started); add(items, to: &value.itemsStarted)
        recoveryStages[stage] = value
        let began = clock.now
        recoveryStageStarts[stage, default: [:]][began, default: 0] += 1
        return began
    }

    private func finishRecoveryStage(_ stage: V2RoomDirectoryRecoveryStage, since start: ContinuousClock.Instant) {
        var value = recoveryStages[stage] ?? .init()
        precondition(value.active > 0)
        value.active -= 1; count(&value.completed)
        let remaining = recoveryStageStarts[stage]?[start] ?? 0
        precondition(remaining > 0)
        if remaining == 1 { recoveryStageStarts[stage]?.removeValue(forKey: start) }
        else { recoveryStageStarts[stage]?[start] = remaining - 1 }
        let elapsed = start.duration(to: clock.now).components
        let milliseconds = max(0, Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
        value.totalMilliseconds += milliseconds
        value.maxMilliseconds = max(value.maxMilliseconds, milliseconds)
        recoveryStages[stage] = value
    }

    private func recoveryStageSnapshot() -> [V2RoomDirectoryRecoveryStage: V2RoomDirectoryRecoveryStageSnapshot] {
        var values = recoveryStages
        let now = clock.now
        for stage in V2RoomDirectoryRecoveryStage.allCases {
            var value = values[stage] ?? .init()
            if let oldest = recoveryStageStarts[stage]?.keys.min() {
                let elapsed = oldest.duration(to: now).components
                value.oldestMilliseconds = max(0, Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
            } else { value.oldestMilliseconds = 0 }
            values[stage] = value
        }
        return values
    }

    private func observeRecoverySettlement(_ values: [V2RoomRecoveryQueryOutcome],
        callback: @Sendable ([V2RoomRecoveryQueryOutcome]) async -> Void) async {
        let began = beginRecoveryStage(.settledCallback, items: values.count)
        defer { finishRecoveryStage(.settledCallback, since: began) }
        await callback(values)
    }

    public func drain() {
        accepting = false
        for id in recoveryHostOrder {
            finishRecoveryHostWaiter(id, failure: .notAccepted(.retired))
        }
        recoveryHostOrder.removeAll()
        for entry in pending.values {
            complete(entry, with: .failure(V2RoomCallFailure.notAccepted(.retired)))
        }
        pending.removeAll()
        pendingQueue.removeAll()
        cache.removeAll()
    }

    /// 拒绝等待者不会结束所有者或租约数据库操作。
    /// 应用关闭共享数据库连接池前，必须等待此流程和传输静默完成。
    public func quiesce(deadline: ContinuousClock.Instant) async -> Bool {
        drain()
        while activeResolutions > 0 || activeCalls > 0 {
            guard clock.now < deadline, !Task.isCancelled else { return false }
            do { try await clock.sleep(until: min(deadline, clock.now + .milliseconds(10))) }
            catch { return false }
        }
        return true
    }

    public func resolve(_ roomID: RoomID, deadline: ContinuousClock.Instant) async throws -> V2RoomActivationToken {
        try await resolve(roomID, deadline: deadline, requiresPhysicalConfirmation: true).token
    }

    private func resolve(_ roomID: RoomID, deadline: ContinuousClock.Instant,
                         requiresPhysicalConfirmation: Bool,
                         cachedRecovery: Cached? = nil, demandRecovery: Bool = false,
                         authoritativeRecovery: Bool = false) async throws -> Resolution {
        guard accepting else { throw V2RoomCallFailure.notAccepted(.retired) }
        guard !Task.isCancelled else { throw V2RoomCallFailure.notAccepted(.cancelled) }
        guard clock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        guard waiterCount < configuration.maximumActivationWaitersPerHost else {
            throw V2RoomCallFailure.notAccepted(.overloaded)
        }
        if let entry = pending[roomID] {
            guard entry.waiters.count < configuration.maximumActivationWaitersPerRoom else {
                throw V2RoomCallFailure.notAccepted(.overloaded)
            }
        } else {
            guard pending.count < configuration.maximumPendingActivations else {
                throw V2RoomCallFailure.notAccepted(.overloaded)
            }
            let entry = Pending(roomID: roomID)
            pending[roomID] = entry
            pendingQueue.append(roomID)
        }
        let entry = pending[roomID]!
        if demandRecovery { entry.demandRecovery = true }
        if authoritativeRecovery { entry.authoritativeRecovery = true; entry.requiresPhysicalConfirmation = true }
        if let cachedRecovery, entry.cachedRecovery == nil { entry.cachedRecovery = cachedRecovery }
        let waiterID = UUID()
        let generation = entry.generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: V2RoomCallFailure.notAccepted(.cancelled))
                    if entry.waiters.isEmpty && !entry.started {
                        pending.removeValue(forKey: roomID)
                        pendingQueue.removeAll { $0 == roomID }
                        pump()
                    }
                    return
                }
                if requiresPhysicalConfirmation { entry.requiresPhysicalConfirmation = true }
                let timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) }
                    catch { return }
                    await self?.removeWaiter(roomID: roomID, generation: generation,
                                             waiterID: waiterID, reason: .deadlineExceeded)
                }
                entry.waiters[waiterID] = Waiter(sink: .continuation(continuation), timer: timer, deadline: deadline, stageStarted: nil)
                waiterCount += 1
                pump()
            }
        } onCancel: {
            Task { await self.removeWaiter(roomID: roomID, generation: generation,
                                           waiterID: waiterID, reason: .cancelled) }
        }
    }

    public func call(_ request: V2RoomRequest, principal: V2RoomClientPrincipal,
                     deadline: ContinuousClock.Instant) async throws -> V2RoomResponse {
        try checkDeadline(deadline)
        activeCalls += 1
        defer { activeCalls -= 1 }
        if request.permitsCachedCall {
            return try await callCachedReplayableOperation(request, principal: principal, deadline: deadline)
        }
        var lastFailure: V2RoomCallFailure = .notAccepted(.unavailable)
        for _ in 0..<configuration.maximumResolveAttempts {
            try checkDeadline(deadline)
            let mayUseLocalHint = request.replayPolicy == .readOnly ||
                (request.replayPolicy == .durableIdempotent && request.hasStableOperationID)
            let resolution = try await resolve(request.roomID, deadline: deadline,
                                               requiresPhysicalConfirmation: !mayUseLocalHint)
            let token = resolution.token
            let installed = cache[request.roomID]
            try checkDeadline(deadline)
            do {
                switch resolution {
                case .confirmed:
                    return try await transport.invoke(token, request: request,
                                                      principal: principal, deadline: deadline)
                case .localHint:
                    return try await transport.invokeCachedLocally(token, request: request,
                                                                   principal: principal, deadline: deadline)
                }
            }
            catch {
                let failure = error as? V2RoomCallFailure ?? .outcomeUnknown
                lastFailure = failure
                let action = failure.retryAction(
                    policy: request.replayPolicy, hasStableOperationID: request.hasStableOperationID
                )
                switch action {
                case .refreshLocation:
                    if let installed, installed.token == token { invalidate(installed) }
                case .retryRead, .retrySameOperation:
                    break
                case .returnFailure, .reconcile:
                    throw failure
                }
            }
        }
        throw lastFailure
    }

    private func callCachedReplayableOperation(_ request: V2RoomRequest, principal: V2RoomClientPrincipal,
                                      deadline: ContinuousClock.Instant) async throws -> V2RoomResponse {
        var lastFailure: V2RoomCallFailure = .notAccepted(.unavailable)
        var forceRecovery = false
        for attempt in 0..<configuration.maximumResolveAttempts {
            try checkDeadline(deadline)
            var installed = cache[request.roomID]
            do {
                if !forceRecovery, let cached = installed {
                    count(&cachedCalls)
                    switch try await transport.tryInvokeCached(cached.token, request: request,
                        principal: principal, deadline: min(deadline, clock.now + configuration.callTimeout.duration)) {
                    case .response(let response):
                        count(&cachedResponses)
                        return response
                    case .cacheMiss:
                        count(&cacheMisses)
                    }
                }
                let resolveStartedAt = ContinuousClock.now
                let resolved = try await resolve(request.roomID, deadline: deadline,
                    requiresPhysicalConfirmation: false, cachedRecovery: forceRecovery ? nil : installed,
                    demandRecovery: true, authoritativeRecovery: forceRecovery)
                V2SendPathTrace.current?.record("directory_resolve", from: resolveStartedAt)
                try checkDeadline(deadline)
                installed = cache[request.roomID].flatMap { $0.token == resolved.token ? $0 : nil }
                // A default/non-Cluster transport may always return cacheMiss;
                // the bounded resolved invocation remains its supported path.
                switch resolved {
                case .confirmed:
                    return try await transport.invoke(resolved.token, request: request,
                        principal: principal, deadline: min(deadline, clock.now + configuration.callTimeout.duration))
                case .localHint:
                    return try await transport.invokeCachedLocally(resolved.token, request: request,
                        principal: principal, deadline: min(deadline, clock.now + configuration.callTimeout.duration))
                }
            } catch {
                let failure = error as? V2RoomCallFailure ?? .outcomeUnknown
                lastFailure = failure
                switch failure.retryAction(policy: request.replayPolicy, hasStableOperationID: request.hasStableOperationID) {
                case .returnFailure, .reconcile: throw failure
                case .refreshLocation:
                    forceRecovery = true
                    switch failure {
                    case .notAccepted(.staleActivation), .rolledBack(.staleActivation),
                         .notAccepted(.retired), .rolledBack(.retired),
                         .notAccepted(.leaseLost), .rolledBack(.leaseLost):
                        if let installed { invalidate(installed) }
                    default: break // availability is not an owner/lease invalidation
                    }
                case .retryRead, .retrySameOperation:
                    forceRecovery = false // exact request/ID is retained; suspect handling belongs to transport
                }
                if attempt + 1 < configuration.maximumResolveAttempts {
                    count(&recoveryWaits)
                    try await clock.sleep(until: min(deadline, clock.now + .milliseconds(100)))
                }
            }
        }
        throw lastFailure
    }

    /// Host-level pair calls own their own reservations. Location retries must
    /// preserve the whole immutable operation and any earlier unknown outcome.
    package func callForwardPair(_ pair: V2ActorForwardPairWire, deadline: ContinuousClock.Instant,
        invoke: @Sendable (V2RoomActivationToken, V2ActorForwardPairWire, ContinuousClock.Instant) async throws -> V2ActorForwardMessageResultWire
    ) async throws -> V2ActorForwardMessageResultWire {
        guard pair.actorUserID.uuidValue != nil, pair.operationID.uuidValue != nil,
              pair.source.roomID.uuidValue != nil, pair.source.messageID.uuidValue != nil,
              pair.targetRoomID.uuidValue != nil else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        try checkDeadline(deadline)
        guard accepting else { throw V2RoomCallFailure.notAccepted(.retired) }
        activeCalls += 1
        defer { activeCalls -= 1 }
        var lastFailure = V2RoomCallFailure.notAccepted(.unavailable)
        var sawUnknown = false
        for attempt in 0..<configuration.maximumResolveAttempts {
            var installed = cache[pair.targetRoomID]
            do {
                try checkDeadline(deadline)
                let resolution = try await resolve(pair.targetRoomID, deadline: deadline,
                    requiresPhysicalConfirmation: true)
                let token = resolution.token
                installed = cache[pair.targetRoomID].flatMap { $0.token == token ? $0 : nil }
                try checkDeadline(deadline)
                let value = try await invoke(token, pair, min(deadline, clock.now + configuration.callTimeout.duration))
                guard value.sourceMessageID == pair.source.messageID, value.targetRoomID == pair.targetRoomID else {
                    throw V2RoomCallFailure.outcomeUnknown
                }
                return value
            } catch {
                let failure = error as? V2RoomCallFailure ?? .outcomeUnknown
                if failure == .outcomeUnknown { sawUnknown = true }
                lastFailure = sawUnknown ? .outcomeUnknown : failure
                if Task.isCancelled || clock.now >= deadline { throw lastFailure }
                switch failure.retryAction(policy: .durableIdempotent, hasStableOperationID: true) {
                case .returnFailure, .reconcile: throw lastFailure
                case .refreshLocation:
                    switch failure {
                    case .notAccepted(.staleActivation), .rolledBack(.staleActivation),
                         .notAccepted(.retired), .rolledBack(.retired),
                         .notAccepted(.leaseLost), .rolledBack(.leaseLost):
                        if let installed { invalidate(installed) }
                    default: break
                    }
                case .retryRead, .retrySameOperation: break
                }
                if attempt + 1 < configuration.maximumResolveAttempts {
                    do { try await clock.sleep(until: min(deadline, clock.now + .milliseconds(100))) }
                    catch { throw sawUnknown ? V2RoomCallFailure.outcomeUnknown : .notAccepted(.cancelled) }
                }
            }
        }
        throw lastFailure
    }

    public func reservationOperations() -> V2RoomReservationOperations {
        let transport = transport
        return .init(
            reserve: { [weak self] roomID, requestID, deadline in
                guard let self else { throw V2RoomCallFailure.notAccepted(.retired) }
                let token = try await self.resolve(roomID, deadline: deadline)
                return try await transport.reserve(token, requestID: requestID, deadline: deadline)
            },
            markDispatched: { grant, deadline in
                try await transport.markDispatched(grant, deadline: deadline)
            },
            abort: { grant, deadline in await transport.abort(grant, deadline: deadline) },
            finish: { grant, completion, deadline in
                await transport.finish(grant, completion: completion, deadline: deadline)
            }
        )
    }

    /// Physical host cohorts progress independently. Cold discovery starts
    /// before warm RPCs; every caller shares the four actual host-call slots.
    public func recoveryStates(
        _ queries: [V2ActorRoomRecoveryItemQuery], deadline: ContinuousClock.Instant,
        onSettled: @escaping @Sendable ([V2RoomRecoveryQueryOutcome]) async -> Void
    ) async throws -> [V2RoomRecoveryQueryOutcome] {
        struct Pair: Hashable { let room: RoomID; let viewer: UserID }
        guard queries.count <= 128, queries.allSatisfy({ $0.kind == .state }),
              Set(queries.map { Pair(room: $0.roomID, viewer: $0.actorUserID) }).count == queries.count else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        try checkDeadline(deadline)
        guard accepting else { throw V2RoomCallFailure.notAccepted(.retired) }
        activeCalls += 1
        defer { activeCalls -= 1 }
        let cold = queries.filter { cache[$0.roomID] == nil }
        let warm = queries.compactMap { query in cache[query.roomID].map { (query, $0.token) } }
        add(warm.count, to: &recoveryWarmItems)
        add(cold.count, to: &recoveryColdItems)
        let batchID = UUID(), batch = RecoveryMailbox()
        recoveryMailboxes[batchID] = batch
        var rooms: [RoomID] = []
        for query in cold where !rooms.contains(query.roomID) { rooms.append(query.roomID) }
        for room in rooms { attachRecoveryObserver(room, batchID: batchID, deadline: deadline) }
        pump()
        let timer = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            await self?.detachRecoveryMailbox(batchID, reason: .deadlineExceeded)
        }
        defer {
            timer.cancel()
            detachRecoveryMailbox(batchID, reason: .cancelled)
            recoveryMailboxes.removeValue(forKey: batchID)
        }
        let warmGroups = recoveryGroups(warm, deadline: deadline)
        let values = await withTaskGroup(of: [V2RoomRecoveryQueryOutcome].self) { group in
            group.addTask {
                await self.settleRecoveryGroups(warmGroups, deadline: deadline, onSettled: onSettled)
            }
            if !cold.isEmpty {
                let coldRooms = rooms
                group.addTask {
                    await self.settleColdRecovery(cold, rooms: coldRooms, batchID: batchID,
                        deadline: deadline, onSettled: onSettled)
                }
            }
            var values: [V2RoomRecoveryQueryOutcome] = []
            for await result in group { values.append(contentsOf: result) }
            return values
        }
        let answers = Dictionary(uniqueKeysWithValues: values.map {
            (Pair(room: $0.query.roomID, viewer: $0.query.actorUserID), $0)
        })
        guard answers.count == queries.count else { throw V2RoomCallFailure.notAccepted(.unavailable) }
        return queries.map { answers[Pair(room: $0.roomID, viewer: $0.actorUserID)]! }
    }

    private func recoveryGroups(_ values: [(V2ActorRoomRecoveryItemQuery, V2RoomActivationToken)], deadline: ContinuousClock.Instant)
        -> [(GroupKey, [V2RoomRecoveryBatchCallItem])] {
        var groups: [(GroupKey, [V2RoomRecoveryBatchCallItem])] = []
        for (query, token) in values {
            let key = GroupKey(host: token.host, owner: token.owner)
            let item = V2RoomRecoveryBatchCallItem(token: token, query: query, deadline: deadline)
            if let index = groups.indices.last(where: { groups[$0].0 == key && groups[$0].1.count < 100 }) {
                groups[index].1.append(item)
            } else { groups.append((key, [item])) }
        }
        return groups
    }

    private func settleRecoveryGroups(_ groups: [(GroupKey, [V2RoomRecoveryBatchCallItem])],
        deadline: ContinuousClock.Instant,
        onSettled: @escaping @Sendable ([V2RoomRecoveryQueryOutcome]) async -> Void
    ) async -> [V2RoomRecoveryQueryOutcome] {
        await withTaskGroup(of: [V2RoomRecoveryQueryOutcome].self) { tasks in
            var next = 0, active = 0
            var answers: [V2RoomRecoveryQueryOutcome] = []
            while next < groups.count || active > 0 {
                while next < groups.count, active < maximumRecoveryHostCalls {
                    let (key, original) = groups[next]
                    let items = original.map { V2RoomRecoveryBatchCallItem(token: $0.token, query: $0.query, deadline: deadline) }
                    next += 1; active += 1
                    tasks.addTask { await self.settleRecoveryGroup(key, items: items, deadline: deadline) }
                }
                guard let values = await tasks.next() else { break }
                active -= 1; answers.append(contentsOf: values)
                await observeRecoverySettlement(values, callback: onSettled)
            }
            return answers
        }
    }

    private enum ColdRecoveryEvent: Sendable {
        case locations([RoomID])
        case host([V2RoomRecoveryQueryOutcome])
    }

    private func nextColdLocations(batchID: UUID, rooms: [RoomID],
        deadline: ContinuousClock.Instant) async -> [RoomID] {
        guard let batch = recoveryMailboxes[batchID] else { return [] }
        while true {
            if Task.isCancelled { detachRecoveryMailbox(batchID, reason: .cancelled) }
            if clock.now >= deadline { detachRecoveryMailbox(batchID, reason: .deadlineExceeded) }
            let ready = rooms.filter { batch.results[$0] != nil }
            if !ready.isEmpty { return ready }
            await withCheckedContinuation { continuation in
                if batch.results.isEmpty { batch.signal = continuation }
                else { continuation.resume() }
            }
        }
    }

    private func settleColdRecovery(_ cold: [V2ActorRoomRecoveryItemQuery], rooms: [RoomID],
        batchID: UUID, deadline: ContinuousClock.Instant,
        onSettled: @escaping @Sendable ([V2RoomRecoveryQueryOutcome]) async -> Void
    ) async -> [V2RoomRecoveryQueryOutcome] {
        guard let batch = recoveryMailboxes[batchID] else { return [] }
        return await withTaskCancellationHandler {
            await withTaskGroup(of: ColdRecoveryEvent.self) { tasks in
                var remaining = rooms
                var pendingGroups: [(GroupKey, [V2RoomRecoveryBatchCallItem])] = []
                var activeHosts = 0
                var answers: [V2RoomRecoveryQueryOutcome] = []
                tasks.addTask { .locations(await self.nextColdLocations(batchID: batchID, rooms: rooms, deadline: deadline)) }
                while let event = await tasks.next() {
                    switch event {
                    case .locations(let ready):
                        var resolved: [(V2ActorRoomRecoveryItemQuery, V2RoomActivationToken)] = []
                        var failures: [V2RoomRecoveryQueryOutcome] = []
                        for room in ready {
                            remaining.removeAll { $0 == room }
                            guard let result = batch.results.removeValue(forKey: room) else { continue }
                            for query in cold where query.roomID == room {
                                switch result {
                                case .success(let resolution): resolved.append((query, resolution.token))
                                case .failure(let error):
                                    failures.append(.init(query: query, result: .failure(
                                        (error as? V2RoomCallFailure) ?? .notAccepted(.unavailable))))
                                }
                            }
                        }
                        if !failures.isEmpty {
                            answers.append(contentsOf: failures)
                            await observeRecoverySettlement(failures, callback: onSettled)
                        }
                        pendingGroups.append(contentsOf: recoveryGroups(resolved, deadline: deadline))
                        if !remaining.isEmpty {
                            let waiting = remaining
                            tasks.addTask { .locations(await self.nextColdLocations(batchID: batchID, rooms: waiting, deadline: deadline)) }
                        }
                    case .host(let values):
                        activeHosts -= 1; answers.append(contentsOf: values)
                        await observeRecoverySettlement(values, callback: onSettled)
                    }
                    // This queue is bounded by the original <=128 query input.
                    // A later resolved host can proceed while an earlier host
                    // remains in flight; only one location waiter exists.
                    while activeHosts < maximumRecoveryHostCalls, !pendingGroups.isEmpty {
                        let (key, items) = pendingGroups.removeFirst()
                        activeHosts += 1
                        tasks.addTask { .host(await self.settleRecoveryGroup(key, items: items, deadline: deadline)) }
                    }
                }
                return answers
            }
        } onCancel: {
            Task { await self.detachRecoveryMailbox(batchID, reason: .cancelled) }
        }
    }

    private func acquireRecoveryHostCall(_ id: UUID, deadline: ContinuousClock.Instant) async throws {
        try checkDeadline(deadline)
        guard accepting else { throw V2RoomCallFailure.notAccepted(.retired) }
        if recoveryHostCalls.count < maximumRecoveryHostCalls {
            recoveryHostCalls.insert(id); return
        }
        guard recoveryHostWaiters.count < configuration.maximumActivationWaitersPerHost else {
            throw V2RoomCallFailure.notAccepted(.overloaded)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: V2RoomCallFailure.notAccepted(.cancelled)); return
                }
                let timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                    await self?.finishRecoveryHostWaiter(id, failure: .notAccepted(.deadlineExceeded))
                }
                recoveryHostWaiters[id] = .init(continuation: continuation, deadline: deadline, timer: timer)
                recoveryHostOrder.append(id)
            }
        } onCancel: {
            Task { await self.finishRecoveryHostWaiter(id, failure: .notAccepted(.cancelled)) }
        }
    }

    private func finishRecoveryHostWaiter(_ id: UUID, failure: V2RoomCallFailure) {
        guard let waiter = recoveryHostWaiters.removeValue(forKey: id) else { return }
        recoveryHostOrder.removeAll { $0 == id }
        waiter.timer.cancel(); waiter.continuation.resume(throwing: failure)
    }

    private func releaseRecoveryHostCall(_ id: UUID) {
        guard recoveryHostCalls.remove(id) != nil else { return }
        while !recoveryHostOrder.isEmpty {
            let next = recoveryHostOrder.removeFirst()
            guard let waiter = recoveryHostWaiters.removeValue(forKey: next) else { continue }
            waiter.timer.cancel()
            if !accepting || waiter.deadline <= .now {
                waiter.continuation.resume(throwing: V2RoomCallFailure.notAccepted(!accepting ? .retired : .deadlineExceeded))
                continue
            }
            recoveryHostCalls.insert(next); waiter.continuation.resume(); break
        }
    }

    private func settleRecoveryGroup(_ key: GroupKey, items: [V2RoomRecoveryBatchCallItem],
                                     deadline: ContinuousClock.Instant) async -> [V2RoomRecoveryQueryOutcome] {
        let values: [V2RoomRecoveryBatchCallOutcome]
        do {
            try checkDeadline(deadline)
            count(&recoveryHostCohorts); add(items.count, to: &recoveryHostItems)
            let began = beginRecoveryStage(.hostCallerWait, items: items.count)
            defer { finishRecoveryStage(.hostCallerWait, since: began) }
            let admission = UUID()
            try await acquireRecoveryHostCall(admission, deadline: deadline)
            defer { releaseRecoveryHostCall(admission) }
            try checkDeadline(deadline)
            let received = try await transport.invokeRecoveryBatch(on: key.host, items: items, deadline: deadline)
            guard received.count == items.count,
                  zip(items, received).allSatisfy({ $0.0.token == $0.1.token && $0.0.query == $0.1.query }) else {
                throw V2RoomCallFailure.notAccepted(.unavailable)
            }
            values = received
        } catch {
            let failure = (error as? V2RoomCallFailure) ?? (error is CancellationError ? .notAccepted(.cancelled) : .outcomeUnknown)
            values = items.map { .init(token: $0.token, query: $0.query, outcome: .failure(failure)) }
        }
        return values.map { value in
            let result: Result<V2RoomResponse, V2RoomCallFailure>
            switch value.outcome {
            case .result(let response):
                if clock.now >= deadline { result = .failure(.notAccepted(.deadlineExceeded)) }
                else if Task.isCancelled { result = .failure(.notAccepted(.cancelled)) }
                else { result = .success(response) }
            case .failure(let failure):
                result = .failure(failure)
                switch failure {
                case .notAccepted(.staleActivation), .rolledBack(.staleActivation),
                     .notAccepted(.retired), .rolledBack(.retired),
                     .notAccepted(.leaseLost), .rolledBack(.leaseLost):
                    if let cached = cache[value.token.roomID], cached.token == value.token { invalidate(cached) }
                default: break
                }
            }
            return .init(query: value.query, result: result)
        }
    }

    private func attachRecoveryObserver(_ room: RoomID, batchID: UUID, deadline: ContinuousClock.Instant) {
        guard let batch = recoveryMailboxes[batchID] else { return }
        if let cached = cache[room] { batch.results[room] = .success(.localHint(cached)); return }
        guard accepting, clock.now < deadline, !Task.isCancelled else {
            batch.results[room] = .failure(V2RoomCallFailure.notAccepted(!accepting ? .retired : (Task.isCancelled ? .cancelled : .deadlineExceeded)))
            return
        }
        guard waiterCount < configuration.maximumActivationWaitersPerHost,
              (pending[room]?.waiters.count ?? 0) < configuration.maximumActivationWaitersPerRoom,
              pending[room] != nil || pending.count < configuration.maximumPendingActivations else {
            batch.results[room] = .failure(V2RoomCallFailure.notAccepted(.overloaded)); return
        }
        let entry: Pending
        if let existing = pending[room] { entry = existing }
        else { entry = Pending(roomID: room); pending[room] = entry; pendingQueue.append(room) }
        let waiterID = UUID()
        let began = beginRecoveryStage(.coldCallerWait, items: 1)
        entry.waiters[waiterID] = Waiter(sink: .mailbox(batchID, room), timer: nil, deadline: deadline, stageStarted: began)
        batch.observers[room] = (entry.generation, waiterID)
        waiterCount += 1
    }

    private func detachRecoveryMailbox(_ id: UUID, reason: V2RoomFailureReason) {
        guard let batch = recoveryMailboxes[id] else { return }
        for (room, observer) in Array(batch.observers) {
            removeWaiter(roomID: room, generation: observer.0, waiterID: observer.1, reason: reason)
        }
    }

    public func groupedRead(
        _ requests: [V2RoomRequest], principal: V2RoomClientPrincipal,
        deadline: ContinuousClock.Instant,
        batch: @escaping @Sendable (V2ActorHostIdentity, V2RoomDataOwner, [(V2RoomActivationToken, V2RoomRequest)],
                          V2RoomClientPrincipal, ContinuousClock.Instant) async throws -> [V2RoomResponse]
    ) async throws -> [V2RoomResponse] {
        guard requests.allSatisfy({ $0.replayPolicy == .readOnly }) else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        guard requests.count <= configuration.maximumConcurrentResolutions else {
            throw V2RoomCallFailure.notAccepted(.overloaded)
        }
        var resolved: [(Int, V2RoomActivationToken, V2RoomRequest)] = []
        try await withThrowingTaskGroup(of: (Int, V2RoomActivationToken).self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask { (index, try await self.resolve(request.roomID, deadline: deadline)) }
            }
            for try await (index, token) in group { resolved.append((index, token, requests[index])) }
        }
        let groups = Dictionary(grouping: resolved) { item in
            GroupKey(host: item.1.host, owner: item.1.owner)
        }
        var answers = Array<V2RoomResponse?>(repeating: nil, count: requests.count)
        try await withThrowingTaskGroup(of: [(Int, V2RoomResponse)].self) { group in
            for (key, items) in groups {
                group.addTask {
                    let results = try await batch(key.host, key.owner,
                                                  items.map { ($0.1, $0.2) }, principal, deadline)
                    guard results.count == items.count else {
                        throw V2RoomCallFailure.notAccepted(.unavailable)
                    }
                    return zip(items, results).map { ($0.0.0, $0.1) }
                }
            }
            for try await groupResults in group {
                for (index, result) in groupResults { answers[index] = result }
            }
        }
        guard answers.allSatisfy({ $0 != nil }) else { throw V2RoomCallFailure.notAccepted(.unavailable) }
        return answers.map { $0! }
    }

    private func pump() {
        while activeResolutions < configuration.maximumConcurrentResolutions, !pendingQueue.isEmpty {
            let roomID = pendingQueue.removeFirst()
            guard let entry = pending[roomID], !entry.started else { continue }
            entry.started = true
            activeResolutions += 1
            let generation = entry.generation
            Task { [weak self] in await self?.resolveEntry(roomID: roomID, generation: generation) }
        }
    }

    private func resolveEntry(roomID: RoomID, generation: UUID) async {
        defer { activeResolutions -= 1; pump() }
        guard let entry = pending[roomID], entry.generation == generation else { return }
        let began = beginRecoveryStage(.actualResolution, items: 1)
        defer { finishRecoveryStage(.actualResolution, since: began) }
        let resolutionDeadline = clock.now + configuration.callTimeout.duration
        let result: Result<Resolution, any Error>
        do {
            var resolution = try await recoverResolution(roomID, entry: entry, deadline: resolutionDeadline)
            // 本地条件检查挂起期间，其他等待者可能加入。
            // 严格等待者即使取消也仍被记录；此 Actor 恢复前缓存也可能已被替换。
            if case .localHint(let cached) = resolution,
               (entry.requiresPhysicalConfirmation || !cacheMatches(cached)) {
                resolution = try await performResolve(roomID, deadline: resolutionDeadline,
                                                      hintEntry: nil)
            }
            result = .success(resolution)
        }
        catch { result = .failure(error) }
        guard pending[roomID] === entry else { return }
        pending.removeValue(forKey: roomID)
        complete(entry, with: result)
    }

    private func recoverResolution(_ roomID: RoomID, entry: Pending,
                                   deadline: ContinuousClock.Instant) async throws -> Resolution {
        var backoff: Duration = .milliseconds(100)
        while true {
            try checkDeadline(deadline)
            guard !entry.waiters.isEmpty else {
                throw V2RoomCallFailure.notAccepted(.cancelled)
            }
            do {
                if entry.demandRecovery { count(&recoveryAttempts) }
                entry.recoveryPhase = .recovering
                if let held = entry.heldLease, clock.now < held.recheckAfter {
                    entry.recoveryPhase = .waitingForLease
                    return .confirmed(try await confirm(held.lease.token, roomID: roomID,
                        owner: held.lease.token.owner, deadline: deadline, recoveryEntry: entry))
                }
                entry.heldLease = nil
                if !entry.requiresPhysicalConfirmation, let cached = entry.cachedRecovery,
                   cacheMatches(cached) {
                    entry.cachedRecovery = nil
                    let local = await transport.canInvokeCachedLocally(cached.token)
                    try checkDeadline(deadline)
                    if local, cacheMatches(cached), pending[roomID] === entry, !entry.requiresPhysicalConfirmation {
                        return .localHint(cached)
                    }
                    if !cacheMatches(cached) {
                        return try await performResolve(roomID, deadline: deadline, hintEntry: nil,
                            recoveryEntry: entry.demandRecovery ? entry : nil)
                    }
                    let found: Bool
                    do { found = try await transport.lookup(cached.token, deadline: locationLookupDeadline(deadline)) }
                    catch {
                        switch error as? V2RoomCallFailure {
                        case .notAccepted(.notReady), .notAccepted(.staleActivation),
                             .notAccepted(.retired), .notAccepted(.leaseLost),
                             .notAccepted(.unavailable), .notAccepted(.deadlineExceeded):
                            found = false
                        default: throw error // overload/authentication/unknown is not location evidence
                        }
                    }
                    try checkDeadline(deadline)
                    if !found { entry.failedCacheProbe = cached }
                    if found, cacheMatches(cached) {
                        remember(cached.token)
                        return .confirmed(cached.token)
                    }
                }
                return try await performResolve(roomID, deadline: deadline,
                    hintEntry: entry.requiresPhysicalConfirmation ? nil : entry,
                    recoveryEntry: entry.demandRecovery ? entry : nil)
            } catch {
                guard entry.demandRecovery, !entry.waiters.isEmpty else { throw error }
                if let timeout = error as? DemandLeaseProbeTimeout {
                    guard entry.heldLease?.lease.token == timeout.token else {
                        throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
                    }
                    // Only confirm of this authoritative lease produces this
                    // error. An expired observation is re-read on the next round.
                } else {
                    guard let failure = error as? V2RoomCallFailure else { throw error }
                    switch failure {
                    case .notAccepted(.notReady), .notAccepted(.unavailable),
                         .notAccepted(.retired), .notAccepted(.leaseLost):
                        break
                    case .notAccepted(.staleActivation):
                        // A restarted Host can reject an old incarnation while
                        // its authoritative lease still prevents a new acquire.
                        guard let held = entry.heldLease, clock.now < held.recheckAfter else { throw failure }
                    default: throw failure // unknown activation must not start another acquire
                    }
                }
                entry.recoveryPhase = entry.heldLease == nil ? .recovering : .waitingForLease
                try checkDeadline(deadline)
                count(&recoveryWaits)
                try await clock.sleep(until: min(deadline, clock.now + backoff))
                backoff = min(backoff * 2, .seconds(1))
            }
        }
    }

    private func performResolve(_ roomID: RoomID, deadline: ContinuousClock.Instant,
                                hintEntry: Pending?, recoveryEntry: Pending? = nil) async throws -> Resolution {
        try checkDeadline(deadline)
        let owner: V2RoomDataOwner
        do { owner = try await owners.owner(for: roomID) }
        catch { throw mapBeforeDispatch(error) }
        try checkDeadline(deadline)
        if let cached = cache[roomID], cached.owner == owner, recoveryEntry?.authoritativeRecovery != true,
           recoveryEntry?.failedCacheProbe.map({ cacheMatches($0) }) != true {
            if let hintEntry {
                let canInvoke = await transport.canInvokeCachedLocally(cached.token)
                try checkDeadline(deadline)
                guard cacheMatches(cached) else {
                    // 缓存已变化时，不能继续探测旧令牌。
                    return try await performResolve(roomID, deadline: deadline, hintEntry: nil, recoveryEntry: recoveryEntry)
                }
                if canInvoke, pending[roomID] === hintEntry,
                   !hintEntry.requiresPhysicalConfirmation {
                    return .localHint(cached)
                }
            }
            do {
                if try await transport.lookup(cached.token, deadline: locationLookupDeadline(deadline)), cacheMatches(cached) {
                    return .confirmed(cached.token)
                }
            } catch { /* 以如下数据库查找结果为准；绝不抢占有效租约。 */ }
            // Unavailability does not prove the owner or lease changed. Keep
            // this location hint until authoritative resolution replaces it.
        }
        let located: V2RoomActivationLease?
        let leaseReadStarted = clock.now
        do { located = try await leases.locate(roomID: roomID, owner: owner) }
        catch { throw mapBeforeDispatch(error) }
        recoveryEntry?.authoritativeRecovery = false
        if let lease = located {
            retainLease(lease, in: recoveryEntry, observedFrom: leaseReadStarted)
            return .confirmed(try await confirm(lease.token, roomID: roomID, owner: owner, deadline: deadline, recoveryEntry: recoveryEntry))
        }
        let candidates: [V2RoomHostCandidate]
        do { candidates = try await hosts.candidates(for: owner) }
        catch { throw mapBeforeDispatch(error) }
        let eligible = candidates.filter {
            $0.isHealthy && $0.availableRooms > 0 && $0.accessibleShardIDs.contains(owner.shardID)
        }.map { candidate in
            (candidate: candidate, score: Self.placementScore(roomID: roomID, hostID: candidate.identity.hostID))
        }.sorted { left, right in
            if left.candidate.availableRooms != right.candidate.availableRooms {
                return left.candidate.availableRooms > right.candidate.availableRooms
            }
            if left.score != right.score { return right.score.lexicographicallyPrecedes(left.score) }
            return left.candidate.identity.hostID.rawValue < right.candidate.identity.hostID.rawValue
        }
        for ranked in eligible {
            let candidate = ranked.candidate
            try checkDeadline(deadline)
            do {
                let activationStarted = clock.now
                let resolution = try await transport.activate(
                    on: candidate.identity, roomID: roomID, owner: owner, deadline: deadline
                )
                switch resolution {
                case .ready(let token):
                    guard token.host == candidate.identity else {
                        throw V2RoomCallFailure.notAccepted(.staleActivation)
                    }
                    return .confirmed(try await confirm(token, roomID: roomID, owner: owner, deadline: deadline))
                case .occupied(let lease):
                    retainLease(lease, in: recoveryEntry, observedFrom: activationStarted)
                    return .confirmed(try await confirm(lease.token, roomID: roomID, owner: owner, deadline: deadline, recoveryEntry: recoveryEntry))
                }
            } catch {
                // 获取操作可能已在传输故障前提交。
                // 考虑其他候选节点前须重新检查数据库。
                let recheckStarted = clock.now
                if let lease = try await leases.locate(roomID: roomID, owner: owner) {
                    retainLease(lease, in: recoveryEntry, observedFrom: recheckStarted)
                    return .confirmed(try await confirm(lease.token, roomID: roomID, owner: owner, deadline: deadline, recoveryEntry: recoveryEntry))
                }
                // 此次观测中不存在记录，不能证明执行中或结果不明的获取操作已回滚。
                // 这种情况下不能启动第二个宿主的获取操作。
                if (error as? V2RoomCallFailure) == .outcomeUnknown {
                    throw V2RoomCallFailure.outcomeUnknown
                }
            }
        }
        throw V2RoomCallFailure.notAccepted(.unavailable)
    }

    private func retainLease(_ lease: V2RoomActivationLease, in entry: Pending?,
                             observedFrom start: ContinuousClock.Instant) {
        let remaining = max(0, lease.expiresAt.timeIntervalSince(lease.databaseObservedAt))
        entry?.heldLease = (lease, start + .seconds(remaining))
    }

    /// Fixed-version rendezvous score for cold placement only. Incarnation is
    /// deliberately absent: a restart preserves host affinity, while SQL
    /// leases and full activation identities remain the authority for access.
    private static func placementScore(roomID: RoomID, hostID: V2ActorHostID) -> [UInt8] {
        var input = Data("IMV2.room-placement.rendezvous.v1\u{0}".utf8)
        for component in [roomID.rawValue, hostID.rawValue] {
            let bytes = Data(component.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(bytes)
        }
        return Array(SHA256.hash(data: input))
    }

    private func confirm(_ token: V2RoomActivationToken, roomID: RoomID,
                         owner: V2RoomDataOwner, deadline: ContinuousClock.Instant,
                         recoveryEntry: Pending? = nil) async throws -> V2RoomActivationToken {
        guard accepting else { throw V2RoomCallFailure.notAccepted(.retired) }
        guard token.roomID == roomID, token.owner == owner else {
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        let observedCache = cache[roomID]
        let probeDeadline = locationLookupDeadline(deadline)
        let found: Bool
        do { found = try await transport.lookup(token, deadline: probeDeadline) }
        catch {
            if error as? V2RoomCallFailure == .notAccepted(.deadlineExceeded),
               probeDeadline < deadline, clock.now < deadline, !Task.isCancelled,
               let recoveryEntry, recoveryEntry.demandRecovery,
               recoveryEntry.heldLease?.lease.token == token {
                throw DemandLeaseProbeTimeout(token: token)
            }
            throw error
        }
        guard found else { throw V2RoomCallFailure.notAccepted(.notReady) }
        guard accepting else { throw V2RoomCallFailure.notAccepted(.retired) }
        let installationChanged = observedCache.map { !cacheMatches($0) } ?? (cache[roomID] != nil)
        if installationChanged {
            guard let current = cache[roomID], current.token == token, current.owner == owner else {
                throw V2RoomCallFailure.notAccepted(.staleActivation)
            }
            return token // a late probe cannot reinstall over another revision or removal
        }
        if let old = cache[token.roomID]?.token, old != token,
           !token.isNewer(than: old) {
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        remember(token)
        return token
    }

    private func locationLookupDeadline(_ deadline: ContinuousClock.Instant) -> ContinuousClock.Instant {
        min(deadline, clock.now + Self.locationLookupTimeout)
    }

    private func cacheMatches(_ token: V2RoomActivationToken) -> Bool {
        cache[token.roomID]?.token == token && cache[token.roomID]?.owner == token.owner
    }

    private func cacheMatches(_ cached: Cached) -> Bool {
        guard let current = cache[cached.token.roomID] else { return false }
        return current.token == cached.token && current.owner == cached.owner && current.revision == cached.revision
    }

    func remember(_ token: V2RoomActivationToken) {
        if let old = cache[token.roomID]?.token, old != token {
            guard token.isNewer(than: old) else { return }
        }
        guard nextCacheRevision < UInt64.max else { return }
        nextCacheRevision += 1
        cache.remember(Cached(owner: token.owner, token: token, revision: nextCacheRevision),
            for: token.roomID)
    }

    private func invalidate(_ cached: Cached) {
        guard cacheMatches(cached) else { return }
        cache.removeValue(forKey: cached.token.roomID)
        count(&locationInvalidations)
    }

    private func complete(_ entry: Pending, with result: Result<Resolution, any Error>) {
        let waiters = entry.waiters
        entry.waiters.removeAll()
        waiterCount -= waiters.count
        for waiter in waiters.values {
            settleWaiter(waiter, result: waiter.deadline <= clock.now
                ? .failure(V2RoomCallFailure.notAccepted(.deadlineExceeded)) : result)
        }
    }

    private func settleWaiter(_ waiter: Waiter, result: Result<Resolution, any Error>) {
        waiter.timer?.cancel()
        if let began = waiter.stageStarted { finishRecoveryStage(.coldCallerWait, since: began) }
        switch waiter.sink {
        case .continuation(let continuation): continuation.resume(with: result)
        case .mailbox(let id, let room):
            guard let batch = recoveryMailboxes[id] else { return }
            batch.observers.removeValue(forKey: room)
            batch.results[room] = result
            let signal = batch.signal; batch.signal = nil; signal?.resume()
        }
    }

    private func removeWaiter(roomID: RoomID, generation: UUID, waiterID: UUID,
                              reason: V2RoomFailureReason) {
        guard let entry = pending[roomID], entry.generation == generation,
              let waiter = entry.waiters.removeValue(forKey: waiterID) else { return }
        waiterCount -= 1
        settleWaiter(waiter, result: .failure(V2RoomCallFailure.notAccepted(reason)))
        // Only an unstarted entry owns no actual location/activation work.
        // The generation guard above prevents an old timer removing a new entry.
        if entry.waiters.isEmpty, !entry.started {
            pending.removeValue(forKey: roomID)
            pendingQueue.removeAll { $0 == roomID }
            pump()
        }
    }

    private func checkDeadline(_ deadline: ContinuousClock.Instant) throws {
        guard accepting else { throw V2RoomCallFailure.notAccepted(.retired) }
        guard !Task.isCancelled else { throw V2RoomCallFailure.notAccepted(.cancelled) }
        guard clock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
    }

    private func mapBeforeDispatch(_ error: any Error) -> V2RoomCallFailure {
        if error as? V2RoomActivationLeaseError == .roomNotFound { return .notAccepted(.notFound) }
        return error as? V2RoomCallFailure ?? .notAccepted(.unavailable)
    }

    private struct Cached: Sendable {
        let owner: V2RoomDataOwner
        let token: V2RoomActivationToken
        let revision: UInt64
    }

    private struct DemandLeaseProbeTimeout: Error { let token: V2RoomActivationToken }

    private enum RecoveryPhase: Equatable { case usable, recovering, waitingForLease }

    private enum Resolution {
        case confirmed(V2RoomActivationToken)
        case localHint(Cached)

        var token: V2RoomActivationToken {
            switch self {
            case .confirmed(let token): token
            case .localHint(let cached): cached.token
            }
        }
    }

    private struct GroupKey: Hashable, Sendable {
        let host: V2ActorHostIdentity
        let owner: V2RoomDataOwner
    }

    private final class Pending {
        let roomID: RoomID
        let generation = UUID()
        var started = false
        var requiresPhysicalConfirmation = false
        var demandRecovery = false
        var authoritativeRecovery = false
        var cachedRecovery: Cached?
        var failedCacheProbe: Cached?
        var heldLease: (lease: V2RoomActivationLease, recheckAfter: ContinuousClock.Instant)?
        var recoveryPhase: RecoveryPhase = .usable
        var waiters: [UUID: Waiter] = [:]
        init(roomID: RoomID) { self.roomID = roomID }
    }

    private struct Waiter {
        let sink: WaiterSink
        let timer: Task<Void, Never>?
        let deadline: ContinuousClock.Instant
        let stageStarted: ContinuousClock.Instant?
    }
    private enum WaiterSink {
        case continuation(CheckedContinuation<Resolution, any Error>)
        case mailbox(UUID, RoomID)
    }
    private final class RecoveryMailbox {
        // Each room is in observers or results, never more than the original
        // <=128 input. All access remains on the Directory actor.
        var results: [RoomID: Result<Resolution, any Error>] = [:]
        var observers: [RoomID: (UUID, UUID)] = [:]
        var signal: CheckedContinuation<Void, Never>?
    }
}
