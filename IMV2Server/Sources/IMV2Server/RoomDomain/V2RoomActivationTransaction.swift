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
                    timeouts: timeouts, body)
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
    _ body: @escaping @Sendable (any Database) async throws -> Value
) async throws -> Value {
    guard state.beginTransaction() else {
        try await state.settleClose()
        throw state.notAcceptedFailure
    }
    do {
        try await control.beginTransaction().get()
        // No operation advisory or room lock precedes these LOCAL limits.
        try await v2SetRoomActivationSQLTimeouts(timeouts, sql: sql)
        let value = try await body(borrowed)
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
