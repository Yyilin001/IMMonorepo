import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import NIOCore
import PostgresKit
import PostgresNIO
import SQLKit
import Synchronization

/// 单次房间事务尝试使用单调时钟计算总截止时间。调用方提供已选定的
/// 所有者数据库；本次尝试完全结束后，再单独决定是否重试。
///
/// PostgreSQL 16 没有 transaction_timeout。LOCAL SQL 限制仍约束每次等待
/// 或语句；总截止时间到达时，看门狗只关闭借用的物理连接。
/// 方法会等待主体及可能的关闭操作结束，并同步解除超时回调。因此调用方超时后，
/// 不会把仍活动的 SQL 事务放回连接池，也不会在其连接上执行后续语句。
/// 主体不能在借用的连接上执行事务控制 SQL，或重试已中止的事务；
/// 重试必须重新调用此方法。
func v2WithRoomActivationTransaction<Value: Sendable>(
    database: any Database,
    deadline: ContinuousClock.Instant,
    timeouts: V2RoomActivationSQLTimeouts = .default,
    sendOperationMetrics: V2SendOperationBatchMetrics? = nil,
    measureConnectionAcquire: Bool = true,
    readOnlyRepeatableRead: Bool = false,
    pinnedConnection: V2BorrowedRoomConnection? = nil,
    _ body: @escaping @Sendable (any Database) async throws -> Value
) async throws -> Value {
    try await v2WithRoomActivationTransactionCore(
        database: database, deadline: deadline, timeouts: timeouts, needsContext: false,
        sendOperationMetrics: sendOperationMetrics, measureConnectionAcquire: measureConnectionAcquire,
        readOnlyRepeatableRead: readOnlyRepeatableRead, pinnedConnection: pinnedConnection
    ) { borrowed, _ in
        try await body(borrowed)
    }
}

/// 只在执行 BEGIN 并确认默认或 LOCAL 超时策略后创建上下文。
/// 它持有实际借用的 SQL 连接；使用其组合房间围栏时，调用方不能替换为池中其他连接。
func v2WithRoomActivationTransactionWithContext<Value: Sendable>(
    database: any Database,
    deadline: ContinuousClock.Instant,
    timeouts: V2RoomActivationSQLTimeouts = .default,
    sendOperationMetrics: V2SendOperationBatchMetrics? = nil,
    measureConnectionAcquire: Bool = true,
    pinnedConnection: V2BorrowedRoomConnection? = nil,
    _ body: @escaping @Sendable (any Database, V2ConfiguredRoomFenceContext) async throws -> Value
) async throws -> Value {
    try await v2WithRoomActivationTransactionCore(
        database: database, deadline: deadline, timeouts: timeouts, needsContext: true,
        sendOperationMetrics: sendOperationMetrics, measureConnectionAcquire: measureConnectionAcquire,
        pinnedConnection: pinnedConnection
    ) { borrowed, context in
        guard let context else { throw V2RoomActorStateError.activationChanged }
        return try await body(borrowed, context)
    }
}

private func v2WithRoomActivationTransactionCore<Value: Sendable>(
    database: any Database, deadline: ContinuousClock.Instant,
    timeouts: V2RoomActivationSQLTimeouts, needsContext: Bool,
    sendOperationMetrics: V2SendOperationBatchMetrics?, measureConnectionAcquire: Bool = true,
    readOnlyRepeatableRead: Bool = false,
    pinnedConnection: V2BorrowedRoomConnection? = nil,
    _ body: @escaping @Sendable (any Database, V2ConfiguredRoomFenceContext?) async throws -> Value
) async throws -> Value {
    let continuationMetrics = sendOperationMetrics ?? V2RoomSQLContinuationObservation.metrics
    if let pinnedConnection {
        return try await v2ExecutePinnedRoomTransaction(connection: pinnedConnection,
            deadline: deadline, timeouts: timeouts, needsContext: needsContext,
            sendOperationMetrics: sendOperationMetrics, continuationMetrics: continuationMetrics,
            readOnlyRepeatableRead: readOnlyRepeatableRead, body)
    }
    return try await v2WithRoomPhysicalConnection(database: database, deadline: deadline,
        sendOperationMetrics: sendOperationMetrics, measureConnectionAcquire: measureConnectionAcquire) { borrowed, control, sql, state in
        try await v2ExecuteBorrowedRoomTransaction(borrowed: borrowed, control: control, sql: sql,
            state: state, deadline: deadline, timeouts: timeouts, needsContext: needsContext,
            sendOperationMetrics: sendOperationMetrics, continuationMetrics: continuationMetrics,
            readOnlyRepeatableRead: readOnlyRepeatableRead, body)
    }
}

