import Fluent
import Foundation
import IMV2Core
import SQLKit

public struct V2DeviceRevocationEvent: Equatable, Sendable {
    public let eventID: Int64
    public let userID: UserID
    public let deviceID: DeviceID
    public let revokedAt: Date

    public init(eventID: Int64, userID: UserID, deviceID: DeviceID, revokedAt: Date) {
        self.eventID = eventID
        self.userID = userID
        self.deviceID = deviceID
        self.revokedAt = revokedAt
    }
}

/// 各网关设备吊销工作器使用的稳定持久化游标标识。
enum V2DeviceRevocationCursorNamespace {
    /// 按网关处理的吊销工作器名称。
    static let workerName = "device-revocation"
}

/// 投影清理工作器使用的集群级游标命名空间。
enum V2RevokedDeviceProjectionCleanupCursorNamespace {
    /// 投影清理工作器名称。
    static let workerName = "revoked-device-projection-cleanup"
    /// 集群级节点标识，全部网关共享同一游标。
    static let nodeID = "cluster"
}

/// 设备吊销事件的持久化能力。
public protocol V2DeviceRevocationEventStore: Sendable {
    /// 按需初始化节点游标。
    ///
    /// 新网关进程在 TLS 监听绑定之前没有任何存活套接字，因此无需重放历史吊销事件；
    /// 已有节点游标必须保持不变，它代表重启节点自己的持久化恢复位置。
    ///
    /// - Parameters:
    ///   - nodeID: 节点标识。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 持久化失败时抛出。
    func initializeCursorIfNeeded(nodeID: String, now: Date) async throws

    /// 把集群级清理游标初始化到事件流起点。
    ///
    /// 投影清理是集群全局的持久化工作：首次部署时从头重放，
    /// 避免某个设备在吊销时恰好所有网关都离线，从而永久占用状态无法回收。
    ///
    /// - Parameters:
    ///   - nodeID: 节点标识。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 持久化失败时抛出。
    func initializeCursorAtBeginningIfNeeded(nodeID: String, now: Date) async throws

    /// 读取游标之后的一批吊销事件。
    ///
    /// - Parameters:
    ///   - nodeID: 节点标识。
    ///   - limit: 本批最多返回的事件数。
    /// - Returns: 本批事件。
    /// - Throws: 持久化失败时抛出。
    func events(afterCursorFor nodeID: String, limit: Int) async throws -> [V2DeviceRevocationEvent]

    /// 记录事件已被处理。
    ///
    /// - Parameters:
    ///   - eventID: 事件标识。
    ///   - nodeID: 节点标识。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 持久化失败时抛出。
    func markProcessed(eventID: Int64, nodeID: String, now: Date) async throws
}

/// 在控制面持久化吊销凭据之后，从用户投影存储中删除该设备的私有状态。
///
/// 由于事件投递为至少一次，实现必须是幂等的。
public protocol V2RevokedDeviceProjectionCleaning: Sendable {
    /// 清理指定设备在用户投影中的状态。
    ///
    /// - Parameters:
    ///   - userID: 设备归属用户。
    ///   - deviceID: 目标设备。
    ///   - revokedAt: 吊销时刻。
    /// - Throws: 清理失败时抛出。
    func clean(userID: UserID, deviceID: DeviceID, revokedAt: Date) async throws
}

/// 集群级投影清理工作器。
///
/// 存储回收与各网关的存活套接字消费分开处理。事件只有在路由后的清理成功之后才被确认，
/// 因此某个分片暂时不可用不会让游标或凭据被静默地永久泄漏。
public struct V2RevokedDeviceProjectionCleanupWorker: Sendable {
    private let store: any V2DeviceRevocationEventStore
    private let cleaner: any V2RevokedDeviceProjectionCleaning
    private let now: @Sendable () -> Date

    /// 组合吊销事件存储与投影清理实现。
    ///
    /// - Parameters:
    ///   - store: 吊销事件的持久化存储。
    ///   - cleaner: 执行投影清理的实现。
    ///   - now: 可注入的当前时刻读取函数。
    public init(
        store: any V2DeviceRevocationEventStore,
        cleaner: any V2RevokedDeviceProjectionCleaning,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.cleaner = cleaner
        self.now = now
    }

