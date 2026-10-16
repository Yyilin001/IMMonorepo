import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Server
import IMV2ServerInfrastructure
import IMV2ServerGateway

/// 前台连接、数据库准入、短期缓存与进程内指标的共享依赖。
/// 这些对象只在本阶段构造，不打开 TLS 或指标监听端口。
struct GatewayFrontdoorAssembly {
    let authenticator: V2PostgresGatewayAuthenticator
    let commandRateLimiter: V2AuthenticatedGatewayCommandRateLimiter
    let connectionRegistry: V2DeviceConnectionRegistry
    let syncWakeCoalescer: V2SyncWakeCoalescer
    let liveSyncNotifier: any V2LiveSyncNotifier
    let databaseWorkAdmission: V2DatabaseWorkAdmissionController
    let databasePoolTopology: V2DatabasePoolTopologySnapshot
    let prometheusTelemetry: V2PrometheusTelemetrySink
    let transportMetrics: V2GatewayTransportMetrics
    let directRoomLogAppendStageMetrics: V2DirectRoomLogAppendStageMetrics
    let messageSendBudget: V2GatewayMessageSendBudget
    let gatewayEventLoopLagMetrics: V2EventLoopLagMetrics
    let directSendPolicyCache: V2DirectSendPolicyCache

    /// 根据网关配置建立前台限流和可观测性依赖，供后续装配阶段复用。
    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        topology: GatewayDatabaseTopology
    ) -> Self {
        let database = topology.database
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
            maximumConnections: configuration.maximumConnections,
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
            policy: Self.databaseWorkAdmissionPolicy(configuration),
            interactiveReadCoverageReservedQueued: coverageReservedQueued(
                roomShardStorage: configuration.roomShardStorage.filter { $0.databaseURL == configuration.databaseURL },
                maximumReadQueued: configuration.interactiveReadDatabaseWorkMaximumQueued)
        )
        let databasePoolTopology = GatewayPoolMetricsTopology.make(
            configuration: configuration,
            physicalDatabaseCount: topology.physicalDatabaseURLs.count
        )
        let prometheusTelemetry = V2PrometheusTelemetrySink()
        let transportMetrics = V2GatewayTransportMetrics()
        let directRoomLogAppendStageMetrics = V2DirectRoomLogAppendStageMetrics()
        let messageSendBudget = V2GatewayMessageSendBudget(
            maximumBytes: configuration.messageSendMaximumInFlightBytesProcess,
            maximumRequests: configuration.messageSendMaximumInFlightProcess)
        let gatewayEventLoopLagMetrics = V2EventLoopLagMetrics()
        let directSendPolicyCache = V2DirectSendPolicyCache(
            capacity: configuration.directSendPolicyCacheMaximumEntries
        )
        return .init(
            authenticator: authenticator,
            commandRateLimiter: commandRateLimiter,
            connectionRegistry: connectionRegistry,
            syncWakeCoalescer: syncWakeCoalescer,
            liveSyncNotifier: liveSyncNotifier,
            databaseWorkAdmission: databaseWorkAdmission,
            databasePoolTopology: databasePoolTopology,
            prometheusTelemetry: prometheusTelemetry,
            transportMetrics: transportMetrics,
            directRoomLogAppendStageMetrics: directRoomLogAppendStageMetrics,
            messageSendBudget: messageSendBudget,
            gatewayEventLoopLagMetrics: gatewayEventLoopLagMetrics,
            directSendPolicyCache: directSendPolicyCache
        )
    }
    static func databaseWorkAdmissionPolicy(_ configuration: V2GatewayRuntimeConfiguration) -> V2DatabaseWorkAdmissionPolicy {
        .init(
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
    }

    /// Logical shard aliases share one physical recovery batcher. Reserve only
    /// its existing actual capacity, inside the unchanged total read queue.
    static func coverageReservedQueued(
        roomShardStorage: [V2RoomShardStorageConfiguration], maximumReadQueued: Int
    ) -> Int {
        let physicalCount = Set(roomShardStorage.map {
            CoveragePhysicalStorage(databaseURL: $0.databaseURL, schema: $0.schema)
        }).count
        let actualLimit = V2HostRoomRecoveryQueryBatcher.Configuration.defaultMaximumInFlightBatches
        let product = physicalCount.multipliedReportingOverflow(by: actualLimit)
        let available = maximumReadQueued > 1 ? maximumReadQueued - 1 : 0
        return min(product.overflow ? available : product.partialValue, available)
    }

    private struct CoveragePhysicalStorage: Hashable {
        let databaseURL: String
        let schema: String
    }

}