/// Own one physical loan across independent owner-cohort/isolation transactions.
/// This function opens no transaction and grants no room or quota authority.
func v2WithOwnerBatchConnection<Value: Sendable>(database: any Database,
    deadline: ContinuousClock.Instant, metrics: V2SendOperationBatchMetrics?,
    acquisitionOnly: Bool = false,
    interrupted: @escaping @Sendable (any Error) -> Void,
    _ body: @escaping @Sendable (any Database, @escaping @Sendable () -> Bool) async throws -> Value
) async throws -> Value {
    try await v2WithRoomPhysicalConnection(database: database, deadline: deadline,
        sendOperationMetrics: metrics, acquisitionOnly: acquisitionOnly, interrupted: interrupted) { borrowed, _, _, state in
        try await body(borrowed, { state.connectionIsUsable })
    }
}

/// Starts a real loan synchronously; the sole owner must await finish before
/// discarding this handle. Cancellation still waits for physical settlement.
package final class V2StartedRoomConnection<Value: Sendable>: Sendable {
    private let claimed = Mutex(false)
    private let finishBody: @Sendable () async throws -> Value
    init(_ finish: @escaping @Sendable () async throws -> Value) { finishBody = finish }
    func finish() async throws -> Value {
        precondition(claimed.withLock { value in
            guard !value else { return false }; value = true; return true
        }, "A started physical loan has exactly one settling owner")
        return try await finishBody()
    }
}

func v2StartOwnerBatchConnection<Value: Sendable>(database: any Database,
    deadline: ContinuousClock.Instant, metrics: V2SendOperationBatchMetrics?,
    acquisitionOnly: Bool = false,
    interrupted: @escaping @Sendable (any Error) -> Void,
    _ body: @escaping @Sendable (any Database, @escaping @Sendable () -> Bool) async throws -> Value
) throws -> V2StartedRoomConnection<Value> {
    try v2StartRoomPhysicalConnection(database: database, deadline: deadline,
        sendOperationMetrics: metrics, acquisitionOnly: acquisitionOnly, interrupted: interrupted) { borrowed, _, _, state in
        try await body(borrowed, { state.connectionIsUsable })
    }
}

private func v2WithRoomPhysicalConnection<Value: Sendable>(
    database: any Database,
    deadline: ContinuousClock.Instant,
    sendOperationMetrics: V2SendOperationBatchMetrics?,
    measureConnectionAcquire: Bool = true,
    acquisitionOnly: Bool = false,
    interrupted: @escaping @Sendable (any Error) -> Void = { _ in },
    _ body: @escaping @Sendable (any Database, any TransactionControlDatabase, any SQLDatabase, V2RoomPhysicalTransactionState) async throws -> Value
) async throws -> Value {
    let started = try v2StartRoomPhysicalConnection(database: database, deadline: deadline,
        sendOperationMetrics: sendOperationMetrics, measureConnectionAcquire: measureConnectionAcquire,
        acquisitionOnly: acquisitionOnly, interrupted: interrupted, body)
    return try await started.finish()
}