    /// 在启动阶段初始化集群级清理游标。
    ///
    /// 首次部署会把游标放在事件流起点，确保历史吊销不会被跳过。
    ///
    /// - Throws: 持久化失败时抛出。
    public func initializeForStartup() async throws {
        try await store.initializeCursorAtBeginningIfNeeded(
            nodeID: V2RevokedDeviceProjectionCleanupCursorNamespace.nodeID,
            now: now()
        )
    }

    /// 执行一轮有界投影清理。
    ///
    /// 逐条清理并在每条成功后确认游标，因此清理失败时游标不会越过未处理事件。
    ///
    /// - Parameter limit: 本轮最多处理的事件数，需大于零。
    /// - Returns: 本轮处理的事件数。
    /// - Throws: 上限非正或持久化失败时抛出
    ///   ``V2GatewayAuthenticationError/corruptPersistenceState``。
    @discardableResult
    public func runOnce(limit: Int) async throws -> Int {
        guard limit > 0 else { throw V2GatewayAuthenticationError.corruptPersistenceState }
        let nodeID = V2RevokedDeviceProjectionCleanupCursorNamespace.nodeID
        let events = try await store.events(afterCursorFor: nodeID, limit: limit)
        for event in events {
            try await cleaner.clean(
                userID: event.userID,
                deviceID: event.deviceID,
                revokedAt: event.revokedAt
            )
            try await store.markProcessed(eventID: event.eventID, nodeID: nodeID, now: now())
        }
        return events.count
    }
}

/// 单个物理投影存储的设备吊销清理实现。
///
/// 快照产物刻意保留：多台设备可能共享同一份不可变产物，
/// 而重置分配、令牌、回执与游标属于设备私有状态。
public struct V2PostgresRevokedDeviceProjectionStore: V2RevokedDeviceProjectionCleaning {
    private let database: any Database
    private let schema: String

    /// 校验并保存数据库与 schema。
    ///
    /// - Parameters:
    ///   - database: 投影存储所用数据库。
    ///   - schema: 目标 schema，需符合 `^[A-Za-z_][A-Za-z0-9_]*$`。
    ///
    /// schema 名不满足格式时直接失败，避免拼接出非法 SQL 标识符。
    public init(database: any Database, schema: String = "im_v2") {
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.database = database
        self.schema = schema
    }

    /// 清理指定设备的投影状态并写下吊销墓碑。
    ///
    /// 事务先按用户与设备加咨询锁，再写入或更新墓碑（保留最早的吊销时刻），
    /// 最后删除同步令牌、回执、重置分配与设备游标。
    ///
    /// - Parameters:
    ///   - userID: 设备归属用户。
    ///   - deviceID: 目标设备。
    ///   - revokedAt: 吊销时刻。
    /// - Throws: 标识非法或吊销时刻不可编码时抛出
    ///   ``V2GatewayAuthenticationError/corruptPersistenceState``。
    public func clean(userID: UserID, deviceID: DeviceID, revokedAt: Date) async throws {
        guard v2PostgresTimestampCanEncode(revokedAt),
              let userUUID = UUID(uuidString: userID.rawValue),
              let deviceUUID = UUID(uuidString: deviceID.rawValue)
        else { throw V2GatewayAuthenticationError.corruptPersistenceState }
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2GatewayAuthenticationError.corruptPersistenceState
            }
            try await sql.raw("""
                SELECT pg_advisory_xact_lock(hashtextextended(
                    CONCAT(\(bind: userUUID), ':', \(bind: deviceUUID)), 684927
                ))
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).revoked_device_projection_tombstones AS tombstone
                    (user_id, device_id, revoked_at)
                VALUES (\(bind: userUUID), \(bind: deviceUUID), \(bind: revokedAt))
                ON CONFLICT (user_id, device_id) DO UPDATE
                SET revoked_at = LEAST(tombstone.revoked_at, EXCLUDED.revoked_at)
                """).run()
            for table in ["sync_tokens", "sync_receipts", "device_snapshot_resets", "device_sync_cursors"] {
                try await sql.raw("""
                    DELETE FROM \(unsafeRaw: schema).\(unsafeRaw: table)
                    WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                    """).run()
            }
        }
    }
}

/// 带路由栅栏的组合清理实现。
///
/// 当前归属与保留的读回退桶都会被清理。初始迁移复制可能与本次清理并发，
/// 但独占的最终切换复制会与该共享路由锁串行，因此最终仍会从已清理的源收敛一致。
public struct V2RoutedRevokedDeviceProjectionCleaner: V2RevokedDeviceProjectionCleaning {
    private let routeFence: any V2UserShardRouteFencing
    private let registry: any V2UserShardStorageResolving
    private let coLocatedControlBuckets: Set<String>

