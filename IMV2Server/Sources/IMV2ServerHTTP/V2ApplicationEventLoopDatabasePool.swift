import Fluent
import IMV2Server
import NIOCore
import Vapor

/// `V2ApplicationEventLoopDatabasePool` 的初始化错误。
public enum V2ApplicationEventLoopDatabasePoolError: Error, Equatable, Sendable {
    case emptyEventLoopSet
    case databaseNotRegistered
    case duplicateEventLoop
}

/// 为每个 EventLoop 预先构造一个 Fluent 数据库句柄。
///
/// `Application.db(_:)` 会按 EventLoop 绑定数据库连接。
/// 长生命周期仓储不应持有单个连接句柄，否则在按 EventLoop
/// 分配连接预算时可能出现路由错配。
/// 本类型显式建立事件循环到数据库句柄的映射，并返回均衡封装。
public struct V2ApplicationEventLoopDatabasePool: Sendable {
    public let database: V2EventLoopBalancedDatabase
    public let eventLoopDatabases: [any Database]

    /// 初始化。
    ///
    /// - Parameters:
    ///   - application: Vapor 应用。
    ///   - identifier: 数据库配置 ID。
    ///   - eventLoops: 事件循环集合。
    /// - Throws: 空集合、重复 EventLoop、数据库未注册等错误。
    public init(
        application: Application,
        identifier: DatabaseID,
        eventLoops: [any EventLoop]
    ) throws {
        guard !eventLoops.isEmpty else {
            throw V2ApplicationEventLoopDatabasePoolError.emptyEventLoopSet
        }
        var eventLoopIdentities = Set<ObjectIdentifier>()
        for eventLoop in eventLoops {
            guard eventLoopIdentities.insert(ObjectIdentifier(eventLoop)).inserted else {
                throw V2ApplicationEventLoopDatabasePoolError.duplicateEventLoop
            }
        }
        let databases: [any Database] = try eventLoops.map { eventLoop in
            guard let database = application.databases.database(
                identifier,
                logger: application.logger,
                on: eventLoop
            ) else {
                throw V2ApplicationEventLoopDatabasePoolError.databaseNotRegistered
            }
            return database
        }
        eventLoopDatabases = databases
        database = try V2EventLoopBalancedDatabase(databases: databases)
    }
}
