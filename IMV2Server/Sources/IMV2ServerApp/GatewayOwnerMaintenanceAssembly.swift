import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Server
import IMV2ServerInfrastructure

/// 按物理数据库去重后，构造房间归属库的维护依赖与持久工作指标。
/// 控制库始终参与聚合，即使房间归属配置只指向其他数据库。
struct GatewayOwnerMaintenanceAssembly {
    let roomOwnerMaintenanceDatabases: [any Database]
    let personalEventGCWorkers: [PostgresV2UserStateEventGCWorker]
    let messageProjectionStateBodyCompactionWorkers: [PostgresV2MessageProjectionStateBodyCompactionWorker]
    let messageProjectionStateGCWorkers: [PostgresV2MessageProjectionStateGCWorker]
    let durableWorkMetrics: V2AggregateDurableWorkMetricsSource
    let userShardWork: GatewayUserShardWork
    let userStateWorkers: [V2UserStateEventWorker]
    let roomDispatchWorkers: [V2RoomDispatchWorker]

    /// 汇总控制库、用户分片和房间归属库的指标，并准备持久投递 Worker。
    /// 此阶段只创建 Worker 和指标源，轮询由 `GatewayBackgroundWorkers.start` 启动。
    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        topology: GatewayDatabaseTopology
    ) throws -> Self {
        let userShardWork = GatewayUserShardWork.build(
            configuration: configuration,
            projectionShardLocations: topology.projectionShardLocations,
            maintenanceShardLocations: topology.maintenanceShardLocations
        )

        let maintenanceDatabase = topology.maintenanceDatabase
        let roomOwnerDatabaseURLs = Set(
            [configuration.databaseURL]
                + configuration.roomShardStorage.map(\.databaseURL)
        ).sorted()
        let roomOwnerMaintenanceDatabases = try roomOwnerDatabaseURLs.map { ownerURL in
            guard let ownerDatabase = topology.databaseForRole(for: .maintenance, url: ownerURL) else {
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
        let sendCompletionMetricsSources = roomOwnerMaintenanceDatabases.map {
            PostgresV2SendCompletionMetricsSource(database: $0)
        }
        let messageProjectionStateBodyCompactionWorkers = roomOwnerMaintenanceDatabases.map {
            PostgresV2MessageProjectionStateBodyCompactionWorker(database: $0)
        }
        let messageProjectionStateGCWorkers = roomOwnerMaintenanceDatabases.map {
            PostgresV2MessageProjectionStateGCWorker(database: $0,
                retention: TimeInterval(configuration.messageProjectionStateRetentionSeconds))
        }
        let durableWorkMetrics = V2AggregateDurableWorkMetricsSource(sources: [
            PostgresV2DurableWorkMetricsSource(database: maintenanceDatabase,
                gatewayNodeID: configuration.gatewayNodeID, includesUserShardMetrics: false)
        ] + userShardWork.userShardMetricsSources + personalEventMetricsSources + roomMessageStateMetricsSources + sendCompletionMetricsSources)
        let userStateProjector = try V2RoutedUserStateEventProjector(
            routeFence: topology.userStateRouter,
            registry: topology.deliveryUserShardStorage
        )
        let userStateWorkers = try roomOwnerDatabaseURLs.map { ownerURL in
            guard let ownerDatabase = topology.databaseForRole(for: .delivery, url: ownerURL) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return V2UserStateEventWorker(
                outbox: try PostgresV2UserStateEventOutbox(database: ownerDatabase),
                projector: userStateProjector
            )
        }
        let roomDispatchProjector = V2RoutedRoomDispatchProjector(
            routeFence: topology.userStateRouter, registry: topology.deliveryUserShardStorage)
        let roomDispatchWorkers = try roomOwnerDatabaseURLs.map { ownerURL in
            guard let owner = topology.databaseForRole(for: .delivery, url: ownerURL) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return V2RoomDispatchWorker(outbox: PostgresV2RoomDispatchStore(database: owner),
                projector: roomDispatchProjector)
        }
        return .init(
            roomOwnerMaintenanceDatabases: roomOwnerMaintenanceDatabases,
            personalEventGCWorkers: personalEventGCWorkers,
            messageProjectionStateBodyCompactionWorkers: messageProjectionStateBodyCompactionWorkers,
            messageProjectionStateGCWorkers: messageProjectionStateGCWorkers,
            durableWorkMetrics: durableWorkMetrics,
            userShardWork: userShardWork,
            userStateWorkers: userStateWorkers,
            roomDispatchWorkers: roomDispatchWorkers
        )
    }
}
