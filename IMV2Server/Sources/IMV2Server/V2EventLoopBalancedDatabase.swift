import Fluent
import NIOCore
import SQLKit
import Synchronization

public enum V2EventLoopBalancedDatabaseError: Error, Equatable, Sendable {
    case emptyDatabaseSet
    case databaseDoesNotSupportSQL
    case inconsistentConfiguration
    case inconsistentDialect
}

/// Dispatches independent database operations across one Fluent database
/// handle per application EventLoop.
///
/// Fluent binds a database returned by `Application.db(...)` to the EventLoop
/// selected when that handle is created. Keeping one such handle in a
/// long-lived Store therefore uses only one member of an
/// `EventLoopGroupConnectionPool`, regardless of the configured number of
/// EventLoops. This adapter restores the intended pool topology while keeping
/// transaction and single-session work pinned to exactly one underlying
/// handle.
///
/// The wrapper's reported EventLoop is deliberately stable, as required by
/// `Database` and `SQLDatabase`. Legacy EventLoopFuture results are hopped back
/// to that loop; async callers are free to resume on the Swift concurrency
/// executor after the selected database operation completes.
public final class V2EventLoopBalancedDatabase: Database, SQLDatabase, Sendable {
    private struct Entry: Sendable {
        let database: any Database
        let sql: any SQLDatabase
    }

    private let entries: [Entry]
    private let cursor = Mutex<Int>(0)

    public let context: DatabaseContext
    public let logger: Logger
    public let eventLoop: any EventLoop
    public let dialect: any SQLDialect
    public let queryLogLevel: Logger.Level?

    public var version: (any SQLDatabaseReportedVersion)? { nil }
    public var inTransaction: Bool { false }
    public var configuredEventLoopCount: Int { entries.count }

    public init(databases: [any Database]) throws {
        guard let firstDatabase = databases.first else {
            throw V2EventLoopBalancedDatabaseError.emptyDatabaseSet
        }
        let entries = try databases.map { database -> Entry in
            guard let sql = database as? any SQLDatabase else {
                throw V2EventLoopBalancedDatabaseError.databaseDoesNotSupportSQL
            }
            guard ObjectIdentifier(type(of: database.context.configuration)) ==
                    ObjectIdentifier(type(of: firstDatabase.context.configuration))
            else {
                throw V2EventLoopBalancedDatabaseError.inconsistentConfiguration
            }
            return .init(database: database, sql: sql)
        }
        guard let firstSQL = entries.first?.sql else {
            throw V2EventLoopBalancedDatabaseError.databaseDoesNotSupportSQL
        }
        let expectedDialect = String(reflecting: type(of: firstSQL.dialect))
        guard entries.allSatisfy({
            String(reflecting: type(of: $0.sql.dialect)) == expectedDialect
        }) else {
            throw V2EventLoopBalancedDatabaseError.inconsistentDialect
        }
        self.entries = entries
        context = firstDatabase.context
        logger = firstSQL.logger
        eventLoop = firstSQL.eventLoop
        dialect = firstSQL.dialect
        queryLogLevel = firstSQL.queryLogLevel
    }

    public func execute(
        query: DatabaseQuery,
        onOutput: @escaping @Sendable (any DatabaseOutput) -> Void
    ) -> EventLoopFuture<Void> {
        nextEntry().database.execute(query: query, onOutput: onOutput)
            .hop(to: eventLoop)
    }

    public func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> {
        nextEntry().database.execute(schema: schema).hop(to: eventLoop)
    }

    public func execute(enum databaseEnum: DatabaseEnum) -> EventLoopFuture<Void> {
        nextEntry().database.execute(enum: databaseEnum).hop(to: eventLoop)
    }

    public func transaction<T>(
        _ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>
    ) -> EventLoopFuture<T> {
        // Fluent's legacy witness does not require `T: Sendable`; returning
        // the selected handle's future preserves that API without asserting an
        // invalid cross-EventLoop Sendable guarantee for an arbitrary `T`.
        nextEntry().database.transaction(closure)
    }

    public func withConnection<T>(
        _ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>
    ) -> EventLoopFuture<T> {
        nextEntry().database.withConnection(closure)
    }

    public func execute(
        sql query: any SQLExpression,
        _ onRow: @escaping @Sendable (any SQLRow) -> Void
    ) -> EventLoopFuture<Void> {
        nextEntry().sql.execute(sql: query, onRow).hop(to: eventLoop)
    }

    public func execute(
        sql query: any SQLExpression,
        _ onRow: @escaping @Sendable (any SQLRow) -> Void
    ) async throws {
        try await nextEntry().sql.execute(sql: query, onRow)
    }

    public func withSession<R>(
        _ closure: @escaping @Sendable (any SQLDatabase) async throws -> R
    ) async throws -> R {
        try await nextEntry().sql.withSession(closure)
    }

    private func nextEntry() -> Entry {
        cursor.withLock { index in
            let entry = entries[index]
            index = index == entries.count - 1 ? 0 : index + 1
            return entry
        }
    }
}
