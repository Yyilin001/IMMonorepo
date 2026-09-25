import Foundation
import FluentKit
import Logging
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import IMV2Server
import IMV2ActorApplication
import IMV2ActorContracts
import IMV2ServerHTTP
import Vapor

/// 进程组合根：按依赖顺序装配网关，启动房间 Actor，但不启动监听器或后台轮询。
/// Actor 启动后的任一步骤失败，均在此边界按原顺序清理 Actor 与 Broker。
struct GatewayComposition {
    let server: V2TLSGatewayServer
    let actors: V2RoomActorApplication
    let actorConfiguration: V2RoomActorApplicationConfiguration
    let connectionRegistry: V2DeviceConnectionRegistry
    let foregroundGroupEventHints: V2ForegroundGroupEventHintDispatcher
    let directRoomLogEventCache: V2DirectRoomLogEventCache?
    let backgroundWorkers: GatewayBackgroundWorkers
    let natsGroupWakeBroker: V2NATSGroupEventWakeBroker?
    let sharedGroupWakeInterests: V2SharedGroupEventWakeInterests?
    let accountRoomChangeService: V2AccountRoomChangeService?
    let natsLiveActivityBroker: V2NATSLiveActivityBroker?

    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        localMediaConfiguration: V2LocalFilesystemMediaRuntimeConfiguration?,
        resources: V2DatabaseResources,
        app: Application,
        logger: Logger
    ) async throws -> Self {
        var natsGroupWakeBroker: V2NATSGroupEventWakeBroker?
        var sharedGroupWakeInterests: V2SharedGroupEventWakeInterests?
        var accountRoomChangeService: V2AccountRoomChangeService?
        var natsLiveActivityBroker: V2NATSLiveActivityBroker?
        var roomActorApplication: V2RoomActorApplication?
        do {
            let topology = try await GatewayDatabaseTopology.build(
                configuration: configuration, resources: resources, logger: logger
            )
            let database = topology.database
            let maintenanceDatabase = topology.maintenanceDatabase
            let authorizationControlDatabase = topology.authorizationControlDatabase
            let directAuthorizationCoordinator = V2DirectAuthorizationCoordinator(
                controlDatabase: authorizationControlDatabase,
                ownerDatabases: topology.authorizationOwners
            )
            let projectionShardLocations = topology.projectionShardLocations
            let maintenanceShardLocations = topology.maintenanceShardLocations
            let roomShardDatabases = topology.roomShardDatabases
            let syncUserShardStorage = topology.syncUserShardStorage
            func databaseForRole(
                for role: V2PostgresWorkloadPoolBudget.Role, url: String
            ) -> (any Database)? {
                topology.databaseForRole(for: role, url: url)
            }
            let coLocatedControlBuckets = Set(configuration.userShardStorage.compactMap { storage in
                storage.databaseURL == configuration.databaseURL && storage.schema == "im_v2" ? storage.bucket : nil
            })
            let userShardWork = GatewayUserShardWork.build(
                configuration: configuration,
                projectionShardLocations: projectionShardLocations,
                maintenanceShardLocations: maintenanceShardLocations
            )
            let snapshotArtifactBuilders = userShardWork.snapshotArtifactBuilders
            let userProjectionWorkers = userShardWork.userProjectionWorkers
            let projectionVersionGCWorkers = userShardWork.projectionVersionGCWorkers
            let syncLogCompactionWorkers = userShardWork.syncLogCompactionWorkers
            let userShardMetricsSources = userShardWork.userShardMetricsSources
            let syncHousekeepingWorkers = userShardWork.syncHousekeepingWorkers

            // 指标使用独立且仅监听回环地址的 HTTP 服务。
            // 原生 TLS Gateway 和公开媒体边缘均不得暴露运维指标。
            app.serverConfiguration.hostname = configuration.metrics.host
            app.serverConfiguration.port = configuration.metrics.port
            let frontdoor = GatewayFrontdoorAssembly.build(
                configuration: configuration, topology: topology
            )
            let authenticator = frontdoor.authenticator
            let commandRateLimiter = frontdoor.commandRateLimiter
            let connectionRegistry = frontdoor.connectionRegistry
            let syncWakeCoalescer = frontdoor.syncWakeCoalescer
            let liveSyncNotifier = frontdoor.liveSyncNotifier
            let databaseWorkAdmission = frontdoor.databaseWorkAdmission
            let databasePoolTopology = frontdoor.databasePoolTopology
            let prometheusTelemetry = frontdoor.prometheusTelemetry
            let transportMetrics = frontdoor.transportMetrics
            let directRoomLogAppendStageMetrics = frontdoor.directRoomLogAppendStageMetrics
            let gatewayEventLoopLagMetrics = frontdoor.gatewayEventLoopLagMetrics
            let directRoomLogFastAppendCache = frontdoor.directRoomLogFastAppendCache
            let directSendPolicyCache = frontdoor.directSendPolicyCache
            let ownerMaintenance = try GatewayOwnerMaintenanceAssembly.build(
                configuration: configuration,
                topology: topology,
                userShardMetricsSources: userShardMetricsSources,
                prometheusTelemetry: prometheusTelemetry,
                logger: logger
            )
            let roomOwnerDatabaseURLs = ownerMaintenance.roomOwnerDatabaseURLs
            let roomOwnerMaintenanceDatabases = ownerMaintenance.roomOwnerMaintenanceDatabases
            let personalEventGCWorkers = ownerMaintenance.personalEventGCWorkers
            let messageProjectionStateBodyCompactionWorkers = ownerMaintenance.messageProjectionStateBodyCompactionWorkers
            let messageProjectionStateGCWorkers = ownerMaintenance.messageProjectionStateGCWorkers
            let durableWorkMetrics = ownerMaintenance.durableWorkMetrics
            let telemetry = ownerMaintenance.telemetry
            let projection = try await GatewayProjectionAssembly.build(
                configuration: configuration,
                topology: topology,
                coLocatedControlBuckets: coLocatedControlBuckets,
                roomOwnerDatabaseURLs: roomOwnerDatabaseURLs
            )
            let syncUserShardRouter = projection.syncUserShardRouter
            let maintenanceUserShardRouter = projection.maintenanceUserShardRouter
            let userShardProjectionDelivery = projection.userShardProjectionDelivery
            let maintenanceUserShardProjectionDelivery = projection.maintenanceUserShardProjectionDelivery
            let directRoomLogEventCache = projection.directRoomLogEventCache
            let preparedGroupEventPageCache = projection.preparedGroupEventPageCache
            let roomShardRouter = projection.roomShardRouter
            let userStateWorkers = projection.userStateWorkers
            let roomOwners = try GatewayRoomOwnerAssembly.build(
                configuration: configuration,
                topology: topology,
                userShardProjectionDelivery: userShardProjectionDelivery,
                databaseWorkAdmission: databaseWorkAdmission,
                directSendPolicyCache: directSendPolicyCache,
                directRoomLogFastAppendCache: directRoomLogFastAppendCache,
                directRoomLogAppendStageMetrics: directRoomLogAppendStageMetrics,
                directRoomLogEventCache: directRoomLogEventCache
            )
            let actorConfiguration = roomOwners.actorConfiguration
            let committedHybridGroupEvents = roomOwners.committedHybridGroupEvents
            let groupEventWakeStore = roomOwners.groupEventWakeStore
            let ownerResources = roomOwners.ownerResources
            let physicalResources = roomOwners.physicalResources
            let ownerBatchers = roomOwners.ownerBatchers
            let physicalStoreKeyByShard = roomOwners.physicalStoreKeyByShard
            let bootstraps = roomOwners.bootstraps
            let forwardPairs = roomOwners.forwardPairs
            let directRoomLogShardAdmissionCredits = roomOwners.shardAdmissionCredits
            let directRoomLogRoomAdmissionCredits = roomOwners.roomAdmissionCredits
            let actorFactory = try V2RoomServerActivationFactory(owners: ownerResources,
                safetyActorUserID: configuration.contentReviewSafetyActorUserID)
            let actors = try await V2RoomActorApplication.start(configuration: actorConfiguration,
                ownerRouter: V2PostgresRoomShardRouter(database: database),
                roomDatabases: roomShardDatabases,
                factory: actorConfiguration.hostIdentity == nil ? nil : actorFactory)
            roomActorApplication = actors
            let actorDirectory = actors.directory
            let callTimeout = actorConfiguration.runtime.callTimeout
            let roomQueries = V2RoomRefQueryClient(directory: actorDirectory, callTimeout: callTimeout.duration)
            let roomActorServices = V2GatewayRoomActorServices(directory: actorDirectory, callTimeout: callTimeout,
                readReceiptControlStore: PostgresV2ReadReceiptStore(database: database,
                    projectionDelivery: userShardProjectionDelivery), databaseWorkAdmission: databaseWorkAdmission,
                directRoomLogEventCache: directRoomLogEventCache)
            let fixedBootstraps = bootstraps
            let bootstrapPort = V2ActorCreationBootstrapPort(execute: { request, deadline in
                guard ContinuousClock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
                let shard: String
                switch request {
                case .direct(let value): shard = value.roomShardID
                case .group(let value): shard = value.intent.roomShardID
                case .stagedGroup(let value): shard = value.intent.roomShardID
                }
                guard let owner = fixedBootstraps[shard] else { throw V2RoomCallFailure.notAccepted(.unavailable) }
                return try await owner.execute(request)
            }, stage: { intent, page, deadline in
                guard ContinuousClock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
                guard let owner = fixedBootstraps[intent.roomShardID] else { throw V2RoomCallFailure.notAccepted(.unavailable) }
                try await owner.stage(intent: intent, page: page)
            })
            let roomCreation = V2ActorRoomCreationCoordinator(controlDatabase: database,
                directRoutes: V2PostgresRoomShardRouter(database: database),
                directSelector: configuration.directRoomShardRouter,
                groupSelector: try .init(rawValue: configuration.groupRoomShardIDs.joined(separator: ",")),
                bootstrap: bootstrapPort, capacityProfile: configuration.capacityProfile)
            let roomCreationServices = V2GatewayRoomCreationServices(coordinator: roomCreation,
                directPreferences: V2ControlDirectMessagePreferenceClient(store:
                    PostgresV2DirectMessagingStore(database: database, projectionDelivery: userShardProjectionDelivery,
                        authorizationCoordinator: directAuthorizationCoordinator)), callTimeout: callTimeout)
            let maintenanceGroupAudienceStore = PostgresV2GroupAudienceImportStore(database: maintenanceDatabase)
            let groupEventLog = V2RoomRefGroupEventLogClient(rooms: roomQueries,
                directRoomLogEventCache: directRoomLogEventCache)
            let forwardPort = V2RoomRefForwardPort(directory: actorDirectory)
            let forwardSources = roomShardDatabases.mapValues {
                V2ActorForwardSourceEndpoint(receipts: .init(database: $0), jobs: .init(database: $0))
            }
            let forwardMessages = try V2ActorForwardingCoordinator(router: roomShardRouter,
                physicalStoreKeyByShard: physicalStoreKeyByShard,
                pair: .init(coordinator: actors.reservations, executorsByShard: forwardPairs),
                crossOwner: V2ActorCrossOwnerForwardService(sources: forwardSources,
                    sourceCommand: { try await forwardPort.execute($0, deadline: $1) },
                    deadline: { .now + callTimeout.duration }),
                deadline: { .now + callTimeout.duration })
            let directRoomLogAppendBatcher = V2AggregatedSendMessageBatchMetrics(
                owners: ownerBatchers.values.map { $0 as any V2SendMessageBatchMetricsReading })
            let readReceiptBatcher = V2AggregatedReadReceiptBatchMetrics(
                owners: physicalResources.values.map(\.receiptBatchMetrics))
            V2VaporMetricsRoutes.register(on: app, telemetry: prometheusTelemetry,
                connectionMetrics: connectionRegistry, transportMetrics: transportMetrics,
                durableWorkMetrics: durableWorkMetrics,
                runtimePressureMetrics: V2GatewayRuntimePressureMetricsSource(
                    databaseWorkAdmission: databaseWorkAdmission, databasePools: databasePoolTopology,
                    syncWakeCoalescer: syncWakeCoalescer,
                    shardAdmissionCommandCredits: directRoomLogShardAdmissionCredits,
                    roomAdmissionCommandCredits: directRoomLogRoomAdmissionCredits,
                    directRoomLogAppendBatcher: directRoomLogAppendBatcher,
                    readReceiptBatcher: readReceiptBatcher,
                    directRoomLogAppendStageMetrics: directRoomLogAppendStageMetrics,
                    gatewayEventLoopLagMetrics: gatewayEventLoopLagMetrics,
                    directSendPolicyCache: directSendPolicyCache,
                    directRoomLogFastAppendCache: directRoomLogFastAppendCache,
                    directRoomLogEventCache: directRoomLogEventCache,
                    preparedGroupEventPageCache: preparedGroupEventPageCache,
                    connectionRegistry: connectionRegistry, roomActors: actors))
            let realtime = await GatewayRealtimeAssembly.build(
                configuration: configuration,
                connectionRegistry: connectionRegistry,
                groupEventLog: groupEventLog,
                transportMetrics: transportMetrics,
                committedHybridGroupEvents: committedHybridGroupEvents
            )
            natsGroupWakeBroker = realtime.natsGroupWakeBroker
            sharedGroupWakeInterests = realtime.sharedGroupWakeInterests
            natsLiveActivityBroker = realtime.natsLiveActivityBroker
            let foregroundGroupEventHints = realtime.foregroundGroupEventHints
            let groupEventWakePublisher = realtime.groupEventWakePublisher
            let recoveryDirectory = try GatewayRoomRecoveryDirectory.build(
                configuration: configuration, topology: topology
            )
            let recoveryStates = roomQueries
            let latestVisible = try V2RoomLatestVisibleCommandService(reader: roomQueries)
            let roomRecovery = V2RoomRecoveryCommandService(directory: recoveryDirectory, states: recoveryStates, latestVisible: latestVisible)
            let accountInterests = sharedGroupWakeInterests
                ?? V2SharedGroupEventWakeInterests(underlying: V2LocalRoomChangeInterest())
            sharedGroupWakeInterests = accountInterests
            let accountChanges = try V2AccountRoomChangeService(states: recoveryStates, interests: accountInterests)
            accountRoomChangeService = accountChanges
            await connectionRegistry.configureAccountRoomChanges(accountChanges)
            let socialRelationships = V2SocialRelationshipService(
                store: PostgresV2SocialRelationshipStore(database: database, projectionDelivery: userShardProjectionDelivery, authorizationCoordinator: directAuthorizationCoordinator)
            )
            let contentReviewWorker: V2RoutedContentReviewWorker?
            if configuration.contentReviewMode == .enabled,
               configuration.contentReviewSafetyActorUserID != nil {
                let reviewer = V2ConfiguredContentReviewer(
                    violatingTerms: configuration.contentReviewViolationTerms,
                    reviewTerms: configuration.contentReviewEscalationTerms
                )
                let trustedModeration = V2RoomContentReviewSafetyApplicator(callTimeout: callTimeout.duration) {
                    request, deadline in
                    try await actorDirectory.room(request.roomID).call(request, principal: .service, deadline: deadline)
                }
                let reviewWorkers = try roomOwnerDatabaseURLs.map { ownerURL in
                    guard let ownerMaintenanceDatabase = databaseForRole(
                        for: .maintenance,
                        url: ownerURL
                    ) else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    return try V2ContentReviewWorker(
                        store: PostgresV2ContentReviewStore(
                            database: ownerMaintenanceDatabase
                        ),
                        reviewer: reviewer,
                        moderation: trustedModeration,
                        retryPolicy: configuration.durableRetryPolicy
                    )
                }
                contentReviewWorker = try V2RoutedContentReviewWorker(
                    workers: reviewWorkers
                )
            } else {
                contentReviewWorker = nil
            }
            let conversationCapabilities = V2ConversationCapabilitiesService(
                store: PostgresV2ConversationCapabilitiesStore(database: database, projectionDelivery: userShardProjectionDelivery)
            )
            let liveActivityStore = try PostgresV2LiveActivityStore(database: database)
            let liveActivity = V2LiveActivityService(store: liveActivityStore)
            await connectionRegistry.configureLivePresenceLeases(liveActivityStore)
            await connectionRegistry.configureLiveActivityObservationAuthorizer(liveActivity)
            let handler = V2GatewayDomainCommandHandler(
                roomActors: roomActorServices,
                roomCreation: roomCreationServices,
                liveActivity: liveActivity,
                foregroundGroupEventHints: foregroundGroupEventHints,
                roomRecovery: roomRecovery,
                accountChanges: connectionRegistry,
                socialRelationships: socialRelationships,
                conversationCapabilities: conversationCapabilities,
                forwardMessages: forwardMessages,
                sync: .init(store: V2RoutedSyncStore(
                    registry: syncUserShardStorage, routeFence: syncUserShardRouter,
                    coLocatedControlBuckets: coLocatedControlBuckets,
                    capabilityProfile: configuration.capabilityProfile,
                    // 为 envelope、不透明令牌、回执、代次、能力配置及 protobuf
                    // 长度前缀预留有界空间；记录本身的大小按实际值精确计算。
                    maximumEncodedRecordsBytes: max(
                        1,
                        configuration.frameLimits.maximumPayloadBytes - 4_096
                    )
                )),
                telemetry: telemetry,
                databaseWorkAdmission: configuration.databaseWorkAdmissionEnabled
                    ? databaseWorkAdmission
                    : nil,
                controlWriteAdmissionEnabled:
                    configuration.foregroundControlWriteDatabaseWorkLimit > 0,
                maximumGroupEventPagePayloadBytes: max(
                    1,
                    configuration.frameLimits.maximumPayloadBytes - 4_096
                )
            )
            // 唤醒转发不构成交付依赖：发布失败或重复只影响前台延迟，
            // 因为客户端始终按游标拉取房间事件日志。
            let groupEventWakeRelay = V2GroupEventWakeRelay(
                store: groupEventWakeStore,
                publisher: groupEventWakePublisher
            )
            let maintenance = try GatewayMaintenanceAssembly.build(
                configuration: configuration,
                topology: topology,
                projectionDelivery: maintenanceUserShardProjectionDelivery,
                liveSyncNotifier: liveSyncNotifier,
                maintenanceUserShardRouter: maintenanceUserShardRouter,
                coLocatedControlBuckets: coLocatedControlBuckets,
                roomOwnerMaintenanceDatabases: roomOwnerMaintenanceDatabases,
                actorDirectory: actorDirectory,
                callTimeout: callTimeout,
                connectionRegistry: connectionRegistry
            )
            let server = try GatewayTransportAssembly.build(
                configuration: configuration,
                authenticator: authenticator,
                commandRateLimiter: commandRateLimiter,
                preparedGroupEventPageCache: preparedGroupEventPageCache,
                handler: handler,
                connectionRegistry: connectionRegistry,
                transportMetrics: transportMetrics,
                gatewayEventLoopLagMetrics: gatewayEventLoopLagMetrics
            )
            // 新命名的副本尚无活动连接。客户端认证前先记录当前撤销水位，
            // 避免扩容时重扫只追加历史；已有游标则保留，以支持崩溃恢复。
            try await maintenance.deviceRevocationWorker.initializeForStartup()
            // 存储清理使用独立的集群全局游标，首次部署从零开始，
            // 以覆盖没有 Gateway 在线观察历史撤销的停机窗口。
            try await maintenance.revokedDeviceProjectionCleanupWorker.initializeForStartup()
            let forwardDelivery = try GatewayForwardDeliveryAssembly.build(
                configuration: configuration,
                localMediaConfiguration: localMediaConfiguration,
                topology: topology,
                roomOwners: roomOwners,
                forwardPort: forwardPort,
                callTimeout: callTimeout,
                logger: logger
            )
            let backgroundWorkers = GatewayBackgroundWorkers(
                configuration: configuration,
                logger: logger,
                delivery: .init(
                    forwardRuntime: forwardDelivery.runtime,
                    directAuthorizationCoordinator: directAuthorizationCoordinator,
                    foregroundGroupEventHints: foregroundGroupEventHints,
                    directRoomLogEventCache: directRoomLogEventCache,
                    syncWakeCoalescer: syncWakeCoalescer,
                    userStateWorkers: userStateWorkers,
                    groupEventWakeRelay: groupEventWakeRelay,
                    contentReviewWorker: contentReviewWorker,
                    pushWakeWorker: maintenance.pushWakeWorker
                ),
                projection: .init(
                    userProjectionWorkers: userProjectionWorkers,
                    databaseWorkAdmission: databaseWorkAdmission,
                    snapshotArtifactBuilders: snapshotArtifactBuilders,
                    messageProjectionStateBodyCompactionWorkers: messageProjectionStateBodyCompactionWorkers
                ),
                maintenance: .init(
                    revokedDeviceProjectionCleanupWorker: maintenance.revokedDeviceProjectionCleanupWorker,
                    controlPlaneHousekeepingWorker: maintenance.controlPlaneHousekeepingWorker,
                    syncLogCompactionWorkers: syncLogCompactionWorkers,
                    roomMaintenanceWorkers: maintenance.roomMaintenanceWorkers,
                    syncHousekeepingWorkers: syncHousekeepingWorkers,
                    projectionVersionGCWorkers: projectionVersionGCWorkers,
                    personalEventGCWorkers: personalEventGCWorkers,
                    messageProjectionStateGCWorkers: messageProjectionStateGCWorkers,
                    forwardBackgroundDatabases: forwardDelivery.backgroundDatabases,
                    directRoomProfilePropagationWorker: maintenance.directRoomProfilePropagationWorker,
                    readReceiptPreferencePropagationWorker: maintenance.readReceiptPreferencePropagationWorker,
                    deviceRevocationWorker: maintenance.deviceRevocationWorker,
                    moderationAuditRetentionWorker: maintenance.moderationAuditRetentionWorker,
                    maintenanceGroupAudienceStore: maintenanceGroupAudienceStore,
                    roomCreation: roomCreation,
                    callTimeout: callTimeout,
                    mediaRetentionWorker: maintenance.mediaRetentionWorker
                )
            )
            return .init(
                server: server,
                actors: actors,
                actorConfiguration: actorConfiguration,
                connectionRegistry: connectionRegistry,
                foregroundGroupEventHints: foregroundGroupEventHints,
                directRoomLogEventCache: directRoomLogEventCache,
                backgroundWorkers: backgroundWorkers,
                natsGroupWakeBroker: natsGroupWakeBroker,
                sharedGroupWakeInterests: sharedGroupWakeInterests,
                accountRoomChangeService: accountRoomChangeService,
                natsLiveActivityBroker: natsLiveActivityBroker
            )
        } catch {
            logger.error("IM V2 gateway composition failed; cleaning up", metadata:
                V2SafeLogMetadata.failure(error, stage: "gateway_composition"))
            if let roomActorApplication {
                do {
                    guard try await roomActorApplication.stop(deadline: .now + .seconds(60)) else {
                        logger.critical("IM V2 room actor failure drain exceeded its deadline",
                            metadata: V2SafeLogMetadata.drainTimeout(stage: "gateway_actor_failure_drain"))
                        exit(EXIT_FAILURE)
                    }
                } catch {
                    logger.critical("IM V2 room actor failure drain failed", metadata:
                        V2SafeLogMetadata.failure(error, stage: "gateway_actor_failure_drain"))
                    exit(EXIT_FAILURE)
                }
            }
            await natsLiveActivityBroker?.shutdown()
            await accountRoomChangeService?.shutdown()
            await sharedGroupWakeInterests?.shutdown()
            await natsGroupWakeBroker?.shutdown()
            throw error
        }
    }

    func shutdownAuxiliaryServices() async {
        await natsLiveActivityBroker?.shutdown()
        await accountRoomChangeService?.shutdown()
        await sharedGroupWakeInterests?.shutdown()
        await natsGroupWakeBroker?.shutdown()
    }

    func shutdownAfterFailure(logger: Logger) async {
        do {
            guard try await actors.stop(deadline: .now + .seconds(60)) else {
                logger.critical("IM V2 room actor failure drain exceeded its deadline",
                    metadata: V2SafeLogMetadata.drainTimeout(stage: "gateway_actor_failure_drain"))
                exit(EXIT_FAILURE)
            }
        } catch {
            logger.critical("IM V2 room actor failure drain failed", metadata:
                V2SafeLogMetadata.failure(error, stage: "gateway_actor_failure_drain"))
            exit(EXIT_FAILURE)
        }
        await shutdownAuxiliaryServices()
    }
}
