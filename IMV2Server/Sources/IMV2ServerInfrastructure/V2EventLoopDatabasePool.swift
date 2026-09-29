import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Logging
import NIOCore

/// 为每个 EventLoop 构造数据库句柄时可能出现的错误。
public enum V2EventLoopDatabasePoolError: Error, Equatable, Sendable {
    case emptyEventLoopSet
    case databaseNotRegistered
    case duplicateEventLoop
}

/// 为每个已配置的 EventLoop 持有一个 Fluent 数据库句柄。
///
/// 长期存活的存储通过 `database` 将独立操作分布到已配置的事件循环。
/// 事务和会话始终使用各自选定的句柄。
public struct V2EventLoopDatabasePool: Sendable {
    public let database: V2EventLoopBalancedDatabase
    public let eventLoopDatabases: [any Database]

    public init(
        databases: Databases,
        logger: Logger,
        identifier: DatabaseID,
        eventLoops: [any EventLoop]
    ) throws {
        guard !eventLoops.isEmpty else {
            throw V2EventLoopDatabasePoolError.emptyEventLoopSet
        }
        var eventLoopIdentities = Set<ObjectIdentifier>()
        for eventLoop in eventLoops {
            guard eventLoopIdentities.insert(ObjectIdentifier(eventLoop)).inserted else {
                throw V2EventLoopDatabasePoolError.duplicateEventLoop
            }
        }
        guard databases.configuration(for: identifier) != nil else {
            throw V2EventLoopDatabasePoolError.databaseNotRegistered
        }
        let handles: [any Database] = try eventLoops.map { eventLoop in
            guard let database = databases.database(identifier, logger: logger, on: eventLoop) else {
                throw V2EventLoopDatabasePoolError.databaseNotRegistered
            }
            return database
        }
        eventLoopDatabases = handles
        database = try V2EventLoopBalancedDatabase(databases: handles)
    }
}
