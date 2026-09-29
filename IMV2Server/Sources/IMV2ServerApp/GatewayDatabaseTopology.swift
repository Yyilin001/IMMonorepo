import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import FluentPostgresDriver
import IMV2Server
import IMV2ServerInfrastructure
import Logging

/// 网关使用的数据库句柄和物理拓扑。构建完成后，所有连接池与 Schema 均已验证。
/// 连接池本身由调用方持有的 `V2DatabaseResources` 负责关闭。
struct GatewayDatabaseTopology {
    let physicalDatabaseURLs: [String]
    private let databasesByRole: [V2PostgresWorkloadPoolBudget.Role: [String: any Database]]
    let database: any Database
    let syncControlDatabase: any Database
    let deliveryDatabase: any Database
    let maintenanceDatabase: any Database
    let userStateRouter: V2PostgresUserShardRouter
    let directSendControlPool: V2EventLoopDatabasePool
    let authorizationControlDatabase: any Database
    let authorizationOwners: [String: any Database]
    let projectionShardLocations: [V2UserShardStorageLocation]
    let maintenanceShardLocations: [V2UserShardStorageLocation]
    let roomShardDatabases: [String: any Database]
    let syncUserShardStorage: V2StaticUserShardStorageRegistry
    let deliveryUserShardStorage: V2StaticUserShardStorageRegistry
    let maintenanceUserShardStorage: V2StaticUserShardStorageRegistry

    func databaseForRole(for role: V2PostgresWorkloadPoolBudget.Role, url: String) -> (any Database)? {
        databasesByRole[role]?[url] ?? databasesByRole[.foreground]?[url]
    }

    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        resources: V2DatabaseResources,
        logger: Logger
    ) async throws -> Self {
        let databaseEventLoops = Array(resources.eventLoopGroup.makeIterator())
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
                // 逐一验证每个 EventLoop 所属连接池的会话 GUC。
                // 若只使用一个长期存活的 `app.db(identifier)` 句柄，所有 Store
                // 都会绑定到同一个连接池，配置的逐 EventLoop 连接数便无法生效。
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

        // 独立控制连接持有路由围栏，数据连接先提交源端再投递到当前归属。
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

        // 解析操作不借用预留连接池或策略写入连接池。
        // 控制回执与归属方中止操作可共用此专用物理连接池：
        // 每笔事务结束后才开始下一笔。
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

        // Schema 就绪性属于拓扑状态，不属于工作类别状态。
        // 各类别连接池验证会话 GUC 后，通过前台连接池逐一验证配置的 Schema。
        try await V2SchemaReadiness.verify(database: database)
        for storage in configuration.userShardStorage {
            guard let shardDatabase = databaseForRole(for: .foreground, url: storage.databaseURL)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await V2SchemaReadiness.verify(
                database: shardDatabase, schema: storage.schema
            )
        }
        // 房间分片必须先验证同一套规范 Schema，进程才能将持久房间命令路由至此。
        // 这是启动时的拓扑栅栏，不延迟到首次请求时检查。
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
        return .init(
            physicalDatabaseURLs: physicalDatabaseURLs,
            databasesByRole: databasesByRole,
            database: database,
            syncControlDatabase: syncControlDatabase,
            deliveryDatabase: deliveryDatabase,
            maintenanceDatabase: maintenanceDatabase,
            userStateRouter: userStateRouter,
            directSendControlPool: directSendControlPool,
            authorizationControlDatabase: authorizationControlDatabase,
            authorizationOwners: authorizationOwners,
            projectionShardLocations: projectionShardLocations,
            maintenanceShardLocations: maintenanceShardLocations,
            roomShardDatabases: roomShardDatabases,
            syncUserShardStorage: syncUserShardStorage,
            deliveryUserShardStorage: deliveryUserShardStorage,
            maintenanceUserShardStorage: maintenanceUserShardStorage
        )
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
