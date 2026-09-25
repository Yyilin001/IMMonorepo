import Logging
import IMV2ActorApplication
import IMV2ServerHTTP
import Vapor
import IMV2Server

/// Actor 启动前所需的依赖快照；包含数据库拓扑、投影、前台连接和房间归属资源。
/// 此阶段只准备依赖并配置指标地址，不启动房间 Actor 或 Broker。
struct GatewayPreparedAssembly {
    let topology: GatewayDatabaseTopology
    let authorization: V2DirectAuthorizationCoordinator
    let userShardWork: GatewayUserShardWork
    let frontdoor: GatewayFrontdoorAssembly
    let ownerMaintenance: GatewayOwnerMaintenanceAssembly
    let projection: GatewayProjectionAssembly
    let roomOwners: GatewayRoomOwnerAssembly
    let coLocatedControlBuckets: Set<String>

    /// 先验证数据库拓扑，再建立前台/维护依赖、用户分片路由及房间归属资源。
    ///
    /// 这里的失败无需清理 Actor 或 Broker；数据库连接池仍由 `GatewayInfrastructure` 持有。
    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        resources: V2DatabaseResources,
        app: Application,
        logger: Logger
    ) async throws -> Self {
        let topology = try await GatewayDatabaseTopology.build(
            configuration: configuration, resources: resources, logger: logger
        )
        let authorization = V2DirectAuthorizationCoordinator(
            controlDatabase: topology.authorizationControlDatabase,
            ownerDatabases: topology.authorizationOwners
        )
        // 同址用户桶复用路由栅栏的控制库连接；其他桶使用各自的投递库连接。
        let coLocatedControlBuckets = Set(configuration.userShardStorage.compactMap { storage in
            storage.databaseURL == configuration.databaseURL && storage.schema == "im_v2"
                ? storage.bucket : nil
        })
        let userShardWork = GatewayUserShardWork.build(
            configuration: configuration,
            projectionShardLocations: topology.projectionShardLocations,
            maintenanceShardLocations: topology.maintenanceShardLocations
        )

        // 指标端口仅监听配置的运维地址，不由客户端 TLS 监听器暴露。
        app.serverConfiguration.hostname = configuration.metrics.host
        app.serverConfiguration.port = configuration.metrics.port
        let frontdoor = GatewayFrontdoorAssembly.build(
            configuration: configuration, topology: topology
        )
        let ownerMaintenance = try GatewayOwnerMaintenanceAssembly.build(
            configuration: configuration,
            topology: topology,
            userShardMetricsSources: userShardWork.userShardMetricsSources,
            prometheusTelemetry: frontdoor.prometheusTelemetry,
            logger: logger
        )
        let projection = try await GatewayProjectionAssembly.build(
            configuration: configuration,
            topology: topology,
            coLocatedControlBuckets: coLocatedControlBuckets,
            roomOwnerDatabaseURLs: ownerMaintenance.roomOwnerDatabaseURLs
        )
        let roomOwners = try GatewayRoomOwnerAssembly.build(
            configuration: configuration,
            topology: topology,
            userShardProjectionDelivery: projection.userShardProjectionDelivery,
            databaseWorkAdmission: frontdoor.databaseWorkAdmission,
            directSendPolicyCache: frontdoor.directSendPolicyCache,
            directRoomLogFastAppendCache: frontdoor.directRoomLogFastAppendCache,
            directRoomLogAppendStageMetrics: frontdoor.directRoomLogAppendStageMetrics,
            directRoomLogEventCache: projection.directRoomLogEventCache
        )
        return .init(
            topology: topology,
            authorization: authorization,
            userShardWork: userShardWork,
            frontdoor: frontdoor,
            ownerMaintenance: ownerMaintenance,
            projection: projection,
            roomOwners: roomOwners,
            coLocatedControlBuckets: coLocatedControlBuckets
        )
    }

    /// Actor 已建立后，把 Actor、连接池及缓存的压力指标接入运维 HTTP 应用。
    /// 此操作仅登记路由；实际监听由 `GatewayRuntime.runServices` 启动。
    func registerMetrics(on app: Application, actors: V2RoomActorApplication) {
        let frontdoor = self.frontdoor
        let ownerMaintenance = self.ownerMaintenance
        let projection = self.projection
        let roomOwners = self.roomOwners
        let directRoomLogAppendBatcher = V2AggregatedSendMessageBatchMetrics(
            owners: roomOwners.ownerBatchers.values.map { $0 as any V2SendMessageBatchMetricsReading })
        let readReceiptBatcher = V2AggregatedReadReceiptBatchMetrics(
            owners: roomOwners.physicalResources.values.map(\.receiptBatchMetrics))
        V2VaporMetricsRoutes.register(on: app, telemetry: frontdoor.prometheusTelemetry,
            connectionMetrics: frontdoor.connectionRegistry, transportMetrics: frontdoor.transportMetrics,
            durableWorkMetrics: ownerMaintenance.durableWorkMetrics,
            runtimePressureMetrics: V2GatewayRuntimePressureMetricsSource(
                databaseWorkAdmission: frontdoor.databaseWorkAdmission, databasePools: frontdoor.databasePoolTopology,
                syncWakeCoalescer: frontdoor.syncWakeCoalescer,
                shardAdmissionCommandCredits: roomOwners.shardAdmissionCredits,
                roomAdmissionCommandCredits: roomOwners.roomAdmissionCredits,
                directRoomLogAppendBatcher: directRoomLogAppendBatcher,
                readReceiptBatcher: readReceiptBatcher,
                directRoomLogAppendStageMetrics: frontdoor.directRoomLogAppendStageMetrics,
                gatewayEventLoopLagMetrics: frontdoor.gatewayEventLoopLagMetrics,
                directSendPolicyCache: frontdoor.directSendPolicyCache,
                directRoomLogFastAppendCache: frontdoor.directRoomLogFastAppendCache,
                directRoomLogEventCache: projection.directRoomLogEventCache,
                preparedGroupEventPageCache: projection.preparedGroupEventPageCache,
                connectionRegistry: frontdoor.connectionRegistry, roomActors: actors))
    }
}
