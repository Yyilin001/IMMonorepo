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
public enum V2ContentReviewVerdict: Equatable, Sendable {
    case clear
    case reviewRequired(category: String, severity: Int, confidence: Double)
    case violation(category: String, severity: Int, confidence: Double)
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
            return .violation(category: "configured_policy", severity: 4, confidence: 1)
        }
        if reviewTerms.contains(where: text.contains) {
            return .reviewRequired(category: "configured_policy", severity: 2, confidence: 1)
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
    public init(input: V2ContentReviewInput, claimToken: UUID) {
        self.input = input
        self.claimToken = claimToken
    }
}

public protocol V2ContentReviewStore: Sendable {
    func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2ContentReviewLease]
    /// A false result means a newer edit, withdrawal, or lost lease made the
    /// assessment obsolete.  The store records it as superseded.
    func isCurrent(_ lease: V2ContentReviewLease, now: Date) async throws -> Bool
    func resolve(_ lease: V2ContentReviewLease, verdict: V2ContentReviewVerdict, now: Date) async throws
    func release(_ lease: V2ContentReviewLease) async throws
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
    private let now: @Sendable () -> Date

    public init(store: any V2ContentReviewStore, reviewer: any V2ContentReviewing, moderation: V2TrustedSafetyModerationService, leaseDuration: TimeInterval = 30, now: @escaping @Sendable () -> Date = Date.init) throws {
        guard leaseDuration > 0 else { throw V2ContentReviewWorkerError.invalidLeaseDuration }
        self.store = store
        self.reviewer = reviewer
        self.moderation = moderation
        self.leaseDuration = leaseDuration
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
                let verdict = try await reviewer.review(lease.input)
                guard try await store.isCurrent(lease, now: now()) else {
                    resolved += 1
                    continue
                }
                if case .violation = verdict {
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
                        redacted += 1
                    case .messageAlreadyRedacted:
                        // A concurrent edit rewrites the review job with a
                        // new revision. Re-check before resolving so that old
                        // evidence cannot close the new job.
                        guard try await store.isCurrent(lease, now: now()) else {
                            resolved += 1
                            continue
                        }
                        redacted += 1
                    case .idempotencyConflict, .targetNotMember, .actionAlreadyInDesiredState, .rateLimited, .unavailable:
                        throw V2ContentReviewWorkerError.dispositionNotApplied
                    }
                }
                try await store.resolve(lease, verdict: verdict, now: now())
                resolved += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? await store.release(lease)
                released += 1
            }
        }
        return .init(claimedCount: leases.count, resolvedCount: resolved, redactedCount: redacted, releasedCount: released)
    }
}

public enum V2ContentReviewWorkerError: Error, Equatable, Sendable {
    case invalidLeaseDuration
    case invalidLimit
    case dispositionNotApplied
}