private func v2StartRoomPhysicalConnection<Value: Sendable>(
    database: any Database,
    deadline: ContinuousClock.Instant,
    sendOperationMetrics: V2SendOperationBatchMetrics?,
    measureConnectionAcquire: Bool = true,
    acquisitionOnly: Bool = false,
    interrupted: @escaping @Sendable (any Error) -> Void = { _ in },
    _ body: @escaping @Sendable (any Database, any TransactionControlDatabase, any SQLDatabase, V2RoomPhysicalTransactionState) async throws -> Value
) throws -> V2StartedRoomConnection<Value> {
    let connectionTimeline = V2OwnerConnectionTimeline.current
    let enteredAt = ContinuousClock.now
    connectionTimeline?.mark("physical_borrow_entered", at: enteredAt)
    if let started = connectionTimeline?.marker("store_borrow_entered") {
        connectionTimeline?.record(.ownerStoreToPhysicalEnter, from: started, to: enteredAt)
    }
    guard ContinuousClock().now < deadline else {
        throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
    }
    let state = V2RoomPhysicalTransactionState()
    let acquisitionCancellation = V2ConnectionAcquisitionCancellation()
    // 在借用连接前启动：连接池耗尽不能重置绝对时间预算。
    // 连接回调结束前同步解除计时回调，无需等待 Swift 计时任务被调度。
    let watchdog = V2RoomDeadlineTimer(deadline: deadline, eventLoop: database.eventLoop) {
        state.stop(.deadline)
        acquisitionCancellation.cancel()
        interrupted(state.notAcceptedFailure)
    }
    // Capture before NIO's connection callback creates its task. Task-local
    // recorder scope is not implicitly transferred from the caller's executor.
    let connectionTimer = measureConnectionAcquire ? sendOperationMetrics?.startStage(.ownerConnectionAcquire) : nil
    let sendTrace = V2SendPathTrace.current
    let timeline = V2OwnerConnectionTimeline.current
    let connectionBody: @Sendable (any Database) -> EventLoopFuture<Value> = { borrowed in
        guard let postgres = borrowed as? any PostgresDatabase,
              let control = borrowed as? any TransactionControlDatabase,
              let sql = borrowed as? any SQLDatabase else {
            return borrowed.eventLoop.makeFailedFuture(V2RoomWriteStoreError.corruptPersistenceState)
        }
        // Fluent 的借用包装器报告 inTransaction=true；调用其 `transaction`
        // 方法会跳过 BEGIN，因此这里显式控制事务。
        return postgres.withConnection { physical in
            let callbackAt = ContinuousClock.now
            let executor = V2DatabaseEventLoopTaskExecutor(physical.eventLoop)
            let promise = physical.eventLoop.makePromise(of: Value.self)
            Task(executorPreference: executor) {
                do {
                    let result: Value = try await V2BorrowedRoomConnectionScope.$current.withValue(
                        V2BorrowedRoomConnection(borrowed: borrowed, control: control, sql: sql, physical: physical,
                            taskExecutor: executor,
                            isUsable: { state.connectionIsUsable })) {
                        let taskAt = ContinuousClock.now
                        timeline?.record(.ownerDriverCallbackTaskWait, from: callbackAt, to: taskAt)
                        connectionTimer?.finish()
                        state.install(connection: physical)
                        if acquisitionOnly {
                            // The selected room owns the transaction deadline.
                            watchdog.disarm()
                        }
                        if ContinuousClock.now >= deadline { state.stop(.deadline) }
                        guard state.connectionIsUsable else { throw state.notAcceptedFailure }
                        return try await V2SendPathTrace.$current.withValue(sendTrace) {
                            try await V2OwnerConnectionTimeline.$current.withValue(timeline) {
                                try await body(borrowed, control, sql, state)
                            }
                        }
                    }
                    watchdog.disarm()
                    state.finishLoan()
                    try await state.settleClose()
                    promise.succeed(result)
                } catch {
                    watchdog.disarm()
                    state.finishLoan()
                    do { try await state.settleClose(); promise.fail(error) }
                    catch { promise.fail(error) }
                }
            }
            return promise.futureResult
        }
    }
    let transactionFuture: EventLoopFuture<Value>
    if let balanced = database as? V2EventLoopBalancedDatabase {
        transactionFuture = balanced.withScheduledConnection(deadline: deadline, acquisitionCancellation: acquisitionCancellation, connectionBody)
    } else { transactionFuture = database.withConnection(connectionBody) }
    return V2StartedRoomConnection {
        defer { timeline?.flushAssignmentTiming() }
        // EventLoopFuture.get() 有意不把 Task 取消传给连接任务。
        // 直接通知被跟踪的物理连接，
        // 并在释放前继续等待该 future 完成。
        let outcome: Result<Value, any Error>
        do {
            outcome = .success(try await withTaskCancellationHandler {
                try await transactionFuture.get()
            } onCancel: {
                state.stop(.cancelled)
                acquisitionCancellation.cancel()
                interrupted(state.notAcceptedFailure)
            })
        } catch {
            outcome = .failure(error)
        }
        // Acquisition failure (including pool timeout) ends only when the
        // actual future settles, never when the watchdog or caller stops waiting.
        connectionTimer?.finish()
        watchdog.disarm()
        try await state.settleClose()
        if state.wasStopped && !state.hadConnection {
            throw state.notAcceptedFailure
        }
        return try outcome.get()
    }
}

