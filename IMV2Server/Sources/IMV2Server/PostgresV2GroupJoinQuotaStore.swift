import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Control-plane ledger paired with durable per-attempt owner receipts;
/// a timeout, missing response, or expired worker lease is never release evidence.
struct PostgresV2GroupJoinQuotaStore: Sendable {
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

    /// Only a fresh user submission retries a definitively denied attempt.
    /// Recovery replays the stored generation, never calls reserve to renew it.
    func reserve(_ request: V2GroupJoinSubmissionPersistenceRequest, roomID: RoomID, inviteID: GroupInviteID,
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
            // At most two edges: a fresh duplicate may point at a denied
            // operation which later joins an already confirmed request. A
            // confirmed request never becomes denied or changes its binding.
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
                // Service retries generate fresh request IDs/times. They must not
                // rewrite the identity or restart an uncertain owner operation.
                if prior.phase != .denied { return .reserved(prior) }
            }
            if let active = try await sql.raw("""
                SELECT * FROM \(unsafeRaw: schema).group_join_quota_intents
                WHERE applicant_user_id = \(bind: applicant) AND invite_id = \(bind: invite)
                  AND phase IN ('held', 'tracking')
                """).first(decoding: V2GroupJoinQuotaIntent.self) {
                guard active.roomID == room, active.tokenDigest == request.tokenDigest else {
                    throw V2GroupInvitationServiceError.conflict
                }
                // Do not attach a previously denied operation to another
                // uncertain attempt: both could be denied and rebind in a cycle.
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
            if let prior {
                guard prior.generation < Int64.max else { throw V2GroupInvitationServiceError.conflict }
                try await sql.raw("""
                    UPDATE \(unsafeRaw: schema).group_join_quota_intents
                    SET phase = 'held', generation = generation + 1, outcome = NULL, target_request_id = NULL,
                        attempt_created_at = \(bind: now), updated_at = \(bind: now),
                        next_check_at = \(bind: now), lease_token = NULL, lease_until = NULL, attempt_count = 0
                    WHERE applicant_user_id = \(bind: applicant) AND operation_id = \(bind: canonical) AND phase = 'denied'
                    """).run()
            } else {
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).group_join_quota_intents
                        (applicant_user_id, operation_id, request_id, room_id, invite_id, token_digest, note,
                         maximum_pending_per_invite, generation, phase, created_at, attempt_created_at, updated_at, next_check_at)
                    VALUES (\(bind: applicant), \(bind: operation), \(bind: id), \(bind: room), \(bind: invite),
                            \(bind: request.tokenDigest), \(bind: request.note), \(bind: request.maximumPendingRequestsPerInvite),
                            1, 'held', \(bind: request.createdAt), \(bind: now), \(bind: now), \(bind: now)) ON CONFLICT DO NOTHING
                    """).run()
            }
            guard let result = try await lookup(applicant: applicant, operation: canonical, sql: sql) else {
                throw V2GroupInvitationServiceError.conflict
            }
            return .reserved(result)
        }
    }

    /// Apply only an authoritative owner receipt or a terminal observation bound
    /// to that receipt's request. Callers must not translate transport errors here.
    /// Stale generations and late nonterminal observations cannot free a new slot.
    @discardableResult
    func resolve(_ intent: V2GroupJoinQuotaIntent, outcome: V2GroupJoinQuotaOutcome,
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

    /// The ledger row is itself the durable recovery job, created atomically
    /// with the slot. Claims expire; reservations do not.
    func claim(limit: Int, now: Date, lease: TimeInterval = 30) async throws -> [V2GroupJoinQuotaIntent] {
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

    func deferClaim(_ intent: V2GroupJoinQuotaIntent, now: Date) async throws {
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
        // Caller holds the applicant lock and has already followed any alias.
        // An existing intent at this operation can only be definitively denied.
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

enum V2GroupJoinQuotaReservation: Equatable, Sendable {
    case reserved(V2GroupJoinQuotaIntent)
    case limited
}

enum V2GroupJoinQuotaPhase: String, Codable, Sendable {
    case held, tracking, denied, terminal
}

enum V2GroupJoinQuotaOutcome: String, Codable, Sendable {
    case pending, approving, approved, rejected, cancelled
    case alreadyMember = "already_member"
    case unavailable, rateLimited = "rate_limited", permissionDenied = "permission_denied"

    var phase: V2GroupJoinQuotaPhase {
        switch self {
        case .pending, .approving: .tracking
        case .approved, .rejected, .cancelled, .alreadyMember: .terminal
        case .unavailable, .rateLimited, .permissionDenied: .denied
        }
    }
    var requiresRequest: Bool {
        switch self {
        case .pending, .approving, .approved, .rejected, .cancelled: true
        case .alreadyMember, .unavailable, .rateLimited, .permissionDenied: false
        }
    }
}

struct V2GroupJoinQuotaIntent: Decodable, Equatable, Sendable {
    let applicantUserID, operationID, requestID, roomID, inviteID: UUID
    let tokenDigest: Data
    let note: String?
    let maximumPendingPerInvite: Int
    let generation: Int64
    let phase: V2GroupJoinQuotaPhase
    let outcome: V2GroupJoinQuotaOutcome?
    let targetRequestID: UUID?
    let createdAt, attemptCreatedAt, updatedAt, nextCheckAt: Date
    let leaseToken: UUID?
    let leaseUntil: Date?
    let attemptCount: Int64

    enum CodingKeys: String, CodingKey {
        case nextCheckAt = "next_check_at", leaseToken = "lease_token", leaseUntil = "lease_until", attemptCount = "attempt_count"
        case applicantUserID = "applicant_user_id", operationID = "operation_id", requestID = "request_id"
        case roomID = "room_id", inviteID = "invite_id", tokenDigest = "token_digest", note
        case maximumPendingPerInvite = "maximum_pending_per_invite", generation, phase, outcome
        case targetRequestID = "target_request_id", createdAt = "created_at", attemptCreatedAt = "attempt_created_at", updatedAt = "updated_at"
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
