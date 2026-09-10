import Foundation
import Fluent
import IMV2Core
import SQLKit

/// 用户写入归属的逻辑桶、观察到的路由代次与可选读取回退桶。
///
/// 不包含物理数据库地址。投递持久化桶与代次用于后续一致性检查，读取回退不产生第二份投递。
public struct V2UserShardRoute: Equatable, Sendable {
    /// 规范化后的非空逻辑写入桶。
    public let bucket: String
    /// 本次解析观察到的非负路由代次。
    public let observedRouterEpoch: Int64
    /// 迁移期间可用于读取的旧归属桶，存在时必须非空且不同于写入桶。
    ///
    /// 仅作为读取回退，不能据此重复扇出写入。
    public let readFallbackBucket: String?

    /// 规范化桶名称并检查代次及回退关系。
    ///
    /// - Parameters:
    ///   - bucket: 写入桶，去除首尾空白后须非空。
    ///   - observedRouterEpoch: 非负路由代次。
    ///   - readFallbackBucket: 可选回退桶，规范化后须非空且不同于写入桶。
    /// - Throws: 任一约束不满足时抛出 `V2UserShardRouterError.invalidRoute`。
    public init(bucket: String, observedRouterEpoch: Int64, readFallbackBucket: String? = nil) throws {
        let normalizedBucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFallback = readFallbackBucket?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBucket.isEmpty,
              observedRouterEpoch >= 0,
              normalizedFallback.map({ !$0.isEmpty && $0 != normalizedBucket }) ?? true
        else {
            throw V2UserShardRouterError.invalidRoute
        }
        self.bucket = normalizedBucket
        self.observedRouterEpoch = observedRouterEpoch
        self.readFallbackBucket = normalizedFallback
    }

    /// 提取持久化扇出所需的写入桶与代次，不包含读取回退信息。
    public var writeIdentity: V2UserShardWriteIdentity {
        .init(bucket: bucket, observedRouterEpoch: observedRouterEpoch)
    }
}

/// 扇出投递持久化的写入归属身份，不携带读取回退或物理端点。
public struct V2UserShardWriteIdentity: Equatable, Sendable {
    /// 目标逻辑写入桶。
    public let bucket: String
    /// 计划该次投递时观察到的路由代次。
    public let observedRouterEpoch: Int64
}

/// 可注入且带代次的用户归属解析边界。
///
/// 扇出计划通过此接口获取归属，不在本地自行哈希标识推导目标桶。
public protocol V2UserShardRouter: Sendable {
    /// 按输入顺序为每个用户返回一个路由。
    ///
    /// - Parameter users: 有界批次中的用户列表，调用方负责选择合适批次规模。
    /// - Returns: 与输入数量和顺序相同的路由数组。
    /// - Throws: 配置缺失、结果不完整、路由无效或底层查询错误。
    func routes(for users: [UserID]) async throws -> [V2UserShardRoute]
}

/// 在控制面用户路由的共享保护范围内执行归属存储操作，与切换和回滚的独占保护互斥。
///
/// 回调可在控制事务仍打开时执行有界的跨库存储操作；这是路由一致性边界，不是通用跨库事务。
public protocol V2UserShardRouteFencing: Sendable {
    /// 在路由保护范围内调用业务操作。
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

/// 为有界用户集合在同一控制事务内取得共享路由保护。
///
/// 实现须按稳定顺序获取各用户锁，避免多用户请求采用相反锁顺序。
/// 批量接口减少控制面往返，不放宽每个用户在切换期间的保护约束。
public protocol V2UserShardRouteBatchFencing: Sendable {
    /// 在路由保护范围内调用业务操作。
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
    /// 桶、代次、回退关系或批量受保护请求参数无效。
    case invalidRoute
    /// 路由查询行数不等于请求用户数，例如默认配置缺失。
    case resultCountMismatch
}

/// 使用默认配置与用户覆盖记录解析逻辑归属的 PostgreSQL 路由器。
///
/// 每批重新读取控制面，仅返回逻辑桶与代次，不将物理地址写入投递记录。
/// 普通解析只提供查询快照；需要跨归属操作保护时应使用共享路由保护接口。
public struct V2PostgresUserShardRouter: V2UserShardRouter {
    private let database: any Database

