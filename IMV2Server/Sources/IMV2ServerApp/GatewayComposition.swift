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
import IMV2ActorApplication
import IMV2ActorContracts
import IMV2ServerHTTP
import NIOPosix
import Vapor

/// 进程组合根：创建网关服务与后台工作依赖，不启动监听器或工作循环。
/// 部分启动失败由此边界清理已创建的 Actor 与 Broker。
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
            let syncControlDatabase = topology.syncControlDatabase
            let deliveryDatabase = topology.deliveryDatabase
            let maintenanceDatabase = topology.maintenanceDatabase
            let userStateRouter = topology.userStateRouter
            let directSendControlPool = topology.directSendControlPool
            let authorizationControlDatabase = topology.authorizationControlDatabase
            let directAuthorizationCoordinator = V2DirectAuthorizationCoordinator(
                controlDatabase: authorizationControlDatabase,
                ownerDatabases: topology.authorizationOwners
            )
            let projectionShardLocations = topology.projectionShardLocations
            let maintenanceShardLocations = topology.maintenanceShardLocations
            let roomShardDatabases = topology.roomShardDatabases
            let syncUserShardStorage = topology.syncUserShardStorage
            let deliveryUserShardStorage = topology.deliveryUserShardStorage
            let maintenanceUserShardStorage = topology.maintenanceUserShardStorage
            let physicalDatabaseURLs = topology.physicalDatabaseURLs
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
            let authenticator = V2PostgresGatewayAuthenticator(database: database, tokenKey: configuration.accessTokenKey)
            let commandRateLimiter = V2AuthenticatedGatewayCommandRateLimiter(
                policy: configuration.commandRateLimitPolicy
            )
            let connectionRegistry = V2DeviceConnectionRegistry(
                connectionAdmissionPolicy: configuration.authenticatedConnectionAdmissionPolicy,
                livePresenceRenewalConfiguration: .init(
                    maximumBatchSize: configuration.livePresenceRenewalBatchSize,
                    maximumDelay: .milliseconds(
                        configuration.livePresenceRenewalMaximumDelayMilliseconds
                    )
                ),
                foregroundFrameLimits: configuration.frameLimits,
                foregroundFrameCompression: configuration.frameCompression,
                foregroundMaximumUncompressedPayloadBytes:
                    configuration.frameLimits.maximumPayloadBytes,
                foregroundCompressionThresholdBytes:
                    configuration.frameCompressionThresholdBytes,
                foregroundMaximumCompressionExpansionRatio:
                    configuration.frameCompressionMaximumExpansionRatio
            )
            let syncWakeCoalescer = V2SyncWakeCoalescer(
                downstream: connectionRegistry,
                interval: .milliseconds(configuration.syncWakeCoalescingMilliseconds),
                maximumPendingUsers: configuration.syncWakeMaximumPendingUsers,
                maximumConcurrentDeliveries:
                    configuration.syncWakeDeliveryConcurrency
            )
            let liveSyncNotifier: any V2LiveSyncNotifier =
                configuration.syncWakeCoalescingEnabled
                    ? syncWakeCoalescer
                    : connectionRegistry
            let databaseWorkAdmission = V2DatabaseWorkAdmissionController(
                policy: .init(
                    maximumForegroundWriteInFlight:
                        configuration.foregroundWriteDatabaseWorkLimit,
                    maximumForegroundControlWriteInFlight:
                        configuration.foregroundControlWriteDatabaseWorkLimit,
                    maximumInteractiveReadInFlight:
                        configuration.interactiveReadDatabaseWorkLimit,
                    maximumSyncInFlight: configuration.syncDatabaseWorkLimit,
                    maximumForegroundWriteQueued:
                        configuration.foregroundWriteDatabaseWorkMaximumQueued,
                    maximumForegroundControlWriteQueued:
                        configuration.foregroundControlWriteDatabaseWorkMaximumQueued,
                    maximumInteractiveReadQueued:
                        configuration.interactiveReadDatabaseWorkMaximumQueued,
                    maximumSyncQueued: configuration.syncDatabaseWorkMaximumQueued,
                    timeout: .milliseconds(
                        configuration.databaseWorkAdmissionTimeoutMilliseconds
                    )
                )
            )
            let workloadPoolTopology: V2DatabasePoolTopologySnapshot
            let configuredHandleCount = configuration.databasePolicy.eventLoopThreads *
                physicalDatabaseURLs.count
            if configuration.databaseWorkloadPoolIsolationEnabled {
                workloadPoolTopology = .init(
                    pools: V2PostgresWorkloadPoolBudget.Role.allCases.map { role in
                        .init(
                            poolClass: databasePoolMetricClass(for: role),
                            eventLoopHandles: configuredHandleCount,
                            connectionCeiling: configuredHandleCount *
                                configuration.databaseWorkloadPoolBudget
                                    .connectionsPerEventLoop(for: role)
                        )
                    }
                )
            } else {
                workloadPoolTopology = .init(pools: [
                    .init(
                        poolClass: .shared,
                        eventLoopHandles: configuredHandleCount,
                        connectionCeiling: configuredHandleCount *
                            configuration.databasePolicy.maximumConnectionsPerEventLoop
                    )
                ])
            }
            let databasePoolTopology = V2DatabasePoolTopologySnapshot(pools: workloadPoolTopology.pools + [
                .init(poolClass: .userStateRoute,
                      eventLoopHandles: configuration.databasePolicy.eventLoopThreads,
                      connectionCeiling: configuration.databasePolicy.eventLoopThreads),
                .init(poolClass: .directSendControl,
                      eventLoopHandles: configuration.databasePolicy.eventLoopThreads,
                      connectionCeiling: configuration.databasePolicy.eventLoopThreads *
                        configuration.directSendControlConnectionsPerEventLoop),
                .init(poolClass: .directAuthorizationResolution,
                      eventLoopHandles: configuration.databasePolicy.eventLoopThreads * configuration.directAuthorizationResolutionDatabaseURLs.count,
                      connectionCeiling: configuration.databasePolicy.eventLoopThreads * configuration.directAuthorizationResolutionDatabaseURLs.count)
            ])
            let prometheusTelemetry = V2PrometheusTelemetrySink()
            let transportMetrics = V2GatewayTransportMetrics()
            let directRoomLogAppendStageMetrics = V2DirectRoomLogAppendStageMetrics()
            let gatewayEventLoopLagMetrics = V2EventLoopLagMetrics()
            // 所有同址房间写入者共享此有界提示缓存。
            // 每次条件追加的策略与游标仍以 PostgreSQL 为权威。
            let directRoomLogFastAppendCache = V2DirectRoomLogFastAppendCache(
                capacity: configuration.directRoomLogFastAppendCacheMaximumEntries,
                lifetime: .seconds(
                    configuration.directRoomLogFastAppendCacheLifetimeSeconds
                )
            )
            let directSendPolicyCache = V2DirectSendPolicyCache(
                capacity: configuration.directSendPolicyCacheMaximumEntries
            )
            let roomOwnerDatabaseURLs = Set(
                [configuration.databaseURL]
                    + configuration.roomShardStorage.map(\.databaseURL)
            ).sorted()
            let roomOwnerMaintenanceDatabases = try roomOwnerDatabaseURLs.map { ownerURL in
                guard let ownerDatabase = databaseForRole(for: .maintenance, url: ownerURL) else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                return ownerDatabase
            }
            let personalEventGCWorkers = roomOwnerMaintenanceDatabases.map {
                PostgresV2UserStateEventGCWorker(database: $0)
            }
            let personalEventMetricsSources = roomOwnerMaintenanceDatabases.map {
                PostgresV2UserStateEventMetricsSource(database: $0)
            }
            let roomMessageStateMetricsSources = roomOwnerMaintenanceDatabases.map {
                PostgresV2RoomMessageStateMetricsSource(database: $0)
            }
            let messageProjectionStateBodyCompactionWorkers = roomOwnerMaintenanceDatabases.map {
                PostgresV2MessageProjectionStateBodyCompactionWorker(database: $0)
            }
            let messageProjectionStateGCWorkers = roomOwnerMaintenanceDatabases.map {
                PostgresV2MessageProjectionStateGCWorker(database: $0,
                    retention: TimeInterval(configuration.messageProjectionStateRetentionSeconds))
            }
            let durableWorkMetrics = V2CachedDurableWorkMetricsSource(
                source: V2AggregateDurableWorkMetricsSource(sources: [
                    PostgresV2DurableWorkMetricsSource(
                        database: maintenanceDatabase,
                        gatewayNodeID: configuration.gatewayNodeID,
                        includesUserShardMetrics: false
                    )
                ] + userShardMetricsSources + personalEventMetricsSources + roomMessageStateMetricsSources),
                minimumRefreshInterval: TimeInterval(
                    configuration.metricsMinimumRefreshIntervalMilliseconds
                ) / 1_000,
                maximumRefreshDuration: TimeInterval(
                    configuration.metricsRefreshTimeoutMilliseconds
                ) / 1_000
            )
            let telemetry = V2CompositeTelemetrySink([
                V2ApplicationTelemetrySink(
                    logger: logger,
                    successSamplePermille: configuration.commandSuccessLogSamplePermille,
                    slowCommandThresholdMilliseconds:
                        configuration.commandSlowLogThresholdMilliseconds,
                    diagnosticLogLimiter: .init(
                        maximumPerSecond:
                            configuration.commandDiagnosticLogMaximumPerSecond
                    )
                ),
                prometheusTelemetry,
            ])
            let userShardRouter = V2PostgresUserShardRouter(database: database)
            try await userShardRouter.bootstrap(defaultRoute: configuration.userShardRoute)
            let syncUserShardRouter = V2PostgresUserShardRouter(database: syncControlDatabase)
            let deliveryUserShardRouter = V2PostgresUserShardRouter(database: deliveryDatabase)
            let maintenanceUserShardRouter = V2PostgresUserShardRouter(
                database: maintenanceDatabase
            )
            // 控制投影属于提交后的跨存储投递工作。
            // 若从前台连接池获取路由栅栏，首条消息突发时可能发生连接池自我饥饿：
            // 每次追加都等待路由栅栏，而前台连接又被同一批请求占满。
            // 咨询锁在数据库内全局有效，因此投递连接池既能保持当前路由栅栏，
            // 又能将有界后续工作与消息持久化隔离。
            let userShardProjectionDelivery = V2PostgresUserShardProjectionDelivery(
                registry: deliveryUserShardStorage,
                routeFence: deliveryUserShardRouter,
                batchRouteFence: deliveryUserShardRouter,
                coLocatedControlBuckets: coLocatedControlBuckets
            )
            let maintenanceUserShardProjectionDelivery =
                V2PostgresUserShardProjectionDelivery(
                    registry: maintenanceUserShardStorage,
                    routeFence: maintenanceUserShardRouter,
                    batchRouteFence: maintenanceUserShardRouter,
                    coLocatedControlBuckets: coLocatedControlBuckets
                )
            let directRoomLogEventCache: V2DirectRoomLogEventCache? =
                configuration.directRoomLogEventCacheMaximumEntries > 0
                ? .init(configuration: .init(
                    maximumEvents: configuration.directRoomLogEventCacheMaximumEntries,
                    maximumBytes: configuration.directRoomLogEventCacheMaximumBytes,
                    maximumEventsPerRoom: configuration.directRoomLogEventCacheMaximumEntriesPerRoom,
                    shardCount: configuration.directRoomLogEventCacheShardCount,
                    maximumPendingWrites: configuration.directRoomLogEventCacheMaximumPendingWrites
                ))
                : nil
            let preparedGroupEventPageCache: V2PreparedGroupEventPageCache? =
                configuration.preparedGroupEventPageCacheMaximumEntries > 0
                ? .init(configuration: .init(
                    maximumEntries: configuration.preparedGroupEventPageCacheMaximumEntries,
                    maximumBytes: configuration.preparedGroupEventPageCacheMaximumBytes,
                    shardCount: configuration.preparedGroupEventPageCacheShardCount
                ))
                : nil
            let roomShardRouter = V2CachedRoomShardRouter(
                source: V2PostgresRoomShardRouter(database: database)
            )
            let roomPhysicalLocationKeys = Set(configuration.roomShardStorage.map {
                $0.databaseURL + "\u{0}" + $0.schema
            })
            let userStateProjector = try V2RoutedUserStateEventProjector(
                routeFence: userStateRouter,
                registry: deliveryUserShardStorage
            )
            let userStateWorkers = try roomOwnerDatabaseURLs.map { ownerURL in
                guard let ownerDatabase = databaseForRole(for: .delivery, url: ownerURL) else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                return V2UserStateEventWorker(
                    outbox: try PostgresV2UserStateEventOutbox(database: ownerDatabase),
                    projector: userStateProjector
                )
            }
            let singleRoomOwnerIsControlDatabase =
                roomPhysicalLocationKeys.count == 1
                && configuration.roomShardStorage.allSatisfy {
                    $0.databaseURL == configuration.databaseURL
                        && $0.schema == "im_v2"
                }
            // 只有同址快速路径与运行时指标、特殊账号命令共用一个准入额度 Actor。
            // 远端单一归属方必须走下面的路由路径；若将这些 Actor 绑定到控制库，
            // 就会在错误的事务域中预留额度。
            let directRoomLogShardAdmissionCredits:
                V2ShardAdmissionCommandCreditPool? =
                singleRoomOwnerIsControlDatabase
                    && configuration.directRoomLogShardAdmissionCreditBatchSize > 0
                ? .init(
                    database: database,
                    batchSize: configuration.directRoomLogShardAdmissionCreditBatchSize
                )
                : nil
            let directRoomLogRoomAdmissionCredits:
                V2RoomAdmissionCommandCreditPool? =
                singleRoomOwnerIsControlDatabase
                    && configuration.directRoomLogRoomAdmissionCreditBatchSize > 0
                ? .init(
                    database: database,
                    batchSize: configuration.directRoomLogRoomAdmissionCreditBatchSize
                )
                : nil
            var groupEventWakeStoresByPhysicalLocation:
                [String: any V2GroupEventWakeStore] = [:]
            for storage in configuration.roomShardStorage {
                let physicalLocationKey = storage.databaseURL + "\u{0}" + storage.schema
                guard groupEventWakeStoresByPhysicalLocation[physicalLocationKey] == nil
                else { continue }
                guard let ownerDeliveryDatabase = databaseForRole(
                    for: .delivery,
                    url: storage.databaseURL
                ) else { throw V2RoomWriteStoreError.corruptPersistenceState }
                groupEventWakeStoresByPhysicalLocation[physicalLocationKey] =
                    PostgresV2GroupEventWakeStore(database: ownerDeliveryDatabase)
            }
            let groupEventWakeStore: any V2GroupEventWakeStore
            if groupEventWakeStoresByPhysicalLocation.count == 1,
               let onlyStore = groupEventWakeStoresByPhysicalLocation.values.first {
                groupEventWakeStore = onlyStore
            } else {
                groupEventWakeStore = try V2RoutedGroupEventWakeStore(
                    ownerStores: groupEventWakeStoresByPhysicalLocation
                )
            }
            let actorConfiguration = try V2RoomActorApplicationConfiguration(
                environment: ProcessRuntimeEnvironment(), hostsRooms: nil,
                configuredShardIDs: Set(configuration.roomShardStorage.map(\.shardID)),
                batchWaitMilliseconds: Int64(max(
                    configuration.directRoomLogAppendBatchMaximumDelayMilliseconds,
                    configuration.directRoomLogAppendBatchHighActivityMaximumDelayMilliseconds ?? 0,
                    configuration.readReceiptBatchMaximumDelayMilliseconds)))
            let committedHybridGroupEvents = V2CommittedHybridGroupEventObserver(
                directRoomLogEventCache: directRoomLogEventCache)
            let actorBatchConfiguration = V2SendMessageAdmissionBatcher.Configuration(
                maximumBatchSize: max(1, configuration.directRoomLogAppendBatchSize),
                maximumDelay: .milliseconds(max(1, configuration.directRoomLogAppendBatchMaximumDelayMilliseconds)),
                adaptiveDelayPolicy: {
                    guard configuration.directRoomLogAppendBatchSize > 0,
                          let delay = configuration.directRoomLogAppendBatchHighActivityMaximumDelayMilliseconds,
                          let minimumRequests = configuration.directRoomLogAppendBatchHighActivityMinimumRequests,
                          let window = configuration.directRoomLogAppendBatchHighActivityWindowMilliseconds
                    else { return nil }
                    return .init(highActivityMaximumDelay: .milliseconds(delay),
                        minimumRequestsInWindow: minimumRequests, observationWindow: .milliseconds(window))
                }(),
                maximumInFlightBatches: configuration.directRoomLogAppendBatchMaximumInFlightBatches,
                maximumPendingRequests: configuration.directRoomLogAppendMaximumPendingRequests,
                maximumTrackedActivations: actorConfiguration.runtime.maximumActiveRooms)
            var ownerResources: [String: V2RoomServerOwnerResources] = [:]
            var physicalResources: [String: V2RoomServerOwnerResources] = [:]
            var ownerBatchers: [String: any V2ActorGrantedSendBatching & V2SendMessageBatchMetricsReading] = [:]
            var forwardTargetWritesByShard: [String: PostgresV2RoomWriteStore] = [:]
            var physicalWrites: [String: PostgresV2RoomWriteStore] = [:]
            var physicalStoreKeyByShard: [String: String] = [:]
            var bootstraps: [String: V2RoomBootstrapDomainExecutor] = [:]
            var forwardPairs: [String: V2ActorForwardPairDomainExecutor] = [:]
            let membershipIdentities = V2PostgresMembershipIdentitySnapshotValidator(database: database)
            let invitationIdentities = PostgresV2GroupInvitationIdentityReader(database: database)
            for storage in configuration.roomShardStorage {
                guard let owner = roomShardDatabases[storage.shardID] else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                let physicalKey = storage.databaseURL + "\u{0}" + storage.schema
                physicalStoreKeyByShard[storage.shardID] = physicalKey
                let write: PostgresV2RoomWriteStore
                let resourcesForOwner: V2RoomServerOwnerResources
                if let existing = physicalResources[physicalKey], let existingWrite = physicalWrites[physicalKey] {
                    resourcesForOwner = existing
                    write = existingWrite
                } else {
                    let shardCredits = singleRoomOwnerIsControlDatabase
                        ? directRoomLogShardAdmissionCredits
                        : configuration.directRoomLogShardAdmissionCreditBatchSize > 0
                            ? V2ShardAdmissionCommandCreditPool(database: owner,
                                batchSize: configuration.directRoomLogShardAdmissionCreditBatchSize) : nil
                    let roomCredits = singleRoomOwnerIsControlDatabase
                        ? directRoomLogRoomAdmissionCredits
                        : configuration.directRoomLogRoomAdmissionCreditBatchSize > 0
                            ? V2RoomAdmissionCommandCreditPool(database: owner,
                                batchSize: configuration.directRoomLogRoomAdmissionCreditBatchSize) : nil
                    write = PostgresV2RoomWriteStore(database: owner,
                        strangerMessagePolicy: configuration.strangerMessagePolicy,
                        contentReviewMode: configuration.contentReviewMode,
                        directSendPolicyCache: directSendPolicyCache,
                        directRoomLogFastAppendCache: directRoomLogFastAppendCache,
                        shardAdmissionCommandCreditPool: shardCredits,
                        roomAdmissionCommandCreditPool: roomCredits,
                        appendStageMetrics: directRoomLogAppendStageMetrics)
                        .usingControlDatabase(directSendControlPool.database,
                            authorizationResolutionDatabase: authorizationControlDatabase)
                    let batcher: any V2ActorGrantedSendBatching & V2SendMessageBatchMetricsReading
                    let appendAdmission = configuration.databaseWorkAdmissionEnabled ? databaseWorkAdmission : nil
                    if configuration.directRoomLogAppendBatchSize > 0,
                       configuration.directRoomLogAppendLaneCount > 1 {
                        batcher = V2ShardedSendMessageAdmissionBatcher(store: write,
                            configuration: actorBatchConfiguration,
                            laneCount: configuration.directRoomLogAppendLaneCount,
                            databaseWorkAdmission: appendAdmission,
                            committedMessageObserver: committedHybridGroupEvents, actorGrantedStore: write)
                    } else {
                        batcher = V2SendMessageAdmissionBatcher(store: write,
                            configuration: actorBatchConfiguration, databaseWorkAdmission: appendAdmission,
                            committedMessageObserver: committedHybridGroupEvents, actorGrantedStore: write)
                    }
                    resourcesForOwner = try .init(database: owner, writes: write, sendBatcher: batcher,
                        membershipIdentities: membershipIdentities, invitationIdentities: invitationIdentities,
                        receiptProjectionDelivery: userShardProjectionDelivery,
                        capacityProfile: configuration.capacityProfile, messageLimits: configuration.messageLimits,
                        maximumEditBytes: configuration.messageLimits.maxUTF8Bytes,
                        contentReviewMode: configuration.contentReviewMode,
                        queryBatchConfiguration: .init(),
                        receiptBatchConfiguration: .init(maximumBatchSize: configuration.readReceiptBatchSize,
                            maximumDelay: .milliseconds(configuration.readReceiptBatchMaximumDelayMilliseconds),
                            maximumInFlightBatches: configuration.readReceiptBatchMaximumInFlightBatches,
                            maximumPendingRequests: configuration.readReceiptBatchMaximumPendingRequests),
                        databaseWorkAdmission: databaseWorkAdmission)
                    physicalResources[physicalKey] = resourcesForOwner
                    physicalWrites[physicalKey] = write
                    ownerBatchers[physicalKey] = batcher
                }
                ownerResources[storage.shardID] = resourcesForOwner
                forwardTargetWritesByShard[storage.shardID] = write
                bootstraps[storage.shardID] = try .init(shardID: storage.shardID,
                    direct: PostgresV2DirectMessagingStore(database: owner, projectionDelivery: userShardProjectionDelivery),
                    group: PostgresV2GroupMessagingStore(database: owner), capacityProfile: configuration.capacityProfile)
                forwardPairs[storage.shardID] = .init(database: owner, write: write,
                    capacityProfile: configuration.capacityProfile, limits: configuration.messageLimits,
                    databaseWorkAdmission: databaseWorkAdmission)
            }
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
            // 前台可用性仅作为尽力而为的提示。
            // 同一个 Broker 适配器也服务于持久 Hybrid 唤醒 outbox，
            // 但两者在命令处理器边界仍遵循不同合同。
            let groupEventWakePublisher: any V2GroupEventWakePublishing
            let foregroundGroupEventHintPublisher: any V2ForegroundGroupEventHintPublishing
            switch configuration.groupEventWake {
            case .localOnly:
                let publisher = V2LocalGroupEventWakePublisher(registry: connectionRegistry)
                groupEventWakePublisher = publisher
                foregroundGroupEventHintPublisher = publisher
            case .nats(let nats):
                let broker = V2NATSGroupEventWakeBroker(
                    configuration: nats,
                    recordRecoveryNotification: { notification in
                        switch notification {
                        case .wake:
                            break
                        case .directEvent(let event):
                            groupEventLog.recordRelayedForegroundEvents([event])
                        case .groupEvents(let events):
                            groupEventLog.recordRelayedForegroundEvents(events)
                        }
                    },
                    metrics: transportMetrics,
                    coverageLost: { [weak connectionRegistry] in
                        await connectionRegistry?.invalidateAccountRoomCoverage()
                    },
                    receiveWake: { [weak connectionRegistry] notification in
                        switch notification {
                        case .wake(let wake):
                            await connectionRegistry?.notifyForegroundGroupAvailable(
                                roomID: wake.roomID,
                                highWatermark: wake.highWatermark
                            )
                        case .directEvent(let event):
                            await connectionRegistry?.notifyForegroundDirectEvent(event)
                        case .groupEvents(let events):
                            await connectionRegistry?.notifyForegroundGroupEvents(events)
                        }
                    }
                )
                natsGroupWakeBroker = broker
                let interests = V2SharedGroupEventWakeInterests(underlying: broker)
                sharedGroupWakeInterests = interests
                await connectionRegistry.configureForegroundGroupInterestManager(interests.manager(for: .foreground))
                let liveActivityBroker = V2NATSLiveActivityBroker(
                    configuration: nats,
                    receivePresence: { [weak connectionRegistry] userID, isOnline, expiresAt in
                        await connectionRegistry?.receivePresence(
                            targetUserID: userID,
                            isOnline: isOnline,
                            expiresAt: expiresAt
                        )
                    },
                    receiveTyping: { [weak connectionRegistry] state in
                        await connectionRegistry?.receiveTyping(state)
                    }
                )
                natsLiveActivityBroker = liveActivityBroker
                await connectionRegistry.configureLiveActivityBroker(liveActivityBroker)
                groupEventWakePublisher = broker
                foregroundGroupEventHintPublisher = broker
            }
            let foregroundGroupEventHints = V2ForegroundGroupEventHintDispatcher(
                publisher: foregroundGroupEventHintPublisher,
                maximumGroupEventsPerBatch:
                    configuration.foregroundGroupBatchMaximumEvents,
                maximumPendingGroupEventsPerRoom:
                    configuration.foregroundGroupPendingMaximumEventsPerRoom,
                groupBatchDelay: .milliseconds(
                    configuration.foregroundGroupBatchDelayMilliseconds
                ),
                groupBatchExtensionDelay: .milliseconds(
                    configuration.foregroundGroupBatchExtensionDelayMilliseconds
                ),
                groupBatchExtensionMinimumEvents:
                    configuration.foregroundGroupBatchExtensionMinimumEvents,
                metrics: transportMetrics
            )
            committedHybridGroupEvents.install(sink: foregroundGroupEventHints)
            // 会话目录按房间归属读取；客户端按有效活动事实本地排序。
            // 恢复扫描使用不经缓存的控制面路由，避免过期的归属缓存
            // 为当前静态归属方之外的房间提供校验。
            let recoveryRouter = V2PostgresRoomShardRouter(database: syncControlDatabase)
            let recoveryStorageGroups = Dictionary(grouping: configuration.roomShardStorage) {
                $0.databaseURL + "\u{0}" + $0.schema
            }
            var recoveryDirectoryStores: [any V2UserRoomDirectoryReading] = []
            var recoveryStorageIdentities: [String] = []
            var recoveryLocations: [V2RoomShardStorageLocation] = []
            for key in recoveryStorageGroups.keys.sorted() {
                guard let group = recoveryStorageGroups[key], let first = group.first,
                      let owner = databaseForRole(for: .sync, url: first.databaseURL) else {
                    throw V2RoomRecoveryReadError.corruptPersistence
                }
                let shardIDs = Set(group.map(\.shardID))
                let store = try PostgresV2RoomRecoveryStore(database: owner, schema: first.schema)
                recoveryDirectoryStores.append(try V2OwnerValidatedRoomDirectoryStore(
                    underlying: store, router: recoveryRouter, physicalStoreShardIDs: shardIDs))
                // 部署指纹同时包含别名与物理身份；连接材料只参与哈希，不对外返回。
                recoveryStorageIdentities.append(try JSONEncoder().encode([key] + shardIDs.sorted()).base64EncodedString())
                for shardID in shardIDs.sorted() {
                    recoveryLocations.append(try .init(shardID: shardID, database: owner, schema: first.schema))
                }
            }
            let recoveryTopology = try PostgresV2RoomRecoveryTopology(
                database: syncControlDatabase, stores: recoveryDirectoryStores,
                orderedStoreIdentities: recoveryStorageIdentities)
            let recoveryDirectory = V2UserRoomDirectoryService(topologySource: recoveryTopology,
                cursorCodec: try .init(key: Data(configuration.accessTokenKey
                    .digest("im-v2-room-recovery-cursor-root-v1").utf8)))
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
            let directRoomProfilePropagationWorker = V2DirectRoomProfilePropagationWorker(
                database: maintenanceDatabase,
                projectionDelivery: maintenanceUserShardProjectionDelivery,
                liveNotifier: liveSyncNotifier
            )
            let readReceiptPreferencePropagationWorker = V2ReadReceiptPreferencePropagationWorker(
                database: maintenanceDatabase
            )
            let deviceRevocationWorker = V2DeviceRevocationWorker(
                store: V2PostgresDeviceRevocationEventStore(database: maintenanceDatabase),
                registry: connectionRegistry,
                nodeID: configuration.gatewayNodeID
            )
            let revokedDeviceProjectionCleanupWorker = V2RevokedDeviceProjectionCleanupWorker(
                store: V2PostgresDeviceRevocationEventStore.projectionCleanup(
                    database: maintenanceDatabase
                ),
                cleaner: V2RoutedRevokedDeviceProjectionCleaner(
                    routeFence: maintenanceUserShardRouter,
                    registry: maintenanceUserShardStorage,
                    coLocatedControlBuckets: coLocatedControlBuckets
                )
            )
            let moderationAuditRetentionWorker = V2ModerationAuditRetentionWorker(
                store: V2OwnerModerationAuditRetentionStore(owners: roomOwnerMaintenanceDatabases.map {
                    PostgresV2ModerationAuditRetentionStore(database: $0)
                })
            )
            let mediaRetentionWorker = try V2MediaRetentionWorker(
                store: PostgresV2MediaRetentionStore(database: maintenanceDatabase),
                withdrawnRetention: TimeInterval(configuration.mediaWithdrawnRetentionSeconds)
            )
            // 房间日志保留：permanent 计入全部回执，window 只计入窗口内回执；
            // 缺少回执的当前成员始终保护历史，裁剪下界告知返回客户端历史不完整。
            let roomMaintenanceWorkers = roomOwnerMaintenanceDatabases.map { owner in
                V2RoomActorMaintenanceWorker(scanner: PostgresV2RoomMaintenanceScanner(database: owner),
                    invoker: V2RoomRefMaintenanceInvoker(directory: actorDirectory), callTimeout: callTimeout.duration)
            }
            let controlPlaneHousekeepingWorker = V2ControlPlaneHousekeepingWorker(
                store: PostgresV2ControlPlaneHousekeepingStore(database: maintenanceDatabase),
                idempotencyRetention: TimeInterval(configuration.idempotencyRetentionSeconds)
            )
            let pushWakeWorker: V2PushWakeWorker?
            switch configuration.push {
            case .disabled:
                pushWakeWorker = nil
            case .apns(let pushConfiguration):
                let authorizer = try V2APNSJWTAuthorizer(
                    teamID: pushConfiguration.teamID,
                    keyID: pushConfiguration.keyID,
                    privateKeyRawBase64: pushConfiguration.privateKeyRawBase64
                )
                let provider = try V2APNSPushWakeProvider(
                    endpointStore: PostgresV2PushDeviceEndpointStore(
                        database: maintenanceDatabase,
                        envelopeKey: pushConfiguration.endpointEnvelopeKey
                    ),
                    httpClient: V2URLSessionPushHTTPClient(),
                    authorizer: authorizer,
                    topic: pushConfiguration.topic
                )
                pushWakeWorker = .init(
                    store: PostgresV2PushWakeStore(database: maintenanceDatabase),
                    provider: provider
                )
            }
            let factory = V2GatewayConnectionFactory {
                let session = V2GatewaySession(
                    limits: configuration.connectionLimits,
                    authenticator: authenticator,
                    capabilityProfile: configuration.capabilityProfile,
                    maximumProtobufMessageDepth: configuration.maximumProtobufMessageDepth,
                    supportedFrameCompression: configuration.frameCompression,
                    maximumUncompressedPayloadBytes: configuration.frameLimits.maximumPayloadBytes,
                    compressionThresholdBytes: configuration.frameCompressionThresholdBytes,
                    maximumCompressionExpansionRatio: configuration.frameCompressionMaximumExpansionRatio,
                    preparedGroupEventPageCache: preparedGroupEventPageCache,
                    commandAdmission: commandRateLimiter
                )
                return .init(frameLimits: configuration.frameLimits, session: session, handler: handler, registry: connectionRegistry)
            }
            let server = try V2TLSGatewayServer(
                configuration: configuration.tls,
                connectionFactory: factory,
                maximumConnections: configuration.maximumConnections,
                listenBacklog: configuration.listenBacklog,
                acceptBatchSize: configuration.acceptBatchSize,
                maximumQueuedInboundBytes: configuration.maximumQueuedInboundBytes,
                maximumQueuedInboundChunks: configuration.maximumQueuedInboundChunks,
                authenticationTimeoutMilliseconds: configuration.authenticationTimeoutMilliseconds,
                idleTimeoutMilliseconds: configuration.idleTimeoutMilliseconds,
                transportMetrics: transportMetrics,
                eventLoopLagMetrics: gatewayEventLoopLagMetrics
            )
            // 新命名的副本尚无活动连接。客户端认证前先记录当前撤销水位，
            // 避免扩容时重扫只追加历史；已有游标则保留，以支持崩溃恢复。
            try await deviceRevocationWorker.initializeForStartup()
            // 存储清理使用独立的集群全局游标，首次部署从零开始，
            // 以覆盖没有 Gateway 在线观察历史撤销的停机窗口。
            try await revokedDeviceProjectionCleanupWorker.initializeForStartup()
            let forwardLogger = logger
            // 仅供本地使用的字节适配器：账号边缘与 Gateway 必须共享配置的对象根目录。
            // 此处不调用 prepare()；活动上传暂存文件由账号边缘在启动时清理。
            let forwardMediaProvider: V2LocalFilesystemMediaProvider?
            if let localMediaConfiguration {
                forwardMediaProvider = try .init(rootDirectory: localMediaConfiguration.rootDirectory,
                    targetBaseURL: localMediaConfiguration.publicBaseURL, signingKey: localMediaConfiguration.signingKey)
            } else { forwardMediaProvider = nil }
            var forwardTargetEndpoints: [String: any V2ForwardExportDelivering] = [:]
            var forwardBackgroundDatabases: [String: any Database] = [:]
            for storage in configuration.roomShardStorage {
                guard let ownerDatabase = databaseForRole(for: .delivery, url: storage.databaseURL)
                else { throw V2RoomWriteStoreError.corruptPersistenceState }
                forwardBackgroundDatabases[storage.shardID] = ownerDatabase
                let mediaWorker: V2ForwardMediaImportWorker?
                if let forwardMediaProvider, let localMediaConfiguration {
                    let sources = Dictionary(uniqueKeysWithValues: forwardTargetWritesByShard.keys.map { ($0, forwardMediaProvider) })
                    mediaWorker = try .init(store: .init(database: ownerDatabase),
                        copier: V2LocalFilesystemForwardMediaCopier(sources: sources, target: forwardMediaProvider, maximumBytes: localMediaConfiguration.maximumBytes),
                        scanner: V2LocalEICARMediaScanner(provider: forwardMediaProvider))
                } else { mediaWorker = nil }
                forwardTargetEndpoints[storage.shardID] = V2ActorForwardImportEndpoint(
                    inbox: .init(database: ownerDatabase), media: mediaWorker,
                    roomCommand: { try await forwardPort.execute($0, deadline: $1) },
                    deadline: { .now + callTimeout.duration })
            }
            let forwardTransport = try V2ConfiguredForwardExportDelivery(targets: forwardTargetEndpoints)
            let forwardWorkers = try Dictionary(uniqueKeysWithValues: forwardBackgroundDatabases.map { shardID, ownerDatabase in
                (shardID, try V2ForwardDeliveryWorker(store: .init(database: ownerDatabase), receipts: .init(database: ownerDatabase), target: forwardTransport,
                    sourceCommand: { try await forwardPort.execute($0, deadline: $1) },
                    deadline: { .now + callTimeout.duration }))
            })
            let forwardRuntime = try V2ForwardDeliveryRuntime(workers: forwardWorkers,
                minimumPollMilliseconds: configuration.workerPollIntervalMilliseconds,
                onFailure: { _ in forwardLogger.error("IM V2 forward delivery worker failed; retrying") })
            let backgroundWorkers = GatewayBackgroundWorkers(
                configuration: configuration,
                logger: logger,
                delivery: .init(
                    forwardRuntime: forwardRuntime,
                    directAuthorizationCoordinator: directAuthorizationCoordinator,
                    foregroundGroupEventHints: foregroundGroupEventHints,
                    directRoomLogEventCache: directRoomLogEventCache,
                    syncWakeCoalescer: syncWakeCoalescer,
                    userStateWorkers: userStateWorkers,
                    groupEventWakeRelay: groupEventWakeRelay,
                    contentReviewWorker: contentReviewWorker,
                    pushWakeWorker: pushWakeWorker
                ),
                projection: .init(
                    userProjectionWorkers: userProjectionWorkers,
                    databaseWorkAdmission: databaseWorkAdmission,
                    snapshotArtifactBuilders: snapshotArtifactBuilders,
                    messageProjectionStateBodyCompactionWorkers: messageProjectionStateBodyCompactionWorkers
                ),
                maintenance: .init(
                    revokedDeviceProjectionCleanupWorker: revokedDeviceProjectionCleanupWorker,
                    controlPlaneHousekeepingWorker: controlPlaneHousekeepingWorker,
                    syncLogCompactionWorkers: syncLogCompactionWorkers,
                    roomMaintenanceWorkers: roomMaintenanceWorkers,
                    syncHousekeepingWorkers: syncHousekeepingWorkers,
                    projectionVersionGCWorkers: projectionVersionGCWorkers,
                    personalEventGCWorkers: personalEventGCWorkers,
                    messageProjectionStateGCWorkers: messageProjectionStateGCWorkers,
                    forwardBackgroundDatabases: forwardBackgroundDatabases,
                    directRoomProfilePropagationWorker: directRoomProfilePropagationWorker,
                    readReceiptPreferencePropagationWorker: readReceiptPreferencePropagationWorker,
                    deviceRevocationWorker: deviceRevocationWorker,
                    moderationAuditRetentionWorker: moderationAuditRetentionWorker,
                    maintenanceGroupAudienceStore: maintenanceGroupAudienceStore,
                    roomCreation: roomCreation,
                    callTimeout: callTimeout,
                    mediaRetentionWorker: mediaRetentionWorker
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

private func databasePoolMetricClass(
    for role: V2PostgresWorkloadPoolBudget.Role
) -> V2DatabasePoolMetricClass {
    switch role {
    case .foreground: .foreground
    case .sync: .sync
    case .delivery: .delivery
    case .projection: .projection
    case .maintenance: .maintenance
    }
}

/// 库遥测边界的生产日志适配器。
///
/// 这些是结构化运维事件，而不是高基数指标标签：
/// 其中不会包含房间、用户或消息标识，也不包含载荷、地址、令牌或凭据。
private struct V2ApplicationTelemetrySink: V2TelemetrySink {
    let logger: Logger
    let successSamplePermille: Int
    let slowCommandThresholdMilliseconds: Int
    let diagnosticLogLimiter: V2CommandDiagnosticLogLimiter

    func record(_ event: V2TelemetryEvent) async {
        switch event {
        case .gatewayCommand(let traceID, let command, let outcome, let rejection, let elapsedMilliseconds):
            guard shouldLogGatewayCommand(
                traceID: traceID,
                command: command,
                outcome: outcome,
                rejection: rejection,
                elapsedMilliseconds: elapsedMilliseconds
            ) else { return }
            logger.info("im_v2.gateway.command", metadata: [
                "trace_id": "\(traceID.uuidString)",
                "command": "\(command.rawValue)",
                "outcome": "\(outcome.rawValue)",
                "rejection": "\(rejection?.rawValue ?? "none")",
                "elapsed_ms": "\(elapsedMilliseconds)",
            ])

        }
    }

    private func shouldLogGatewayCommand(
        traceID: UUID,
        command: V2GatewayTelemetryCommand,
        outcome: V2GatewayTelemetryOutcome,
        rejection: V2GatewayTelemetryRejection?,
        elapsedMilliseconds: UInt64
    ) -> Bool {
        guard outcome == .accepted,
              elapsedMilliseconds < UInt64(slowCommandThresholdMilliseconds)
        else {
            return diagnosticLogLimiter.admit(
                command: command,
                outcome: outcome,
                rejection: rejection
            )
        }
        guard successSamplePermille > 0 else { return false }
        guard successSamplePermille < 1_000 else { return true }
        // 对 UUID 的 16 个原始字节计算 FNV，避免每次接受命令时
        // 都分配其 36 字符的字符串表示。
        var hash: UInt64 = 14_695_981_039_346_656_037
        withUnsafeBytes(of: traceID.uuid) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }
        return hash % 1_000 < UInt64(successSamplePermille)
    }
}
