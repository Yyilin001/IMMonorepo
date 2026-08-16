import Fluent
import Foundation
import IMV2Core
import SQLKit

/// The review boundary receives the minimum message representation needed to
/// make a decision.  It deliberately has no device, recipient, object-store
/// location, filename, or transport credential.
public struct V2ContentReviewInput: Sendable {
    public let messageID: MessageID
    public let roomID: RoomID
    public let contentRevision: UInt64
    public let text: String
    public let mediaCount: Int

    public init(messageID: MessageID, roomID: RoomID, contentRevision: UInt64, text: String, mediaCount: Int) {
        self.messageID = messageID
        self.roomID = roomID
        self.contentRevision = contentRevision
        self.text = text
        self.mediaCount = mediaCount
    }
}

/// Policy data is intentionally code-only.  Detailed provider output belongs
/// in an isolated evidence system, never in sync events or generic logs.
public struct V2ContentReviewFinding: Equatable, Sendable {
    public let category: String
    public let severity: Int
    public let confidence: Double

    public init(category: String, severity: Int, confidence: Double) throws {
        guard !category.isEmpty,
              category.utf8.count <= 64,
              category.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { throw V2ContentReviewWorkerError.invalidFindingCategory }
        guard (0...4).contains(severity) else { throw V2ContentReviewWorkerError.invalidFindingSeverity }
        guard confidence.isFinite, (0...1).contains(confidence) else {
            throw V2ContentReviewWorkerError.invalidFindingConfidence
        }
        self.category = category
        self.severity = severity
        self.confidence = confidence
    }
}

public enum V2ContentReviewVerdict: Equatable, Sendable {
    case clear
    case reviewRequired(V2ContentReviewFinding)
    case violation(V2ContentReviewFinding)
}

public protocol V2ContentReviewing: Sendable {
    func review(_ input: V2ContentReviewInput) async throws -> V2ContentReviewVerdict
}

/// Small deterministic deployment gate.  Production OCR/image/video or AI
/// providers implement `V2ContentReviewing`; this evaluator remains useful as
/// a cheap, auditable first lane and in local environments.
public struct V2ConfiguredContentReviewer: V2ContentReviewing {
    private let violatingTerms: [String]
    private let reviewTerms: [String]

    public init(violatingTerms: [String] = [], reviewTerms: [String] = []) {
        self.violatingTerms = violatingTerms.map(Self.normalize).filter { !$0.isEmpty }
        self.reviewTerms = reviewTerms.map(Self.normalize).filter { !$0.isEmpty }
    }

    public func review(_ input: V2ContentReviewInput) async throws -> V2ContentReviewVerdict {
        let text = Self.normalize(input.text)
        if violatingTerms.contains(where: text.contains) {
            return try .violation(.init(category: "configured_policy", severity: 4, confidence: 1))
        }
        if reviewTerms.contains(where: text.contains) {
            return try .reviewRequired(.init(category: "configured_policy", severity: 2, confidence: 1))
        }
        // Media is already blocked from reference until its malware scan is
        // available. Semantic media/OCR adapters can return a verdict later.
        return .clear
    }

    private static func normalize(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }
}

public struct V2ContentReviewLease: Sendable {
    public let input: V2ContentReviewInput
    public let claimToken: UUID
    public let attempt: Int
    public let stagedViolation: V2ContentReviewFinding?
    public init(
        input: V2ContentReviewInput,
        claimToken: UUID,
        attempt: Int = 1,
        stagedViolation: V2ContentReviewFinding? = nil
    ) {
        precondition(attempt > 0)
        self.input = input
        self.claimToken = claimToken
        self.attempt = attempt
        self.stagedViolation = stagedViolation
    }
}

public enum V2ContentReviewLeaseValidation: Equatable, Sendable {
    case current
    case superseded
    case lostLease
}

public protocol V2ContentReviewStore: Sendable {
    func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2ContentReviewLease]
    /// Atomically renews the same claim after a slow provider call. A newer
    /// edit/withdrawal is terminally superseded; another claim token is merely
    /// lost and must never alter the newer worker's job.
    func validateAndRenew(_ lease: V2ContentReviewLease, now: Date, leaseDuration: TimeInterval) async throws -> V2ContentReviewLeaseValidation
    /// Atomically closes the job only while this worker still owns the claim.
    /// Returns false after a concurrent reclaim instead of letting an older
    /// worker report a decision it did not persist.
    func resolve(_ lease: V2ContentReviewLease, verdict: V2ContentReviewVerdict, now: Date) async throws -> Bool
    /// Persists the bounded violation finding before the authoritative
    /// moderation side effect. This lets a reclaimed lease resume the same
    /// decision after a crash without asking a nondeterministic provider to
    /// recreate lost evidence.
    func stageViolation(_ lease: V2ContentReviewLease, finding: V2ContentReviewFinding) async throws -> Bool
    func scheduleRetry(_ lease: V2ContentReviewLease, disposition: V2DurableRetryDisposition, now: Date) async throws
}

