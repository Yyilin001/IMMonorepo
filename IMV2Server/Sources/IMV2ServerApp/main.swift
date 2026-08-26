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

@main
enum IMV2ServerApp {
    static func main() async throws {
        let configuration = try V2GatewayRuntimeConfiguration(environment: ProcessRuntimeEnvironment())
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
        var natsGroupWakeBroker: V2NATSGroupEventWakeBroker?
        var natsLiveActivityBroker: V2NATSLiveActivityBroker?
        do {
            let databaseEventLoops = Array(applicationEventLoops.makeIterator())
            guard databaseEventLoops.count == configuration.databasePolicy.eventLoopThreads else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let physicalDatabaseURLs = Array(Set(
                [configuration.databaseURL]
                    + configuration.userShardStorage.map(\.databaseURL)
                    + configuration.roomShardStorage.map(\.databaseURL)
            )).sorted()
            var databasesByRole: [
                V2PostgresWorkloadPoolBudget.Role: [String: any Database]
            ] = [:]
            let databaseRoles: [V2PostgresWorkloadPoolBudget.Role] =
                configuration.databaseWorkloadPoolIsolationEnabled
                    ? V2PostgresWorkloadPoolBudget.Role.allCases
                    : [.foreground]
            for (urlIndex, url) in physicalDatabaseURLs.enumerated() {
                for role in databaseRoles {
                    let identifier: DatabaseID = role == .foreground && url == configuration.databaseURL
                        ? .psql
                        : DatabaseID(string: "gateway-\(role.rawValue)-pool-\(urlIndex)")
                    app.databases.use(
                        try postgresDatabaseConfiguration(
                            url: url,
                            policy: configuration.databasePolicy,
                            maximumConnectionsPerEventLoop:
                                configuration.databaseWorkloadPoolIsolationEnabled
                                    ? configuration.databaseWorkloadPoolBudget
                                        .connectionsPerEventLoop(for: role)
                                    : configuration.databasePolicy
                                        .maximumConnectionsPerEventLoop
                        ),
                        as: identifier
                    )
                    let eventLoopPool = try V2ApplicationEventLoopDatabasePool(
                        application: app,
                        identifier: identifier,
                        eventLoops: databaseEventLoops
                    )
                    // Prove session GUCs on every EventLoop-owned pool. A
                    // single long-lived `app.db(identifier)` handle would bind
                    // all Stores to only one pool and make the configured
                    // per-EventLoop connection multiplication fictitious.
                    for eventLoopDatabase in eventLoopPool.eventLoopDatabases {
                        try await V2PostgresSessionReadiness.verify(
                            database: eventLoopDatabase,
                            policy: configuration.databasePolicy
                        )
                    }
                    databasesByRole[role, default: [:]][url] = eventLoopPool.database
                }
            }
            func databaseForRole(
                for role: V2PostgresWorkloadPoolBudget.Role,
                url: String
            ) -> (any Database)? {
                databasesByRole[role]?[url] ?? databasesByRole[.foreground]?[url]
            }
            guard let database = databaseForRole(for: .foreground, url: configuration.databaseURL),
                  let syncControlDatabase = databaseForRole(for: .sync, url: configuration.databaseURL),
                  let deliveryDatabase = databaseForRole(for: .delivery, url: configuration.databaseURL),
                  let maintenanceDatabase = databaseForRole(for: .maintenance, url: configuration.databaseURL)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }

            // Schema readiness is topology state rather than work-class
            // state. Verify each configured schema once through its foreground
            // pool after every role pool has proven its session GUCs.
            try await V2SchemaReadiness.verify(database: database)
            for storage in configuration.userShardStorage {
                guard let shardDatabase = databaseForRole(for: .foreground, url: storage.databaseURL)
                else { throw V2RoomWriteStoreError.corruptPersistenceState }
                try await V2SchemaReadiness.verify(
                    database: shardDatabase, schema: storage.schema
                )
            }
            // A room shard must prove the same canonical schema before the
            // process can later route a durable room command there. This is a
            // startup topology fence, not a lazy first-request check.
            var verifiedRoomLocations: Set<String> = []
            for storage in configuration.roomShardStorage {
                let key = storage.databaseURL + "\u{0}" + storage.schema
                guard verifiedRoomLocations.insert(key).inserted else { continue }
                guard let shardDatabase = databaseForRole(for: .foreground, url: storage.databaseURL)
                else { throw V2RoomWriteStoreError.corruptPersistenceState }
                try await V2SchemaReadiness.verify(
                    database: shardDatabase, schema: storage.schema
                )
                try await V2CapacityProfileReadiness.verify(
                    database: shardDatabase,
                    schema: storage.schema,
                    profile: configuration.capacityProfile
                )
            }
            func shardLocations(
                for role: V2PostgresWorkloadPoolBudget.Role
            ) throws -> [V2UserShardStorageLocation] {
                try configuration.userShardStorage.map { storage in
                    guard let shardDatabase = databaseForRole(for: role, url: storage.databaseURL)
                    else { throw V2RoomWriteStoreError.corruptPersistenceState }
                    return try .init(
                        bucket: storage.bucket,
                        database: shardDatabase,
                        schema: storage.schema
                    )
                }
            }
            let foregroundShardLocations = try shardLocations(for: .foreground)
            let syncShardLocations = try shardLocations(for: .sync)
            let deliveryShardLocations = try shardLocations(for: .delivery)
            let projectionShardLocations = try shardLocations(for: .projection)
            let maintenanceShardLocations = try shardLocations(for: .maintenance)
            let userShardStorage = try V2StaticUserShardStorageRegistry(
                locations: foregroundShardLocations
            )
            var roomShardDatabases: [String: any Database] = [:]
            for storage in configuration.roomShardStorage {
                guard let shardDatabase = databaseForRole(
                    for: .foreground, url: storage.databaseURL
                ) else { throw V2RoomWriteStoreError.corruptPersistenceState }
                roomShardDatabases[storage.shardID] = shardDatabase
            }
            let syncUserShardStorage = try V2StaticUserShardStorageRegistry(
                locations: syncShardLocations
            )
            let deliveryUserShardStorage = try V2StaticUserShardStorageRegistry(
                locations: deliveryShardLocations
            )
            let maintenanceUserShardStorage = try V2StaticUserShardStorageRegistry(
                locations: maintenanceShardLocations
            )
            let coLocatedControlBuckets = Set(configuration.userShardStorage.compactMap { storage in
                storage.databaseURL == configuration.databaseURL && storage.schema == "im_v2" ? storage.bucket : nil
            })
            var seenSyncStores: Set<String> = []
            var snapshotArtifactBuilders: [PostgresV2SnapshotArtifactBuilder] = []
            var userProjectionWorkers: [PostgresV2UserProjectionWorker] = []
            var messageProjectionBackfillWorkers: [PostgresV2MessageProjectionBackfillWorker] = []
            var messageProjectionStateBodyCompactionWorkers:
                [PostgresV2MessageProjectionStateBodyCompactionWorker] = []
            var fanoutPayloadReferenceBackfillWorkers: [PostgresV2FanoutPayloadReferenceBackfillWorker] = []
            var projectionVersionGCWorkers: [PostgresV2ProjectionVersionGCWorker] = []
            var messageProjectionStateGCWorkers: [PostgresV2MessageProjectionStateGCWorker] = []
            var syncLogCompactionWorkers: [PostgresV2UserSyncLogCompactionWorker] = []
            var userShardMetricsSources: [any V2DurableWorkMetricsSource] = []
            let syncHousekeepingWorkers: [V2SyncHousekeepingWorker] = zip(
                configuration.userShardStorage,
                maintenanceShardLocations
            ).compactMap { storage, maintenanceLocation in
                let key = storage.databaseURL + "\u{0}" + storage.schema
                guard seenSyncStores.insert(key).inserted else { return nil }
                guard let projectionLocation = projectionShardLocations.first(where: {
                    $0.bucket == storage.bucket
                }) else { return nil }
                snapshotArtifactBuilders.append(.init(
                    database: projectionLocation.database,
                    schema: projectionLocation.schema,
                    messageReadMode: configuration.messageProjectionReadMode
                ))
                userProjectionWorkers.append(.init(
                    database: projectionLocation.database, schema: projectionLocation.schema,
                    batchSize: configuration.workerBatchSize,
                    retryPolicy: configuration.durableRetryPolicy,
                    messageWriteMode: configuration.messageProjectionWriteMode,
                    acceptedMessageBatchEnabled:
                        configuration.acceptedMessageProjectionBatchEnabled
                ))
                messageProjectionBackfillWorkers.append(.init(
                    database: maintenanceLocation.database,
                    schema: maintenanceLocation.schema,
                    compactInlinePayloads: configuration.messageProjectionWriteMode == .shared
                ))
                messageProjectionStateBodyCompactionWorkers.append(.init(
                    database: maintenanceLocation.database,
                    schema: maintenanceLocation.schema
                ))
                if configuration.fanoutPayloadWriteMode == .reference {
                    fanoutPayloadReferenceBackfillWorkers.append(.init(
                        database: maintenanceLocation.database,
                        schema: maintenanceLocation.schema
                    ))
                }
                projectionVersionGCWorkers.append(.init(
                    database: maintenanceLocation.database,
                    schema: maintenanceLocation.schema
                ))
                messageProjectionStateGCWorkers.append(.init(
                    database: maintenanceLocation.database,
                    schema: maintenanceLocation.schema,
                    retention: TimeInterval(configuration.messageProjectionStateRetentionSeconds)
                ))
                syncLogCompactionWorkers.append(.init(
                    database: maintenanceLocation.database, schema: maintenanceLocation.schema
                ))
                userShardMetricsSources.append(
                    PostgresV2UserShardDurableWorkMetricsSource(
                        database: maintenanceLocation.database, schema: maintenanceLocation.schema
                    )
                )
                return V2SyncHousekeepingWorker(
                    store: PostgresV2SyncHousekeepingStore(
                        database: maintenanceLocation.database,
                        schema: maintenanceLocation.schema
                    ),
                    projectionEffectRetention: TimeInterval(configuration.idempotencyRetentionSeconds)
                )
            }

            // Metrics intentionally use a distinct loopback-only HTTP
            // listener. The native TLS gateway and public media edge must
            // never expose operational metrics.
            app.http.server.configuration.hostname = configuration.metrics.host
            app.http.server.configuration.port = configuration.metrics.port
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
                )
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
            let databasePoolTopology: V2DatabasePoolTopologySnapshot
            let configuredHandleCount = configuration.databasePolicy.eventLoopThreads *
                physicalDatabaseURLs.count
            if configuration.databaseWorkloadPoolIsolationEnabled {
                databasePoolTopology = .init(
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
                databasePoolTopology = .init(pools: [
                    .init(
                        poolClass: .shared,
                        eventLoopHandles: configuredHandleCount,
                        connectionCeiling: configuredHandleCount *
                            configuration.databasePolicy.maximumConnectionsPerEventLoop
                    )
                ])
            }
            let prometheusTelemetry = V2PrometheusTelemetrySink()
            let transportMetrics = V2GatewayTransportMetrics()
            let directRoomLogShardAdmissionCredits:
                V2ShardAdmissionCommandCreditPool? =
                configuration.directRoomLogShardAdmissionCreditBatchSize > 0
                ? .init(
                    database: database,
                    batchSize: configuration.directRoomLogShardAdmissionCreditBatchSize
                )
                : nil
            let directRoomLogRoomAdmissionCredits:
                V2RoomAdmissionCommandCreditPool? =
                configuration.directRoomLogRoomAdmissionCreditBatchSize > 0
                ? .init(
                    database: database,
                    batchSize: configuration.directRoomLogRoomAdmissionCreditBatchSize
                )
                : nil
            // Shared across all co-located room writers. It is a bounded
            // hint cache only; PostgreSQL remains the policy and cursor
            // authority for every conditional append.
            let directRoomLogFastAppendCache = V2DirectRoomLogFastAppendCache(
                capacity: configuration.directRoomLogFastAppendCacheMaximumEntries,
                lifetime: .seconds(
                    configuration.directRoomLogFastAppendCacheLifetimeSeconds
                )
            )
            let directSendPolicyCache = V2DirectSendPolicyCache(
                capacity: configuration.directSendPolicyCacheMaximumEntries
            )
            let durableWorkMetrics = V2CachedDurableWorkMetricsSource(
                source: V2AggregateDurableWorkMetricsSource(sources: [
                    PostgresV2DurableWorkMetricsSource(
                        database: maintenanceDatabase,
                        gatewayNodeID: configuration.gatewayNodeID,
                        includesUserShardMetrics: false
                    )
                ] + userShardMetricsSources),
                minimumRefreshInterval: TimeInterval(
                    configuration.metricsMinimumRefreshIntervalMilliseconds
                ) / 1_000,
                maximumRefreshDuration: TimeInterval(
                    configuration.metricsRefreshTimeoutMilliseconds
                ) / 1_000
            )
            let telemetry = V2CompositeTelemetrySink([
                V2ApplicationTelemetrySink(
                    logger: app.logger,
                    successSamplePermille: configuration.commandSuccessLogSamplePermille,
                    slowCommandThresholdMilliseconds:
                        configuration.commandSlowLogThresholdMilliseconds
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
            let userShardMigrations = PostgresV2UserShardMigrationStore(
                database: deliveryDatabase
            )
            let userShardShadowForwarder = V2PostgresUserShardProjectionShadowForwarder(
                registry: userShardStorage,
                routeFence: userShardRouter,
                coLocatedControlBuckets: coLocatedControlBuckets
            )
            let maintenanceUserShardShadowForwarder =
                V2PostgresUserShardProjectionShadowForwarder(
                    registry: maintenanceUserShardStorage,
                    routeFence: maintenanceUserShardRouter,
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
            let roomShardRouter = V2PostgresRoomShardRouter(database: database)
            let roomPhysicalLocationKeys = Set(configuration.roomShardStorage.map {
                $0.databaseURL + "\u{0}" + $0.schema
            })
            let roomWriteStore: any V2AtomicRoomWriteBatchStore
            let directMessagingStore: any V2DirectMessagingStore
            let groupEventLogStore: any V2GroupEventLogStore
            if roomPhysicalLocationKeys.count == 1 {
                // Preserve the original single-owner hot path exactly. In
                // particular, its command-credit pools are shared with the
                // Gateway's pressure metrics and append batcher; creating a
                // second actor over the same PostgreSQL rows changes credit
                // refill/heat coordination without adding isolation.
                roomWriteStore = PostgresV2RoomWriteStore(
                    database: database,
                    strangerMessagePolicy: configuration.strangerMessagePolicy,
                    shadowForwarder: userShardShadowForwarder,
                    contentReviewMode: configuration.contentReviewMode,
                    directFanoutMode: configuration.directFanoutMode,
                    directRoomLogAdmissionMode: configuration.directRoomLogAdmissionMode,
                    payloadWriteMode: configuration.fanoutPayloadWriteMode,
                    directSendPolicyCache: directSendPolicyCache,
                    directRoomLogFastAppendCache: directRoomLogFastAppendCache,
                    shardAdmissionCommandCreditPool: directRoomLogShardAdmissionCredits,
                    roomAdmissionCommandCreditPool: directRoomLogRoomAdmissionCredits
                )
                directMessagingStore = PostgresV2DirectMessagingStore(
                    database: database, shadowForwarder: userShardShadowForwarder
                )
                groupEventLogStore = PostgresV2GroupEventLogStore(
                    database: database, directRoomLogEventCache: directRoomLogEventCache
                )
            } else {
                var roomWriteStoresByShard: [String: any V2AtomicRoomWriteBatchStore] = [:]
                var directMessagingStoresByShard: [String: any V2DirectMessagingStore] = [:]
                var groupEventLogStoresByShard: [String: any V2GroupEventLogStore] = [:]
                var roomStoreKeyByShard: [String: String] = [:]
                var roomWriteStoresByPhysicalLocation: [String: any V2AtomicRoomWriteBatchStore] = [:]
                var directMessagingStoresByPhysicalLocation: [String: any V2DirectMessagingStore] = [:]
                var groupEventLogStoresByPhysicalLocation: [String: any V2GroupEventLogStore] = [:]
                for storage in configuration.roomShardStorage {
                    guard let ownerDatabase = roomShardDatabases[storage.shardID] else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    let physicalLocationKey = storage.databaseURL + "\u{0}" + storage.schema
                    roomStoreKeyByShard[storage.shardID] = physicalLocationKey
                    if let existingWrite = roomWriteStoresByPhysicalLocation[physicalLocationKey],
                       let existingDirect = directMessagingStoresByPhysicalLocation[physicalLocationKey],
                       let existingEvents = groupEventLogStoresByPhysicalLocation[physicalLocationKey] {
                        roomWriteStoresByShard[storage.shardID] = existingWrite
                        directMessagingStoresByShard[storage.shardID] = existingDirect
                        groupEventLogStoresByShard[storage.shardID] = existingEvents
                        continue
                    }
                    let shardCredits: V2ShardAdmissionCommandCreditPool? =
                        configuration.directRoomLogShardAdmissionCreditBatchSize > 0
                        ? .init(database: ownerDatabase, batchSize: configuration.directRoomLogShardAdmissionCreditBatchSize)
                        : nil
                    let roomCredits: V2RoomAdmissionCommandCreditPool? =
                        configuration.directRoomLogRoomAdmissionCreditBatchSize > 0
                        ? .init(database: ownerDatabase, batchSize: configuration.directRoomLogRoomAdmissionCreditBatchSize)
                        : nil
                    let write = PostgresV2RoomWriteStore(database: ownerDatabase, strangerMessagePolicy: configuration.strangerMessagePolicy, shadowForwarder: userShardShadowForwarder, contentReviewMode: configuration.contentReviewMode, directFanoutMode: configuration.directFanoutMode, directRoomLogAdmissionMode: configuration.directRoomLogAdmissionMode, payloadWriteMode: configuration.fanoutPayloadWriteMode, directSendPolicyCache: directSendPolicyCache, directRoomLogFastAppendCache: directRoomLogFastAppendCache, shardAdmissionCommandCreditPool: shardCredits, roomAdmissionCommandCreditPool: roomCredits)
                    let direct = PostgresV2DirectMessagingStore(database: ownerDatabase, shadowForwarder: userShardShadowForwarder)
                    let events = PostgresV2GroupEventLogStore(database: ownerDatabase, directRoomLogEventCache: directRoomLogEventCache)
                    roomWriteStoresByPhysicalLocation[physicalLocationKey] = write
                    directMessagingStoresByPhysicalLocation[physicalLocationKey] = direct
                    groupEventLogStoresByPhysicalLocation[physicalLocationKey] = events
                    roomWriteStoresByShard[storage.shardID] = write
                    directMessagingStoresByShard[storage.shardID] = direct
                    groupEventLogStoresByShard[storage.shardID] = events
                }
                roomWriteStore = try V2RoutedRoomWriteStore(router: roomShardRouter, stores: roomWriteStoresByShard, physicalStoreKeyByShard: roomStoreKeyByShard)
                directMessagingStore = try V2RoutedDirectMessagingStore(router: roomShardRouter, ownerStores: directMessagingStoresByShard, controlStore: PostgresV2DirectMessagingStore(database: database, shadowForwarder: userShardShadowForwarder))
                groupEventLogStore = try V2RoutedGroupEventLogStore(router: roomShardRouter, stores: groupEventLogStoresByShard)
            }
            let directRoomLogAppendBatcher: (any V2SendMessageAdmission)?
            if configuration.directRoomLogAppendBatchSize > 0 {
                let appendBatchConfiguration = V2SendMessageAdmissionBatcher.Configuration(
                        maximumBatchSize: configuration.directRoomLogAppendBatchSize,
                        maximumDelay: .milliseconds(
                            configuration.directRoomLogAppendBatchMaximumDelayMilliseconds
                        ),
                        adaptiveDelayPolicy: {
                            guard let highActivityDelay = configuration
                                .directRoomLogAppendBatchHighActivityMaximumDelayMilliseconds,
                                  let minimumRequests = configuration
                                .directRoomLogAppendBatchHighActivityMinimumRequests,
                                  let windowMilliseconds = configuration
                                .directRoomLogAppendBatchHighActivityWindowMilliseconds
                            else { return nil }
                            return .init(
                                highActivityMaximumDelay: .milliseconds(highActivityDelay),
                                minimumRequestsInWindow: minimumRequests,
                                observationWindow: .milliseconds(windowMilliseconds)
                            )
                        }(),
                        maximumInFlightBatches:
                            configuration.directRoomLogAppendBatchMaximumInFlightBatches,
                        maximumPendingRequests:
                            configuration.foregroundWriteDatabaseWorkMaximumQueued
                )
                let appendDatabaseWorkAdmission = configuration.databaseWorkAdmissionEnabled
                    ? databaseWorkAdmission
                    : nil
                if configuration.directRoomLogAppendLaneCount == 1 {
                    directRoomLogAppendBatcher = V2SendMessageAdmissionBatcher(
                        store: roomWriteStore,
                        configuration: appendBatchConfiguration,
                        databaseWorkAdmission: appendDatabaseWorkAdmission
                    )
                } else {
                    directRoomLogAppendBatcher = V2ShardedSendMessageAdmissionBatcher(
                        store: roomWriteStore,
                        configuration: appendBatchConfiguration,
                        laneCount: configuration.directRoomLogAppendLaneCount,
                        databaseWorkAdmission: appendDatabaseWorkAdmission
                    )
                }
            } else {
                directRoomLogAppendBatcher = nil
            }
            // Register after the optional append batcher exists so the
            // loopback-only metrics endpoint can expose its aggregate queue
            // and adaptive-timer facts. The application has not started its
            // public listener yet, so this ordering changes no route timing.
            V2VaporMetricsRoutes.register(
                on: app,
                telemetry: prometheusTelemetry,
                connectionMetrics: connectionRegistry,
                transportMetrics: transportMetrics,
                durableWorkMetrics: durableWorkMetrics,
                runtimePressureMetrics: V2GatewayRuntimePressureMetricsSource(
                    databaseWorkAdmission: databaseWorkAdmission,
                    databasePools: databasePoolTopology,
                    syncWakeCoalescer: syncWakeCoalescer,
                    shardAdmissionCommandCredits: directRoomLogShardAdmissionCredits,
                    roomAdmissionCommandCredits: directRoomLogRoomAdmissionCredits,
                    directRoomLogAppendBatcher: directRoomLogAppendBatcher,
                    directSendPolicyCache: directSendPolicyCache,
                    directRoomLogFastAppendCache: directRoomLogFastAppendCache,
                    directRoomLogEventCache: directRoomLogEventCache,
                    connectionRegistry: connectionRegistry
                )
            )
            let sendMessage = V2SendMessageService(
                store: roomWriteStore,
                capacityProfile: configuration.capacityProfile,
                limits: configuration.messageLimits,
                batcher: directRoomLogAppendBatcher
            )
            let membership = V2RoomMembershipService(
                store: PostgresV2RoomMembershipStore(database: database),
                capacityProfile: configuration.capacityProfile
            )
            let withdrawal = V2MessageWithdrawalService(
                store: PostgresV2MessageWithdrawalStore(database: database),
                capacityProfile: configuration.capacityProfile
            )
            let reaction = V2MessageReactionService(
                store: PostgresV2MessageReactionStore(database: database),
                capacityProfile: configuration.capacityProfile
            )
            let edit = V2MessageEditService(
                store: PostgresV2MessageEditStore(database: database, contentReviewMode: configuration.contentReviewMode),
                capacityProfile: configuration.capacityProfile,
                maximumTextUTF8Bytes: configuration.messageLimits.maxUTF8Bytes
            )
            let readReceipt = V2ReadReceiptService(store: PostgresV2ReadReceiptStore(database: database, shadowForwarder: userShardShadowForwarder))
            let directMessaging = try V2DirectMessagingService(
                store: directMessagingStore,
                capacityProfile: configuration.capacityProfile,
                roomShardRouter: configuration.directRoomShardRouter
            )
            let groupMessaging = try V2GroupMessagingService(
                store: PostgresV2GroupMessagingStore(database: database),
                capacityProfile: configuration.capacityProfile,
                roomShardID: configuration.groupRoomShardID
            )
            let groupAudienceImports = V2GroupAudienceImportService(
                store: PostgresV2GroupAudienceImportStore(database: database),
                groupMessaging: groupMessaging
            )
            let maintenanceGroupMessaging = try V2GroupMessagingService(
                store: PostgresV2GroupMessagingStore(database: maintenanceDatabase),
                capacityProfile: configuration.capacityProfile,
                roomShardID: configuration.groupRoomShardID
            )
            let maintenanceGroupAudienceImports = V2GroupAudienceImportService(
                store: PostgresV2GroupAudienceImportStore(database: maintenanceDatabase),
                groupMessaging: maintenanceGroupMessaging
            )
            let groupEventLog = V2GroupEventLogService(
                store: groupEventLogStore,
                directRoomLogEventCache: directRoomLogEventCache
            )
            // Foreground availability is intentionally a best-effort hint.
            // The same broker adapter also serves the durable Hybrid wake
            // outbox, but the two contracts remain distinct at the command
            // handler boundary.
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
                    receiveWake: { [weak connectionRegistry] notification in
                        switch notification {
                        case .wake(let wake):
                            await connectionRegistry?.notifyForegroundGroupAvailable(
                                roomID: wake.roomID,
                                highWatermark: wake.highWatermark
                            )
                        case .directEvent(let event):
                            await connectionRegistry?.notifyForegroundDirectEvent(event)
                        }
                    }
                )
                natsGroupWakeBroker = broker
                await connectionRegistry.configureForegroundGroupInterestManager(broker)
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
                publisher: foregroundGroupEventHintPublisher
            )
            let membershipDirectory = V2RoomMembershipDirectoryService(
                store: PostgresV2RoomMembershipDirectoryStore(database: database)
            )
            let socialRelationships = V2SocialRelationshipService(
                store: PostgresV2SocialRelationshipStore(database: database, shadowForwarder: userShardShadowForwarder)
            )
            let moderation = V2ModerationService(
                store: PostgresV2ModerationStore(database: database),
                capacityProfile: configuration.capacityProfile
            )
            let contentReviewWorker: V2ContentReviewWorker?
            if configuration.contentReviewMode == .enabled,
               let safetyActor = configuration.contentReviewSafetyActorUserID {
                contentReviewWorker = try V2ContentReviewWorker(
                    store: PostgresV2ContentReviewStore(database: maintenanceDatabase),
                    reviewer: V2ConfiguredContentReviewer(
                        violatingTerms: configuration.contentReviewViolationTerms,
                        reviewTerms: configuration.contentReviewEscalationTerms
                    ),
                    moderation: .init(
                        store: PostgresV2ModerationStore(database: maintenanceDatabase),
                        safetyActorUserID: safetyActor,
                        capacityProfile: configuration.capacityProfile
                    ),
                    retryPolicy: configuration.durableRetryPolicy
                )
            } else {
                contentReviewWorker = nil
            }
            let conversationCapabilities = V2ConversationCapabilitiesService(
                store: PostgresV2ConversationCapabilitiesStore(database: database, shadowForwarder: userShardShadowForwarder)
            )
            let groupCapabilities = V2GroupCapabilitiesService(
                store: PostgresV2GroupCapabilitiesStore(database: database),
                capacityProfile: configuration.capacityProfile
            )
            let forwardMessages = V2ForwardMessagesService(
                database: database,
                writeStore: PostgresV2RoomWriteStore(
                    database: database,
                    strangerMessagePolicy: configuration.strangerMessagePolicy,
                    shadowForwarder: userShardShadowForwarder,
                    contentReviewMode: configuration.contentReviewMode,
                    directFanoutMode: configuration.directFanoutMode,
                    directRoomLogAdmissionMode: configuration.directRoomLogAdmissionMode,
                    payloadWriteMode: configuration.fanoutPayloadWriteMode,
                    directSendPolicyCache: directSendPolicyCache,
                    directRoomLogFastAppendCache: directRoomLogFastAppendCache,
                    shardAdmissionCommandCreditPool: directRoomLogShardAdmissionCredits,
                    roomAdmissionCommandCreditPool: directRoomLogRoomAdmissionCredits
                ),
                capacityProfile: configuration.capacityProfile,
                limits: configuration.messageLimits
            )
            let liveActivityStore = PostgresV2LiveActivityStore(database: database)
            let liveActivity = V2LiveActivityService(store: liveActivityStore)
            await connectionRegistry.configureLivePresenceLeases(liveActivityStore)
            await connectionRegistry.configureLiveActivityObservationAuthorizer(liveActivity)
            let handler = V2GatewayDomainCommandHandler(
                sendMessage: sendMessage,
                membership: membership,
                withdrawal: withdrawal,
                reaction: reaction,
                edit: edit,
                readReceipt: readReceipt,
                liveActivity: liveActivity,
                directMessaging: directMessaging,
                groupAudienceImports: groupAudienceImports,
                groupEventLog: groupEventLog,
                foregroundGroupEventHints: foregroundGroupEventHints,
                membershipDirectory: membershipDirectory,
                socialRelationships: socialRelationships,
                moderation: moderation,
                conversationCapabilities: conversationCapabilities,
                groupCapabilities: groupCapabilities,
                forwardMessages: forwardMessages,
                sync: .init(store: V2RoutedSyncStore(
                    registry: syncUserShardStorage, routeFence: syncUserShardRouter,
                    coLocatedControlBuckets: coLocatedControlBuckets,
                    capabilityProfile: configuration.capabilityProfile,
                    // Reserve bounded space for the envelope, opaque token,
                    // receipt, generation, capability profile, and protobuf
                    // length prefixes. Record sizing itself is exact.
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
            let fanoutDeliveryControlStore = PostgresV2FanoutDeliveryStore(
                database: deliveryDatabase,
                payloadWriteMode: configuration.fanoutPayloadWriteMode
            )
            let fanoutCompletionReleaseWorker = V2FanoutCompletionReleaseWorker(
                store: fanoutDeliveryControlStore
            )
            let durableFanoutPublisher = V2LocalFanoutPlanPublisher(
                planner: .init(
                    store: PostgresV2FanoutPlanStore(database: deliveryDatabase),
                    pageSize: configuration.capacityProfile.limits.maxEnumerationPageSize
                )
            )
            let fanoutPublisher: any V2FanoutPlanPublisher
            switch configuration.fanoutHint {
            case .durablePollingOnly: fanoutPublisher = durableFanoutPublisher
            case .nats(let nats):
                fanoutPublisher = V2BestEffortFanoutPlanHintPublisher(
                    durablePublisher: durableFanoutPublisher,
                    hintPublisher: V2NATSFanoutPlanHintPublisher(configuration: nats)
                )
            }
            let fanoutPipeline = V2FanoutPipeline(
                relay: .init(
                    store: PostgresV2RoomOutboxStore(database: deliveryDatabase),
                    publisher: fanoutPublisher,
                    retryPolicy: configuration.durableRetryPolicy
                ),
                deliveryWorkers: configuration.userShardStorage
                    .map(\.bucket)
                    .sorted()
                    .map { bucket in
                        let isCoLocated = coLocatedControlBuckets.contains(bucket)
                        return V2FanoutDeliveryWorker(
                            store: V2CrossStoreFanoutDeliveryStore(
                                control: fanoutDeliveryControlStore,
                                registry: deliveryUserShardStorage,
                                migrations: userShardMigrations,
                                coLocatedControlBucket: isCoLocated ? bucket : nil,
                                payloadWriteMode: configuration.fanoutPayloadWriteMode
                            ),
                            bucket: bucket,
                            liveNotifier: liveSyncNotifier,
                            router: deliveryUserShardRouter,
                            retryPolicy: configuration.durableRetryPolicy,
                            claimScheduler: .init(freshBurstPasses: configuration.fanoutFreshBurstPasses),
                            commitBatchSize: isCoLocated
                                ? configuration.fanoutDeliveryCommitBatchSize
                                : configuration.crossStoreFanoutDeliveryCommitBatchSize,
                            maximumConcurrentCommitBatches: isCoLocated
                                ? 1
                                : configuration.crossStoreFanoutDeliveryCommitConcurrency
                        )
                    },
                telemetry: telemetry
            )
            // The wake relay is not a delivery dependency: a failed or
            // duplicated publication only changes foreground latency because
            // Hybrid clients always cursor-pull the room event log.
            let groupEventWakeRelay = V2GroupEventWakeRelay(
                store: PostgresV2GroupEventWakeStore(database: deliveryDatabase),
                publisher: groupEventWakePublisher
            )
            let directRoomProfilePropagationWorker = V2DirectRoomProfilePropagationWorker(
                database: maintenanceDatabase,
                shadowForwarder: maintenanceUserShardShadowForwarder,
                liveNotifier: liveSyncNotifier
            )
            let readReceiptPreferencePropagationWorker = V2ReadReceiptPreferencePropagationWorker(
                database: maintenanceDatabase,
                shadowForwarder: maintenanceUserShardShadowForwarder,
                liveNotifier: liveSyncNotifier
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
                store: PostgresV2ModerationAuditRetentionStore(database: maintenanceDatabase)
            )
            let mediaRetentionWorker = try V2MediaRetentionWorker(
                store: PostgresV2MediaRetentionStore(database: maintenanceDatabase),
                withdrawnRetention: TimeInterval(configuration.mediaWithdrawnRetentionSeconds)
            )
            let controlPlaneHousekeepingWorker = V2ControlPlaneHousekeepingWorker(
                store: PostgresV2ControlPlaneHousekeepingStore(database: maintenanceDatabase),
                idempotencyRetention: TimeInterval(configuration.idempotencyRetentionSeconds)
            )
            let userShardMigrationRetentionWorker = V2UserShardMigrationRetentionWorker(
                store: PostgresV2UserShardMigrationStore(database: maintenanceDatabase),
                cleaner: V2UserShardProjectionSourceCleaner(
                    registry: maintenanceUserShardStorage
                )
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
                    commandAdmission: commandRateLimiter
                )
                return .init(frameLimits: configuration.frameLimits, session: session, handler: handler, registry: connectionRegistry)
            }
            let server = try V2TLSGatewayServer(
                configuration: configuration.tls,
                connectionFactory: factory,
                maximumConnections: configuration.maximumConnections,
                maximumQueuedInboundBytes: configuration.maximumQueuedInboundBytes,
                maximumQueuedInboundChunks: configuration.maximumQueuedInboundChunks,
                authenticationTimeoutMilliseconds: configuration.authenticationTimeoutMilliseconds,
                idleTimeoutMilliseconds: configuration.idleTimeoutMilliseconds,
                transportMetrics: transportMetrics
            )
            // A newly named replica has no live sockets yet. Record its
            // current revocation watermark before any client can authenticate
            // so it never rescans the append-only history on scale-out. An
            // existing cursor is deliberately preserved for crash recovery.
            try await deviceRevocationWorker.initializeForStartup()
            // Storage cleanup has a separate cluster-global cursor and starts
            // at zero on first deployment. This closes the outage window in
            // which no gateway existed to observe a historical revocation.
            try await revokedDeviceProjectionCleanupWorker.initializeForStartup()
            try await server.bind()
            app.logger.notice("IM V2 TLS gateway bound", metadata: ["host": "\(configuration.tls.host)", "port": "\(configuration.tls.port)"])
            do {
                try await app.startup()
            } catch {
                try? await server.shutdown()
                throw error
            }
            app.logger.notice("IM V2 metrics listener bound", metadata: ["host": "\(configuration.metrics.host)", "port": "\(configuration.metrics.port)"])
            let logger = app.logger
            let maintenanceCadence = try V2MaintenanceCadence(
                intervalMilliseconds: configuration.maintenancePollIntervalMilliseconds
            )
            // Foreground metadata publication is deliberately owned outside
            // the command handler. An optional broker or socket stall can
            // therefore never extend the committed-message response path.
            let foregroundGroupEventHintTask = Task {
                await foregroundGroupEventHints.run()
            }
            let directRoomLogEventCacheTask = Task {
                await directRoomLogEventCache?.run()
            }
            let syncWakeCoalescerTask = Task {
                if configuration.syncWakeCoalescingEnabled {
                    await syncWakeCoalescer.run()
                }
            }
            // `SKIP LOCKED` checkpoint claims allow several bounded workers
            // per physical store while preserving strict sequence for one
            // user. Snapshot publication keeps one loop per store because it
            // is a heavier, separately fenced artifact build.
            let userProjectionTasks = userProjectionWorkers.flatMap { worker in
                (0 ..< configuration.userProjectionConcurrency).map { workerIndex in
                    Task {
                        var cadence = V2BoundedBusyDrainCadence(
                            minimumIdleIntervalMilliseconds:
                                configuration.workerPollIntervalMilliseconds,
                            maximumConsecutiveBusyPasses: configuration
                                .userProjectionMaximumConsecutiveBusyPasses,
                            maximumConsecutiveBusyDurationMilliseconds: configuration
                                .userProjectionBusyDrainBudgetMilliseconds
                        )
                        while !Task.isCancelled {
                            // One reserved projector always guarantees durable
                            // convergence. Additional lanes are opportunistic:
                            // they yield while foreground or Sync is already
                            // waiting at the database admission boundary.
                            if workerIndex > 0,
                               configuration.databaseWorkAdmissionEnabled,
                               await databaseWorkAdmission.snapshot().queued > 0 {
                                do {
                                    try await Task.sleep(for: .milliseconds(
                                        configuration.workerPollIntervalMilliseconds
                                    ))
                                } catch {
                                    break
                                }
                                continue
                            }
                            let passStartedAt = ContinuousClock.now
                            var didWork = false
                            do {
                                didWork = try await worker.runOnce().claimed
                            } catch is CancellationError {
                                break
                            } catch {
                                logger.error("IM V2 user snapshot projection failed; retrying")
                            }
                            let passDuration = passStartedAt.duration(to: .now)
                            switch cadence.decisionAfterPass(
                                didWork: didWork,
                                passDuration: passDuration
                            ) {
                            case .continueImmediately:
                                continue
                            case .yield:
                                await Task.yield()
                            case .sleep(let duration):
                                do {
                                    try await Task.sleep(for: duration)
                                } catch {
                                    break
                                }
                            }
                        }
                    }
                }
            }
            let snapshotArtifactTasks = snapshotArtifactBuilders.map { builder in
                Task {
                    var cadence = V2AdaptiveWorkerCadence(
                        minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
                    )
                    while !Task.isCancelled {
                        var didWork = false
                        do {
                            didWork = try await builder.runOnce().claimed
                        } catch is CancellationError {
                            break
                        } catch {
                            logger.error("IM V2 snapshot artifact build failed; retrying")
                        }
                        do {
                            try await Task.sleep(for: cadence.delayAfterPass(didWork: didWork))
                        } catch {
                            break
                        }
                    }
                }
            }
            // Historical conversion is isolated from latency-sensitive user
            // projection. Busy batches drain continuously; an empty shard
            // backs off to a cheap bounded poll.
            let messageProjectionBackfillTasks = messageProjectionBackfillWorkers.map { worker in
                Task {
                    var cadence = V2AdaptiveWorkerCadence(
                        minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
                    )
                    while !Task.isCancelled {
                        var didWork = false
                        do {
                            let report = try await worker.runOnce(
                                limit: cadence.claimLimit(
                                    configuredLimit: configuration.workerBatchSize
                                )
                            )
                            didWork = report.didWork
                        } catch is CancellationError {
                            break
                        } catch {
                            logger.error("IM V2 message projection backfill failed; retrying")
                        }
                        do {
                            try await Task.sleep(for: cadence.delayAfterPass(didWork: didWork))
                        } catch {
                            break
                        }
                    }
                }
            }
            let messageProjectionStateBodyCompactionTasks =
                messageProjectionStateBodyCompactionWorkers.map { worker in
                    Task {
                        var cadence = V2AdaptiveWorkerCadence(
                            minimumIntervalMilliseconds:
                                configuration.workerPollIntervalMilliseconds
                        )
                        while !Task.isCancelled {
                            var didWork = false
                            do {
                                let report = try await worker.runOnce(
                                    limit: cadence.claimLimit(
                                        configuredLimit: configuration.workerBatchSize
                                    )
                                )
                                didWork = report.didWork
                            } catch is CancellationError {
                                break
                            } catch {
                                logger.error(
                                    "IM V2 message-state body compaction failed; retrying"
                                )
                            }
                            do {
                                try await Task.sleep(
                                    for: cadence.delayAfterPass(didWork: didWork)
                                )
                            } catch {
                                break
                            }
                        }
                    }
                }
            let fanoutPayloadReferenceBackfillTasks = fanoutPayloadReferenceBackfillWorkers.map { worker in
                Task {
                    var cadence = V2AdaptiveWorkerCadence(
                        minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
                    )
                    while !Task.isCancelled {
                        var didWork = false
                        do {
                            let report = try await worker.runOnce(
                                limit: cadence.claimLimit(
                                    configuredLimit: configuration.workerBatchSize
                                )
                            )
                            didWork = report.didWork
                        } catch is CancellationError {
                            break
                        } catch {
                            logger.error("IM V2 fan-out payload reference backfill failed; retrying")
                        }
                        do {
                            try await Task.sleep(for: cadence.delayAfterPass(didWork: didWork))
                        } catch {
                            break
                        }
                    }
                }
            }
            // Planning stays on its own cadence. A delivery pass may hold a
            // large, lease-fenced batch while it commits several bounded
            // transactions; serially placing planning behind it would add the
            // entire drain duration to a newly committed room event.
            let fanoutPlanningTask = Task {
                var cadence = V2AdaptiveWorkerCadence(
                    minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
                )
                while !Task.isCancelled {
                    var didWork = false
                    do {
                        // An idle planner lane publishes each claimed outbox
                        // item sequentially. Probe with one item so a burst
                        // cannot strand a full batch at idle concurrency; the
                        // next pass immediately restores both the configured
                        // batch and planner concurrency.
                        let report = try await fanoutPipeline.runRelayAndPlanOnce(
                            limit: cadence.claimLimit(configuredLimit: configuration.workerBatchSize),
                            concurrency: cadence.isIdle ? 1 : configuration.capacityProfile.limits.maxPlannerConcurrency
                        )
                        didWork = report.claimedCount > 0 || report.publishedCount > 0 ||
                            report.releasedCount > 0 || report.pausedCount > 0
                    } catch is CancellationError {
                        break
                    } catch {
                        logger.error("IM V2 fan-out relay and planner failed; retrying")
                    }
                    do {
                        // Hybrid wake publication is a latency hint and is
                        // independent from fan-out delivery correctness; keep
                        // it beside the short planning pass rather than after
                        // a potentially long user-projection drain.
                        let report = try await groupEventWakeRelay.runOnce(limit: configuration.workerBatchSize)
                        didWork = didWork || report.claimed > 0 || report.published > 0 || report.retryScheduled > 0
                    } catch is CancellationError {
                        break
                    } catch {
                        logger.error("IM V2 group-event wake relay failed; retrying")
                    }
                    do {
                        try await Task.sleep(for: cadence.delayAfterPass(didWork: didWork))
                    } catch is CancellationError {
                        break
                    } catch {
                        break
                    }
                }
            }
            // Delivery owns its own cadence. It must not wait behind Push,
            // revocation, profile propagation, or retention work: those
            // workers have independent durable retry semantics, while a
            // delayed delivery pass directly increases a standard group's
            // recipient-visible convergence age.
            let fanoutDeliveryTask = Task {
                var cadence = V2AdaptiveWorkerCadence(
                    minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
                )
                var concurrencyController = V2AdaptiveFanoutDeliveryConcurrency(
                    configuredMaximum: configuration.capacityProfile.limits.maxDeliveryConcurrency
                )
                while !Task.isCancelled {
                    var didWork = false
                    var selectedConcurrency = 1
                    do {
                        try Task.checkCancellation()
                        let pressure = await databaseWorkAdmission.snapshot()
                        selectedConcurrency = concurrencyController.concurrencyForPass(
                            isIdle: cadence.isIdle,
                            foregroundInFlight: pressure.foregroundInFlight,
                            foregroundQueued: pressure.foregroundQueued
                        )
                        let report = try await fanoutPipeline.runDeliveryOnce(
                            claimLimit: cadence.claimLimit(
                                configuredLimit: configuration.fanoutDeliveryClaimBatchSize
                            ),
                            concurrency: selectedConcurrency
                        )
                        didWork = report.claimedCount > 0 || report.committedCount > 0 ||
                            report.staleCount > 0 || report.staleRouteCount > 0 ||
                            report.releasedCount > 0 || report.pausedCount > 0
                        let pressureAfterPass = await databaseWorkAdmission.snapshot()
                        concurrencyController.observePass(
                            selectedConcurrency: selectedConcurrency,
                            claimedCount: report.claimedCount,
                            perLaneSaturationCount: configuration.fanoutDeliveryCommitBatchSize,
                            foregroundInFlight: pressureAfterPass.foregroundInFlight,
                            foregroundQueued: pressureAfterPass.foregroundQueued
                        )
                    } catch is CancellationError {
                        break
                    } catch {
                        let pressure = await databaseWorkAdmission.snapshot()
                        concurrencyController.observePass(
                            selectedConcurrency: selectedConcurrency,
                            claimedCount: 0,
                            perLaneSaturationCount: configuration.fanoutDeliveryCommitBatchSize,
                            foregroundInFlight: pressure.foregroundInFlight,
                            foregroundQueued: pressure.foregroundQueued,
                            failed: true
                        )
                        logger.error("IM V2 fan-out delivery failed; retrying")
                    }
                    do {
                        try await Task.sleep(for: cadence.delayAfterPass(didWork: didWork))
                    } catch is CancellationError {
                        break
                    } catch {
                        break
                    }
                }
            }
            // Projection completion and admission-capacity release are two
            // durable phases with disjoint lock sets. This independent polling
            // worker is the crash-recovery path for units committed immediately
            // before a process exit; an in-process wake is never required for
            // correctness.
            let fanoutCompletionReleaseTask = Task {
                var cadence = V2AdaptiveWorkerCadence(
                    minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
                )
                while !Task.isCancelled {
                    var didWork = false
                    do {
                        let report = try await fanoutCompletionReleaseWorker.runOnce(
                            limit: configuration.workerBatchSize
                        )
                        didWork = report.releasedCount > 0
                    } catch is CancellationError {
                        break
                    } catch {
                        logger.error("IM V2 fan-out completion release failed; retrying")
                    }
                    do {
                        try await Task.sleep(for: cadence.delayAfterPass(didWork: didWork))
                    } catch is CancellationError {
                        break
                    } catch {
                        break
                    }
                }
            }
            // Review is intentionally separate from fan-out and maintenance.
            // A slow external/OCR adapter must never increase the accepted
            // message's recipient delivery latency or delay media retention.
            let contentReviewTask = Task {
                guard let contentReviewWorker else { return }
                var cadence = V2AdaptiveWorkerCadence(
                    minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
                )
                while !Task.isCancelled {
                    var didWork = false
                    do {
                        let report = try await contentReviewWorker.runOnce(limit: configuration.workerBatchSize)
                        didWork = report.claimedCount > 0 || report.resolvedCount > 0 ||
                            report.redactedCount > 0 || report.releasedCount > 0
                    } catch is CancellationError {
                        break
                    } catch {
                        // No message text, identifiers, or provider response
                        // is included in this log line.
                        logger.error("IM V2 content-review worker failed; retrying")
                    }
                    do {
                        try await Task.sleep(for: cadence.delayAfterPass(didWork: didWork))
                    } catch is CancellationError {
                        break
                    } catch {
                        break
                    }
                }
            }
            // Push owns external-network latency and retry policy. It must not
            // serialize revocation, propagation, or database housekeeping.
            let pushWakeTask = Task {
                guard let pushWakeWorker else { return }
                var cadence = V2AdaptiveWorkerCadence(
                    minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
                )
                while !Task.isCancelled {
                    var didWork = false
                    do {
                        let report = try await pushWakeWorker.runOnce(limit: configuration.workerBatchSize)
                        didWork = report.admittedCount > 0 || report.sentCount > 0 || report.releasedCount > 0
                    } catch is CancellationError {
                        break
                    } catch {
                        // Provider and endpoint detail must never reach logs.
                        logger.error("IM V2 Push wake worker failed; retrying")
                    }
                    do {
                        try await Task.sleep(for: cadence.delayAfterPass(didWork: didWork))
                    } catch is CancellationError {
                        break
                    } catch {
                        break
                    }
                }
            }
            // Projection cleanup can cross a remote shard boundary. Give it
            // an independent retry cadence so one unavailable shard cannot
            // delay live-socket revocation or unrelated control-plane work.
            let revokedDeviceProjectionCleanupTask = Task {
                var cadence = V2AdaptiveWorkerCadence(
                    minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
                )
                while !Task.isCancelled {
                    var didWork = false
                    do {
                        didWork = try await revokedDeviceProjectionCleanupWorker.runOnce(
                            limit: configuration.workerBatchSize
                        ) > 0
                    } catch is CancellationError {
                        break
                    } catch {
                        logger.error("IM V2 revoked-device projection cleanup failed; retrying")
                    }
                    do {
                        try await Task.sleep(for: cadence.delayAfterPass(didWork: didWork))
                    } catch is CancellationError {
                        break
                    } catch {
                        break
                    }
                }
            }
            // These tables grow with message throughput rather than operator
            // activity. Keep their catch-up capacity independent of the
            // minute-scale retention sweep while bounding executor and
            // maintenance-pool occupancy after every database transaction.
            let controlPlaneHousekeepingTask = Task {
                var cadence = V2BoundedBusyDrainCadence(
                    minimumIdleIntervalMilliseconds:
                        configuration.backlogMaintenanceIdlePollIntervalMilliseconds,
                    maximumConsecutiveBusyPasses:
                        configuration.backlogMaintenanceMaximumConsecutiveBusyPasses,
                    maximumConsecutiveBusyDurationMilliseconds:
                        configuration.backlogMaintenanceBusyDrainBudgetMilliseconds
                )
                while !Task.isCancelled {
                    let passStartedAt = ContinuousClock.now
                    var didWork = false
                    do {
                        didWork = try await controlPlaneHousekeepingWorker.runOnce(
                            limit: configuration.workerBatchSize
                        ).didWork
                    } catch is CancellationError {
                        break
                    } catch {
                        logger.error("IM V2 control-plane housekeeping failed; retrying")
                    }
                    switch cadence.decisionAfterPass(
                        didWork: didWork,
                        passDuration: passStartedAt.duration(to: .now)
                    ) {
                    case .continueImmediately:
                        continue
                    case .yield:
                        await Task.yield()
                    case .sleep(let duration):
                        do {
                            try await Task.sleep(for: duration)
                        } catch {
                            break
                        }
                    }
                }
            }
            let syncLogCompactionTask = Task {
                var cadence = V2BoundedBusyDrainCadence(
                    minimumIdleIntervalMilliseconds:
                        configuration.backlogMaintenanceIdlePollIntervalMilliseconds,
                    maximumConsecutiveBusyPasses:
                        configuration.backlogMaintenanceMaximumConsecutiveBusyPasses,
                    maximumConsecutiveBusyDurationMilliseconds:
                        configuration.backlogMaintenanceBusyDrainBudgetMilliseconds
                )
                while !Task.isCancelled {
                    let passStartedAt = ContinuousClock.now
                    var didWork = false
                    for worker in syncLogCompactionWorkers {
                        do {
                            let report = try await worker.runOnce(
                                userLimit: min(8, configuration.workerBatchSize),
                                rowLimit: configuration.workerBatchSize
                            )
                            didWork = didWork || report.didWork
                        } catch is CancellationError {
                            return
                        } catch {
                            logger.error("IM V2 user sync-log compaction failed; retrying")
                        }
                    }
                    switch cadence.decisionAfterPass(
                        didWork: didWork,
                        passDuration: passStartedAt.duration(to: .now)
                    ) {
                    case .continueImmediately:
                        continue
                    case .yield:
                        await Task.yield()
                    case .sleep(let duration):
                        do {
                            try await Task.sleep(for: duration)
                        } catch {
                            break
                        }
                    }
                }
            }
            let maintenanceTask = Task {
                var nextMaintenanceAt: Date?
                var cadence = V2AdaptiveWorkerCadence(
                    minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
                )
                while !Task.isCancelled {
                    var didWork = false
                    do {
                        // Profile changes are a distinct direct-contact
                        // graph from room-event fan-out. Its work budget is
                        // per recipient, so one very connected account never
                        // turns a maintenance tick into an unbounded loop.
                        let report = try await directRoomProfilePropagationWorker.runOnce(
                            limit: configuration.workerBatchSize
                        )
                        didWork = report.claimedUpdateCount > 0 || report.projectedRecipientCount > 0 ||
                            report.completedUpdateCount > 0
                    } catch is CancellationError {
                        break
                    } catch {
                        logger.error("IM V2 direct-profile propagation failed; retrying")
                    }
                    do {
                        let report = try await readReceiptPreferencePropagationWorker.runOnce(
                            limit: configuration.workerBatchSize
                        )
                        didWork = didWork || report.claimedOperationCount > 0 ||
                            report.projectedRoomCount > 0 || report.completedOperationCount > 0 ||
                            report.releasedOperationCount > 0 || report.pausedOperationCount > 0
                    } catch is CancellationError {
                        break
                    } catch {
                        logger.error("IM V2 read-receipt preference propagation failed; retrying")
                    }
                    do {
                        didWork = try await deviceRevocationWorker.runOnce(limit: configuration.workerBatchSize) > 0 || didWork
                    } catch is CancellationError {
                        break
                    } catch {
                        logger.error("IM V2 device revocation worker failed; retrying")
                    }
                    let maintenanceNow = Date()
                    if maintenanceCadence.isDue(now: maintenanceNow, nextScheduledAt: nextMaintenanceAt) {
                        do {
                            _ = try await moderationAuditRetentionWorker.runOnce(limit: configuration.workerBatchSize)
                        } catch is CancellationError {
                            break
                        } catch {
                            logger.error("IM V2 moderation-audit retention worker failed; retrying")
                        }
                        do {
                            // Staged creation drafts own potentially large
                            // temporary audiences. Reclaim them on the same
                            // bounded maintenance cadence as other retention
                            // work; cancellation and actor-local admission
                            // also perform immediate targeted cleanup.
                            _ = try await maintenanceGroupAudienceImports.purgeExpired(
                                limit: configuration.workerBatchSize
                            )
                        } catch is CancellationError {
                            return
                        } catch {
                            logger.error("IM V2 group creation draft cleanup failed; retrying")
                        }
                        do {
                            let report = try await maintenanceGroupAudienceImports.recoverFinalizing(
                                limit: configuration.workerBatchSize
                            )
                            if report.failedCount > 0 {
                                logger.warning("IM V2 group creation finalization recovery left retryable drafts")
                            }
                        } catch is CancellationError {
                            break
                        } catch {
                            logger.error("IM V2 group creation finalization recovery failed; retrying")
                        }
                        do {
                            _ = try await mediaRetentionWorker.runOnce(limit: configuration.workerBatchSize)
                        } catch is CancellationError {
                            break
                        } catch {
                            logger.error("IM V2 media retention worker failed; retrying")
                        }
                        for worker in syncHousekeepingWorkers {
                            do {
                                _ = try await worker.runOnce(limit: configuration.workerBatchSize)
                            } catch is CancellationError {
                                return
                            } catch {
                                logger.error("IM V2 sync capability housekeeping failed; retrying")
                            }
                        }
                        for worker in projectionVersionGCWorkers {
                            do {
                                _ = try await worker.runOnce(limit: configuration.workerBatchSize)
                            } catch is CancellationError {
                                return
                            } catch {
                                logger.error("IM V2 snapshot projection history cleanup failed; retrying")
                            }
                        }
                        for worker in messageProjectionStateGCWorkers {
                            do {
                                _ = try await worker.runOnce(limit: configuration.workerBatchSize)
                            } catch is CancellationError {
                                return
                            } catch {
                                logger.error("IM V2 shared message-state cleanup failed; retrying")
                            }
                        }
                        do {
                            _ = try await userShardMigrationRetentionWorker.runOnce(limit: configuration.workerBatchSize)
                        } catch is CancellationError {
                            break
                        } catch {
                            // The cleaner is idempotent and retains a fenced
                            // claim through expiry on failure; never include
                            // source/target details in process logs.
                            logger.error("IM V2 user-shard retention worker failed; retrying")
                        }
                        nextMaintenanceAt = maintenanceCadence.nextScheduledAt(after: maintenanceNow)
                    }
                    do {
                        try await Task.sleep(for: cadence.delayAfterPass(didWork: didWork))
                    } catch is CancellationError {
                        break
                    } catch {
                        break
                    }
                }
            }
            await TerminationSignal.wait()
            userProjectionTasks.forEach { $0.cancel() }
            snapshotArtifactTasks.forEach { $0.cancel() }
            messageProjectionBackfillTasks.forEach { $0.cancel() }
            messageProjectionStateBodyCompactionTasks.forEach { $0.cancel() }
            fanoutPayloadReferenceBackfillTasks.forEach { $0.cancel() }
            fanoutPlanningTask.cancel()
            fanoutDeliveryTask.cancel()
            fanoutCompletionReleaseTask.cancel()
            contentReviewTask.cancel()
            pushWakeTask.cancel()
            revokedDeviceProjectionCleanupTask.cancel()
            controlPlaneHousekeepingTask.cancel()
            syncLogCompactionTask.cancel()
            maintenanceTask.cancel()
            foregroundGroupEventHintTask.cancel()
            directRoomLogEventCacheTask.cancel()
            syncWakeCoalescerTask.cancel()
            await foregroundGroupEventHints.finish()
            await directRoomLogEventCache?.finish()
            for task in userProjectionTasks { await task.value }
            for task in snapshotArtifactTasks { await task.value }
            for task in messageProjectionBackfillTasks { await task.value }
            for task in messageProjectionStateBodyCompactionTasks { await task.value }
            for task in fanoutPayloadReferenceBackfillTasks { await task.value }
            await fanoutPlanningTask.value
            await fanoutDeliveryTask.value
            await fanoutCompletionReleaseTask.value
            await contentReviewTask.value
            await pushWakeTask.value
            await revokedDeviceProjectionCleanupTask.value
            await controlPlaneHousekeepingTask.value
            await syncLogCompactionTask.value
            await maintenanceTask.value
            await foregroundGroupEventHintTask.value
            await directRoomLogEventCacheTask.value
            await syncWakeCoalescerTask.value
            await connectionRegistry.finishLivePresenceRenewals()
            await connectionRegistry.detachForegroundGroupInterestManager()
            await connectionRegistry.detachLiveActivityBroker()
            await natsLiveActivityBroker?.shutdown()
            await natsGroupWakeBroker?.shutdown()
            try await server.shutdown()
            try await app.asyncShutdown()
            try await applicationEventLoops.shutdownGracefully()
        } catch {
            await natsLiveActivityBroker?.shutdown()
            await natsGroupWakeBroker?.shutdown()
            try? await app.asyncShutdown()
            try? await applicationEventLoops.shutdownGracefully()
            throw error
        }
    }
}

private func postgresDatabaseConfiguration(
    url: String,
    policy: V2PostgresRuntimePolicy,
    maximumConnectionsPerEventLoop: Int
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
        maxConnectionsPerEventLoop: maximumConnectionsPerEventLoop,
        connectionPoolTimeout: .milliseconds(Int64(policy.poolTimeoutMilliseconds))
    )
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

private struct ProcessRuntimeEnvironment: V2RuntimeEnvironment {
    func value(for key: String) -> String? { ProcessInfo.processInfo.environment[key] }
}

/// Production log adapter for the library telemetry boundary. These are
/// structured operational events, not high-cardinality metric labels: they do
/// not include room/user/message IDs, payloads, URLs, tokens or credentials.
private struct V2ApplicationTelemetrySink: V2TelemetrySink {
    let logger: Logger
    let successSamplePermille: Int
    let slowCommandThresholdMilliseconds: Int

    func record(_ event: V2TelemetryEvent) async {
        switch event {
        case .gatewayCommand(let traceID, let command, let outcome, let rejection, let elapsedMilliseconds):
            guard shouldLogGatewayCommand(
                traceID: traceID,
                outcome: outcome,
                elapsedMilliseconds: elapsedMilliseconds
            ) else { return }
            logger.info("im_v2.gateway.command", metadata: [
                "trace_id": "\(traceID.uuidString)",
                "command": "\(command.rawValue)",
                "outcome": "\(outcome.rawValue)",
                "rejection": "\(rejection?.rawValue ?? "none")",
                "elapsed_ms": "\(elapsedMilliseconds)",
            ])
        case .fanoutProgress(let traceID, let claimedOutboxRows, let publishedOutboxRows, let releasedOutboxRows, let pausedOutboxRows, let claimedDeliveries, let committedDeliveries, let staleDeliveries, let staleRouteDeliveries, let releasedDeliveries, let pausedDeliveries, let relayElapsedMilliseconds, let deliveryElapsedMilliseconds, let elapsedMilliseconds):
            logger.info("im_v2.fanout.progress", metadata: [
                "trace_id": "\(traceID.uuidString)",
                "claimed_outbox_rows": "\(claimedOutboxRows)",
                "published_outbox_rows": "\(publishedOutboxRows)",
                "released_outbox_rows": "\(releasedOutboxRows)",
                "paused_outbox_rows": "\(pausedOutboxRows)",
                "claimed_deliveries": "\(claimedDeliveries)",
                "committed_deliveries": "\(committedDeliveries)",
                "stale_deliveries": "\(staleDeliveries)",
                "stale_route_deliveries": "\(staleRouteDeliveries)",
                "released_deliveries": "\(releasedDeliveries)",
                "paused_deliveries": "\(pausedDeliveries)",
                "relay_elapsed_ms": "\(relayElapsedMilliseconds)",
                "delivery_elapsed_ms": "\(deliveryElapsedMilliseconds)",
                "elapsed_ms": "\(elapsedMilliseconds)",
            ])
        case .fanoutFailure(let traceID, let stage, let elapsedMilliseconds):
            logger.error("im_v2.fanout.failure", metadata: [
                "trace_id": "\(traceID.uuidString)",
                "stage": "\(stage.rawValue)",
                "elapsed_ms": "\(elapsedMilliseconds)",
            ])
        }
    }

    private func shouldLogGatewayCommand(
        traceID: UUID,
        outcome: V2GatewayTelemetryOutcome,
        elapsedMilliseconds: UInt64
    ) -> Bool {
        guard outcome == .accepted,
              elapsedMilliseconds < UInt64(slowCommandThresholdMilliseconds)
        else { return true }
        guard successSamplePermille > 0 else { return false }
        guard successSamplePermille < 1_000 else { return true }
        // Swift's `Hasher` is intentionally randomized per process. FNV over
        // this already-random trace ID gives deterministic sampling without
        // making identity or payload data part of the decision.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in traceID.uuidString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash % 1_000 < UInt64(successSamplePermille)
    }
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
