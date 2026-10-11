import Foundation
import Synchronization
import IMV2ActorContracts
import IMV2Core

public enum V2RoomActivationResolution: Equatable, Sendable {
    case ready(V2RoomActivationToken)
    case occupied(V2RoomActivationLease)
}



public struct V2RoomActivationDrainResult: Sendable {
    public let completed: Bool
    public let remainingRooms: Int
}

/// 负责一个进程实例的有界激活、租约续期和退役。
/// 每个回调在修改房间条目前，都要与本地代次和完整数据库令牌核对。
public actor V2RoomActivationHost<Request: Sendable, Response: Sendable> {
    private nonisolated let hostAdmission = V2RoomHostAdmission()
    private nonisolated let executionHandles = Mutex<[RoomID: V2RoomExecutionHandle<Request, Response>]>([:])
    private let identity: V2ActorHostIdentity
    private let leaseStore: any V2RoomActivationLeaseStore
    private let qualification: V2ActorServiceQualification
    private let configuration: V2RoomRuntimeConfiguration
    private let budget: V2RoomCommandBudget
    private let classify: @Sendable (Request) -> V2RoomTurnSchedulingClass
    private let factory: V2RoomActivationFactory<Request, Response>
    private let clock = ContinuousClock()
    private var started = false
    private var accepting = false
    private var entries: [RoomID: Entry] = [:]
    private var activationQueue: [RoomID] = []
    private var runningActivations = 0
    private var pendingRooms = 0
    private var waiterCount = 0
    // Pure snapshot reads retain lifecycle ownership, never a command reservation.
    private var recoveryBatchesInFlight = 0
    private var idleTask: Task<Void, Never>?
    private var qualificationWatchdog: Task<Void, Never>?
    private var qualificationWatchdogID: UUID?
    private var changeRevision: UInt64 = 0
    private var changeObserver: (id: UUID, continuation: AsyncStream<UInt64>.Continuation)?
    // Controlled scheduler seam: production leaves this nil. The observer runs
    // only after the real lane/budget settlement, before Host state cleanup.
    private var reservationFinishObserver: (@Sendable (V2RoomReservation) async -> Void)?

    func observeReservationFinish(_ observer: @escaping @Sendable (V2RoomReservation) async -> Void) {
        reservationFinishObserver = observer
    }

    public init(
        identity: V2ActorHostIdentity,
        leaseStore: any V2RoomActivationLeaseStore,
        configuration: V2RoomRuntimeConfiguration,
        budget: V2RoomCommandBudget,
        classify: @escaping @Sendable (Request) -> V2RoomTurnSchedulingClass,
        factory: V2RoomActivationFactory<Request, Response>,
        qualification: V2ActorServiceQualification = .standalone()
    ) {
        self.identity = identity
        self.leaseStore = leaseStore
        self.configuration = configuration
        self.budget = budget
        self.classify = classify
        self.factory = factory
        self.qualification = qualification
    }

    public func start() {
        guard !started else { return }
        started = true
        accepting = true
        hostAdmission.open()
        qualificationDidChange()
        idleTask = Task { [weak self] in await self?.idleLoop() }
    }

    /// The authenticated eligibility controller calls this after updating its
    /// shared proof. Membership alone never grants room ownership.
    public func qualificationDidChange() {
        let probe = V2SynchronousActorTurnProbe.start("host_qualification_scan")
        defer { probe?.finish() }
        qualificationWatchdog?.cancel(); qualificationWatchdog = nil
        qualificationWatchdogID = nil
        let proof = liveQualification()
        for entry in Array(entries.values) where proof?.generation != entry.qualificationGeneration {
            beginRetirement(entry, uncertain: true)
        }
        guard started, accepting, let proof else { signalChange(); return }
        let id = UUID(); qualificationWatchdogID = id
        qualificationWatchdog = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: proof.validUntil) } catch { return }
            await self?.qualificationDeadlineReached(id)
        }
        signalChange()
        pumpActivations()
    }

    private func qualificationDeadlineReached(_ id: UUID) {
        guard qualificationWatchdogID == id else { return }
        // An authenticated refresh may extend the same generation. Re-read its
        // exact current deadline, rather than treating an old timer as expiry.
        qualificationDidChange()
    }

    private func liveQualification() -> V2ActorServiceQualification.Snapshot? {
        guard let proof = qualification.snapshot(), clock.now < proof.validUntil else { return nil }
        return proof
    }

    private func hasQualification(_ entry: Entry) -> Bool {
        liveQualification()?.generation == entry.qualificationGeneration
    }

    public func snapshot() -> V2RoomActivationHostSnapshot {
        let probe = V2SynchronousActorTurnProbe.start("host_snapshot_scan")
        defer { probe?.finish() }
        return .init(
            accepting: accepting && liveQualification() != nil,
            activeRooms: entries.values.filter { $0.phase == .ready && isSafe($0) }.count,
            pendingRooms: pendingRooms,
            activationWaiters: waiterCount,
            restoringRooms: runningActivations,
            retiringRooms: entries.values.filter { $0.phase == .draining || $0.phase == .uncertain }.count
        )
    }

    /// 本地接待组件可依据此有界权威集合核对 Actor 的强引用。
    /// 完整令牌可防止过期回调删除替代的激活实例。
    public func readyTokens() -> [V2RoomActivationToken] {
        let probe = V2SynchronousActorTurnProbe.start("host_ready_tokens_scan")
        defer { probe?.finish() }
        return entries.values.compactMap { entry in
            entry.phase == .ready && isSafe(entry) ? entry.token : nil
        }
    }

    /// Constant-time readiness for an exact activation. This uses the same
    /// authority and watchdog checks as invocation; it never acquires a lease.
    public func isReady(token: V2RoomActivationToken) -> Bool {
        (try? readyEntry(token)) != nil
    }

    /// 单个本地观察者接收有界且合并后的变更信号，随后核对 `readyTokens()`。
    /// 缓慢的观察者不能阻塞续期或 SQL。
    public func changes() -> AsyncStream<UInt64> {
        changeObserver?.continuation.finish()
        let id = UUID()
        let (stream, continuation) = AsyncStream<UInt64>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        changeObserver = (id, continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeChangeObserver(id: id) }
        }
        continuation.yield(changeRevision)
        return stream
    }

    private func removeChangeObserver(id: UUID) {
        if changeObserver?.id == id { changeObserver = nil }
    }

    private func signalChange() {
        changeRevision &+= 1
        changeObserver?.continuation.yield(changeRevision)
    }

    public func activate(
        roomID: RoomID,
        owner: V2RoomDataOwner,
        deadline: ContinuousClock.Instant
    ) async throws -> V2RoomActivationResolution {
        guard started, accepting else { throw V2RoomCallFailure.notAccepted(.retired) }
        guard let proof = liveQualification() else { throw V2RoomCallFailure.notAccepted(.unavailable) }
        guard !Task.isCancelled else { throw V2RoomCallFailure.notAccepted(.cancelled) }
        guard clock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        guard waiterCount < configuration.maximumActivationWaitersPerHost else {
            throw V2RoomCallFailure.notAccepted(.overloaded)
        }
        if let entry = entries[roomID] {
            guard hasQualification(entry) else {
                beginRetirement(entry, uncertain: true)
                throw V2RoomCallFailure.notAccepted(.leaseLost)
            }
            guard entry.owner == owner else { throw V2RoomCallFailure.notAccepted(.staleActivation) }
            switch entry.phase {
            case .ready:
                guard let token = entry.token, isSafe(entry) else {
                    if let token = entry.token { scheduleLeaseLoss(roomID: roomID, generation: entry.generation, token: token) }
                    throw V2RoomCallFailure.notAccepted(.leaseLost)
                }
                return .ready(token)
            case .acquiring, .restoring: break
            case .draining, .uncertain, .stopped:
                throw V2RoomCallFailure.notAccepted(.retired)
            }
        } else {
            guard entries.count < configuration.maximumActiveRooms,
                  pendingRooms < configuration.maximumPendingActivations
            else { throw V2RoomCallFailure.notAccepted(.overloaded) }
            let entry = Entry(roomID: roomID, owner: owner, qualificationGeneration: proof.generation)
            entries[roomID] = entry
            pendingRooms += 1
            activationQueue.append(roomID)
        }
        guard let entry = entries[roomID],
              entry.waiters.count < configuration.maximumActivationWaitersPerRoom,
              waiterCount < configuration.maximumActivationWaitersPerHost
        else { throw V2RoomCallFailure.notAccepted(.overloaded) }
        let waiterID = UUID()
        let generation = entry.generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: V2RoomCallFailure.notAccepted(.cancelled))
                    if entry.waiters.isEmpty && !entry.activationJobRunning && entry.phase == .acquiring {
                        activationQueue.removeAll { $0 == roomID }
                        clearPending(entry)
                        entries.removeValue(forKey: roomID)
                        pumpActivations()
                    }
                    return
                }
                let timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) }
                    catch { return }
                    await self?.removeWaiter(roomID: roomID, generation: generation,
                                             waiterID: waiterID, reason: .deadlineExceeded)
                }
                entry.waiters[waiterID] = Waiter(
                    continuation: continuation, timer: timer, deadline: deadline
                )
                waiterCount += 1
                pumpActivations()
            }
        } onCancel: {
            Task { await self.removeWaiter(roomID: roomID, generation: generation,
                                           waiterID: waiterID, reason: .cancelled) }
        }
    }

    /// Ready room calls do not rendezvous with the node-wide lifecycle actor.
    public nonisolated func executionHandle(token: V2RoomActivationToken) throws -> V2RoomExecutionHandle<Request, Response> {
        guard hostAdmission.isAccepting, let handle = executionHandles.withLock({ $0[token.roomID] }), handle.token == token else {
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        return handle
    }

    public nonisolated func invoke(token: V2RoomActivationToken, request: Request,
                                   deadline: ContinuousClock.Instant) async throws -> Response {
        if factory.pureRoomLogPull != nil,
           let concrete = request as? V2RoomRequest, case .roomLog(.pull) = concrete {
            return try await invokePureRead(token: token, request: request, deadline: deadline)
        }
        if factory.pureSubscriptionRenew != nil,
           let concrete = request as? V2RoomRequest, case .roomSubscription(.renew) = concrete {
            return try await invokePureRenew(token: token, request: request, deadline: deadline)
        }
        return try await executionHandle(token: token).invoke(decodedInvocation: V2RoomInvocation(request), deadline: deadline)
    }

    private func invokePureRead(token: V2RoomActivationToken,
                               request: Request, deadline: ContinuousClock.Instant) async throws -> Response {
        let entry = try readyEntry(token)
        guard let execute = factory.pureRoomLogPull else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        if let request = request as? V2RoomRequest, request.roomID != token.roomID {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        return try await invokePinnedRead(entry: entry, token: token,
            request: request, deadline: deadline, execute: execute)
    }

    private func invokePureRenew(token: V2RoomActivationToken,
                                 request: Request, deadline: ContinuousClock.Instant) async throws -> Response {
        guard let concrete = request as? V2RoomRequest, concrete.roomID == token.roomID,
              case .roomSubscription(.renew) = concrete,
              let execute = factory.pureSubscriptionRenew else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        let entry = try readyEntry(token)
        guard let validUntil = entry.executionAuthority?.deadline() else {
            throw V2RoomCallFailure.notAccepted(.leaseLost)
        }
        return try await invokePinnedRead(entry: entry, token: token,
            request: request, deadline: deadline, execute: { token, request, deadline in
                await execute(token, request, deadline, validUntil)
            })
    }

    private func invokePinnedRead(
        entry: Entry, token: V2RoomActivationToken,
        request: Request, deadline: ContinuousClock.Instant,
        execute: @Sendable (V2RoomActivationToken, Request, ContinuousClock.Instant) async -> V2RoomTransactionCompletion<Response>
    ) async throws -> Response {
        guard clock.now < deadline, !Task.isCancelled else {
            throw V2RoomCallFailure.notAccepted(Task.isCancelled ? .cancelled : .deadlineExceeded)
        }
        // Retain the exact lifecycle while executing the read. The same
        // count/bytes limits apply to reads and queued write-lane submissions.
        entry.inFlightCalls += 1
        defer { entry.inFlightCalls -= 1 }
        let permit = try budget.acquire(roomID: token.roomID, byteCount: V2ActorPayloadBudget.retainedBytes(of: request))
        do {
            guard entries[token.roomID] === entry, try readyEntry(token) === entry else {
                throw V2RoomCallFailure.notAccepted(.staleActivation)
            }
            guard clock.now < deadline, !Task.isCancelled else {
                throw V2RoomCallFailure.notAccepted(Task.isCancelled ? .cancelled : .deadlineExceeded)
            }
        } catch {
            budget.release(permit)
            throw error
        }
        // No separate Task, timeout release, or write-executor invalidation.
        // A caller cancellation cannot return this permit before the read/proof
        // execution and its owned callback have settled.
        let completion = await execute(token, request, deadline)
        budget.release(permit)
        switch completion {
        case .committed(let value):
            // Graceful drain closes new admission but permits an already owned
            // read to finish while the exact lease and qualification remain safe.
            guard entries[token.roomID] === entry, entry.token == token,
                  entry.phase == .ready || entry.phase == .draining else {
                throw V2RoomCallFailure.notAccepted(.staleActivation)
            }
            guard isSafe(entry) else { throw V2RoomCallFailure.notAccepted(.leaseLost) }
            guard clock.now < deadline, !Task.isCancelled else {
                throw V2RoomCallFailure.notAccepted(Task.isCancelled ? .cancelled : .deadlineExceeded)
            }
            return value
        case .rolledBack(let reason): throw V2RoomCallFailure.rolledBack(reason)
        // An unknown callback remains unknown even after retirement/deadline;
        // Read/proof uncertainty never poisons the separate write executor.
        case .outcomeUnknown: throw V2RoomCallFailure.outcomeUnknown
        }
    }

    public func reserve(
        token: V2RoomActivationToken,
        requestID: UUID,
        deadline: ContinuousClock.Instant
    ) async throws -> V2RoomReservation {
        let entry = try readyEntry(token)
        guard let lane = entry.lane else { throw V2RoomCallFailure.notAccepted(.notReady) }
        entry.inFlightCalls += 1
        defer { entry.inFlightCalls -= 1 }
        do {
            let grant = try await lane.reserve(requestID: requestID, deadline: deadline)
            guard entries[token.roomID] === entry, entry.token == token,
                  (entry.phase == .ready || entry.phase == .draining),
                  isSafe(entry), !Task.isCancelled else {
                _ = await lane.abortReservation(grant)
                throw V2RoomCallFailure.notAccepted(.leaseLost)
            }
            entry.heldReservation = grant
            entry.reservationDispatched = false
            return grant
        } catch {
            throw error
        }
    }

    public func markReservationDispatched(_ grant: V2RoomReservation) async throws {
        guard let entry = entries[grant.token.roomID], entry.token == grant.token,
              entry.phase == .ready || entry.phase == .draining,
              isSafe(entry) else { throw V2RoomCallFailure.notAccepted(.staleActivation) }
        guard entry.heldReservation == grant, !entry.reservationDispatched else {
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        guard let lane = entry.lane else { throw V2RoomCallFailure.notAccepted(.notReady) }
        try await lane.markReservationDispatched(grant)
        guard entries[grant.token.roomID] === entry, entry.heldReservation == grant,
              (entry.phase == .ready || entry.phase == .draining), isSafe(entry) else {
            scheduleLeaseLoss(roomID: grant.token.roomID, generation: entry.generation,
                              token: grant.token)
            throw V2RoomCallFailure.notAccepted(.leaseLost)
        }
        entry.reservationDispatched = true
    }

    public func abortReservation(_ grant: V2RoomReservation) async -> Bool {
        guard let entry = entries[grant.token.roomID], entry.token == grant.token,
              entry.heldReservation == grant, !entry.reservationDispatched,
              let lane = entry.lane else { return false }
        let aborted = await lane.abortReservation(grant)
        if aborted, entries[grant.token.roomID] === entry, entry.heldReservation == grant {
            entry.heldReservation = nil
            entry.reservationDispatched = false
        }
        return aborted
    }

    /// 重复的完成通知不会让执行器状态失效两次。屏障一直保持到失效操作结束；
    /// 之后通道才可完成并接受下一轮次。
    /// A different held grant proves the preceding lane already settled. Its
    /// late Host continuation cannot block completion of the current grant.
    public func finishReservation(
        _ grant: V2RoomReservation,
        completion: V2RoomReservationCompletion
    ) async -> Bool {
        guard let entry = entries[grant.token.roomID], entry.token == grant.token,
              (entry.phase == .ready || entry.phase == .draining),
              entry.heldReservation == grant, entry.reservationDispatched,
              entry.finishingReservation != grant, let lane = entry.lane,
              let executor = entry.executor else { return false }
        entry.finishingReservation = grant
        defer {
            if entries[grant.token.roomID] === entry, entry.finishingReservation == grant {
                entry.finishingReservation = nil
            }
        }
        let snapshot = await lane.snapshot()
        guard snapshot.hasReservation, entries[grant.token.roomID] === entry,
              entry.token == grant.token, isSafe(entry),
              entry.phase == .ready || entry.phase == .draining else {
            if !isSafe(entry) { scheduleLeaseLoss(roomID: grant.token.roomID,
                                                   generation: entry.generation, token: grant.token) }
            return false
        }
        // 调用方取消不能缩短执行器失效流程，
        // 也不能把结果不明的 SQL 转成可安全释放的屏障。
        let invalidation = Task.detached { await executor.invalidateReservation(grant) }
        await invalidation.value
        guard entries[grant.token.roomID] === entry,
              entry.token == grant.token, entry.finishingReservation == grant,
              isSafe(entry), entry.phase == .ready || entry.phase == .draining else {
            if !isSafe(entry) { scheduleLeaseLoss(roomID: grant.token.roomID,
                                                   generation: entry.generation, token: grant.token) }
            return false
        }
        let finished = await lane.finishReservation(grant, completion: completion)
        if let reservationFinishObserver { await reservationFinishObserver(grant) }
        // The lane has already released its permit and may have admitted a
        // successor while this continuation was suspended. Never clear that
        // successor's Host capability with the old grant's completion.
        if finished, entries[grant.token.roomID] === entry, entry.heldReservation == grant {
            entry.heldReservation = nil
            entry.reservationDispatched = false
        }
        return finished
    }

    /// 在向任何通道让出执行权前关闭准入。已接受的调用和预留
    /// 继续持有租约，直到其事务结束。
    public func beginDrain() async {
        guard accepting else { return }
        accepting = false
        hostAdmission.close()
        qualificationWatchdog?.cancel(); qualificationWatchdog = nil; qualificationWatchdogID = nil
        idleTask?.cancel()
        for entry in Array(entries.values) { beginRetirement(entry, uncertain: false) }
    }

    public func drain(deadline: ContinuousClock.Instant) async -> V2RoomActivationDrainResult {
        await beginDrain()
        while !entries.isEmpty && clock.now < deadline {
            do { try await clock.sleep(for: .milliseconds(10)) }
            catch { break }
        }
        if entries.isEmpty { await leaseStore.shutdownRenewals() }
        return .init(completed: entries.isEmpty, remainingRooms: entries.count)
    }

    public func stop(deadline: ContinuousClock.Instant) async -> V2RoomActivationDrainResult {
        await drain(deadline: deadline)
    }

    private func readyEntry(_ token: V2RoomActivationToken) throws -> Entry {
        guard accepting, let entry = entries[token.roomID], entry.token == token else {
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        guard entry.phase == .ready else { throw V2RoomCallFailure.notAccepted(.retired) }
        guard isSafe(entry) else {
            scheduleLeaseLoss(roomID: token.roomID, generation: entry.generation, token: token)
            throw V2RoomCallFailure.notAccepted(.leaseLost)
        }
        return entry
    }

    private func isSafe(_ entry: Entry) -> Bool {
        guard hasQualification(entry), let safetyUntil = entry.safetyUntil else { return false }
        return clock.now < safetyUntil
    }

    private func pumpActivations() {
        guard accepting, liveQualification() != nil else { return }
        while runningActivations < configuration.maximumConcurrentRestores, !activationQueue.isEmpty {
            let roomID = activationQueue.removeFirst()
            guard let entry = entries[roomID], entry.phase == .acquiring else { continue }
            guard hasQualification(entry) else { beginRetirement(entry, uncertain: true); continue }
            runningActivations += 1
            let generation = entry.generation
            entry.activationJobRunning = true
            Task { [weak self] in await self?.activateEntry(roomID: roomID, generation: generation) }
        }
    }

    private func activateEntry(roomID: RoomID, generation: UUID) async {
        defer { activationFinished(roomID: roomID, generation: generation) }
        guard let entry = entries[roomID], entry.generation == generation,
              entry.phase == .acquiring else { return }
        guard accepting, hasQualification(entry) else { beginRetirement(entry, uncertain: true); return }
        let startedAt = clock.now
        do {
            let acquisition = try await leaseStore.acquire(
                roomID: roomID, owner: entry.owner, host: identity, duration: configuration.leaseDuration
            )
            switch acquisition {
            case .occupied(let lease):
                guard hasQualification(entry), entry.phase == .acquiring else {
                    beginRetirement(entry, uncertain: true); return
                }
                if lease.token.roomID == roomID, lease.token.owner == entry.owner {
                    finishPending(entry, result: .success(.occupied(lease)))
                } else {
                    finishPending(entry, result: .failure(V2RoomCallFailure.notAccepted(.unavailable)))
                }
            case .acquired(let lease):
                guard lease.token.roomID == roomID, lease.token.owner == entry.owner,
                      lease.token.host == identity else {
                    // 即使存储响应损坏，也可能持有已提交的令牌。
                    // 保留容量，并重试按条件释放。
                    entry.token = lease.token
                    entry.lease = lease
                    beginRetirement(entry, uncertain: true)
                    return
                }
                guard adoptLease(entry, lease: lease, callStartedAt: startedAt) else { return }
                let executor = factory.make(lease.token)
                entry.executor = executor
                entry.restoreInFlight = true
                let restoreDeadline = min(clock.now + configuration.callTimeout.duration,
                                          entry.safetyUntil ?? clock.now)
                entry.restoreTimer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: restoreDeadline) }
                    catch { return }
                    await self?.restoreTimedOut(roomID: roomID, generation: generation,
                                                token: lease.token)
                }
                do {
                    try await executor.restore(restoreDeadline)
                    entry.restoreInFlight = false
                    entry.restoreTimer?.cancel()
                    guard entries[roomID] === entry else { await executor.close(); return }
                    guard entry.phase == .restoring, isSafe(entry), clock.now < restoreDeadline else {
                        beginRetirement(entry, uncertain: true)
                        return
                    }
                    let authority = V2RoomExecutionAuthority(safetyUntil: entry.safetyUntil!,
                        qualification: qualification, generation: entry.qualificationGeneration, hostAdmission: hostAdmission)
                    entry.executionAuthority = authority
                    entry.lane = V2RoomTurnLane(
                        token: lease.token, configuration: configuration, budget: budget,
                        classify: classify, execute: { [authority] turn in
                            // Retirement closes authority synchronously before the lane's
                            // asynchronous drain callback; already dispatched SQL retains ownership.
                            guard let validUntil = authority.deadline() else { return .rolledBack(.leaseLost) }
                            let context = V2RoomTurnContext(token: turn.context.token, turnID: turn.context.turnID,
                                batchDeadline: turn.context.batchDeadline, activationValidUntil: validUntil,
                                queueWaitDuration: turn.context.queueWaitDuration)
                            return await executor.execute(.init(context: context, items: turn.items))
                        },
                        onUncertain: { [weak self] token in
                            // 通道消费方绝不等待退役完成。
                            await self?.scheduleLeaseLoss(roomID: token.roomID,
                                                          generation: generation, token: token)
                        }
                    )
                    entry.phase = .ready
                    authority.setPhase(.ready)
                    let handle = V2RoomExecutionHandle(token: lease.token, lane: entry.lane!, authority: authority)
                    executionHandles.withLock { $0[roomID] = handle }
                    clearPending(entry)
                    signalChange()
                    completeWaiters(entry, result: .success(.ready(lease.token)))
                } catch {
                    entry.restoreInFlight = false
                    entry.restoreTimer?.cancel()
                    guard entries[roomID] === entry else { await executor.close(); return }
                    completeWaiters(entry, result: .failure(V2RoomCallFailure.notAccepted(.unavailable)))
                    beginRetirement(entry, uncertain: false)
                }
            }
        } catch {
            guard entries[roomID] === entry else { return }
            if error as? V2RoomActivationLeaseError == .outcomeUnknown {
                // 可能已有提交的租约，却没有返回令牌可供恢复或释放。
                // 该租约会保持占用直到数据库判定过期。
                finishPending(entry, result: .failure(V2RoomCallFailure.outcomeUnknown))
                return
            }
            let reason: V2RoomFailureReason = error as? V2RoomActivationLeaseError == .roomNotFound
                ? .notFound : .unavailable
            finishPending(entry, result: .failure(V2RoomCallFailure.notAccepted(reason)))
        }
    }

    private func activationFinished(roomID: RoomID, generation: UUID) {
        if let entry = entries[roomID], entry.generation == generation {
            entry.activationJobRunning = false
        }
        runningActivations -= 1
        pumpActivations()
    }

    private func restoreTimedOut(roomID: RoomID, generation: UUID, token: V2RoomActivationToken) {
        guard let entry = entries[roomID], entry.generation == generation,
              entry.token == token, entry.restoreInFlight, entry.phase == .restoring else { return }
        beginRetirement(entry, uncertain: true)
    }

    private func adoptLease(_ entry: Entry, lease: V2RoomActivationLease,
                            callStartedAt: ContinuousClock.Instant) -> Bool {
        guard entries[entry.roomID] === entry else { return false }
        entry.token = lease.token
        entry.lease = lease
        guard entry.phase == .acquiring, hasQualification(entry),
              let safety = safetyDeadline(lease, callStartedAt: callStartedAt), safety > clock.now else {
            beginRetirement(entry, uncertain: true)
            return false
        }
        entry.safetyUntil = safety
        entry.phase = .restoring
        let roomID = entry.roomID
        let generation = entry.generation
        entry.renewTask = Task { [weak self] in
            await self?.renewLoop(roomID: roomID, generation: generation, token: lease.token)
        }
        setWatchdog(entry, until: safety)
        return true
    }

    /// 数据库观测只提供时长，不提供本地墙上时钟的过期时刻。
    /// 从数据库调用开始计时，会保守地将网络与等锁时间计入已用时长。
    private func safetyDeadline(_ lease: V2RoomActivationLease,
                                callStartedAt: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        let milliseconds = Int64((lease.expiresAt.timeIntervalSince(lease.databaseObservedAt) * 1_000).rounded(.down))
        guard milliseconds > configuration.renewalSafetyMargin.rawValue else { return nil }
        return callStartedAt + .milliseconds(milliseconds - configuration.renewalSafetyMargin.rawValue)
    }

    private func renewLoop(roomID: RoomID, generation: UUID, token: V2RoomActivationToken) async {
        while true {
            do { try await clock.sleep(for: configuration.renewalInterval.duration) }
            catch { return }
            guard let entry = entries[roomID], entry.generation == generation,
                  entry.token == token,
                  entry.phase == .restoring || entry.phase == .ready || entry.phase == .draining
            else { return }
            guard isSafe(entry) else {
                scheduleLeaseLoss(roomID: roomID, generation: generation, token: token)
                return
            }
            let startedAt = clock.now
            do {
                entry.renewalInFlight = true
                defer { entry.renewalInFlight = false }
                let lease = try await leaseStore.renew(token: token, duration: configuration.leaseDuration)
                guard entries[roomID] === entry, entry.token == token,
                      entry.phase == .restoring || entry.phase == .ready || entry.phase == .draining
                else { return }
                guard isSafe(entry) else {
                    scheduleLeaseLoss(roomID: roomID, generation: generation, token: token)
                    return
                }
                guard lease.token == token,
                      let safety = safetyDeadline(lease, callStartedAt: startedAt),
                      safety > clock.now else {
                    scheduleLeaseLoss(roomID: roomID, generation: generation, token: token)
                    return
                }
                entry.lease = lease
                entry.safetyUntil = safety
                entry.executionAuthority?.renew(until: safety)
                setWatchdog(entry, until: safety)
            } catch V2RoomActivationLeaseError.renewalDeferred {
                // A confirmed unsuccessful attempt supplies no new authority.
                // Keep the original watchdog and lease untouched; the next
                // attempt follows the normal interval and rechecks safety.
                guard entries[roomID] === entry, entry.generation == generation,
                      entry.token == token,
                      entry.phase == .restoring || entry.phase == .ready || entry.phase == .draining
                else { return }
                guard isSafe(entry) else {
                    scheduleLeaseLoss(roomID: roomID, generation: generation, token: token)
                    return
                }
            } catch {
                scheduleLeaseLoss(roomID: roomID, generation: generation, token: token)
                return
            }
        }
    }

    private func setWatchdog(_ entry: Entry, until deadline: ContinuousClock.Instant) {
        let probe = V2SynchronousActorTurnProbe.start("host_watchdog_update")
        defer { probe?.finish() }
        entry.watchdogTask?.cancel()
        let roomID = entry.roomID
        let generation = entry.generation
        let token = entry.token
        entry.watchdogTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) }
            catch { return }
            guard let token else { return }
            await self?.watchdogExpired(roomID: roomID, generation: generation,
                                        token: token, expectedDeadline: deadline)
        }
    }

    private func watchdogExpired(roomID: RoomID, generation: UUID, token: V2RoomActivationToken,
                                 expectedDeadline: ContinuousClock.Instant) {
        guard let entry = entries[roomID], entry.generation == generation,
              entry.token == token, entry.safetyUntil == expectedDeadline,
              !isSafe(entry) else { return }
        scheduleLeaseLoss(roomID: roomID, generation: generation, token: token)
    }

    private func scheduleLeaseLoss(roomID: RoomID, generation: UUID, token: V2RoomActivationToken) {
        guard let entry = entries[roomID], entry.generation == generation,
              entry.token == token else { return }
        beginRetirement(entry, uncertain: true)
    }

    private func beginRetirement(_ entry: Entry, uncertain: Bool) {
        guard entries[entry.roomID] === entry, entry.phase != .stopped else { return }
        if entry.phase == .uncertain || (entry.phase == .draining && !uncertain) { return }
        let wasReady = entry.phase == .ready
        if uncertain { entry.phase = .uncertain }
        else if entry.phase != .uncertain { entry.phase = .draining }
        entry.executionAuthority?.setPhase(entry.phase)
        // Keep a closed handle until retirement completes so exact callers retain
        // the existing retired result; process drain removes public admission immediately.
        if !accepting {
            executionHandles.withLock { handles in
                if handles[entry.roomID]?.token == entry.token { handles.removeValue(forKey: entry.roomID) }
            }
        }
        if wasReady { signalChange() }
        completeWaiters(entry, result: .failure(V2RoomCallFailure.notAccepted(
            uncertain ? .leaseLost : .retired
        )))
        if let lane = entry.lane {
            Task {
                if uncertain { await lane.loseLease() }
                else { await lane.beginDrain() }
            }
        }
        guard entry.retireTask == nil else { return }
        let roomID = entry.roomID
        let generation = entry.generation
        entry.retireTask = Task { [weak self] in
            await self?.retireLoop(roomID: roomID, generation: generation)
        }
    }

    private func retireLoop(roomID: RoomID, generation: UUID) async {
        var retryDelayMilliseconds: Int64 = 25
        while true {
            guard let entry = entries[roomID], entry.generation == generation else { return }
            if !entry.activationJobRunning && !entry.restoreInFlight && !entry.renewalInFlight &&
                entry.inFlightCalls == 0 && (entry.executionAuthority?.inFlight ?? 0) == 0 && entry.finishingReservation == nil {
                let laneSnapshot = await entry.lane?.snapshot()
                guard entries[roomID] === entry else { return }
                if laneSnapshot == nil || (laneSnapshot!.executingCount == 0 &&
                                           laneSnapshot!.queuedCount == 0 && !laneSnapshot!.hasReservation) {
                    if await closeAndRelease(entry) { return }
                    retryDelayMilliseconds = min(retryDelayMilliseconds * 2, 5_000)
                }
            }
            do { try await clock.sleep(for: .milliseconds(retryDelayMilliseconds)) }
            catch { return }
        }
    }

    private func closeAndRelease(_ entry: Entry) async -> Bool {
        guard entries[entry.roomID] === entry else { return true }
        if !entry.executorClosed {
            entry.executorClosed = true
            await entry.executor?.close()
        }
        guard entries[entry.roomID] === entry else { return true }
        if let token = entry.token {
            do { _ = try await leaseStore.release(token: token) }
            catch { return false }
        }
        guard entries[entry.roomID] === entry else { return true }
        if let lane = entry.lane {
            guard await lane.completeRetirement() else { return false }
        }
        entry.renewTask?.cancel()
        entry.watchdogTask?.cancel()
        entry.restoreTimer?.cancel()
        clearPending(entry)
        entry.phase = .stopped
        entry.executionAuthority?.setPhase(.stopped)
        executionHandles.withLock { handles in
            if handles[entry.roomID]?.token == entry.token { handles.removeValue(forKey: entry.roomID) }
        }
        entries.removeValue(forKey: entry.roomID)
        return true
    }

    private func finishPending(_ entry: Entry, result: Result<V2RoomActivationResolution, any Error>) {
        guard entries[entry.roomID] === entry else { return }
        clearPending(entry)
        completeWaiters(entry, result: result)
        entries.removeValue(forKey: entry.roomID)
    }

    private func completeWaiters(_ entry: Entry, result: Result<V2RoomActivationResolution, any Error>) {
        let waiters = entry.waiters
        entry.waiters.removeAll()
        waiterCount -= waiters.count
        for waiter in waiters.values {
            waiter.timer.cancel()
            if waiter.deadline <= clock.now {
                waiter.continuation.resume(throwing: V2RoomCallFailure.notAccepted(.deadlineExceeded))
            } else {
                waiter.continuation.resume(with: result)
            }
        }
    }

    private func clearPending(_ entry: Entry) {
        if entry.countedPending {
            entry.countedPending = false
            pendingRooms -= 1
        }
    }

    private func removeWaiter(roomID: RoomID, generation: UUID, waiterID: UUID,
                              reason: V2RoomFailureReason) {
        guard let entry = entries[roomID], entry.generation == generation,
              let waiter = entry.waiters.removeValue(forKey: waiterID) else { return }
        waiterCount -= 1
        waiter.timer.cancel()
        waiter.continuation.resume(throwing: V2RoomCallFailure.notAccepted(reason))
        // Acquiring jobs become actual owners before their Task is created.
        // Never remove started work or a lease just because its caller leaves.
        if entry.waiters.isEmpty, !entry.activationJobRunning, entry.phase == .acquiring {
            activationQueue.removeAll { $0 == roomID }
            clearPending(entry)
            entries.removeValue(forKey: roomID)
            pumpActivations()
        }
    }

    private func idleLoop() async {
        while accepting {
            do { try await clock.sleep(for: min(configuration.idleTimeout.duration, .seconds(1))) }
            catch { return }
            guard accepting else { return }
            var probe = V2SynchronousActorTurnProbe.start("host_idle_scan")
            for entry in Array(entries.values) where entry.phase == .ready && entry.inFlightCalls == 0 && (entry.executionAuthority?.inFlight ?? 0) == 0 {
                guard let lane = entry.lane else { continue }
                let cutoff = clock.now - configuration.idleTimeout.duration
                guard !lane.wasActive(after: cutoff) else { continue }
                probe?.finish(); probe = nil
                let claimed = await lane.beginIdleDrain(ifLastActivityAtOrBefore: cutoff)
                probe = V2SynchronousActorTurnProbe.start("host_idle_scan")
                guard entries[entry.roomID] === entry, entry.phase == .ready else { continue }
                if claimed { beginRetirement(entry, uncertain: false) }
            }
            probe?.finish()
        }
    }

    private final class Entry {
        let roomID: RoomID
        let owner: V2RoomDataOwner
        let generation = UUID()
        var phase: V2RoomActivationPhase = .acquiring
        var countedPending = true
        var activationJobRunning = false
        var waiters: [UUID: Waiter] = [:]
        var token: V2RoomActivationToken?
        var lease: V2RoomActivationLease?
        var safetyUntil: ContinuousClock.Instant?
        var executionAuthority: V2RoomExecutionAuthority?
        var lane: V2RoomTurnLane<Request, Response>?
        var executor: V2RoomActivationExecutor<Request, Response>?
        var executorClosed = false
        var restoreInFlight = false
        var renewalInFlight = false
        var inFlightCalls = 0
        var finishingReservation: V2RoomReservation?
        var heldReservation: V2RoomReservation?
        var reservationDispatched = false
        var renewTask: Task<Void, Never>?
        var watchdogTask: Task<Void, Never>?
        var restoreTimer: Task<Void, Never>?
        var retireTask: Task<Void, Never>?

        let qualificationGeneration: UUID

        init(roomID: RoomID, owner: V2RoomDataOwner, qualificationGeneration: UUID) {
            self.roomID = roomID
            self.owner = owner
            self.qualificationGeneration = qualificationGeneration
        }
    }

    private struct Waiter {
        let continuation: CheckedContinuation<V2RoomActivationResolution, any Error>
        let timer: Task<Void, Never>
        let deadline: ContinuousClock.Instant
    }
}

