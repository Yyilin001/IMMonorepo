import Foundation
import IMV2ActorContracts
import IMV2Core
import IMV2ServerContracts
import IMV2ServerApplication
import SQLKit

struct V2DurableOwnerBatchOperationKey: Hashable, Encodable, Sendable {
    let roomID: UUID
    let senderID: UUID
    let clientMessageID: UUID
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", senderID = "sender_id", clientMessageID = "client_message_id"
    }
}

/// The same permanent operation lock namespace and hash ordering used
/// by MessageOperationLockBatchStatement. Recursion creates a real dependency
/// between acquisitions; an incidental SELECT result order is insufficient.
func v2AcquireDurableOwnerBatchOperationLocks(
    _ keys: [V2DurableOwnerBatchOperationKey], sql: any SQLDatabase
) async throws {
    let locks = try durableOperationLockCTE(keys)
    guard let row = try await sql.raw("""
        \(locks.statement)
        SELECT count(*)::bigint AS acquired_count FROM locked
        """).first(decoding: DurableOwnerBatchLockCount.self), row.count == Int64(locks.count) else {
        throw V2MessageOperationValidationError.invalidReceipt
    }
}

private func durableOperationLockCTE(_ keys: [V2DurableOwnerBatchOperationKey]) throws
    -> (statement: SQLQueryString, count: Int) {
    guard !keys.isEmpty, keys.count <= 256 else { throw V2MessageOperationValidationError.invalidReceipt }
    let unique = Set(keys).sorted {
        if $0.roomID != $1.roomID { return $0.roomID.uuidString < $1.roomID.uuidString }
        if $0.senderID != $1.senderID { return $0.senderID.uuidString < $1.senderID.uuidString }
        return $0.clientMessageID.uuidString < $1.clientMessageID.uuidString
    }
    let input = String(decoding: try JSONEncoder().encode(unique), as: UTF8.self)
    let statement: SQLQueryString = """
        WITH RECURSIVE key_input AS MATERIALIZED (
            SELECT (row_number() OVER (ORDER BY input.room_id,input.sender_id,input.client_message_id) - 1)::integer AS ordinal,
                   hashtextextended('v2-message-operation:' || input.room_id::text || ':' ||
                       input.sender_id::text || ':' || input.client_message_id::text, 0) AS lock_key
            FROM jsonb_to_recordset(\(bind: input)::jsonb)
              AS input(room_id uuid,sender_id uuid,client_message_id uuid)
        ), input AS MATERIALIZED (
            SELECT (row_number() OVER (ORDER BY lock_key, ordinal) - 1)::integer AS ordinal, lock_key
            FROM key_input
        ), locked(ordinal, lock_acquired) AS (
            SELECT ordinal, pg_advisory_xact_lock(lock_key) FROM input WHERE ordinal=0
            UNION ALL
            SELECT input.ordinal, pg_advisory_xact_lock(input.lock_key)
            FROM locked previous JOIN input ON input.ordinal=previous.ordinal+1
        )
        """
    return (statement, unique.count)
}

/// This distinct cohort path retains the ordinary fence's owner -> activation
/// lock order, but uses constant SQL round trips. It never excludes stale rows
/// in WHERE: every observed row is validated after all locks and a fresh DB
/// clock have been obtained, including rows whose lease expired while waiting.
func v2RequireDurableOwnerBatchActivations(
    tokens: [V2RoomActivationToken], sql: any SQLDatabase,
    schema: String = "im_v2", timeouts: V2RoomActivationSQLTimeouts = .default,
    configureTimeouts: Bool = true
) async throws {
    defer { V2RoomSQLContinuationObservation.current?.finishWithoutDispatch() }
    v2PreconditionSQLSchema(schema)
    guard !tokens.isEmpty, tokens.count <= 256 else { throw V2RoomActivationLeaseError.activationChanged }
    var byRoom: [UUID: V2RoomActivationToken] = [:]
    for token in tokens {
        guard let room = token.roomID.uuidValue else { throw V2CoreError.invalidIdentifier }
        if let prior = byRoom[room], prior != token { throw V2RoomActivationLeaseError.activationChanged }
        byRoom[room] = token
    }
    let ordered = byRoom.keys.sorted { $0.uuidString < $1.uuidString }
    let input = String(decoding: try JSONEncoder().encode(ordered.map(\.uuidString)), as: UTF8.self)
    if configureTimeouts { try await v2SetRoomActivationSQLTimeouts(timeouts, sql: sql) }
    let rooms = try await v2RoomSQLObservedAll(sql.raw("""
        SELECT room_id,room_shard_id,owner_epoch FROM \(unsafeRaw: schema).rooms
        WHERE room_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: input)::jsonb)
                         LIMIT \(literal: ordered.count))
        ORDER BY room_id FOR NO KEY UPDATE
        """), decoding: DurableOwnerBatchRoomRow.self, source: .durableFenceRooms)
    let leases = try await v2LockRoomActivationLeasesAndClock(
        roomIDs: ordered, sql: sql, schema: schema, source: .durableFenceLeases)
    // Preserve missing/owner errors before reporting lease validation failures.
    guard rooms.count == ordered.count, Set(rooms.map(\.roomID)) == Set(ordered) else {
        throw V2RoomActivationLeaseError.roomNotFound
    }
    for room in rooms {
        guard let token = byRoom[room.roomID], room.shardID == token.owner.shardID,
              room.epoch == token.owner.epoch else { throw V2RoomActivationLeaseError.ownerChanged }
    }
    guard leases.count == ordered.count, Set(leases.map(\.roomID)) == Set(ordered) else {
        throw V2RoomActivationLeaseError.activationChanged
    }
    for lease in leases {
        guard let token = byRoom[lease.roomID], lease.matches(token) else { throw V2RoomActivationLeaseError.activationChanged }
        guard let expiry = lease.expiresAt, expiry > lease.observedAt else { throw V2RoomActivationLeaseError.leaseExpired }
    }
}

