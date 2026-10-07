import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2Core
import SQLKit

/// One queue per physical store instance; struct copies share the queue. A
/// cancelled waiter never cancels an accepted SQL transaction. Shutdown waits
/// for commit/rollback before the database owner may close its pool.
actor V2RoomActivationRenewalBatcher {
    enum Failure: Error { case closed, overloaded }
    private struct Request {
        let token: V2RoomActivationToken
        let duration: V2ActorMilliseconds
        let continuation: CheckedContinuation<V2RoomActivationLease, any Error>
    }
    private struct Input: Sendable {
        let token: V2RoomActivationToken
        let duration: V2ActorMilliseconds
    }
    private let database: any Database
    private let schema: String
    private let timeouts: V2RoomActivationSQLTimeouts
    private var queue: [Request] = []
    private var inflight = 0
    private var accepted = 0
    private var closed = false
    private var window: Task<Void, Never>?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(database: any Database, schema: String, timeouts: V2RoomActivationSQLTimeouts) {
        self.database = database; self.schema = schema; self.timeouts = timeouts
    }

    func renew(token: V2RoomActivationToken, duration: V2ActorMilliseconds) async throws -> V2RoomActivationLease {
        try Task.checkCancellation()
        guard !closed else { throw Failure.closed }
        guard accepted < 10_000 else { throw Failure.overloaded }
        let lease = try await withCheckedThrowingContinuation { continuation in
            accepted += 1
            queue.append(.init(token: token, duration: duration, continuation: continuation))
            schedule()
        }
        try Task.checkCancellation()
        return lease
    }

    private func schedule() {
        guard !queue.isEmpty, inflight < 2 else { return }
        if closed || queue.count >= 128 {
            window?.cancel(); window = nil
            pump()
        } else if window == nil {
            window = Task {
                do { try await Task.sleep(for: .milliseconds(2)) }
                catch { return }
                self.window = nil
                self.pump()
            }
        }
    }

    private func pump() {
        while inflight < 2, !queue.isEmpty {
            let count = min(128, queue.count)
            let batch = Array(queue.prefix(count)); queue.removeFirst(count)
            inflight += 1
            let database = self.database; let schema = self.schema; let timeouts = self.timeouts
            let inputs = batch.map { Input(token: $0.token, duration: $0.duration) }
            Task {
                let results: [Result<V2RoomActivationLease, any Error>]
                do { results = try await Self.commit(inputs, database: database, schema: schema, timeouts: timeouts) }
                catch { results = inputs.map { _ in .failure(error) } }
                self.completed(batch, results: results)
            }
        }
    }

    private func completed(_ batch: [Request], results: [Result<V2RoomActivationLease, any Error>]) {
        for (request, result) in zip(batch, results) { request.continuation.resume(with: result) }
        accepted -= batch.count; inflight -= 1
        schedule()
        if closed, accepted == 0 {
            let waiters = drainWaiters; drainWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func shutdown() async {
        closed = true
        window?.cancel(); window = nil
        // Requests not yet dispatched own no SQL or row lock. Reject them;
        // only actual in-flight transactions must finish before pool shutdown.
        let pending = queue; queue.removeAll(); accepted -= pending.count
        for request in pending { request.continuation.resume(throwing: Failure.closed) }
        if accepted > 0 { await withCheckedContinuation { drainWaiters.append($0) } }
    }

    private static func commit(_ inputs: [Input], database: any Database, schema: String,
                               timeouts: V2RoomActivationSQLTimeouts) async throws -> [Result<V2RoomActivationLease, any Error>] {
        let ids = Set(inputs.compactMap { $0.token.roomID.uuidValue }).sorted { $0.uuidString < $1.uuidString }
        // The public adapter checks UUIDs before enqueueing. Keep the internal
        // boundary defensive too: malformed siblings must never create IN ()
        // or turn a valid request's transaction into a decoding failure.
        guard !ids.isEmpty else { return inputs.map { _ in .failure(V2CoreError.invalidIdentifier) } }
        do {
            return try await v2WithPostgresTransactionRetry(database: database, maximumRetryCount: 0,
                classifyCommitFailure: true, useRoomDeadline: true) { transaction in
                guard let sql = transaction as? any SQLDatabase else { throw V2SchemaReadinessError.unsupportedDatabase }
                try await v2SetRoomActivationSQLTimeouts(timeouts, sql: sql)
                var list: SQLQueryString = ""
                for (index, id) in ids.enumerated() {
                    if index > 0 { list += "," }
                    list += "\(bind: id)"
                }
                // Keep a fresh statement snapshot AFTER the room locks. A
                // predecessor may have inserted a lease while we waited for
                // its room lock; EPQ alone cannot reveal that new row inside
                // a single statement's original snapshot.
                let rooms = try await sql.raw("""
                    SELECT room_id,room_shard_id,owner_epoch FROM \(unsafeRaw: schema).rooms
                    WHERE room_id IN (\(list)) ORDER BY room_id FOR NO KEY UPDATE
                    """).all(decoding: RenewalOwner.self)
                var owners: SQLQueryString = "SELECT NULL::uuid,NULL::text,NULL::bigint WHERE false"
                if !rooms.isEmpty {
                    owners = "VALUES "
                    for (index, room) in rooms.enumerated() {
                        if index > 0 { owners += "," }
                        owners += "(\(bind: room.roomID)::uuid,\(bind: room.shardID)::text,\(bind: room.ownerEpoch)::bigint)"
                    }
                }
                var values: SQLQueryString = ""
                for (ordinal, input) in inputs.enumerated() {
                    if ordinal > 0 { values += "," }
                    let token = input.token
                    values += """
                        (\(bind: ordinal)::integer,\(bind: token.roomID.uuidValue)::uuid,
                         \(bind: token.owner.shardID)::text,\(bind: token.owner.epoch)::bigint,
                         \(bind: token.activationEpoch.rawValue)::bigint,\(bind: token.host.hostID.rawValue)::text,
                         \(bind: token.host.incarnationID)::uuid,\(bind: input.duration.rawValue)::bigint)
                        """
                }
                // The aggregate fully consumes every sorted lease LockRows
                // result before evaluating the volatile database clock. Room
                // ownership values came from the already-held room locks;
                // lease comparisons use the post-wait EPQ returned versions.
                let rows = try await sql.raw("""
                    WITH requests(ordinal,room_id,owner_shard_id,owner_epoch,activation_epoch,
                                  host_id,host_incarnation_id,duration_ms) AS MATERIALIZED (VALUES \(values)),
                    locked_rooms(room_id,room_shard_id,owner_epoch) AS MATERIALIZED (\(owners)),
                    locked_leases AS MATERIALIZED (
                        SELECT lease.room_id,lease.activation_epoch,lease.owner_shard_id,lease.owner_epoch,
                               lease.host_id,lease.host_incarnation_id,lease.expires_at
                        FROM \(unsafeRaw: schema).room_activation_leases AS lease
                        WHERE lease.room_id IN (SELECT room_id FROM requests)
                        ORDER BY lease.room_id FOR UPDATE OF lease
                    ),
                    leases_done AS MATERIALIZED (SELECT count(*) AS locked_count FROM locked_leases),
                    observed AS MATERIALIZED (
                        SELECT clock_timestamp() AS database_now FROM leases_done WHERE locked_count >= 0
                    ),
                    checked AS MATERIALIZED (
                        SELECT request.*,observed.database_now,lease.expires_at AS old_expiry,
                          CASE
                            WHEN request.room_id IS NULL THEN 'invalid_identifier'
                            WHEN room.room_id IS NULL THEN 'room_not_found'
                            WHEN room.room_shard_id IS DISTINCT FROM request.owner_shard_id
                              OR room.owner_epoch IS DISTINCT FROM request.owner_epoch THEN 'owner_changed'
                            WHEN lease.room_id IS NULL
                              OR lease.activation_epoch IS DISTINCT FROM request.activation_epoch
                              OR lease.owner_shard_id IS DISTINCT FROM request.owner_shard_id
                              OR lease.owner_epoch IS DISTINCT FROM request.owner_epoch
                              OR lease.host_id IS DISTINCT FROM request.host_id
                              OR lease.host_incarnation_id IS DISTINCT FROM request.host_incarnation_id THEN 'activation_changed'
                            WHEN lease.expires_at IS NULL OR lease.expires_at <= observed.database_now THEN 'lease_expired'
                          END AS failure
                        FROM requests AS request CROSS JOIN observed
                        LEFT JOIN locked_rooms AS room ON room.room_id=request.room_id
                        LEFT JOIN locked_leases AS lease ON lease.room_id=request.room_id
                    ),
                    renewals AS MATERIALIZED (
                        SELECT room_id,max(GREATEST(old_expiry,
                            database_now + duration_ms * interval '1 millisecond')) AS renewed_expiry
                        FROM checked WHERE failure IS NULL GROUP BY room_id
                    ),
                    updated AS (
                        UPDATE \(unsafeRaw: schema).room_activation_leases AS lease
                        SET expires_at=renewals.renewed_expiry
                        FROM renewals JOIN locked_leases AS original USING(room_id)
                        -- Authorization and expiry use checked's locked,
                        -- post-wait row versions. Repeating them against the
                        -- UPDATE target's original snapshot can prefilter an
                        -- otherwise valid EPQ-updated lease. The source join
                        -- limits writes to leases already locked by this txn;
                        -- no other transaction can change them before COMMIT.
                        WHERE lease.room_id=renewals.room_id
                        RETURNING lease.room_id,lease.expires_at
                    )
                    SELECT checked.ordinal,checked.failure,checked.database_now,
                           updated.expires_at AS renewed_expiry
                    FROM checked LEFT JOIN updated ON updated.room_id=checked.room_id
                    ORDER BY checked.ordinal
                    """).all(decoding: RenewalResult.self)
                guard rows.count == inputs.count else { throw V2RoomWriteStoreError.corruptPersistenceState }
                return try rows.enumerated().map { ordinal, row in
                    guard row.ordinal == ordinal else { throw V2RoomWriteStoreError.corruptPersistenceState }
                    if let failure = row.failure {
                        let error: any Error
                        switch failure {
                        case "invalid_identifier": error = V2CoreError.invalidIdentifier
                        case "room_not_found": error = V2RoomActivationLeaseError.roomNotFound
                        case "owner_changed": error = V2RoomActivationLeaseError.ownerChanged
                        case "activation_changed": error = V2RoomActivationLeaseError.activationChanged
                        case "lease_expired": error = V2RoomActivationLeaseError.leaseExpired
                        default: throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                        return .failure(error)
                    }
                    guard let expiry = row.renewedExpiry else { throw V2RoomWriteStoreError.corruptPersistenceState }
                    return .success(try V2RoomActivationLease(token: inputs[ordinal].token,
                        databaseObservedAt: row.databaseNow, expiresAt: expiry))
                }
            }
        } catch is V2RoomTransactionOutcomeUnknown { throw V2RoomActivationLeaseError.outcomeUnknown }
        catch V2RoomCallFailure.rolledBack(.unavailable) { throw V2RoomActivationLeaseError.renewalDeferred }
    }
}

private struct RenewalResult: Decodable {
    let ordinal: Int
    let failure: String?
    let databaseNow: Date
    let renewedExpiry: Date?
    enum CodingKeys: String, CodingKey {
        case ordinal, failure
        case databaseNow = "database_now", renewedExpiry = "renewed_expiry"
    }
}

private struct RenewalOwner: Decodable {
    let roomID: UUID
    let shardID: String
    let ownerEpoch: Int64
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", shardID = "room_shard_id", ownerEpoch = "owner_epoch"
    }
}
