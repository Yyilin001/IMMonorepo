import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// 房间归属栅栏校验错误。
public enum V2RoomOwnerFenceError: Error, Equatable, Sendable { case ownerChanged }

/// PostgreSQL 16 无法用 transaction_timeout 限制整个事务。
/// 这些 LOCAL 限制分别约束锁等待、语句和空闲间隔；
/// 调用方还必须为外围业务操作设置有限的截止时间。
public struct V2RoomActivationSQLTimeouts: Sendable, Equatable {
    public let lockMilliseconds: Int
    public let statementMilliseconds: Int
    public let idleTransactionMilliseconds: Int

    public init(lockMilliseconds: Int = 2_000, statementMilliseconds: Int = 10_000, idleTransactionMilliseconds: Int = 10_000) throws {
        guard (1...30_000).contains(lockMilliseconds),
              (lockMilliseconds...60_000).contains(statementMilliseconds),
              (lockMilliseconds...60_000).contains(idleTransactionMilliseconds)
        else { throw V2ActorContractError.invalidConfiguration("room activation SQL timeouts") }
        self.lockMilliseconds = lockMilliseconds
        self.statementMilliseconds = statementMilliseconds
        self.idleTransactionMilliseconds = idleTransactionMilliseconds
    }

    public static let `default` = try! Self()
}

/// 在获取房间围栏的同一事务中设置。
func v2SetRoomActivationSQLTimeouts(_ timeouts: V2RoomActivationSQLTimeouts, sql: any SQLDatabase) async throws {
    // 三项 LOCAL 设置均在下一次加锁或业务语句前生效。
    // 一次往返即可维持相同的事务范围限制。
    try await sql.raw("""
        SELECT set_config('lock_timeout', \(bind: "\(timeouts.lockMilliseconds)ms"), true),
               set_config('statement_timeout', \(bind: "\(timeouts.statementMilliseconds)ms"), true),
               set_config('idle_in_transaction_session_timeout', \(bind: "\(timeouts.idleTransactionMilliseconds)ms"), true)
        """).run()
}

/// 在所有业务写入方都传入具体激活令牌前，为 V1 调用方保留既有的
/// 仅所有者路径。它不会授予虚拟 Actor 权限。
func v2RequireRoomOwner(roomID: UUID, route: V2RoomShardRoute, sql: any SQLDatabase, schema: String = "im_v2") async throws {
    v2PreconditionSQLSchema(schema)
    guard let room = try await sql.raw("""
        SELECT room_shard_id, owner_epoch FROM \(unsafeRaw: schema).rooms WHERE room_id = \(bind: roomID) FOR UPDATE
        """).first(decoding: RoomOwnerFenceRow.self),
          room.shardID == route.shardID, room.epoch == route.epoch
    else { throw V2RoomOwnerFenceError.ownerChanged }
}

/// 业务写入在其所有者事务内调用此方法：先等额度补充或预留事务提交，
/// 再于重放或写入前执行。独立的房间额度预留必须把可用余额绑定到同一激活令牌；
/// 业务事务通过此围栏后，会重新检查准入窗口、租约代次和额度身份。
/// 持有业务围栏时，绝不能在另一连接上等待额度补充，
/// 也不能把旧令牌的额度转给后继令牌。
/// 此辅助方法既不预留也不退还额度，单靠它也无法覆盖旧写入调用点。
/// 房间锁使用 NO KEY UPDATE，与额度预留的 KEY SHARE 兼容。
/// 所有房间按规范 UUID 顺序加锁；仅在取得最后一把锁后，
/// 才按当时的数据库时钟进行校验。锁一直持有到提交，
/// 因而新提交的激活纪元会排除旧令牌的后续提交。
/// 若旧事务先取得围栏，仍可在后继实例取得其纪元前提交。
func v2RequireRoomActivations(
    tokens: [V2RoomActivationToken],
    sql: any SQLDatabase,
    schema: String = "im_v2",
    timeouts: V2RoomActivationSQLTimeouts = .default
) async throws {
    v2PreconditionSQLSchema(schema)
    try await v2SetRoomActivationSQLTimeouts(timeouts, sql: sql)
    let ordered = try tokens.map { token -> (UUID, V2RoomActivationToken) in
        guard let roomUUID = token.roomID.uuidValue else { throw V2CoreError.invalidIdentifier }
        return (roomUUID, token)
    }.sorted { $0.0.uuidString < $1.0.uuidString }
    guard !ordered.isEmpty, Set(ordered.map { $0.0 }).count == ordered.count else {
        throw V2RoomActivationLeaseError.activationChanged
    }
    for (roomUUID, token) in ordered {
        try await v2LockRoomActivationOwner(roomID: roomUUID, owner: token.owner, sql: sql, schema: schema)
    }
    var activationRows: [(V2RoomActivationToken, V2RoomActivationPersistenceRow?)] = []
    for (roomUUID, token) in ordered {
        let row = try await sql.raw("""
            SELECT activation_epoch, owner_shard_id, owner_epoch, host_id, host_incarnation_id, expires_at
            FROM \(unsafeRaw: schema).room_activation_leases WHERE room_id = \(bind: roomUUID) FOR UPDATE
            """).first(decoding: V2RoomActivationPersistenceRow.self)
        activationRows.append((token, row))
    }
    // 锁等待可能跨过过期时刻。不能使用 PostgreSQL 固定在事务开始时的
    // now()/CURRENT_TIMESTAMP。
    let observed = try await v2RoomActivationDatabaseClock(sql: sql)
    for (token, row) in activationRows {
        guard let row, row.matches(token) else { throw V2RoomActivationLeaseError.activationChanged }
        guard let expiresAt = row.expiresAt, expiresAt > observed else {
            throw V2RoomActivationLeaseError.leaseExpired
        }
    }
}

