import Foundation
import FluentKit
import SQLKit
import IMV2ActorContracts
import IMV2ServerContracts

public enum V2RealtimePartitionStoreError: Error, Equatable, Sendable {
    case invalidInput, corruptPersistenceState
}

/// Fixed-size control-plane fencing; never used to resolve a publication.
/// Locks are acquired in ascending partition order. Every decision uses a
/// database clock sampled after those locks, and results escape only on COMMIT.
public struct PostgresV2RealtimePartitionLeaseStore: V2RealtimePartitionLeaseStore {
    private let database: any Database
    private let schema: String
    private let operationTimeout: Duration
    private static let partitionCount = 256

    public init(database: any Database, schema: String = "im_v2", operationTimeout: Duration = .seconds(5)) throws {
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw V2RealtimePartitionStoreError.invalidInput
        }
        guard operationTimeout > .zero, operationTimeout <= .seconds(10) else { throw V2RealtimePartitionStoreError.invalidInput }
        self.operationTimeout = operationTimeout
        self.database = database
        self.schema = schema
    }

    public func claim(partitionIDs: [Int], identity: V2GatewayRealtimeIdentity,
                      token: UUID, leaseDuration: TimeInterval) async throws -> [V2RealtimePartitionLease] {
        try validate(partitionIDs)
        try validate(identity)
        try validate(leaseDuration)
        guard !partitionIDs.isEmpty else { return [] }
        return try await transaction { db in
            let sql = try sql(db)
            let rows = try await lockedRows(sql, ids: partitionIDs)
            let now = try await clock(sql)
            let expiry = now.addingTimeInterval(leaseDuration)
            guard v2PostgresTimestampCanEncode(expiry) else {
                throw V2RealtimePartitionStoreError.invalidInput
            }
            var confirmed: [V2RealtimePartitionLease] = []
            var changes: [Mutation] = []
            for row in rows {
                try row.validate()
                if row.expiresAt > now {
                    // A retry of an uncertain claim confirms exactly its token;
                    // it does not extend time or replace an active incarnation.
                    if row.identity == identity, row.token == token {
                        confirmed.append(try row.lease(at: now))
                    }
                    continue
                }
                guard row.epoch < Int64.max else {
                    throw V2RealtimePartitionStoreError.corruptPersistenceState
                }
                changes.append(.init(partitionID: row.partitionID, identity: identity,
                                     epoch: row.epoch + 1, token: token, expiry: expiry))
            }
            confirmed += try await update(sql, changes: changes, now: now)
            return confirmed.sorted { $0.partitionID < $1.partitionID }
        }
    }

    public func renew(_ leases: [V2RealtimePartitionLease],
                      leaseDuration: TimeInterval) async throws -> [V2RealtimePartitionLease] {
        try validate(leases)
        try validate(leaseDuration)
        guard !leases.isEmpty else { return [] }
        let expected = Dictionary(uniqueKeysWithValues: leases.map { ($0.partitionID, $0) })
        return try await transaction { db in
            let sql = try sql(db)
            let rows = try await lockedRows(sql, ids: leases.map(\.partitionID))
            let now = try await clock(sql)
            let expiry = now.addingTimeInterval(leaseDuration)
            guard v2PostgresTimestampCanEncode(expiry) else {
                throw V2RealtimePartitionStoreError.invalidInput
            }
            var changes: [Mutation] = []
            for row in rows {
                try row.validate()
                guard let lease = expected[row.partitionID], row.matches(lease), row.expiresAt > now else { continue }
                changes.append(.init(partitionID: row.partitionID, identity: lease.identity,
                                     epoch: lease.epoch, token: lease.token,
                                     expiry: max(row.expiresAt, expiry)))
            }
            return try await update(sql, changes: changes, now: now)
        }
    }

    public func confirm(_ leases: [V2RealtimePartitionLease]) async throws -> [V2RealtimePartitionLease] {
        try validate(leases)
        guard !leases.isEmpty else { return [] }
        let expected = Dictionary(uniqueKeysWithValues: leases.map { ($0.partitionID, $0) })
        return try await transaction { db in
            let sql = try sql(db)
            let rows = try await lockedRows(sql, ids: leases.map(\.partitionID))
            let now = try await clock(sql)
            var result: [V2RealtimePartitionLease] = []
            for row in rows {
                try row.validate()
                guard let lease = expected[row.partitionID], row.matches(lease), row.expiresAt > now else { continue }
                result.append(try row.lease(at: now))
            }
            return result
        }
    }

    public func release(_ leases: [V2RealtimePartitionLease]) async throws {
        try validate(leases)
        guard !leases.isEmpty else { return }
        let expected = Dictionary(uniqueKeysWithValues: leases.map { ($0.partitionID, $0) })
        try await transaction { db in
            let sql = try sql(db)
            let rows = try await lockedRows(sql, ids: leases.map(\.partitionID))
            let now = try await clock(sql)
            var changes: [Mutation] = []
            for row in rows {
                try row.validate()
                guard let lease = expected[row.partitionID], row.matches(lease) else { continue }
                // Retain the epoch forever. An old release cannot retire a
                // successor, and the next claim must allocate a higher epoch.
                changes.append(.init(partitionID: row.partitionID, identity: lease.identity,
                                     epoch: lease.epoch, token: lease.token,
                                     expiry: min(row.expiresAt, now)))
            }
            _ = try await update(sql, changes: changes, now: now, returningActive: false)
        }
    }

    private func transaction<Value: Sendable>(
        _ body: @escaping @Sendable (any Database) async throws -> Value
    ) async throws -> Value {
        let limit = ContinuousClock.now + operationTimeout
        let deadline = min(V2RoomSQLDeadline.current ?? limit, limit)
        return try await V2RoomSQLDeadline.$current.withValue(deadline) {
            try await v2WithPostgresTransactionRetry(database: database, maximumRetryCount: 0,
                classifyCommitFailure: true, useRoomDeadline: true, body)
        }
    }

    private func lockedRows(_ sql: any SQLDatabase, ids: [Int]) async throws -> [Row] {
        let json = try encode(ids.sorted())
        let rows = try await sql.raw("""
            SELECT partition_id, host_id, service_id, process_incarnation,
                   lease_epoch, lease_token, expires_at
            FROM \(unsafeRaw: schema).realtime_partition_leases
            WHERE partition_id IN (SELECT value::integer
                FROM jsonb_array_elements_text(\(bind: json)::jsonb))
            ORDER BY partition_id FOR UPDATE
            """).all(decoding: Row.self)
        guard rows.map(\.partitionID) == ids.sorted() else {
            throw V2RealtimePartitionStoreError.corruptPersistenceState
        }
        return rows
    }

    private func update(_ sql: any SQLDatabase, changes: [Mutation], now: Date,
                        returningActive: Bool = true) async throws -> [V2RealtimePartitionLease] {
        guard !changes.isEmpty else { return [] }
        let json = try encode(changes.sorted { $0.partitionID < $1.partitionID })
        let rows = try await sql.raw("""
            UPDATE \(unsafeRaw: schema).realtime_partition_leases AS lease
            SET host_id = change.host_id, service_id = change.service_id,
                process_incarnation = change.process_incarnation,
                lease_epoch = change.lease_epoch, lease_token = change.lease_token,
                expires_at = to_timestamp(change.expires_at), updated_at = \(bind: now)
            FROM jsonb_to_recordset(\(bind: json)::jsonb) AS change
                (partition_id integer, host_id text, service_id text,
                 process_incarnation uuid, lease_epoch bigint, lease_token uuid,
                 expires_at double precision)
            WHERE lease.partition_id = change.partition_id
            RETURNING lease.partition_id, lease.host_id, lease.service_id,
                      lease.process_incarnation, lease.lease_epoch, lease.lease_token, lease.expires_at
            """).all(decoding: Row.self)
        let expected = Dictionary(uniqueKeysWithValues: changes.map { ($0.partitionID, $0) })
        guard rows.count == changes.count, Set(rows.map(\.partitionID)).count == changes.count else {
            throw V2RealtimePartitionStoreError.corruptPersistenceState
        }
        for row in rows {
            try row.validate()
            guard let change = expected[row.partitionID], row.identity == change.identity,
                  row.epoch == change.epoch, row.token == change.token,
                  abs(row.expiresAt.timeIntervalSince1970 - change.expirySeconds) < 0.000_01 else {
                throw V2RealtimePartitionStoreError.corruptPersistenceState
            }
        }
        guard returningActive else { return [] }
        return try rows.sorted { $0.partitionID < $1.partitionID }.map { try $0.lease(at: now) }
    }

    private func clock(_ sql: any SQLDatabase) async throws -> Date {
        guard let row = try await sql.raw("SELECT clock_timestamp() AS now").first(decoding: ClockRow.self),
              v2PostgresTimestampCanEncode(row.now) else {
            throw V2RealtimePartitionStoreError.corruptPersistenceState
        }
        return row.now
    }
    private func sql(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else { throw V2RealtimePartitionStoreError.corruptPersistenceState }
        return sql
    }
    private func encode<T: Encodable>(_ value: T) throws -> String {
        guard let string = String(data: try JSONEncoder().encode(value), encoding: .utf8) else {
            throw V2RealtimePartitionStoreError.corruptPersistenceState
        }
        return string
    }
    private func validate(_ ids: [Int]) throws {
        guard ids.count <= Self.partitionCount, Set(ids).count == ids.count,
              ids.allSatisfy({ (0..<Self.partitionCount).contains($0) }) else {
            throw V2RealtimePartitionStoreError.invalidInput
        }
    }
    private func validate(_ identity: V2GatewayRealtimeIdentity) throws {
        guard !identity.nodeID.isEmpty, identity.nodeID.utf8.count <= 128,
              !identity.serviceID.isEmpty, identity.serviceID.utf8.count <= 128 else {
            throw V2RealtimePartitionStoreError.invalidInput
        }
    }
    private func validate(_ duration: TimeInterval) throws {
        guard duration.isFinite, duration > 0, duration <= 300 else {
            throw V2RealtimePartitionStoreError.invalidInput
        }
    }
    private func validate(_ leases: [V2RealtimePartitionLease]) throws {
        try validate(leases.map(\.partitionID))
        for lease in leases {
            try validate(lease.identity)
            guard lease.epoch > 0, lease.remainingLeaseSeconds.isFinite else {
                throw V2RealtimePartitionStoreError.invalidInput
            }
        }
    }

    private struct ClockRow: Decodable { let now: Date }
    private struct Row: Decodable {
        let partitionID: Int
        let hostID: String?
        let serviceID: String?
        let incarnation: UUID?
        let epoch: Int64
        let token: UUID?
        let expiresAt: Date
        enum CodingKeys: String, CodingKey {
            case partitionID = "partition_id", hostID = "host_id", serviceID = "service_id"
            case incarnation = "process_incarnation", epoch = "lease_epoch"
            case token = "lease_token", expiresAt = "expires_at"
        }
        var identity: V2GatewayRealtimeIdentity? {
            guard let hostID, let serviceID, let incarnation else { return nil }
            return .init(nodeID: hostID, serviceID: serviceID, incarnationID: incarnation)
        }
        func validate() throws {
            let initial = epoch == 0 && hostID == nil && serviceID == nil && incarnation == nil && token == nil
            let assigned = epoch > 0 && identity != nil && token != nil
            guard (initial || assigned), (0..<256).contains(partitionID),
                  v2PostgresTimestampCanEncode(expiresAt) else {
                throw V2RealtimePartitionStoreError.corruptPersistenceState
            }
        }
        func matches(_ lease: V2RealtimePartitionLease) -> Bool {
            identity == lease.identity && epoch == lease.epoch && token == lease.token
        }
        func lease(at now: Date) throws -> V2RealtimePartitionLease {
            guard let identity, let token, epoch > 0, expiresAt > now else {
                throw V2RealtimePartitionStoreError.corruptPersistenceState
            }
            return .init(partitionID: partitionID, identity: identity, epoch: epoch,
                         token: token, remainingLeaseSeconds: expiresAt.timeIntervalSince(now))
        }
    }
    private struct Mutation: Encodable {
        let partitionID: Int
        let identity: V2GatewayRealtimeIdentity
        let epoch: Int64
        let token: UUID
        let expirySeconds: TimeInterval
        var hostID: String { identity.nodeID }
        var serviceID: String { identity.serviceID }
        var incarnation: UUID { identity.incarnationID }
        enum CodingKeys: String, CodingKey {
            case partitionID = "partition_id", hostID = "host_id", serviceID = "service_id"
            case incarnation = "process_incarnation", epoch = "lease_epoch", token = "lease_token"
            case expirySeconds = "expires_at"
        }
        init(partitionID: Int, identity: V2GatewayRealtimeIdentity, epoch: Int64, token: UUID, expiry: Date) {
            self.partitionID = partitionID; self.identity = identity
            self.epoch = epoch; self.token = token; self.expirySeconds = expiry.timeIntervalSince1970
        }
        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(partitionID, forKey: .partitionID)
            try values.encode(hostID, forKey: .hostID)
            try values.encode(serviceID, forKey: .serviceID)
            try values.encode(incarnation, forKey: .incarnation)
            try values.encode(epoch, forKey: .epoch)
            try values.encode(token, forKey: .token)
            try values.encode(expirySeconds, forKey: .expirySeconds)
        }
    }
}
