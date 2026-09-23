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

@main
enum IMV2ServerApp {
    static func main() async {
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        let logger = Logger(label: "imv2.gateway")
        do {
            try await withLogger(logger) { _ in try await run(logger: logger) }
        } catch {
            logger.error("IM V2 gateway startup or shutdown failed")
            exit(EXIT_FAILURE)
        }
    }

    private static func run(logger: Logger) async throws {
        V2ProcessTerminationSignal.install()
        let configuration = try V2GatewayRuntimeConfiguration(environment: ProcessRuntimeEnvironment())
        let localMediaConfiguration = try V2LocalFilesystemMediaRuntimeConfiguration(environment: ProcessRuntimeEnvironment())
        let applicationEventLoops = MultiThreadedEventLoopGroup(
            numberOfThreads: configuration.databasePolicy.eventLoopThreads
        )
        let resources = V2DatabaseResources(eventLoopGroup: applicationEventLoops, logger: logger)
        let app: Application
        do {
            app = try await V2HTTPService.makeApplication(host: configuration.metrics.host, port: configuration.metrics.port)
        } catch {
            try? await resources.shutdown()
            try? await applicationEventLoops.shutdownGracefully()
            throw error
        }
        V2RedactedHTTPMiddlewareConfiguration.install(on: app)
        var natsGroupWakeBroker: V2NATSGroupEventWakeBroker?
        var sharedGroupWakeInterests: V2SharedGroupEventWakeInterests?
        var accountRoomChangeService: V2AccountRoomChangeService?
        var natsLiveActivityBroker: V2NATSLiveActivityBroker?
        var roomActorApplication: V2RoomActorApplication?
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
                    resources.databases.use(
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
                    let eventLoopPool = try V2EventLoopDatabasePool(
                        databases: resources.databases, logger: logger,
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

            // 独立控制连接持有路由围栏，数据连接先提交源端再镜像。
            // 即使关闭工作类别隔离也不能合并这两个池；总连接数已在配置阶段计入预算。
            let userStateRouteDatabaseID = DatabaseID(string: "gateway-user-state-route")
            resources.databases.use(try postgresDatabaseConfiguration(
                url: configuration.databaseURL,
                policy: configuration.databasePolicy,
                maximumConnectionsPerEventLoop: 1
            ), as: userStateRouteDatabaseID)
            let userStateRoutePool = try V2EventLoopDatabasePool(
                databases: resources.databases, logger: logger, identifier: userStateRouteDatabaseID, eventLoops: databaseEventLoops
            )
            for routeDatabase in userStateRoutePool.eventLoopDatabases {
                try await V2PostgresSessionReadiness.verify(database: routeDatabase, policy: configuration.databasePolicy)
            }
            let userStateRouter = V2PostgresUserShardRouter(database: userStateRoutePool.database)

            let directSendControlID = DatabaseID(string: "gateway-direct-send-control")
            resources.databases.use(try postgresDatabaseConfiguration(url: configuration.databaseURL,
                policy: configuration.databasePolicy,
                maximumConnectionsPerEventLoop: configuration.directSendControlConnectionsPerEventLoop),
                as: directSendControlID)
            let directSendControlPool = try V2EventLoopDatabasePool(databases: resources.databases, logger: logger,
                identifier: directSendControlID, eventLoops: databaseEventLoops)
            for policyDatabase in directSendControlPool.eventLoopDatabases {
                try await V2PostgresSessionReadiness.verify(database: policyDatabase, policy: configuration.databasePolicy)
            }

            // Resolution never borrows from reservation or policy-writer pools.
            // Control acknowledgement and owner abort can share this dedicated
            // physical pool: each transaction finishes before the next begins.
            var authorizationResolutionDatabases: [String: any Database] = [:]
            for (index, url) in configuration.directAuthorizationResolutionDatabaseURLs.enumerated() {
                let id = DatabaseID(string: "gateway-authorization-resolution-\(index)")
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
            let syncShardLocations = try shardLocations(for: .sync)
            let deliveryShardLocations = try shardLocations(for: .delivery)
            let projectionShardLocations = try shardLocations(for: .projection)
            let maintenanceShardLocations = try shardLocations(for: .maintenance)
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
            var projectionVersionGCWorkers: [PostgresV2ProjectionVersionGCWorker] = []
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
                    schema: projectionLocation.schema
                ))
                userProjectionWorkers.append(.init(
                    database: projectionLocation.database, schema: projectionLocation.schema,
                    batchSize: configuration.workerBatchSize,
                    retryPolicy: configuration.durableRetryPolicy
                ))
                projectionVersionGCWorkers.append(.init(
                    database: maintenanceLocation.database,
                    schema: maintenanceLocation.schema
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
            // Projection shadowing is post-commit cross-store delivery work.
            // Acquiring its route fence from the foreground pool can create a
            // pool self-starvation cycle during a first-message burst: every
            // append waits for a shadow fence while foreground connections are
            // occupied by the same burst. Advisory locks are database-global,
            // so the delivery pool preserves the exact cutover fence while
            // isolating this bounded follow-up work from message persistence.
            let userShardShadowForwarder = V2PostgresUserShardProjectionShadowForwarder(
                registry: deliveryUserShardStorage,
                routeFence: deliveryUserShardRouter,
                batchRouteFence: deliveryUserShardRouter,
                coLocatedControlBuckets: coLocatedControlBuckets
            )
            let maintenanceUserShardShadowForwarder =
                V2PostgresUserShardProjectionShadowForwarder(
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
            // Only the co-located fast path shares one admission-credit actor
            // with runtime metrics and special-account commands. A remote
            // single owner must take the routed path below; binding these
            // actors to the control database would reserve credits in the
            // wrong transaction domain.
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
                        directRoomLogAdmissionMode: configuration.directRoomLogAdmissionMode,
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
                        receiptShadowForwarder: userShardShadowForwarder,
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
                    direct: PostgresV2DirectMessagingStore(database: owner, shadowForwarder: userShardShadowForwarder),
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
                    shadowForwarder: userShardShadowForwarder), databaseWorkAdmission: databaseWorkAdmission,
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
                    PostgresV2DirectMessagingStore(database: database, shadowForwarder: userShardShadowForwarder,
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
                    connectionRegistry: connectionRegistry))
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
            // 会话摘要按房间分片扇出；未读与预览都由服务端聚合，客户端只回传游标。
            // Recovery scans use uncached control-plane routing, so a cached
            // owner cannot validate a stale physical copy after migration.
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
                // Include aliases as well as physical identity in the deployment
                // fingerprint. Connection material is hashed, never returned.
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
                store: PostgresV2SocialRelationshipStore(database: database, shadowForwarder: userShardShadowForwarder, authorizationCoordinator: directAuthorizationCoordinator)
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
                store: PostgresV2ConversationCapabilitiesStore(database: database, shadowForwarder: userShardShadowForwarder)
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
            // The wake relay is not a delivery dependency: a failed or
            // duplicated publication only changes foreground latency because
            // Clients always cursor-pull the room event log.
            let groupEventWakeRelay = V2GroupEventWakeRelay(
                store: groupEventWakeStore,
                publisher: groupEventWakePublisher
            )
            let directRoomProfilePropagationWorker = V2DirectRoomProfilePropagationWorker(
                database: maintenanceDatabase,
                shadowForwarder: maintenanceUserShardShadowForwarder,
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
                store: PostgresV2ControlPlaneHousekeepingStore(database: maintenanceDatabase, roomCleanupMode: .actorOwned),
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
            // A newly named replica has no live sockets yet. Record its
            // current revocation watermark before any client can authenticate
            // so it never rescans the append-only history on scale-out. An
            // existing cursor is deliberately preserved for crash recovery.
            try await deviceRevocationWorker.initializeForStartup()
            // Storage cleanup has a separate cluster-global cursor and starts
            // at zero on first deployment. This closes the outage window in
            // which no gateway existed to observe a historical revocation.
            try await revokedDeviceProjectionCleanupWorker.initializeForStartup()
            let forwardLogger = logger
            // Local-only byte adapter: the account edge and Gateway must share
            // this configured object root. Do not call prepare() here because
            // the edge owns startup cleanup of active upload staging files.
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
            var serverIsShutdown = false
            do {
                try await server.bind()
                logger.notice("IM V2 TLS gateway bound", metadata: ["host": "\(configuration.tls.host)", "port": "\(configuration.tls.port)"])
                try await V2HTTPService.withRunning(app, logger: logger,
                    gracefulShutdownDuration: .milliseconds(configuration.shutdownGraceMilliseconds),
                    waitForShutdown: V2ProcessTerminationSignal.wait) { shutdown in
                    logger.notice("IM V2 metrics listener bound", metadata: ["host": "\(configuration.metrics.host)", "port": "\(configuration.metrics.port)"])
                    let maintenanceCadence = try V2MaintenanceCadence(
                        intervalMilliseconds: configuration.maintenancePollIntervalMilliseconds
                    )
                    let forwardDeliveryTask = Task { await forwardRuntime.run() }
                    let directAuthorizationRecoveryTask = Task {
                        while !Task.isCancelled {
                            do {
                                let report = try await directAuthorizationCoordinator.recover(limit: 8, now: Date())
                                if report.deferred > 0 {
                                    logger.warning("IM V2 authorization recovery deferred owner work", metadata: ["count": "\(report.deferred)"])
                                }
                            } catch is CancellationError { break }
                            catch { logger.error("IM V2 authorization recovery failed; retrying") }
                            do { try await v2Sleep(for: .milliseconds(configuration.workerPollIntervalMilliseconds)) }
                            catch { break }
                        }
                    }

                    // Foreground metadata publication is deliberately owned outside
                    // the command handler. An optional broker or socket stall can
                    // therefore never extend the committed-message response path.
                    let foregroundGroupEventHintTask = Task {
                        await foregroundGroupEventHints.run()
                    }
                    let directRoomLogEventCacheTask = Task {
                        if let directRoomLogEventCache {
                            await directRoomLogEventCache.run()
                        }
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
                                            try await v2Sleep(for: .milliseconds(
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
                                            try await v2Sleep(for: duration)
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
                                    try await v2Sleep(for: cadence.delayAfterPass(didWork: didWork))
                                } catch {
                                    break
                                }
                            }
                        }
                    }
                    // Historical conversion is isolated from latency-sensitive user
                    // projection. Busy batches drain continuously; an empty shard
                    // backs off to a cheap bounded poll.
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
                    let userStateTasks = userStateWorkers.map { worker in
                        Task {
                            var cadence = V2AdaptiveWorkerCadence(
                                minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
                            )
                            while !Task.isCancelled {
                                var didWork = false
                                do {
                                    didWork = try await worker.runOnce(limit: min(1024, cadence.claimLimit(
                                        configuredLimit: configuration.workerBatchSize
                                    ))) > 0
                                } catch is CancellationError {
                                    break
                                } catch {
                                    logger.error("IM V2 personal state delivery failed; retrying")
                                }
                                do {
                                    try await v2Sleep(for: cadence.delayAfterPass(didWork: didWork))
                                } catch { break }
                            }
                        }
                    }
                    // Room event payloads already use the low-latency foreground
                    // dispatcher. The durable wake is a coalesced repair hint: give
                    // independent Gateway publishers time to deliver their payloads
                    // before announcing a later waterline to every active client.
                    let groupEventWakeTask = Task {
                        var cadence = V2AdaptiveWorkerCadence(
                            minimumIntervalMilliseconds:
                                configuration.groupEventWakePollIntervalMilliseconds
                        )
                        while !Task.isCancelled {
                            var didWork = false
                            do {
                                let report = try await groupEventWakeRelay.runOnce(
                                    limit: cadence.claimLimit(
                                        configuredLimit: configuration.workerBatchSize
                                    )
                                )
                                didWork = report.claimed > 0 || report.published > 0
                                    || report.retryScheduled > 0
                            } catch is CancellationError {
                                break
                            } catch {
                                logger.error("IM V2 group-event wake relay failed; retrying")
                            }
                            do {
                                try await Task.sleep(
                                    for: cadence.delayAfterPass(didWork: didWork)
                                )
                            } catch is CancellationError {
                                break
                            } catch {
                                break
                            }
                        }
                    }
                    // Review runs independently of personal state delivery and maintenance.
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
                                let report = try await contentReviewWorker.runOnce(
                                    limitPerOwner: configuration.workerBatchSize
                                )
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
                                try await v2Sleep(for: cadence.delayAfterPass(didWork: didWork))
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
                                try await v2Sleep(for: cadence.delayAfterPass(didWork: didWork))
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
                                try await v2Sleep(for: cadence.delayAfterPass(didWork: didWork))
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
                                    try await v2Sleep(for: duration)
                                } catch {
                                    break
                                }
                            }
                        }
                    }
                    let syncLogCompactionTask = Task { [syncLogCompactionWorkers] in
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
                                    try await v2Sleep(for: duration)
                                } catch {
                                    break
                                }
                            }
                        }
                    }
                    let maintenanceTask = Task { [roomMaintenanceWorkers, syncHousekeepingWorkers,
                        projectionVersionGCWorkers, personalEventGCWorkers,
                        messageProjectionStateGCWorkers, forwardBackgroundDatabases] in
                        var nextMaintenanceAt: ContinuousClock.Instant?
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
                            let maintenanceNow = ContinuousClock.now
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
                                    _ = try await maintenanceGroupAudienceStore.purgeExpired(
                                        now: Date(), limit: configuration.workerBatchSize
                                    )
                                } catch is CancellationError {
                                    return
                                } catch {
                                    logger.error("IM V2 group creation draft cleanup failed; retrying")
                                }
                                do {
                                    let report = try await roomCreation.recoverFinalizing(
                                        limit: configuration.workerBatchSize, deadline: .now + callTimeout.duration
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
                                for worker in roomMaintenanceWorkers {
                                    do {
                                        _ = try await worker.runRetention(limit: configuration.workerBatchSize,
                                            mode: configuration.roomLogRetentionMode,
                                            window: configuration.roomLogRetentionWindowSeconds)
                                        _ = try await worker.runBookkeeping(limit: configuration.workerBatchSize,
                                            retention: 7 * 86_400,
                                            idempotencyRetention: TimeInterval(configuration.idempotencyRetentionSeconds),
                                            rowLimitPerRoom: configuration.workerBatchSize)
                                    } catch is CancellationError {
                                        return
                                    } catch {
                                        logger.error("IM V2 room log retention worker failed; retrying")
                                    }
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
                                for worker in personalEventGCWorkers {
                                    do {
                                        _ = try await worker.runOnce(limit: configuration.workerBatchSize)
                                    } catch is CancellationError {
                                        return
                                    } catch {
                                        logger.error("IM V2 completed personal event cleanup failed; retrying")
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
                                for database in forwardBackgroundDatabases.values {
                                    do {
                                        _ = try await PostgresV2ForwardExportCompactor(database: database).runOnce(
                                            limit: min(1_024, max(1, configuration.workerBatchSize)))
                                    } catch is CancellationError {
                                        return
                                    } catch {
                                        logger.error("IM V2 terminal forward export compaction failed; retrying")
                                    }
                                    do {
                                        _ = try await PostgresV2ForwardInboxCompactor(database: database).runOnce(
                                            limit: min(1_024, max(1, configuration.workerBatchSize)))
                                    } catch is CancellationError {
                                        return
                                    } catch {
                                        logger.error("IM V2 terminal forward inbox compaction failed; retrying")
                                    }
                                }
                                nextMaintenanceAt = maintenanceCadence.nextScheduledAt(after: maintenanceNow)
                            }
                            do {
                                try await v2Sleep(for: cadence.delayAfterPass(didWork: didWork))
                            } catch is CancellationError {
                                break
                            } catch {
                                break
                            }
                        }
                    }
                    await shutdown.wait()
                    logger.notice("IM V2 shutdown signal received")
                    // Stop admitting new sockets before cancelling background work.
                    // Existing channels remain alive for the bounded cooperative
                    // drain and are closed by the full server shutdown below.
                    var listenerShutdownError: (any Error)?
                    do { try await server.stopAccepting() }
                    catch { listenerShutdownError = error }
                    logger.notice("IM V2 public listener closed")
                    userStateTasks.forEach { $0.cancel() }
                    userProjectionTasks.forEach { $0.cancel() }
                    snapshotArtifactTasks.forEach { $0.cancel() }
                    messageProjectionStateBodyCompactionTasks.forEach { $0.cancel() }
                    directAuthorizationRecoveryTask.cancel()
                    forwardDeliveryTask.cancel()
                    groupEventWakeTask.cancel()
                    contentReviewTask.cancel()
                    pushWakeTask.cancel()
                    revokedDeviceProjectionCleanupTask.cancel()
                    controlPlaneHousekeepingTask.cancel()
                    syncLogCompactionTask.cancel()
                    maintenanceTask.cancel()
                    foregroundGroupEventHintTask.cancel()
                    directRoomLogEventCacheTask.cancel()
                    syncWakeCoalescerTask.cancel()
                    foregroundGroupEventHints.finish()
                    await directRoomLogEventCache?.finish()
                    var serviceTasks: [Task<Void, Never>] = []
                    serviceTasks.append(contentsOf: userStateTasks)
                    serviceTasks.append(contentsOf: userProjectionTasks)
                    serviceTasks.append(contentsOf: snapshotArtifactTasks)
                    serviceTasks.append(contentsOf: messageProjectionStateBodyCompactionTasks)
                    serviceTasks.append(contentsOf: [
                        directAuthorizationRecoveryTask,
                        forwardDeliveryTask,
                        groupEventWakeTask,
                        contentReviewTask,
                        pushWakeTask,
                        revokedDeviceProjectionCleanupTask,
                        controlPlaneHousekeepingTask,
                        syncLogCompactionTask,
                        maintenanceTask,
                        foregroundGroupEventHintTask,
                        directRoomLogEventCacheTask,
                        syncWakeCoalescerTask,
                    ])
                    let drained = await v2WaitForTaskDrain(
                        serviceTasks,
                        timeout: .milliseconds(configuration.shutdownGraceMilliseconds)
                    )
                    guard drained else {
                        // A live worker may still own a transaction. Do not free its
                        // pools or event loops underneath it after the deadline.
                        logger.critical("IM V2 service-task drain exceeded its shutdown deadline")
                        exit(EXIT_FAILURE)
                    }
                    logger.notice("IM V2 service-task drain finished", metadata: ["drained": "\(drained)"])
                    await connectionRegistry.finishLivePresenceRenewals()
                    await connectionRegistry.detachForegroundGroupInterestManager()
                    await connectionRegistry.detachLiveActivityBroker()
                    await natsLiveActivityBroker?.shutdown()
                    await accountRoomChangeService?.shutdown()
                    await sharedGroupWakeInterests?.shutdown()
                    await natsGroupWakeBroker?.shutdown()
                    logger.notice("IM V2 broker and presence shutdown finished")
                    try await server.shutdown()
                    serverIsShutdown = true
                    guard try await actors.stop(deadline: .now + actorConfiguration.runtime.drainTimeout.duration) else {
                        logger.critical("IM V2 room actors still own work after shutdown deadline")
                        exit(EXIT_FAILURE)
                    }
                    logger.notice("IM V2 TLS event loops and room actors shut down")
                    if let listenerShutdownError { throw listenerShutdownError }
                }
            } catch {
                if !serverIsShutdown { try? await server.shutdown() }
                throw error
            }
            try await app.shutdown()
            logger.notice("IM V2 Vapor application shut down")
            try await resources.shutdown()
            try await applicationEventLoops.shutdownGracefully()
        } catch {
            if let roomActorApplication {
                do {
                    guard try await roomActorApplication.stop(deadline: .now + .seconds(60)) else {
                        logger.critical("IM V2 room actor failure drain exceeded its deadline")
                        exit(EXIT_FAILURE)
                    }
                } catch {
                    logger.critical("IM V2 room actor failure drain failed")
                    exit(EXIT_FAILURE)
                }
            }
            await natsLiveActivityBroker?.shutdown()
            await accountRoomChangeService?.shutdown()
            await sharedGroupWakeInterests?.shutdown()
            await natsGroupWakeBroker?.shutdown()
            try? await app.shutdown()
            try? await resources.shutdown()
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
        // FNV over the UUID's 16 raw bytes avoids allocating its 36-character
        // string representation on every accepted command.
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
