import FluentKit
import Logging
import NIOCore

/// Errors constructing one database handle per EventLoop.
public enum V2EventLoopDatabasePoolError: Error, Equatable, Sendable {
    case emptyEventLoopSet
    case databaseNotRegistered
    case duplicateEventLoop
}

/// Retains a Fluent database handle for each configured EventLoop.
///
/// Long-lived stores use `database` to distribute independent operations over
/// the configured loops. Transactions and sessions stay on their selected handle.
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