    /// 保存支持 SQL 的控制面数据库，不立即查询配置。
    ///
    /// - Parameter database: 路由配置与覆盖记录所在数据库。
    public init(database: any Database) { self.database = database }

    /// 首次部署插入默认路由配置，已存在配置时保持原值。
    ///
    /// - Parameters:
    ///   - defaultRoute: 新部署的默认写入桶、代次与回退桶。
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
                (configuration_key, router_epoch, default_write_bucket, default_read_fallback_bucket, updated_at)
            VALUES (TRUE, \(bind: defaultRoute.observedRouterEpoch), \(bind: defaultRoute.bucket),
                    \(bind: defaultRoute.readFallbackBucket), \(bind: now))
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
                   COALESCE(override.router_epoch, config.router_epoch) AS router_epoch,
                   COALESCE(override.read_fallback_bucket, config.default_read_fallback_bucket) AS read_fallback_bucket
            FROM jsonb_array_elements_text(\(bind: requestedJSON)::jsonb) WITH ORDINALITY AS requested(user_id, ordinal)
            CROSS JOIN im_v2.user_shard_router_configuration AS config
            LEFT JOIN im_v2.user_shard_route_overrides AS override
              ON override.user_id = requested.user_id::uuid
            WHERE config.configuration_key = TRUE
            ORDER BY requested.ordinal
            """).all(decoding: V2PostgresUserShardRouteRow.self)
        guard rows.count == users.count else { throw V2UserShardRouterError.resultCountMismatch }
        return try rows.map {
            try .init(bucket: $0.writeBucket, observedRouterEpoch: $0.routerEpoch, readFallbackBucket: $0.readFallbackBucket)
        }
    }
}

extension V2PostgresUserShardRouter: V2UserShardRouteFencing {
    /// 在控制事务内取得该用户共享建议锁，再读取默认与覆盖配置并执行业务回调。
    ///
    /// - Parameters:
    ///   - userID: 可转换为 UUID 的用户标识。
    ///   - operation: 在共享锁仍被持有时执行的操作，可复用提供的控制事务。
    /// - Returns: 回调结果，事务成功后返回。
    /// - Throws: 配置缺失、标识或路由无效、数据库及回调错误。
    ///
    /// 不为外部数据库的已提交操作提供分布式回滚。
    public func withCurrentRoute<Result: Sendable>(
        for userID: UserID,
        _ operation: @escaping @Sendable (V2UserShardRoute, any Database) async throws -> Result
    ) async throws -> Result {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let userUUID = UUID(uuidString: userID.rawValue)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await sql.raw("SELECT pg_advisory_xact_lock_shared(hashtextextended(\(bind: userID.rawValue), 0))").run()
            guard let configuration = try await sql.raw("""
                SELECT router_epoch, default_write_bucket, default_read_fallback_bucket
                FROM im_v2.user_shard_router_configuration
                WHERE configuration_key = TRUE
                """).first(decoding: V2PostgresFencedRouterConfigurationRow.self)
            else { throw V2UserShardRouteControlError.missingRouterConfiguration }
            let override = try await sql.raw("""
                SELECT write_bucket, read_fallback_bucket, router_epoch
                FROM im_v2.user_shard_route_overrides
                WHERE user_id = \(bind: userUUID)
                """).first(decoding: V2UserShardRouteOverrideRow.self)
            let route = try V2UserShardRoute(
                bucket: override?.writeBucket ?? configuration.defaultWriteBucket,
                observedRouterEpoch: override?.routerEpoch ?? configuration.routerEpoch,
                readFallbackBucket: override?.readFallbackBucket ?? configuration.defaultReadFallbackBucket
            )
            return try await operation(route, transaction)
        }
    }
}

extension V2PostgresUserShardRouter: V2UserShardRouteBatchFencing {
    /// 以稳定顺序锁定去重后的用户集合，再按原始请求顺序解析路由并执行回调。
    ///
    /// - Parameters:
    ///   - userIDs: 原始用户列表，最多允许 1,024 个不同 UUID；重复项仍保留在返回路由中。
    ///   - operation: 接收同序路由和控制事务的有界操作。
    /// - Returns: 回调结果。空列表也会打开事务并调用回调，只是不获取用户锁。
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
              uniqueUserIDs.allSatisfy({ UUID(uuidString: $0) != nil }),
              let requestedJSON = String(
                  data: try JSONEncoder().encode(uniqueUserIDs),
                  encoding: .utf8
              )
        else { throw V2UserShardRouterError.invalidRoute }

        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            // Materialization and the outer ordering make every participant
            // acquire multi-user fences in the same order. PostgreSQL's
            // transaction-level advisory locks are released automatically on
            // commit or rollback.
            try await sql.raw("""
                WITH ordered_users AS MATERIALIZED (
                    SELECT value
                    FROM jsonb_array_elements_text(\(bind: requestedJSON)::jsonb)
                         AS requested(value)
                    ORDER BY value
                )
                SELECT pg_advisory_xact_lock_shared(
                    hashtextextended(ordered_users.value, 0)
                )
                FROM ordered_users
                ORDER BY ordered_users.value
                """).run()
            let routes = try await routes(for: userIDs, sql: sql)
            return try await operation(routes, transaction)
        }
    }
}

/// 单用户逻辑写入归属的切换命令，携带幂等标识和预期全局路由代次。
///
/// 构造只验证路由值，不执行复制或检查迁移记录；控制器要求迁移已验证，并在发布前最终同步。
public struct V2UserShardRouteCutover: Sendable {
    /// 切换操作幂等标识。
    public let operationID: UUID
    /// 需要切换的用户。
    public let userID: UserID
    /// 预期全局配置代次，新操作须与锁定配置相等。
    public let expectedRouterEpoch: Int64
    /// 去除首尾空白后的目标写入桶。
    public let newWriteBucket: String
    /// 可选读取回退桶；实际迁移切换要求匹配记录中的源桶。
    public let readFallbackBucket: String?

    /// 校验并规范化命令中的路由值，不检查迁移阶段或持久化代次。
    ///
    /// - Parameters:
    ///   - operationID: 幂等标识。
    ///   - userID: 目标用户。
    ///   - expectedRouterEpoch: 非负预期代次。
    ///   - newWriteBucket: 非空目标桶。
    ///   - readFallbackBucket: 可选的非空回退桶，不能与目标相同。
    /// - Throws: 路由值无效时抛出 `invalidRoute`。
    public init(operationID: UUID, userID: UserID, expectedRouterEpoch: Int64, newWriteBucket: String, readFallbackBucket: String?) throws {
        _ = try V2UserShardRoute(bucket: newWriteBucket, observedRouterEpoch: expectedRouterEpoch, readFallbackBucket: readFallbackBucket)
        self.operationID = operationID
        self.userID = userID
        self.expectedRouterEpoch = expectedRouterEpoch
        self.newWriteBucket = newWriteBucket.trimmingCharacters(in: .whitespacesAndNewlines)
        self.readFallbackBucket = readFallbackBucket?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 路由控制操作的阶段、代次、幂等与最终同步错误。
public enum V2UserShardRouteControlError: Error, Equatable, Sendable {
    /// 预期代次不匹配；回滚流程中全局配置缺失也使用此错误。
    case staleRouterEpoch
    /// 已有操作记录或迁移切换关联与请求不一致。
    case operationConflict
    /// 所需默认路由配置缺失。
    case missingRouterConfiguration
    /// 迁移不存在、未验证，或已不满足回滚保留条件。
    case migrationNotVerified
    /// 迁移源、目标、代次或当前覆盖路由与请求不一致。
    case migrationConflict
    /// 最终同步或校验抛错，底层错误被归并为此固定类别。
    case finalVerificationFailed
}

/// 切换与回滚共用的结果，可能来自本次变更或历史操作重放。
public struct V2UserShardRouteCutoverResult: Equatable, Sendable {
    /// 操作产生或历史记录保存的路由，不保证重放时仍是最新归属。
    public let route: V2UserShardRoute
    /// 是否直接复用已有操作记录。
    public let wasIdempotent: Bool

    /// 保存控制操作结果。
    ///
    /// - Parameters:
    ///   - route: 操作结果路由。
    ///   - wasIdempotent: 是否为历史操作重放。
    public init(route: V2UserShardRoute, wasIdempotent: Bool) {
        self.route = route
        self.wasIdempotent = wasIdempotent
    }
}

/// 请求将仍满足保留条件的用户恢复到原始源写入桶。
///
/// 不接受调用方另选桶，源与目标来自已持久化的迁移记录。构造不验证保留窗口。
public struct V2UserShardRouteRollback: Sendable {
    /// 回滚操作的幂等标识。
    public let operationID: UUID
    /// 回滚用户。
    public let userID: UserID
    /// 非负预期当前路由代次。
    public let expectedRouterEpoch: Int64

    /// 保存回滚请求并验证预期代次非负。
    ///
    /// - Parameters:
    ///   - operationID: 回滚幂等标识。
    ///   - userID: 目标用户。
    ///   - expectedRouterEpoch: 非负预期代次。
    /// - Throws: 负代次抛出 `invalidRoute`。
    public init(operationID: UUID, userID: UserID, expectedRouterEpoch: Int64) throws {
        guard expectedRouterEpoch >= 0 else { throw V2UserShardRouterError.invalidRoute }
        self.operationID = operationID
        self.userID = userID
        self.expectedRouterEpoch = expectedRouterEpoch
    }
}

/// 向运维传输层暴露用户路由切换能力。
public protocol V2UserShardRouteCutoverHandling: Sendable {
    /// 执行受代次与迁移状态约束的切换。
    ///
    /// - Parameter command: 已构造的控制命令。
    /// - Returns: 路由结果及是否幂等重放。
    /// - Throws: 阶段、代次、操作冲突、最终同步或存储错误。
    func cutOver(_ command: V2UserShardRouteCutover) async throws -> V2UserShardRouteCutoverResult
}

/// 向运维传输层暴露用户路由回滚能力。
public protocol V2UserShardRouteRollbackHandling: Sendable {
    /// 执行受代次与迁移状态约束的回滚。
    ///
    /// - Parameter command: 已构造的控制命令。
    /// - Returns: 路由结果及是否幂等重放。
    /// - Throws: 阶段、代次、操作冲突、最终同步或存储错误。
    func rollBack(_ command: V2UserShardRouteRollback) async throws -> V2UserShardRouteCutoverResult
}

/// PostgreSQL 用户路由切换与回滚控制器，原子更新控制面配置、覆盖、操作与迁移记录。
///
/// 通过用户独占建议锁与普通读写的共享路由保护互斥。最终同步器在控制事务内调用，
/// 外部数据库已完成的复制或重建不因控制事务回滚而自动撤销。
/// 操作员身份用于审计及重放匹配，入口鉴权由调用方负责。
public struct V2PostgresUserShardRouteControl: Sendable {
    private let database: any Database
    private let operatorPrincipal: String
    private let retentionWindow: TimeInterval
    private let finalizer: any V2UserShardCutoverFinalizing

    /// 配置控制数据库、操作员身份、源端保留时长和最终同步器。
    ///
    /// - Parameters:
    ///   - database: 支持 SQL 的控制面数据库。
    ///   - operatorPrincipal: 通过固定操作员身份规则验证的审计主体。
    ///   - retentionWindow: 源端保留秒数，默认一天，须为正。
    ///   - finalizer: 在独占保护内完成最终复制与校验的组件。
    /// - Precondition: 主体符合规则，保留时长大于零；日期可编码性在新切换时验证。
    public init(
        database: any Database, operatorPrincipal: String,
        retentionWindow: TimeInterval = 86_400,
        finalizer: any V2UserShardCutoverFinalizing
    ) {
        precondition(V2DurableWorkOperatorReplayService.isValidPrincipal(operatorPrincipal))
        precondition(retentionWindow > 0)
        self.database = database
        self.operatorPrincipal = operatorPrincipal
        self.retentionWindow = retentionWindow
        self.finalizer = finalizer
    }

    /// 最终同步后切换写入桶，递增全局代次并使迁移进入保留阶段。
    ///
    /// 优先查找操作重放，匹配用户、主体、写入桶和回退桶后直接返回历史结果，不再检查
    /// 本次预期代次或时间。新操作先锁全局配置并检查代次，再取得用户独占锁和迁移行锁。
    /// verified 迁移的源、目标及源代次须匹配命令，最终同步成功后在同一控制事务中发布变更。
    ///
    /// - Parameters:
    ///   - command: 切换命令。
    ///   - now: 新操作的更新与保留期基准时间，默认当前时间。
    /// - Returns: 新路由或幂等历史结果。
    /// - Throws: 控制约束、时间范围、SQL 或数据库错误；最终同步器的所有错误归并为
    ///   `finalVerificationFailed`。控制事务失败不撤销外部已提交复制。
    public func cutOver(_ command: V2UserShardRouteCutover, now: Date = Date()) async throws -> V2UserShardRouteCutoverResult {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            if let replay = try await sql.raw("""
                SELECT operator_principal, user_id, write_bucket, read_fallback_bucket, resulting_router_epoch
                FROM im_v2.user_shard_route_operations WHERE operation_id = \(bind: command.operationID)
                """).first(decoding: V2UserShardRouteOperationRow.self) {
                guard replay.userID == (try v2UUID(command.userID)),
                      replay.operatorPrincipal == operatorPrincipal,
                      replay.writeBucket == command.newWriteBucket,
                      replay.readFallbackBucket == command.readFallbackBucket
                else { throw V2UserShardRouteControlError.operationConflict }
                return .init(route: try .init(bucket: replay.writeBucket, observedRouterEpoch: replay.resultingRouterEpoch, readFallbackBucket: replay.readFallbackBucket), wasIdempotent: true)
            }
            guard let retentionUntil = v2PostgresFutureTimestamp(now: now, interval: retentionWindow),
                  command.expectedRouterEpoch < Int64.max
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard let configuration = try await sql.raw("""
                SELECT router_epoch FROM im_v2.user_shard_router_configuration
                WHERE configuration_key = TRUE FOR UPDATE
                """).first(decoding: V2PostgresRouterConfigurationRow.self)
            else { throw V2UserShardRouteControlError.missingRouterConfiguration }
            guard configuration.routerEpoch == command.expectedRouterEpoch else { throw V2UserShardRouteControlError.staleRouterEpoch }
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: command.userID.rawValue), 0))").run()
            guard let migration = try await sql.raw("""
                SELECT migration_id, source_bucket, target_bucket, source_router_epoch, phase, cutover_operation_id
                FROM im_v2.user_shard_migrations
                WHERE user_id = \(bind: try v2UUID(command.userID))
                FOR UPDATE
                """).first(decoding: V2UserShardCutoverMigrationRow.self)
            else { throw V2UserShardRouteControlError.migrationNotVerified }
            guard migration.sourceBucket == command.readFallbackBucket,
                  migration.targetBucket == command.newWriteBucket,
                  migration.sourceRouterEpoch == command.expectedRouterEpoch
            else { throw V2UserShardRouteControlError.migrationConflict }
            guard migration.phase == .verified else { throw V2UserShardRouteControlError.migrationNotVerified }
            guard migration.cutoverOperationID == nil || migration.cutoverOperationID == command.operationID else {
                throw V2UserShardRouteControlError.operationConflict
            }
            do {
                try await finalizer.finalizeForCutover(
                    migrationID: migration.migrationID, userID: command.userID,
                    sourceBucket: migration.sourceBucket, targetBucket: migration.targetBucket,
                    sourceRouterEpoch: migration.sourceRouterEpoch,
                    controlTransaction: transaction
                )
            } catch {
                throw V2UserShardRouteControlError.finalVerificationFailed
            }
            let cutoverPhase = try V2UserShardMigrationStateMachine.transition(from: migration.phase, by: .cutOver)
            let migrationPhase = try V2UserShardMigrationStateMachine.transition(from: cutoverPhase, by: .beginRetention)
            let resultingEpoch = configuration.routerEpoch + 1
            try await sql.raw("""
                INSERT INTO im_v2.user_shard_route_overrides
                    (user_id, write_bucket, read_fallback_bucket, router_epoch, updated_at)
                VALUES (\(bind: try v2UUID(command.userID)), \(bind: command.newWriteBucket), \(bind: command.readFallbackBucket), \(bind: resultingEpoch), \(bind: now))
                ON CONFLICT (user_id) DO UPDATE
                SET write_bucket = EXCLUDED.write_bucket,
                    read_fallback_bucket = EXCLUDED.read_fallback_bucket,
                    router_epoch = EXCLUDED.router_epoch,
                    updated_at = EXCLUDED.updated_at
                """).run()
            try await sql.raw("""
                UPDATE im_v2.user_shard_router_configuration
                SET router_epoch = \(bind: resultingEpoch), updated_at = \(bind: now)
                WHERE configuration_key = TRUE
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.user_shard_route_operations
                    (operation_id, operator_principal, user_id, write_bucket, read_fallback_bucket, resulting_router_epoch, created_at)
                VALUES (\(bind: command.operationID), \(bind: operatorPrincipal), \(bind: try v2UUID(command.userID)), \(bind: command.newWriteBucket), \(bind: command.readFallbackBucket), \(bind: resultingEpoch), \(bind: now))
                """).run()
            try await sql.raw("""
                UPDATE im_v2.user_shard_migrations
                SET phase = \(bind: migrationPhase.rawValue),
                    cutover_operation_id = \(bind: command.operationID),
                    retention_until = \(bind: retentionUntil),
                    retention_claim_token = NULL, retention_claim_expires_at = NULL,
                    updated_at = \(bind: now)
                WHERE migration_id = \(bind: migration.migrationID) AND phase = 'verified' AND cutover_operation_id IS NULL
                """).run()
            return .init(route: try .init(bucket: command.newWriteBucket, observedRouterEpoch: resultingEpoch, readFallbackBucket: command.readFallbackBucket), wasIdempotent: false)
        }
    }

    /// 在源端尚可保留恢复时重建源端并回滚归属，递增代次且标记迁移 rolledBack。
    ///
    /// 先锁迁移行，再尝试历史操作重放。新回滚要求 retention 阶段、无清理领取令牌，且保留期限
    /// 按数据库微秒精度严格晚于当前时间。取得用户独占锁后执行最终重建，再检查全局代次
    /// 与当前覆盖路由；这些后续检查失败时不会撤销外部已经完成的重建。
    ///
    /// - Parameters:
    ///   - command: 不携带桶选择的回滚命令。
    ///   - now: 检查保留期与更新记录的基准时间，默认当前时间。
    /// - Returns: 源桶作为写入桶、目标桶作为读取回退的新路由，或幂等历史结果。
    /// - Throws: 保留条件、阶段、代次、归属冲突及数据库错误；最终同步错误归并为
    ///   `finalVerificationFailed`。重放仍要求迁移记录存在，但不重新检查窗口或预期代次。
    public func rollBack(_ command: V2UserShardRouteRollback, now: Date = Date()) async throws -> V2UserShardRouteCutoverResult {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard let migration = try await sql.raw("""
                SELECT migration_id, source_bucket, target_bucket, source_router_epoch, phase,
                       cutover_operation_id, retention_until, retention_claim_token
                FROM im_v2.user_shard_migrations
                WHERE user_id = \(bind: try v2UUID(command.userID)) FOR UPDATE
                """).first(decoding: V2UserShardCutoverMigrationRow.self)
            else { throw V2UserShardRouteControlError.migrationNotVerified }
            if let replay = try await sql.raw("""
                SELECT operator_principal, user_id, write_bucket, read_fallback_bucket, resulting_router_epoch
                FROM im_v2.user_shard_route_operations WHERE operation_id = \(bind: command.operationID)
                """).first(decoding: V2UserShardRouteOperationRow.self) {
                guard replay.userID == (try v2UUID(command.userID)),
                      replay.operatorPrincipal == operatorPrincipal,
                      replay.writeBucket == migration.sourceBucket,
                      replay.readFallbackBucket == migration.targetBucket
                else { throw V2UserShardRouteControlError.operationConflict }
                return .init(route: try .init(bucket: replay.writeBucket, observedRouterEpoch: replay.resultingRouterEpoch, readFallbackBucket: replay.readFallbackBucket), wasIdempotent: true)
            }
            guard v2PostgresTimestampCanEncode(now), command.expectedRouterEpoch < Int64.max else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let currentTime = try V2PostgresTimestamp(date: now)
            // Cleanup runs outside this transaction after its durable claim.
            // A backwards clock cannot make a source already being cleaned
            // safe for rollback; the shared row lock orders these decisions.
            guard migration.phase == .retention, migration.retentionClaimToken == nil,
                  let retentionUntil = migration.retentionUntil,
                  retentionUntil.microseconds > currentTime.microseconds
            else { throw V2UserShardRouteControlError.migrationNotVerified }
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: command.userID.rawValue), 0))").run()
            do {
                try await finalizer.finalizeForRollback(
                    migrationID: migration.migrationID, userID: command.userID,
                    sourceBucket: migration.sourceBucket, targetBucket: migration.targetBucket,
                    sourceRouterEpoch: migration.sourceRouterEpoch,
                    controlTransaction: transaction
                )
            } catch {
                throw V2UserShardRouteControlError.finalVerificationFailed
            }
            guard let configuration = try await sql.raw("""
                SELECT router_epoch FROM im_v2.user_shard_router_configuration
                WHERE configuration_key = TRUE FOR UPDATE
                """).first(decoding: V2PostgresRouterConfigurationRow.self),
                configuration.routerEpoch == command.expectedRouterEpoch
            else { throw V2UserShardRouteControlError.staleRouterEpoch }
            guard let current = try await sql.raw("""
                SELECT write_bucket, read_fallback_bucket, router_epoch
                FROM im_v2.user_shard_route_overrides
                WHERE user_id = \(bind: try v2UUID(command.userID)) FOR UPDATE
                """).first(decoding: V2UserShardRouteOverrideRow.self),
                current.writeBucket == migration.targetBucket,
                current.readFallbackBucket == migration.sourceBucket,
                current.routerEpoch == command.expectedRouterEpoch
            else { throw V2UserShardRouteControlError.migrationConflict }
            let rolledBack = try V2UserShardMigrationStateMachine.transition(from: .retention, by: .rollback)
            let resultingEpoch = configuration.routerEpoch + 1
            try await sql.raw("""
                UPDATE im_v2.user_shard_route_overrides
                SET write_bucket = \(bind: migration.sourceBucket),
                    read_fallback_bucket = \(bind: migration.targetBucket),
                    router_epoch = \(bind: resultingEpoch), updated_at = \(bind: now)
                WHERE user_id = \(bind: try v2UUID(command.userID))
                """).run()
            try await sql.raw("""
                UPDATE im_v2.user_shard_router_configuration
                SET router_epoch = \(bind: resultingEpoch), updated_at = \(bind: now)
                WHERE configuration_key = TRUE
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.user_shard_route_operations
                    (operation_id, operator_principal, user_id, write_bucket, read_fallback_bucket, resulting_router_epoch, created_at)
                VALUES (\(bind: command.operationID), \(bind: operatorPrincipal), \(bind: try v2UUID(command.userID)),
                        \(bind: migration.sourceBucket), \(bind: migration.targetBucket), \(bind: resultingEpoch), \(bind: now))
                """).run()
            try await sql.raw("""
                UPDATE im_v2.user_shard_migrations
                SET phase = \(bind: rolledBack.rawValue), retention_until = NULL,
                    retention_claim_token = NULL, retention_claim_expires_at = NULL, updated_at = \(bind: now)
                WHERE migration_id = \(bind: migration.migrationID) AND phase = 'retention'
                """).run()
            return .init(route: try .init(
                bucket: migration.sourceBucket, observedRouterEpoch: resultingEpoch,
                readFallbackBucket: migration.targetBucket
            ), wasIdempotent: false)
        }
    }
}

extension V2PostgresUserShardRouteControl: V2UserShardRouteCutoverHandling {
    /// 使用系统当前日期调用显式时间版本。
    ///
    /// - Parameter command: 控制命令。
    /// - Returns: 操作结果及幂等标记。
    /// - Throws: 底层控制方法的错误原样传播。
    public func cutOver(_ command: V2UserShardRouteCutover) async throws -> V2UserShardRouteCutoverResult {
        try await cutOver(command, now: Date())
    }
}

extension V2PostgresUserShardRouteControl: V2UserShardRouteRollbackHandling {
    /// 使用系统当前日期调用显式时间版本。
    ///
    /// - Parameter command: 控制命令。
    /// - Returns: 操作结果及幂等标记。
    /// - Throws: 底层控制方法的错误原样传播。
    public func rollBack(_ command: V2UserShardRouteRollback) async throws -> V2UserShardRouteCutoverResult {
        try await rollBack(command, now: Date())
    }
}

private struct V2PostgresUserShardRouteRow: Decodable {
    let ordinal: Int64
    let writeBucket: String
    let routerEpoch: Int64
    let readFallbackBucket: String?
    enum CodingKeys: String, CodingKey {
        case ordinal
        case writeBucket = "write_bucket"
        case routerEpoch = "router_epoch"
        case readFallbackBucket = "read_fallback_bucket"
    }
}

private struct V2PostgresRouterConfigurationRow: Decodable {
    let routerEpoch: Int64
    enum CodingKeys: String, CodingKey { case routerEpoch = "router_epoch" }
}

private struct V2PostgresFencedRouterConfigurationRow: Decodable {
    let routerEpoch: Int64
    let defaultWriteBucket: String
    let defaultReadFallbackBucket: String?
    enum CodingKeys: String, CodingKey {
        case routerEpoch = "router_epoch"
        case defaultWriteBucket = "default_write_bucket"
        case defaultReadFallbackBucket = "default_read_fallback_bucket"
    }
}

private struct V2UserShardRouteOperationRow: Decodable {
    let operatorPrincipal: String
    let userID: UUID
    let writeBucket: String
    let readFallbackBucket: String?
    let resultingRouterEpoch: Int64
    enum CodingKeys: String, CodingKey {
        case operatorPrincipal = "operator_principal"
        case userID = "user_id"
        case writeBucket = "write_bucket"
        case readFallbackBucket = "read_fallback_bucket"
        case resultingRouterEpoch = "resulting_router_epoch"
    }
}

private struct V2UserShardCutoverMigrationRow: Decodable {
    let migrationID: UUID
    let sourceBucket: String
    let targetBucket: String
    let sourceRouterEpoch: Int64
    let phase: V2UserShardMigrationPhase
    let cutoverOperationID: UUID?
    let retentionUntil: V2PostgresTimestamp?
    let retentionClaimToken: UUID?

    enum CodingKeys: String, CodingKey {
        case migrationID = "migration_id", sourceBucket = "source_bucket", targetBucket = "target_bucket"
        case sourceRouterEpoch = "source_router_epoch", phase, cutoverOperationID = "cutover_operation_id", retentionUntil = "retention_until"
        case retentionClaimToken = "retention_claim_token"
    }
}

private struct V2UserShardRouteOverrideRow: Decodable {
    let writeBucket: String
    let readFallbackBucket: String?
    let routerEpoch: Int64
    enum CodingKeys: String, CodingKey {
        case writeBucket = "write_bucket", readFallbackBucket = "read_fallback_bucket", routerEpoch = "router_epoch"
    }
}

private func v2UUID(_ userID: UserID) throws -> UUID {
    guard let value = UUID(uuidString: userID.rawValue) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}
