import AsyncHTTPClient
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
enum IMV2AdminServerApp {
    static func main() async {
        if CommandLine.arguments.dropFirst() == ["--local-demo"] {
            do { try await V2AdminLocalDemo.run() }
            catch {
                FileHandle.standardError.write(Data("Local admin demo failed; check isolated database and configuration.\n".utf8))
                exit(EXIT_FAILURE)
            }
            return
        }

        if CommandLine.arguments.dropFirst() == ["--hash-password"] {
            let worker = V2PasswordHashWorker()
            do {
                guard let password = readLine(strippingNewline: true) else { throw V2AdminError.invalidInput }
                let digest = try await worker.hash(password)
                try await worker.shutdown()
                print(digest)
                return
            } catch {
                try? await worker.shutdown()
                FileHandle.standardError.write(Data("Password must contain 12–1024 UTF-8 bytes and no NUL.\n".utf8))
                exit(EXIT_FAILURE)
            }
        }

        do { try V2ServiceLogging.bootstrap() }
        catch {
            FileHandle.standardError.write(Data("Invalid IM_V2_LOG_LEVEL; expected a swift-log level.\n".utf8))
            exit(EXIT_FAILURE)
        }
        let logger = Logger(label: "imv2.admin")
        do {
            try await withLogger(logger) { scopedLogger in
                try await run(logger: scopedLogger)
            }
        } catch {
            logger.error("IM V2 admin startup or shutdown failed", metadata:
                V2SafeLogMetadata.failure(error, stage: "admin_lifecycle"))
            exit(EXIT_FAILURE)
        }
    }

    private static func run(logger: Logger) async throws {
        V2ProcessTerminationSignal.install()
        let configuration: V2AdminRuntimeConfiguration
        let policyConfiguration: V2RoomActorApplicationConfiguration
        do {
            let environment = ProcessRuntimeEnvironment()
            configuration = try V2AdminRuntimeConfiguration(environment: environment)
            policyConfiguration = try V2RoomActorApplicationConfiguration(environment: environment, hostsRooms: false,
                configuredShardIDs: Set(configuration.roomShardStorage.map(\.shardID)))
            guard policyConfiguration.policyPlacement != nil else {
                throw V2RoomActorApplicationConfigurationError.invalidConfiguration
            }
        } catch {
            throw V2StagedOperationalError(stage: "admin_configuration", error: error)
        }
        let applicationEventLoops = MultiThreadedEventLoopGroup(
            numberOfThreads: configuration.databasePolicy.eventLoopThreads
        )
        let passwords = V2PasswordHashWorker()
        let resources = V2DatabaseResources(eventLoopGroup: applicationEventLoops, logger: logger)
        let app: Application
        do {
            app = try await V2HTTPService.makeApplication(host: "127.0.0.1", port: configuration.port)
        } catch {
            try? await passwords.shutdown()
            try? await resources.shutdown()
            try? await applicationEventLoops.shutdownGracefully()
            throw V2StagedOperationalError(stage: "admin_http_application", error: error)
        }
        V2RedactedHTTPMiddlewareConfiguration.install(on: app)
        let http = HTTPClient(eventLoopGroupProvider: .shared(applicationEventLoops),
            configuration: .init(redirectConfiguration: .disallow))
        var stage = "admin_composition"
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
            guard let placement = policyConfiguration.policyPlacement else {
                throw V2RoomActorApplicationConfigurationError.invalidConfiguration
            }
            try await deployment.verifyExisting(V2PolicyOwnerPlacement(placement))
            var shardDatabasesByURL: [String: any Database] = [
                configuration.databaseURL: database
            ]
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
                roomDatabases[storage.shardID] = ownerDatabase
            }
            try await V2FixedShardSources.verify(control: database, rooms: configuration.roomShardStorage,
                users: nil) { shardDatabasesByURL[$0] }
            // 独立管理身份只调用受权 Policy Owner，保持原有禁用事务边界。
            stage = "admin_policy_caller"
            let caller = try await V2RoomActorApplication.start(configuration: policyConfiguration,
                ownerRouter: V2PostgresRoomShardRouter(database: database), roomDatabases: roomDatabases)
            policyCaller = caller
            let store = PostgresV2AdminStore(database: database)
            try await store.verifySchema()
            let accountData = try Data(contentsOf: URL(fileURLWithPath: configuration.accountsFile))
            guard accountData.count <= 65_536 else { throw V2AdminError.invalidInput }
            let accounts = try JSONDecoder().decode([V2AdminAccount].self, from: accountData)
            let policyOwners = try await caller.policyMutationExecutor()
            let service = try V2AdminService(accounts: accounts, store: store, passwords: passwords) { principal, command in
                try await V2PostgresAccountDisableService(operatorPrincipal: principal, policyOwners: policyOwners).disable(command)
            }
            let databaseMonitor = PostgresV2AdminMonitoring(database: database)
            let monitoring = try V2AdminMonitoringService(local: false, database: { try await databaseMonitor.observe() },
                remote: AdminRemoteProbes.make(configuration: configuration, caller: caller, http: http, group: applicationEventLoops))
            try V2AdminRoutes(service: service, origin: configuration.origin, monitoring: monitoring).register(on: app)
            stage = "admin_http_runtime"
            try await V2HTTPService.withRunning(app, logger: logger,
                waitForShutdown: V2ProcessTerminationSignal.wait) { shutdown in
            logger.notice("IM V2 admin service bound", metadata: [
                "host": "127.0.0.1",
                "port": "\(configuration.port)",
            ])
                await shutdown.wait()
            }
            stage = "admin_shutdown"
            try await http.shutdown()
            try await app.shutdown()
            await stopPolicyCaller(policyCaller, logger: logger)
            policyCaller = nil
            try await passwords.shutdown()
            try await resources.shutdown()
            try await applicationEventLoops.shutdownGracefully()
        } catch {
            if case V2RoomActorApplicationError.incompleteShutdown = error {
                logger.critical("IM V2 admin policy caller startup drain incomplete; retaining shared resources",
                    metadata: V2SafeLogMetadata.failure(error, stage: "admin_policy_startup_drain"))
                exit(EXIT_FAILURE)
            }
            try? await http.shutdown()
            try? await app.shutdown()
            await stopPolicyCaller(policyCaller, logger: logger)
            try? await passwords.shutdown()
            try? await resources.shutdown()
            try? await applicationEventLoops.shutdownGracefully()
            throw V2StagedOperationalError(stage: stage, error: error)
        }
    }

    private static func stopPolicyCaller(_ caller: V2RoomActorApplication?, logger: Logger) async {
        guard let caller else { return }
        do {
            guard try await caller.stop(deadline: .now + caller.configuration.drainTimeout.duration) else {
                logger.critical("IM V2 admin policy caller drain incomplete; retaining database resources",
                    metadata: V2SafeLogMetadata.drainTimeout(stage: "admin_policy_shutdown"))
                exit(EXIT_FAILURE)
            }
        } catch {
            logger.critical("IM V2 admin policy caller shutdown failed; retaining database resources",
                metadata: V2SafeLogMetadata.failure(error, stage: "admin_policy_shutdown"))
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
