import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// 事务性审核发件箱的 PostgreSQL 持久化实现。
///
/// 它只存储编码/严重级别/置信度；这条运行路径不保留任何文本或提供方响应。
public struct PostgresV2ContentReviewStore: V2ContentReviewStore {
    private static let configuredPolicyVersion = "configured-terms-1"
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID

    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database
        self.makeUUID = makeUUID
    }

    public func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2ContentReviewLease] {
        guard limit > 0, leaseDuration > 0 else { return [] }
        guard let expiresAt = v2PostgresFutureTimestamp(now: now, interval: leaseDuration) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let token = makeUUID()
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let rows = try await sql.raw("""
                WITH candidates AS (
                    SELECT message_id
                    FROM im_v2.content_review_jobs AS job
                    WHERE ((state = 'pending' AND COALESCE(next_attempt_at, created_at) <= \(bind: now))
                       OR (state = 'claimed' AND lease_expires_at <= \(bind: now)))
                      AND (SELECT true FROM im_v2.rooms AS room
                           WHERE room.room_id = job.room_id
                           FOR SHARE OF room SKIP LOCKED)
                    ORDER BY created_at, message_id
                    LIMIT \(bind: limit)
                    FOR UPDATE OF job SKIP LOCKED
                )
                UPDATE im_v2.content_review_jobs AS job
                SET state = 'claimed', claim_token = \(bind: token), lease_expires_at = \(bind: expiresAt),
                    next_attempt_at = NULL, paused_at = NULL,
                    retry_count = CASE WHEN job.retry_count = 2147483647
                        THEN job.retry_count ELSE job.retry_count + 1 END
                FROM candidates
                WHERE job.message_id = candidates.message_id
                RETURNING job.message_id, job.room_id, job.expected_content_revision,
                          (SELECT text_body FROM im_v2.messages WHERE message_id = job.message_id) AS text_body,
                          (SELECT COUNT(*) FROM im_v2.message_media_references WHERE message_id = job.message_id AND revoked_at IS NULL) AS media_count,
                          job.retry_count, job.decision, job.finding_category,
                          job.finding_severity, job.finding_confidence
                """).all(decoding: ContentReviewClaimRow.self)
            return try rows.map { row in
                let stagedViolation: V2ContentReviewFinding?
                if row.decision == "violation" {
                    guard let category = row.findingCategory,
                          let severity = row.findingSeverity,
                          let confidence = row.findingConfidence
                    else { throw V2RoomWriteStoreError.corruptPersistenceState }
                    stagedViolation = try .init(category: category, severity: severity, confidence: confidence)
                } else {
                    guard row.decision == nil,
                          row.findingCategory == nil,
                          row.findingSeverity == nil,
                          row.findingConfidence == nil
                    else { throw V2RoomWriteStoreError.corruptPersistenceState }
                    stagedViolation = nil
                }
                return try V2ContentReviewLease(
                    input: V2ContentReviewInput(
                        messageID: MessageID(row.messageID.uuidString),
                        roomID: RoomID(row.roomID.uuidString),
                        contentRevision: contentReviewUnsigned(row.contentRevision),
                        text: row.text,
                        mediaCount: row.mediaCount
                    ),
                    claimToken: token,
                    attempt: row.retryCount,
                    stagedViolation: stagedViolation
                )
            }
        }
    }

    public func validateAndRenew(_ lease: V2ContentReviewLease, now: Date, leaseDuration: TimeInterval) async throws -> V2ContentReviewLeaseValidation {
        guard leaseDuration > 0 else { throw V2ContentReviewWorkerError.invalidLeaseDuration }
        guard let renewedUntil = v2PostgresFutureTimestamp(now: now, interval: leaseDuration) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let messageID = try contentReviewUUID(lease.input.messageID)
        let roomID = try contentReviewRoomUUID(lease.input.roomID)
        let expected = try v2PersistenceSigned(lease.input.contentRevision, invalid: V2RoomWriteStoreError.corruptPersistenceState)
        guard expected < Int64.max else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let enforcedRevision = expected + 1
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await lockReviewRoom(lease, sql: sql)
            let renewed = try await sql.raw("""
                UPDATE im_v2.content_review_jobs AS job
                SET lease_expires_at = GREATEST(job.lease_expires_at, \(bind: renewedUntil))
                FROM im_v2.messages AS message
                WHERE job.message_id = \(bind: messageID)
                  AND job.room_id = \(bind: roomID)
                  AND job.state = 'claimed' AND job.claim_token = \(bind: lease.claimToken)
                  AND message.message_id = job.message_id
                  AND (
                      (message.withdrawn_at IS NULL AND message.content_revision = \(bind: expected))
                      OR (
                          job.decision = 'violation'
                          AND EXISTS (
                              SELECT 1 FROM im_v2.moderation_operations AS operation
                              WHERE operation.operation_id = \(bind: messageID)
                                AND operation.room_id = \(bind: roomID)
                                AND operation.action = 'redact_message'
                                AND operation.message_id = \(bind: messageID)
                                AND operation.resulting_message_revision = \(bind: enforcedRevision)
                                AND operation.reason_code = 'content_policy_violation'
                          )
                      )
                  )
                RETURNING job.message_id
                """).first(decoding: ContentReviewMessageRow.self)
            if renewed != nil { return .current }

            let superseded = try await sql.raw("""
                UPDATE im_v2.content_review_jobs AS job
                SET state = 'superseded', completed_at = \(bind: now), claim_token = NULL, lease_expires_at = NULL,
                    decision = NULL, next_attempt_at = NULL, paused_at = NULL,
                    finding_category = NULL, finding_severity = NULL, finding_confidence = NULL
                FROM im_v2.messages AS message
                WHERE job.message_id = \(bind: messageID)
                  AND job.room_id = \(bind: roomID)
                  AND job.state = 'claimed' AND job.claim_token = \(bind: lease.claimToken)
                  AND message.message_id = job.message_id
                  AND (message.withdrawn_at IS NOT NULL OR message.content_revision <> \(bind: expected))
                RETURNING job.message_id
                """).first(decoding: ContentReviewMessageRow.self)
            return superseded == nil ? .lostLease : .superseded
        }
    }

    public func resolve(_ lease: V2ContentReviewLease, verdict: V2ContentReviewVerdict, now: Date) async throws -> Bool {
        guard v2PostgresTimestampCanEncode(now) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let messageID = try contentReviewUUID(lease.input.messageID)
        let data = contentReviewData(verdict)
        return try await database.transaction { transaction in
            guard let tx = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await lockReviewRoom(lease, sql: tx)
            let updated = try await tx.raw("""
                UPDATE im_v2.content_review_jobs
                SET state = \(bind: data.state), decision = \(bind: data.decision), completed_at = \(bind: now),
                    claim_token = NULL, lease_expires_at = NULL, next_attempt_at = NULL, paused_at = NULL,
                    finding_category = \(bind: data.category), finding_severity = \(bind: data.severity),
                    finding_confidence = \(bind: data.confidence)
                WHERE message_id = \(bind: messageID)
                  AND room_id = \(bind: try contentReviewRoomUUID(lease.input.roomID)) AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                RETURNING message_id
                """).first(decoding: ContentReviewMessageRow.self)
            guard updated != nil else { return false }
            try await tx.raw("""
                INSERT INTO im_v2.content_review_decisions (message_id, decision, policy_version, decided_at)
                VALUES (\(bind: messageID), \(bind: data.decision), \(bind: Self.configuredPolicyVersion), \(bind: now))
                ON CONFLICT (message_id) DO UPDATE SET decision = EXCLUDED.decision, policy_version = EXCLUDED.policy_version, decided_at = EXCLUDED.decided_at
                """).run()
            if let category = data.category {
                try await tx.raw("""
                    INSERT INTO im_v2.content_review_findings (message_id, category, severity, confidence, created_at)
                    VALUES (\(bind: messageID), \(bind: category), \(bind: data.severity!), \(bind: data.confidence!), \(bind: now))
                    ON CONFLICT (message_id, category) DO UPDATE SET severity = EXCLUDED.severity, confidence = EXCLUDED.confidence, created_at = EXCLUDED.created_at
                    """).run()
            }
            if data.decision == "review_required" {
                try await tx.raw("""
                    INSERT INTO im_v2.content_review_cases (message_id, status, created_at, updated_at)
                    VALUES (\(bind: messageID), 'open', \(bind: now), \(bind: now))
                    ON CONFLICT (message_id) DO UPDATE SET updated_at = EXCLUDED.updated_at
                    """).run()
            }
            return true
        }
    }

    public func stageViolation(_ lease: V2ContentReviewLease, finding: V2ContentReviewFinding) async throws -> Bool {
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await lockReviewRoom(lease, sql: sql)
            return try await sql.raw("""
            UPDATE im_v2.content_review_jobs
            SET decision = 'violation', finding_category = \(bind: finding.category),
                finding_severity = \(bind: finding.severity), finding_confidence = \(bind: finding.confidence)
            WHERE message_id = \(bind: try contentReviewUUID(lease.input.messageID))
              AND room_id = \(bind: try contentReviewRoomUUID(lease.input.roomID))
              AND expected_content_revision = \(bind: try v2PersistenceSigned(lease.input.contentRevision, invalid: V2RoomWriteStoreError.corruptPersistenceState))
              AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
            RETURNING message_id
            """).first(decoding: ContentReviewMessageRow.self) != nil
        }
    }

    public func scheduleRetry(_ lease: V2ContentReviewLease, disposition: V2DurableRetryDisposition, now: Date) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await lockReviewRoom(lease, sql: sql)
            let messageID = try contentReviewUUID(lease.input.messageID)
            switch disposition {
            case .retry(let retryAt):
                guard v2PostgresTimestampCanEncode(retryAt) else { throw V2RoomWriteStoreError.corruptPersistenceState }
                try await sql.raw("""
                    UPDATE im_v2.content_review_jobs
                    SET state = 'pending', claim_token = NULL, lease_expires_at = NULL,
                        next_attempt_at = \(bind: retryAt), paused_at = NULL
                    WHERE message_id = \(bind: messageID)
                      AND room_id = \(bind: try contentReviewRoomUUID(lease.input.roomID))
                      AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                    """).run()
            case .pause:
                guard v2PostgresTimestampCanEncode(now) else { throw V2RoomWriteStoreError.corruptPersistenceState }
                try await sql.raw("""
                    UPDATE im_v2.content_review_jobs
                    SET state = 'paused', claim_token = NULL, lease_expires_at = NULL,
                        next_attempt_at = NULL, paused_at = \(bind: now)
                    WHERE message_id = \(bind: messageID)
                      AND room_id = \(bind: try contentReviewRoomUUID(lease.input.roomID))
                      AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                    """).run()
            }
        }
    }

    /// 写入任务和派生结果期间保持源房间稳定。
    /// 这是数据库围栏，不会取消执行中的审核者。
    private func lockReviewRoom(_ lease: V2ContentReviewLease, sql: any SQLDatabase) async throws {
        guard try await sql.raw("""
            SELECT room_id FROM im_v2.rooms
            WHERE room_id = \(bind: try contentReviewRoomUUID(lease.input.roomID))

            FOR SHARE
            """).first() != nil else { throw V2RoomOwnerFenceError.ownerChanged }
    }
}

