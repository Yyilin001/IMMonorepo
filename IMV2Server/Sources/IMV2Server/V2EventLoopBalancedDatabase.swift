import FluentKit
import Logging
import NIOCore
import SQLKit
import Synchronization

/// 事件循环均衡数据库错误。
public enum V2EventLoopBalancedDatabaseError: Error, Equatable, Sendable {
    /// 未提供任何数据库句柄。
    case emptyDatabaseSet
    /// 提供的句柄不支持 SQL。
    case databaseDoesNotSupportSQL
    /// 各句柄的配置类型不一致。
    case inconsistentConfiguration
    /// 各句柄的 SQL 方言类型不一致。
    case inconsistentDialect
}

/// 把相互独立的数据库操作分发到每个应用事件循环各一个 Fluent 数据库句柄上。
///
/// FluentKit 会把 `Databases.database(..., on:)` 返回的数据库绑定到指定的事件循环，
/// 因此长期存活的 Store 若只持有其中一个句柄，无论配置了多少事件循环，
/// 都只会用到 `EventLoopGroupConnectionPool` 中的一个成员。该适配器恢复预期的连接池拓扑，
/// 同时让事务与单会话工作严格固定在同一个底层句柄上。
///
/// 包装器对外报告的事件循环刻意保持稳定，以满足 `Database` 与 `SQLDatabase` 的要求。
/// 基于 `EventLoopFuture` 的旧接口结果会被回跳到该循环；异步调用方则可在所选操作完成后
/// 自由地在 Swift 并发执行器上恢复。
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
    /// 已配置的句柄数量。
    public var configuredEventLoopCount: Int { entries.count }

    /// 校验并保存各事件循环的数据库句柄。
    ///
    /// 要求所有句柄都支持 SQL、配置类型一致且方言类型一致，
    /// 以免在同一个包装器下混用语义不同的连接。
    ///
    /// - Parameter databases: 各事件循环对应的数据库句柄。
    /// - Throws: 列表为空时抛出 ``V2EventLoopBalancedDatabaseError/emptyDatabaseSet``；
    ///   句柄不支持 SQL 时抛出 ``V2EventLoopBalancedDatabaseError/databaseDoesNotSupportSQL``；
    ///   配置类型不一致时抛出 ``V2EventLoopBalancedDatabaseError/inconsistentConfiguration``；
    ///   方言不一致时抛出 ``V2EventLoopBalancedDatabaseError/inconsistentDialect``。
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

    /// 依次选取下一个句柄，实现轮转分发。
    ///
    /// - Returns: 本次使用的句柄。
    private func nextEntry() -> Entry {
        cursor.withLock { index in
            let entry = entries[index]
            index = index == entries.count - 1 ? 0 : index + 1
            return entry
        }
    }
}
