import IMV2ServerContracts
import FluentKit
import Logging
import NIOCore
import PostgresNIO
import SQLKit

protocol V2RoomSQLSessionDefaults {
    var roomSQLSessionTimeouts: V2RoomActivationSQLTimeouts? { get }
}

protocol V2ObservedDatabaseHandle {
    var loanObservation: V2DatabaseLoanObservation? { get }
}

/// Observes an already borrowed handle. Nested operations keep this same loan;
/// no extra connection, transaction, SQL or task is introduced.
func v2ObserveBorrowedDatabase(_ database: any Database,
    observation: V2DatabaseLoanObservation?,
    sessionTimeouts: V2RoomActivationSQLTimeouts? = nil) -> any Database {
    let sessionTimeouts = sessionTimeouts ?? (database as? any V2RoomSQLSessionDefaults)?.roomSQLSessionTimeouts
    guard observation != nil || sessionTimeouts != nil, let sql = database as? any SQLDatabase else { return database }
    let core = V2ObservedSQLBorrow(database: database, sql: sql, observation: observation, roomSQLSessionTimeouts: sessionTimeouts)
    if let postgres = database as? any PostgresDatabase,
       let control = database as? any TransactionControlDatabase {
        return V2ObservedPostgresBorrow(core: core, postgres: postgres, control: control)
    }
    return core
}

private struct V2ObservedSQLBorrow: Database, SQLDatabase, V2ObservedDatabaseHandle, V2RoomSQLSessionDefaults {
    let database: any Database
    let sql: any SQLDatabase
    let observation: V2DatabaseLoanObservation?
    let roomSQLSessionTimeouts: V2RoomActivationSQLTimeouts?
    var loanObservation: V2DatabaseLoanObservation? { observation }
    var context: DatabaseContext { database.context }
    var inTransaction: Bool { database.inTransaction }
    var logger: Logger { sql.logger }
    var eventLoop: any EventLoop { database.eventLoop }
    var dialect: any SQLDialect { sql.dialect }
    var queryLogLevel: Logger.Level? { sql.queryLogLevel }
    var version: (any SQLDatabaseReportedVersion)? { sql.version }

    func observe<T>(phase: V2DatabaseLoanSQLPhase? = nil,
        _ operation: () -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        guard let observation else { return operation() }
        let token = observation.startSQL(phase: phase)
        let actual = operation()
        actual.whenComplete { [observation] _ in observation.finishSQL(token) }
        return actual
    }
    func execute(query: DatabaseQuery,
        onOutput: @escaping @Sendable (any DatabaseOutput) -> Void) -> EventLoopFuture<Void> {
        observe { database.execute(query: query, onOutput: onOutput) }
    }
    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> {
        observe { database.execute(schema: schema) }
    }
    func execute(enum value: DatabaseEnum) -> EventLoopFuture<Void> {
        observe { database.execute(enum: value) }
    }
    func execute(sql query: any SQLExpression,
        _ onRow: @escaping @Sendable (any SQLRow) -> Void) -> EventLoopFuture<Void> {
        observe { sql.execute(sql: query, onRow) }
    }
    func execute(sql query: any SQLExpression,
        _ onRow: @escaping @Sendable (any SQLRow) -> Void) async throws {
        // Track actual SDK completion, rather than the lifetime of a waiter.
        let actual: EventLoopFuture<Void> = execute(sql: query, onRow)
        try await actual.get()
    }
    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        database.transaction { [observation, roomSQLSessionTimeouts] borrowed in
            closure(v2ObserveBorrowedDatabase(borrowed, observation: observation, sessionTimeouts: roomSQLSessionTimeouts))
        }
    }
    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        database.withConnection { [observation, roomSQLSessionTimeouts] borrowed in
            closure(v2ObserveBorrowedDatabase(borrowed, observation: observation, sessionTimeouts: roomSQLSessionTimeouts))
        }
    }
    func withSession<R>(_ closure: @escaping @Sendable (any SQLDatabase) async throws -> R) async throws -> R {
        try await sql.withSession { [observation, database, roomSQLSessionTimeouts] session in
            try await closure(V2ObservedSQLBorrow(database: database, sql: session, observation: observation, roomSQLSessionTimeouts: roomSQLSessionTimeouts))
        }
    }
}

/// Preserve the driver's conditional transaction/physical-connection capability.
/// Explicit BEGIN/COMMIT/ROLLBACK also belong to the same actual loan.
private struct V2ObservedPostgresBorrow: Database, SQLDatabase, PostgresDatabase, TransactionControlDatabase, V2ObservedDatabaseHandle, V2RoomSQLSessionDefaults {
    let core: V2ObservedSQLBorrow
    let postgres: any PostgresDatabase
    let control: any TransactionControlDatabase
    var loanObservation: V2DatabaseLoanObservation? { core.observation }
    var roomSQLSessionTimeouts: V2RoomActivationSQLTimeouts? { core.roomSQLSessionTimeouts }
    var context: DatabaseContext { core.context }
    var inTransaction: Bool { core.inTransaction }
    var logger: Logger { core.logger }
    var eventLoop: any EventLoop { core.eventLoop }
    var dialect: any SQLDialect { core.dialect }
    var queryLogLevel: Logger.Level? { core.queryLogLevel }
    var version: (any SQLDatabaseReportedVersion)? { core.version }
    func execute(query: DatabaseQuery,
        onOutput: @escaping @Sendable (any DatabaseOutput) -> Void) -> EventLoopFuture<Void> {
        core.execute(query: query, onOutput: onOutput)
    }
    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> { core.execute(schema: schema) }
    func execute(enum value: DatabaseEnum) -> EventLoopFuture<Void> { core.execute(enum: value) }
    func execute(sql query: any SQLExpression,
        _ onRow: @escaping @Sendable (any SQLRow) -> Void) -> EventLoopFuture<Void> {
        core.execute(sql: query, onRow)
    }
    func execute(sql query: any SQLExpression,
        _ onRow: @escaping @Sendable (any SQLRow) -> Void) async throws {
        try await core.execute(sql: query, onRow)
    }
    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        core.transaction(closure)
    }
    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        core.withConnection(closure)
    }
    func withSession<R>(_ closure: @escaping @Sendable (any SQLDatabase) async throws -> R) async throws -> R {
        try await core.withSession(closure)
    }
    func beginTransaction() -> EventLoopFuture<Void> { core.observe(phase: .transactionControl) { control.beginTransaction() } }
    func commitTransaction() -> EventLoopFuture<Void> { core.observe(phase: .transactionControl) { control.commitTransaction() } }
    func rollbackTransaction() -> EventLoopFuture<Void> { core.observe(phase: .transactionControl) { control.rollbackTransaction() } }
    func send(_ request: any PostgresRequest, logger: Logger) -> EventLoopFuture<Void> {
        core.observe { postgres.send(request, logger: logger) }
    }
    func withConnection<T>(_ closure: @escaping (PostgresConnection) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        postgres.withConnection(closure)
    }
}
