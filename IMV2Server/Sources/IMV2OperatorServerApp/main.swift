import IMV2ServerApplication
import IMV2ServerContracts
import FluentPostgresDriver
import Foundation
import FluentKit
import Logging
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import IMV2Server
import IMV2ServerInfrastructure
import IMV2ActorApplication
import IMV2ServerHTTP
import NIOPosix
import Vapor

/// 仅面向运维的独立进程。
///
/// 它刻意不提供公网 TLS 网关监听、账号认证因子路由、媒体边缘或指标端点。
@main
enum IMV2OperatorServerApp {
    static func main() async {
        do { try V2ServiceLogging.bootstrap() }
        catch {
            FileHandle.standardError.write(Data("Invalid IM_V2_LOG_LEVEL; expected a swift-log level.\n".utf8))
            exit(EXIT_FAILURE)
        }
        let logger = Logger(label: "imv2.operator")
        do {
            try await withLogger(logger) { scopedLogger in
                try await run(logger: scopedLogger)
            }
        } catch {
            logger.error("IM V2 operator startup or shutdown failed", metadata:
                V2SafeLogMetadata.failure(error, stage: "operator_lifecycle"))
            exit(EXIT_FAILURE)
        }
    }

    private static func run(logger: Logger) async throws {
        V2ProcessTerminationSignal.install()
        let configuration: V2OperatorReplayRuntimeConfiguration
        let policyConfiguration: V2RoomActorApplicationConfiguration?
        do {
            let environment = ProcessRuntimeEnvironment()
            configuration = try V2OperatorReplayRuntimeConfiguration(environment: environment)
            if environment.value(for: "IMV2_ROOM_ACTOR_CONFIGURATION_FILE") != nil {
                let actor = try V2RoomActorApplicationConfiguration(environment: environment, hostsRooms: false,
                    configuredShardIDs: Set(configuration.roomShardStorage.map(\.shardID)))
                policyConfiguration = actor.policyPlacement == nil ? nil : actor
            } else { policyConfiguration = nil }
        } catch {
            throw V2StagedOperationalError(stage: "operator_configuration", error: error)
        }
        let applicationEventLoops = MultiThreadedEventLoopGroup(
            numberOfThreads: configuration.databasePolicy.eventLoopThreads
        )
        let resources = V2DatabaseResources(eventLoopGroup: applicationEventLoops, logger: logger)
        let app: Application
        do {
            app = try await V2HTTPService.makeApplication(host: configuration.listener.host, port: configuration.listener.port)
        } catch {
            try? await resources.shutdown()
            try? await applicationEventLoops.shutdownGracefully()
            throw V2StagedOperationalError(stage: "operator_http_application", error: error)
        }
        V2RedactedHTTPMiddlewareConfiguration.install(on: app)
        var stage = "operator_composition"
        var policyCaller: V2RoomActorApplication?
        do {
            resources.databases.use(
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
            let controlPool = try V2EventLoopDatabasePool(
                databases: resources.databases, logger: logger,
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
            let deployment = PostgresV2PolicyDeploymentPlacementStore(database: database)
            if let placement = policyConfiguration?.policyPlacement {
                try await deployment.require(V2PolicyOwnerPlacement(placement))
            } else { try await deployment.requireLegacy() }
            // 解析操作不借用预留连接池或策略写入连接池。
            // 控制回执与归属方中止操作可共用此专用物理连接池：
            // 每笔事务结束后才开始下一笔。
            var authorizationResolutionDatabases: [String: any Database] = [:]
            for (index, url) in configuration.directAuthorizationResolutionDatabaseURLs.enumerated() {
                let id = DatabaseID(string: "operator-authorization-resolution-\(index)")
                resources.databases.use(try postgresDatabaseConfiguration(url: url, policy: configuration.databasePolicy,
                    maximumConnectionsPerEventLoop: 1), as: id)
                let pool = try V2EventLoopDatabasePool(databases: resources.databases, logger: logger, identifier: id, eventLoops: databaseEventLoops)
                for member in pool.eventLoopDatabases {
                    try await V2PostgresSessionReadiness.verify(database: member, policy: configuration.databasePolicy)
                }
                authorizationResolutionDatabases[url] = pool.database
            }
            guard let authorizationControlDatabase = authorizationResolutionDatabases[configuration.databaseURL] else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let authorizationOwners = try Dictionary(uniqueKeysWithValues: configuration.roomShardStorage.map { storage in
                guard let owner = authorizationResolutionDatabases[storage.databaseURL] else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                return (storage.shardID, owner)
            })
            let directAuthorizationCoordinator = V2DirectAuthorizationCoordinator(
                controlDatabase: authorizationControlDatabase, ownerDatabases: authorizationOwners)

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
                    resources.databases.use(
                        try postgresDatabaseConfiguration(
                            url: storage.databaseURL,
                            policy: configuration.databasePolicy
                        ),
                        as: identifier
                    )
                    let shardPool = try V2EventLoopDatabasePool(
                        databases: resources.databases, logger: logger,
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
            var userStateReplayStores: [String: any V2DurableWorkReplayStore] = [:]
            var forwardReplayStores: [String: any V2ForwardWorkReplayStore] = [:]
            var roomDatabases: [String: any Database] = [:]
            for storage in configuration.roomShardStorage {
                let ownerDatabase: any Database
                if let existing = shardDatabasesByURL[storage.databaseURL] {
                    ownerDatabase = existing
                } else {
                    let identifier = DatabaseID(string: "room-owner-pool-\(shardDatabasesByURL.count)")
                    resources.databases.use(try postgresDatabaseConfiguration(url: storage.databaseURL, policy: configuration.databasePolicy), as: identifier)
                    let pool = try V2EventLoopDatabasePool(databases: resources.databases, logger: logger, identifier: identifier, eventLoops: databaseEventLoops)
                    for member in pool.eventLoopDatabases {
                        try await V2PostgresSessionReadiness.verify(database: member, policy: configuration.databasePolicy)
                    }
                    ownerDatabase = pool.database
                    shardDatabasesByURL[storage.databaseURL] = ownerDatabase
                }
                try await V2SchemaReadiness.verify(database: ownerDatabase)
                userStateReplayStores[storage.shardID] = PostgresV2DurableWorkReplayStore(database: ownerDatabase)
                forwardReplayStores[storage.shardID] = PostgresV2ForwardWorkReplayStore(database: ownerDatabase)
                roomDatabases[storage.shardID] = ownerDatabase
            }
            // Queue replay remains local; policy changes use the authenticated
            // caller only when owner authorization is configured.
            if let policyConfiguration {
                stage = "operator_policy_caller"
                policyCaller = try await V2RoomActorApplication.start(configuration: policyConfiguration,
                    ownerRouter: V2PostgresRoomShardRouter(database: database), roomDatabases: roomDatabases)
            }
            let forwardReplay = try V2ForwardWorkOperatorReplayService(stores: forwardReplayStores,
                operatorPrincipal: configuration.operatorPrincipal)
            let coLocatedControlBuckets = Set(configuration.userShardStorage.compactMap { storage in
                storage.databaseURL == configuration.databaseURL && storage.schema == "im_v2" ? storage.bucket : nil
            })
            app.serverConfiguration.hostname = configuration.listener.host
            app.serverConfiguration.port = configuration.listener.port
            V2VaporDurableWorkOperatorReplayRoutes(
                authenticator: configuration.authenticator,
                service: .init(
                    store: PostgresV2DurableWorkReplayStore(database: database),
                    roomOwnerStores: userStateReplayStores,
                    operatorPrincipal: configuration.operatorPrincipal
                )
            ).register(on: app)
            V2VaporForwardWorkOperatorReplayRoutes(authenticator: configuration.authenticator, service: forwardReplay).register(on: app)
            var disableService = try V2PostgresAccountDisableService(database: database,
                operatorPrincipal: configuration.accountDisableOperatorPrincipal,
                authorizationCoordinator: directAuthorizationCoordinator)
            if let policyCaller {
                disableService = disableService.usingPolicyOwners(try await policyCaller.policyMutationExecutor())
            }
            V2VaporAccountDisableOperatorRoutes(authenticator: configuration.accountDisableAuthenticator,
                service: disableService).register(on: app)
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
            stage = "operator_http_runtime"
            try await V2HTTPService.withRunning(app, logger: logger,
                waitForShutdown: V2ProcessTerminationSignal.wait) { shutdown in
            logger.notice("IM V2 durable-work operator service bound", metadata: [
                "host": "\(configuration.listener.host)",
                "port": "\(configuration.listener.port)",
            ])
                await shutdown.wait()
            }
            stage = "operator_shutdown"
            try await app.shutdown()
            await stopPolicyCaller(policyCaller, logger: logger)
            policyCaller = nil
            try await resources.shutdown()
            try await applicationEventLoops.shutdownGracefully()
        } catch {
            if case V2RoomActorApplicationError.incompleteShutdown = error {
                logger.critical("IM V2 operator policy caller startup drain incomplete; retaining shared resources",
                    metadata: V2SafeLogMetadata.failure(error, stage: "operator_policy_startup_drain"))
                exit(EXIT_FAILURE)
            }
            try? await app.shutdown()
            await stopPolicyCaller(policyCaller, logger: logger)
            try? await resources.shutdown()
            try? await applicationEventLoops.shutdownGracefully()
            throw V2StagedOperationalError(stage: stage, error: error)
        }
    }

    private static func stopPolicyCaller(_ caller: V2RoomActorApplication?, logger: Logger) async {
        guard let caller else { return }
        do {
            guard try await caller.stop(deadline: .now + caller.configuration.drainTimeout.duration) else {
                logger.critical("IM V2 operator policy caller drain incomplete; retaining database resources",
                    metadata: V2SafeLogMetadata.drainTimeout(stage: "operator_policy_shutdown"))
                exit(EXIT_FAILURE)
            }
        } catch {
            logger.critical("IM V2 operator policy caller shutdown failed; retaining database resources",
                metadata: V2SafeLogMetadata.failure(error, stage: "operator_policy_shutdown"))
            exit(EXIT_FAILURE)
        }
    }
}

private func postgresDatabaseConfiguration(
    url: String,
    policy: V2PostgresRuntimePolicy,
    maximumConnectionsPerEventLoop: Int? = nil
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
        maxConnectionsPerEventLoop: maximumConnectionsPerEventLoop ?? policy.maximumConnectionsPerEventLoop,
        connectionPoolTimeout: .milliseconds(Int64(policy.poolTimeoutMilliseconds))
    )
}

private struct ProcessRuntimeEnvironment: V2RuntimeEnvironment {
    func value(for key: String) -> String? { ProcessInfo.processInfo.environment[key] }
}