    /// 组合路由栅栏与归属存储解析器。
    ///
    /// - Parameters:
    ///   - routeFence: 用户归属栅栏。
    ///   - registry: 用户归属存储解析器。
    ///   - coLocatedControlBuckets: 与控制库同库部署、需复用栅栏连接的归属桶。
    public init(
        routeFence: any V2UserShardRouteFencing,
        registry: any V2UserShardStorageResolving,
        coLocatedControlBuckets: Set<String> = []
    ) {
        self.routeFence = routeFence
        self.registry = registry
        self.coLocatedControlBuckets = coLocatedControlBuckets
    }

    /// 在当前归属与读回退桶中清理设备投影状态。
    ///
    /// - Parameters:
    ///   - userID: 设备归属用户。
    ///   - deviceID: 目标设备。
    ///   - revokedAt: 吊销时刻。
    /// - Throws: 路由解析或底层清理失败时抛出。
    public func clean(userID: UserID, deviceID: DeviceID, revokedAt: Date) async throws {
        try await routeFence.withCurrentRoute(for: userID) { route, fencedDatabase in
            var buckets = [route.bucket]
            if let fallback = route.readFallbackBucket {
                buckets.append(fallback)
            }
            for bucket in buckets {
                let configured = try registry.location(for: bucket)
                let database = coLocatedControlBuckets.contains(bucket)
                    ? fencedDatabase
                    : configured.database
                try await V2PostgresRevokedDeviceProjectionStore(
                    database: database,
                    schema: configured.schema
                ).clean(userID: userID, deviceID: deviceID, revokedAt: revokedAt)
            }
        }
    }
}

/// 设备吊销事件工作者。
///
/// 每次本地成功关闭之后都会推进一次持久游标。若在推进之前崩溃，
/// 重放该关闭动作是刻意设计的无害行为。
public struct V2DeviceRevocationWorker: Sendable {
    private let store: any V2DeviceRevocationEventStore
    private let registry: V2DeviceConnectionRegistry
    private let nodeID: String
    private let now: @Sendable () -> Date

    public init(store: any V2DeviceRevocationEventStore, registry: V2DeviceConnectionRegistry, nodeID: String, now: @escaping @Sendable () -> Date = Date.init) {
        precondition(!nodeID.isEmpty)
        self.store = store
        self.registry = registry
        self.nodeID = nodeID
        self.now = now
    }

    /// 启动初始化，必须在本进程接受实时连接之前完成。
    ///
    /// 它可以防止新命名的副本从头扫描只追加的历史记录，
    /// 同时保留任何已存在的游标以支持崩溃恢复。
    ///
    /// - Throws: 游标初始化持久化失败时抛出。
    public func initializeForStartup() async throws {
        try await store.initializeCursorIfNeeded(nodeID: nodeID, now: now())
    }

    @discardableResult
    public func runOnce(limit: Int) async throws -> Int {
        guard limit > 0 else { throw V2GatewayAuthenticationError.corruptPersistenceState }
        let events = try await store.events(afterCursorFor: nodeID, limit: limit)
        for event in events {
            await registry.revoke(deviceID: event.deviceID)
            try await store.markProcessed(eventID: event.eventID, nodeID: nodeID, now: now())
        }
        return events.count
    }
}

public struct V2PostgresDeviceRevocationEventStore: V2DeviceRevocationEventStore {
    private let database: any Database
    private let workerName: String

    public init(database: any Database) {
        self.database = database
        workerName = V2DeviceRevocationCursorNamespace.workerName
    }

    private init(database: any Database, workerName: String) {
        self.database = database
        self.workerName = workerName
    }

    public static func projectionCleanup(database: any Database) -> Self {
        .init(
            database: database,
            workerName: V2RevokedDeviceProjectionCleanupCursorNamespace.workerName
        )
    }

