import Foundation

/// Independent PostgreSQL pool budgets for the gateway's latency and durable
/// work classes. The sum is still fenced by the process-wide per-event-loop
/// ceiling, so isolation cannot silently increase the deployment's database
/// connection budget.
public struct V2PostgresWorkloadPoolBudget: Equatable, Sendable {
    public enum Role: String, CaseIterable, Sendable {
        case foreground
        case sync
        case delivery
        case projection
        case maintenance
    }

    public let foregroundConnectionsPerEventLoop: Int
    public let syncConnectionsPerEventLoop: Int
    public let deliveryConnectionsPerEventLoop: Int
    public let projectionConnectionsPerEventLoop: Int
    public let maintenanceConnectionsPerEventLoop: Int

    public init(environment: any V2RuntimeEnvironment) throws {
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

    public var totalConnectionsPerEventLoop: Int {
        foregroundConnectionsPerEventLoop + syncConnectionsPerEventLoop
            + deliveryConnectionsPerEventLoop + projectionConnectionsPerEventLoop
            + maintenanceConnectionsPerEventLoop
    }

    public func connectionsPerEventLoop(for role: Role) -> Int {
        switch role {
        case .foreground: foregroundConnectionsPerEventLoop
        case .sync: syncConnectionsPerEventLoop
        case .delivery: deliveryConnectionsPerEventLoop
        case .projection: projectionConnectionsPerEventLoop
        case .maintenance: maintenanceConnectionsPerEventLoop
        }
    }

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

/// One process-wide PostgreSQL resource and timeout policy. Every physical
/// pool is created from this value, so adding user-shard databases cannot
/// silently multiply connections or create an unbounded query/lock wait.
public struct V2PostgresRuntimePolicy: Equatable, Sendable {
    public let eventLoopThreads: Int
    public let maximumConnectionsPerEventLoop: Int
    public let maximumTotalConnections: Int
    public let maximumUserShardStores: Int
    public let connectTimeoutMilliseconds: Int
    public let poolTimeoutMilliseconds: Int
    public let statementTimeoutMilliseconds: Int
    public let lockTimeoutMilliseconds: Int
    public let idleTransactionTimeoutMilliseconds: Int

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

    /// PostgreSQL accepts session GUCs through the startup `options`
    /// parameter. Unlike `SET` on one borrowed connection, this applies to
    /// every connection Fluent creates now or after a pool replacement.
    public var startupParameters: [(String, String)] {
        [("options", [
            "-c statement_timeout=\(statementTimeoutMilliseconds)",
            "-c lock_timeout=\(lockTimeoutMilliseconds)",
            "-c idle_in_transaction_session_timeout=\(idleTransactionTimeoutMilliseconds)",
        ].joined(separator: " "))]
    }

    public func validate(primaryDatabaseURL: String, userShardStorage: [V2UserShardStorageConfiguration]) throws {
        guard userShardStorage.count <= maximumUserShardStores else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_MAX_USER_SHARD_STORES")
        }
        try validate(databaseURLs: [primaryDatabaseURL] + userShardStorage.map(\.databaseURL))
    }

    public func validate(databaseURLs: [String]) throws {
        try validate(
            databaseURLs: databaseURLs,
            connectionsPerEventLoopPerPhysicalStore: maximumConnectionsPerEventLoop
        )
    }

    /// Validates a gateway's sum of role-specific pools without changing the
    /// legacy single-pool policy used by the account and operator processes.
    public func validate(
        databaseURLs: [String],
        connectionsPerEventLoopPerPhysicalStore: Int
    ) throws {
        let physicalPoolCount = Set(databaseURLs).count
        guard physicalPoolCount > 0, connectionsPerEventLoopPerPhysicalStore > 0,
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
        let (total, totalOverflow) = perPool.multipliedReportingOverflow(by: physicalPoolCount)
        guard !perPoolOverflow, !totalOverflow, total <= maximumTotalConnections else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS")
        }
    }

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
