import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 房间持久化归属的逻辑分片标识及路由代次。
///
/// 不携带主机名或数据库连接信息，实际存储由部署配置单独解析。
/// 路由仅决定访问位置，不代表调用方具有房间访问权限。
public struct V2RoomShardRoute: Equatable, Sendable {
    /// 去除首尾空白后的非空逻辑分片标识。
    public let shardID: String
    /// 非负路由代次；新用户对提议路由使用零。
    public let epoch: Int64

    /// 规范化并验证路由值。
    ///
    /// - Parameters:
    ///   - shardID: 逻辑分片标识，首尾空白与换行会被移除。
    ///   - epoch: 非负路由代次。
    /// - Throws: 规范化后的标识为空或代次为负时抛出 ``V2RoomShardRouteError/invalidRoute``。
    public init(shardID: String, epoch: Int64) throws {
        let normalized = shardID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, epoch >= 0 else {
            throw V2RoomShardRouteError.invalidRoute
        }
        self.shardID = normalized
        self.epoch = epoch
    }
}

/// 房间归属查询与目录登记使用的领域错误。
public enum V2RoomShardRouteError: Error, Equatable, Sendable {
    /// 分片标识为空或路由代次为负。
    case invalidRoute
    /// 显式归属目录和历史房间记录均不能提供完整的请求路由。
    case roomNotFound
    /// 已有房间或用户对的持久化归属与本次登记结果不一致。
    case routeConflict
    /// 标识、数据库适配能力或待持久化时间不满足路由存储要求。
    case corruptPersistenceState
}

/// 解析已存在房间的持久化归属，供调用方选择归属存储。
///
/// 目录属于控制面，不保存第二份权威消息状态；实现可通过缓存提示加速查询。
public protocol V2RoomShardRouting: Sendable {
    /// 解析单个房间归属。
    ///
    /// - Parameter roomID: 已存在房间的标识。
    /// - Returns: 分片标识与路由代次。
    /// - Throws: 房间不存在、路由无效或底层目录查询错误。
    func route(for roomID: RoomID) async throws -> V2RoomShardRoute
    /// 批量解析房间归属，默认实现逐个查询去重后的房间。
    ///
    /// - Parameter roomIDs: 待解析标识，可含重复项；调用方负责限制批次规模。
    /// - Returns: 不同房间到路由的映射，空输入返回空字典。
    /// - Throws: 任一房间解析失败时抛错，不返回部分结果。
    func routes(for roomIDs: [RoomID]) async throws -> [RoomID: V2RoomShardRoute]
}

public extension V2RoomShardRouting {
    /// 为不支持集合查询的路由器提供顺序批量适配。
    ///
    /// - Parameter roomIDs: 原始请求标识，重复项在首次查询成功后跳过。
    /// - Returns: 每个不同房间对应的路由；不会并行发起查询。
    /// - Throws: 第一个失败的单房间查询错误，其前面已经发生的读取不会回滚。
    func routes(for roomIDs: [RoomID]) async throws -> [RoomID: V2RoomShardRoute] {
        var routes: [RoomID: V2RoomShardRoute] = [:]
        routes.reserveCapacity(roomIDs.count)
        for roomID in roomIDs {
            if routes[roomID] == nil {
                routes[roomID] = try await route(for: roomID)
            }
        }
        return routes
    }
}

/// 在尚无房间标识的私聊创建阶段，为用户对选择稳定归属并保护目录登记。
///
/// PostgreSQL 实现以控制面事务级建议锁串行化同一用户对的创建。
/// 回调可执行一次有界的归属存储创建或重放事务；它与控制面事务不是同一个原子提交。
public protocol V2DirectRoomShardRouting: V2RoomShardRouting {
    /// 在用户对归属保护范围内执行业务操作。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起用户。
    ///   - targetUserID: 目标用户，反向用户对也应映射到同一归属。
    ///   - proposedShardID: 用户对尚无显式记录时提议的分片。
    ///   - operation: 使用选定路由执行创建或重放，返回业务结果及可选房间标识。
    /// - Returns: 回调的业务结果；外层目录操作成功后才返回。
    /// - Throws: 路由选择、回调或目录登记失败。回调已提交的归属存储事务不由目录回滚撤销。
    func withDirectPairRoute<Result: Sendable>(
        actorUserID: UserID,
        targetUserID: UserID,
        proposedShardID: String,
        _ operation: @escaping @Sendable (V2RoomShardRoute) async throws -> (result: Result, roomID: RoomID?)
    ) async throws -> Result
}

