import Fluent
import Foundation
import SQLKit

public struct PostgresV2GroupApprovalRecoveryStore: V2GroupApprovalRecoveryStore {
    private let database: any Database
    public init(database: any Database) { self.database = database }

    public func candidates(scope: V2GroupApprovalRecoveryScope, after: UUID?, limit: Int) async throws -> V2GroupApprovalRecoveryPage {
        guard (1...100).contains(limit) else { throw V2GroupApprovalRecoveryError.invalidRequest }
        return try await database.transaction { database in
            let sql = try recoverySQL(database)
            _ = try await assertOwner(scope, sql: sql)
            let rows = try await sql.raw("""
                SELECT request_id, decided_by_user_id, decision_operation_id, applicant_user_id, approval_membership_revision
                FROM im_v2.group_join_requests
                WHERE room_id = \(bind: scope.roomID) AND state = 'approving'
                  AND (\(bind: after)::uuid IS NULL OR request_id > \(bind: after)::uuid)
                ORDER BY request_id LIMIT \(bind: limit + 1)
                """).all(decoding: ApprovalRecoveryCandidateRow.self)
            let page = Array(rows.prefix(limit)).map(\.candidate)
            return .init(candidates: page, nextCursor: rows.count > limit ? page.last?.requestID : nil)
        }
    }

    public func recover(_ command: V2GroupApprovalRecoveryCommand, operatorPrincipal: String, now: Date) async throws -> V2GroupApprovalRecoveryResult {
        guard V2DurableWorkOperatorReplayService.isValidPrincipal(operatorPrincipal) else { throw V2GroupApprovalRecoveryError.invalidRequest }
        return try await database.transaction { database in
            let sql = try recoverySQL(database)
            try await lock("group-approval-recovery:" + command.operationID.uuidString, sql: sql)
            if let prior = try await sql.raw("SELECT * FROM im_v2.group_join_approval_recovery_audit WHERE operation_id = \(bind: command.operationID)").first(decoding: ApprovalRecoveryAuditRow.self) {
                guard prior.matches(command, principal: operatorPrincipal) else { throw V2GroupApprovalRecoveryError.idempotencyConflict }
                return .init(operationID: command.operationID, outcome: prior.outcome, detail: prior.detail, wasIdempotent: true)
            }
            try await lock(command.reviewerUserID.uuidString + ":" + command.decisionOperationID.uuidString, sql: sql)
            let revision = try await assertOwner(command.scope, sql: sql)
            guard let request = try await sql.raw("""
                SELECT invite_id, applicant_user_id, state, decided_by_user_id,
                       decision_operation_id, approval_membership_revision
                FROM im_v2.group_join_requests
                WHERE request_id = \(bind: command.requestID) AND room_id = \(bind: command.scope.roomID) FOR UPDATE
                """).first(decoding: ApprovalRecoveryRequestRow.self) else { throw V2GroupApprovalRecoveryError.requestNotFound }
            guard v2PostgresTimestampCanEncode(now) else { throw V2GroupApprovalRecoveryError.corruptPersistenceState }
            if request.state != "approving" {
                return try await record(command, principal: operatorPrincipal, outcome: .notApproving, detail: .notApproving, request: request, member: nil, now: now, sql: sql)
            }
            guard request.reviewerUserID == command.reviewerUserID, request.decisionOperationID == command.decisionOperationID else { throw V2GroupApprovalRecoveryError.decisionChanged }
            guard let prepared = request.preparedRevision, prepared >= 0, prepared <= revision else {
                return try await record(command, principal: operatorPrincipal, outcome: .quarantined, detail: .invalidRevision, request: request, member: nil, now: now, sql: sql)
            }
            // Row locking also serializes against an already running old
            // housekeeping pass. New housekeeping retains referenced receipts.
            let member = try await sql.raw("""
                SELECT room_id, target_user_id, action, expected_membership_revision,
                       resulting_membership_revision, room_sequence, event_id, plan_id, created_at
                FROM im_v2.room_membership_operations
                WHERE actor_user_id = \(bind: command.reviewerUserID) AND operation_id = \(bind: command.decisionOperationID) FOR UPDATE
                """).first(decoding: ApprovalRecoveryMemberRow.self)
            if let member {
                guard member.roomID == command.scope.roomID, member.targetUserID == request.applicantUserID,
                      member.action == "add", member.expectedRevision >= prepared,
                      member.expectedRevision < Int64.max, member.resultingRevision == member.expectedRevision + 1,
                      member.resultingRevision <= revision, member.roomSequence > 0
                else {
                    return try await record(command, principal: operatorPrincipal, outcome: .quarantined, detail: .operationMismatch, request: request, member: member, now: now, sql: sql)
                }
                guard let invite = try await sql.raw("SELECT approved_use_count, maximum_approved_uses FROM im_v2.group_invite_links WHERE invite_id = \(bind: request.inviteID) FOR UPDATE").first(decoding: ApprovalRecoveryInviteRow.self), invite.used < invite.maximum else {
                    return try await record(command, principal: operatorPrincipal, outcome: .quarantined, detail: .inviteExhausted, request: request, member: member, now: now, sql: sql)
                }
                guard v2PostgresTimestampCanEncode(member.createdAt) else { throw V2GroupApprovalRecoveryError.corruptPersistenceState }
                try await sql.raw("UPDATE im_v2.group_invite_links SET approved_use_count = approved_use_count + 1 WHERE invite_id = \(bind: request.inviteID)").run()
                try await sql.raw("""
                    UPDATE im_v2.group_join_requests SET state = 'approved',
                        approval_membership_revision = \(bind: member.expectedRevision),
                        decided_at = \(bind: member.createdAt), updated_at = \(bind: now)
                    WHERE request_id = \(bind: command.requestID)
                    """).run()
                return try await record(command, principal: operatorPrincipal, outcome: .completed, detail: .committedOperation, request: request, member: member, now: now, sql: sql)
            }
            // Historical intervals are authoritative and are not pruned by
            // current production lifecycle code. Every possible legacy add
            // would insert joined_revision > prepared. A current-member test
            // cannot make this proof: a later departure keeps its interval.
            // Any future history GC must provide a coverage floor before this
            // absence proof can remain enabled.
            let hasHistoricalAdd = try await sql.raw("""
                SELECT EXISTS (SELECT 1 FROM im_v2.room_memberships
                    WHERE room_id = \(bind: command.scope.roomID) AND user_id = \(bind: request.applicantUserID)
                      AND joined_revision > \(bind: prepared)) AS value
                """).first(decoding: ApprovalRecoveryBool.self)?.value
            guard hasHistoricalAdd == false else {
                return try await record(command, principal: operatorPrincipal, outcome: .quarantined, detail: .historicalAddWithoutReceipt, request: request, member: nil, now: now, sql: sql)
            }
            let result = try await record(command, principal: operatorPrincipal, outcome: .released, detail: .noHistoricalAdd, request: request, member: nil, now: now, sql: sql)
            try await sql.raw("""
                INSERT INTO im_v2.room_membership_operation_fences
                    (actor_user_id, operation_id, room_id, request_id, recovery_operation_id, created_at)
                VALUES (\(bind: command.reviewerUserID), \(bind: command.decisionOperationID), \(bind: command.scope.roomID),
                        \(bind: command.requestID), \(bind: command.operationID), \(bind: now))
                """).run()
            try await sql.raw("""
                UPDATE im_v2.group_join_requests SET state = 'pending', decision_operation_id = NULL,
                    decided_by_user_id = NULL, approval_membership_revision = NULL, updated_at = \(bind: now)
                WHERE request_id = \(bind: command.requestID)
                """).run()
            return result
        }
    }