public extension V2RoomActivationHost where Request == V2RoomRequest, Response == V2RoomResponse {
    /// Pure state snapshots pin each exact ready activation until the actual
    /// owner SQL settles, independently of the room's command lane.
    func invokeRecoveryBatch(items: [V2RoomRecoveryBatchCallItem],
                             deadline: ContinuousClock.Instant) async -> [V2RoomRecoveryBatchCallOutcome] {
        func rejected(_ item: V2RoomRecoveryBatchCallItem, _ failure: V2RoomCallFailure) -> V2RoomRecoveryBatchCallOutcome {
            .init(token: item.token, query: item.query, outcome: .failure(failure))
        }
        guard !items.isEmpty, items.count <= 100, let execute = factory.recoveryBatch,
              items.allSatisfy({ $0.query.kind == .state && $0.token.roomID == $0.query.roomID && $0.token.host == identity }),
              Set(items.map { RecoveryPair(room: $0.token.roomID, viewer: $0.query.actorUserID) }).count == items.count,
              Set(items.map { $0.token.owner }).count == 1 else {
            return items.map { rejected($0, .notAccepted(.invalidRequest)) }
        }
        let requestBytes = V2ActorPayloadBudget.retainedBytes(of: items.map {
            V2RoomRecoveryBatchWireItem(token: $0.token, query: $0.query)
        })
        guard requestBytes <= 64 * 1_024 else {
            return items.map { rejected($0, .notAccepted(.invalidRequest)) }
        }
        let end = min(deadline, items.map(\.deadline).min()!)
        guard started, accepting, recoveryBatchesInFlight < 4 else {
            return items.map { rejected($0, .notAccepted(accepting ? .overloaded : .retired)) }
        }
        guard !Task.isCancelled, clock.now < end else {
            return items.map { rejected($0, .notAccepted(Task.isCancelled ? .cancelled : .deadlineExceeded)) }
        }
        let rooms = Dictionary(grouping: items.indices, by: { items[$0].token.roomID })
        var failures: [Int: V2RoomCallFailure] = [:]
        var pins: [RoomID: Entry] = [:]
        // Synchronous exact lifecycle admission: no room is held while waiting
        // for another room's command lane. SQL remains the token authority.
        for (room, indices) in rooms {
            let token = items[indices[0]].token
            do {
                guard indices.allSatisfy({ items[$0].token == token }) else {
                    throw V2RoomCallFailure.notAccepted(.staleActivation)
                }
                pins[room] = try readyEntry(token)
            } catch {
                let failure = (error as? V2RoomCallFailure) ?? .notAccepted(.unavailable)
                for index in indices { failures[index] = failure }
            }
        }
        let selected = items.indices.filter { failures[$0] == nil }
        var answers: [Int: V2RoomRecoveryBatchCallOutcome] = [:]
        if !selected.isEmpty {
            recoveryBatchesInFlight += 1
            for entry in pins.values { entry.inFlightCalls += 1 }
            defer {
                recoveryBatchesInFlight -= 1
                for entry in pins.values { entry.inFlightCalls -= 1 }
            }
            let selectedItems = selected.map {
                V2RoomRecoveryBatchCallItem(token: items[$0].token, query: items[$0].query, deadline: end)
            }
            // Cancellation/retirement cannot release pins before the actual
            // owned callback settles. A SELECT failure never invalidates write
            // hints or makes an uncommitted write outcome certain.
            let completion = await execute(selectedItems)
            switch completion {
            case .committed(let values):
                if values.count == selected.count,
                   V2ActorPayloadBudget.retainedBytes(of: values) <= 256 * 1_024, zip(selectedItems, values).allSatisfy({
                    $0.0.token == $0.1.token && $0.0.query == $0.1.query
                }) {
                    for (index, value) in zip(selected, values) { answers[index] = value }
                } else {
                    for index in selected { failures[index] = .outcomeUnknown }
                }
            case .rolledBack(let reason):
                for index in selected { failures[index] = .rolledBack(reason) }
            case .outcomeUnknown:
                for index in selected { failures[index] = .outcomeUnknown }
            }
            for index in selected {
                let token = items[index].token
                let pin = pins[token.roomID]!
                let failure: V2RoomCallFailure?
                if Task.isCancelled { failure = .notAccepted(.cancelled) }
                else if clock.now >= min(end, items[index].deadline) { failure = .notAccepted(.deadlineExceeded) }
                else if entries[token.roomID] !== pin || pin.token != token { failure = .notAccepted(.staleActivation) }
                else if !isSafe(pin) { failure = .notAccepted(.leaseLost) }
                else if !accepting || pin.phase != .ready { failure = .notAccepted(.retired) }
                else { failure = nil }
                // Preserve unknown as unknown; never turn it into safe retry.
                if let failure, let answer = answers[index], case .result = answer.outcome {
                    answers.removeValue(forKey: index); failures[index] = failure
                }
            }
        }
        return items.indices.map { index in
            if let answer = answers[index] {
                if case .result = answer.outcome, ContinuousClock.now >= min(end, items[index].deadline) {
                    return rejected(items[index], .notAccepted(.deadlineExceeded))
                }
                return answer
            }
            return rejected(items[index], failures[index] ?? .outcomeUnknown)
        }
    }

    private struct RecoveryPair: Hashable { let room: RoomID; let viewer: UserID }
}
