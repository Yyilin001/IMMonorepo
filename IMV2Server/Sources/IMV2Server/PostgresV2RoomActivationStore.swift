import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// Actor 的持久化位置位于房间实际所有者数据库中。
/// 解析器必须提供该数据库；此存储绝不经控制数据库路由，
/// 也不把宿主进程当作数据所有者。
public struct PostgresV2RoomActivationStore: V2RoomActivationLeaseStore {
    private let database: any Database
    private let schema: String
    private let timeouts: V2RoomActivationSQLTimeouts

    public init(database: any Database, schema: String = "im_v2", timeouts: V2RoomActivationSQLTimeouts = .default) {
        v2PreconditionSQLSchema(schema)
        self.database = database
        self.schema = schema
        self.timeouts = timeouts
    }

    public func locate(roomID: RoomID, owner: V2RoomDataOwner) async throws -> V2RoomActivationLease? {
        let roomUUID = try uuid(roomID)
        return try await v2WithRoomScopedTransaction(database: database, timeouts: timeouts) { transaction in
            let sql = try activationSQL(transaction)
            try await v2SetRoomActivationSQLTimeouts(timeouts, sql: sql)
            try await v2LockRoomActivationOwner(roomID: roomUUID, owner: owner, sql: sql, schema: schema)
            let row = try await activationRow(roomID: roomUUID, sql: sql)
            let observed = try await v2RoomActivationDatabaseClock(sql: sql)
            guard let row, row.ownerShardID == owner.shardID, row.ownerEpoch == owner.epoch else { return nil }
            return try row.lease(roomID: roomID, observedAt: observed)
        }
    }

