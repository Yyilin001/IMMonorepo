import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import IMV2ActorContracts
import SQLKit

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
        deadline: ContinuousClock.Instant? = nil,
        _ operation: @escaping @Sendable (V2RoomShardRoute) async throws -> (result: Result, roomID: RoomID?)
    ) async throws -> Result {
        guard let actor = UUID(uuidString: actorUserID.rawValue),
              let target = UUID(uuidString: targetUserID.rawValue)
        else { throw V2RoomShardRouteError.corruptPersistenceState }
        let pair = canonicalPair(actor, target)
        let lockKey = roomOwnerDirectRouteLockKey(pair)
        // 此控制侧围栏有意只短暂覆盖私聊房间创建。
        // 既有房间的发送使用 `route(for:)`，所有者事务运行时
        // 不会同时持有控制侧事务。
        let stop = deadline ?? ContinuousClock.now.advanced(by: .seconds(10))
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < stop else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
            let completion: DirectPairTurn<Result>? = try await database.transaction { transaction in
                guard let sql = transaction as? any SQLDatabase else {
                    throw V2RoomShardRouteError.corruptPersistenceState
                }
                let acquired = try await sql.raw("SELECT pg_try_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0)) AS acquired").first(decoding: DirectPairLockRow.self)
                guard acquired?.acquired == true else { return nil }
                try Task.checkCancellation()
                guard ContinuousClock.now < stop else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
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
                else { return .init(value: completion.result) }
                try await record(
                    roomID: roomUUID, pair: pair, route: route, sql: sql, now: now()
                )
                return .init(value: completion.result)
            }
            if let completion { return completion.value }
            // Contended turns return their connection before sleeping; a
            // winner can acquire the control connection needed by its owner.
            try await Task.sleep(until: min(stop, ContinuousClock.now.advanced(by: .milliseconds(10))), clock: .continuous)
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
    // 这是控制目录围栏。咨询锁命名空间须与
    // PostgresV2DirectMessagingStore 的所有者存储关系锁区分开；
    // 否则同址部署会等待自身尚未结束的事务。
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
    // PostgreSQL 文本参数不能包含 NUL 字节。UUID 的文本形式固定，
    // 因此冒号分隔符在此不会歧义，也能让此命名空间
    // 与所有者存储的私聊关系锁区分开。
    "room-route:" + pair.lower.uuidString.lowercased() + ":" + pair.higher.uuidString.lowercased()
}

private struct DirectPairLockRow: Decodable { let acquired: Bool }
private struct DirectPairTurn<Value: Sendable>: Sendable { let value: Value }
