import IMV2ServerApplication
import IMV2ServerContracts
import Foundation

/// 网关按延迟与持久化工作类别划分的独立 PostgreSQL 连接池预算。
///
/// 各项之和仍受进程级每事件循环上限约束，因此工作类别隔离不会悄悄抬高部署的数据库连接预算。
public struct V2PostgresWorkloadPoolBudget: Equatable, Sendable {
    /// 工作类别。
    public enum Role: String, CaseIterable, Sendable {
        /// 前台请求路径。
        case messageWrite = "message_write"
        case foreground
        /// 同步读取路径。
        case sync
        /// 投递路径。
        case delivery
        /// 投影路径。
        case projection
        /// 维护路径。
        case maintenance
    }

    /// 前台路径每事件循环连接数。
    public let messageWriteConnectionsPerEventLoop: Int
    public let foregroundConnectionsPerEventLoop: Int
    /// 同步路径每事件循环连接数。
    public let syncConnectionsPerEventLoop: Int
    /// 投递路径每事件循环连接数。
    public let deliveryConnectionsPerEventLoop: Int
    /// 投影路径每事件循环连接数。
    public let projectionConnectionsPerEventLoop: Int
    /// 维护路径每事件循环连接数。
    public let maintenanceConnectionsPerEventLoop: Int

    /// 从运行环境读取各项连接预算。
    ///
    /// - Parameter environment: 读取环境变量的运行时视图。
    /// - Throws: 任一变量缺失时抛出
    ///   ``V2GatewayRuntimeConfigurationError/missing(_:)``；
    ///   取值非整数或不在 `1...256` 时抛出 ``V2GatewayRuntimeConfigurationError/invalid(_:)``。
    public init(environment: any V2RuntimeEnvironment) throws {
        if let raw = environment.value(for: "IM_V2_DATABASE_MESSAGE_WRITE_CONNECTIONS_PER_EVENT_LOOP") {
            guard let value = Int(raw), (1...256).contains(value) else {
                throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_DATABASE_MESSAGE_WRITE_CONNECTIONS_PER_EVENT_LOOP")
            }
            messageWriteConnectionsPerEventLoop = value
        } else { messageWriteConnectionsPerEventLoop = 0 }
        foregroundConnectionsPerEventLoop = try Self.value(
            "IM_V2_DATABASE_FOREGROUND_CONNECTIONS_PER_EVENT_LOOP", environment: environment
        )
        syncConnectionsPerEventLoop = try Self.value(
            "IM_V2_DATABASE_SYNC_CONNECTIONS_PER_EVENT_LOOP", environment: environment
        )
        deliveryConnectionsPerEventLoop = try Self.value(
            "IM_V2_DATABASE_DELIVERY_CONNECTIONS_PER_EVENT_LOOP", environment: environment
        )
        projectionConnectionsPerEventLoop = try Self.value(
            "IM_V2_DATABASE_PROJECTION_CONNECTIONS_PER_EVENT_LOOP", environment: environment
        )
        maintenanceConnectionsPerEventLoop = try Self.value(
            "IM_V2_DATABASE_MAINTENANCE_CONNECTIONS_PER_EVENT_LOOP", environment: environment
        )
    }

    /// 各工作类别每事件循环连接数之和。
    public var totalConnectionsPerEventLoop: Int {
        messageWriteConnectionsPerEventLoop + foregroundConnectionsPerEventLoop + syncConnectionsPerEventLoop
            + deliveryConnectionsPerEventLoop + projectionConnectionsPerEventLoop
            + maintenanceConnectionsPerEventLoop
    }

    /// 读取指定工作类别的每事件循环连接数。
    ///
    /// - Parameter role: 工作类别。
    /// - Returns: 该类别的连接预算。
    public func connectionsPerEventLoop(for role: Role) -> Int {
        switch role {
        case .messageWrite: messageWriteConnectionsPerEventLoop
        case .foreground: foregroundConnectionsPerEventLoop
        case .sync: syncConnectionsPerEventLoop
        case .delivery: deliveryConnectionsPerEventLoop
        case .projection: projectionConnectionsPerEventLoop
        case .maintenance: maintenanceConnectionsPerEventLoop
        }
    }