    private func assertOwner(_ scope: V2GroupApprovalRecoveryScope, sql: any SQLDatabase) async throws -> Int64 {
        guard let room = try await sql.raw("SELECT room_shard_id, owner_epoch, membership_revision FROM im_v2.rooms WHERE room_id = \(bind: scope.roomID) FOR UPDATE").first(decoding: ApprovalRecoveryRoomRow.self),
              room.shardID == scope.shardID, room.epoch == scope.ownerEpoch else { throw V2GroupApprovalRecoveryError.ownerChanged }
        return room.revision
    }
    private func lock(_ key: String, sql: any SQLDatabase) async throws {
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
    }
    private func record(_ command: V2GroupApprovalRecoveryCommand, principal: String,
                        outcome: V2GroupApprovalRecoveryOutcome, detail: V2GroupApprovalRecoveryDetail,
                        request: ApprovalRecoveryRequestRow, member: ApprovalRecoveryMemberRow?, now: Date, sql: any SQLDatabase) async throws -> V2GroupApprovalRecoveryResult {
        try await sql.raw("""
            INSERT INTO im_v2.group_join_approval_recovery_audit
                (operation_id, operator_principal, shard_id, owner_epoch, room_id, request_id,
                 reviewer_user_id, decision_operation_id, reason_code, outcome, detail, requested_at,
                 applicant_user_id, prepared_revision, member_room_id, member_target_user_id, member_action,
                 expected_revision, resulting_revision, room_sequence, event_id, plan_id)
            VALUES (\(bind: command.operationID), \(bind: principal), \(bind: command.scope.shardID),
                    \(bind: command.scope.ownerEpoch), \(bind: command.scope.roomID), \(bind: command.requestID),
                    \(bind: command.reviewerUserID), \(bind: command.decisionOperationID), \(bind: command.reason.rawValue),
                    \(bind: outcome.rawValue), \(bind: detail.rawValue), \(bind: now),
                    \(bind: request.applicantUserID), \(bind: request.preparedRevision),
                    \(bind: member?.roomID), \(bind: member?.targetUserID), \(bind: member?.action),
                    \(bind: member?.expectedRevision), \(bind: member?.resultingRevision), \(bind: member?.roomSequence),
                    \(bind: member?.eventID), \(bind: member?.planID))
            """).run()
        return .init(operationID: command.operationID, outcome: outcome, detail: detail, wasIdempotent: false)
    }
}

