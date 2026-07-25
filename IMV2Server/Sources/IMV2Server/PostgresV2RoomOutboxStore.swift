import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Durable at-least-once outbox implementation. The lease token fences a
/// stale worker from marking a newer claim as published or released.
public struct PostgresV2RoomOutboxStore: V2RoomOutboxStore {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID

    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database
        self.makeUUID = makeUUID
    }

    public func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2OutboxLease] {
        guard limit > 0, leaseDuration > 0 else { return [] }
        let token = makeUUID()
        let expiry = now.addingTimeInterval(leaseDuration)
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
                    retry_count = outbox.retry_count + 1
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
            try await sql.raw("""
                UPDATE im_v2.room_outbox
                SET claim_token = NULL, lease_expires_at = NULL,
                    next_attempt_at = \(bind: retryAt), paused_at = NULL,
                    last_failure_code = 'worker_failure'
                WHERE source_event_id = \(bind: eventID)
                  AND state = 'pending' AND claim_token = \(bind: lease.claimToken)
                """).run()
        case .pause:
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
