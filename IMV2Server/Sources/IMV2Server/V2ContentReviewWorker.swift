import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 内容审核边界接收做出判定所需的最小消息表示。
///
/// 它刻意不含设备、接收者、对象存储位置、文件名或传输凭据。
public struct V2ContentReviewInput: Sendable {
    /// 目标消息。
    public let messageID: MessageID
    /// 目标房间。
    public let roomID: RoomID
    /// 消息内容修订。
    public let contentRevision: UInt64
    /// 消息正文。
    public let text: String
    /// 附件数量。
    public let mediaCount: Int

    /// 保存审核输入。
    ///
    /// - Parameters:
    ///   - messageID: 目标消息。
    ///   - roomID: 目标房间。
    ///   - contentRevision: 内容修订。
    ///   - text: 消息正文。
    ///   - mediaCount: 附件数量。
    public init(messageID: MessageID, roomID: RoomID, contentRevision: UInt64, text: String, mediaCount: Int) {
        self.messageID = messageID
        self.roomID = roomID
        self.contentRevision = contentRevision
        self.text = text
        self.mediaCount = mediaCount
    }
}

/// 违规发现。
///
/// 策略数据刻意只存在于代码中；提供方的详细输出应保存在独立的证据系统，
/// 绝不能进入同步事件或通用日志。
public struct V2ContentReviewFinding: Equatable, Sendable {
    /// 违规类别。
    public let category: String
    /// 严重程度。
    public let severity: Int
    /// 置信度。
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

/// 内容审核结论。
public enum V2ContentReviewVerdict: Equatable, Sendable {
    /// 无需处理。
    case clear
    /// 需要人工复核，附带发现内容。
    case reviewRequired(V2ContentReviewFinding)
    /// 判定违规，附带发现内容。
    case violation(V2ContentReviewFinding)
}

/// 内容审核能力。
public protocol V2ContentReviewing: Sendable {
    /// 审核一条消息。
    ///
    /// - Parameter input: 审核输入。
    /// - Returns: 审核结论。
    /// - Throws: 提供方失败时抛出。
    func review(_ input: V2ContentReviewInput) async throws -> V2ContentReviewVerdict
}

/// 小型确定性部署闸门。
///
/// 生产环境的 OCR、图像、视频或 AI 提供方实现 ``V2ContentReviewing``；
/// 该评估器仍可作为廉价且可审计的第一道处理，并适用于本地环境。
public struct V2ConfiguredContentReviewer: V2ContentReviewing {
    private let violatingTerms: [String]
    private let reviewTerms: [String]

    /// 以违规词与待复核词列表构造评估器。
    ///
    /// - Parameters:
    ///   - violatingTerms: 判定违规的词列表。
    ///   - reviewTerms: 需要人工复核的词列表。
    public init(violatingTerms: [String] = [], reviewTerms: [String] = []) {
        self.violatingTerms = violatingTerms.map(Self.normalize).filter { !$0.isEmpty }
        self.reviewTerms = reviewTerms.map(Self.normalize).filter { !$0.isEmpty }
    }

    /// 按配置词表审核消息正文。
    ///
    /// - Parameter input: 审核输入。
    /// - Returns: 命中违规词时判定违规，命中待复核词时要求人工复核，否则判定无需处理。
    /// - Throws: 评估过程失败时抛出。
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

/// 内容审核的持久化能力。
public protocol V2ContentReviewStore: Sendable {
    /// 认领一批待审核任务。
    ///
    /// - Parameters:
    ///   - now: 本次认领时刻。
    ///   - leaseDuration: 租约时长秒数。
    ///   - limit: 本次最多认领的数量。
    /// - Returns: 认领到的审核租约。
    /// - Throws: 持久化失败时抛出。
    func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2ContentReviewLease]

    /// 在缓慢的提供方调用之后原子地续期同一份认领。
    ///
    /// 更新后的编辑或撤回会把该任务判定为被取代；若认领令牌已被他人夺走，则视为丢失认领，
    /// 且绝不能改动新工作器的任务。
    ///
    /// - Parameters:
    ///   - lease: 本次审核租约。
    ///   - now: 本次校验时刻。
    ///   - leaseDuration: 新的租约时长秒数。
    /// - Returns: 校验结论。
    /// - Throws: 持久化失败时抛出。
    func validateAndRenew(_ lease: V2ContentReviewLease, now: Date, leaseDuration: TimeInterval) async throws -> V2ContentReviewLeaseValidation

    /// 仅在该工作器仍持有认领时原子地关闭任务。
    ///
    /// 若期间已被并发重新认领则返回 `false`，避免旧工作器报告一个并非由它持久化的决定。
    ///
    /// - Parameters:
    ///   - lease: 本次审核租约。
    ///   - verdict: 审核结论。
    ///   - now: 完成时刻。
    /// - Returns: 关闭生效时为 `true`。
    /// - Throws: 持久化失败时抛出。
    func resolve(_ lease: V2ContentReviewLease, verdict: V2ContentReviewVerdict, now: Date) async throws -> Bool