public struct V2ContentReviewReport: Equatable, Sendable {
    public let claimedCount: Int
    public let resolvedCount: Int
    public let redactedCount: Int
    public let releasedCount: Int
}

/// A durable, lease-fenced worker.  A security redaction uses the stable
/// message ID as the moderation operation ID, so a crash after redaction but
/// before job completion retries idempotently rather than producing a second
/// event.  The fresh content-revision check prevents an old assessment from
/// acting on an edited message.
public struct V2ContentReviewWorker: Sendable {
    private let store: any V2ContentReviewStore
    private let reviewer: any V2ContentReviewing
    private let moderation: V2TrustedSafetyModerationService
    private let leaseDuration: TimeInterval
    private let retryPolicy: V2DurableRetryPolicy
    private let now: @Sendable () -> Date

    public init(store: any V2ContentReviewStore, reviewer: any V2ContentReviewing, moderation: V2TrustedSafetyModerationService, leaseDuration: TimeInterval = 30, retryPolicy: V2DurableRetryPolicy = .standard, now: @escaping @Sendable () -> Date = Date.init) throws {
        guard leaseDuration > 0 else { throw V2ContentReviewWorkerError.invalidLeaseDuration }
        self.store = store
        self.reviewer = reviewer
        self.moderation = moderation
        self.leaseDuration = leaseDuration
        self.retryPolicy = retryPolicy
        self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2ContentReviewReport {
        guard limit > 0 else { throw V2ContentReviewWorkerError.invalidLimit }
        let leases = try await store.claimPending(now: now(), leaseDuration: leaseDuration, limit: limit)
        var resolved = 0
        var redacted = 0
        var released = 0
        for lease in leases {
            do {
                let verdict: V2ContentReviewVerdict
                if let stagedViolation = lease.stagedViolation {
                    verdict = .violation(stagedViolation)
                } else {
                    verdict = try await reviewer.review(lease.input)
                }
                guard try await validate(lease) else {
                    resolved += 1
                    continue
                }
                var appliedRedaction = false
                if case .violation(let finding) = verdict {
                    if lease.stagedViolation == nil,
                       try await store.stageViolation(lease, finding: finding) == false {
                        resolved += 1
                        continue
                    }
                    let operationID = try ModerationOperationID(lease.input.messageID.rawValue)
                    let request = try V2TrustedSafetyModeration(
                        roomID: lease.input.roomID,
                        operationID: operationID,
                        action: .redactMessage,
                        messageID: lease.input.messageID,
                        expectedMessageRevision: lease.input.contentRevision,
                        reasonCode: .init("content_policy_violation")
                    )
                    let outcome = try await moderation.apply(request)
                    switch outcome {
                    case .applied, .idempotent:
                        // The authoritative transaction already fenced the
                        // exact reviewed revision. Its own tombstone must not
                        // make this job look like an unrelated superseding
                        // withdrawal on the validation below.
                        appliedRedaction = true
                    case .messageAlreadyRedacted:
                        // This opaque outcome also represents a revision
                        // conflict. Re-check the original revision so stale
                        // evidence never closes a newer edit's job.
                        guard try await validate(lease) else {
                            resolved += 1
                            continue
                        }
                    case .idempotencyConflict, .targetNotMember, .actionAlreadyInDesiredState, .rateLimited, .unavailable:
                        throw V2ContentReviewWorkerError.dispositionNotApplied
                    }
                }
                let didResolve = try await store.resolve(lease, verdict: verdict, now: now())
                if appliedRedaction, didResolve { redacted += 1 }
                resolved += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let failureTime = now()
                let disposition = retryPolicy.disposition(
                    attempt: lease.attempt,
                    claimToken: lease.claimToken,
                    now: failureTime
                )
                try? await store.scheduleRetry(lease, disposition: disposition, now: failureTime)
                released += 1
            }
        }
        return .init(claimedCount: leases.count, resolvedCount: resolved, redactedCount: redacted, releasedCount: released)
    }

    private func validate(_ lease: V2ContentReviewLease) async throws -> Bool {
        switch try await store.validateAndRenew(lease, now: now(), leaseDuration: leaseDuration) {
        case .current:
            true
        case .superseded, .lostLease:
            false
        }
    }
}

public enum V2ContentReviewWorkerError: Error, Equatable, Sendable {
    case invalidLeaseDuration
    case invalidLimit
    case invalidFindingCategory
    case invalidFindingSeverity
    case invalidFindingConfidence
    case dispositionNotApplied
}

/// PostgreSQL persistence for the transactional review outbox.  It stores
/// only code/severity/confidence; no text or provider response is retained in
/// this operational path.
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
        let token = makeUUID()
        let expiresAt = now.addingTimeInterval(leaseDuration)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let rows = try await sql.raw("""
                WITH candidates AS (
                    SELECT message_id
                    FROM im_v2.content_review_jobs
                    WHERE (state = 'pending' AND COALESCE(next_attempt_at, created_at) <= \(bind: now))
                       OR (state = 'claimed' AND lease_expires_at <= \(bind: now))
                    ORDER BY created_at, message_id
                    LIMIT \(bind: limit)
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE im_v2.content_review_jobs AS job
                SET state = 'claimed', claim_token = \(bind: token), lease_expires_at = \(bind: expiresAt),
                    next_attempt_at = NULL, paused_at = NULL, retry_count = job.retry_count + 1
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
        let messageID = try contentReviewUUID(lease.input.messageID)
        let roomID = try contentReviewRoomUUID(lease.input.roomID)
        let expected = try contentReviewSigned(lease.input.contentRevision)
        guard expected < Int64.max else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let enforcedRevision = expected + 1
        let renewedUntil = now.addingTimeInterval(leaseDuration)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let renewed = try await sql.raw("""
                UPDATE im_v2.content_review_jobs AS job
                SET lease_expires_at = \(bind: renewedUntil)
                FROM im_v2.messages AS message
                WHERE job.message_id = \(bind: messageID)
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
                  AND job.state = 'claimed' AND job.claim_token = \(bind: lease.claimToken)
                  AND message.message_id = job.message_id
                  AND (message.withdrawn_at IS NOT NULL OR message.content_revision <> \(bind: expected))
                RETURNING job.message_id
                """).first(decoding: ContentReviewMessageRow.self)
            return superseded == nil ? .lostLease : .superseded
        }
    }

    public func resolve(_ lease: V2ContentReviewLease, verdict: V2ContentReviewVerdict, now: Date) async throws -> Bool {
        let messageID = try contentReviewUUID(lease.input.messageID)
        let data = contentReviewData(verdict)
        return try await database.transaction { transaction in
            guard let tx = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let updated = try await tx.raw("""
                UPDATE im_v2.content_review_jobs
                SET state = \(bind: data.state), decision = \(bind: data.decision), completed_at = \(bind: now),
                    claim_token = NULL, lease_expires_at = NULL, next_attempt_at = NULL, paused_at = NULL,
                    finding_category = \(bind: data.category), finding_severity = \(bind: data.severity),
                    finding_confidence = \(bind: data.confidence)
                WHERE message_id = \(bind: messageID) AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
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
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return try await sql.raw("""
            UPDATE im_v2.content_review_jobs
            SET decision = 'violation', finding_category = \(bind: finding.category),
                finding_severity = \(bind: finding.severity), finding_confidence = \(bind: finding.confidence)
            WHERE message_id = \(bind: try contentReviewUUID(lease.input.messageID))
              AND expected_content_revision = \(bind: try contentReviewSigned(lease.input.contentRevision))
              AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
            RETURNING message_id
            """).first(decoding: ContentReviewMessageRow.self) != nil
    }