/// 使用 PostgreSQL 控制面目录解析并登记房间归属。
///
/// 只查询显式 `room_owner_routes`；新建房间在创建事务中登记目录，
/// 避免部署新分片配置后重新哈希已有房间。新私聊登记用户对及房间两份一致的目录记录。
/// 现有房间查询不打开控制面事务包裹归属存储操作；用户对创建才使用短事务与建议锁。
public struct V2PostgresRoomShardRouter: V2DirectRoomShardRouting {
    private let database: any Database
    private let now: @Sendable () -> Date

    /// 注入控制面数据库与目录新增记录使用的时钟。
    ///
    /// - Parameters:
    ///   - database: 支持 SQL 的 Fluent 数据库，不应替换为非 SQL 后端。
    ///   - now: 写入新目录记录时读取的绝对时间，默认系统当前时间。
    public init(database: any Database, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.now = now
    }

    /// 读取显式房间路由；缺失时拒绝访问。
    ///
    /// - Parameter roomID: UUID 形式的房间标识。
    /// - Returns: 显式分片与代次。
    /// - Throws: 无法取得 SQL 适配器或解析 UUID 时抛出 `corruptPersistenceState`；
    ///   目录未命中时抛出 `roomNotFound`，路由校验和数据库错误原样传播。
    public func route(for roomID: RoomID) async throws -> V2RoomShardRoute {
        guard let sql = database as? any SQLDatabase,
              let roomUUID = UUID(uuidString: roomID.rawValue)
        else { throw V2RoomShardRouteError.corruptPersistenceState }
        if let row = try await sql.raw("""
            SELECT room_shard_id, route_epoch
            FROM im_v2.room_owner_routes
            WHERE room_id = \(bind: roomUUID)
            """).first(decoding: RouteRow.self) {
            return try .init(shardID: row.roomShardID, epoch: row.routeEpoch)
        }
        throw V2RoomShardRouteError.roomNotFound
    }

    /// 通过一次集合查询批量解析显式目录中的路由。
    ///
    /// 两次读取未包裹在本方法创建的统一事务中，不保证跨查询的同一时刻快照。
    ///
    /// - Parameter roomIDs: 可重复的 UUID 房间标识，空输入不访问数据库。
    /// - Returns: 所有不同房间的完整路由映射，历史回退值使用零代次。
    /// - Throws: 缺失任一请求房间时抛出 `roomNotFound`；标识、SQL 能力、JSON 编码、
    ///   路由校验及查询错误按实际失败路径传播。
    public func routes(for roomIDs: [RoomID]) async throws -> [RoomID: V2RoomShardRoute] {
        guard !roomIDs.isEmpty else { return [:] }
        let uniqueRoomIDs = Array(Set(roomIDs))
        let requestedRoomIDs: [(roomID: RoomID, uuid: UUID)] = try uniqueRoomIDs.map { roomID in
            guard let uuid = UUID(uuidString: roomID.rawValue) else {
                throw V2RoomShardRouteError.corruptPersistenceState
            }
            return (roomID, uuid)
        }
        guard let sql = database as? any SQLDatabase else {
            throw V2RoomShardRouteError.corruptPersistenceState
        }
        let requestedJSON = try roomRouteUUIDJSON(requestedRoomIDs.map(\.uuid))
        let explicitRows = try await sql.raw("""
            SELECT route.room_id, route.room_shard_id, route.route_epoch
            FROM im_v2.room_owner_routes AS route
            INNER JOIN jsonb_array_elements_text(\(bind: requestedJSON)::jsonb) AS requested(room_id)
              ON route.room_id = requested.room_id::uuid
            """).all(decoding: RoutedRoomRow.self)
        var routes: [RoomID: V2RoomShardRoute] = [:]
        routes.reserveCapacity(requestedRoomIDs.count)
        for row in explicitRows {
            routes[try RoomID(row.roomID.uuidString)] = try .init(
                shardID: row.roomShardID, epoch: row.routeEpoch
            )
        }
        guard routes.count == requestedRoomIDs.count else {
            throw V2RoomShardRouteError.roomNotFound
        }
        return routes
    }