    /// 在权威审核副作用之前先持久化有界的违规发现。
    ///
    /// 这样在崩溃后被重新认领的租约可以继续同一决定，
    /// 无需让非确定性提供方重新生成已经丢失的证据。
    ///
    /// - Parameters:
    ///   - lease: 本次审核租约。
    ///   - finding: 违规发现。
    /// - Returns: 记录生效时为 `true`。
    /// - Throws: 持久化失败时抛出。
    func stageViolation(_ lease: V2ContentReviewLease, finding: V2ContentReviewFinding) async throws -> Bool

    /// 按处置结果安排重试或暂停。
    ///
    /// - Parameters:
    ///   - lease: 本次审核租约。
    ///   - disposition: 下一步处置。
    ///   - now: 记录时刻。
    /// - Throws: 持久化失败时抛出。
    func scheduleRetry(_ lease: V2ContentReviewLease, disposition: V2DurableRetryDisposition, now: Date) async throws
}

/// 单轮内容审核统计。
public struct V2ContentReviewReport: Equatable, Sendable {
    /// 本轮认领数量。
    public let claimedCount: Int
    /// 已给出结论的数量。
    public let resolvedCount: Int
    /// 已执行屏蔽的数量。
    public let redactedCount: Int
    /// 安排重试的数量。
    public let releasedCount: Int
}

/// 持久化且带租约栅栏的审核工作器。
///
/// 安全屏蔽使用稳定的消息标识作为审核操作标识，因此「已完成屏蔽但尚未完成任务」时的崩溃
/// 会幂等重试，而不会产生第二条事件。最新内容修订校验则阻止旧评估作用于已被编辑的消息。
public struct V2ContentReviewWorker: Sendable {
    private let store: any V2ContentReviewStore
    private let reviewer: any V2ContentReviewing
    private let moderation: V2TrustedSafetyModerationService
    private let leaseDuration: TimeInterval
    private let retryPolicy: V2DurableRetryPolicy
    private let now: @Sendable () -> Date

    public init(store: any V2ContentReviewStore, reviewer: any V2ContentReviewing, moderation: V2TrustedSafetyModerationService, leaseDuration: TimeInterval = 30, retryPolicy: V2DurableRetryPolicy = .standard, now: @escaping @Sendable () -> Date = Date.init) throws {
        guard leaseDuration.isFinite, leaseDuration > 0 else { throw V2ContentReviewWorkerError.invalidLeaseDuration }
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
        var retryFailure: (any Error)?
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
                    now: failureTime,
                    kind: v2DurableWorkFailureKind(for: error)
                )
                do {
                    if case .retry(let retryAt) = disposition, !v2PostgresTimestampPrecedes(failureTime, retryAt) {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    try await store.scheduleRetry(lease, disposition: disposition, now: failureTime)
                    released += 1
                } catch {
                    // Continue the bounded batch, but do not report a failed
                    // persistence operation as a successfully released lease.
                    retryFailure = retryFailure ?? error
                }
            }
        }
        if let retryFailure { throw retryFailure }
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
                           WHERE room.room_id = job.room_id AND room.migration_fence_id IS NULL
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
        let expected = try contentReviewSigned(lease.input.contentRevision)
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
              AND expected_content_revision = \(bind: try contentReviewSigned(lease.input.contentRevision))
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

    /// Keep the source room stable through task and derived-result writes.
    /// This is a database fence, not cancellation of an in-flight reviewer.
    private func lockReviewRoom(_ lease: V2ContentReviewLease, sql: any SQLDatabase) async throws {
        guard try await sql.raw("""
            SELECT room_id FROM im_v2.rooms
            WHERE room_id = \(bind: try contentReviewRoomUUID(lease.input.roomID))
              AND migration_fence_id IS NULL
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
private func contentReviewSigned(_ value: UInt64) throws -> Int64 { guard value <= UInt64(Int64.max) else { throw V2RoomWriteStoreError.corruptPersistenceState }; return Int64(value) }
private func contentReviewUnsigned(_ value: Int64) -> UInt64 { UInt64(value) }
private func contentReviewData(_ verdict: V2ContentReviewVerdict) -> (state: String, decision: String, category: String?, severity: Int?, confidence: Double?) {
    switch verdict {
    case .clear: return ("completed", "clear", nil, nil, nil)
    case .reviewRequired(let finding): return ("completed", "review_required", finding.category, finding.severity, finding.confidence)
    case .violation(let finding): return ("completed", "violation", finding.category, finding.severity, finding.confidence)
    }
}
