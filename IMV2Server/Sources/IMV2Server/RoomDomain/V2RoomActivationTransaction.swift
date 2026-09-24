import FluentKit
import Foundation
import IMV2ActorContracts
import NIOCore
import PostgresKit
import PostgresNIO
import SQLKit
import Synchronization

/// One room transaction attempt with a monotonic total deadline. The caller
/// supplies the already selected owner database; retry remains a separate
/// decision after this attempt has completely settled.
///
/// PostgreSQL 16 has no transaction_timeout. LOCAL SQL limits still bound each
/// individual wait or statement; this watchdog closes only the borrowed
/// physical connection when the total deadline expires. This call
/// does not complete until the body, watchdog, and any
/// close have settled. A caller timeout therefore cannot release a live SQL
/// transaction into the pool or run later statements on its connection.
/// The body must not issue transaction-control SQL or retry an aborted
/// transaction on this borrowed handle; retries need a fresh invocation.
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

/// The context is minted only after BEGIN and the first LOCAL timeout setting.
/// It owns the exact borrowed SQL handle; callers cannot substitute a pooled
/// connection when using its combined room fence.
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
    // Start before borrowing: an exhausted pool must not reset the absolute
    // budget. This task is joined before the public call can return.
    let watchdog = Task<Void, Never> {
        do {
            try await Task.sleep(until: deadline, clock: .continuous)
            state.stop(.deadline)
        } catch is CancellationError {
            // Completed operation cancels the timer.
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
        // Fluent's borrowed wrapper reports inTransaction=true. Calling its
        // `transaction` method would skip BEGIN, so drive the explicit controls.
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
    // EventLoopFuture.get() deliberately does not propagate Task cancellation
    // into the future's makeFutureWithTask body. Signal the tracked physical
    // connection directly, then still await that future before releasing it.
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
        // No operation advisory or room lock precedes these LOCAL limits.
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
            // PostgreSQL proves a deadlock/serialization rollback even at
            // deferred COMMIT. Every other missing COMMIT ACK is ambiguous.
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
            // COMMIT was never sent. Only a settled physical close proves
            // this transaction cannot subsequently be committed.
            state.stop(.rollbackFailure)
            try await state.settleClose()
        }
        if state.wasStopped {
            try await state.settleClose()
            throw state.rollbackFailure
        }
        if v2PostgresFailureDisposition(error) == .unavailable {
            // A SQL lock/statement timeout happened before COMMIT and this
            // transaction's ROLLBACK was acknowledged. Preserve that proof
            // for the room turn instead of reporting an unknown outcome.
            throw V2RoomCallFailure.rolledBack(.unavailable)
        }
        throw error
    }
}

/// Internal transaction-bound authority for the combined room lock and fence.
/// Only the physical transaction can construct it. The active-use guard makes
/// an escaped or concurrently used context fail closed rather than borrowing a
/// connection after its enclosing transaction has returned.
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

    /// This one-shot operation uses only the SQL handle that the enclosing
    /// physical transaction supplied. The transaction body must await all
    /// its SQL before returning; invalidate closes an improperly outstanding
    /// operation instead of allowing COMMIT and later reuse.
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
            // The optimization is valid only for the exact LOCAL policy the
            // transaction installed. A different policy takes the complete
            // original fence after setting its limits before the first lock.
            try await v2SetRoomActivationSQLTimeouts(timeouts, sql: sql)
        }
        let roomIDsJSON = String(decoding: try JSONEncoder().encode(
            orderedRooms.map(\.uuidString)), as: UTF8.self)
        let rows = try await sql.raw("""
            SELECT room_id, room_shard_id, owner_epoch, room_kind FROM im_v2.rooms
            WHERE room_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: roomIDsJSON)::jsonb))
            ORDER BY room_id FOR NO KEY UPDATE
            """).all(decoding: V2ConfiguredRoomOwnerRow.self)
        // Preserve the ordinary writer's error priority: kind before route
        // row-count/owner, then the exact activation token and lease.
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
            // Full default path: it re-applies LOCAL limits and independently
            // locks/verifies room rows, then leases and DB clock.
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
        // clock_timestamp must run after every room and lease lock; a wait
        // can cross expiry, whereas now() is fixed at transaction start.
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

    /// A primary-key lookup has only one row, so this retains the same room
    /// and lease lock order without constructing the multi-room lock plan.
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
        // Preserve the collection path's error priority: kind, presence and
        // selected route, then the immutable token and current lease.
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
        // Observe the database clock only after both locks were acquired.
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