    /// 持有规范化用户对的控制面建议锁，选择归属、执行回调并登记目录。
    ///
    /// 已有用户对记录优先于提议分片。回调成功后，仅在返回房间标识且能转换为 UUID 时登记；
    /// 未提供或无法转换时直接返回业务结果。两张目录表中已有记录须与选定归属精确一致。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起用户的 UUID 标识。
    ///   - targetUserID: 目标用户的 UUID 标识。
    ///   - proposedShardID: 无既有用户对路由时使用的分片，初始代次为零。
    ///   - operation: 在目录事务仍打开时执行的有界业务回调，应能安全重放已提交的创建。
    /// - Returns: 目录事务成功后的业务结果。
    /// - Throws: 无效持久化状态、无效路由、归属冲突、回调错误或数据库错误。
    ///   目录登记失败不会撤销回调自行提交的归属存储事务。
    public func withDirectPairRoute<Result: Sendable>(
        actorUserID: UserID,
        targetUserID: UserID,
        proposedShardID: String,
        _ operation: @escaping @Sendable (V2RoomShardRoute) async throws -> (result: Result, roomID: RoomID?)
    ) async throws -> Result {
        guard let actor = UUID(uuidString: actorUserID.rawValue),
              let target = UUID(uuidString: targetUserID.rawValue)
        else { throw V2RoomShardRouteError.corruptPersistenceState }
        let pair = canonicalPair(actor, target)
        let lockKey = roomOwnerDirectRouteLockKey(pair)
        // This is intentionally a short control-plane fence around direct
        // room creation only. Existing-room sends use `route(for:)` and never
        // hold a control transaction while their owner transaction runs.
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomShardRouteError.corruptPersistenceState
            }
            try await sql.raw(
                "SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))"
            ).run()
            let route: V2RoomShardRoute
            if let existing = try await sql.raw("""
                SELECT room_shard_id, route_epoch
                FROM im_v2.direct_room_owner_routes
                WHERE lower_user_id = \(bind: pair.lower)
                  AND higher_user_id = \(bind: pair.higher)
                """).first(decoding: RouteRow.self) {
                route = try .init(shardID: existing.roomShardID, epoch: existing.routeEpoch)
            } else {
                route = try .init(shardID: proposedShardID, epoch: 0)
            }
            let completion = try await operation(route)
            guard let roomID = completion.roomID,
                  let roomUUID = UUID(uuidString: roomID.rawValue)
            else { return completion.result }
            try await record(
                roomID: roomUUID, pair: pair, route: route, sql: sql, now: now()
            )
            return completion.result
        }
    }

    /// 在现有控制面事务内校验或插入房间与用户对的归属记录。
    ///
    /// 已有记录使用行锁并要求房间、分片、代次一致，不覆写冲突值；仅需插入时检查时钟
    /// 能否编码为有限 PostgreSQL 时间戳。任一失败由外层事务回滚本次目录变更。
    private func record(
        roomID: UUID, pair: CanonicalDirectPair, route: V2RoomShardRoute,
        sql: any SQLDatabase, now: Date
    ) async throws {
        if let existing = try await sql.raw("""
            SELECT room_shard_id, route_epoch
            FROM im_v2.room_owner_routes WHERE room_id = \(bind: roomID) FOR UPDATE
            """).first(decoding: RouteRow.self) {
            guard existing.roomShardID == route.shardID, existing.routeEpoch == route.epoch else {
                throw V2RoomShardRouteError.routeConflict
            }
        } else {
            guard v2PostgresTimestampCanEncode(now) else { throw V2RoomShardRouteError.corruptPersistenceState }
            try await sql.raw("""
                INSERT INTO im_v2.room_owner_routes
                    (room_id, room_shard_id, route_epoch, created_at, updated_at)
                VALUES (\(bind: roomID), \(bind: route.shardID), \(bind: route.epoch), \(bind: now), \(bind: now))
                """).run()
        }
        if let existing = try await sql.raw("""
            SELECT room_id, room_shard_id, route_epoch
            FROM im_v2.direct_room_owner_routes
            WHERE lower_user_id = \(bind: pair.lower) AND higher_user_id = \(bind: pair.higher)
            FOR UPDATE
            """).first(decoding: DirectRouteRow.self) {
            guard existing.roomID == roomID,
                  existing.roomShardID == route.shardID,
                  existing.routeEpoch == route.epoch
            else { throw V2RoomShardRouteError.routeConflict }
        } else {
            guard v2PostgresTimestampCanEncode(now) else { throw V2RoomShardRouteError.corruptPersistenceState }
            try await sql.raw("""
                INSERT INTO im_v2.direct_room_owner_routes
                    (lower_user_id, higher_user_id, room_id, room_shard_id, route_epoch, created_at, updated_at)
                VALUES (\(bind: pair.lower), \(bind: pair.higher), \(bind: roomID),
                        \(bind: route.shardID), \(bind: route.epoch), \(bind: now), \(bind: now))
                """).run()
        }
    }
}

