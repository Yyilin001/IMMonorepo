import Foundation
import IMV2Server

/// 同一物理用户分片上的投影、维护与指标来源只组装一次。
struct GatewayUserShardWork {
    let snapshotArtifactBuilders: [PostgresV2SnapshotArtifactBuilder]
    let userProjectionWorkers: [PostgresV2UserProjectionWorker]
    let projectionVersionGCWorkers: [PostgresV2ProjectionVersionGCWorker]
    let syncLogCompactionWorkers: [PostgresV2UserSyncLogCompactionWorker]
    let userShardMetricsSources: [any V2DurableWorkMetricsSource]
    let syncHousekeepingWorkers: [V2SyncHousekeepingWorker]

    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        projectionShardLocations: [V2UserShardStorageLocation],
        maintenanceShardLocations: [V2UserShardStorageLocation]
    ) -> Self {
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

        return .init(
            snapshotArtifactBuilders: snapshotArtifactBuilders,
            userProjectionWorkers: userProjectionWorkers,
            projectionVersionGCWorkers: projectionVersionGCWorkers,
            syncLogCompactionWorkers: syncLogCompactionWorkers,
            userShardMetricsSources: userShardMetricsSources,
            syncHousekeepingWorkers: syncHousekeepingWorkers
        )
    }
}