    public func scheduleRetry(_ lease: V2ContentReviewLease, disposition: V2DurableRetryDisposition, now: Date) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let messageID = try contentReviewUUID(lease.input.messageID)
        switch disposition {
        case .retry(let retryAt):
            try await sql.raw("""
                UPDATE im_v2.content_review_jobs
                SET state = 'pending', claim_token = NULL, lease_expires_at = NULL,
                    next_attempt_at = \(bind: retryAt), paused_at = NULL
                WHERE message_id = \(bind: messageID)
                  AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                """).run()
        case .pause:
            try await sql.raw("""
                UPDATE im_v2.content_review_jobs
                SET state = 'paused', claim_token = NULL, lease_expires_at = NULL,
                    next_attempt_at = NULL, paused_at = \(bind: now)
                WHERE message_id = \(bind: messageID)
                  AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                """).run()
        }
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
private func contentReviewSigned(_ value: UInt64) throws -> Int64 { guard value <= UInt64(Int64.max) else { throw V2RoomWriteStoreError.corruptPersistenceState }; return Int64(value) }
private func contentReviewUnsigned(_ value: Int64) -> UInt64 { UInt64(value) }
private func contentReviewData(_ verdict: V2ContentReviewVerdict) -> (state: String, decision: String, category: String?, severity: Int?, confidence: Double?) {
    switch verdict {
    case .clear: return ("completed", "clear", nil, nil, nil)
    case .reviewRequired(let finding): return ("completed", "review_required", finding.category, finding.severity, finding.confidence)
    case .violation(let finding): return ("completed", "violation", finding.category, finding.severity, finding.confidence)
    }
}