func v2RequireRoomActivation(
    token: V2RoomActivationToken,
    sql: any SQLDatabase,
    schema: String = "im_v2",
    timeouts: V2RoomActivationSQLTimeouts = .default
) async throws {
    try await v2RequireRoomActivations(tokens: [token], sql: sql, schema: schema, timeouts: timeouts)
}

func v2LockRoomActivationOwner(roomID: UUID, owner: V2RoomDataOwner, sql: any SQLDatabase, schema: String) async throws {
    guard let room = try await sql.raw("""
        SELECT room_shard_id, owner_epoch FROM \(unsafeRaw: schema).rooms WHERE room_id = \(bind: roomID) FOR NO KEY UPDATE
        """).first(decoding: RoomOwnerFenceRow.self) else { throw V2RoomActivationLeaseError.roomNotFound }
    guard room.shardID == owner.shardID, room.epoch == owner.epoch else {
        throw V2RoomActivationLeaseError.ownerChanged
    }
}

func v2RoomActivationDatabaseClock(sql: any SQLDatabase) async throws -> Date {
    guard let row = try await sql.raw("SELECT clock_timestamp() AS observed_at")
        .first(decoding: RoomActivationClockRow.self) else {
        throw V2RoomActivationLeaseError.activationChanged
    }
    return row.observedAt
}

func v2PreconditionSQLSchema(_ schema: String) {
    if schema == "im_v2" { return }
    precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
}

private struct RoomOwnerFenceRow: Decodable {
    let shardID: String
    let epoch: Int64
    enum CodingKeys: String, CodingKey { case shardID = "room_shard_id", epoch = "owner_epoch" }
}

private struct RoomActivationClockRow: Decodable {
    let observedAt: Date
    enum CodingKeys: String, CodingKey { case observedAt = "observed_at" }
}

struct V2RoomActivationPersistenceRow: Decodable {
    let activationEpoch: Int64
    let ownerShardID: String
    let ownerEpoch: Int64
    let hostID: String?
    let hostIncarnationID: UUID?
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case activationEpoch = "activation_epoch", ownerShardID = "owner_shard_id"
        case ownerEpoch = "owner_epoch", hostID = "host_id"
        case hostIncarnationID = "host_incarnation_id", expiresAt = "expires_at"
    }

    func matches(_ token: V2RoomActivationToken) -> Bool {
        activationEpoch == token.activationEpoch.rawValue
            && ownerShardID == token.owner.shardID && ownerEpoch == token.owner.epoch
            && hostID == token.host.hostID.rawValue
            && hostIncarnationID == token.host.incarnationID
    }

    func lease(roomID: RoomID, observedAt: Date) throws -> V2RoomActivationLease? {
        guard let hostID, let hostIncarnationID, let expiresAt, expiresAt > observedAt else { return nil }
        let owner = try V2RoomDataOwner(shardID: ownerShardID, epoch: ownerEpoch)
        let host = V2ActorHostIdentity(hostID: try V2ActorHostID(hostID), incarnationID: hostIncarnationID)
        let token = V2RoomActivationToken(roomID: roomID, owner: owner,
            activationEpoch: try V2ActorEpoch(activationEpoch), host: host)
        return try V2RoomActivationLease(token: token, databaseObservedAt: observedAt, expiresAt: expiresAt)
    }
}