    /// 读取必需的连接数环境变量。
    ///
    /// - Parameters:
    ///   - key: 环境变量名。
    ///   - environment: 运行时环境视图。
    /// - Returns: 介于 1 与 256 之间的取值。
    /// - Throws: 变量缺失时抛出 ``V2GatewayRuntimeConfigurationError/missing(_:)``；
    ///   取值非法时抛出 ``V2GatewayRuntimeConfigurationError/invalid(_:)``。
    private static func value(
        _ key: String,
        environment: any V2RuntimeEnvironment
    ) throws -> Int {
        guard let raw = environment.value(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { throw V2GatewayRuntimeConfigurationError.missing(key) }
        guard let value = Int(raw), (1 ... 256).contains(value) else {
            throw V2GatewayRuntimeConfigurationError.invalid(key)
        }
        return value
    }
}

/// 进程级统一的 PostgreSQL 资源与超时策略。
///
/// 每个物理连接池都依据该值创建，因此新增用户分片库不会悄悄放大连接数，
/// 也不会产生无界的查询或锁等待。
public struct V2PostgresRuntimePolicy: Equatable, Sendable {
    /// 事件循环线程数上限。
    public let eventLoopThreads: Int
    /// 每事件循环最大连接数。
    public let maximumConnectionsPerEventLoop: Int
    /// 进程最大连接总数。
    public let maximumTotalConnections: Int
    /// 允许配置的用户分片库数量上限。
    public let maximumUserShardStores: Int
    /// 建连超时毫秒数。
    public let connectTimeoutMilliseconds: Int
    /// 连接池等待超时毫秒数。
    public let poolTimeoutMilliseconds: Int
    /// 语句超时毫秒数。
    public let statementTimeoutMilliseconds: Int
    /// 锁等待超时毫秒数。
    public let lockTimeoutMilliseconds: Int
    /// 空闲事务超时毫秒数。
    public let idleTransactionTimeoutMilliseconds: Int

