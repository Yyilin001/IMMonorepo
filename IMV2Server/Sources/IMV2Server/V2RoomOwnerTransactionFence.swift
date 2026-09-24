import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// 房间归属栅栏校验错误。
public enum V2RoomOwnerFenceError: Error, Equatable, Sendable { case ownerChanged }

/// PostgreSQL 16 cannot bound an entire transaction with transaction_timeout.
/// These LOCAL limits bound each lock wait, statement, and idle interval. The
/// caller must also give the enclosing business operation a finite deadline.
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

/// Set inside the same transaction that acquires the room fence.
func v2SetRoomActivationSQLTimeouts(_ timeouts: V2RoomActivationSQLTimeouts, sql: any SQLDatabase) async throws {
    // All three LOCAL settings take effect before the next lock or business
    // statement. One round trip preserves the same transaction-scoped limits.
    try await sql.raw("""
        SELECT set_config('lock_timeout', \(bind: "\(timeouts.lockMilliseconds)ms"), true),
               set_config('statement_timeout', \(bind: "\(timeouts.statementMilliseconds)ms"), true),
               set_config('idle_in_transaction_session_timeout', \(bind: "\(timeouts.idleTransactionMilliseconds)ms"), true)
        """).run()
}

/// Existing owner-only path remains for V1 callers until every business writer
/// passes a concrete activation token. It does not grant virtual actor authority.
func v2RequireRoomOwner(roomID: UUID, route: V2RoomShardRoute, sql: any SQLDatabase, schema: String = "im_v2") async throws {
    v2PreconditionSQLSchema(schema)
    guard let room = try await sql.raw("""
        SELECT room_shard_id, owner_epoch FROM \(unsafeRaw: schema).rooms WHERE room_id = \(bind: roomID) FOR UPDATE
        """).first(decoding: RoomOwnerFenceRow.self),
          room.shardID == route.shardID, room.epoch == route.epoch
    else { throw V2RoomOwnerFenceError.ownerChanged }
}

/// Business writes call this inside their owner transaction, after any credit
/// refill/pre-reservation transaction has committed and before replay or writes.
/// A separate room-credit reservation must bind its available balance to this
/// same activation token; the business transaction rechecks admission window,
/// lease generation, and credit identity after this fence. Never wait for a
/// refill on another connection while holding a business fence, and never
/// transfer old-token credit to a successor. This helper does not reserve or
/// refund credit and does not, by itself, cover legacy writer call sites.
/// The room lock is NO KEY UPDATE, compatible with the credit reserve's KEY
/// SHARE. All rooms are locked in canonical UUID order; validation occurs only after
/// the final lock, against the database clock at that point. Holding the locks
/// through commit means a newly committed activation epoch excludes any later
/// commit from an old token. An old transaction that held its fence first may
/// commit before the successor acquires its epoch.
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
    // A lock wait may cross expiry. Never use now()/CURRENT_TIMESTAMP, which
    // PostgreSQL fixes at transaction start.
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
