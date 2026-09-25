import Foundation
import IMV2Server

/// 初始化用户分片路由栅栏、提交后投影投递器和有界读缓存。
/// 同一用户路由由前台、投递、维护各自的数据库角色访问。
struct GatewayProjectionAssembly {
    let syncUserShardRouter: V2PostgresUserShardRouter
    let maintenanceUserShardRouter: V2PostgresUserShardRouter
    let userShardProjectionDelivery: V2PostgresUserShardProjectionDelivery
    let maintenanceUserShardProjectionDelivery: V2PostgresUserShardProjectionDelivery
    let directRoomLogEventCache: V2DirectRoomLogEventCache?
    let preparedGroupEventPageCache: V2PreparedGroupEventPageCache?
    let roomShardRouter: V2CachedRoomShardRouter
    let userStateWorkers: [V2UserStateEventWorker]

    /// 先建立默认用户路由，再为各数据库角色构造独立路由句柄。
    /// 投影 Worker 按物理房间归属库创建，以消费各库的持久 outbox。
    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        topology: GatewayDatabaseTopology,
        coLocatedControlBuckets: Set<String>,
        roomOwnerDatabaseURLs: [String]
    ) async throws -> Self {
        let database = topology.database
        let syncControlDatabase = topology.syncControlDatabase
        let deliveryDatabase = topology.deliveryDatabase
        let maintenanceDatabase = topology.maintenanceDatabase
        let userStateRouter = topology.userStateRouter
        let deliveryUserShardStorage = topology.deliveryUserShardStorage
        let maintenanceUserShardStorage = topology.maintenanceUserShardStorage
        let userShardRouter = V2PostgresUserShardRouter(database: database)
        try await userShardRouter.bootstrap(defaultRoute: configuration.userShardRoute)
        let syncUserShardRouter = V2PostgresUserShardRouter(database: syncControlDatabase)
        let deliveryUserShardRouter = V2PostgresUserShardRouter(database: deliveryDatabase)
        let maintenanceUserShardRouter = V2PostgresUserShardRouter(
            database: maintenanceDatabase
        )
        // 控制投影属于提交后的跨存储投递工作。
        // 若从前台连接池获取路由栅栏，首条消息突发时可能发生连接池自我饥饿：
        // 每次追加都等待路由栅栏，而前台连接又被同一批请求占满。
        // 咨询锁在数据库内全局有效，因此投递连接池既能保持当前路由栅栏，
        // 又能将有界后续工作与消息持久化隔离。
        let userShardProjectionDelivery = V2PostgresUserShardProjectionDelivery(
            registry: deliveryUserShardStorage,
            routeFence: deliveryUserShardRouter,
            batchRouteFence: deliveryUserShardRouter,
            coLocatedControlBuckets: coLocatedControlBuckets
        )
        let maintenanceUserShardProjectionDelivery =
            V2PostgresUserShardProjectionDelivery(
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
        let userStateProjector = try V2RoutedUserStateEventProjector(
            routeFence: userStateRouter,
            registry: deliveryUserShardStorage
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
        return .init(
            syncUserShardRouter: syncUserShardRouter,
            maintenanceUserShardRouter: maintenanceUserShardRouter,
            userShardProjectionDelivery: userShardProjectionDelivery,
            maintenanceUserShardProjectionDelivery: maintenanceUserShardProjectionDelivery,
            directRoomLogEventCache: directRoomLogEventCache,
            preparedGroupEventPageCache: preparedGroupEventPageCache,
            roomShardRouter: roomShardRouter,
            userStateWorkers: userStateWorkers
        )
    }
}
