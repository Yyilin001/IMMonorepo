import Foundation
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ServerGateway
import Logging
import IMV2ActorApplication
import IMV2ServerHTTP
import Vapor
import IMV2Server
import IMV2ServerInfrastructure

/// Actor 启动前所需的依赖快照；包含数据库拓扑、投影、前台连接和房间归属资源。
/// 此阶段只准备依赖并配置指标地址，不启动房间 Actor 或 Broker。
struct GatewayPreparedAssembly {
    let topology: GatewayDatabaseTopology
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
        resources: V2DatabaseWorkloadResources,
        app: Application,
        logger: Logger
    ) async throws -> Self {
        // Issue one process identity before opening any SQL pool. The same
        // incarnation tags its sessions and later registers the native Host.
        let actorConfiguration = try V2RoomActorApplicationConfiguration(
            environment: ProcessRuntimeEnvironment(), hostsRooms: nil,
            configuredShardIDs: Set(configuration.roomShardStorage.map(\.shardID)),
            batchWaitMilliseconds: Int64(max(
                configuration.roomTurnBatchMaximumDelayMilliseconds,
                configuration.readReceiptBatchMaximumDelayMilliseconds)))
        try await actorConfiguration.awaitSupervisedStartup()
        let topology = try await GatewayDatabaseTopology.build(
            configuration: configuration, resources: resources, logger: logger,
            actorConfiguration: actorConfiguration
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
            actorConfiguration: actorConfiguration,
            topology: topology,
            userShardProjectionDelivery: projection.userShardProjectionDelivery,
            databaseWorkAdmission: frontdoor.databaseWorkAdmission,
            directSendPolicyCache: frontdoor.directSendPolicyCache,
            directRoomLogAppendStageMetrics: frontdoor.directRoomLogAppendStageMetrics
        )
        return .init(
            topology: topology,
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
    func registerMetrics(on app: Application, actors: V2RoomActorApplication, actorRealtimeMetrics: (any V2ActorRealtimeMetricsSource)? = nil) {
        let frontdoor = self.frontdoor
        let ownerMaintenance = self.ownerMaintenance
        let projection = self.projection
        let roomOwners = self.roomOwners
        let topology = self.topology
        let physicalRecoveryOwners = Array(roomOwners.physicalResources.values)
        let readReceiptBatcher = V2AggregatedReadReceiptBatchMetrics(
            owners: roomOwners.physicalResources.values.map(\.receiptBatchMetrics))
        let schedulingRegistry = frontdoor.connectionRegistry
        V2SendPathTraceLogging.install(collection:
            ProcessInfo.processInfo.environment["IM_V2_SEND_PATH_TRACE_MODE"] == "all"
                ? .all : .sampledOperations)
        V2VaporMetricsRoutes.register(on: app, telemetry: frontdoor.prometheusTelemetry,
            connectionMetrics: frontdoor.connectionRegistry, transportMetrics: frontdoor.transportMetrics,
            durableWorkMetrics: ownerMaintenance.durableWorkMetrics,
            runtimePressureMetrics: V2GatewayRuntimePressureMetricsSource(
                databaseWorkAdmission: frontdoor.databaseWorkAdmission, databasePools: frontdoor.databasePoolTopology,
                syncWakeCoalescer: frontdoor.syncWakeCoalescer,
                readReceiptBatcher: readReceiptBatcher,
                directRoomLogAppendStageMetrics: frontdoor.directRoomLogAppendStageMetrics,
                gatewayEventLoopLagMetrics: frontdoor.gatewayEventLoopLagMetrics,
                directSendPolicyCache: frontdoor.directSendPolicyCache,
                directRoomLogEventCache: projection.directRoomLogEventCache,
                preparedGroupEventPageCache: projection.preparedGroupEventPageCache,
                connectionRegistry: frontdoor.connectionRegistry, roomActors: actors,
                sendOperationMetrics: V2AggregatedSendOperationBatchMetrics(
                    owners: roomOwners.physicalResources.values.map(\.sendOperationMetrics)),
                sendOperationOwnerMetrics: V2AggregatedSendOperationOwnerMetrics(
                    owners: roomOwners.physicalResources.values.map { $0 as any V2SendOperationOwnerMetricsReading }),
                databaseLoans: {
                    let snapshot = topology.loanMetricsSnapshot()
                    let ordinary = snapshot.classes[.ordinary, default: .init()]
                    let activation = snapshot.classes[.activation, default: .init()]
                    let renewal = snapshot.classes[.renewal, default: .init()]
                    let sync = snapshot.classes[.sync, default: .init()]
                    return .init(
                        ordinary: .init(inFlight: ordinary.inFlight, queued: ordinary.queued,
                                        granted: ordinary.granted, rejected: ordinary.rejected),
                        activation: .init(inFlight: activation.inFlight, queued: activation.queued,
                                          granted: activation.granted, rejected: activation.rejected),
                        renewal: .init(inFlight: renewal.inFlight, queued: renewal.queued,
                                       granted: renewal.granted, rejected: renewal.rejected),
                        sync: .init(inFlight: sync.inFlight, queued: sync.queued,
                                    granted: sync.granted, rejected: sync.rejected),
                        observations: v2LoanObservationMetrics(snapshot.observations))
                }, gatewayMessageSendBudget: frontdoor.messageSendBudget,
                roomRecoveryBatches: {
                    v2AggregateRecoveryBatchPressure(physicalRecoveryOwners.map { $0.recoveryBatchPressureSnapshot() })
                }, additionalDatabaseWorkAdmissions: roomOwners.databaseWorkAdmissions.controllers),
            actorRealtimeMetrics: actorRealtimeMetrics,
            recoverySchedulingMetrics: { schedulingRegistry.recoverySchedulingMetricsSnapshot() },
            roomHeadDeliveryMetrics: {
                v2RenderPrometheusRoomSubscriptionHeadDeliveryMetrics(
                    V2RoomSubscriptionHeadDeliveryMetrics.shared.snapshot())
            })
    }
}

/// 内部观测与对外指标共享固定标签，仅转换聚合快照。
private func v2LoanObservationMetrics(
    _ observations: [V2DatabaseLoanSource: V2DatabaseLoanSourceSnapshot]
) -> [V2DatabaseLoanObservationMetricSource: V2DatabaseLoanObservationSourceMetric] {
    var result: [V2DatabaseLoanObservationMetricSource: V2DatabaseLoanObservationSourceMetric] = [:]
    for source in V2DatabaseLoanSource.allCases {
        let observed = observations[source, default: .init()]
        var metric = V2DatabaseLoanObservationSourceMetric()
        metric.actualHeldCount = observed.actualHeldCount
        metric.actualHeldTotalMilliseconds = observed.actualHeldTotalMilliseconds
        metric.actualHeldMaxMilliseconds = observed.actualHeldMaxMilliseconds
        for (phase, item) in observed.sqlPhases {
            var value = V2DatabaseLoanObservationSQLMetric()
            value.count = item.count
            value.totalMilliseconds = item.totalMilliseconds
            value.maxMilliseconds = item.maxMilliseconds
            metric.sqlPhases[phase] = value
        }
        for stage in V2DatabaseLoanStage.allCases {
            let item = observed.stages[stage, default: .init()]
            var value = V2DatabaseLoanObservationStageMetric()
            value.active = item.active
            value.oldestMilliseconds = item.oldestMilliseconds
            value.count = item.count
            value.totalMilliseconds = item.totalMilliseconds
            value.maxMilliseconds = item.maxMilliseconds
            metric.stages[stage] = value
        }
        result[source] = metric
    }
    return result
}

/// Physical URL/schema owners are deduplicated at assembly; logical aliases must
/// not multiply actual occupancy. These component snapshots are not atomic.
private func v2AggregateRecoveryBatchPressure(
    _ snapshots: [V2RoomRecoveryBatchPressureSnapshot]
) -> V2RoomRecoveryBatchPressureSnapshot {
    var result = V2RoomRecoveryBatchPressureSnapshot()
    func sum(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let value = a.addingReportingOverflow(b)
        return value.overflow ? .max : value.partialValue
    }
    for snapshot in snapshots {
        result.pendingItems += snapshot.pendingItems
        result.retainedItems += snapshot.retainedItems
        result.retainedBytes += snapshot.retainedBytes
        result.ordinaryRetainedItems += snapshot.ordinaryRetainedItems
        result.actualBatches += snapshot.actualBatches
        result.oldestQueuedMilliseconds = max(result.oldestQueuedMilliseconds, snapshot.oldestQueuedMilliseconds)
        result.oldestActualMilliseconds = max(result.oldestActualMilliseconds, snapshot.oldestActualMilliseconds)
        result.batchesStarted = sum(result.batchesStarted, snapshot.batchesStarted)
        result.itemsSelected = sum(result.itemsSelected, snapshot.itemsSelected)
        result.itemsSettled = sum(result.itemsSettled, snapshot.itemsSettled)
        for purpose in V2RoomRecoveryBatchPurpose.allCases {
            let value = snapshot.purposes[purpose, default: .init()]
            var aggregate = result.purposes[purpose, default: .init()]
            aggregate.inFlight += value.inFlight
            aggregate.items += value.items
            aggregate.oldestMilliseconds = max(aggregate.oldestMilliseconds, value.oldestMilliseconds)
            aggregate.started = sum(aggregate.started, value.started)
            aggregate.completed = sum(aggregate.completed, value.completed)
            aggregate.busyBeforeAcquire = sum(aggregate.busyBeforeAcquire, value.busyBeforeAcquire)
            aggregate.durationMillisecondsSum += value.durationMillisecondsSum
            aggregate.durationMillisecondsMax = max(aggregate.durationMillisecondsMax, value.durationMillisecondsMax)
            result.purposes[purpose] = aggregate
        }
    }
    return result
}
