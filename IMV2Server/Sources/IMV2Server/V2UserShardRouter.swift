import Foundation
import FluentKit
import IMV2Core
import SQLKit

/// 用户写入归属的逻辑桶、观察到的路由代次。
///
/// 不包含物理数据库地址。投递持久化桶与代次用于后续一致性检查。
public struct V2UserShardRoute: Equatable, Sendable {
    /// 规范化后的非空逻辑写入桶。
    public let bucket: String
    /// 本次解析观察到的非负路由代次。
    public let observedRouterEpoch: Int64
    public init(bucket: String, observedRouterEpoch: Int64) throws {
        let normalizedBucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBucket.isEmpty,
              observedRouterEpoch >= 0
        else {
            throw V2UserShardRouterError.invalidRoute
        }
        self.bucket = normalizedBucket
        self.observedRouterEpoch = observedRouterEpoch
    }

}

/// 可注入且带代次的用户归属解析边界。
///
/// 个人状态投递通过此接口获取归属，不在本地自行哈希标识推导目标桶。
public protocol V2UserShardRouter: Sendable {
    /// 按输入顺序为每个用户返回一个路由。
    ///
    /// - Parameter users: 有界批次中的用户列表，调用方负责选择合适批次规模。
    /// - Returns: 与输入数量和顺序相同的路由数组。
    /// - Throws: 配置缺失、结果不完整、路由无效或底层查询错误。
    func routes(for users: [UserID]) async throws -> [V2UserShardRoute]
}

/// 解析控制面用户路由后执行归属存储操作，复用控制面事务。
///
/// 回调可在控制事务仍打开时执行有界的跨库存储操作；部署期间路由配置保持固定，回调不提供跨库原子提交。
public protocol V2UserShardRouteFencing: Sendable {
    /// 在控制面事务内调用业务操作。
    ///
    /// - Parameters:
    ///   - userID: 单个用户。
    ///   - operation: 接收当前路由和控制事务的有界操作。
    /// - Returns: 操作返回的业务结果。
    /// - Throws: 保护获取、路由读取或业务回调错误。
    func withCurrentRoute<Result: Sendable>(
        for userID: UserID,
        _ operation: @escaping @Sendable (V2UserShardRoute, any Database) async throws -> Result
    ) async throws -> Result
}

/// 为有界用户集合在同一控制事务内读取路由。
///
/// 部署期间保持路由配置固定。
/// 批量接口减少控制面往返，保留每个用户的路由结果。
public protocol V2UserShardRouteBatchFencing: Sendable {
    /// 在控制面事务内调用业务操作。
    ///
    /// - Parameters:
    ///   - userIDs: 用户列表。
    ///   - operation: 接收当前路由和控制事务的有界操作。
    /// - Returns: 操作返回的业务结果。
    /// - Throws: 保护获取、路由读取或业务回调错误。
    func withCurrentRoutes<Result: Sendable>(
        for userIDs: [UserID],
        _ operation: @escaping @Sendable ([V2UserShardRoute], any Database) async throws -> Result
    ) async throws -> Result
}

/// 用户路由值或批量解析结果不满足契约时的错误。
public enum V2UserShardRouterError: Error, Equatable, Sendable {
    /// 桶、代次或批量受保护请求参数无效。
    case invalidRoute
    /// 路由查询行数不等于请求用户数，例如默认配置缺失。
    case resultCountMismatch
}

/// 使用默认配置与用户覆盖记录解析逻辑归属的 PostgreSQL 路由器。
///
/// 每批重新读取控制面，仅返回逻辑桶与代次，不将物理地址写入投递记录。
/// 普通解析只提供查询快照；需要跨归属操作保护时应使用事务回调接口。
public struct V2PostgresUserShardRouter: V2UserShardRouter {
    private let database: any Database

    /// 保存支持 SQL 的控制面数据库，不立即查询配置。
    ///
    /// - Parameter database: 路由配置与覆盖记录所在数据库。
    public init(database: any Database) { self.database = database }

