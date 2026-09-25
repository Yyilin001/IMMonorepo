import FluentPostgresDriver
import Foundation
import FluentKit
import Logging
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import IMV2Core
import IMV2ActorApplication
import IMV2Server
import IMV2ServerHTTP
import NIOPosix
import Vapor

@main
enum IMV2AccountServerApp {
    static func main() async {
        do { try V2ServiceLogging.bootstrap() }
        catch {
            fputs("Invalid IM_V2_LOG_LEVEL; expected a swift-log level.\n", stderr)
            exit(EXIT_FAILURE)
        }
        let logger = Logger(label: "imv2.account")
        do {
            try await withLogger(logger) { _ in try await run(logger: logger) }
        } catch {
            logger.error("IM V2 account startup or shutdown failed", metadata:
                V2SafeLogMetadata.failure(error, stage: "account_lifecycle"))
            exit(EXIT_FAILURE)
        }
    }

    private static func run(logger: Logger) async throws {
        V2ProcessTerminationSignal.install()
        let configuration: V2AccountRuntimeConfiguration
        let localMediaConfiguration: V2LocalFilesystemMediaRuntimeConfiguration?
        do {
            configuration = try V2AccountRuntimeConfiguration(environment: ProcessRuntimeEnvironment())
            localMediaConfiguration = try V2LocalFilesystemMediaRuntimeConfiguration(environment: ProcessRuntimeEnvironment())
        } catch {
            throw V2StagedOperationalError(stage: "account_configuration", error: error)
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
            throw V2StagedOperationalError(stage: "account_http_application", error: error)
        }
        V2RedactedHTTPMiddlewareConfiguration.install(on: app)
        let runtimeTasks = RuntimeTaskSupervisor()
        let passwordWorker = V2PasswordHashWorker()
        var roomActor: V2RoomActorApplication?
        var stage = "account_composition"
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
            let databasePool = try V2EventLoopDatabasePool(
                databases: resources.databases, logger: logger,
                identifier: .psql,
                eventLoops: databaseEventLoops
            )
            for eventLoopDatabase in databasePool.eventLoopDatabases {
                try await V2PostgresSessionReadiness.verify(
                    database: eventLoopDatabase,
                    policy: configuration.databasePolicy
                )
            }
            let database: any Database = databasePool.database
            try await V2SchemaReadiness.verify(database: database)
            try await V2CapacityProfileReadiness.verify(database: database, profile: configuration.capacityProfile)
            app.serverConfiguration.hostname = configuration.listener.host
            app.serverConfiguration.port = configuration.listener.port
            app.middleware.use(V2AccountEdgeAuthenticationMiddleware(secret: configuration.edgeAuthorizationSecret))
            let edgeClientRateLimiter = V2PostgresAccountEdgeClientRateLimiter(
                database: database,
                policy: configuration.edgeClientRateLimit,
                key: configuration.edgeClientRateLimitKey
            )
            app.middleware.use(V2AccountEdgeClientRateLimitMiddleware(
                limiter: edgeClientRateLimiter,
                limitedPaths: [
                    "/v2/account-auth/password/register",
                    "/v2/account-auth/password/assertion",
                    "/v2/account-auth/password/change",
                    "/v2/account-auth/password/recovery-code",
                    "/v2/account-auth/password/recover",
                    "/v2/device-credentials",
                    "/v2/device-credentials/refresh",
                    V2VaporDeviceRevocationCapabilityRoutes.path,
                    V2VaporDeviceRegistrationCancellationRoutes.path,
                ]
            ))

            let assertionIssuer = try V2HMACAccountAssertionIssuer(rawKey: configuration.accountAssertionKey)
            let credentials = try V2PostgresDeviceCredentialService(
                database: database,
                tokenHMACKey: configuration.accessTokenKey,
                replayEnvelopeKey: configuration.replayEnvelopeKey,
                registrationPolicy: configuration.deviceRegistrationPolicy
            )
            let authenticator = V2PostgresGatewayAuthenticator(
                database: database,
                tokenKey: configuration.accessTokenKey
            )
            let authenticatedAccountRoutes = app
                .grouped(V2AuthenticatedAccountMiddleware(authenticator: authenticator))
                .grouped(V2AuthenticatedAccountRateLimitMiddleware(limiter: edgeClientRateLimiter))
            await runtimeTasks.start {
                while !Task.isCancelled {
                    do {
                        _ = try await edgeClientRateLimiter.purgeExpired(limit: 1_000)
                    } catch is CancellationError {
                        break
                    } catch {
                        V2ServiceLogging.logWorkerFailure(logger, worker: "account_edge_rate_limit_retention", error: error)
                    }
                    do {
                        try await v2Sleep(for: .seconds(60))
                    } catch {
                        break
                    }
                }
            }
            // 每个物理归属方保留一个连接池，用于租约解析和限定范围的媒体授权；
            // 房间命令始终通过 RoomRef 执行。
            var accountStorageDatabases: [String: any Database] = [configuration.databaseURL: database]
            for url in Set(configuration.roomShardStorage.map(\.databaseURL)) where accountStorageDatabases[url] == nil {
                let identifier = DatabaseID(string: "account-owner-\(accountStorageDatabases.count)")
                resources.databases.use(try postgresDatabaseConfiguration(url: url, policy: configuration.databasePolicy), as: identifier)
                let pool = try V2EventLoopDatabasePool(databases: resources.databases, logger: logger, identifier: identifier, eventLoops: databaseEventLoops)
                for member in pool.eventLoopDatabases {
                    try await V2PostgresSessionReadiness.verify(database: member, policy: configuration.databasePolicy)
                }
                try await V2SchemaReadiness.verify(database: pool.database)
                try await V2CapacityProfileReadiness.verify(database: pool.database, profile: configuration.capacityProfile)
                accountStorageDatabases[url] = pool.database
            }
            var roomDatabases: [String: any Database] = [:]
            for storage in configuration.roomShardStorage {
                guard let owner = accountStorageDatabases[storage.databaseURL] else { throw V2RoomWriteStoreError.corruptPersistenceState }
                roomDatabases[storage.shardID] = owner
            }
            let roomRouter = V2PostgresRoomShardRouter(database: database)
            let actorConfiguration = try V2RoomActorApplicationConfiguration(
                environment: ProcessRuntimeEnvironment(), hostsRooms: false,
                configuredShardIDs: Set(roomDatabases.keys))
            let actor = try await V2RoomActorApplication.start(
                configuration: actorConfiguration, ownerRouter: roomRouter,
                roomDatabases: roomDatabases)
            roomActor = actor
            if let localMediaConfiguration {
                let provider = try V2LocalFilesystemMediaProvider(
                    rootDirectory: localMediaConfiguration.rootDirectory,
                    targetBaseURL: localMediaConfiguration.publicBaseURL,
                    signingKey: localMediaConfiguration.signingKey
                )
                try await provider.prepare()
                let media = V2MediaService(
                    store: PostgresV2MediaStore(database: database),
                    limits: try V2MediaUploadLimits(maximumBytes: localMediaConfiguration.maximumBytes)
                )
                let uploadProviderSessions = try V2MediaUploadProviderSessionService(
                    store: PostgresV2MediaUploadSessionStore(database: database),
                    provider: provider
                )
                let downloadProviderSessions = try V2MediaProviderSessionService(
                    store: PostgresV2MediaDownloadSessionStore(database: database),
                    provider: provider
                )
                let mediaEventLoops = Array(applicationEventLoops.makeIterator())
                for url in Set(configuration.roomShardStorage.map(\.databaseURL) + configuration.userShardStorage.map(\.databaseURL)) where accountStorageDatabases[url] == nil {
                    let identifier = DatabaseID(string: "media-store-\(accountStorageDatabases.count)")
                    resources.databases.use(try postgresDatabaseConfiguration(url: url, policy: configuration.databasePolicy), as: identifier)
                    let pool = try V2EventLoopDatabasePool(databases: resources.databases, logger: logger, identifier: identifier, eventLoops: mediaEventLoops)
                    for member in pool.eventLoopDatabases {
                        try await V2PostgresSessionReadiness.verify(database: member, policy: configuration.databasePolicy)
                    }
                    accountStorageDatabases[url] = pool.database
                }
                var mediaOwners: [String: V2MessageMediaOwner] = [:]
                for storage in configuration.roomShardStorage {
                    guard let owner = accountStorageDatabases[storage.databaseURL] else { throw V2RoomWriteStoreError.corruptPersistenceState }
                    try await V2SchemaReadiness.verify(database: owner)
                    mediaOwners[storage.shardID] = .init(database: owner, provider: provider)
                }
                let mediaDownloads = V2RoomRefMediaDownloadClient(
                    local: .init(media: media, providerSessions: downloadProviderSessions),
                    rooms: roomRouter, owners: mediaOwners, controlDatabase: database,
                    authorization: .init(directory: actor.directory)
                )
                V2VaporMediaUploadRoutes(
                    authenticator: authenticator,
                    handler: .init(edge: .init(media: media, providerSessions: uploadProviderSessions))
                ).register(on: authenticatedAccountRoutes)
                V2VaporMediaEdgeRoutes(
                    authenticator: authenticator,
                    handler: .init(resolver: mediaDownloads)
                ).register(on: authenticatedAccountRoutes)
                try V2VaporLocalFilesystemMediaRoutes(
                    provider: provider,
                    fileIO: app.fileio,
                    publicBaseURL: localMediaConfiguration.publicBaseURL,
                    maximumUploadBytes: localMediaConfiguration.maximumBytes
                ).register(on: app)

                let scanner = try V2MediaScanWorker(
                    store: PostgresV2MediaScanStore(database: database),
                    provider: V2LocalEICARMediaScanner(provider: provider)
                )
                let purger = try V2MediaPurgeWorker(
                    store: PostgresV2MediaPurgeStore(database: database),
                    provider: provider
                )
                await runtimeTasks.start {
                    while !Task.isCancelled {
                        do {
                            async let scanReport = scanner.runOnce(limit: 16)
                            async let purgeReport = purger.runOnce(limit: 16)
                            _ = try await (scanReport, purgeReport)
                        } catch is CancellationError {
                            break
                        } catch {
                            // 此本地扫描器仅用于诊断；这里不得记录标识符、路径或字节内容。
                            V2ServiceLogging.logWorkerFailure(logger, worker: "local_media_maintenance_worker", error: error)
                        }
                        do {
                            try await v2Sleep(for: .milliseconds(200))
                        } catch is CancellationError {
                            break
                        } catch {
                            break
                        }
                    }
                }
                logger.notice("IM V2 local filesystem media edge enabled")
            }
            V2VaporDeviceCredentialRoutes(assertionVerifier: assertionIssuer, issuer: credentials).register(on: app)
            V2VaporDeviceRevocationCapabilityRoutes(
                service: V2PostgresDeviceSessionService(database: database)
            ).register(on: app)
            V2VaporDeviceRegistrationCancellationRoutes(
                service: V2PostgresDeviceRegistrationCancellationService(database: database)
            ).register(on: app)
            let pushEndpoints = PostgresV2PushDeviceEndpointStore(database: database, envelopeKey: configuration.pushEndpointEnvelopeKey)
            V2VaporPushEndpointRoutes(authenticator: authenticator, store: pushEndpoints).register(on: authenticatedAccountRoutes)
            V2VaporPushIntentRoutes(authenticator: authenticator, store: pushEndpoints).register(on: authenticatedAccountRoutes)
            V2VaporDeviceSessionRoutes(
                authenticator: authenticator,
                sessions: V2PostgresDeviceSessionService(database: database)
            ).register(on: authenticatedAccountRoutes)
            V2VaporPublicIdentityRoutes(
                authenticator: authenticator,
                directory: V2PostgresPublicIdentityDirectory(
                    database: database,
                    policy: configuration.publicIdentityLookupRateLimit
                )
            ).register(on: authenticatedAccountRoutes)
            V2VaporProfileViewRoutes(
                authenticator: authenticator,
                profiles: .init(store: PostgresV2ProfileViewStore(database: database))
            ).register(on: authenticatedAccountRoutes)
            let profileUpdateStore = PostgresV2ProfileUpdateStore(database: database)
            V2VaporProfileUpdateRoutes(
                authenticator: authenticator,
                profiles: .init(store: profileUpdateStore, reader: profileUpdateStore)
            ).register(on: authenticatedAccountRoutes)
            V2VaporProfilePresentationRoutes(
                authenticator: authenticator,
                presentations: V2RoomRefProfilePresentationClient(
                    aliases: PostgresV2ProfilePresentationStore(database: database),
                    directory: actor.directory
                )
            ).register(on: authenticatedAccountRoutes)
            let invitationCoordinator = V2ActorInvitationCoordinator(
                controlDatabase: database,
                room: .init(directory: actor.directory),
                secretIssuer: try .init(rawKey: configuration.groupInviteTokenHMACKey))
            let inviteRecovery = V2GroupInviteCreationRecoveryWorker(
                jobs: PostgresV2GroupInviteDirectory(database: database),
                coordinator: invitationCoordinator,
                deadline: { .now + .seconds(10) })
            await runtimeTasks.start {
                while !Task.isCancelled {
                    do {
                        let report = try await inviteRecovery.runOnce(limit: 8)
                        if report.paused > 0 {
                            logger.error("IM V2 invite creation recovery paused; inspect control recovery reasons", metadata: ["paused": "\(report.paused)"])
                        } else if report.deferred > 0 {
                            logger.warning("IM V2 invite creation recovery deferred", metadata: ["deferred": "\(report.deferred)"])
                        }
                    } catch is CancellationError { break }
                    catch { V2ServiceLogging.logWorkerFailure(logger, worker: "invite_creation_recovery", error: error) }
                    do { try await v2Sleep(for: .seconds(5)) } catch { break }
                }
            }
            let joinQuotaRecovery = V2GroupJoinQuotaRecoveryWorker(
                controlDatabase: database, coordinator: invitationCoordinator,
                deadline: { .now + .seconds(10) })
            await runtimeTasks.start {
                while !Task.isCancelled {
                    do {
                        let report = try await joinQuotaRecovery.runOnce(limit: 8)
                        if report.deferred > 0 {
                            logger.warning("IM V2 join quota recovery deferred", metadata: ["deferred": "\(report.deferred)"])
                        }
                    } catch is CancellationError { break }
                    catch { V2ServiceLogging.logWorkerFailure(logger, worker: "join_quota_recovery", error: error) }
                    do { try await v2Sleep(for: .seconds(5)) } catch { break }
                }
            }
            let groupInvitations = V2ActorGroupInvitationClient(coordinator: invitationCoordinator)
            V2VaporGroupInvitationRoutes(
                authenticator: authenticator,
                invitations: groupInvitations
            ).register(on: authenticatedAccountRoutes)
            V2PasswordLifecycleRoutes(service: V2PasswordLifecycleService(database: database, passwords: passwordWorker,
                limiter: V2PostgresPasswordLoginAttemptLimiter(database: database, policy: configuration.passwordLoginRateLimit),
                recoveryKey: configuration.accessTokenKey)).register(on: app)
            V2PasswordAccountRoutes(
                store: V2PostgresPasswordAccountStore(database: database),
                assertionIssuer: assertionIssuer,
                passwords: passwordWorker,
                loginAttemptLimiter: V2PostgresPasswordLoginAttemptLimiter(
                    database: database,
                    policy: configuration.passwordLoginRateLimit
                )
            ).register(on: app)
            stage = "account_http_runtime"
            try await V2HTTPService.withRunning(app, logger: logger,
                waitForShutdown: V2ProcessTerminationSignal.wait) { shutdown in
                logger.notice("IM V2 account service bound", metadata: ["host": "\(configuration.listener.host)", "port": "\(configuration.listener.port)"])
                await shutdown.wait()
            }
            stage = "account_shutdown"
            await runtimeTasks.cancelAndWait(logger: logger)
            try await passwordWorker.shutdown()
            try await app.shutdown()
            guard try await actor.stop(deadline: .now + actor.configuration.drainTimeout.duration) else {
                logger.critical("IM V2 account room actor drain exceeded its shutdown deadline",
                    metadata: V2SafeLogMetadata.drainTimeout(stage: "account_actor_shutdown"))
                exit(EXIT_FAILURE)
            }
            roomActor = nil
            try await resources.shutdown()
            try await applicationEventLoops.shutdownGracefully()
        } catch {
            logger.error("IM V2 account lifecycle failed; cleaning up", metadata:
                V2SafeLogMetadata.failure(error, stage: stage))
            await runtimeTasks.cancelAndWait(logger: logger)
            try? await passwordWorker.shutdown()
            try? await app.shutdown()
            if let roomActor {
                do {
                    guard try await roomActor.stop(deadline: .now + roomActor.configuration.drainTimeout.duration) else {
                        logger.critical("IM V2 account room actor drain incomplete; retaining database resources",
                            metadata: V2SafeLogMetadata.drainTimeout(stage: "account_actor_failure_drain"))
                        exit(EXIT_FAILURE)
                    }
                } catch {
                    logger.critical("IM V2 account room actor shutdown failed; retaining database resources",
                        metadata: V2SafeLogMetadata.failure(error, stage: "account_actor_failure_drain"))
                    exit(EXIT_FAILURE)
                }
            }
            try? await resources.shutdown()
            try? await applicationEventLoops.shutdownGracefully()
            throw V2StagedOperationalError(stage: stage, error: error)
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


/// 持有服务运行期间的非结构化后台任务。
///
/// 无论正常退出还是异常退出，都会在开始关闭数据库与事件循环之前取消并等待这批任务收敛。
private actor RuntimeTaskSupervisor {
    private var tasks: [Task<Void, Never>] = []
    private var isShuttingDown = false

    func start(_ operation: @escaping @Sendable () async -> Void) {
        guard !isShuttingDown else { return }
        tasks.append(Task { await operation() })
    }

    func cancelAndWait(logger: Logger) async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        let ownedTasks = tasks
        tasks.removeAll(keepingCapacity: false)
        for task in ownedTasks { task.cancel() }
        guard await v2WaitForTaskDrain(ownedTasks, timeout: .seconds(30)) else {
            logger.critical("IM V2 account task drain exceeded its shutdown deadline",
                metadata: V2SafeLogMetadata.drainTimeout(stage: "account_worker_shutdown"))
            exit(EXIT_FAILURE)
        }
    }
}
