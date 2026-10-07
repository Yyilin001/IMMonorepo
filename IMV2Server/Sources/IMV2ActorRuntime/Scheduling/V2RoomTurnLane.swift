import Foundation
import Synchronization
import IMV2ActorContracts

/// 相邻发送或相邻资料可见性读取各自可以共享轮次；两类不能混合。
/// 其余能力和预留都是屏障。处理器 await 期间不放入第二个轮次。
public enum V2RoomTurnSchedulingClass: Equatable, Sendable {
    case send
    case sendOperation
    case profileVisibility(targetCount: Int)
    case barrier
}

public extension V2RoomRequest {
    var turnSchedulingClass: V2RoomTurnSchedulingClass {
        if case .messaging(.sendOperation(_)) = self { return .sendOperation }
        if canShareSendTurn { return .send }
        if let count = profileVisibilityTargetCount { return .profileVisibility(targetCount: count) }
        return .barrier
    }
}

/// 由本地运行时创建的执行权限，绝不从 RPC 解码得来。
public struct V2RoomTurnContext: Sendable {
    public let token: V2RoomActivationToken
    public let turnID: UUID
    /// 共享数据库批处理器使用此预算的剩余部分，不能再启动独立的批处理等待。
    public let batchDeadline: ContinuousClock.Instant
    /// Exact Host-confirmed authority, capped by room lease safety and service qualification.
    /// Filled at dispatch by the Host, never decoded from a remote request.
    public let activationValidUntil: ContinuousClock.Instant?
    public let queueWaitDuration: Duration

    public init(token: V2RoomActivationToken, turnID: UUID, batchDeadline: ContinuousClock.Instant,
                activationValidUntil: ContinuousClock.Instant? = nil, queueWaitDuration: Duration = .zero) {
        self.token = token; self.turnID = turnID; self.batchDeadline = batchDeadline
        self.activationValidUntil = activationValidUntil
        self.queueWaitDuration = queueWaitDuration
    }
}

public struct V2RoomTurnItem<Request: Sendable>: Sendable {
    public let ordinal: UInt64
    public let request: Request
    public let deadline: ContinuousClock.Instant
}

public struct V2RoomTurn<Request: Sendable>: Sendable {
    public let context: V2RoomTurnContext
    public let items: [V2RoomTurnItem<Request>]
}

public struct V2RoomTurnLaneSnapshot: Sendable {
    public let phase: V2RoomActivationPhase
    public let queuedCount: Int
    public let executingCount: Int
    public let unresolvedCount: Int
    public let hasReservation: Bool
    public let lastActivity: ContinuousClock.Instant
    public var isIdle: Bool { queuedCount == 0 && executingCount == 0 && unresolvedCount == 0 && !hasReservation }
}