private struct ContentReviewClaimRow: Decodable {
    let messageID: UUID; let roomID: UUID; let contentRevision: Int64; let text: String; let mediaCount: Int; let retryCount: Int
    let decision: String?; let findingCategory: String?; let findingSeverity: Int?; let findingConfidence: Double?
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id", roomID = "room_id", contentRevision = "expected_content_revision"
        case text = "text_body", mediaCount = "media_count", retryCount = "retry_count", decision
        case findingCategory = "finding_category", findingSeverity = "finding_severity", findingConfidence = "finding_confidence"
    }
}
private struct ContentReviewMessageRow: Decodable { let messageID: UUID; enum CodingKeys: String, CodingKey { case messageID = "message_id" } }
private func contentReviewUUID(_ id: MessageID) throws -> UUID { guard let value = UUID(uuidString: id.rawValue) else { throw V2RoomWriteStoreError.corruptPersistenceState }; return value }
private func contentReviewRoomUUID(_ id: RoomID) throws -> UUID { guard let value = UUID(uuidString: id.rawValue) else { throw V2RoomWriteStoreError.corruptPersistenceState }; return value }

private func contentReviewUnsigned(_ value: Int64) -> UInt64 { UInt64(value) }
private func contentReviewData(_ verdict: V2ContentReviewVerdict) -> (state: String, decision: String, category: String?, severity: Int?, confidence: Double?) {
    switch verdict {
    case .clear: return ("completed", "clear", nil, nil, nil)
    case .reviewRequired(let finding): return ("completed", "review_required", finding.category, finding.severity, finding.confidence)
    case .violation(let finding): return ("completed", "violation", finding.category, finding.severity, finding.confidence)
    }
}
