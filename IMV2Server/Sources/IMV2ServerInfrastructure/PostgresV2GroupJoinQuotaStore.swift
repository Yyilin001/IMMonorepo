import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 控制侧台账与逐次尝试的持久化所有者回执配对；
/// 超时、响应缺失或工作器租约过期都不能作为释放额度的证据。
package struct PostgresV2GroupJoinQuotaStore: Sendable {
    let database: any Database
    let schema: String

    init(database: any Database) { self.database = database; self.schema = "im_v2" }

    init(database: any Database, schema: String) throws {
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw V2GroupInvitationServiceError.invalidRequest
        }
        self.database = database
        self.schema = schema
    }

    /// 只有用户发起的新提交才会重试已明确拒绝的尝试。
    /// 恢复流程重放已存代次，绝不调用 reserve 为其续期。
    package func releaseVerifiedDecision(_ receipt: V2GroupInvitationOperationReceipt, intent: V2GroupInvitationOperationIntent, now: Date) async throws {
        guard receipt.validates(intent:intent) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        let value: V2GroupInvitationOperationValue
        switch receipt.outcome { case .applied(let v),.alreadySatisfied(let v): value=v; default:return }
        let target:GroupJoinRequestID
        let outcome:String
        switch value {
        case .requestCancelled(let id):target=id;outcome="cancelled"
        case .requestDecided(let id,let decision,_):target=id;outcome=decision == .approve ? "approved":"rejected"
        default:return
        }
        let sql = try quotaSQL(database)
        try await sql.raw("UPDATE \(unsafeRaw: schema).group_join_quota_intents SET phase = 'terminal',outcome = \(bind: outcome),updated_at = \(bind: now),lease_token = NULL,lease_until = NULL WHERE room_id = \(bind: intent.roomID.uuidValue!) AND target_request_id = \(bind: target.uuidValue!) AND phase IN ('held','tracking')").run()
    }

    package func reserve(_ request: V2GroupJoinSubmissionPersistenceRequest, roomID: RoomID, inviteID: GroupInviteID,
                 now: Date) async throws -> V2GroupJoinQuotaReservation {
        guard let applicant = request.applicantUserID.uuidValue, let operation = request.operationID.uuidValue,
              let room = roomID.uuidValue, let invite = inviteID.uuidValue, let id = request.requestID.uuidValue,
              request.tokenDigest.count == 32, request.maximumPendingRequestsPerApplicant > 0,
              request.maximumPendingRequestsPerInvite > 0, request.note.map({ !$0.isEmpty && $0.utf8.count <= 500 }) ?? true,
              v2PostgresTimestampCanEncode(request.createdAt), v2PostgresTimestampCanEncode(now)
        else { throw V2GroupInvitationServiceError.invalidRequest }
        return try await database.transaction { transaction in
            let sql = try quotaSQL(transaction)
            try await lock(applicant, sql: sql)
            // 最多两条关联边：新的重复请求可能指向已拒绝的操作，
            // 而该操作随后关联到已确认的请求。已确认请求不会变为拒绝，
            // 也不会改变绑定。
            var canonical = operation
            var visited: Set<UUID> = [operation]
            while let alias = try await sql.raw("""
                SELECT * FROM \(unsafeRaw: schema).group_join_quota_aliases
                WHERE applicant_user_id = \(bind: applicant) AND operation_id = \(bind: canonical)
                """).first(decoding: QuotaAlias.self) {
                guard alias.roomID == room, alias.inviteID == invite, alias.tokenDigest == request.tokenDigest,
                      canonical != operation || alias.note == request.note else { throw V2GroupInvitationServiceError.conflict }
                guard visited.count < 3, visited.insert(alias.canonicalOperationID).inserted else {
                    throw V2GroupInvitationServiceError.corruptPersistenceState
                }
                canonical = alias.canonicalOperationID
            }
            let prior = try await lookup(applicant: applicant, operation: canonical, sql: sql)
            guard canonical == operation || prior != nil else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            if let prior {
                guard prior.roomID == room, prior.inviteID == invite, prior.tokenDigest == request.tokenDigest,
                      canonical != operation || prior.note == request.note else { throw V2GroupInvitationServiceError.conflict }
                // 服务重试会生成新的请求 ID 和时间，
                // 不能重写身份，也不能重启结果不明的所有者操作。
                // The immutable operation proof seals the original attempt. A denied
                // canonical identity can never mint a new quota generation or deadline.
                if prior.phase == .denied { return .limited }
                return .reserved(prior)
            }
            if let active = try await sql.raw("""
                SELECT * FROM \(unsafeRaw: schema).group_join_quota_intents
                WHERE applicant_user_id = \(bind: applicant) AND invite_id = \(bind: invite)
                  AND phase IN ('held', 'tracking')
                """).first(decoding: V2GroupJoinQuotaIntent.self) {
                guard active.roomID == room, active.tokenDigest == request.tokenDigest else {
                    throw V2GroupInvitationServiceError.conflict
                }
                // 不要把此前被拒绝的操作关联到另一项结果不明的尝试；
                // 两者都可能被拒绝并循环重新绑定。
                if prior != nil, active.phase == .held { return .limited }
                try await bindAlias(applicant: applicant, operation: canonical, target: active.operationID,
                    room: room, invite: invite, digest: request.tokenDigest,
                    note: prior != nil ? prior!.note : request.note, now: now, sql: sql)
                return .reserved(active)
            }
            if let terminal = try await sql.raw("""
                SELECT * FROM \(unsafeRaw: schema).group_join_quota_intents
                WHERE applicant_user_id = \(bind: applicant) AND invite_id = \(bind: invite)
                  AND phase = 'terminal' AND outcome IN ('approved', 'rejected')
                ORDER BY created_at DESC LIMIT 1
                """).first(decoding: V2GroupJoinQuotaIntent.self) {
                guard terminal.roomID == room, terminal.tokenDigest == request.tokenDigest else { throw V2GroupInvitationServiceError.conflict }
                try await bindAlias(applicant: applicant, operation: canonical, target: terminal.operationID,
                    room: room, invite: invite, digest: request.tokenDigest,
                    note: prior != nil ? prior!.note : request.note, now: now, sql: sql)
                return .reserved(terminal)
            }
            guard let count = try await sql.raw("""
                SELECT count(*) AS value FROM \(unsafeRaw: schema).group_join_quota_intents
                WHERE applicant_user_id = \(bind: applicant) AND phase IN ('held', 'tracking')
                """).first(decoding: QuotaCount.self) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            guard count.value < request.maximumPendingRequestsPerApplicant else { return .limited }
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).group_join_quota_intents
                        (applicant_user_id, operation_id, request_id, room_id, invite_id, token_digest, note,
                         maximum_pending_per_invite, generation, phase, created_at, attempt_created_at, updated_at, next_check_at)
                    VALUES (\(bind: applicant), \(bind: operation), \(bind: id), \(bind: room), \(bind: invite),
                            \(bind: request.tokenDigest), \(bind: request.note), \(bind: request.maximumPendingRequestsPerInvite),
                            1, 'held', \(bind: request.createdAt), \(bind: now), \(bind: now), \(bind: now)) ON CONFLICT DO NOTHING
                    """).run()
            guard let result = try await lookup(applicant: applicant, operation: canonical, sql: sql) else {
                throw V2GroupInvitationServiceError.conflict
            }
            return .reserved(result)
        }
    }

    /// 只应用权威所有者回执，或绑定到该回执请求的终态观测。
    /// 调用方不得在此转换传输错误。过期代次和迟到的非终态观测
    /// 不能释放新的槽位。
    @discardableResult
    package func resolve(_ intent: V2GroupJoinQuotaIntent, outcome: V2GroupJoinQuotaOutcome,
                 targetRequestID: UUID?, now: Date) async throws -> Bool {
        guard let nextCheck = v2PostgresFutureTimestamp(now: now, interval: 30), outcome.requiresRequest == (targetRequestID != nil) else {
            throw V2GroupInvitationServiceError.invalidRequest
        }
        return try await database.transaction { transaction in
            let sql = try quotaSQL(transaction)
            try await lock(intent.applicantUserID, sql: sql)
            guard let current = try await lookup(applicant: intent.applicantUserID, operation: intent.operationID, sql: sql),
                  current.requestID == intent.requestID, current.inviteID == intent.inviteID,
                  current.roomID == intent.roomID, current.tokenDigest == intent.tokenDigest, current.note == intent.note
            else { throw V2GroupInvitationServiceError.conflict }
            guard current.generation == intent.generation else { return false }
            if outcome == .rateLimited {
                // A deferred response retains its original uncertain reservation and
                // authorization clock. It cannot release a slot or resurrect a sealed ID.
                guard current.phase == .held else { return false }
                try await sql.raw("""
                    UPDATE \(unsafeRaw: schema).group_join_quota_intents
                    SET next_check_at = \(bind: nextCheck), lease_token = NULL, lease_until = NULL
                    WHERE applicant_user_id = \(bind: intent.applicantUserID) AND operation_id = \(bind: intent.operationID)
                      AND generation = \(bind: intent.generation) AND phase = 'held'
                    """).run()
                return true
            }
            if current.phase == .terminal || current.phase == .denied {
                return current.outcome == outcome && current.targetRequestID == targetRequestID
            }
            if current.phase == .tracking {
                guard current.targetRequestID == targetRequestID, outcome.phase != .denied else {
                    throw V2GroupInvitationServiceError.conflict
                }

            }
            try await sql.raw("""
                UPDATE \(unsafeRaw: schema).group_join_quota_intents
                SET phase = \(bind: outcome.phase.rawValue), outcome = \(bind: outcome.rawValue),
                    target_request_id = \(bind: targetRequestID), updated_at = \(bind: now),
                    next_check_at = \(bind: nextCheck), lease_token = NULL, lease_until = NULL, attempt_count = 0
                WHERE applicant_user_id = \(bind: intent.applicantUserID) AND operation_id = \(bind: intent.operationID)
                  AND generation = \(bind: intent.generation)
                """).run()
            return true
        }
    }

    /// 台账记录本身就是持久化恢复任务，与槽位原子创建。
    /// 认领会过期，预留不会。
    package func claim(limit: Int, now: Date, lease: TimeInterval = 30) async throws -> [V2GroupJoinQuotaIntent] {
        guard (1...100).contains(limit), let until = v2PostgresFutureTimestamp(now: now, interval: lease) else {
            throw V2GroupInvitationServiceError.invalidRequest
        }
        let sql = try quotaSQL(database), token = UUID()
        return try await sql.raw("""
            WITH candidates AS (
                SELECT applicant_user_id, operation_id FROM \(unsafeRaw: schema).group_join_quota_intents
                WHERE phase IN ('held', 'tracking') AND next_check_at <= \(bind: now)
                  AND (lease_token IS NULL OR lease_until <= \(bind: now))
                ORDER BY next_check_at, applicant_user_id, operation_id
                FOR UPDATE SKIP LOCKED LIMIT \(bind: limit)
            )
            UPDATE \(unsafeRaw: schema).group_join_quota_intents AS intent
            SET lease_token = \(bind: token), lease_until = \(bind: until),
                attempt_count = CASE WHEN intent.attempt_count < 9223372036854775807 THEN intent.attempt_count + 1 ELSE intent.attempt_count END
            FROM candidates
            WHERE intent.applicant_user_id = candidates.applicant_user_id AND intent.operation_id = candidates.operation_id
            RETURNING intent.*
            """).all(decoding: V2GroupJoinQuotaIntent.self)
    }

    package func deferClaim(_ intent: V2GroupJoinQuotaIntent, now: Date) async throws {
        guard let token = intent.leaseToken,
              let next = v2PostgresFutureTimestamp(now: now, interval: min(60, Double(min(intent.attemptCount, 6)) * 10))
        else { throw V2GroupInvitationServiceError.invalidRequest }
        let sql = try quotaSQL(database)
        try await sql.raw("""
            UPDATE \(unsafeRaw: schema).group_join_quota_intents
            SET lease_token = NULL, lease_until = NULL, next_check_at = \(bind: next)
            WHERE applicant_user_id = \(bind: intent.applicantUserID) AND operation_id = \(bind: intent.operationID)
              AND generation = \(bind: intent.generation) AND lease_token = \(bind: token)
              AND phase IN ('held', 'tracking')
            """).run()
    }

    func releaseTerminal(_ request: V2GroupJoinRequestRecord, now: Date) async throws {
        guard let outcome = V2GroupJoinQuotaOutcome(rawValue: request.state.rawValue), outcome.phase == .terminal,
              let applicant = request.applicant.userID.uuidValue, let room = request.roomID.uuidValue,
              let target = request.requestID.uuidValue else { throw V2GroupInvitationServiceError.invalidRequest }
        let sql = try quotaSQL(database)
        let intents = try await sql.raw("""
            SELECT * FROM \(unsafeRaw: schema).group_join_quota_intents
            WHERE applicant_user_id = \(bind: applicant) AND room_id = \(bind: room)
              AND phase IN ('held', 'tracking') AND (request_id = \(bind: target) OR target_request_id = \(bind: target))
            """).all(decoding: V2GroupJoinQuotaIntent.self)
        for intent in intents {
            guard intent.inviteID == request.inviteID.uuidValue else { throw V2GroupInvitationServiceError.conflict }
            try await resolve(intent, outcome: outcome, targetRequestID: target, now: now)
        }
    }

    private func bindAlias(applicant: UUID, operation: UUID, target: UUID,
                           room: UUID, invite: UUID, digest: Data, note: String?,
                           now: Date, sql: any SQLDatabase) async throws {
        guard operation != target else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        // 调用方持有申请人锁，且已追踪所有别名。
        // 此操作已有的意图只能是已明确拒绝的状态。
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).group_join_quota_aliases
                (applicant_user_id, operation_id, canonical_operation_id, room_id, invite_id, token_digest, note, created_at)
            VALUES (\(bind: applicant), \(bind: operation), \(bind: target), \(bind: room), \(bind: invite),
                    \(bind: digest), \(bind: note), \(bind: now))
            """).run()
    }

    private func lock(_ applicant: UUID, sql: any SQLDatabase) async throws {
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "group-join-global:" + applicant.uuidString), 0))").run()
    }

    private func lookup(applicant: UUID, operation: UUID, sql: any SQLDatabase) async throws -> V2GroupJoinQuotaIntent? {
        try await sql.raw("""
            SELECT * FROM \(unsafeRaw: schema).group_join_quota_intents
            WHERE applicant_user_id = \(bind: applicant) AND operation_id = \(bind: operation) FOR UPDATE
            """).first(decoding: V2GroupJoinQuotaIntent.self)
    }
}

private struct QuotaCount: Decodable { let value: Int64 }
private func quotaSQL(_ database: any Database) throws -> any SQLDatabase {
    guard let sql = database as? any SQLDatabase else { throw V2GroupInvitationServiceError.corruptPersistenceState }
    return sql
}

private struct QuotaAlias: Decodable {
    let canonicalOperationID, roomID, inviteID: UUID
    let tokenDigest: Data
    let note: String?
    enum CodingKeys: String, CodingKey {
        case canonicalOperationID = "canonical_operation_id", roomID = "room_id", inviteID = "invite_id"
        case tokenDigest = "token_digest", note
    }
}
