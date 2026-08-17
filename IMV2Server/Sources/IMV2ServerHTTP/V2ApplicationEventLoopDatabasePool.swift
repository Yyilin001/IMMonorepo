import Fluent
import IMV2Server
import NIOCore
import Vapor

public enum V2ApplicationEventLoopDatabasePoolError: Error, Equatable, Sendable {
    case emptyEventLoopSet
    case databaseNotRegistered
    case duplicateEventLoop
}

/// Materializes one Fluent database handle for every application EventLoop.
///
/// `Application.db(_:)` returns a handle bound to one EventLoop. Long-lived
/// repositories must not retain that single handle when the configured
/// connection budget is expressed per EventLoop. This factory makes the
/// topology explicit and returns a round-robin database whose transactional
/// operations remain pinned to one underlying handle.
public struct V2ApplicationEventLoopDatabasePool: Sendable {
    public let database: V2EventLoopBalancedDatabase
    public let eventLoopDatabases: [any Database]

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