    public func initializeCursorIfNeeded(nodeID: String, now: Date) async throws {
        guard !nodeID.isEmpty, let sql = database as? any SQLDatabase else {
            throw V2GatewayAuthenticationError.corruptPersistenceState
        }
        guard v2PostgresTimestampCanEncode(now) else {
            // A restart preserves its durable cursor without writing a time.
            guard try await cursorExists(nodeID: nodeID, on: sql) else {
                throw V2GatewayAuthenticationError.corruptPersistenceState
            }
            return
        }
        // `ON CONFLICT DO NOTHING` is intentional. Replacing an existing
        // cursor here could make two accidentally duplicated node IDs skip a
        // revocation which only the older process still needs to close.
        // PostgreSQL evaluates this insert from one statement snapshot: an
        // event committed after that snapshot remains above the watermark and
        // is consumed normally once the listener is bound.
        try await sql.raw("""
            INSERT INTO im_v2.gateway_worker_cursors (worker_name, node_id, last_event_id, updated_at)
            SELECT \(bind: workerName), \(bind: nodeID), COALESCE(MAX(event_id), 0), \(bind: now)
            FROM im_v2.device_revocation_events
            ON CONFLICT (worker_name, node_id) DO NOTHING
            """).run()
    }

    public func initializeCursorAtBeginningIfNeeded(nodeID: String, now: Date) async throws {
        guard !nodeID.isEmpty, let sql = database as? any SQLDatabase else {
            throw V2GatewayAuthenticationError.corruptPersistenceState
        }
        guard v2PostgresTimestampCanEncode(now) else {
            guard try await cursorExists(nodeID: nodeID, on: sql) else {
                throw V2GatewayAuthenticationError.corruptPersistenceState
            }
            return
        }
        try await sql.raw("""
            INSERT INTO im_v2.gateway_worker_cursors
                (worker_name, node_id, last_event_id, updated_at)
            VALUES (\(bind: workerName), \(bind: nodeID), 0, \(bind: now))
            ON CONFLICT (worker_name, node_id) DO NOTHING
            """).run()
    }

    public func events(afterCursorFor nodeID: String, limit: Int) async throws -> [V2DeviceRevocationEvent] {
        guard !nodeID.isEmpty, limit > 0, let sql = database as? any SQLDatabase else {
            throw V2GatewayAuthenticationError.corruptPersistenceState
        }
        let rows = try await sql.raw("""
            SELECT event.event_id, event.user_id, event.device_id, event.created_at
            FROM im_v2.device_revocation_events AS event
            WHERE event.event_id > COALESCE((
                SELECT cursor.last_event_id
                FROM im_v2.gateway_worker_cursors AS cursor
                WHERE cursor.worker_name = \(bind: workerName) AND cursor.node_id = \(bind: nodeID)
            ), 0)
            ORDER BY event.event_id
            LIMIT \(bind: limit)
            """).all(decoding: V2DeviceRevocationEventRow.self)
        return try rows.map {
            guard let userID = try? UserID($0.userID.uuidString), let deviceID = try? DeviceID($0.deviceID.uuidString) else {
                throw V2GatewayAuthenticationError.corruptPersistenceState
            }
            return .init(
                eventID: $0.eventID,
                userID: userID,
                deviceID: deviceID,
                revokedAt: $0.createdAt
            )
        }
    }

    public func markProcessed(eventID: Int64, nodeID: String, now: Date) async throws {
        guard !nodeID.isEmpty, eventID > 0, v2PostgresTimestampCanEncode(now),
              let sql = database as? any SQLDatabase else {
            throw V2GatewayAuthenticationError.corruptPersistenceState
        }
        try await sql.raw("""
            INSERT INTO im_v2.gateway_worker_cursors (worker_name, node_id, last_event_id, updated_at)
            VALUES (\(bind: workerName), \(bind: nodeID), \(bind: eventID), \(bind: now))
            ON CONFLICT (worker_name, node_id) DO UPDATE
            SET last_event_id = GREATEST(im_v2.gateway_worker_cursors.last_event_id, EXCLUDED.last_event_id),
                updated_at = EXCLUDED.updated_at
            """).run()
    }

    private func cursorExists(nodeID: String, on sql: any SQLDatabase) async throws -> Bool {
        try await sql.raw("""
            SELECT 1 FROM im_v2.gateway_worker_cursors
            WHERE worker_name = \(bind: workerName) AND node_id = \(bind: nodeID)
            """).first() != nil
    }
}

private struct V2DeviceRevocationEventRow: Decodable {
    let eventID: Int64
    let userID: UUID
    let deviceID: UUID
    let createdAt: Date
    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case userID = "user_id"
        case deviceID = "device_id"
        case createdAt = "created_at"
    }
}
