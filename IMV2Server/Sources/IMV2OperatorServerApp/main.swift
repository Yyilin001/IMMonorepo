import Dispatch
import FluentPostgresDriver
import Foundation
import IMV2Server
import IMV2ServerHTTP
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
        let app = try await Application.make(.production)
        do {
            app.databases.use(try .postgres(url: configuration.databaseURL), as: .psql)
            let database = app.db(.psql)
            try await V2SchemaReadiness.verify(database: database)
            var shardLocations: [V2UserShardStorageLocation] = []
            for storage in configuration.userShardStorage {
                let shardDatabase: any Database
                if storage.databaseURL == configuration.databaseURL {
                    shardDatabase = database
                } else {
                    let identifier = DatabaseID(string: "user-shard-\(storage.bucket)")
                    app.databases.use(try .postgres(url: storage.databaseURL), as: identifier)
                    shardDatabase = app.db(identifier)
                }
                try await V2SchemaReadiness.verify(database: shardDatabase, schema: storage.schema)
                shardLocations.append(try .init(bucket: storage.bucket, database: shardDatabase, schema: storage.schema))
            }
            let userShardStorage = try V2StaticUserShardStorageRegistry(locations: shardLocations)
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
                    operatorPrincipal: configuration.operatorPrincipal
                )
            ).register(on: app)
            V2VaporUserShardMigrationOperatorRoutes(
                authenticator: configuration.authenticator,
                service: V2UserShardMigrationOperatorService(
                    store: PostgresV2UserShardMigrationStore(database: database),
                    executor: V2UserShardProjectionMigrationExecutor(
                        store: PostgresV2UserShardMigrationStore(database: database),
                        registry: userShardStorage
                    )
                )
            ).register(on: app)
            V2VaporAccountDisableOperatorRoutes(
                authenticator: configuration.accountDisableAuthenticator,
                service: try V2PostgresAccountDisableService(
                    database: database,
                    operatorPrincipal: configuration.accountDisableOperatorPrincipal
                )
            ).register(on: app)
            try await app.startup()
            app.logger.notice("IM V2 durable-work operator service bound", metadata: [
                "host": "\(configuration.listener.host)",
                "port": "\(configuration.listener.port)",
            ])
            await TerminationSignal.wait()
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }
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
