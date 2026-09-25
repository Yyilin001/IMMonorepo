import FluentKit
import Foundation
import IMV2Server
import Logging

/// 构造各物理房间归属库的维护依赖和持久工作指标。
struct GatewayOwnerMaintenanceAssembly {
    let roomOwnerDatabaseURLs: [String]
    let roomOwnerMaintenanceDatabases: [any Database]
    let personalEventGCWorkers: [PostgresV2UserStateEventGCWorker]
    let messageProjectionStateBodyCompactionWorkers: [PostgresV2MessageProjectionStateBodyCompactionWorker]
    let messageProjectionStateGCWorkers: [PostgresV2MessageProjectionStateGCWorker]
    let durableWorkMetrics: V2CachedDurableWorkMetricsSource
    let telemetry: V2CompositeTelemetrySink

    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        topology: GatewayDatabaseTopology,
        userShardMetricsSources: [any V2DurableWorkMetricsSource],
        prometheusTelemetry: V2PrometheusTelemetrySink,
        logger: Logger
    ) throws -> Self {
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
            GatewayApplicationTelemetrySink(
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
        return .init(
            roomOwnerDatabaseURLs: roomOwnerDatabaseURLs,
            roomOwnerMaintenanceDatabases: roomOwnerMaintenanceDatabases,
            personalEventGCWorkers: personalEventGCWorkers,
            messageProjectionStateBodyCompactionWorkers: messageProjectionStateBodyCompactionWorkers,
            messageProjectionStateGCWorkers: messageProjectionStateGCWorkers,
            durableWorkMetrics: durableWorkMetrics,
            telemetry: telemetry
        )
    }
}
