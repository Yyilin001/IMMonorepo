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
/// 方法会等待主体、看门狗及可能的关闭操作全部结束。因此调用方超时后，
/// 不会把仍活动的 SQL 事务放回连接池，也不会在其连接上执行后续语句。
/// 主体不能在借用的连接上执行事务控制 SQL，或重试已中止的事务；
/// 重试必须重新调用此方法。
func v2WithRoomActivationTransaction<Value: Sendable>(
    database: any Database,
    deadline: ContinuousClock.Instant,
    timeouts: V2RoomActivationSQLTimeouts = .default,
    _ body: @escaping @Sendable (any Database) async throws -> Value
) async throws -> Value {
    try await v2WithRoomActivationTransactionCore(
        database: database, deadline: deadline, timeouts: timeouts, needsContext: false
    ) { borrowed, _ in
        try await body(borrowed)
    }
}

/// 只在执行 BEGIN 和首次设置 LOCAL 超时后创建上下文。
/// 它持有实际借用的 SQL 连接；使用其组合房间围栏时，调用方不能替换为池中其他连接。
func v2WithRoomActivationTransactionWithContext<Value: Sendable>(
    database: any Database,
    deadline: ContinuousClock.Instant,
    timeouts: V2RoomActivationSQLTimeouts = .default,
    _ body: @escaping @Sendable (any Database, V2ConfiguredRoomFenceContext) async throws -> Value
) async throws -> Value {
    try await v2WithRoomActivationTransactionCore(
        database: database, deadline: deadline, timeouts: timeouts, needsContext: true
    ) { borrowed, context in
        guard let context else { throw V2RoomActivationLeaseError.activationChanged }
        return try await body(borrowed, context)
    }
}

private func v2WithRoomActivationTransactionCore<Value: Sendable>(
    database: any Database,
    deadline: ContinuousClock.Instant,
    timeouts: V2RoomActivationSQLTimeouts,
    needsContext: Bool,
    _ body: @escaping @Sendable (any Database, V2ConfiguredRoomFenceContext?) async throws -> Value
) async throws -> Value {
    guard ContinuousClock().now < deadline else {
        throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
    }
    let state = V2RoomPhysicalTransactionState()
    // 在借用连接前启动：连接池耗尽不能重置绝对时间预算。
    // 公开调用返回前必须等待此任务结束。
    let watchdog = Task<Void, Never> {
        do {
            try await Task.sleep(until: deadline, clock: .continuous)
            state.stop(.deadline)
        } catch is CancellationError {
            // 操作完成后取消计时器。
        } catch {
            state.stop(.deadline)
        }
    }
    let transactionFuture: EventLoopFuture<Value> = database.withConnection { borrowed in
        guard let postgres = borrowed as? any PostgresDatabase,
              let control = borrowed as? any TransactionControlDatabase,
              let sql = borrowed as? any SQLDatabase else {
            return borrowed.eventLoop.makeFailedFuture(V2RoomWriteStoreError.corruptPersistenceState)
        }
        // Fluent 的借用包装器报告 inTransaction=true；调用其 `transaction`
        // 方法会跳过 BEGIN，因此这里显式控制事务。
        return postgres.withConnection { physical in
            physical.eventLoop.makeFutureWithTask {
                state.install(connection: physical)
                if ContinuousClock().now >= deadline { state.stop(.deadline) }
                return try await v2ExecuteBorrowedRoomTransaction(borrowed: borrowed,
                    control: control, sql: sql, state: state,
                    timeouts: timeouts, needsContext: needsContext, body)
            }
        }
    }
    // EventLoopFuture.get() 有意不把 Task 取消传给 future 的
    // makeFutureWithTask 主体。直接通知被跟踪的物理连接，
    // 并在释放前继续等待该 future 完成。
    let outcome: Result<Value, any Error>
    do {
        outcome = .success(try await withTaskCancellationHandler {
            try await transactionFuture.get()
        } onCancel: {
            state.stop(.cancelled)
        })
    } catch {
        outcome = .failure(error)
    }
    watchdog.cancel()
    await watchdog.value
    try await state.settleClose()
    if state.wasStopped && !state.hadConnection {
        throw state.notAcceptedFailure
    }
    return try outcome.get()
}