/// 显式目录中的分片和代次行。
private struct RouteRow: Decodable {
    let roomShardID: String
    let routeEpoch: Int64
    enum CodingKeys: String, CodingKey {
        case roomShardID = "room_shard_id"
        case routeEpoch = "route_epoch"
    }
}

/// 集合查询得到的带房间标识的显式路由行。
private struct RoutedRoomRow: Decodable {
    let roomID: UUID
    let roomShardID: String
    let routeEpoch: Int64
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case roomShardID = "room_shard_id"
        case routeEpoch = "route_epoch"
    }
}

/// 用户对目录中用于一致性校验的房间及路由行。
private struct DirectRouteRow: Decodable {
    let roomID: UUID
    let roomShardID: String
    let routeEpoch: Int64
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case roomShardID = "room_shard_id"
        case routeEpoch = "route_epoch"
    }
}

/// 按小写 UUID 文本升序排列的用户对，用于对称目录键与锁键。
struct CanonicalDirectPair: Sendable {
    let lower: UUID
    let higher: UUID
    // This is a control-directory fence. Keep its advisory-lock namespace
    // distinct from PostgresV2DirectMessagingStore's owner-store pair lock;
    // otherwise a co-located deployment would wait on its own open transaction.
}

/// 以规范 UUID 文本顺序排列用户对，不在此处检查两个用户是否相同。
private func canonicalPair(_ first: UUID, _ second: UUID) -> CanonicalDirectPair {
    first.uuidString.lowercased() < second.uuidString.lowercased()
        ? .init(lower: first, higher: second)
        : .init(lower: second, higher: first)
}

/// 将 UUID 数组编码为供 SQL 集合查询展开的 JSON 文本，编码错误向上传播。
private func roomRouteUUIDJSON(_ values: [UUID]) throws -> String {
    String(decoding: try JSONEncoder().encode(values.map(\.uuidString)), as: UTF8.self)
}

/// 生成用户对的稳定控制面建议锁键，与归属存储的用户对锁命名空间分离。
///
/// - Parameter pair: 已按规范顺序排列的用户对。
/// - Returns: 以 `room-route:` 开头、使用冒号分隔的小写 UUID 文本，不含 PostgreSQL 不接受的空字节。
func roomOwnerDirectRouteLockKey(_ pair: CanonicalDirectPair) -> String {
    // PostgreSQL text parameters cannot contain a NUL byte. UUIDs have a fixed
    // textual form, so colon delimiters are unambiguous here and keep this
    // namespace separate from the owner-store direct-pair lock.
    "room-route:" + pair.lower.uuidString.lowercased() + ":" + pair.higher.uuidString.lowercased()
}
