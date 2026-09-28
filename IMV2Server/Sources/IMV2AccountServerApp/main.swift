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
import IMV2ActorContracts
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
            try await withLogger(logger) { scopedLogger in
                try await run(logger: scopedLogger)
            }
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
        var resourceProfileRuntime: V2ResourceProfilePresentationService?
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
            for url in Set(configuration.roomShardStorage.map(\.databaseURL) + configuration.userShardStorage.map(\.databaseURL)) where accountStorageDatabases[url] == nil {
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
            var socialUserLocations:[V2UserShardStorageLocation]=[]
            for storage in configuration.userShardStorage {
                guard let owner=accountStorageDatabases[storage.databaseURL] else { throw V2RoomWriteStoreError.corruptPersistenceState }
                socialUserLocations.append(try .init(bucket:storage.bucket,database:owner,schema:storage.schema))
            }
            let socialUserRegistry=try V2StaticUserShardStorageRegistry(locations:socialUserLocations)
            // Partition the existing coordination budget N: the outer direct
            // pair-route transaction gets 1; all nested work retains N-1.
            // Route waiters cannot consume identity/authorization/projection capacity.
            let socialCoordinationID=DatabaseID(string:"account-social-coordination")
            resources.databases.use(try postgresDatabaseConfiguration(url:configuration.databaseURL,policy:configuration.databasePolicy,
                connectionsPerEventLoop:configuration.databasePolicy.maximumConnectionsPerEventLoop-1),as:socialCoordinationID)
            let socialCoordinationPool=try V2EventLoopDatabasePool(databases:resources.databases,logger:logger,identifier:socialCoordinationID,eventLoops:databaseEventLoops)
            let directPairRouteID=DatabaseID(string:"account-direct-pair-route")
            resources.databases.use(try postgresDatabaseConfiguration(url:configuration.databaseURL,policy:configuration.databasePolicy,
                connectionsPerEventLoop:1),as:directPairRouteID)
            let directPairRoutePool=try V2EventLoopDatabasePool(databases:resources.databases,logger:logger,identifier:directPairRouteID,eventLoops:databaseEventLoops)
            for member in socialCoordinationPool.eventLoopDatabases + directPairRoutePool.eventLoopDatabases {
                try await V2PostgresSessionReadiness.verify(database:member,policy:configuration.databasePolicy)
            }
            let socialRouteFence=V2PostgresUserShardRouter(database:socialCoordinationPool.database)
            let socialProjectionDelivery=V2PostgresUserShardProjectionDelivery(registry:socialUserRegistry,routeFence:socialRouteFence,batchRouteFence:socialRouteFence,
                coLocatedControlBuckets:Set(configuration.userShardStorage.filter{$0.databaseURL==configuration.databaseURL && $0.schema=="im_v2"}.map(\.bucket)))
            let socialAuthorization=V2DirectAuthorizationCoordinator(controlDatabase:socialCoordinationPool.database,ownerDatabases:roomDatabases)
            await runtimeTasks.start {
                while !Task.isCancelled {
                    do { _ = try await socialAuthorization.recover(limit:100,now:Date()) }
                    catch is CancellationError { break }
                    catch { V2ServiceLogging.logWorkerFailure(logger,worker:"social_direct_authorization_recovery",error:error) }
                    do { try await v2Sleep(for:.seconds(1)) } catch { break }
                }
            }
            let socialOperations=PostgresV2SocialRelationshipStore(database:database,projectionDelivery:socialProjectionDelivery,authorizationCoordinator:socialAuthorization)
            V2VaporSocialOperationRoutes(authenticator:authenticator,store:socialOperations).register(on:authenticatedAccountRoutes)
            let accountPreferenceOperations=PostgresV2AccountPreferenceOperationStore(database:database,projectionDelivery:socialProjectionDelivery,authorizationCoordinator:socialAuthorization)
            V2VaporAccountPreferenceOperationRoutes(authenticator:authenticator,store:accountPreferenceOperations).register(on:authenticatedAccountRoutes)
            var fixedGroupBootstraps:[String:V2RoomBootstrapDomainExecutor]=[:]
            for storage in configuration.roomShardStorage {
                guard let owner=roomDatabases[storage.shardID] else { throw V2RoomWriteStoreError.corruptPersistenceState }
                fixedGroupBootstraps[storage.shardID]=try .init(shardID:storage.shardID,
                    direct:PostgresV2DirectMessagingStore(database:owner,identityReader:PostgresV2DirectRoomIdentityReader(database:socialCoordinationPool.database),projectionDelivery:socialProjectionDelivery,authorizationCoordinator:socialAuthorization),
                    group:PostgresV2GroupMessagingStore(database:owner),capacityProfile:configuration.capacityProfile)
            }
            let groupBootstrapOwners=fixedGroupBootstraps
            let groupCreationBootstrap=V2ActorCreationBootstrapPort(execute:{ request,deadline in
                guard ContinuousClock.now<deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
                let shard:String=switch request { case .provenDirect(let value):value.roomShardID;case .provenDirectRecovery(let value):value.roomShardID;case .provenGroup(let value):value.placement.roomShardID }
                guard let owner=groupBootstrapOwners[shard] else { throw V2RoomCallFailure.notAccepted(.unavailable) }
                return try await owner.execute(request)
            },stage:{ placement,page,deadline in
                guard ContinuousClock.now<deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
                guard let owner=groupBootstrapOwners[placement.roomShardID] else { throw V2RoomCallFailure.notAccepted(.unavailable) }
                try await owner.stage(intent:placement,page:page)
            })
            let groupCreationOperations=PostgresV2GroupCreationOperationStore(database:database,selector:try .init(rawValue:configuration.groupRoomShardIDs.joined(separator:",")),bootstrap:groupCreationBootstrap,capacityProfile:configuration.capacityProfile)
            V2VaporGroupCreationOperationRoutes(authenticator:authenticator,store:groupCreationOperations).register(on:authenticatedAccountRoutes)
            let directRoomOperations=PostgresV2DirectRoomOperationStore(database:database,routes:V2PostgresRoomShardRouter(database:directPairRoutePool.database),selector:try .init(shardIDs:configuration.directRoomShardIDs),bootstrap:groupCreationBootstrap)
            V2VaporDirectRoomOperationRoutes(authenticator:authenticator,store:directRoomOperations).register(on:authenticatedAccountRoutes)
            let roomRouter = V2PostgresRoomShardRouter(database: database)
            let actorConfiguration = try V2RoomActorApplicationConfiguration(
                environment: ProcessRuntimeEnvironment(), hostsRooms: false,
                configuredShardIDs: Set(roomDatabases.keys))
            let actor = try await V2RoomActorApplication.start(
                configuration: actorConfiguration, ownerRouter: roomRouter,
                roomDatabases: roomDatabases)
            roomActor = actor
            let forwardPlans=V2ForwardPlanService(store:.init(database:database),
                port:.init(router:roomRouter,rooms:.init(directory:actor.directory)))
            V2VaporForwardPlanRoutes(authenticator:authenticator,service:forwardPlans).register(on:authenticatedAccountRoutes)
            await runtimeTasks.start {
                while !Task.isCancelled {
                    do { try await forwardPlans.runOnce(limit:16) }
                    catch is CancellationError { break }
                    catch { V2ServiceLogging.logWorkerFailure(logger,worker:"forward_plan_recovery",error:error) }
                    do { try await v2Sleep(for:.milliseconds(200)) } catch { break }
                }
            }
            if let localMediaConfiguration {
                let provider = try V2LocalFilesystemMediaProvider(
                    rootDirectory: localMediaConfiguration.rootDirectory,
                    targetBaseURL: localMediaConfiguration.publicBaseURL,
                    signingKey: localMediaConfiguration.signingKey
                )
                try await provider.prepare()
                let media = V2MediaService(
                    store: PostgresV2MediaStore(database: database)
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
                let backendConfiguration = try V2ResourceBackendConfiguration(environment: ProcessRuntimeEnvironment(), defaultDirectory: localMediaConfiguration.rootDirectory)
                var storageValues: [V2StorageBinding: V2LocalResourceStorage] = [:]
                var transportValues: [any V2UploadTransport] = []
                for entry in backendConfiguration.entries {
                    let binding = try entry.binding
                    let directory = URL(fileURLWithPath: entry.directory, isDirectory: true)
                    let uploadProvider: V2LocalFilesystemMediaProvider
                    if directory.standardizedFileURL == localMediaConfiguration.rootDirectory {
                        uploadProvider = provider
                    } else {
                        let base = localMediaConfiguration.publicBaseURL.appendingPathComponent("v2/resource-backends")
                            .appendingPathComponent(entry.id).appendingPathComponent(String(entry.revision))
                        uploadProvider = try .init(rootDirectory: directory, targetBaseURL: base, signingKey: localMediaConfiguration.signingKey)
                        try await uploadProvider.prepare()
                        try V2VaporLocalFilesystemMediaRoutes(provider: uploadProvider, fileIO: app.fileio,
                            publicBaseURL: base, maximumUploadBytes: localMediaConfiguration.maximumBytes)
                            .register(on: app.grouped("v2", "resource-backends", .constant(entry.id), .constant(String(entry.revision))))
                    }
                    storageValues[binding] = try .init(root: directory.appendingPathComponent("sealed-resources"), binding: binding)
                    transportValues.append(V2LocalResourceUploadTransport(binding: binding, provider: uploadProvider))
                }
                let configuredStorages = storageValues
                let configuredTransports = transportValues
                let resourceRegistry = try V2ResourceStorageRegistry(storages: Array(configuredStorages.values), defaultBinding: backendConfiguration.defaultBinding)
                let resourceDelivery = try V2LocalResourceDelivery(registry: resourceRegistry,
                    baseURL: localMediaConfiguration.publicBaseURL, keyID: "local-v1", keys: ["local-v1": localMediaConfiguration.signingKey])
                V2VaporResourceByteRoutes(delivery: resourceDelivery).register(on: app)
                for owner in accountStorageDatabases.values {
                    try await V2BoundMediaProvider(database: owner, registry: resourceRegistry, delivery: resourceDelivery, transports: configuredTransports).verifyReferencedBindings()
                }
                for storage in configuration.roomShardStorage {
                    guard let owner = accountStorageDatabases[storage.databaseURL] else { throw V2ResourceProviderError.configurationInvalid }
                    mediaOwners[storage.shardID] = .init(database: owner,
                        provider: try V2BoundMediaProvider(database: owner, registry: resourceRegistry, delivery: resourceDelivery, transports: configuredTransports))
                }
                let resourceRouter = V2ResourceHomeRouter(controlDatabase: database, rooms: roomRouter,
                    ownerDatabases: roomDatabases, authorization: .init(directory: actor.directory))
                let imageWorkerPath = ProcessInfo.processInfo.environment["IMV2_RESOURCE_IMAGE_WORKER"]
                    ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                        .appendingPathComponent("IMV2ResourceImageWorker").path
                let transformer: V2LocalResourceTransformer?
                if FileManager.default.isExecutableFile(atPath: imageWorkerPath) {
                    transformer = try .init(executable: URL(fileURLWithPath: imageWorkerPath),
                        temporaryDirectory: localMediaConfiguration.rootDirectory.appendingPathComponent("processing"))
                } else { transformer = nil }
                if let transformer { try await transformer.verifyReadiness() }
                let resourceService = try V2ResourceService(resolve: { home, usage, user, device in
                    try await resourceRouter.resolve(home: home, usage: usage, actorUserID: user, deviceID: device)
                }, registry: resourceRegistry,
                    transports: configuredTransports,
                    maximumBytes: localMediaConfiguration.maximumBytes, supportsAvatars: transformer != nil,
                    allocate: { binding in
                        guard let storage = configuredStorages[binding] else { throw V2ResourceProviderError.configurationInvalid }
                        return try storage.allocate()
                    })
                V2VaporResourceRoutes(authenticator: authenticator, service: resourceService).register(on: authenticatedAccountRoutes)
                let resourceProfiles = V2ResourceProfilePresentationService(controlDatabase: database,
                    authorization: .init(directory: actor.directory), avatars: .init(delivery: resourceDelivery))
                resourceProfileRuntime = resourceProfiles
                V2VaporProfilePresentationBatchRoutes(authenticator: authenticator, service: resourceProfiles).register(on: authenticatedAccountRoutes)
                let groupAvatars = V2ResourceGroupAvatarPresentationService(controlDatabase: database,
                    rooms: roomRouter, ownerDatabases: roomDatabases, authorization: .init(directory: actor.directory),
                    avatars: .init(delivery: resourceDelivery))
                V2VaporGroupAvatarPresentationRoutes(authenticator: authenticator, service: groupAvatars).register(on: authenticatedAccountRoutes)
                let groupAvatarCommands = V2ResourceGroupAvatarCommandService(controlDatabase: database,
                    administration: .init(directory: actor.directory))
                V2VaporGroupAvatarCommandRoutes(authenticator: authenticator, service: groupAvatarCommands).register(on: authenticatedAccountRoutes)
                V2VaporGroupAvatarRecoveryRoutes(authenticator: authenticator, service: groupAvatarCommands).register(on: authenticatedAccountRoutes)
                let resourceImports = V2ResourceImportService(resources: resourceService, resolve: { home, usage, user, device in
                    try await resourceRouter.resolve(home: home, usage: usage, actorUserID: user, deviceID: device)
                }, sources: .init(controlDatabase: database, rooms: roomRouter, ownerDatabases: roomDatabases,
                    authorization: .init(directory: actor.directory), avatarAuthorization: { key, media, variant, user, device in
                        _ = try await resourceProfiles.authorizeAvatarImport(key: key, mediaID: media, variantID: variant,
                            actorUserID: user, deviceID: device)
                    }), registry: resourceRegistry, transports: configuredTransports)
                V2VaporResourceImportRoutes(authenticator: authenticator, service: resourceImports).register(on: authenticatedAccountRoutes)

                let mediaDownloads = V2RoomRefMediaDownloadClient(
                    local: .init(media: media, providerSessions: try V2MediaProviderSessionService(
                        store: PostgresV2MediaDownloadSessionStore(database: database),
                        provider: V2BoundMediaProvider(database: database, registry: resourceRegistry, delivery: resourceDelivery, transports: configuredTransports))),
                    rooms: roomRouter, owners: mediaOwners, controlDatabase: database,
                    authorization: .init(directory: actor.directory)
                )
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

                // Every distinct physical owner hosts resource sessions and durable jobs.
                for ownerDatabase in accountStorageDatabases.values {
                    let variants = transformer.map { transformer in
                        V2ResourceVariantProcessor(database: ownerDatabase, registry: resourceRegistry, transformer: transformer,
                            allocate: { binding in
                                guard let storage = configuredStorages[binding] else { throw V2ResourceProviderError.configurationInvalid }
                                return try storage.allocate()
                            })
                    }
                    let scanner = try V2MediaScanWorker(store: PostgresV2MediaScanStore(database: ownerDatabase),
                        provider: V2PlacementMediaScanner(database: ownerDatabase, registry: resourceRegistry,
                            scanner: V2LocalResourceScanner(), variants: variants))
                    let purger = try V2MediaPurgeWorker(store: PostgresV2MediaPurgeStore(database: ownerDatabase),
                        provider: V2PlacementMediaPurger(database: ownerDatabase, registry: resourceRegistry,
                            uploads: try V2BoundMediaProvider(database: ownerDatabase, registry: resourceRegistry, delivery: resourceDelivery, transports: configuredTransports)))
                    let retention = try V2MediaRetentionWorker(store: PostgresV2MediaRetentionStore(database: ownerDatabase))
                    let recovery = V2ResourceRecoveryWorker(database: ownerDatabase, service: resourceService)
                    await runtimeTasks.start {
                        while !Task.isCancelled {
                            do {
                                try await recovery.runOnce(limit: 16)
                                try await resourceImports.runOnce(database: ownerDatabase, limit: 16)
                                _ = try await scanner.runOnce(limit: 16)
                                _ = try await retention.runOnce(limit: 16)
                                _ = try await purger.runOnce(limit: 16)
                            } catch is CancellationError { break
                            } catch {
                                V2ServiceLogging.logWorkerFailure(logger, worker: "local_media_maintenance_worker", error: error)
                            }
                            do { try await v2Sleep(for: .milliseconds(200)) } catch { break }
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
            let profileUpdateStore = PostgresV2ProfileUpdateStore(database: database)
            V2VaporPersonalPreferenceRecoveryRoutes(authenticator:authenticator,administration:.init(directory:actor.directory)).register(on:authenticatedAccountRoutes)
            V2VaporMessageSendOperationRoutes(authenticator:authenticator,messages:.init(directory:actor.directory,callTimeout:try .init(10_000))).register(on:authenticatedAccountRoutes)
            V2VaporMessageMutationOperationRoutes(authenticator:authenticator,messages:.init(directory:actor.directory,callTimeout:try .init(10_000))).register(on:authenticatedAccountRoutes)
            V2VaporGroupCapabilityRoutes(authenticator:authenticator,rooms:.init(directory:actor.directory)).register(on:authenticatedAccountRoutes)
            V2VaporMembershipOperationRoutes(authenticator:authenticator,rooms:.init(directory:actor.directory)).register(on:authenticatedAccountRoutes)
            V2VaporMemberAdministrationRoutes(authenticator:authenticator,rooms:.init(directory:actor.directory)).register(on:authenticatedAccountRoutes)
            V2VaporMessageModerationRoutes(authenticator:authenticator,rooms:.init(directory:actor.directory)).register(on:authenticatedAccountRoutes)
            V2VaporMessageReactionOperationRoutes(authenticator:authenticator,messages:.init(directory:actor.directory,callTimeout:try .init(10_000))).register(on:authenticatedAccountRoutes)
            V2VaporReadReceiptRecoveryRoutes(authenticator:authenticator,queries:.init(directory:actor.directory)).register(on:authenticatedAccountRoutes)
            V2VaporProfileUpdateRoutes(
                authenticator: authenticator,
                profiles: .init(store: profileUpdateStore, reader: profileUpdateStore)
            ).register(on: authenticatedAccountRoutes)
            V2VaporProfilePresentationRoutes(
                authenticator: authenticator,
                presentations: V2RoomRefProfilePresentationClient(
                    aliases: PostgresV2ProfilePresentationStore(database: database),
                    directory: actor.directory
                ), authorizedProfiles: resourceProfileRuntime
            ).register(on: authenticatedAccountRoutes)
            let invitationOperations=V2RoomRefAdministrationClient(directory:actor.directory)
            let invitationCoordinator = V2ActorInvitationCoordinator(
                controlDatabase: database,
                room: .init(directory: actor.directory),
                operations:.init(baseline:{ input,deadline in try await invitationOperations.groupInvitationBaseline(input,deadline:deadline) },
                    admit:{ input,deadline in try await invitationOperations.admitGroupInvitation(input,deadline:deadline) },
                    submit:{ input,deadline in try await invitationOperations.submitGroupInvitation(input,deadline:deadline) },
                    recover:{ input,deadline in try await invitationOperations.recoverGroupInvitation(input,deadline:deadline) }),
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
            V2VaporGroupInvitationOperationRoutes(authenticator:authenticator,coordinator:invitationCoordinator).register(on:authenticatedAccountRoutes)
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
            await resourceProfileRuntime?.close()
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
            await resourceProfileRuntime?.close()
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
    policy: V2PostgresRuntimePolicy,
    connectionsPerEventLoop: Int? = nil
) throws -> DatabaseConfigurationFactory {
    let connections = connectionsPerEventLoop ?? policy.maximumConnectionsPerEventLoop
    guard (1...policy.maximumConnectionsPerEventLoop).contains(connections) else {
        throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP")
    }
    var configuration = try SQLPostgresConfiguration(url: url)
    configuration.coreConfiguration.options.connectTimeout = .milliseconds(
        Int64(policy.connectTimeoutMilliseconds)
    )
    configuration.coreConfiguration.options.additionalStartupParameters.append(
        contentsOf: policy.startupParameters
    )
    return .postgres(
        configuration: configuration,
        maxConnectionsPerEventLoop: connections,
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