    /// 从运行环境读取并校验运行时策略。
    ///
    /// 各项都有独立上限；锁等待超时必须不超过语句超时，否则长时间持锁的语句会在
    /// 锁超时之前就被语句超时打断，策略失去意义。
    ///
    /// - Parameter environment: 读取环境变量的运行时视图。
    /// - Throws: 任一变量缺失时抛出
    ///   ``V2GatewayRuntimeConfigurationError/missing(_:)``；取值越界或锁超时大于语句超时时抛出
    ///   ``V2GatewayRuntimeConfigurationError/invalid(_:)``。
    public init(environment: any V2RuntimeEnvironment) throws {
        eventLoopThreads = try Self.boundedPositive(
            "IM_V2_DATABASE_EVENT_LOOP_THREADS", maximum: 64, environment: environment
        )
        maximumConnectionsPerEventLoop = try Self.boundedPositive(
            "IM_V2_DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP", maximum: 256, environment: environment
        )
        maximumTotalConnections = try Self.boundedPositive(
            "IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS", maximum: 100_000, environment: environment
        )
        maximumUserShardStores = try Self.boundedPositive(
            "IM_V2_MAX_USER_SHARD_STORES", maximum: 64, environment: environment
        )
        connectTimeoutMilliseconds = try Self.boundedPositive(
            "IM_V2_DATABASE_CONNECT_TIMEOUT_MS", maximum: 60_000, environment: environment
        )
        poolTimeoutMilliseconds = try Self.boundedPositive(
            "IM_V2_DATABASE_POOL_TIMEOUT_MS", maximum: 60_000, environment: environment
        )
        statementTimeoutMilliseconds = try Self.boundedPositive(
            "IM_V2_DATABASE_STATEMENT_TIMEOUT_MS", maximum: 300_000, environment: environment
        )
        lockTimeoutMilliseconds = try Self.boundedPositive(
            "IM_V2_DATABASE_LOCK_TIMEOUT_MS", maximum: 300_000, environment: environment
        )
        idleTransactionTimeoutMilliseconds = try Self.boundedPositive(
            "IM_V2_DATABASE_IDLE_TRANSACTION_TIMEOUT_MS", maximum: 3_600_000, environment: environment
        )
        guard lockTimeoutMilliseconds <= statementTimeoutMilliseconds else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_DATABASE_LOCK_TIMEOUT_MS/IM_V2_DATABASE_STATEMENT_TIMEOUT_MS"
            )
        }
    }

    /// 通过启动参数下发的会话级 GUC 配置。
    ///
    /// PostgreSQL 允许在启动包的 `options` 中设置会话参数；与在某条借出的连接上执行 `SET` 不同，
    /// 该方式对 Fluent 当前及连接池替换之后创建的所有连接都生效。
    public var startupParameters: [(String, String)] {
        [("options", [
            "-c statement_timeout=\(statementTimeoutMilliseconds)",
            "-c lock_timeout=\(lockTimeoutMilliseconds)",
            "-c idle_in_transaction_session_timeout=\(idleTransactionTimeoutMilliseconds)",
        ].joined(separator: " "))]
    }

    /// 校验主库与用户分片库是否满足资源上限。
    ///
    /// - Parameters:
    ///   - primaryDatabaseURL: 主库连接地址。
    ///   - userShardStorage: 用户分片存储配置。
    /// - Throws: 分片数量超过上限，或连接总量超出进程预算时抛出
    ///   ``V2GatewayRuntimeConfigurationError/invalid(_:)``。
    public func validate(primaryDatabaseURL: String, userShardStorage: [V2UserShardStorageConfiguration]) throws {
        guard userShardStorage.count <= maximumUserShardStores else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_MAX_USER_SHARD_STORES")
        }
        try validate(databaseURLs: [primaryDatabaseURL] + userShardStorage.map(\.databaseURL))
    }

    /// 按默认的单池策略校验一组数据库地址。
    ///
    /// - Parameter databaseURLs: 待校验的连接地址。
    /// - Throws: 地址列表为空、连接数非法或总量超出预算时抛出
    ///   ``V2GatewayRuntimeConfigurationError/invalid(_:)``。
    public func validate(databaseURLs: [String]) throws {
        try validate(
            databaseURLs: databaseURLs,
            connectionsPerEventLoopPerPhysicalStore: maximumConnectionsPerEventLoop
        )
    }

    /// 校验网关按工作类别划分的多池总预算，同时不改变账号与运维进程使用的旧单池策略。
    ///
    /// 去重后的物理库数量乘以事件循环线程数再乘以单池连接数，必须不超过进程总连接上限；
    /// 两次乘法均使用溢出检测。
    ///
    /// - Parameters:
    ///   - databaseURLs: 涉及的数据库地址。
    ///   - connectionsPerEventLoopPerPhysicalStore: 每个物理库每事件循环的连接数。
    ///   - additionalConnections: 控制面专用池的额外连接数，同样计入进程总上限。
    /// - Throws: 物理库数量为零、单池连接数非法或超过上限，或总连接数越界时抛出
    ///   ``V2GatewayRuntimeConfigurationError/invalid(_:)``。
    public func validate(
        databaseURLs: [String],
        connectionsPerEventLoopPerPhysicalStore: Int,
        additionalConnections: Int = 0,
        workloadConnectionsPerPhysicalStore: Int? = nil
    ) throws {
        let physicalPoolCount = Set(databaseURLs).count
        guard physicalPoolCount > 0, additionalConnections >= 0, connectionsPerEventLoopPerPhysicalStore > 0,
              connectionsPerEventLoopPerPhysicalStore <= maximumConnectionsPerEventLoop
        else {
            if physicalPoolCount == 0 {
                throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_DATABASE_URL")
            }
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_DATABASE_WORKLOAD_POOL_BUDGET"
            )
        }
        let (perPool, perPoolOverflow) = eventLoopThreads.multipliedReportingOverflow(
            by: connectionsPerEventLoopPerPhysicalStore
        )
        let effectivePerPool = workloadConnectionsPerPhysicalStore ?? perPool
        guard !perPoolOverflow, effectivePerPool > 0, effectivePerPool <= perPool else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_DATABASE_WORKLOAD_POOL_BUDGET")
        }
        let (total, totalOverflow) = effectivePerPool.multipliedReportingOverflow(by: physicalPoolCount)
        let (combinedTotal, additionalOverflow) = total.addingReportingOverflow(additionalConnections)
        guard !perPoolOverflow, !totalOverflow, !additionalOverflow, combinedTotal <= maximumTotalConnections else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS")
        }
    }

    /// 读取必需的正整数环境变量并校验上限。
    ///
    /// - Parameters:
    ///   - key: 环境变量名。
    ///   - maximum: 允许的最大取值。
    ///   - environment: 运行时环境视图。
    /// - Returns: 介于 1 与 `maximum` 之间的取值。
    /// - Throws: 变量缺失时抛出 ``V2GatewayRuntimeConfigurationError/missing(_:)``；
    ///   取值非法时抛出 ``V2GatewayRuntimeConfigurationError/invalid(_:)``。
    private static func boundedPositive(
        _ key: String,
        maximum: Int,
        environment: any V2RuntimeEnvironment
    ) throws -> Int {
        guard let raw = environment.value(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { throw V2GatewayRuntimeConfigurationError.missing(key) }
        guard let value = Int(raw), value > 0, value <= maximum else {
            throw V2GatewayRuntimeConfigurationError.invalid(key)
        }
        return value
    }
}