private func v2ExecuteBorrowedRoomTransaction<Value: Sendable>(
    borrowed: any Database,
    control: any TransactionControlDatabase,
    sql: any SQLDatabase,
    state: V2RoomPhysicalTransactionState,
    timeouts: V2RoomActivationSQLTimeouts,
    needsContext: Bool,
    _ body: @escaping @Sendable (any Database, V2ConfiguredRoomFenceContext?) async throws -> Value
) async throws -> Value {
    guard state.beginTransaction() else {
        try await state.settleClose()
        throw state.notAcceptedFailure
    }
    do {
        try await control.beginTransaction().get()
        // 这些 LOCAL 限制必须先于操作咨询锁和房间锁设置。
        try await v2SetRoomActivationSQLTimeouts(timeouts, sql: sql)
        let context = needsContext
            ? V2ConfiguredRoomFenceContext(sql: sql, timeouts: timeouts, state: state) : nil
        let value: Value
        do { value = try await body(borrowed, context) }
        catch {
            context?.invalidate()
            throw error
        }
        context?.invalidate()
        guard state.beginCommit() else {
            try await state.settleClose()
            throw state.rollbackFailure
        }
        do {
            try await control.commitTransaction().get()
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
        if state.wasStopped {
            try await state.settleClose()
            throw state.rollbackFailure
        }
        do {
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
        try lifecycle.withLock { lifecycle in
            guard lifecycle.active, !lifecycle.inUse, !lifecycle.used else {
                throw V2RoomActivationLeaseError.activationChanged
            }
            lifecycle.inUse = true
            lifecycle.used = true
        }
        defer { lifecycle.withLock { $0.inUse = false } }
        if roomIDs.count == 1, timeouts == configuredTimeouts {
            try await requireSingleOwnerAndActivation(
                roomID: roomIDs[0], expectedRoutes: expectedRoutes,
                expectedKinds: expectedKinds, scope: scope)
            return
        }
        let orderedRooms = Set(roomIDs).sorted { $0.uuidString < $1.uuidString }
        guard !orderedRooms.isEmpty else { throw V2RoomActivationLeaseError.activationChanged }
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
        let rows = try await sql.raw("""
            SELECT room_id, room_shard_id, owner_epoch, room_kind FROM im_v2.rooms
            WHERE room_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: roomIDsJSON)::jsonb))
            ORDER BY room_id FOR NO KEY UPDATE
            """).all(decoding: V2ConfiguredRoomOwnerRow.self)
        // 保持普通写入路径的错误优先级：先检查类型，再检查路由行数和所有者，
        // 最后检查精确激活令牌及租约。
        if let expectedKinds,
           rows.contains(where: { row in
               expectedKinds[row.roomID].map { $0 != row.kind } ?? false
           }) {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard rows.count == orderedRooms.count,
              Set(rows.map(\.roomID)) == Set(orderedRooms) else {
            if expectedRoutes != nil { throw V2RoomOwnerFenceError.ownerChanged }
            throw V2RoomActivationLeaseError.roomNotFound
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
                throw V2RoomActivationLeaseError.ownerChanged
            }
            return (room, token)
        }
        if timeouts != configuredTimeouts {
            // 完整默认路径：重新设置 LOCAL 限制，独立加锁并校验房间记录，
            // 再检查租约和数据库时钟。
            try await v2RequireRoomActivations(tokens: orderedTokens.map { $0.1 },
                                               sql: sql, timeouts: timeouts)
            return
        }
        var leases: [(V2RoomActivationToken, V2RoomActivationPersistenceRow?)] = []
        for (room, token) in orderedTokens {
            let row = try await sql.raw("""
                SELECT activation_epoch, owner_shard_id, owner_epoch, host_id, host_incarnation_id, expires_at
                FROM im_v2.room_activation_leases WHERE room_id = \(bind: room) FOR UPDATE
                """).first(decoding: V2RoomActivationPersistenceRow.self)
            leases.append((token, row))
        }
        // clock_timestamp 必须在取得所有房间锁和租约锁后调用；
        // 等锁期间可能越过过期时间，而 now() 固定在事务开始时。
        let observed = try await v2RoomActivationDatabaseClock(sql: sql)
        for (token, row) in leases {
            guard let row, row.matches(token) else {
                throw V2RoomActivationLeaseError.activationChanged
            }
            guard let expiresAt = row.expiresAt, expiresAt > observed else {
                throw V2RoomActivationLeaseError.leaseExpired
            }
        }
    }

    /// 主键查询最多返回一行，因此无须构造多房间加锁方案，
    /// 也能保持相同的房间锁与租约锁顺序。
    private func requireSingleOwnerAndActivation(
        roomID: UUID,
        expectedRoutes: [UUID: V2RoomShardRoute]?,
        expectedKinds: [UUID: String]?,
        scope: V2RoomActivationWriteScope
    ) async throws {
        if let expectedRoutes, expectedRoutes[roomID] == nil {
            throw V2RoomOwnerFenceError.ownerChanged
        }
        let room = try await sql.raw("""
            SELECT room_id, room_shard_id, owner_epoch, room_kind FROM im_v2.rooms
            WHERE room_id = \(bind: roomID) FOR NO KEY UPDATE
            """).first(decoding: V2ConfiguredRoomOwnerRow.self)
        // 保持集合路径的错误优先级：类型、记录是否存在及选定路由，
        // 然后才是不可变令牌和当前租约。
        if let room, let kind = expectedKinds?[roomID], kind != room.kind {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard let room, room.roomID == roomID else {
            if expectedRoutes != nil { throw V2RoomOwnerFenceError.ownerChanged }
            throw V2RoomActivationLeaseError.roomNotFound
        }
        if let route = expectedRoutes?[roomID],
           (route.shardID != room.shardID || route.epoch != room.epoch) {
            throw V2RoomOwnerFenceError.ownerChanged
        }
        let token = try scope.token(for: roomID)
        guard room.shardID == token.owner.shardID,
              room.epoch == token.owner.epoch else {
            throw V2RoomActivationLeaseError.ownerChanged
        }
        let lease = try await sql.raw("""
            SELECT activation_epoch, owner_shard_id, owner_epoch, host_id, host_incarnation_id, expires_at
            FROM im_v2.room_activation_leases WHERE room_id = \(bind: roomID) FOR UPDATE
            """).first(decoding: V2RoomActivationPersistenceRow.self)
        // 取得两把锁后才读取数据库时钟。
        let observed = try await v2RoomActivationDatabaseClock(sql: sql)
        guard let lease, lease.matches(token) else {
            throw V2RoomActivationLeaseError.activationChanged
        }
        guard let expiresAt = lease.expiresAt, expiresAt > observed else {
            throw V2RoomActivationLeaseError.leaseExpired
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

    func beginCommit() -> Bool {
        state.withLock {
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
            guard $0.phase != .confirmed && $0.phase != .resolvedRollback else { return }
            if $0.stopReason == nil { $0.stopReason = reason }
            if $0.closeFuture == nil, let connection = $0.connection {
                $0.closeFuture = connection.close()
            }
        }
    }

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
