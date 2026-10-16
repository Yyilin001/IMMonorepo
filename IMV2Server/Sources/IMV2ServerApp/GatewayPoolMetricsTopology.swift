import IMV2ServerApplication
import IMV2ServerContracts
import IMV2Server
import IMV2ServerInfrastructure

/// 根据部署的物理数据库数量和连接预算，构造指标使用的连接池拓扑快照。
/// 此处只计算指标描述，不创建或关闭数据库连接池。
enum GatewayPoolMetricsTopology {
    static func make(
        configuration: V2GatewayRuntimeConfiguration,
        physicalDatabaseCount: Int
    ) -> V2DatabasePoolTopologySnapshot {
        let configuredHandleCount = configuration.databaseNonMessagePoolEventLoopThreads * physicalDatabaseCount
        let workloadPoolTopology: V2DatabasePoolTopologySnapshot
        if configuration.databaseWorkloadPoolIsolationEnabled {
            workloadPoolTopology = .init(
                pools: V2PostgresWorkloadPoolBudget.Role.allCases.filter { configuration.databaseWorkloadPoolBudget.connectionsPerEventLoop(for: $0) > 0 }.map { role in
                    .init(
                        poolClass: metricClass(for: role),
                        eventLoopHandles: configuration.databasePoolEventLoopCount(for: role) * physicalDatabaseCount,
                        connectionCeiling: configuration.databasePoolEventLoopCount(for: role) * physicalDatabaseCount *
                            configuration.databaseWorkloadPoolBudget.connectionsPerEventLoop(for: role)
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
        return .init(pools: workloadPoolTopology.pools + [
            .init(poolClass: .initialization,
                  eventLoopHandles: configuredHandleCount,
                  connectionCeiling: configuredHandleCount * configuration.initializationConnectionsPerEventLoop),
            .init(poolClass: .userStateRoute,
                  eventLoopHandles: configuration.databaseNonMessagePoolEventLoopThreads,
                  connectionCeiling: configuration.databaseNonMessagePoolEventLoopThreads),
            .init(poolClass: .directSendControl,
                  eventLoopHandles: configuration.databaseNonMessagePoolEventLoopThreads,
                  connectionCeiling: configuration.databaseNonMessagePoolEventLoopThreads *
                    configuration.directSendControlConnectionsPerEventLoop),
            .init(poolClass: .roomIdentityControl,
                  eventLoopHandles: configuration.databaseNonMessagePoolEventLoopThreads,
                  connectionCeiling: configuration.databaseNonMessagePoolEventLoopThreads)
        ])
    }

    static func metricClass(
        for role: V2PostgresWorkloadPoolBudget.Role
    ) -> V2DatabasePoolMetricClass {
        switch role {
        case .messageWrite: .messageWrite
        case .foreground: .foreground
        case .sync: .sync
        case .delivery: .delivery
        case .projection: .projection
        case .maintenance: .maintenance
        }
    }
}
