import Dispatch
import FluentPostgresDriver
import Foundation
import IMV2Server
import IMV2ServerHTTP
import NIOPosix
import Vapor
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A deliberately separate operator-only process. It has no public TLS
/// gateway listener, account-factor route, media edge or metrics endpoint.
@main
enum IMV2OperatorServerApp {
    static func main() async throws {
        let configuration = try V2OperatorReplayRuntimeConfiguration(environment: ProcessRuntimeEnvironment())
        let applicationEventLoops = MultiThreadedEventLoopGroup(
            numberOfThreads: configuration.databasePolicy.eventLoopThreads
        )
        let app: Application
        do {
            app = try await Application.make(.production, .shared(applicationEventLoops))
        } catch {
            try? await applicationEventLoops.shutdownGracefully()
            throw error
        }
        V2RedactedHTTPMiddlewareConfiguration.install(on: app)
        do {
            app.databases.use(
                try postgresDatabaseConfiguration(
                    url: configuration.databaseURL,
                    policy: configuration.databasePolicy
                ),
                as: .psql
            )
            let databaseEventLoops = Array(applicationEventLoops.makeIterator())
            guard databaseEventLoops.count == configuration.databasePolicy.eventLoopThreads else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let controlPool = try V2ApplicationEventLoopDatabasePool(
                application: app,
                identifier: .psql,
                eventLoops: databaseEventLoops
            )
            for eventLoopDatabase in controlPool.eventLoopDatabases {
                try await V2PostgresSessionReadiness.verify(
                    database: eventLoopDatabase,
                    policy: configuration.databasePolicy
                )
            }
            let database: any Database = controlPool.database
            try await V2SchemaReadiness.verify(database: database)
            var shardDatabasesByURL: [String: any Database] = [
                configuration.databaseURL: database
            ]
            var shardLocations: [V2UserShardStorageLocation] = []
            for storage in configuration.userShardStorage {
                let shardDatabase: any Database
                if let existing = shardDatabasesByURL[storage.databaseURL] {
                    shardDatabase = existing
                } else {
                    let identifier = DatabaseID(string: "user-shard-pool-\(shardDatabasesByURL.count)")
                    app.databases.use(
                        try postgresDatabaseConfiguration(
                            url: storage.databaseURL,
                            policy: configuration.databasePolicy
                        ),
                        as: identifier
                    )
                    let shardPool = try V2ApplicationEventLoopDatabasePool(
                        application: app,
                        identifier: identifier,
                        eventLoops: databaseEventLoops
                    )
                    for eventLoopDatabase in shardPool.eventLoopDatabases {
                        try await V2PostgresSessionReadiness.verify(
                            database: eventLoopDatabase,
                            policy: configuration.databasePolicy
                        )
                    }
                    shardDatabase = shardPool.database
                    shardDatabasesByURL[storage.databaseURL] = shardDatabase
                }
                try await V2SchemaReadiness.verify(database: shardDatabase, schema: storage.schema)
                shardLocations.append(try .init(bucket: storage.bucket, database: shardDatabase, schema: storage.schema))
            }
            let userShardStorage = try V2StaticUserShardStorageRegistry(locations: shardLocations)
            let coLocatedControlBuckets = Set(configuration.userShardStorage.compactMap { storage in
                storage.databaseURL == configuration.databaseURL && storage.schema == "im_v2" ? storage.bucket : nil
            })
            let userShardMigrationStore = PostgresV2UserShardMigrationStore(database: database)
            let userShardMigrationExecutor = V2UserShardProjectionMigrationExecutor(
                store: userShardMigrationStore,
                registry: userShardStorage,
                coLocatedControlBuckets: coLocatedControlBuckets
            )
            app.http.server.configuration.hostname = configuration.listener.host
            app.http.server.configuration.port = configuration.listener.port
            V2VaporDurableWorkOperatorReplayRoutes(
                authenticator: configuration.authenticator,
                service: .init(
                    store: PostgresV2DurableWorkReplayStore(database: database),
                    operatorPrincipal: configuration.operatorPrincipal
                )
            ).register(on: app)
            V2VaporUserShardRouteOperatorRoutes(
                authenticator: configuration.authenticator,
                control: V2PostgresUserShardRouteControl(
                    database: database,
                    operatorPrincipal: configuration.operatorPrincipal,
                    finalizer: userShardMigrationExecutor
                )
            ).register(on: app)
            V2VaporUserShardMigrationOperatorRoutes(
                authenticator: configuration.authenticator,
                service: V2UserShardMigrationOperatorService(
                    store: userShardMigrationStore,
                    executor: userShardMigrationExecutor
                )
            ).register(on: app)
            V2VaporAccountDisableOperatorRoutes(
                authenticator: configuration.accountDisableAuthenticator,
                service: try V2PostgresAccountDisableService(
                    database: database,
                    operatorPrincipal: configuration.accountDisableOperatorPrincipal
                )
            ).register(on: app)
            V2VaporDeviceSnapshotResetOperatorRoutes(
                authenticator: configuration.authenticator,
                service: try V2PostgresDeviceSnapshotResetService(
                    registry: userShardStorage,
                    deviceAvailability: V2PostgresDeviceAvailabilityChecker(
                        database: database
                    ),
                    routeFence: V2PostgresUserShardRouter(database: database),
                    coLocatedControlBuckets: coLocatedControlBuckets,
                    capabilityProfile: configuration.capabilityProfile
                )
            ).register(on: app)
            try await app.startup()
            app.logger.notice("IM V2 durable-work operator service bound", metadata: [
                "host": "\(configuration.listener.host)",
                "port": "\(configuration.listener.port)",
            ])
            await TerminationSignal.wait()
            try await app.asyncShutdown()
            try await applicationEventLoops.shutdownGracefully()
        } catch {
            try? await app.asyncShutdown()
            try? await applicationEventLoops.shutdownGracefully()
            throw error
        }
    }
}

private func postgresDatabaseConfiguration(
    url: String,
    policy: V2PostgresRuntimePolicy
) throws -> DatabaseConfigurationFactory {
    var configuration = try SQLPostgresConfiguration(url: url)
    configuration.coreConfiguration.options.connectTimeout = .milliseconds(
        Int64(policy.connectTimeoutMilliseconds)
    )
    configuration.coreConfiguration.options.additionalStartupParameters.append(
        contentsOf: policy.startupParameters
    )
    return .postgres(
        configuration: configuration,
        maxConnectionsPerEventLoop: policy.maximumConnectionsPerEventLoop,
        connectionPoolTimeout: .milliseconds(Int64(policy.poolTimeoutMilliseconds))
    )
}

private struct ProcessRuntimeEnvironment: V2RuntimeEnvironment {
    func value(for key: String) -> String? { ProcessInfo.processInfo.environment[key] }
}

private enum TerminationSignal {
    static func wait() async {
        await withCheckedContinuation { continuation in
            signal(SIGTERM, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            source.setEventHandler {
                source.cancel()
                continuation.resume()
            }
            source.resume()
        }
    }
}