/// PostgreSQL persistence for the transactional review outbox.  It stores
/// only code/severity/confidence; no text or provider response is retained in
/// this operational path.
public struct PostgresV2ContentReviewStore: V2ContentReviewStore {
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
                    WHERE state = 'pending' OR (state = 'claimed' AND lease_expires_at <= \(bind: now))
                    ORDER BY created_at, message_id
                    LIMIT \(bind: limit)
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE im_v2.content_review_jobs AS job
                SET state = 'claimed', claim_token = \(bind: token), lease_expires_at = \(bind: expiresAt), retry_count = job.retry_count + 1
                FROM candidates
                WHERE job.message_id = candidates.message_id
                RETURNING job.message_id, job.room_id, job.expected_content_revision,
                          (SELECT text_body FROM im_v2.messages WHERE message_id = job.message_id) AS text_body,
                          (SELECT COUNT(*) FROM im_v2.message_media_references WHERE message_id = job.message_id AND revoked_at IS NULL) AS media_count
                """).all(decoding: ContentReviewClaimRow.self)
            return try rows.map { row in
                try .init(
                    input: .init(messageID: .init(row.messageID.uuidString), roomID: .init(row.roomID.uuidString), contentRevision: contentReviewUnsigned(row.contentRevision), text: row.text, mediaCount: row.mediaCount),
                    claimToken: token
                )
            }
        }
    }

    public func isCurrent(_ lease: V2ContentReviewLease, now: Date) async throws -> Bool {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let messageID = try contentReviewUUID(lease.input.messageID)
        let expected = try contentReviewSigned(lease.input.contentRevision)
        let row = try await sql.raw("""
            SELECT message.content_revision, message.withdrawn_at
            FROM im_v2.content_review_jobs AS job
            INNER JOIN im_v2.messages AS message ON message.message_id = job.message_id
            WHERE job.message_id = \(bind: messageID) AND job.state = 'claimed'
              AND job.claim_token = \(bind: lease.claimToken) AND job.lease_expires_at > \(bind: now)
            """).first(decoding: ContentReviewCurrentRow.self)
        guard let row, row.withdrawnAt == nil, row.contentRevision == expected else {
            try await sql.raw("""
                UPDATE im_v2.content_review_jobs
                SET state = 'superseded', completed_at = \(bind: now), claim_token = NULL, lease_expires_at = NULL
                WHERE message_id = \(bind: messageID) AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                """).run()
            return false
        }
        return true
    }

    public func resolve(_ lease: V2ContentReviewLease, verdict: V2ContentReviewVerdict, now: Date) async throws {
        let messageID = try contentReviewUUID(lease.input.messageID)
        let data = try contentReviewData(verdict)
        try await database.transaction { transaction in
            guard let tx = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let updated = try await tx.raw("""
                UPDATE im_v2.content_review_jobs
                SET state = \(bind: data.state), decision = \(bind: data.decision), completed_at = \(bind: now),
                    claim_token = NULL, lease_expires_at = NULL
                WHERE message_id = \(bind: messageID) AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                RETURNING message_id
                """).first(decoding: ContentReviewMessageRow.self)
            guard updated != nil else { return }
            try await tx.raw("""
                INSERT INTO im_v2.content_review_decisions (message_id, decision, policy_version, decided_at)
                VALUES (\(bind: messageID), \(bind: data.decision), 'v1', \(bind: now))
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
        }
    }

    public func release(_ lease: V2ContentReviewLease) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            UPDATE im_v2.content_review_jobs SET state = 'pending', claim_token = NULL, lease_expires_at = NULL
            WHERE message_id = \(bind: try contentReviewUUID(lease.input.messageID))
              AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
            """).run()
    }
}

private struct ContentReviewClaimRow: Decodable {
    let messageID: UUID; let roomID: UUID; let contentRevision: Int64; let text: String; let mediaCount: Int
    enum CodingKeys: String, CodingKey { case messageID = "message_id", roomID = "room_id", contentRevision = "expected_content_revision", text = "text_body", mediaCount = "media_count" }
}
private struct ContentReviewCurrentRow: Decodable { let contentRevision: Int64; let withdrawnAt: Date?; enum CodingKeys: String, CodingKey { case contentRevision = "content_revision", withdrawnAt = "withdrawn_at" } }
private struct ContentReviewMessageRow: Decodable { let messageID: UUID; enum CodingKeys: String, CodingKey { case messageID = "message_id" } }
private func contentReviewUUID(_ id: MessageID) throws -> UUID { guard let value = UUID(uuidString: id.rawValue) else { throw V2RoomWriteStoreError.corruptPersistenceState }; return value }
private func contentReviewSigned(_ value: UInt64) throws -> Int64 { guard value <= UInt64(Int64.max) else { throw V2RoomWriteStoreError.corruptPersistenceState }; return Int64(value) }
private func contentReviewUnsigned(_ value: Int64) -> UInt64 { UInt64(value) }
private func contentReviewData(_ verdict: V2ContentReviewVerdict) throws -> (state: String, decision: String, category: String?, severity: Int?, confidence: Double?) {
    switch verdict {
    case .clear: return ("completed", "clear", nil, nil, nil)
    case .reviewRequired(let category, let severity, let confidence): return ("completed", "review_required", try contentReviewCategory(category), severity, confidence)
    case .violation(let category, let severity, let confidence): return ("completed", "violation", try contentReviewCategory(category), severity, confidence)
    }
}
private func contentReviewCategory(_ value: String) throws -> String {
    guard !value.isEmpty, value.utf8.count <= 64, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}