/// Per-room read outcomes use the same canonical lock order and full authority
/// as durable writes. A stale room does not prevent a healthy read sibling.
/// Authorized database snapshot, independent of uncommitted command-lane turns.
func v2RoomSnapshotReadActivationFences(
    tokens: [V2RoomActivationToken], sql: any SQLDatabase,
    schema: String = "im_v2", timeouts: V2RoomActivationSQLTimeouts = .default
) async throws -> [RoomID: Result<Void, any Error>] {
    defer { V2RoomSQLContinuationObservation.current?.finishWithoutDispatch() }
    v2PreconditionSQLSchema(schema)
    guard !tokens.isEmpty, tokens.count <= 100 else { throw V2RoomActivationLeaseError.activationChanged }
    var expected: [UUID: V2RoomActivationToken] = [:]
    for token in tokens {
        guard let room = token.roomID.uuidValue, expected[room] == nil else {
            throw V2RoomActivationLeaseError.activationChanged
        }
        expected[room] = token
    }
    let ordered = expected.keys.sorted { $0.uuidString < $1.uuidString }
    let input = String(decoding: try JSONEncoder().encode(ordered.map(\.uuidString)), as: UTF8.self)
    try await v2SetRoomActivationSQLTimeouts(timeouts, sql: sql)
    let rooms = try await v2RoomSQLObservedAll(sql.raw("""
        SELECT room_id,room_shard_id,owner_epoch FROM \(unsafeRaw: schema).rooms
        WHERE room_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: input)::jsonb))
        ORDER BY room_id FOR SHARE
        """), decoding: DurableOwnerBatchRoomRow.self, source: .durableFenceRooms)
    let leases = try await v2RoomSQLObservedAll(sql.raw("""
        WITH requested AS MATERIALIZED (
            SELECT value::uuid AS room_id FROM jsonb_array_elements_text(\(bind: input)::jsonb)
        ), locked_leases AS MATERIALIZED (
            SELECT lease.* FROM \(unsafeRaw: schema).room_activation_leases AS lease
            JOIN requested USING(room_id) ORDER BY lease.room_id FOR SHARE OF lease
        ), leases_done AS MATERIALIZED (
            SELECT count(*) AS locked_count FROM locked_leases
        ), observed AS MATERIALIZED (
            SELECT clock_timestamp() AS observed_at FROM leases_done WHERE locked_count >= 0
        )
        SELECT requested.room_id, lease.activation_epoch, lease.owner_shard_id, lease.owner_epoch,
               lease.host_id, lease.host_incarnation_id, lease.expires_at, observed.observed_at
        FROM requested CROSS JOIN observed LEFT JOIN locked_leases AS lease USING(room_id)
        ORDER BY requested.room_id
        """), decoding: V2LockedRoomActivationLeaseRow.self, source: .durableFenceLeases)
    guard Set(rooms.map(\.roomID)).count == rooms.count,
          rooms.allSatisfy({ expected[$0.roomID] != nil }),
          leases.count == ordered.count, Set(leases.map(\.roomID)) == Set(ordered) else {
        throw V2RoomActivationLeaseError.activationChanged
    }
    let owners = Dictionary(uniqueKeysWithValues: rooms.map { ($0.roomID, $0) })
    let leaseRows = Dictionary(uniqueKeysWithValues: leases.map { ($0.roomID, $0) })
    var result: [RoomID: Result<Void, any Error>] = [:]
    for id in ordered {
        let token = expected[id]!
        do {
            guard let owner = owners[id] else { throw V2RoomActivationLeaseError.roomNotFound }
            guard owner.shardID == token.owner.shardID, owner.epoch == token.owner.epoch else {
                throw V2RoomActivationLeaseError.ownerChanged
            }
            guard let lease = leaseRows[id], lease.matches(token) else {
                throw V2RoomActivationLeaseError.activationChanged
            }
            guard let expiry = lease.expiresAt, expiry > lease.observedAt else {
                throw V2RoomActivationLeaseError.leaseExpired
            }
            result[token.roomID] = .success(())
        } catch { result[token.roomID] = .failure(error) }
    }
    return result
}