private func recoverySQL(_ database: any Database) throws -> any SQLDatabase {
    guard let sql = database as? any SQLDatabase else { throw V2GroupApprovalRecoveryError.corruptPersistenceState }; return sql
}
private struct ApprovalRecoveryBool: Decodable { let value: Bool }
private struct ApprovalRecoveryRoomRow: Decodable {
    let shardID: String; let epoch: Int64; let revision: Int64
    enum CodingKeys: String, CodingKey { case shardID = "room_shard_id", epoch = "owner_epoch", revision = "membership_revision" }
}
private struct ApprovalRecoveryRequestRow: Decodable {
    let inviteID: UUID; let applicantUserID: UUID; let state: String
    let reviewerUserID: UUID?; let decisionOperationID: UUID?; let preparedRevision: Int64?
    enum CodingKeys: String, CodingKey { case inviteID = "invite_id", applicantUserID = "applicant_user_id", state, reviewerUserID = "decided_by_user_id", decisionOperationID = "decision_operation_id", preparedRevision = "approval_membership_revision" }
}
private struct ApprovalRecoveryCandidateRow: Decodable {
    let requestID: UUID; let reviewerUserID: UUID; let decisionOperationID: UUID; let applicantUserID: UUID; let preparedRevision: Int64
    enum CodingKeys: String, CodingKey { case requestID = "request_id", reviewerUserID = "decided_by_user_id", decisionOperationID = "decision_operation_id", applicantUserID = "applicant_user_id", preparedRevision = "approval_membership_revision" }
    var candidate: V2GroupApprovalRecoveryCandidate { .init(requestID: requestID, reviewerUserID: reviewerUserID, decisionOperationID: decisionOperationID, applicantUserID: applicantUserID, preparedRevision: preparedRevision) }
}
private struct ApprovalRecoveryMemberRow: Decodable {
    let roomID: UUID; let targetUserID: UUID; let action: String; let expectedRevision: Int64; let resultingRevision: Int64
    let roomSequence: Int64; let eventID: UUID; let planID: UUID; let createdAt: Date
    enum CodingKeys: String, CodingKey { case roomID = "room_id", targetUserID = "target_user_id", action, expectedRevision = "expected_membership_revision", resultingRevision = "resulting_membership_revision", roomSequence = "room_sequence", eventID = "event_id", planID = "plan_id", createdAt = "created_at" }
}
private struct ApprovalRecoveryInviteRow: Decodable {
    let used: Int; let maximum: Int
    enum CodingKeys: String, CodingKey { case used = "approved_use_count", maximum = "maximum_approved_uses" }
}
private struct ApprovalRecoveryAuditRow: Decodable {
    let principal: String; let shardID: String; let epoch: Int64; let roomID: UUID; let requestID: UUID
    let reviewerUserID: UUID; let decisionOperationID: UUID; let reason: V2DurableWorkReplayReason
    let outcome: V2GroupApprovalRecoveryOutcome; let detail: V2GroupApprovalRecoveryDetail
    enum CodingKeys: String, CodingKey { case principal = "operator_principal", shardID = "shard_id", epoch = "owner_epoch", roomID = "room_id", requestID = "request_id", reviewerUserID = "reviewer_user_id", decisionOperationID = "decision_operation_id", reason = "reason_code", outcome, detail }
    func matches(_ command: V2GroupApprovalRecoveryCommand, principal: String) -> Bool {
        self.principal == principal && shardID == command.scope.shardID && epoch == command.scope.ownerEpoch && roomID == command.scope.roomID && requestID == command.requestID && reviewerUserID == command.reviewerUserID && decisionOperationID == command.decisionOperationID && reason == command.reason
    }
}

/// Shared by ordinary membership and approval writes; a released legacy
/// operation cannot become executable again when its reviewer regains access.
func v2MembershipOperationIsFenced(actor: UUID, operation: UUID, sql: any SQLDatabase) async throws -> Bool {
    try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.room_membership_operation_fences WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation)) AS value").first(decoding: ApprovalRecoveryBool.self)?.value == true
}