    /// 首次部署插入默认路由配置，已存在配置时保持原值。
    ///
    /// - Parameters:
    ///   - defaultRoute: 新部署的默认写入桶与代次。
    ///   - now: 配置更新时间，调用时验证可编码性，即使配置已经存在也会验证。
    /// - Throws: 日期无效、SQL 能力缺失或数据库错误。
    ///
    /// 使用冲突忽略插入，不通过进程环境变化覆盖已持久化的受控路由决策。
    public func bootstrap(defaultRoute: V2UserShardRoute, now: Date = Date()) async throws {
        guard v2PostgresTimestampCanEncode(now) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            INSERT INTO im_v2.user_shard_router_configuration
                (configuration_key, router_epoch, default_write_bucket, updated_at)
            VALUES (TRUE, \(bind: defaultRoute.observedRouterEpoch), \(bind: defaultRoute.bucket),
                    \(bind: now))
            ON CONFLICT (configuration_key) DO NOTHING
            """).run()
    }

    /// 查询整批用户的当前路由，保留输入顺序和重复项。
    ///
    /// - Parameter users: 用户列表，空列表不访问数据库。
    /// - Returns: 每个输入位置对应的路由；可空覆盖字段回退到默认配置字段。
    /// - Throws: 结果行数不匹配、路由校验、JSON 编码或数据库错误。
    public func routes(for users: [UserID]) async throws -> [V2UserShardRoute] {
        guard !users.isEmpty else { return [] }
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return try await routes(for: users, sql: sql)
    }

    /// 使用序号保持 JSON 输入顺序，以字段级 COALESCE 合并覆盖和默认配置，并检查结果数量。
    private func routes(
        for users: [UserID],
        sql: any SQLDatabase
    ) async throws -> [V2UserShardRoute] {
        let requestedJSON = try String(data: JSONEncoder().encode(users.map(\.rawValue)), encoding: .utf8)
        guard let requestedJSON else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let rows = try await sql.raw("""
            SELECT requested.ordinal, COALESCE(override.write_bucket, config.default_write_bucket) AS write_bucket,
                   COALESCE(override.router_epoch, config.router_epoch) AS router_epoch
            FROM jsonb_array_elements_text(\(bind: requestedJSON)::jsonb) WITH ORDINALITY AS requested(user_id, ordinal)
            CROSS JOIN im_v2.user_shard_router_configuration AS config
            LEFT JOIN im_v2.user_shard_route_overrides AS override
              ON override.user_id = requested.user_id::uuid
            WHERE config.configuration_key = TRUE
            ORDER BY requested.ordinal
            """).all(decoding: V2PostgresUserShardRouteRow.self)
        guard rows.count == users.count else { throw V2UserShardRouterError.resultCountMismatch }
        return try rows.map {
            try .init(bucket: $0.writeBucket, observedRouterEpoch: $0.routerEpoch)
        }
    }
}

extension V2PostgresUserShardRouter: V2UserShardRouteFencing {
    /// 在控制事务内读取默认与覆盖配置并执行业务回调。
    ///
    /// - Parameters:
    ///   - userID: 可转换为 UUID 的用户标识。
    ///   - operation: 在控制事务内执行的操作，可复用提供的控制事务。
    /// - Returns: 回调结果，事务成功后返回。
    /// - Throws: 配置缺失、标识或路由无效、数据库及回调错误。
    ///
    /// 不为外部数据库的已提交操作提供分布式回滚。
    public func withCurrentRoute<Result: Sendable>(
        for userID: UserID,
        _ operation: @escaping @Sendable (V2UserShardRoute, any Database) async throws -> Result
    ) async throws -> Result {
        try await withCurrentRoutes(for: [userID]) { routes, transaction in
            guard let route = routes.first else { throw V2UserShardRouterError.resultCountMismatch }
            return try await operation(route, transaction)
        }
    }
}

extension V2PostgresUserShardRouter: V2UserShardRouteBatchFencing {
    /// 校验用户集合，按原始请求顺序解析路由并执行回调。
    ///
    /// - Parameters:
    ///   - userIDs: 原始用户列表，最多允许 1,024 个不同 UUID；重复项仍保留在返回路由中。
    ///   - operation: 接收同序路由和控制事务的有界操作。
    /// - Returns: 回调结果。空列表也会打开事务并调用回调。
    /// - Throws: 不同用户超限或无效时抛出 `invalidRoute`；查询、配置、路由及回调错误传播。
    public func withCurrentRoutes<Result: Sendable>(
        for userIDs: [UserID],
        _ operation: @escaping @Sendable ([V2UserShardRoute], any Database) async throws -> Result
    ) async throws -> Result {
        guard !userIDs.isEmpty else {
            return try await database.transaction { transaction in
                try await operation([], transaction)
            }
        }
        let uniqueUserIDs = Array(Set(userIDs.map(\.rawValue))).sorted()
        guard uniqueUserIDs.count <= 1_024,
              uniqueUserIDs.allSatisfy({ UUID(uuidString: $0) != nil })
        else { throw V2UserShardRouterError.invalidRoute }

        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let routes = try await routes(for: userIDs, sql: sql)
            return try await operation(routes, transaction)
        }
    }
}

private struct V2PostgresUserShardRouteRow: Decodable {
    let ordinal: Int64
    let writeBucket: String
    let routerEpoch: Int64
    enum CodingKeys: String, CodingKey {
        case ordinal
        case writeBucket = "write_bucket"
        case routerEpoch = "router_epoch"
    }
}
