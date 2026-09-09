import Fluent
import Foundation
import SQLKit

public struct V2ForwardDeliveryLease: Sendable {
    public let export: V2ForwardExport
    public let claimToken: UUID
    public let attempt: Int
    public let expiresAt: Date
}

/// Durable delivery scheduling, separate from the immutable source envelope.
public struct PostgresV2ForwardDeliveryStore: Sendable {
    private let database: any Database
    public init(database: any Database) { self.database = database }

    public func isPaused(exportID: UUID) async throws -> Bool {
        guard let sql = database as? any SQLDatabase else { throw V2ForwardExportError.corruptPersistenceState }
        return try await sql.raw("SELECT EXISTS(SELECT 1 FROM im_v2.message_forward_delivery_jobs WHERE export_id = \(bind: exportID) AND state = 'paused') AS value").first(decoding: DeliveryBoolRow.self)?.value == true
    }

    public func claim(sourceShardID: String, now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2ForwardDeliveryLease] {
        guard !sourceShardID.isEmpty, (1...1_024).contains(limit), leaseDuration.isFinite,
              leaseDuration > 0, leaseDuration <= 3_600 else { throw V2ForwardDeliveryError.invalidConfiguration }
        guard let expiresAt = v2PostgresFutureTimestamp(now: now, interval: leaseDuration) else {
            throw V2ForwardExportError.corruptPersistenceState
        }
        let token = UUID()
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ForwardExportError.corruptPersistenceState }
            let rows = try await sql.raw("""
                WITH candidates AS (
                    SELECT job.export_id FROM im_v2.message_forward_delivery_jobs AS job
                    JOIN im_v2.message_forward_exports AS export ON export.export_id = job.export_id
                    JOIN im_v2.rooms AS room ON room.room_id = export.source_room_id
                    WHERE export.source_shard_id = \(bind: sourceShardID)
                      AND room.room_shard_id = export.source_shard_id AND room.owner_epoch = export.source_epoch
                      AND ((job.state = 'pending' AND job.next_attempt_at <= \(bind: now))
                           OR (job.state = 'claimed' AND job.lease_expires_at <= \(bind: now)))
                    ORDER BY job.next_attempt_at NULLS FIRST, job.created_at, job.export_id
                    LIMIT \(bind: limit) FOR UPDATE OF job SKIP LOCKED
                ), claimed AS (
                    UPDATE im_v2.message_forward_delivery_jobs AS job
                    SET state = 'claimed', claim_token = \(bind: token), lease_expires_at = \(bind: expiresAt),
                        next_attempt_at = NULL, retry_count = CASE WHEN retry_count = 9223372036854775807 THEN retry_count ELSE retry_count + 1 END
                    FROM candidates WHERE candidates.export_id = job.export_id
                    RETURNING job.export_id, job.retry_count
                )
                SELECT export.payload, export.payload_digest, claimed.retry_count
                FROM claimed JOIN im_v2.message_forward_exports AS export ON export.export_id = claimed.export_id
                """).all(decoding: DeliveryClaimRow.self)
            return try rows.map { row in
                guard let attempt = Int(exactly: row.attempt), attempt > 0 else { throw V2ForwardExportError.corruptPersistenceState }
                return try .init(export: .init(payload: row.payload, digest: row.digest), claimToken: token, attempt: attempt, expiresAt: expiresAt)
            }
        }
    }

    public func isCurrent(_ lease: V2ForwardDeliveryLease, now: Date) async throws -> Bool {
        guard v2PostgresTimestampCanEncode(now) else { throw V2ForwardExportError.corruptPersistenceState }
        guard let sql = database as? any SQLDatabase else { throw V2ForwardExportError.corruptPersistenceState }
        return try await sql.raw("""
            SELECT EXISTS(SELECT 1 FROM im_v2.message_forward_delivery_jobs
                WHERE export_id = \(bind: lease.export.intent.exportID) AND state = 'claimed'
                  AND claim_token = \(bind: lease.claimToken) AND lease_expires_at > \(bind: now)) AS value
            """).first(decoding: DeliveryBoolRow.self)?.value == true
    }

    public func complete(_ lease: V2ForwardDeliveryLease, now: Date) async throws -> Bool {
        guard v2PostgresTimestampCanEncode(now) else { throw V2ForwardExportError.corruptPersistenceState }
        guard let sql = database as? any SQLDatabase else { throw V2ForwardExportError.corruptPersistenceState }
        return try await sql.raw("""
            UPDATE im_v2.message_forward_delivery_jobs AS job
            SET state = 'completed', claim_token = NULL, lease_expires_at = NULL,
                next_attempt_at = NULL, completed_at = \(bind: now)
            WHERE job.export_id = \(bind: lease.export.intent.exportID) AND job.state = 'claimed'
              AND job.claim_token = \(bind: lease.claimToken) AND job.lease_expires_at > \(bind: now)
              AND EXISTS(SELECT 1 FROM im_v2.message_forward_export_receipts AS receipt WHERE receipt.export_id = job.export_id)
            RETURNING true AS value
            """).first(decoding: DeliveryBoolRow.self)?.value == true
    }

    public func reschedule(_ lease: V2ForwardDeliveryLease, disposition: V2DurableRetryDisposition,
                           resetAttempts: Bool = false, now: Date) async throws -> Bool {
        guard v2PostgresTimestampCanEncode(now) else { throw V2ForwardExportError.corruptPersistenceState }
        guard let sql = database as? any SQLDatabase else { throw V2ForwardExportError.corruptPersistenceState }
        let state: String, retryAt: Date?
        switch disposition {
        case .retry(let at):
            guard v2PostgresTimestampCanEncode(at) else { throw V2ForwardExportError.corruptPersistenceState }
            state = "pending"; retryAt = at
        case .pause: state = "paused"; retryAt = nil
        }
        return try await sql.raw("""
            UPDATE im_v2.message_forward_delivery_jobs
            SET state = \(bind: state), next_attempt_at = \(bind: retryAt), claim_token = NULL, lease_expires_at = NULL,
                retry_count = CASE WHEN \(bind: resetAttempts) THEN 0 ELSE retry_count END
            WHERE export_id = \(bind: lease.export.intent.exportID) AND state = 'claimed'
              AND claim_token = \(bind: lease.claimToken) AND lease_expires_at > \(bind: now)
            RETURNING true AS value
            """).first(decoding: DeliveryBoolRow.self)?.value == true
    }
}

private struct DeliveryClaimRow: Decodable {
    let payload: Data; let digest: Data; let attempt: Int64
    enum CodingKeys: String, CodingKey { case payload; case digest = "payload_digest"; case attempt = "retry_count" }
}
private struct DeliveryBoolRow: Decodable { let value: Bool }
