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
import IMV2Server
import IMV2ServerHTTP
import NIOPosix
import Vapor

@main
enum IMV2AccountServerApp {
    static func main() async {
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        let logger = Logger(label: "imv2.account")
        do {
            try await withLogger(logger) { _ in try await run(logger: logger) }
        } catch {
            logger.error("IM V2 account startup or shutdown failed")
            exit(EXIT_FAILURE)
        }
    }

    private static func run(logger: Logger) async throws {
        V2ProcessTerminationSignal.install()
        let configuration = try V2AccountRuntimeConfiguration(environment: ProcessRuntimeEnvironment())
        let localMediaConfiguration = try V2LocalFilesystemMediaRuntimeConfiguration(environment: ProcessRuntimeEnvironment())
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
            throw error
        }
        V2RedactedHTTPMiddlewareConfiguration.install(on: app)
        let runtimeTasks = RuntimeTaskSupervisor()
        let passwordWorker = V2PasswordHashWorker()
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
                        logger.error("IM V2 account-edge rate-limit retention failed; retrying")
                    }
                    do {
                        try await v2Sleep(for: .seconds(60))
                    } catch {
                        break
                    }
                }
            }
            // Reuse one physical pool for room invitations and local media.
            // Owner routing must exist even when the filesystem media adapter is off.
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
            let invitationOwners = try V2StaticRoomShardStorageRegistry(locations: configuration.roomShardStorage.map { storage in
                guard let owner = accountStorageDatabases[storage.databaseURL] else { throw V2RoomShardStorageRegistryError.unknownShardID }
                return try .init(shardID: storage.shardID, database: owner, schema: storage.schema)
            })
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
                let mediaDownloads = V2RoutedMediaDownloadService(
                    local: .init(media: media, providerSessions: downloadProviderSessions),
                    rooms: V2PostgresRoomShardRouter(database: database), owners: mediaOwners,
                    controlDatabase: database
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
                            // This local scanner is deliberately diagnostic
                            // only; never include IDs, paths, or bytes here.
                            logger.error("IM V2 local media maintenance worker failed; retrying")
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
                presentations: V2RoutedProfilePresentationStore(
                    aliases: PostgresV2ProfilePresentationStore(database: database),
                    router: V2PostgresRoomShardRouter(database: database),
                    owners: invitationOwners
                )
            ).register(on: authenticatedAccountRoutes)
            let routedInvitations = V2RoutedGroupInvitationStore(controlDatabase: database, router: V2PostgresRoomShardRouter(database: database), owners: invitationOwners)
            let inviteRecovery = V2GroupInviteCreationRecoveryWorker(jobs: PostgresV2GroupInviteDirectory(database: database), invitations: routedInvitations)
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
                    catch { logger.error("IM V2 invite creation recovery failed; retrying") }
                    do { try await v2Sleep(for: .seconds(5)) } catch { break }
                }
            }
            let joinQuotaRecovery = V2GroupJoinQuotaRecoveryWorker(controlDatabase: database, invitations: routedInvitations)
            await runtimeTasks.start {
                while !Task.isCancelled {
                    do {
                        let report = try await joinQuotaRecovery.runOnce(limit: 8)
                        if report.deferred > 0 {
                            logger.warning("IM V2 join quota recovery deferred", metadata: ["deferred": "\(report.deferred)"])
                        }
                    } catch is CancellationError { break }
                    catch { logger.error("IM V2 join quota recovery failed; retrying") }
                    do { try await v2Sleep(for: .seconds(5)) } catch { break }
                }
            }
            let groupInvitations = V2GroupInvitationService(
                store: routedInvitations,
                capacityProfile: configuration.capacityProfile,
                secretIssuer: try .init(rawKey: configuration.groupInviteTokenHMACKey)
            )
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
            try await V2HTTPService.withRunning(app, logger: logger,
                waitForShutdown: V2ProcessTerminationSignal.wait) { shutdown in
                logger.notice("IM V2 account service bound", metadata: ["host": "\(configuration.listener.host)", "port": "\(configuration.listener.port)"])
                await shutdown.wait()
            }
            await runtimeTasks.cancelAndWait(logger: logger)
            try await passwordWorker.shutdown()
            try await app.shutdown()
            try await resources.shutdown()
            try await applicationEventLoops.shutdownGracefully()
        } catch {
            await runtimeTasks.cancelAndWait(logger: logger)
            try? await passwordWorker.shutdown()
            try? await app.shutdown()
            try? await resources.shutdown()
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
            logger.critical("IM V2 account task drain exceeded its shutdown deadline")
            exit(EXIT_FAILURE)
        }
    }
}
