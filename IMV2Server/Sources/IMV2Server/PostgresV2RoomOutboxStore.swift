import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Durable at-least-once outbox implementation. The lease token fences a
/// stale worker from marking a newer claim as published or released.
public struct PostgresV2RoomOutboxStore: V2BatchRoomOutboxStore {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID

    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database
        self.makeUUID = makeUUID
    }

    public func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2OutboxLease] {
        guard limit > 0, leaseDuration > 0 else { return [] }
        guard let expiry = v2PostgresFutureTimestamp(now: now, interval: leaseDuration) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let token = makeUUID()
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let rows = try await sql.raw("""
                WITH candidates AS (
                    SELECT source_event_id, plan_id
                    FROM im_v2.room_outbox
                    WHERE state = 'pending'
                      AND (next_attempt_at IS NULL OR next_attempt_at <= \(bind: now))
                      AND (lease_expires_at IS NULL OR lease_expires_at <= \(bind: now))
                    ORDER BY created_at, source_event_id
                    LIMIT \(bind: limit)
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE im_v2.room_outbox AS outbox
                SET claim_token = \(bind: token),
                    lease_expires_at = \(bind: expiry),
                    retry_count = CASE WHEN outbox.retry_count = 9223372036854775807 THEN outbox.retry_count ELSE outbox.retry_count + 1 END
                FROM candidates
                WHERE outbox.source_event_id = candidates.source_event_id
                RETURNING outbox.source_event_id, outbox.plan_id, outbox.retry_count
                """).all(decoding: OutboxRow.self)
            return try rows.map { row in
                .init(
                    trigger: .init(
                        sourceEventID: try EventID(row.sourceEventID.uuidString),
                        planID: try FanoutPlanID(row.planID.uuidString)
                    ),
                    claimToken: token,
                    attempt: try retryAttempt(row.retryCount)
                )
            }
        }
    }

    public func markPublished(_ lease: V2OutboxLease) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let eventID = try eventUUID(lease.trigger.sourceEventID)
        try await sql.raw("""
            UPDATE im_v2.room_outbox
            SET state = 'published', claim_token = NULL, lease_expires_at = NULL,
                next_attempt_at = NULL, paused_at = NULL, last_failure_code = NULL
            WHERE source_event_id = \(bind: eventID)
              AND state = 'pending'
              AND claim_token = \(bind: lease.claimToken)
            """).run()
    }

    public func markPublished(_ leases: [V2OutboxLease]) async throws {
        guard !leases.isEmpty else { return }
        let input = try leases.map {
            OutboxPublishInput(
                sourceEventID: try eventUUID($0.trigger.sourceEventID),
                claimToken: $0.claimToken
            )
        }
        guard Set(input.map(\.sourceEventID)).count == input.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let inputJSON = try outboxJSON(input)
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard let mutation = try await sql.raw("""
                WITH input AS MATERIALIZED (
                    SELECT source_event_id, claim_token
                    FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb)
                        AS value(source_event_id uuid, claim_token uuid)
                ), published AS (
                    UPDATE im_v2.room_outbox AS outbox
                    SET state = 'published', claim_token = NULL,
                        lease_expires_at = NULL, next_attempt_at = NULL,
                        paused_at = NULL, last_failure_code = NULL
                    FROM input
                    WHERE outbox.source_event_id = input.source_event_id
                      AND outbox.state = 'pending'
                      AND outbox.claim_token = input.claim_token
                    RETURNING outbox.source_event_id
                ), already_terminal AS MATERIALIZED (
                    -- Zero-audience settlement (or a completed delivery race)
                    -- can finish the source before relay acknowledgement.
                    -- Accept only durable terminal evidence; pending rows
                    -- still require the exact current claim token above.
                    SELECT outbox.source_event_id
                    FROM input
                    JOIN im_v2.room_outbox AS outbox USING (source_event_id)
                    JOIN im_v2.fanout_plans AS plan
                      ON plan.source_event_id = outbox.source_event_id
                     AND plan.plan_id = outbox.plan_id
                    WHERE outbox.state = 'terminal' AND plan.state = 'terminal'
                )
                SELECT (SELECT COUNT(*)::bigint FROM input) AS input_count,
                       (SELECT COUNT(*)::bigint FROM published)
                         + (SELECT COUNT(*)::bigint FROM already_terminal) AS published_count
                """).first(decoding: OutboxBatchPublishMutationRow.self),
                  mutation.inputCount == Int64(leases.count),
                  mutation.publishedCount == Int64(leases.count)
            else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
        }
    }

    public func release(_ lease: V2OutboxLease) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let eventID = try eventUUID(lease.trigger.sourceEventID)
        try await sql.raw("""
            UPDATE im_v2.room_outbox
            SET claim_token = NULL, lease_expires_at = NULL, next_attempt_at = NULL
            WHERE source_event_id = \(bind: eventID)
              AND state = 'pending'
              AND claim_token = \(bind: lease.claimToken)
        """).run()
    }

    public func scheduleRetry(_ lease: V2OutboxLease, disposition: V2DurableRetryDisposition, now: Date) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let eventID = try eventUUID(lease.trigger.sourceEventID)
        switch disposition {
        case .retry(let retryAt):
            guard v2PostgresTimestampCanEncode(retryAt) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await sql.raw("""
                UPDATE im_v2.room_outbox
                SET claim_token = NULL, lease_expires_at = NULL,
                    next_attempt_at = \(bind: retryAt), paused_at = NULL,
                    last_failure_code = 'worker_failure'
                WHERE source_event_id = \(bind: eventID)
                  AND state = 'pending' AND claim_token = \(bind: lease.claimToken)
                """).run()
        case .pause:
            guard v2PostgresTimestampCanEncode(now) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await sql.raw("""
                UPDATE im_v2.room_outbox
                SET state = 'paused', claim_token = NULL, lease_expires_at = NULL,
                    next_attempt_at = NULL, paused_at = \(bind: now),
                    last_failure_code = 'retry_exhausted'
                WHERE source_event_id = \(bind: eventID)
                  AND state = 'pending' AND claim_token = \(bind: lease.claimToken)
                """).run()
        }
    }

    /// Operator replay is explicit. It never fabricates a terminal result or
    /// alters the source event; it only returns paused work to normal leasing.
    public func requeuePaused(sourceEventID: EventID) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        try await sql.raw("""
            UPDATE im_v2.room_outbox
            SET state = 'pending', claim_token = NULL, lease_expires_at = NULL,
                next_attempt_at = NULL, paused_at = NULL, last_failure_code = NULL,
                retry_count = 0
            WHERE source_event_id = \(bind: try eventUUID(sourceEventID))
              AND state = 'paused'
            """).run()
    }
}

private struct OutboxRow: Decodable {
    let sourceEventID: UUID
    let planID: UUID
    let retryCount: Int64
    enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id", planID = "plan_id", retryCount = "retry_count" }
}

private struct OutboxPublishInput: Encodable {
    let sourceEventID: UUID
    let claimToken: UUID
    enum CodingKeys: String, CodingKey {
        case sourceEventID = "source_event_id"
        case claimToken = "claim_token"
    }
}

private struct OutboxBatchPublishMutationRow: Decodable {
    let inputCount: Int64
    let publishedCount: Int64
    enum CodingKeys: String, CodingKey {
        case inputCount = "input_count"
        case publishedCount = "published_count"
    }
}

private func retryAttempt(_ value: Int64) throws -> Int {
    guard value > 0, value <= Int64(Int.max) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return Int(value)
}

private func eventUUID(_ identifier: EventID) throws -> UUID {
    guard let value = UUID(uuidString: identifier.rawValue) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return value
}


private func outboxJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    guard let json = String(data: try encoder.encode(value), encoding: .utf8) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return json
}
