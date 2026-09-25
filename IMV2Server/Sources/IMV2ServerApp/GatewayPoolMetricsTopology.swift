import IMV2Server

/// 根据部署的物理数据库数量和连接预算，构造指标使用的连接池拓扑快照。
/// 此处只计算指标描述，不创建或关闭数据库连接池。
enum GatewayPoolMetricsTopology {
    static func make(
        configuration: V2GatewayRuntimeConfiguration,
        physicalDatabaseCount: Int
    ) -> V2DatabasePoolTopologySnapshot {
        let configuredHandleCount = configuration.databasePolicy.eventLoopThreads * physicalDatabaseCount
        let workloadPoolTopology: V2DatabasePoolTopologySnapshot
        if configuration.databaseWorkloadPoolIsolationEnabled {
            workloadPoolTopology = .init(
                pools: V2PostgresWorkloadPoolBudget.Role.allCases.map { role in
                    .init(
                        poolClass: metricClass(for: role),
                        eventLoopHandles: configuredHandleCount,
                        connectionCeiling: configuredHandleCount *
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
            .init(poolClass: .userStateRoute,
                  eventLoopHandles: configuration.databasePolicy.eventLoopThreads,
                  connectionCeiling: configuration.databasePolicy.eventLoopThreads),
            .init(poolClass: .directSendControl,
                  eventLoopHandles: configuration.databasePolicy.eventLoopThreads,
                  connectionCeiling: configuration.databasePolicy.eventLoopThreads *
                    configuration.directSendControlConnectionsPerEventLoop),
            .init(poolClass: .directAuthorizationResolution,
                  eventLoopHandles: configuration.databasePolicy.eventLoopThreads *
                    configuration.directAuthorizationResolutionDatabaseURLs.count,
                  connectionCeiling: configuration.databasePolicy.eventLoopThreads *
                    configuration.directAuthorizationResolutionDatabaseURLs.count)
        ])
    }

    private static func metricClass(
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
}
