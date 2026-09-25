import Foundation
import IMV2ActorContracts
import IMV2Core

/// 协调器的运行时与传输适配器。每次操作都必须遵守单调截止时间；
/// 远程实现只发送剩余时间预算。
public struct V2RoomReservationOperations: Sendable {
    let reserve: @Sendable (RoomID, UUID, ContinuousClock.Instant) async throws -> V2RoomReservation
    let markDispatched: @Sendable (V2RoomReservation, ContinuousClock.Instant) async throws -> Void
    let abort: @Sendable (V2RoomReservation, ContinuousClock.Instant) async -> Bool
    let finish: @Sendable (V2RoomReservation, V2RoomReservationCompletion, ContinuousClock.Instant) async -> Bool

    public init(
        reserve: @escaping @Sendable (RoomID, UUID, ContinuousClock.Instant) async throws -> V2RoomReservation,
        markDispatched: @escaping @Sendable (V2RoomReservation, ContinuousClock.Instant) async throws -> Void,
        abort: @escaping @Sendable (V2RoomReservation, ContinuousClock.Instant) async -> Bool,
        finish: @escaping @Sendable (V2RoomReservation, V2RoomReservationCompletion, ContinuousClock.Instant) async -> Bool
    ) {
        self.reserve = reserve
        self.markDispatched = markDispatched
        self.abort = abort
        self.finish = finish
    }
}

/// 每次调用最多持有一对源与目标。按规范顺序获取，
/// 可防止 A->B 与 B->A 形成循环，而不扩大业务原子性范围。
public actor V2RoomReservationCoordinator {
    private let operations: V2RoomReservationOperations
    private let configuration: V2RoomRuntimeConfiguration
    private var inFlight = 0

    public init(operations: V2RoomReservationOperations, configuration: V2RoomRuntimeConfiguration) {
        self.operations = operations
        self.configuration = configuration
    }

    public func withReservations<Value: Sendable>(
        source: RoomID,
        target: RoomID,
        deadline: ContinuousClock.Instant,
        execute: @Sendable ([V2RoomReservation]) async -> V2RoomTransactionCompletion<Value>
    ) async throws -> Value {
        guard V2RoomTurnScope.roomID == nil else {
            // 普通轮次绝不能等待另一房间的轮次。
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        guard inFlight < configuration.maximumConcurrentReservations else {
            throw V2RoomCallFailure.notAccepted(.overloaded)
        }
        try checkBeforeDispatch(deadline)
        inFlight += 1
        defer { inFlight -= 1 }

        let requestID = UUID()
        let rooms = Array(Set([source, target])).sorted()
        var grants: [V2RoomReservation] = []
        var markingStarted = false
        do {
            for roomID in rooms {
                try checkBeforeDispatch(deadline)
                let grant = try await operations.reserve(roomID, requestID, deadline)
                // 不匹配的响应绝不能成为写入权限。
                guard grant.token.roomID == roomID, grant.requestID == requestID else {
                    // 它可能属于其他调用方的尝试，绝不能释放。
                    // 我方可能已获准的请求会在持有方过期。
                    throw V2RoomCallFailure.notAccepted(.staleActivation)
                }
                grants.append(grant)
            }
            // 同一数据库中的两个房间可以有不同的所有者纪元；
            // 不同物理所有者则使用既有持久化转发流程。
            guard Set(grants.map { $0.token.owner.shardID }).count == 1 else {
                throw V2RoomCallFailure.notAccepted(.invalidRequest)
            }
            for grant in grants {
                try checkBeforeDispatch(deadline)
                markingStarted = true
                try await operations.markDispatched(grant, deadline)
            }
            try checkBeforeDispatch(deadline)
        } catch {
            // SQL 尚未执行。即使分发确认丢失，也可将结果确认为已回滚；
            // 未标记的授权可安全中止。
            await abandon(grants, markingStarted: markingStarted)
            if let failure = error as? V2RoomCallFailure,
               case .notAccepted = failure { throw failure }
            throw V2RoomCallFailure.notAccepted(.unavailable)
        }

        // 从这里开始，取消和超时必须由实际事务所有者分类。
        // 此闭包不能抛出结果不明的数据库错误。
        let completion = await execute(grants)
        switch completion {
        case .committed(let value):
            await settle(grants, completion: .committed)
            return value
        case .rolledBack(let reason):
            await settle(grants, completion: .rolledBack)
            throw V2RoomCallFailure.rolledBack(reason)
        case .outcomeUnknown:
            await settle(grants, completion: .outcomeUnknown)
            throw V2RoomCallFailure.outcomeUnknown
        }
    }

    public func activePairCount() -> Int { inFlight }

    private func checkBeforeDispatch(_ deadline: ContinuousClock.Instant) throws {
        guard !Task.isCancelled else { throw V2RoomCallFailure.notAccepted(.cancelled) }
        guard ContinuousClock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
    }

    private func cleanupDeadline() -> ContinuousClock.Instant {
        .now + configuration.transactionTimeout.duration
    }

    private func abandon(_ grants: [V2RoomReservation], markingStarted: Bool) async {
        let operations = operations
        let deadline = cleanupDeadline()
        await withTaskGroup(of: Void.self) { group in
            for grant in grants {
                group.addTask {
                    if markingStarted,
                       await operations.finish(grant, .rolledBack, deadline) { return }
                    _ = await operations.abort(grant, deadline)
                    // 无法联系的持有方会保留屏障，直到纪元安全退役。
                    // 故障绝不授权按本地 TTL 解锁。
                }
            }
        }
    }

    private func settle(_ grants: [V2RoomReservation], completion: V2RoomReservationCompletion) async {
        let operations = operations
        let deadline = cleanupDeadline()
        await withTaskGroup(of: Void.self) { group in
            for grant in grants {
                group.addTask { _ = await operations.finish(grant, completion, deadline) }
            }
        }
        // 通知丢失不会改变已知的 SQL 提交结果。
        // 持有方继续关闭，并在有界授权过期时退役。
    }
}

enum V2RoomTurnScope {
    @TaskLocal static var roomID: RoomID?
}