/// Every lock stage depends on completion of the preceding materialized stage.
/// Receipt reads remain a separate statement after this fence settles.
func v2RequireDurableOperationAndActivationLocks(
    keys: [V2DurableOwnerBatchOperationKey], tokens: [V2RoomActivationToken], sql: any SQLDatabase
) async throws {
    guard !keys.isEmpty, keys.count <= 256, !tokens.isEmpty, tokens.count <= 256 else {
        throw V2MessageOperationValidationError.invalidReceipt
    }
    let locks = try durableOperationLockCTE(keys)
    var expected: [UUID: V2RoomActivationToken] = [:]
    for token in tokens {
        guard let room = token.roomID.uuidValue else { throw V2CoreError.invalidIdentifier }
        if let prior = expected[room], prior != token { throw V2RoomActivationLeaseError.activationChanged }
        expected[room] = token
    }
    guard keys.allSatisfy({ expected[$0.roomID] != nil }) else {
        throw V2RoomActivationLeaseError.activationChanged
    }
    let roomsInput = String(decoding: try JSONEncoder().encode(expected.keys.sorted { $0.uuidString < $1.uuidString }.map(\.uuidString)), as: UTF8.self)
    let rows = try await v2RoomSQLObservedAll(sql.raw("""
        \(locks.statement), operation_locks_done AS MATERIALIZED (
            SELECT count(*) AS acquired_count FROM locked
        ), requested AS MATERIALIZED (
            SELECT value::uuid AS room_id FROM jsonb_array_elements_text(\(bind: roomsInput)::jsonb)
        ), locked_rooms AS MATERIALIZED (
            SELECT room.room_id, room.room_shard_id, room.owner_epoch
            FROM im_v2.rooms room JOIN requested USING(room_id) CROSS JOIN operation_locks_done
            WHERE acquired_count=\(bind: locks.count)
            ORDER BY room.room_id FOR NO KEY UPDATE OF room
        ), rooms_done AS MATERIALIZED (
            SELECT count(*) AS locked_count FROM locked_rooms
        ), locked_leases AS MATERIALIZED (
            SELECT lease.* FROM im_v2.room_activation_leases lease JOIN requested USING(room_id)
            CROSS JOIN rooms_done WHERE locked_count>=0
            ORDER BY lease.room_id FOR UPDATE OF lease
        ), leases_done AS MATERIALIZED (
            SELECT count(*) AS locked_count FROM locked_leases
        ), observed AS MATERIALIZED (
            SELECT clock_timestamp() AS observed_at FROM leases_done WHERE locked_count>=0
        )
        SELECT requested.room_id, room.room_shard_id, room.owner_epoch AS room_owner_epoch,
               lease.activation_epoch, lease.owner_shard_id, lease.owner_epoch,
               lease.host_id, lease.host_incarnation_id, lease.expires_at, observed.observed_at
        FROM requested CROSS JOIN observed
        LEFT JOIN locked_rooms room USING(room_id) LEFT JOIN locked_leases lease USING(room_id)
        ORDER BY requested.room_id
        """), decoding: DurableCombinedFenceRow.self, source: .durableFenceCombined)
    guard rows.count == expected.count, Set(rows.map { $0.lease.roomID }) == Set(expected.keys) else {
        throw V2RoomActivationLeaseError.activationChanged
    }
    // Preserve room/owner error precedence before lease identity and expiry.
    for row in rows {
        guard let shard = row.shardID, let epoch = row.epoch else { throw V2RoomActivationLeaseError.roomNotFound }
        let token = expected[row.lease.roomID]!
        guard shard == token.owner.shardID, epoch == token.owner.epoch else {
            throw V2RoomActivationLeaseError.ownerChanged
        }
    }
    for row in rows {
        guard row.lease.matches(expected[row.lease.roomID]!) else { throw V2RoomActivationLeaseError.activationChanged }
        guard let expiry = row.lease.expiresAt, expiry > row.lease.observedAt else {
            throw V2RoomActivationLeaseError.leaseExpired
        }
    }

}

private struct DurableCombinedFenceRow: Decodable {
    let shardID: String?
    let epoch: Int64?
    let lease: V2LockedRoomActivationLeaseRow
    enum CodingKeys: String, CodingKey { case shardID = "room_shard_id", epoch = "room_owner_epoch" }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shardID = try container.decodeIfPresent(String.self, forKey: .shardID)
        epoch = try container.decodeIfPresent(Int64.self, forKey: .epoch)
        lease = try V2LockedRoomActivationLeaseRow(from: decoder)
    }
}

private struct DurableOwnerBatchLockCount: Decodable {
    let count: Int64
    enum CodingKeys: String, CodingKey { case count = "acquired_count" }
}
private struct DurableOwnerBatchRoomRow: Decodable {
    let roomID: UUID, shardID: String, epoch: Int64
    enum CodingKeys: String, CodingKey { case roomID="room_id",shardID="room_shard_id",epoch="owner_epoch" }
}
