import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import IMV2ServerContracts
import SQLKit
import Synchronization

package struct V2RoomActivationLifecycleInput: Sendable {
    package let roomID: RoomID
    package let operation: Operation
    package enum Operation: Sendable {
        case locate(owner: V2RoomDataOwner)
        case acquire(owner: V2RoomDataOwner, host: V2ActorHostIdentity, duration: V2ActorMilliseconds)
        case release(token: V2RoomActivationToken)
        case validate(token: V2RoomActivationToken)
    }
    package init(roomID: RoomID, operation: Operation) { self.roomID = roomID; self.operation = operation }
    var owner: V2RoomDataOwner {
        switch operation {
        case .locate(let owner), .acquire(let owner, _, _): return owner
        case .release(let token), .validate(let token): return token.owner
        }
    }
}
package enum V2RoomActivationLifecycleValue: Sendable {
    case located(V2RoomActivationLease?)
    case acquired(V2RoomActivationAcquisition)
    case released(Bool)
    case validated
}

/// One bounded physical transaction. Room locks serialize predecessor inserts;
/// the next statement sees those commits before locking leases and sampling time.
package enum V2RoomActivationLifecycleSQL {
    package static func commit(_ inputs: [V2RoomActivationLifecycleInput], database: any Database,
        schema: String, timeouts: V2RoomActivationSQLTimeouts
    ) async throws -> [Result<V2RoomActivationLifecycleValue, any Error>] {
        v2PreconditionSQLSchema(schema)
        guard inputs.count <= 128, Set(inputs.map(\.roomID)).count == inputs.count else {
            throw V2RoomActivationLeaseError.activationChanged
        }
        guard !inputs.isEmpty else { return [] }
        let roomUUIDs = inputs.compactMap { $0.roomID.uuidValue }
        guard Set(roomUUIDs).count == roomUUIDs.count else { throw V2RoomActivationLeaseError.activationChanged }
        let valid = inputs.indices.filter { inputs[$0].roomID.uuidValue != nil }
        let initial = inputs.map { _ in Result<V2RoomActivationLifecycleValue, any Error>.failure(V2CoreError.invalidIdentifier) }
        guard !valid.isEmpty else { return initial }
        let ids = valid.map { inputs[$0].roomID.uuidValue! }.sorted { $0.uuidString < $1.uuidString }
        let encodedIDs = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        // Only independently proven semantic rejections survive a shared SQL
        // failure. No acquired token escapes before actual COMMIT settlement.
        let semantic = Mutex<[Result<V2RoomActivationLifecycleValue, any Error>]?> (nil)
        do {
            return try await v2WithPostgresTransactionRetry(database: database, maximumRetryCount: 0,
                classifyCommitFailure: true, useRoomDeadline: true) { transaction in
                guard let sql = transaction as? any SQLDatabase else { throw V2SchemaReadinessError.unsupportedDatabase }
                try await v2SetRoomActivationSQLTimeouts(timeouts, sql: sql)
                let roomRows = try await v2RoomSQLObservedAll(sql.raw("""
                    SELECT room_id, room_shard_id, owner_epoch
                    FROM \(unsafeRaw: schema).rooms
                    WHERE room_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: encodedIDs)::jsonb))
                    ORDER BY room_id FOR NO KEY UPDATE
                    """), decoding: LifecycleRoomRow.self, source: .lifecycleRooms)
                let rooms = Dictionary(uniqueKeysWithValues: roomRows.map { ($0.roomID, $0) })
                let rows = try await v2RoomSQLObservedAll(sql.raw("""
                    WITH requested AS MATERIALIZED (
                        SELECT value::uuid AS room_id FROM jsonb_array_elements_text(\(bind: encodedIDs)::jsonb)
                    ), locked_leases AS MATERIALIZED (
                        SELECT lease.* FROM \(unsafeRaw: schema).room_activation_leases AS lease
                        JOIN requested USING(room_id) ORDER BY lease.room_id FOR UPDATE OF lease
                    ), leases_done AS MATERIALIZED (SELECT count(*) AS locked_count FROM locked_leases),
                    observed AS MATERIALIZED (
                        SELECT clock_timestamp() AS observed_at FROM leases_done WHERE locked_count >= 0
                    )
                    SELECT requested.room_id, lease.activation_epoch, lease.owner_shard_id, lease.owner_epoch,
                           lease.host_id, lease.host_incarnation_id, lease.expires_at, observed.observed_at
                    FROM requested CROSS JOIN observed LEFT JOIN locked_leases AS lease USING(room_id)
                    ORDER BY requested.room_id
                    """), decoding: LifecycleLeaseRow.self, source: .lifecycleLeases)
                guard rows.count == valid.count else { throw V2RoomActivationLeaseError.activationChanged }
                let leases = Dictionary(uniqueKeysWithValues: rows.map { ($0.roomID, $0) })
                var results = initial
                var changes: [LifecycleMutation] = []
                for index in valid {
                    let input = inputs[index], roomID = input.roomID.uuidValue!
                    do {
                        guard let room = rooms[roomID] else { throw V2RoomActivationLeaseError.roomNotFound }
                        guard room.shardID == input.owner.shardID, room.ownerEpoch == input.owner.epoch else {
                            throw V2RoomActivationLeaseError.ownerChanged
                        }
                        guard let locked = leases[roomID] else { throw V2RoomActivationLeaseError.activationChanged }
                        let row = try locked.persistence(), observed = locked.observedAt
                        switch input.operation {
                        case .locate:
                            if let row, row.ownerShardID == input.owner.shardID, row.ownerEpoch == input.owner.epoch {
                                results[index] = .success(.located(try row.lease(roomID: input.roomID, observedAt: observed)))
                            } else { results[index] = .success(.located(nil)) }
                        case .acquire(let owner, let host, let duration):
                            if let row, let lease = try row.lease(roomID: input.roomID, observedAt: observed),
                               row.ownerShardID == owner.shardID, row.ownerEpoch == owner.epoch {
                                results[index] = .success(.acquired(.occupied(lease)))
                                continue
                            }
                            guard row == nil || row!.activationEpoch < Int64.max else { throw V2RoomActivationLeaseError.epochExhausted }
                            let epoch = (row?.activationEpoch ?? 0) + 1
                            let expiry = observed.addingTimeInterval(Double(duration.rawValue) / 1_000)
                            let token = V2RoomActivationToken(roomID: input.roomID, owner: owner,
                                activationEpoch: try V2ActorEpoch(epoch), host: host)
                            let lease = try V2RoomActivationLease(token: token, databaseObservedAt: observed, expiresAt: expiry)
                            changes.append(try .init(ordinal: index, roomID: roomID, action: row == nil ? "insert" : "acquire",
                                epoch: epoch, owner: owner, host: host, expiresAt: expiry))
                            results[index] = .success(.acquired(.acquired(lease)))
                        case .validate(let token):
                            guard token.roomID == input.roomID else { throw V2CoreError.invalidIdentifier }
                            guard let row, row.matches(token) else {
                                throw V2RoomActivationLeaseError.activationChanged
                            }
                            guard let expiry = row.expiresAt, expiry > observed else {
                                throw V2RoomActivationLeaseError.leaseExpired
                            }
                            results[index] = .success(.validated)
                        case .release(let token):
                            guard token.roomID == input.roomID else { throw V2CoreError.invalidIdentifier }
                            guard let row, row.matches(token), let expiry = row.expiresAt, expiry > observed else {
                                results[index] = .success(.released(false)); continue
                            }
                            changes.append(try .init(ordinal: index, roomID: roomID, action: "release", epoch: row.activationEpoch,
                                owner: input.owner, host: nil, expiresAt: nil))
                            results[index] = .success(.released(true))
                        }
                    } catch let error as V2RoomActivationLeaseError where error == .roomNotFound || error == .ownerChanged {
                        if case .release = input.operation { results[index] = .success(.released(false)) }
                        else { results[index] = .failure(error) }
                    } catch { results[index] = .failure(error) }
                }
                semantic.withLock { $0 = results }
                if !changes.isEmpty { try await mutate(changes, sql: sql, schema: schema) }
                return results
            }
        } catch {
            let failure: any Error
            if error is V2RoomTransactionOutcomeUnknown { failure = V2RoomActivationLeaseError.outcomeUnknown }
            else if let call = error as? V2RoomCallFailure, call == .outcomeUnknown { failure = V2RoomActivationLeaseError.outcomeUnknown }
            else { failure = error }
            let decisions = semantic.withLock { $0 }
            var failed = decisions ?? initial
            for index in valid {
                if decisions == nil { failed[index] = .failure(failure) }
                else if case .success = failed[index] { failed[index] = .failure(failure) }
            }
            return failed
        }
    }

    private static func mutate(_ changes: [LifecycleMutation], sql: any SQLDatabase, schema: String) async throws {
        let payload = String(decoding: try JSONEncoder().encode(changes), as: UTF8.self)
        V2RoomSQLContinuationObservation.current?.willDispatch()
        let returned = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT item.*,
                    CASE WHEN expires_microseconds IS NOT NULL THEN
                        TIMESTAMPTZ '2000-01-01 00:00:00+00'
                        + (expires_microseconds / 86400000000) * INTERVAL '1 day'
                        + (expires_microseconds % 86400000000) * INTERVAL '1 microsecond' END AS expires_at
                FROM jsonb_to_recordset(\(bind: payload)::jsonb)
                    AS item(ordinal integer, room_id uuid, action text, activation_epoch bigint, owner_shard_id text,
                            owner_epoch bigint, host_id text, host_incarnation_id uuid, expires_microseconds bigint)
            ), inserted AS (
                INSERT INTO \(unsafeRaw: schema).room_activation_leases
                    (room_id,activation_epoch,owner_shard_id,owner_epoch,host_id,host_incarnation_id,expires_at)
                SELECT room_id,activation_epoch,owner_shard_id,owner_epoch,host_id,host_incarnation_id,expires_at
                FROM input WHERE action = 'insert' RETURNING *
            ), updated AS (
                UPDATE \(unsafeRaw: schema).room_activation_leases AS lease
                SET activation_epoch=input.activation_epoch,owner_shard_id=input.owner_shard_id,
                    owner_epoch=input.owner_epoch,host_id=input.host_id,
                    host_incarnation_id=input.host_incarnation_id,expires_at=input.expires_at
                FROM input WHERE lease.room_id=input.room_id AND input.action IN ('acquire','release')
                RETURNING lease.*
            )
            SELECT changed.*, input.ordinal,
                CASE WHEN changed.expires_at IS NOT NULL THEN
                    ((extract(epoch FROM changed.expires_at) - 946684800) * 1000000)::bigint
                END AS expires_microseconds
            FROM (SELECT * FROM inserted UNION ALL SELECT * FROM updated) AS changed JOIN input USING(room_id)
            """).all(decoding: LifecycleMutationResult.self)
        guard returned.count == changes.count, Set(returned.map(\.roomID)).count == changes.count else {
            throw V2RoomActivationLeaseError.activationChanged
        }
        let expected = Dictionary(uniqueKeysWithValues: changes.map { ($0.roomID, $0) })
        for row in returned {
            guard let item = expected[row.roomID], row.ordinal == item.ordinal, row.epoch == item.epoch,
                  row.ownerShardID == item.ownerShardID, row.ownerEpoch == item.ownerEpoch,
                  row.hostID == item.hostID, row.hostIncarnationID == item.hostIncarnationID,
                  row.expiresMicroseconds == item.expiresMicroseconds else { throw V2RoomActivationLeaseError.activationChanged }
        }
    }
}

private struct LifecycleRoomRow: Decodable {
    let roomID: UUID; let shardID: String; let ownerEpoch: Int64
    enum CodingKeys: String, CodingKey { case roomID="room_id", shardID="room_shard_id", ownerEpoch="owner_epoch" }
}
private struct LifecycleLeaseRow: Decodable {
    let roomID: UUID; let activationEpoch: Int64?; let ownerShardID: String?; let ownerEpoch: Int64?
    let hostID: String?; let hostIncarnationID: UUID?; let expiresAt: Date?; let observedAt: Date
    enum CodingKeys: String, CodingKey {
        case roomID="room_id", activationEpoch="activation_epoch", ownerShardID="owner_shard_id", ownerEpoch="owner_epoch"
        case hostID="host_id", hostIncarnationID="host_incarnation_id", expiresAt="expires_at", observedAt="observed_at"
    }
    func persistence() throws -> V2RoomActivationPersistenceRow? {
        guard let activationEpoch else { return nil }
        guard let ownerShardID, let ownerEpoch else { throw V2RoomActivationLeaseError.activationChanged }
        return .init(activationEpoch: activationEpoch, ownerShardID: ownerShardID, ownerEpoch: ownerEpoch,
            hostID: hostID, hostIncarnationID: hostIncarnationID, expiresAt: expiresAt)
    }
}
private struct LifecycleMutation: Encodable {
    let ordinal: Int
    let roomID: UUID; let action: String; let epoch: Int64; let ownerShardID: String; let ownerEpoch: Int64
    let hostID: String?; let hostIncarnationID: UUID?; let expiresMicroseconds: Int64?
    init(ordinal: Int, roomID: UUID, action: String, epoch: Int64, owner: V2RoomDataOwner, host: V2ActorHostIdentity?, expiresAt: Date?) throws {
        self.ordinal=ordinal; self.roomID=roomID; self.action=action; self.epoch=epoch; ownerShardID=owner.shardID; ownerEpoch=owner.epoch
        hostID=host?.hostID.rawValue; hostIncarnationID=host?.incarnationID; self.expiresMicroseconds = try expiresAt.map(roomWritePostgresMicroseconds)
    }
    enum CodingKeys: String, CodingKey {
        case ordinal, roomID="room_id", action, epoch="activation_epoch", ownerShardID="owner_shard_id", ownerEpoch="owner_epoch"
        case hostID="host_id", hostIncarnationID="host_incarnation_id", expiresMicroseconds="expires_microseconds"
    }
}
private struct LifecycleMutationResult: Decodable {
    let ordinal: Int
    let roomID: UUID; let epoch: Int64; let ownerShardID: String; let ownerEpoch: Int64
    let hostID: String?; let hostIncarnationID: UUID?; let expiresMicroseconds: Int64?
    enum CodingKeys: String, CodingKey {
        case ordinal, roomID="room_id", epoch="activation_epoch", ownerShardID="owner_shard_id", ownerEpoch="owner_epoch"
        case hostID="host_id", hostIncarnationID="host_incarnation_id", expiresMicroseconds="expires_microseconds"
    }
}