/// 此调度器面向封闭且有类型的请求集合，不按方法名分发，
/// 也不接受任意载荷集合。解码始终使用已计入宿主准入预算的确切不可变字节。
public actor V2RoomTurnLane<Request: Decodable & Sendable, Response: Sendable> {
    public typealias Execute = @Sendable (V2RoomTurn<Request>) async -> V2RoomTransactionCompletion<[Response]>

    public let token: V2RoomActivationToken
    private let configuration: V2RoomRuntimeConfiguration
    private let budget: V2RoomCommandBudget
    private let classify: @Sendable (Request) -> V2RoomTurnSchedulingClass
    private let execute: Execute
    private let onUncertain: @Sendable (V2RoomActivationToken) async -> Void
    private let clock = ContinuousClock()
    private var phase: V2RoomActivationPhase = .ready
    private var nextOrdinal: UInt64 = 0
    private var queue = EntryQueue()
    private var executing: [Entry] = []
    private var unresolved: [V2RoomCommandPermit] = []
    private var reservation: HeldReservation?
    private var consumer: Task<Void, Never>?
    // One timestamp, written only at the existing actual activity boundaries.
    // The Host can cheaply rule out a not-yet-idle lane without an actor hop;
    // retirement still uses this lane's atomic admission/ownership check.
    private let activity: Mutex<ContinuousClock.Instant>
    private var lastActivity: ContinuousClock.Instant {
        get { activity.withLock { $0 } }
        set { activity.withLock { $0 = newValue } }
    }
    private var pendingAdmissions = 0
    private var deadlines = V2RoomTurnDeadlines()
    private var deadlineWake: Task<Void, Never>?
    private var deadlineWakeID: UUID?
    private var deadlineWakeAt: ContinuousClock.Instant?
    private var processingDeadlines = false

    public init(
        token: V2RoomActivationToken,
        configuration: V2RoomRuntimeConfiguration,
        budget: V2RoomCommandBudget,
        classify: @escaping @Sendable (Request) -> V2RoomTurnSchedulingClass,
        execute: @escaping Execute,
        onUncertain: @escaping @Sendable (V2RoomActivationToken) async -> Void
    ) {
        self.token = token
        self.configuration = configuration
        self.budget = budget
        self.classify = classify
        self.execute = execute
        self.onUncertain = onUncertain
        self.activity = Mutex(ContinuousClock.now)
    }

    /// A recent observation can only skip a premature probe. An old observation
    /// never grants retirement; beginIdleDrain must still validate atomically.
    nonisolated func wasActive(after cutoff: ContinuousClock.Instant) -> Bool {
        activity.withLock { $0 > cutoff }
    }

    public func submit(
        encodedRequest: Data,
        deadline: ContinuousClock.Instant
    ) async throws -> Response {
        V2SendPathTrace.current?.mark("lane_submit_enter")
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            guard phase == .ready else { throw rejection() }
            guard !Task.isCancelled else { throw V2RoomCallFailure.notAccepted(.cancelled) }
            guard clock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
            pendingAdmissions += 1
            defer { pendingAdmissions -= 1 }
            let permit = try await budget.acquire(roomID: token.roomID, encodedRequest: encodedRequest)
            // 准入曾等待另一个 Actor；须重新检查全部本地条件。
            guard phase == .ready, !Task.isCancelled, clock.now < deadline else {
                let failure = phase != .ready ? rejection() : V2RoomCallFailure.notAccepted(
                    Task.isCancelled ? .cancelled : .deadlineExceeded
                )
                await budget.release(permit)
                throw failure
            }
            let request: Request
            do { request = try JSONDecoder().decode(Request.self, from: permit.encodedRequest) }
            catch {
                await budget.release(permit)
                throw V2RoomCallFailure.notAccepted(.invalidRequest)
            }
            if case .profileVisibility = classify(request), permit.byteCount > 64 * 1_024 {
                await budget.release(permit)
                throw V2RoomCallFailure.notAccepted(.invalidRequest)
            }
            guard nextOrdinal < UInt64.max else {
                await budget.release(permit)
                throw V2RoomCallFailure.notAccepted(.overloaded)
            }
            nextOrdinal += 1
            let ordinal = nextOrdinal
            let admittedAt = clock.now
            V2SendPathTrace.current?.mark("lane_admitted")
            return try await withCheckedThrowingContinuation { continuation in
                queue.append(Entry(
                    id: requestID, permit: permit, request: request, ordinal: ordinal,
                    admittedAt: admittedAt, deadline: deadline, continuation: continuation,
                    reservationGrant: nil, reservationContinuation: nil
                ))
                trackDeadline(queueEntryID: requestID, deadline: deadline)
                lastActivity = admittedAt
                startConsumerIfNeeded()
            }
        } onCancel: {
            Task { await self.withdraw(requestID, reason: .cancelled) }
        }
    }

    /// 原子地关闭准入。已接受的请求保留位置和租约直至完成；
    /// 排空截止时间由宿主生命周期负责。
    public func beginDrain() {
        if phase == .ready { phase = .draining }
    }

    /// The activity check and admission cutoff share the Lane's isolation.
    /// A Host snapshot from before a suspended/newly completed turn cannot
    /// retire this lane; even admission awaiting the shared budget prevents it.
    public func beginIdleDrain(ifLastActivityAtOrBefore cutoff: ContinuousClock.Instant) -> Bool {
        guard phase == .ready, pendingAdmissions == 0,
              queue.isEmpty, executing.isEmpty, unresolved.isEmpty, reservation == nil,
              lastActivity <= cutoff else { return false }
        phase = .draining
        return true
    }

    /// 将普通轮次之外的协调器屏障入队。截止时间覆盖等待和持有阶段；
    /// 已获准的屏障到期时，不会悄然解锁同一激活供后续命令使用。
    public func reserve(requestID: UUID, deadline: ContinuousClock.Instant) async throws -> V2RoomReservation {
        let grant = V2RoomReservation(token: token, requestID: requestID, reservationID: UUID())
        return try await withTaskCancellationHandler {
            guard phase == .ready else { throw rejection() }
            guard !Task.isCancelled else { throw V2RoomCallFailure.notAccepted(.cancelled) }
            let boundedDeadline = min(deadline, clock.now + configuration.reservationTimeout.duration)
            guard clock.now < boundedDeadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
            let bytes = try JSONEncoder().encode(grant)
            pendingAdmissions += 1
            defer { pendingAdmissions -= 1 }
            let permit = try await budget.acquireReservation(roomID: token.roomID, encodedRequest: bytes)
            guard phase == .ready, !Task.isCancelled, clock.now < boundedDeadline, nextOrdinal < UInt64.max else {
                let failure = phase != .ready ? rejection() : V2RoomCallFailure.notAccepted(
                    Task.isCancelled ? .cancelled : .deadlineExceeded
                )
                await budget.release(permit)
                throw failure
            }
            nextOrdinal += 1
            let admittedAt = clock.now
            return try await withCheckedThrowingContinuation { continuation in
                queue.append(Entry(
                    id: grant.reservationID, permit: permit, request: nil, ordinal: nextOrdinal,
                    admittedAt: admittedAt, deadline: boundedDeadline, continuation: nil,
                    reservationGrant: grant, reservationContinuation: continuation
                ))
                trackDeadline(queueEntryID: grant.reservationID, deadline: boundedDeadline)
                lastActivity = admittedAt
                startConsumerIfNeeded()
            }
        } onCancel: {
            Task { await self.withdraw(grant.reservationID, reason: .cancelled) }
        }
    }

    /// 分发前必须确认。迟到或伪造的授权会失败；
    /// 预留过期或退役后，调用方不能启动 SQL。
    public func markReservationDispatched(_ grant: V2RoomReservation) throws {
        guard phase == .ready || phase == .draining,
              reservation?.entry.reservationGrant == grant,
              let held = reservation, held.entry.deadline > clock.now,
              !held.dispatched
        else { throw V2RoomCallFailure.notAccepted(.staleActivation) }
        reservation?.dispatched = true
    }

    /// 协调器只能在分发前安全地放弃授权。一旦确认，
    /// 必须报告持久化完成结果，或将两个房间都退役。
    @discardableResult
    public func abortReservation(_ grant: V2RoomReservation) async -> Bool {
        guard let held = reservation, held.entry.reservationGrant == grant,
              !held.dispatched, phase == .ready || phase == .draining
        else { return false }
        reservation = nil
        forgetDeadline(held.entry.id)
        lastActivity = clock.now
        await budget.release(held.entry.permit)
        startConsumerIfNeeded()
        return true
    }

    /// 宿主在仍持有屏障时先更新或失效化执行器状态，然后完成屏障。
    /// 外部调用方不能跳过此步骤。
    @discardableResult
    func finishReservation(_ grant: V2RoomReservation, completion: V2RoomReservationCompletion) async -> Bool {
        guard let held = reservation, held.entry.reservationGrant == grant,
              held.dispatched, phase == .ready || phase == .draining
        else { return false }
        forgetDeadline(held.entry.id)
        reservation = nil
        lastActivity = clock.now
        if completion == .outcomeUnknown {
            phase = .uncertain
            unresolved.append(held.entry.permit)
            await rejectQueued(reason: .leaseLost)
            await onUncertain(token)
        } else {
            await budget.release(held.entry.permit)
            startConsumerIfNeeded()
        }
        return true
    }

    public func snapshot() -> V2RoomTurnLaneSnapshot {
        .init(
            phase: phase, queuedCount: queue.count, executingCount: executing.count,
            unresolvedCount: unresolved.count, hasReservation: reservation != nil,
            lastActivity: lastActivity
        )
    }

    /// 租约丢失会独立于业务消费方关闭准入。已分发的事务仍保有完成结果和已扣的许可。
    public func loseLease() async {
        guard phase != .stopped, phase != .uncertain else { return }
        phase = .uncertain
        quarantineReservation()
        await rejectQueued(reason: .leaseLost)
        await onUncertain(token)
    }

    /// 仅宿主可在旧令牌被数据库围栏排除且其执行器停止后调用。
    /// 绝不释放仍在执行的事务。
    func completeRetirement() async -> Bool {
        guard executing.isEmpty else { return false }
        phase = .stopped
        consumer?.cancel()
        quarantineReservation()
        await rejectQueued(reason: .retired)
        let permits = unresolved
        unresolved.removeAll()
        for permit in permits { await budget.release(permit) }
        return true
    }

    func deadlineTrackingSnapshot() -> (entries: Int, hasWake: Bool) {
        (deadlines.count, deadlineWake != nil)
    }

    private func trackDeadline(queueEntryID: UUID, deadline: ContinuousClock.Instant) {
        deadlines.insert(id: queueEntryID, deadline: deadline)
        scheduleDeadlineWake()
    }

    private func forgetDeadline(_ id: UUID) {
        deadlines.remove(id)
        scheduleDeadlineWake()
    }

    private func scheduleDeadlineWake() {
        guard !processingDeadlines else { return }
        guard let next = deadlines.first else {
            deadlineWake?.cancel(); deadlineWake = nil
            deadlineWakeID = nil; deadlineWakeAt = nil
            return
        }
        // An earlier wake remains safe after its entry is withdrawn. It will
        // inspect the current index, without firing a stale request callback.
        if deadlineWake != nil, let deadlineWakeAt, deadlineWakeAt <= next.deadline { return }
        deadlineWake?.cancel()
        let id = UUID(), wake = next.deadline
        deadlineWakeID = id; deadlineWakeAt = wake
        deadlineWake = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: wake) }
            catch { return }
            await self?.deadlineWakeFired(id)
        }
    }

    private func deadlineWakeFired(_ id: UUID) async {
        guard deadlineWakeID == id else { return }
        deadlineWake = nil; deadlineWakeID = nil; deadlineWakeAt = nil
        processingDeadlines = true
        defer { processingDeadlines = false; scheduleDeadlineWake() }
        while let next = deadlines.first, next.deadline <= clock.now {
            deadlines.remove(next.id)
            await withdraw(next.id, reason: .deadlineExceeded)
        }
    }

    private func rejection() -> V2RoomCallFailure {
        .notAccepted(phase == .uncertain ? .leaseLost : .retired)
    }

    private func startConsumerIfNeeded() {
        guard consumer == nil, reservation == nil, !queue.isEmpty,
              phase == .ready || phase == .draining else { return }
        consumer = Task { await self.consume() }
    }

    private func consume() async {
        while phase == .ready || phase == .draining {
            guard !queue.isEmpty else { break }
            // This is the only room sequencer. Durable sends normally collect
            // compatible work already queued, without waiting for new arrivals.
            guard phase == .ready || phase == .draining else { break }
            // 计时器回调可能尚未运行。不能只因执行器赢得调度竞争，
            // 就分发已过期的请求。
            while let entry = queue.first, entry.deadline <= clock.now {
                await withdraw(entry.id, reason: .deadlineExceeded)
            }
            guard let head = queue.first else { continue }
            if schedulingClass(head) == .sendOperation && configuration.durableSendCollectionWindowEnabled {
                let collectionDeadline = min(head.admittedAt + configuration.batchWait.duration, head.deadline)
                if clock.now < collectionDeadline {
                    do { try await clock.sleep(until: collectionDeadline) }
                    catch { break }
                    // Cancellation, retirement and deadlines may change the head
                    // while collection suspends. Re-evaluate before dispatching.
                    guard phase == .ready || phase == .draining else { break }
                    if queue.first?.id != head.id || head.deadline <= clock.now { continue }
                }
            }
            if let grant = head.reservationGrant {
                guard var entry = queue.removeFirst() else { continue }
                let continuation = entry.reservationContinuation
                entry.reservationContinuation = nil
                reservation = HeldReservation(entry: entry, dispatched: false)
                continuation?.resume(returning: grant)
                break
            }
            let headClass = schedulingClass(head)
            var count = 1
            var bytes = head.permit.byteCount
            if headClass == .send || headClass == .sendOperation {
                for entry in queue.prefix(configuration.maximumCommandsPerTurn).dropFirst() {
                    guard schedulingClass(entry) == headClass,
                          entry.deadline > clock.now,
                          count < configuration.maximumCommandsPerTurn,
                          entry.permit.byteCount <= configuration.maximumBytesPerTurn - bytes
                    else { break }
                    count += 1
                    bytes += entry.permit.byteCount
                }
            } else if case .profileVisibility(let headTargets) = headClass,
                      (1...100).contains(headTargets) {
                var targets = headTargets
                let byteLimit = min(configuration.maximumBytesPerTurn, 64 * 1_024)
                for entry in queue.prefix(configuration.maximumCommandsPerTurn).dropFirst() {
                    guard case .profileVisibility(let nextTargets) = schedulingClass(entry),
                          (1...100).contains(nextTargets), nextTargets <= 100 - targets,
                          entry.deadline > clock.now,
                          count < configuration.maximumCommandsPerTurn,
                          bytes <= byteLimit, entry.permit.byteCount <= byteLimit - bytes
                    else { break }
                    count += 1
                    bytes += entry.permit.byteCount
                    targets += nextTargets
                }
            }
            executing = []
            for _ in 0..<count {
                if let entry = queue.removeFirst() { executing.append(entry) }
            }
            let turn = V2RoomTurn(
                context: V2RoomTurnContext(
                    token: token, turnID: UUID(),
                    batchDeadline: min(head.admittedAt + configuration.batchWait.duration, head.deadline),
                    queueWaitDuration: head.admittedAt.duration(to: .now)
                ),
                items: executing.compactMap { entry in
                    entry.request.map { .init(ordinal: entry.ordinal, request: $0, deadline: entry.deadline) }
                }
            )
            let operationIDs = executing.compactMap { entry -> String? in
                guard let request = entry.request as? V2RoomRequest,
                      case .messaging(.sendOperation(let command)) = request else { return nil }
                return try? command.identity.operation.rawOperationID
            }
            let trace = V2SendPathTrace.enabled && !operationIDs.isEmpty
                ? V2SendPathTrace(operations: operationIDs, segment: "room_actor") : nil
            trace?.record("room_queue_wait", from: head.admittedAt)
            trace?.mark("turn_execute_dispatch")
            let completion = await V2RoomTurnScope.$roomID.withValue(token.roomID) {
                await V2SendPathTrace.$current.withValue(trace) { await execute(turn) }
            }
            trace?.mark("turn_execute_return")
            let finishStartedAt = ContinuousClock.now
            await finish(completion)
            trace?.record("lane_finish", from: finishStartedAt)
            trace?.finish()
        }
        consumer = nil
    }

    private func finish(_ completion: V2RoomTransactionCompletion<[Response]>) async {
        let entries = executing
        executing.removeAll()
        lastActivity = clock.now
        var uncertain = false
        switch completion {
        case .committed(let values) where values.count == entries.count:
            for (entry, value) in zip(entries, values) {
                forgetDeadline(entry.id)
                entry.continuation?.resume(returning: value)
            }
        case .rolledBack(let reason):
            for entry in entries {
                forgetDeadline(entry.id)
                entry.continuation?.resume(throwing: V2RoomCallFailure.rolledBack(reason))
            }
            if reason == .leaseLost || reason == .staleActivation { uncertain = true }
        case .outcomeUnknown, .committed:
            // 格式错误的执行器结果无法安全地与调用方逐一对应。
            uncertain = true
            for entry in entries {
                forgetDeadline(entry.id)
                entry.continuation?.resume(throwing: V2RoomCallFailure.outcomeUnknown)
            }
        }
        if uncertain {
            phase = .uncertain
            unresolved.append(contentsOf: entries.map(\.permit))
            await rejectQueued(reason: .leaseLost)
            await onUncertain(token)
        } else {
            for entry in entries { await budget.release(entry.permit) }
        }
    }

    private func withdraw(_ id: UUID, reason: V2RoomFailureReason) async {
        if let entry = queue.remove(id) {
            forgetDeadline(entry.id)
            entry.continuation?.resume(throwing: V2RoomCallFailure.notAccepted(reason))
            entry.reservationContinuation?.resume(throwing: V2RoomCallFailure.notAccepted(reason))
            await budget.release(entry.permit)
        } else if let index = executing.firstIndex(where: { $0.id == id }) {
            // 只让调用方退出，不中断 SQL。保留许可和独占轮次，
            // 直到执行器报告实际事务结果。
            let continuation = executing[index].continuation
            executing[index].continuation = nil
            forgetDeadline(id)
            continuation?.resume(throwing: V2RoomCallFailure.outcomeUnknown)
        } else if reservation?.entry.id == id {
            // 授权返回后若协调器失联，须采取保守处理：
            // 即使分发确认丢失，也要退役此纪元。
            phase = .uncertain
            quarantineReservation()
            await rejectQueued(reason: .leaseLost)
            await onUncertain(token)
        }
    }

    private func rejectQueued(reason: V2RoomFailureReason) async {
        let rejected = queue.prefix(queue.count)
        queue.removeAll()
        for entry in rejected {
            forgetDeadline(entry.id)
            entry.continuation?.resume(throwing: V2RoomCallFailure.notAccepted(reason))
            entry.reservationContinuation?.resume(throwing: V2RoomCallFailure.notAccepted(reason))
            await budget.release(entry.permit)
        }
    }

    private func schedulingClass(_ entry: Entry) -> V2RoomTurnSchedulingClass {
        entry.request.map(classify) ?? .barrier
    }

    private func quarantineReservation() {
        guard let held = reservation else { return }
        reservation = nil
        forgetDeadline(held.entry.id)
        unresolved.append(held.entry.permit)
    }

    /// Room-local FIFO. Taking the head and withdrawing a queued request do
    /// not scan or move the remaining commands. Batch inspection visits only
    /// the existing turn limit; execution and reservation ownership stay in
    /// the Lane, outside this waiting queue.
    private struct EntryQueue: Sendable {
        private struct Node: Sendable {
            let entry: Entry
            var previous: UUID?
            var next: UUID?
        }
        private var nodes: [UUID: Node] = [:]
        private var head: UUID?
        private var tail: UUID?
        var count: Int { nodes.count }
        var isEmpty: Bool { nodes.isEmpty }
        var first: Entry? { head.flatMap { nodes[$0]?.entry } }

        mutating func append(_ entry: Entry) {
            precondition(nodes[entry.id] == nil)
            nodes[entry.id] = .init(entry: entry, previous: tail, next: nil)
            if let tail { nodes[tail]?.next = entry.id } else { head = entry.id }
            tail = entry.id
        }

        mutating func remove(_ id: UUID) -> Entry? {
            guard let node = nodes.removeValue(forKey: id) else { return nil }
            if let previous = node.previous { nodes[previous]?.next = node.next }
            else { head = node.next }
            if let next = node.next { nodes[next]?.previous = node.previous }
            else { tail = node.previous }
            return node.entry
        }

        mutating func removeFirst() -> Entry? {
            guard let head else { return nil }
            return remove(head)
        }

        func prefix(_ limit: Int) -> [Entry] {
            var result: [Entry] = []
            var current = head
            while result.count < limit, let id = current, let node = nodes[id] {
                result.append(node.entry)
                current = node.next
            }
            return result
        }

        mutating func removeAll() {
            nodes.removeAll(); head = nil; tail = nil
        }
    }

    private struct HeldReservation: Sendable {
        let entry: Entry
        var dispatched: Bool
    }

    private struct Entry: Sendable {
        let id: UUID
        let permit: V2RoomCommandPermit
        let request: Request?
        let ordinal: UInt64
        let admittedAt: ContinuousClock.Instant
        let deadline: ContinuousClock.Instant
        var continuation: CheckedContinuation<Response, any Error>?
        let reservationGrant: V2RoomReservation?
        var reservationContinuation: CheckedContinuation<V2RoomReservation, any Error>?
    }
}