/// Available only while the physical loan's callback is alive.
struct V2BorrowedRoomConnection: Sendable {
    let borrowed: any Database
    let control: any TransactionControlDatabase
    let sql: any SQLDatabase
    let physical: PostgresConnection
    let taskExecutor: V2DatabaseEventLoopTaskExecutor
    let isUsable: @Sendable () -> Bool
}

enum V2BorrowedRoomConnectionScope {
    @TaskLocal static var current: V2BorrowedRoomConnection?
}

/// Issued only after a one-room statement returned zero cursor, message and
/// completion mutations. It permits recovery after ReadyForQuery confirms idle.
struct V2SingleStatementNoMutation: Error, Sendable {}

/// The body is exactly one atomic statement, with no subsequent durable work.
/// Result rows alone are insufficient: the implicit transaction must reach its
/// backend ReadyForQuery before this method returns a committed value.
func v2ExecuteSingleStatementRoomWrite<Value: Sendable>(
    connection: V2BorrowedRoomConnection, deadline: ContinuousClock.Instant,
    metrics: V2SendOperationBatchMetrics?,
    _ statement: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    guard !Task.isCancelled, .now < deadline, connection.isUsable() else {
        throw V2RoomCallFailure.notAccepted(Task.isCancelled ? .cancelled :
            (.now >= deadline ? .deadlineExceeded : .unavailable))
    }
    let statementTimer = metrics?.startStage(.ownerSingleStatement)
    defer { statementTimer?.finish() }
    let state = V2RoomPhysicalTransactionState()
    state.install(connection: connection.physical)
    let timer = V2RoomDeadlineTimer(deadline: deadline, eventLoop: connection.physical.eventLoop) {
        state.stop(.deadline)
    }
    defer { timer.disarm() }
    let outcome: Result<Value, any Error>
    do {
        outcome = .success(try await withTaskCancellationHandler {
            // Dispatching the write can dispatch an implicit COMMIT too. From
            // this point, closing the socket is never proof of rollback.
            guard state.beginCommit(deadline: deadline) else { throw state.notAcceptedFailure }
            let result: Result<Value, any Error>
            let bodyTimer = metrics?.startStage(.ownerBody)
            do { result = .success(try await statement()) }
            catch { result = .failure(error) }
            bodyTimer?.finish()
            let confirmationTimer = metrics?.startStage(.ownerCommit)
            let status: PostgresConnection.ReadyForQueryState
            do {
                status = try await connection.physical.confirmReadyForQuery().get()
                confirmationTimer?.finish()
            } catch {
                confirmationTimer?.finish()
                state.stop(.rollbackFailure)
                throw V2RoomTransactionOutcomeUnknown()
            }
            guard status == .idle else {
                state.stop(.rollbackFailure)
                throw V2RoomTransactionOutcomeUnknown()
            }
            V2OwnerConnectionTimeline.current?.mark("implicit_ready_confirmed")
            switch result {
            case .success(let value):
                state.confirmCommit()
                return value
            case .failure(let error):
                if error is V2SingleStatementNoMutation {
                    state.confirmRollback()
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                let statementFailed: Bool
                if let error = error as? PSQLError { statementFailed = error.serverInfo?[.sqlState] != nil }
                else if let error = error as? PostgresError, case .server = error { statementFailed = true }
                else { statementFailed = false }
                if statementFailed {
                    state.confirmRollback()
                    if v2PostgresFailureDisposition(error) == .unavailable {
                        throw V2RoomCallFailure.rolledBack(.unavailable)
                    }
                    throw error
                }
                // A local decoding/validation failure after a successful SQL
                // cycle cannot retroactively roll back the implicit commit.
                state.confirmCommit()
                throw V2RoomTransactionOutcomeUnknown()
            }
        } onCancel: { state.stop(.cancelled) })
    } catch { outcome = .failure(error) }
    timer.disarm()
    try await state.settleClose()
    return try outcome.get()
}

/// Execute on an already borrowed connection without a nested pool/future/task bridge.
private func v2ExecutePinnedRoomTransaction<Value: Sendable>(
    connection: V2BorrowedRoomConnection, deadline: ContinuousClock.Instant,
    timeouts: V2RoomActivationSQLTimeouts, needsContext: Bool,
    sendOperationMetrics: V2SendOperationBatchMetrics?, continuationMetrics: V2SendOperationBatchMetrics?,
    readOnlyRepeatableRead: Bool,
    _ body: @escaping @Sendable (any Database, V2ConfiguredRoomFenceContext?) async throws -> Value
) async throws -> Value {
    guard ContinuousClock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
    guard connection.isUsable() else { throw V2RoomCallFailure.notAccepted(.unavailable) }
    let state = V2RoomPhysicalTransactionState()
    state.install(connection: connection.physical)
    let timer = V2RoomDeadlineTimer(deadline: deadline, eventLoop: connection.physical.eventLoop) {
        state.stop(.deadline)
    }
    defer { timer.disarm() }
    let outcome: Result<Value, any Error>
    do {
        outcome = .success(try await withTaskCancellationHandler {
            try await v2ExecuteBorrowedRoomTransaction(borrowed: connection.borrowed,
                control: connection.control, sql: connection.sql, state: state,
                deadline: deadline, timeouts: timeouts, needsContext: needsContext,
                sendOperationMetrics: sendOperationMetrics, continuationMetrics: continuationMetrics,
                readOnlyRepeatableRead: readOnlyRepeatableRead, body)
        } onCancel: { state.stop(.cancelled) })
    } catch { outcome = .failure(error) }
    timer.disarm()
    try await state.settleClose()
    return try outcome.get()
}

private func v2ExecuteBorrowedRoomTransaction<Value: Sendable>(
    borrowed: any Database,
    control: any TransactionControlDatabase,
    sql: any SQLDatabase,
    state: V2RoomPhysicalTransactionState,
    deadline: ContinuousClock.Instant,
    timeouts: V2RoomActivationSQLTimeouts,
    needsContext: Bool,
    sendOperationMetrics: V2SendOperationBatchMetrics?,
    continuationMetrics: V2SendOperationBatchMetrics?,
    readOnlyRepeatableRead: Bool = false,
    _ body: @escaping @Sendable (any Database, V2ConfiguredRoomFenceContext?) async throws -> Value
) async throws -> Value {
    let continuationTrace = continuationMetrics.map { V2RoomSQLContinuationTrace(metrics: $0) }
    defer { continuationTrace?.finishWithoutDispatch() }
    guard state.beginTransaction() else {
        try await state.settleClose()
        throw state.notAcceptedFailure
    }
    var rollbackTimer: V2SendOperationStageTimer?
    defer { rollbackTimer?.finish() }
    do {
        let setupTimer = sendOperationMetrics?.startStage(.ownerSetup)
        do {
            defer { setupTimer?.finish() }
            try await V2OwnerConnectionTimeline.$sqlLabel.withValue(.begin) {
                try await control.beginTransaction().get()
            }
            if let timeline = V2OwnerConnectionTimeline.current, let settled = timeline.marker("begin_future_completed") {
                timeline.record(.ownerBeginResume, from: settled)
            }
            // Isolation must precede the timeout SELECT, which establishes a
            // snapshot. The physical loan watchdog still owns close and join.
            if readOnlyRepeatableRead {
                try await sql.raw("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY").run()
            }
            // Verified message-pool defaults need no setup round trip. Other handles
            // and custom policies install LOCAL limits before any business SQL.
            if (borrowed as? any V2RoomSQLSessionDefaults)?.roomSQLSessionTimeouts != timeouts {
                try await v2SetRoomActivationSQLTimeouts(timeouts, sql: sql)
            }
        }
        let context = needsContext
            ? V2ConfiguredRoomFenceContext(sql: sql, timeouts: timeouts, state: state) : nil
        let admissionTrace = sendOperationMetrics.map { _ in V2OwnerAdmissionHandoffTrace() }
        let value: Value
        let bodyTimer = sendOperationMetrics?.startStage(.ownerBody)
        do {
            defer { bodyTimer?.finish() }
            value = try await V2RoomSQLContinuationObservation.$current.withValue(continuationTrace) {
                try await V2OwnerAdmissionHandoffObservation.$current.withValue(admissionTrace) {
                    try await body(borrowed, context)
                }
            }
        }
        catch {
            context?.invalidate()
            throw error
        }
        context?.invalidate()
        guard state.beginCommit(deadline: deadline) else {
            rollbackTimer = sendOperationMetrics?.startStage(.ownerRollback)
            try await state.settleClose()
            throw state.rollbackFailure
        }
        let commitTimer = sendOperationMetrics?.startStage(.ownerCommit)
        do {
            defer { commitTimer?.finish() }
            if let sendOperationMetrics { admissionTrace?.willDispatchCommit(metrics: sendOperationMetrics) }
            continuationTrace?.willDispatch()
            try await V2OwnerConnectionTimeline.$sqlLabel.withValue(.commit) {
                try await control.commitTransaction().get()
            }
            if let timeline = V2OwnerConnectionTimeline.current, let settled = timeline.marker("commit_future_completed") {
                timeline.record(.ownerCommitResume, from: settled)
            }
            state.confirmCommit()
            return value
        } catch {
            // 即使 COMMIT 被延后，PostgreSQL 也能证明死锁或序列化冲突已回滚。
            // 其他未收到 COMMIT 确认的情况都属于结果不明。
            if v2PostgresFailureDisposition(error) == .retryTransaction {
                state.confirmRollback()
                throw error
            }
            throw V2RoomTransactionOutcomeUnknown()
        }
    } catch {
        if state.commitWasDispatched { throw error }
        if rollbackTimer == nil { rollbackTimer = sendOperationMetrics?.startStage(.ownerRollback) }
        if state.wasStopped {
            try await state.settleClose()
            throw state.rollbackFailure
        }
        do {
            continuationTrace?.willDispatch()
            try await control.rollbackTransaction().get()
            state.confirmRollback()
        } catch {
            // COMMIT 从未发出。只有物理连接关闭完成，才能证明事务之后不会提交。
            state.stop(.rollbackFailure)
            try await state.settleClose()
        }
        if state.wasStopped {
            try await state.settleClose()
            throw state.rollbackFailure
        }
        if v2PostgresFailureDisposition(error) == .unavailable {
            // SQL 锁或语句在 COMMIT 前超时，且该事务的 ROLLBACK 已获确认。
            // 为房间轮次保留这一证明，不将结果报告为未知。
            throw V2RoomCallFailure.rolledBack(.unavailable)
        }
        throw error
    }
}

/// 组合房间锁与围栏所用的内部事务绑定权限。只有物理事务能创建它。
/// 活动使用检查确保逃逸或并发使用的上下文以安全方式失败，
/// 而不是在外围事务返回后重新借用连接。
final class V2ConfiguredRoomFenceContext: @unchecked Sendable {
    private struct Lifecycle: Sendable {
        var active = true
        var inUse = false
        var used = false
    }

    private let sql: any SQLDatabase
    private let configuredTimeouts: V2RoomActivationSQLTimeouts
    private let transactionState: V2RoomPhysicalTransactionState
    private let lifecycle: Mutex<Lifecycle>

    fileprivate init(sql: any SQLDatabase, timeouts: V2RoomActivationSQLTimeouts,
                     state: V2RoomPhysicalTransactionState) {
        self.sql = sql
        configuredTimeouts = timeouts
        transactionState = state
        lifecycle = Mutex(Lifecycle())
    }

    /// 此一次性操作只使用外围物理事务提供的 SQL 连接。
    /// 事务主体返回前必须等待所有 SQL 完成；若仍有未结束的操作，
    /// invalidate 会关闭连接，避免 COMMIT 和后续复用。
    func requireSelectedOwnersAndActivations(
        roomIDs: [UUID],
        expectedRoutes: [UUID: V2RoomShardRoute]?,
        expectedKinds: [UUID: String]?,
        scope: V2RoomActivationWriteScope,
        timeouts: V2RoomActivationSQLTimeouts = .default
    ) async throws {
        if scope.reliesOnRuntimeLifecycle {
            for room in Set(roomIDs) { _ = try scope.token(for: room) }
            return
        }
        try lifecycle.withLock { lifecycle in
            guard lifecycle.active, !lifecycle.inUse, !lifecycle.used else {
                throw V2RoomActorStateError.activationChanged
            }
            lifecycle.inUse = true
            lifecycle.used = true
        }
        defer {
            lifecycle.withLock { $0.inUse = false }
            // Failed fence validation may be caught by a domain/savepoint
            // path. Do not carry its observation across uninstrumented SQL.
            V2RoomSQLContinuationObservation.current?.finishWithoutDispatch()
        }
        if roomIDs.count == 1, timeouts == configuredTimeouts {
            try await requireSingleOwnerAndActivation(
                roomID: roomIDs[0], expectedRoutes: expectedRoutes,
                expectedKinds: expectedKinds, scope: scope)
            return
        }
        let orderedRooms = Set(roomIDs).sorted { $0.uuidString < $1.uuidString }
        guard !orderedRooms.isEmpty else { throw V2RoomActorStateError.activationChanged }
        if let expectedRoutes,
           !orderedRooms.allSatisfy({ expectedRoutes[$0] != nil }) {
            throw V2RoomOwnerFenceError.ownerChanged
        }
        if timeouts != configuredTimeouts {
            // 此优化只适用于事务设置的确切 LOCAL 策略。
            // 其他策略会在首次加锁前设置限制，然后执行完整的原始围栏检查。
            try await v2SetRoomActivationSQLTimeouts(timeouts, sql: sql)
        }
        let roomIDsJSON = String(decoding: try JSONEncoder().encode(
            orderedRooms.map(\.uuidString)), as: UTF8.self)
        let rows = try await v2RoomSQLObservedAll(sql.raw("""
            SELECT room_id, room_shard_id, owner_epoch, room_kind FROM im_v2.rooms
            WHERE room_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: roomIDsJSON)::jsonb))
            ORDER BY room_id FOR NO KEY UPDATE
            """), decoding: V2ConfiguredRoomOwnerRow.self, source: .configuredFenceRooms)
        // 保持普通写入路径的错误优先级：先检查类型，再检查路由行数和所有者，
        // 最后核对当前轮次令牌的数据 Owner。
        if let expectedKinds,
           rows.contains(where: { row in
               expectedKinds[row.roomID].map { $0 != row.kind } ?? false
           }) {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard rows.count == orderedRooms.count,
              Set(rows.map(\.roomID)) == Set(orderedRooms) else {
            if expectedRoutes != nil { throw V2RoomOwnerFenceError.ownerChanged }
            throw V2RoomActorStateError.roomNotFound
        }
        if let expectedRoutes,
           rows.contains(where: { row in
               guard let route = expectedRoutes[row.roomID] else { return true }
               return route.shardID != row.shardID || route.epoch != row.epoch
           }) {
            throw V2RoomOwnerFenceError.ownerChanged
        }
        let rowsByRoom = Dictionary(uniqueKeysWithValues: rows.map { ($0.roomID, $0) })
        let orderedTokens = try orderedRooms.map { room -> (UUID, V2RoomActivationToken) in
            let token = try scope.token(for: room)
            guard let row = rowsByRoom[room],
                  row.shardID == token.owner.shardID,
                  row.epoch == token.owner.epoch else {
                throw V2RoomActorStateError.ownerChanged
            }
            return (room, token)
        }
        // The scope is owned by an accepted Actor turn. Its lifecycle cannot
        // complete while this transaction is outstanding; only data-owner
        // identity is checked in SQL. No second activation row or clock query.
        _ = orderedTokens

    }

    /// 主键查询最多返回一行，因此无须构造多房间加锁方案，
    /// 并保持与集合路径相同的数据 Owner 校验。
    private func requireSingleOwnerAndActivation(
        roomID: UUID,
        expectedRoutes: [UUID: V2RoomShardRoute]?,
        expectedKinds: [UUID: String]?,
        scope: V2RoomActivationWriteScope
    ) async throws {
        if let expectedRoutes, expectedRoutes[roomID] == nil {
            throw V2RoomOwnerFenceError.ownerChanged
        }
        let room = try await v2RoomSQLObservedFirst(sql.raw("""
            SELECT room_id, room_shard_id, owner_epoch, room_kind FROM im_v2.rooms
            WHERE room_id = \(bind: roomID) FOR NO KEY UPDATE
            """), decoding: V2ConfiguredRoomOwnerRow.self, source: .configuredFenceRooms)
        // 保持集合路径的错误优先级：类型、记录是否存在及选定路由，
        // 然后核对当前轮次令牌的数据 Owner。
        if let room, let kind = expectedKinds?[roomID], kind != room.kind {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard let room, room.roomID == roomID else {
            if expectedRoutes != nil { throw V2RoomOwnerFenceError.ownerChanged }
            throw V2RoomActorStateError.roomNotFound
        }
        if let route = expectedRoutes?[roomID],
           (route.shardID != room.shardID || route.epoch != room.epoch) {
            throw V2RoomOwnerFenceError.ownerChanged
        }
        let token = try scope.token(for: roomID)
        guard room.shardID == token.owner.shardID,
              room.epoch == token.owner.epoch else {
            throw V2RoomActorStateError.ownerChanged
        }

    }

    fileprivate func invalidate() {
        let wasInUse = lifecycle.withLock { lifecycle -> Bool in
            lifecycle.active = false
            return lifecycle.inUse
        }
        if wasInUse { transactionState.stop(.cancelled) }
    }
}

private struct V2ConfiguredRoomOwnerRow: Decodable {
    let roomID: UUID
    let shardID: String
    let epoch: Int64
    let kind: String
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", shardID = "room_shard_id"
        case epoch = "owner_epoch", kind = "room_kind"
    }
}

private final class V2RoomPhysicalTransactionState: Sendable {
    enum StopReason: Sendable { case deadline, cancelled, rollbackFailure }
    private enum Phase: Sendable {
        case beforeBegin, beforeCommit, commitDispatched, confirmed, resolvedRollback
    }
    private struct State: Sendable {
        var phase: Phase = .beforeBegin
        var stopReason: StopReason?
        var connection: PostgresConnection?
        var closeFuture: EventLoopFuture<Void>?
        var loanFinished = false
    }

    private let state = Mutex(State())

    func install(connection: PostgresConnection) {
        state.withLock {
            $0.connection = connection
            if $0.stopReason != nil && $0.closeFuture == nil {
                $0.closeFuture = connection.close()
            }
        }
    }

    var wasStopped: Bool { state.withLock { $0.stopReason != nil } }
    var hadConnection: Bool { state.withLock { $0.connection != nil } }
    var connectionIsUsable: Bool { state.withLock { !$0.loanFinished && $0.stopReason == nil && $0.connection?.isClosed == false } }
    var commitWasDispatched: Bool {
        state.withLock {
            $0.phase == .commitDispatched || $0.phase == .confirmed || $0.phase == .resolvedRollback
        }
    }
    var rollbackFailure: V2RoomCallFailure {
        state.withLock {
            switch $0.stopReason {
            case .deadline: .rolledBack(.deadlineExceeded)
            case .cancelled: .rolledBack(.cancelled)
            case .rollbackFailure, nil: .rolledBack(.unavailable)
            }
        }
    }
    var notAcceptedFailure: V2RoomCallFailure {
        state.withLock {
            switch $0.stopReason {
            case .deadline: .notAccepted(.deadlineExceeded)
            case .cancelled: .notAccepted(.cancelled)
            case .rollbackFailure, nil: .notAccepted(.unavailable)
            }
        }
    }

    func beginCommit(deadline: ContinuousClock.Instant) -> Bool {
        state.withLock {
            // The EventLoop timer callback may be delayed behind other jobs,
            // including a body that already crossed the budget, so enforce the
            // same absolute deadline at the COMMIT dispatch boundary as well.
            if $0.stopReason == nil, ContinuousClock.now >= deadline {
                $0.stopReason = .deadline
                if $0.closeFuture == nil, let connection = $0.connection {
                    $0.closeFuture = connection.close()
                }
            }
            guard $0.stopReason == nil else { return false }
            $0.phase = .commitDispatched
            return true
        }
    }

    func beginTransaction() -> Bool {
        state.withLock {
            guard $0.stopReason == nil else { return false }
            $0.phase = .beforeCommit
            return true
        }
    }

    func confirmCommit() {
        state.withLock { $0.phase = .confirmed }
    }

    func confirmRollback() {
        state.withLock { $0.phase = .resolvedRollback }
    }

    func stop(_ reason: StopReason) {
        state.withLock {
            guard !$0.loanFinished, $0.phase != .confirmed && $0.phase != .resolvedRollback else { return }
            if $0.stopReason == nil { $0.stopReason = reason }
            if $0.closeFuture == nil, let connection = $0.connection {
                $0.closeFuture = connection.close()
            }
        }
    }

    /// Cancellation can arrive after the pool callback settles but before its
    /// caller resumes. It must never close a connection now owned by another loan.
    func finishLoan() { state.withLock { $0.loanFinished = true } }

    func settleClose() async throws {
        let snapshot = state.withLock { ($0.closeFuture, $0.connection, $0.stopReason, $0.phase) }
        guard let connection = snapshot.1 else { return }
        if let future = snapshot.0 {
            do { try await future.get() }
            catch {
                if snapshot.3 != .confirmed && snapshot.3 != .resolvedRollback {
                    throw V2RoomTransactionOutcomeUnknown()
                }
            }
        }
        if snapshot.2 != nil && snapshot.3 != .confirmed && snapshot.3 != .resolvedRollback
            && !connection.isClosed {
            throw V2RoomTransactionOutcomeUnknown()
        }
    }
}
