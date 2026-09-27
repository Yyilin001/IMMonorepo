import Foundation
import IMV2ActorContracts

/// 相邻发送或相邻资料可见性读取各自可以共享轮次；两类不能混合。
/// 其余能力和预留都是屏障。处理器 await 期间不放入第二个轮次。
public enum V2RoomTurnSchedulingClass: Equatable, Sendable {
    case send
    case profileVisibility(targetCount: Int)
    case barrier
}

public extension V2RoomRequest {
    var turnSchedulingClass: V2RoomTurnSchedulingClass {
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
    private var queue: [Entry] = []
    private var executing: [Entry] = []
    private var unresolved: [V2RoomCommandPermit] = []
    private var reservation: HeldReservation?
    private var consumer: Task<Void, Never>?
    private var lastActivity: ContinuousClock.Instant

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
        self.lastActivity = ContinuousClock.now
    }

    public func submit(
        encodedRequest: Data,
        deadline: ContinuousClock.Instant
    ) async throws -> Response {
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            guard phase == .ready else { throw rejection() }
            guard !Task.isCancelled else { throw V2RoomCallFailure.notAccepted(.cancelled) }
            guard clock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
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
            return try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) }
                    catch { return }
                    await self?.withdraw(requestID, reason: .deadlineExceeded)
                }
                queue.append(Entry(
                    id: requestID, permit: permit, request: request, ordinal: ordinal,
                    admittedAt: admittedAt, deadline: deadline, continuation: continuation,
                    reservationGrant: nil, reservationContinuation: nil, timer: timer
                ))
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
                let timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: boundedDeadline) }
                    catch { return }
                    await self?.withdraw(grant.reservationID, reason: .deadlineExceeded)
                }
                queue.append(Entry(
                    id: grant.reservationID, permit: permit, request: nil, ordinal: nextOrdinal,
                    admittedAt: admittedAt, deadline: boundedDeadline, continuation: nil,
                    reservationGrant: grant, reservationContinuation: continuation, timer: timer
                ))
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
        held.entry.timer.cancel()
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
        held.entry.timer.cancel()
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
            // 立即放行已排队的连续发送请求。共享的物理所有者批处理器
            // 负责唯一的收集等待，且受首条请求原始准入时间限制。
            // 若此处先等待，其他房间尚未加入时就会耗尽该窗口。
            guard phase == .ready || phase == .draining else { break }
            // 计时器回调可能尚未运行。不能只因执行器赢得调度竞争，
            // 就分发已过期的请求。
            while let entry = queue.first, entry.deadline <= clock.now {
                await withdraw(entry.id, reason: .deadlineExceeded)
            }
            guard let head = queue.first else { continue }
            if let grant = head.reservationGrant {
                var entry = queue.removeFirst()
                let continuation = entry.reservationContinuation
                entry.reservationContinuation = nil
                reservation = HeldReservation(entry: entry, dispatched: false)
                continuation?.resume(returning: grant)
                break
            }
            let headClass = schedulingClass(head)
            var count = 1
            var bytes = head.permit.byteCount
            if headClass == .send {
                for entry in queue.dropFirst() {
                    guard schedulingClass(entry) == .send,
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
                for entry in queue.dropFirst() {
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
            executing = Array(queue.prefix(count))
            queue.removeFirst(count)
            let turn = V2RoomTurn(
                context: V2RoomTurnContext(
                    token: token, turnID: UUID(),
                    batchDeadline: min(head.admittedAt + configuration.batchWait.duration, head.deadline)
                ),
                items: executing.compactMap { entry in
                    entry.request.map { .init(ordinal: entry.ordinal, request: $0, deadline: entry.deadline) }
                }
            )
            let completion = await V2RoomTurnScope.$roomID.withValue(token.roomID) {
                await execute(turn)
            }
            await finish(completion)
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
                entry.timer.cancel()
                entry.continuation?.resume(returning: value)
            }
        case .rolledBack(let reason):
            for entry in entries {
                entry.timer.cancel()
                entry.continuation?.resume(throwing: V2RoomCallFailure.rolledBack(reason))
            }
            if reason == .leaseLost || reason == .staleActivation { uncertain = true }
        case .outcomeUnknown, .committed:
            // 格式错误的执行器结果无法安全地与调用方逐一对应。
            uncertain = true
            for entry in entries {
                entry.timer.cancel()
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
        if let index = queue.firstIndex(where: { $0.id == id }) {
            let entry = queue.remove(at: index)
            entry.timer.cancel()
            entry.continuation?.resume(throwing: V2RoomCallFailure.notAccepted(reason))
            entry.reservationContinuation?.resume(throwing: V2RoomCallFailure.notAccepted(reason))
            await budget.release(entry.permit)
        } else if let index = executing.firstIndex(where: { $0.id == id }) {
            // 只让调用方退出，不中断 SQL。保留许可和独占轮次，
            // 直到执行器报告实际事务结果。
            let continuation = executing[index].continuation
            executing[index].continuation = nil
            executing[index].timer.cancel()
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
        let rejected = queue
        queue.removeAll()
        for entry in rejected {
            entry.timer.cancel()
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
        held.entry.timer.cancel()
        unresolved.append(held.entry.permit)
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
        let timer: Task<Void, Never>
    }
}