    public func acquire(
        roomID: RoomID,
        owner: V2RoomDataOwner,
        host: V2ActorHostIdentity,
        duration: V2ActorMilliseconds
    ) async throws -> V2RoomActivationAcquisition {
        let roomUUID = try uuid(roomID)
        return try await mutation { transaction in
            let sql = try activationSQL(transaction)
            try await v2SetRoomActivationSQLTimeouts(timeouts, sql: sql)
            try await v2LockRoomActivationOwner(roomID: roomUUID, owner: owner, sql: sql, schema: schema)
            // 房间锁串行化首次插入及所有后续操作。
            // 第二把行锁覆盖外部读取方，并在采样数据库时间前取得。
            let row = try await activationRow(roomID: roomUUID, sql: sql)
            let observed = try await v2RoomActivationDatabaseClock(sql: sql)
            if let row, let existing = try row.lease(roomID: roomID, observedAt: observed),
               row.ownerShardID == owner.shardID, row.ownerEpoch == owner.epoch {
                return .occupied(existing)
            }
            let nextEpoch: Int64
            if let row {
                guard row.activationEpoch < Int64.max else { throw V2RoomActivationLeaseError.epochExhausted }
                nextEpoch = row.activationEpoch + 1
            } else {
                nextEpoch = 1
            }
            let expiry = observed.addingTimeInterval(Double(duration.rawValue) / 1_000)
            if row == nil {
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).room_activation_leases
                        (room_id, activation_epoch, owner_shard_id, owner_epoch, host_id, host_incarnation_id, expires_at)
                    VALUES (\(bind: roomUUID), \(bind: nextEpoch), \(bind: owner.shardID), \(bind: owner.epoch),
                            \(bind: host.hostID.rawValue), \(bind: host.incarnationID), \(bind: expiry))
                    """).run()
            } else {
                try await sql.raw("""
                    UPDATE \(unsafeRaw: schema).room_activation_leases SET
                        activation_epoch = \(bind: nextEpoch), owner_shard_id = \(bind: owner.shardID),
                        owner_epoch = \(bind: owner.epoch), host_id = \(bind: host.hostID.rawValue),
                        host_incarnation_id = \(bind: host.incarnationID), expires_at = \(bind: expiry)
                    WHERE room_id = \(bind: roomUUID)
                    """).run()
            }
            let token = V2RoomActivationToken(roomID: roomID, owner: owner,
                activationEpoch: try V2ActorEpoch(nextEpoch), host: host)
            return .acquired(try V2RoomActivationLease(token: token,
                databaseObservedAt: observed, expiresAt: expiry))
        }
    }

    public func renew(token: V2RoomActivationToken, duration: V2ActorMilliseconds) async throws -> V2RoomActivationLease {
        let roomUUID = try uuid(token.roomID)
        return try await mutation { transaction in
            let sql = try activationSQL(transaction)
            try await v2SetRoomActivationSQLTimeouts(timeouts, sql: sql)
            try await v2LockRoomActivationOwner(roomID: roomUUID, owner: token.owner, sql: sql, schema: schema)
            let row = try await activationRow(roomID: roomUUID, sql: sql)
            let observed = try await v2RoomActivationDatabaseClock(sql: sql)
            guard let row, row.matches(token) else { throw V2RoomActivationLeaseError.activationChanged }
            guard let expiresAt = row.expiresAt, expiresAt > observed else { throw V2RoomActivationLeaseError.leaseExpired }
            let renewedExpiry = observed.addingTimeInterval(Double(duration.rawValue) / 1_000)
            try await sql.raw("""
                UPDATE \(unsafeRaw: schema).room_activation_leases SET expires_at = \(bind: renewedExpiry)
                WHERE room_id = \(bind: roomUUID)
                """).run()
            return try V2RoomActivationLease(token: token, databaseObservedAt: observed, expiresAt: renewedExpiry)
        }
    }

    public func release(token: V2RoomActivationToken) async throws -> Bool {
        let roomUUID = try uuid(token.roomID)
        return try await mutation { transaction in
            let sql = try activationSQL(transaction)
            try await v2SetRoomActivationSQLTimeouts(timeouts, sql: sql)
            do {
                try await v2LockRoomActivationOwner(roomID: roomUUID, owner: token.owner, sql: sql, schema: schema)
            } catch let error as V2RoomActivationLeaseError where error == .roomNotFound || error == .ownerChanged {
                return false
            }
            let row = try await activationRow(roomID: roomUUID, sql: sql)
            let observed = try await v2RoomActivationDatabaseClock(sql: sql)
            guard let row, row.matches(token), let expiresAt = row.expiresAt, expiresAt > observed else { return false }
            try await sql.raw("""
                UPDATE \(unsafeRaw: schema).room_activation_leases SET
                    host_id = NULL, host_incarnation_id = NULL, expires_at = NULL
                WHERE room_id = \(bind: roomUUID)
                """).run()
            return true
        }
    }

    private func mutation<Value: Sendable>(
        _ operation: @escaping @Sendable (any Database) async throws -> Value
    ) async throws -> Value {
        do {
            return try await v2WithPostgresTransactionRetry(database: database,
                maximumRetryCount: 0, classifyCommitFailure: true,
                useRoomDeadline: true, operation)
        } catch is V2RoomTransactionOutcomeUnknown {
            throw V2RoomActivationLeaseError.outcomeUnknown
        }
    }

    private func activationRow(roomID: UUID, sql: any SQLDatabase) async throws -> V2RoomActivationPersistenceRow? {
        try await sql.raw("""
            SELECT activation_epoch, owner_shard_id, owner_epoch, host_id, host_incarnation_id, expires_at
            FROM \(unsafeRaw: schema).room_activation_leases WHERE room_id = \(bind: roomID) FOR UPDATE
            """).first(decoding: V2RoomActivationPersistenceRow.self)
    }

    private func uuid(_ roomID: RoomID) throws -> UUID {
        guard let value = roomID.uuidValue else { throw V2CoreError.invalidIdentifier }
        return value
    }

    private func activationSQL(_ database: any Database) throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else { throw V2SchemaReadinessError.unsupportedDatabase }
        return sql
    }
}
