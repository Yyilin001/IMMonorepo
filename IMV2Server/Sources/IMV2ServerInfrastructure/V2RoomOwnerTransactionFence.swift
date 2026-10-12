import IMV2ServerApplication
import Foundation
import IMV2ServerContracts
import IMV2ActorContracts
import IMV2Core
import SQLKit


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

    /// Applied at physical connection startup; custom transactions use LOCAL overrides.
    public var startupParameters: [(String, String)] {
        [("options", "-c statement_timeout=\(statementMilliseconds) -c lock_timeout=\(lockMilliseconds) -c idle_in_transaction_session_timeout=\(idleTransactionMilliseconds)")]
    }
}

/// 在业务事务中设置自定义 SQL 超时。
func v2SetRoomActivationSQLTimeouts(_ timeouts: V2RoomActivationSQLTimeouts, sql: any SQLDatabase) async throws {
    V2RoomSQLContinuationObservation.current?.willDispatch()
    // 三项 LOCAL 设置均在下一次加锁或业务语句前生效。
    // 一次往返即可维持相同的事务范围限制。
    try await sql.raw("""
        SELECT set_config('lock_timeout', \(bind: "\(timeouts.lockMilliseconds)ms"), true),
               set_config('statement_timeout', \(bind: "\(timeouts.statementMilliseconds)ms"), true),
               set_config('idle_in_transaction_session_timeout', \(bind: "\(timeouts.idleTransactionMilliseconds)ms"), true)
        """).run()
}

/// 资料展示写入核对持久化数据归属。房间实例的执行权限由 Actor 生命周期管理。
func v2RequireRoomOwner(roomID: UUID, route: V2RoomShardRoute, sql: any SQLDatabase, schema: String = "im_v2") async throws {
    v2PreconditionSQLSchema(schema)
    guard let room = try await sql.raw("""
        SELECT room_shard_id, owner_epoch FROM \(unsafeRaw: schema).rooms WHERE room_id = \(bind: roomID) FOR UPDATE
        """).first(decoding: RoomOwnerFenceRow.self),
          room.shardID == route.shardID, room.epoch == route.epoch
    else { throw V2RoomOwnerFenceError.ownerChanged }
}

/// Host owns the exact activation and retains it through physical SQL completion.
/// SQL checks only the durable data-owner route, in canonical room order.
func v2RequireRoomActivations(
    tokens: [V2RoomActivationToken],
    sql: any SQLDatabase,
    schema: String = "im_v2",
    timeouts: V2RoomActivationSQLTimeouts = .default
) async throws {
    defer { V2RoomSQLContinuationObservation.current?.finishWithoutDispatch() }
    v2PreconditionSQLSchema(schema)
    try await v2SetRoomActivationSQLTimeouts(timeouts, sql: sql)
    let ordered = try tokens.map { token -> (UUID, V2RoomActivationToken) in
        guard let roomUUID = token.roomID.uuidValue else { throw V2CoreError.invalidIdentifier }
        return (roomUUID, token)
    }.sorted { $0.0.uuidString < $1.0.uuidString }
    guard !ordered.isEmpty, Set(ordered.map { $0.0 }).count == ordered.count else {
        throw V2RoomActorStateError.activationChanged
    }
    for (roomUUID, token) in ordered {
        try await v2LockRoomActivationOwner(roomID: roomUUID, owner: token.owner, sql: sql, schema: schema, source: .scalarFenceRooms)
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

func v2LockRoomActivationOwner(roomID: UUID, owner: V2RoomDataOwner, sql: any SQLDatabase, schema: String,
    source: V2RoomSQLContinuationSource? = nil) async throws {
    let query = sql.raw("""
        SELECT room_shard_id, owner_epoch FROM \(unsafeRaw: schema).rooms WHERE room_id = \(bind: roomID) FOR NO KEY UPDATE
        """)
    let room: RoomOwnerFenceRow?
    if let source {
        room = try await v2RoomSQLObservedFirst(query, decoding: RoomOwnerFenceRow.self, source: source)
    } else {
        // Other users do not promise that their next SQL is instrumented.
        V2RoomSQLContinuationObservation.current?.willDispatch()
        room = try await query.first(decoding: RoomOwnerFenceRow.self)
    }
    guard let room else { throw V2RoomActorStateError.roomNotFound }
    guard room.shardID == owner.shardID, room.epoch == owner.epoch else {
        throw V2RoomActorStateError.ownerChanged
    }
}

func v2RoomActivationDatabaseClock(sql: any SQLDatabase) async throws -> Date {
    V2RoomSQLContinuationObservation.current?.willDispatch()
    guard let row = try await sql.raw("SELECT clock_timestamp() AS observed_at")
        .first(decoding: RoomActivationClockRow.self) else {
        throw V2RoomActorStateError.activationChanged
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
