import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// 群邀请的 PostgreSQL 实现。
///
/// 邀请有效性、审批容量与审核人授权都以 PostgreSQL 为权威。
/// 明文 Bearer 令牌绝不会跨越该边界：查询与持久化都只使用其 SHA-256 摘要。
public struct PostgresV2GroupInvitationStore: V2GroupInvitationStore {
    private let database: any Database
    private let identities: any V2GroupInvitationIdentityReading
    private let scope: V2GroupInvitationOwnerScope?
    private let activationScope: V2RoomActivationWriteScope?

    public init(database: any Database) {
        self.database = database
        self.identities = PostgresV2GroupInvitationIdentityReader(database: database)
        self.scope = nil
        self.activationScope = nil
    }

    init(database: any Database, identities: any V2GroupInvitationIdentityReading, scope: V2GroupInvitationOwnerScope) {
        self.database = database
        self.identities = identities
        self.scope = scope
        self.activationScope = nil
    }

    /// Room actor operations bind every read, replay and mutation to one granted turn.
    init(database: any Database, identities: any V2GroupInvitationIdentityReading,
         activationToken: V2RoomActivationToken, inviteID: GroupInviteID? = nil) throws {
        guard let room = activationToken.roomID.uuidValue else {
            throw V2GroupInvitationServiceError.invalidRequest
        }
        self.database = database
        self.identities = identities
        self.scope = .init(roomID: room,
                           route: try .init(shardID: activationToken.owner.shardID,
                                            epoch: activationToken.owner.epoch),
                           inviteID: inviteID?.uuidValue)
        self.activationScope = try .init(tokens: [activationToken])
    }

    func preflightCreation(_ request: V2GroupInviteCreatePersistenceRequest) async throws -> V2StoredGroupInvite? {
        let actorIsActive = try await isActive(request.actorUserID)
        return try await v2WithPostgresTransactionRetry(database: database, maximumRetryCount: 0,
            classifyCommitFailure: false, useRoomDeadline: activationScope != nil) { transaction in
            let sql = try groupInviteSQL(transaction)
            let room = try groupInviteUUID(request.roomID), actor = try groupInviteUUID(request.actorUserID)
            try await fence(room: room, sql: sql, shared: true)
            if let existing = try await inviteByCreation(actor: actor, operation: groupInviteUUID(request.operationID), sql: sql) {
                guard existing.roomID == room, existing.tokenDigest == request.tokenDigest,
                      existing.requestedLifetimeSeconds == request.requestedLifetimeSeconds,
                      existing.maximumApprovedUses == request.maximumApprovedUses
                else { throw V2GroupInvitationServiceError.conflict }
                return try existing.stored(now: request.evaluatedAt)
            }
            let timestamps = try validateGroupInviteCreationClock(request)
            guard try V2PostgresTimestamp(date: request.evaluatedAt).microseconds < timestamps.expiresAt.microseconds else { throw V2GroupInvitationServiceError.creationExpired }
            _ = try await authorize(room: room, actor: actor, actorIsActive: actorIsActive, lockMembership: false, sql: sql)
            return nil
        }
    }

    public func create(_ request: V2GroupInviteCreatePersistenceRequest) async throws -> V2StoredGroupInvite {
        let actorIsActive = try await isActive(request.actorUserID)
        return try await v2WithPostgresTransactionRetry(database: database, maximumRetryCount: 0,
            classifyCommitFailure: activationScope != nil, useRoomDeadline: activationScope != nil) { transaction in
            let sql = try groupInviteSQL(transaction)
            let room = try groupInviteUUID(request.roomID)
            let actor = try groupInviteUUID(request.actorUserID)
            let operation = try groupInviteUUID(request.operationID)
            try await advisoryLock(sql, value: "group-invite-create:\(actor):\(operation)")
            try await advisoryLock(sql, value: "group-invite-room:\(room)")
            try await fence(room: room, sql: sql)
            if let existing = try await inviteByCreation(actor: actor, operation: operation, sql: sql) {
                guard existing.roomID == room,
                      existing.tokenDigest == request.tokenDigest,
                      existing.requestedLifetimeSeconds == request.requestedLifetimeSeconds,
                      existing.maximumApprovedUses == request.maximumApprovedUses
                else { throw V2GroupInvitationServiceError.conflict }
                return try existing.stored(now: request.evaluatedAt)
            }
            let timestamps = try validateGroupInviteCreationClock(request)
            guard try V2PostgresTimestamp(date: request.evaluatedAt).microseconds < timestamps.expiresAt.microseconds else { throw V2GroupInvitationServiceError.creationExpired }
            _ = try await authorize(room: room, actor: actor, actorIsActive: actorIsActive, lockMembership: true, sql: sql)
            let activeCount = try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_links WHERE room_id = \(bind: room) AND state = 'active' AND approved_use_count < maximum_approved_uses AND expires_at > \(bind: request.evaluatedAt)").first(decoding: GroupInviteCountRow.self)?.value ?? 0
            guard activeCount < request.maximumActiveInvitesPerRoom else {
                throw V2GroupInvitationServiceError.rateLimited
            }
            let invite = try groupInviteUUID(request.inviteID)
            try await sql.raw("""
                INSERT INTO im_v2.group_invite_links
                    (invite_id, room_id, created_by_user_id, creation_operation_id,
                     token_digest, requested_lifetime_seconds, expires_at,
                     maximum_approved_uses, approved_use_count, state, created_at)
                VALUES (\(bind: invite), \(bind: room), \(bind: actor), \(bind: operation),
                        \(bind: request.tokenDigest), \(bind: request.requestedLifetimeSeconds),
                        \(bind: timestamps.expiresAt), \(bind: request.maximumApprovedUses),
                        0, 'active', \(bind: timestamps.createdAt))
                """).run()
            guard let result = try await inviteByID(invite, sql: sql) else {
                throw V2GroupInvitationServiceError.corruptPersistenceState
            }
            return try result.stored(now: request.evaluatedAt)
        }
    }

    public func activeInvites(roomID: RoomID, actorUserID: UserID, now: Date) async throws -> [V2StoredGroupInvite] {
        let actorIsActive = try await isActive(actorUserID)
        return try await v2WithRoomScopedTransaction(database: database, useRoomDeadline: activationScope != nil) { transaction in
            let sql = try groupInviteSQL(transaction)
            let room = try groupInviteUUID(roomID)
            try await fence(room: room, sql: sql, shared: true)
            _ = try await authorize(room: room, actor: groupInviteUUID(actorUserID), actorIsActive: actorIsActive, lockMembership: false, sql: sql)
            guard v2PostgresTimestampCanEncode(now) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            return try await sql.raw("""
                SELECT invite.invite_id, invite.room_id, room.title AS room_title,
                       invite.created_by_user_id, invite.creation_operation_id,
                       invite.token_digest, invite.requested_lifetime_seconds,
                       invite.expires_at, invite.maximum_approved_uses,
                       invite.approved_use_count, invite.state, invite.created_at
                FROM im_v2.group_invite_links AS invite
                JOIN im_v2.group_rooms AS room ON room.room_id = invite.room_id
                WHERE invite.room_id = \(bind: room) AND invite.state = 'active'
                  AND invite.expires_at > \(bind: now)
                  AND invite.approved_use_count < invite.maximum_approved_uses
                ORDER BY invite.created_at DESC, invite.invite_id DESC
                LIMIT 100
                """).all(decoding: GroupInviteRow.self).map { try $0.stored(now: now) }
        }
    }

    public func revoke(inviteID: GroupInviteID, roomID: RoomID, actorUserID: UserID, operationID: GroupInviteOperationID, now: Date) async throws {
        let actorIsActive = try await isActive(actorUserID)
        try await v2WithPostgresTransactionRetry(database: database, maximumRetryCount: 0,
            classifyCommitFailure: activationScope != nil, useRoomDeadline: activationScope != nil) { transaction in
            let sql = try groupInviteSQL(transaction)
            let room = try groupInviteUUID(roomID)
            let actor = try groupInviteUUID(actorUserID)
            let operation = try groupInviteUUID(operationID)
            try await advisoryLock(sql, value: "group-invite-revoke:\(actor):\(operation)")
            try await fence(room: room, sql: sql)
            _ = try await authorize(room: room, actor: actor, actorIsActive: actorIsActive, lockMembership: true, sql: sql)
            guard let invite = try await inviteByID(groupInviteUUID(inviteID), lock: true, sql: sql), invite.roomID == room else {
                throw V2GroupInvitationServiceError.inviteNotFound
            }
            if invite.state == "revoked" {
                guard invite.revocationOperationID == operation else { throw V2GroupInvitationServiceError.conflict }
                return
            }
            guard v2PostgresTimestampCanEncode(now) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            try await sql.raw("""
                UPDATE im_v2.group_invite_links
                SET state = 'revoked', revocation_operation_id = \(bind: operation),
                    revoked_by_user_id = \(bind: actor), revoked_at = \(bind: now)
                WHERE invite_id = \(bind: invite.inviteID) AND state = 'active'
                """).run()
        }
    }

    public func preview(tokenDigest: Data, applicantUserID: UserID, now: Date) async throws -> V2GroupInvitePreviewPersistenceOutcome {
        guard try await isActive(applicantUserID) else { throw V2GroupInvitationServiceError.permissionDenied }
        return try await v2WithRoomScopedTransaction(database: database, useRoomDeadline: activationScope != nil) { transaction in
            let sql = try groupInviteSQL(transaction)
            if let scope { try await fence(room: scope.roomID, sql: sql, shared: true) }
            guard v2PostgresTimestampCanEncode(now) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            guard let row = try await sql.raw("""
                SELECT invite.invite_id, invite.room_id, room.title AS room_title,
                       invite.expires_at, request.state AS request_state,
                       request.request_id,
                       EXISTS (
                           SELECT 1 FROM im_v2.room_memberships AS membership
                           JOIN im_v2.rooms AS current_room ON current_room.room_id = membership.room_id
                           WHERE membership.room_id = invite.room_id
                             AND membership.user_id = \(bind: try groupInviteUUID(applicantUserID))
                             AND membership.joined_revision <= current_room.membership_revision
                             AND (membership.left_revision IS NULL OR membership.left_revision > current_room.membership_revision)
                       ) AS is_already_member
                FROM im_v2.group_invite_links AS invite
                JOIN im_v2.group_rooms AS room ON room.room_id = invite.room_id
                LEFT JOIN LATERAL (
                    SELECT request_id, state FROM im_v2.group_join_requests
                    WHERE invite_id = invite.invite_id
                      AND applicant_user_id = \(bind: try groupInviteUUID(applicantUserID))
                    ORDER BY (state <> 'cancelled') DESC, created_at DESC, request_id DESC LIMIT 1
                ) AS request ON TRUE
                WHERE invite.token_digest = \(bind: tokenDigest)
                  AND ((invite.state = 'active' AND invite.expires_at > \(bind: now))
                       OR request.state = 'pending')
                LIMIT 1
                """).first(decoding: GroupInvitePreviewRow.self) else { return .unavailable }
            try validateInvite(invite: row.inviteID, room: row.roomID)
            // Existing members and existing applications may still inspect a link
            // after its approval allowance becomes full; only new submissions stop.
            if row.requestID == nil && !row.isAlreadyMember {
                let hasCapacity = try await sql.raw("""
                    SELECT approved_use_count < maximum_approved_uses AS value
                    FROM im_v2.group_invite_links WHERE invite_id = \(bind: row.inviteID)
                    """).first(decoding: GroupInviteBooleanRow.self)?.value == true
                guard hasCapacity else { return .unavailable }
        }
        return .available(try row.preview())
        }
    }

    public func submit(_ request: V2GroupJoinSubmissionPersistenceRequest) async throws -> V2GroupJoinSubmissionPersistenceOutcome {
        let actorIsActive = try await isActive(request.applicantUserID)
        let result = try await v2WithPostgresTransactionRetry(database: database, maximumRetryCount: 0,
            classifyCommitFailure: activationScope != nil, useRoomDeadline: activationScope != nil) { transaction in
            let sql = try groupInviteSQL(transaction)
            try await lockSubmission(applicant: groupInviteUUID(request.applicantUserID), sql: sql)
            return try await submitLocked(request, actorIsActive: actorIsActive, evaluatedAt: request.createdAt, sql: sql)
        }
        return try await hydrate(result)
    }

    private func lockSubmission(applicant: UUID, sql: any SQLDatabase) async throws {
        try await advisoryLock(sql, value: "group-join-applicant:\(applicant)")
        if let scope { try await fence(room: scope.roomID, sql: sql) }
    }

    private func submitLocked(_ request: V2GroupJoinSubmissionPersistenceRequest, actorIsActive: Bool,
                              evaluatedAt: Date, sql: any SQLDatabase) async throws -> GroupJoinSubmissionResult {
        let applicant = try groupInviteUUID(request.applicantUserID), operation = try groupInviteUUID(request.operationID)
        if let priorDigest = try await sql.raw("SELECT invite.token_digest FROM im_v2.group_join_requests AS request JOIN im_v2.group_invite_links AS invite ON invite.invite_id = request.invite_id WHERE request.applicant_user_id = \(bind: applicant) AND request.submission_operation_id = \(bind: operation)").first(decoding: GroupInviteDigestRow.self) {
            guard priorDigest.tokenDigest == request.tokenDigest,
                  let prior = try await requestBySubmission(applicant: applicant, operation: operation, sql: sql),
                  prior.note == request.note
            else { throw V2GroupInvitationServiceError.conflict }
            try validateInvite(invite: prior.inviteID, room: prior.roomID)
            return try submissionOutcome(prior)
        }
        guard actorIsActive else { throw V2GroupInvitationServiceError.permissionDenied }
        guard v2PostgresTimestampCanEncode(request.createdAt), v2PostgresTimestampCanEncode(evaluatedAt) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        let currentTime = try V2PostgresTimestamp(date: evaluatedAt)
        if scope == nil {
            // Discover the immutable room binding before locking the invite.
            // Keep the same room -> invite order as approval and revocation.
            guard let binding = try await sql.raw("""
                SELECT room_id FROM im_v2.group_invite_links WHERE token_digest = \(bind: request.tokenDigest)
                """).first(decoding: GroupInviteRoomBinding.self) else { return .unavailable }
            try await fence(room: binding.roomID, sql: sql)
        }
        guard let invite = try await sql.raw("""
            SELECT invite.invite_id, invite.room_id, room.title AS room_title,
                   invite.created_by_user_id, invite.creation_operation_id,
                   invite.token_digest, invite.requested_lifetime_seconds,
                   invite.expires_at, invite.maximum_approved_uses,
                   invite.approved_use_count, invite.state, invite.created_at,
                   invite.revocation_operation_id
            FROM im_v2.group_invite_links AS invite
            JOIN im_v2.group_rooms AS room ON room.room_id = invite.room_id
            WHERE invite.token_digest = \(bind: request.tokenDigest)
            FOR UPDATE OF invite
            """).first(decoding: GroupInviteRow.self),
              invite.state == "active", invite.expiresAt.microseconds > currentTime.microseconds,
              invite.approvedUseCount < invite.maximumApprovedUses
        else { return .unavailable }

        try validateInvite(invite: invite.inviteID, room: invite.roomID)
        guard v2PostgresTimestampCanEncode(invite.expiresAt.date) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        if try await isCurrentMember(room: invite.roomID, user: applicant, sql: sql) {
            return .alreadyMember(.init(inviteID: .init(uuid: invite.inviteID), roomID: .init(uuid: invite.roomID), roomTitle: invite.roomTitle, expiresAt: invite.expiresAt.date, requestState: nil, requestID: nil, isAlreadyMember: true))
        }
        if let existing = try await requestByInvite(invite: invite.inviteID, applicant: applicant, sql: sql) {
            return try submissionOutcome(existing)
        }
        let counts = try await sql.raw("""
            SELECT
              (SELECT COUNT(*) FROM im_v2.group_join_requests WHERE applicant_user_id = \(bind: applicant) AND state = 'pending') AS applicant_count,
              (SELECT COUNT(*) FROM im_v2.group_join_requests WHERE invite_id = \(bind: invite.inviteID) AND state = 'pending') AS invite_count
            """).first(decoding: GroupInvitePendingCountRow.self)
        guard let counts else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        guard counts.applicantCount < request.maximumPendingRequestsPerApplicant,
              counts.inviteCount < request.maximumPendingRequestsPerInvite else { return .rateLimited }

        try await sql.raw("""
            INSERT INTO im_v2.group_join_requests
                (request_id, invite_id, room_id, applicant_user_id,
                 submission_operation_id, note, state, created_at, updated_at)
            VALUES (\(bind: try groupInviteUUID(request.requestID)), \(bind: invite.inviteID),
                    \(bind: invite.roomID), \(bind: applicant), \(bind: operation),
                    \(bind: request.note), 'pending', \(bind: request.createdAt), \(bind: request.createdAt))
            """).run()
        guard let inserted = try await requestByID(try groupInviteUUID(request.requestID), sql: sql) else {
            throw V2GroupInvitationServiceError.corruptPersistenceState
        }
        return .submitted(inserted)
    }

    public func pendingRequests(roomID: RoomID, reviewerUserID: UserID, cursor: String?, pageSize: Int, now: Date) async throws -> V2GroupJoinRequestRecordPage {
        let actorIsActive = try await isActive(reviewerUserID)
        let result: ([GroupJoinRequestRow], String?) = try await v2WithRoomScopedTransaction(database: database, useRoomDeadline: activationScope != nil) { transaction in
            let sql = try groupInviteSQL(transaction)
            let room = try groupInviteUUID(roomID)
            try await fence(room: room, sql: sql, shared: true)
            _ = try await authorize(room: room, actor: groupInviteUUID(reviewerUserID), actorIsActive: actorIsActive, lockMembership: false, sql: sql)
            guard (1...100).contains(pageSize) else { throw V2GroupInvitationServiceError.invalidRequest }
            let anchor = try cursor.map { try V2GroupJoinPageCursor.decode($0, roomID: room) }
            let rows: [GroupJoinRequestRow]
            if let anchor {
                rows = try await sql.raw("""
                    SELECT \(unsafeRaw: requestSelection)
                    FROM im_v2.group_join_requests AS request
                    JOIN im_v2.group_invite_links AS invite ON invite.invite_id = request.invite_id
                    JOIN im_v2.group_rooms AS group_room ON group_room.room_id = request.room_id
                    WHERE request.room_id = \(bind: room) AND request.state = 'pending'
                      AND (request.created_at, request.request_id) > (\(bind: try anchor.timestampBinding())::timestamptz, \(bind: anchor.requestID))
                    ORDER BY request.created_at, request.request_id LIMIT \(bind: pageSize + 1)
                    """).all(decoding: GroupJoinRequestRow.self)
            } else {
                rows = try await sql.raw("""
                    SELECT \(unsafeRaw: requestSelection)
                    FROM im_v2.group_join_requests AS request
                    JOIN im_v2.group_invite_links AS invite ON invite.invite_id = request.invite_id
                    JOIN im_v2.group_rooms AS group_room ON group_room.room_id = request.room_id
                    WHERE request.room_id = \(bind: room) AND request.state = 'pending'
                    ORDER BY request.created_at, request.request_id LIMIT \(bind: pageSize + 1)
                    """).all(decoding: GroupJoinRequestRow.self)
        }
        let visible = Array(rows.prefix(pageSize))
        return (visible, rows.count > pageSize ? try visible.last.map { try V2GroupJoinPageCursor(roomID: room, timestamp: $0.cursorCreatedAt, requestID: $0.requestID).encoded() } : nil)
        }
        let profiles = try await identities.read(userIDs: Set(result.0.map { .init(uuid: $0.applicantUserID) }))
        return .init(requests: try result.0.map { row in
            guard let profile = profiles[.init(uuid: row.applicantUserID)]?.profile else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            return try row.record(identity: profile)
        }, nextCursor: result.1)
    }

    public func approve(
        roomID: RoomID, requestID: GroupJoinRequestID, reviewerUserID: UserID,
        operationID: GroupJoinDecisionOperationID, capacityProfile: V2CapacityProfile,
        eventID: EventID, now: Date
    ) async throws -> V2GroupJoinApprovalPersistenceOutcome {
        // The applicant ID is immutable business input. Read it without an
        // owner transaction, snapshot control identities, then recheck the ID
        // under the real room/request locks before adding any member.
        let applicant = try await requestByID(groupInviteUUID(requestID), sql: groupInviteSQL(database))?.applicantUserID
        var identityIDs: Set<UserID> = [reviewerUserID]
        if let applicant { identityIDs.insert(.init(uuid: applicant)) }
        let identityFacts = try await identities.read(userIDs: identityIDs)
        let actorIsActive = identityFacts[reviewerUserID]?.isActive == true
        do {
            let result: GroupJoinApprovalResult = try await v2WithPostgresTransactionRetry(database: database, maximumRetryCount: 0,
                classifyCommitFailure: activationScope != nil, useRoomDeadline: activationScope != nil) { transaction in
                let sql = try groupInviteSQL(transaction)
                let room = try groupInviteUUID(roomID), reviewer = try groupInviteUUID(reviewerUserID)
                let operation = try groupInviteUUID(operationID), request = try groupInviteUUID(requestID)
                // Use the membership operation's lock namespace before taking
                // the room lock. Ordinary adds/removes use the same order.
                try await advisoryLock(sql, value: reviewer.uuidString + ":" + operation.uuidString)
                try await fence(room: room, sql: sql)
                if let prior = try await requestByDecision(reviewer: reviewer, operation: operation, sql: sql) {
                    guard prior.roomID == room, prior.requestID == request, prior.state == "approved" else { return .conflict }
                    return .approved(prior)
                }
                // An independently committed member add is not proof that this
                // request was approved, even if its actor/target happen to match.
                guard try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.room_membership_operations WHERE actor_user_id = \(bind: reviewer) AND operation_id = \(bind: operation)) AS value").first(decoding: GroupInviteBooleanRow.self)?.value == false else { return .conflict }
                let revision = try await authorize(room: room, actor: reviewer, actorIsActive: actorIsActive, lockMembership: true, sql: sql)
                guard let value = try await requestByID(request, lock: true, sql: sql), value.roomID == room else { throw V2GroupInvitationServiceError.requestNotFound }
                switch value.state {
                case "approved", "rejected", "cancelled": return .alreadyDecided(value)
                case "pending": break
                default: throw V2GroupInvitationServiceError.corruptPersistenceState
                }
                guard let invite = try await inviteByID(value.inviteID, lock: true, sql: sql) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                guard invite.approvedUseCount < invite.maximumApprovedUses else { return .memberLimitReached }
                // Revocation/expiration blocks new submissions; already pending
                // requests retain the review policy established by ADR-019.
                guard value.applicantUserID == applicant else { return .unavailable }
                guard v2PostgresTimestampCanEncode(now) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                try value.validateResponseTimes()
                let membershipIdentity = V2MembershipIdentitySnapshot(
                    actorUserID: reviewerUserID, targetUserID: .init(uuid: value.applicantUserID),
                    actorIsActive: actorIsActive,
                    targetIsActive: identityFacts[.init(uuid: value.applicantUserID)]?.isActive == true
                )
                let command = try V2ChangeRoomMembershipCommand(
                    roomID: roomID, actorUserID: reviewerUserID,
                    operationID: .init(operationID.rawValue), targetUserID: .init(uuid: value.applicantUserID),
                    action: .add, expectedMembershipRevision: revision
                )
                let membership = try await PostgresV2RoomMembershipStore.change(
                    in: sql, command: command, identitySnapshot: membershipIdentity, capacityProfile: capacityProfile,
                    eventID: eventID, now: now
                )
                switch membership {
                case .changed: break
                case .memberLimitReached: return .memberLimitReached
                case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
                case .unavailable: return .unavailable
                case .targetAlreadyMember, .idempotencyConflict, .targetNotMember: return .conflict
                case .idempotent, .revisionConflict:
                    // Both locks are held and the operation was absent above.
                    throw V2GroupInvitationServiceError.corruptPersistenceState
                }
                try await sql.raw("UPDATE im_v2.group_invite_links SET approved_use_count = approved_use_count + 1 WHERE invite_id = \(bind: invite.inviteID)").run()
                try await sql.raw("""
                    UPDATE im_v2.group_join_requests
                    SET state = 'approved', decision_operation_id = \(bind: operation),
                        decided_by_user_id = \(bind: reviewer), approval_membership_revision = \(bind: Int64(revision)),
                        decided_at = \(bind: now), updated_at = \(bind: now)
                    WHERE request_id = \(bind: request) AND state = 'pending'
                    """).run()
                guard let completed = try await requestByID(request, sql: sql) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                return .approved(completed)
            }
            return try await hydrate(result)
        } catch V2RoomMembershipStoreError.actorNotOwner {
            throw V2GroupInvitationServiceError.permissionDenied
        } catch V2RoomMembershipStoreError.roomNotFound {
            return .unavailable
        } catch V2RoomMembershipStoreError.targetUnavailable {
            return .unavailable
        } catch V2RoomMembershipStoreError.corruptPersistenceState {
            throw V2GroupInvitationServiceError.corruptPersistenceState
        }
    }

    public func cancel(roomID: RoomID, requestID: GroupJoinRequestID, applicantUserID: UserID, now: Date) async throws -> V2GroupJoinRequestRecord {
        guard try await isActive(applicantUserID) else { throw V2GroupInvitationServiceError.permissionDenied }
        let result = try await v2WithPostgresTransactionRetry(database: database, maximumRetryCount: 0,
            classifyCommitFailure: activationScope != nil, useRoomDeadline: activationScope != nil) { transaction in
            let sql = try groupInviteSQL(transaction)
            let applicant = try groupInviteUUID(applicantUserID), room = try groupInviteUUID(roomID)
            // Submission uses this lock too: quota release and a subsequent
            // submission observe one serial order within this owner database.
            try await advisoryLock(sql, value: "group-join-applicant:" + applicant.uuidString)
            try await fence(room: room, sql: sql)
            guard let value = try await requestByID(try groupInviteUUID(requestID), lock: true, sql: sql),
                  value.roomID == room, value.applicantUserID == applicant
            else { throw V2GroupInvitationServiceError.requestNotFound }
            switch value.state {
            case "cancelled", "approved", "rejected": return value
            case "pending":
                guard v2PostgresTimestampCanEncode(now) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                try value.validateResponseTimes()
                try await sql.raw("""
                    UPDATE im_v2.group_join_requests
                    SET state = 'cancelled', decided_by_user_id = \(bind: applicant),
                        decided_at = \(bind: now), updated_at = \(bind: now)
                    WHERE request_id = \(bind: value.requestID)
                    """).run()
                guard let completed = try await requestByID(value.requestID, sql: sql) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                return completed
            default: throw V2GroupInvitationServiceError.corruptPersistenceState
            }
        }
        return try await hydrate(result)
    }

    public func reject(roomID: RoomID, requestID: GroupJoinRequestID, reviewerUserID: UserID, operationID: GroupJoinDecisionOperationID, now: Date) async throws -> V2GroupJoinDecisionPreparationOutcome {
        let actorIsActive = try await isActive(reviewerUserID)
        let result: GroupJoinDecisionResult = try await v2WithPostgresTransactionRetry(database: database, maximumRetryCount: 0,
            classifyCommitFailure: activationScope != nil, useRoomDeadline: activationScope != nil) { transaction in
            let sql = try groupInviteSQL(transaction)
            let room = try groupInviteUUID(roomID), reviewer = try groupInviteUUID(reviewerUserID), operation = try groupInviteUUID(operationID)
            try await advisoryLock(sql, value: reviewer.uuidString + ":" + operation.uuidString)
            try await fence(room: room, sql: sql)
            if let prior = try await requestByDecision(reviewer: reviewer, operation: operation, sql: sql) {
                guard prior.roomID == room, prior.requestID == (try groupInviteUUID(requestID)), prior.state == "rejected" else { return .decisionConflict }
                return .rejected(prior)
            }
            guard try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.room_membership_operations WHERE actor_user_id = \(bind: reviewer) AND operation_id = \(bind: operation)) AS value").first(decoding: GroupInviteBooleanRow.self)?.value == false else { return .decisionConflict }
            _ = try await authorize(room: room, actor: reviewer, actorIsActive: actorIsActive, lockMembership: true, sql: sql)
            guard let value = try await requestByID(try groupInviteUUID(requestID), lock: true, sql: sql), value.roomID == room else { throw V2GroupInvitationServiceError.requestNotFound }
            switch value.state {
            case "approved": return .alreadyApproved(value)
            case "rejected": return .alreadyRejected(value)
            case "cancelled": return .decisionConflict
            case "pending":
                guard v2PostgresTimestampCanEncode(now) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                try value.validateResponseTimes()
                try await sql.raw("UPDATE im_v2.group_join_requests SET state = 'rejected', decision_operation_id = \(bind: operation), decided_by_user_id = \(bind: reviewer), decided_at = \(bind: now), updated_at = \(bind: now) WHERE request_id = \(bind: value.requestID)").run()
                guard let rejected = try await requestByID(value.requestID, sql: sql) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                return .rejected(rejected)
            default: throw V2GroupInvitationServiceError.corruptPersistenceState
            }
        }
        return try await hydrate(result)
    }

    private func authorize(room: UUID, actor: UUID, actorIsActive: Bool, lockMembership: Bool, sql: any SQLDatabase) async throws -> UInt64 {
        guard actorIsActive else { throw V2GroupInvitationServiceError.permissionDenied }
        if lockMembership {
            // Lock the room before any member row, as membership.change does.
            // A separate statement makes the order independent of join plans.
            try await sql.raw("SELECT room_id FROM im_v2.rooms WHERE room_id = \(bind: room) FOR NO KEY UPDATE").run()
        }
        let lock = lockMembership ? " FOR UPDATE OF membership" : ""
        guard let row = try await sql.raw("""
            SELECT current_room.membership_revision, membership.role
            FROM im_v2.rooms AS current_room
            JOIN im_v2.group_rooms AS group_room ON group_room.room_id = current_room.room_id
            JOIN im_v2.room_memberships AS membership
              ON membership.room_id = current_room.room_id AND membership.user_id = \(bind: actor)
             AND membership.joined_revision <= current_room.membership_revision
             AND (membership.left_revision IS NULL OR membership.left_revision > current_room.membership_revision)
            WHERE current_room.room_id = \(bind: room)
            \(unsafeRaw: lock)
            """).first(decoding: GroupInviteAuthorizationRow.self),
              let role = V2RoomMembershipRole(rawValue: row.role) else { throw V2GroupInvitationServiceError.permissionDenied }
        if role != .owner {
            let configured = try await v2ResolvedGroupPermissions(roomID: room, role: role, sql: sql)
            guard V2GroupPermissionDefaults.allows(role: role, permission: .inviteMembers, configured: configured) else {
                throw V2GroupInvitationServiceError.permissionDenied
            }
        }
        guard row.membershipRevision >= 0 else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        return UInt64(row.membershipRevision)
    }

    private func inviteByCreation(actor: UUID, operation: UUID, sql: any SQLDatabase) async throws -> GroupInviteRow? {
        try await sql.raw("SELECT \(unsafeRaw: inviteSelection) FROM im_v2.group_invite_links AS invite JOIN im_v2.group_rooms AS room ON room.room_id = invite.room_id WHERE invite.created_by_user_id = \(bind: actor) AND invite.creation_operation_id = \(bind: operation)").first(decoding: GroupInviteRow.self)
    }

    private func inviteByID(_ id: UUID, lock: Bool = false, sql: any SQLDatabase) async throws -> GroupInviteRow? {
        try await sql.raw("SELECT \(unsafeRaw: inviteSelection) FROM im_v2.group_invite_links AS invite JOIN im_v2.group_rooms AS room ON room.room_id = invite.room_id WHERE invite.invite_id = \(bind: id) \(unsafeRaw: lock ? "FOR UPDATE OF invite" : "")").first(decoding: GroupInviteRow.self)
    }

    private func requestByID(_ id: UUID, lock: Bool = false, sql: any SQLDatabase) async throws -> GroupJoinRequestRow? {
        try await sql.raw("SELECT \(unsafeRaw: requestSelection) FROM im_v2.group_join_requests AS request JOIN im_v2.group_invite_links AS invite ON invite.invite_id = request.invite_id JOIN im_v2.group_rooms AS group_room ON group_room.room_id = request.room_id WHERE request.request_id = \(bind: id) \(unsafeRaw: lock ? "FOR UPDATE OF request" : "")").first(decoding: GroupJoinRequestRow.self)
    }

    private func requestByDecision(reviewer: UUID, operation: UUID, sql: any SQLDatabase) async throws -> GroupJoinRequestRow? {
        try await sql.raw("SELECT \(unsafeRaw: requestSelection) FROM im_v2.group_join_requests AS request JOIN im_v2.group_invite_links AS invite ON invite.invite_id = request.invite_id JOIN im_v2.group_rooms AS group_room ON group_room.room_id = request.room_id WHERE request.decided_by_user_id = \(bind: reviewer) AND request.decision_operation_id = \(bind: operation)").first(decoding: GroupJoinRequestRow.self)
    }

    private func requestBySubmission(applicant: UUID, operation: UUID, sql: any SQLDatabase) async throws -> GroupJoinRequestRow? {
        try await sql.raw("SELECT \(unsafeRaw: requestSelection) FROM im_v2.group_join_requests AS request JOIN im_v2.group_invite_links AS invite ON invite.invite_id = request.invite_id JOIN im_v2.group_rooms AS group_room ON group_room.room_id = request.room_id WHERE request.applicant_user_id = \(bind: applicant) AND request.submission_operation_id = \(bind: operation)").first(decoding: GroupJoinRequestRow.self)
    }

    private func requestByInvite(invite: UUID, applicant: UUID, sql: any SQLDatabase) async throws -> GroupJoinRequestRow? {
        try await sql.raw("SELECT \(unsafeRaw: requestSelection) FROM im_v2.group_join_requests AS request JOIN im_v2.group_invite_links AS invite ON invite.invite_id = request.invite_id JOIN im_v2.group_rooms AS group_room ON group_room.room_id = request.room_id WHERE request.invite_id = \(bind: invite) AND request.applicant_user_id = \(bind: applicant) AND request.state <> 'cancelled'").first(decoding: GroupJoinRequestRow.self)
    }

    private func isCurrentMember(room: UUID, user: UUID, sql: any SQLDatabase) async throws -> Bool {
        try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.room_memberships AS membership JOIN im_v2.rooms AS current_room ON current_room.room_id = membership.room_id WHERE membership.room_id = \(bind: room) AND membership.user_id = \(bind: user) AND membership.joined_revision <= current_room.membership_revision AND (membership.left_revision IS NULL OR membership.left_revision > current_room.membership_revision)) AS value").first(decoding: GroupInviteBooleanRow.self)?.value == true
    }

    private func advisoryLock(_ sql: any SQLDatabase, value: String) async throws {
        if activationScope != nil { try await v2SetRoomActivationSQLTimeouts(.default, sql: sql) }
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: value), 0))").run()
    }
}

private let inviteSelection = "invite.invite_id, invite.room_id, room.title AS room_title, invite.created_by_user_id, invite.creation_operation_id, invite.token_digest, invite.requested_lifetime_seconds, invite.expires_at, invite.maximum_approved_uses, invite.approved_use_count, invite.state, invite.created_at, invite.revocation_operation_id"
private let requestSelection = "request.request_id, request.invite_id, request.room_id, request.applicant_user_id, request.submission_operation_id, request.note, request.state, request.decision_operation_id, request.decided_by_user_id, request.approval_membership_revision, request.created_at, request.created_at AS cursor_created_at, request.decided_at, group_room.title AS room_title, invite.expires_at AS invite_expires_at"

private struct GroupInviteRow: Decodable {
    let inviteID: UUID, roomID: UUID, roomTitle: String, createdByUserID: UUID, creationOperationID: UUID
    let tokenDigest: Data, requestedLifetimeSeconds: Int, expiresAt: V2PostgresTimestamp, maximumApprovedUses: Int, approvedUseCount: Int, state: String, createdAt: V2PostgresTimestamp
    let revocationOperationID: UUID?
    enum CodingKeys: String, CodingKey { case inviteID = "invite_id", roomID = "room_id", roomTitle = "room_title", createdByUserID = "created_by_user_id", creationOperationID = "creation_operation_id", tokenDigest = "token_digest", requestedLifetimeSeconds = "requested_lifetime_seconds", expiresAt = "expires_at", maximumApprovedUses = "maximum_approved_uses", approvedUseCount = "approved_use_count", state, createdAt = "created_at", revocationOperationID = "revocation_operation_id" }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        inviteID = try values.decode(UUID.self, forKey: .inviteID)
        roomID = try values.decode(UUID.self, forKey: .roomID)
        roomTitle = try values.decode(String.self, forKey: .roomTitle)
        createdByUserID = try values.decode(UUID.self, forKey: .createdByUserID)
        creationOperationID = try values.decode(UUID.self, forKey: .creationOperationID)
        tokenDigest = try values.decode(Data.self, forKey: .tokenDigest)
        requestedLifetimeSeconds = try values.decode(Int.self, forKey: .requestedLifetimeSeconds)
        // Preserve the public error contract when exact timestamp decoding
        // rejects a non-finite or otherwise invalid stored deadline.
        do { expiresAt = try values.decode(V2PostgresTimestamp.self, forKey: .expiresAt) }
        catch { throw V2GroupInvitationServiceError.corruptPersistenceState }
        maximumApprovedUses = try values.decode(Int.self, forKey: .maximumApprovedUses)
        approvedUseCount = try values.decode(Int.self, forKey: .approvedUseCount)
        state = try values.decode(String.self, forKey: .state)
        do { createdAt = try values.decode(V2PostgresTimestamp.self, forKey: .createdAt) }
        catch { throw V2GroupInvitationServiceError.corruptPersistenceState }
        revocationOperationID = try values.decodeIfPresent(UUID.self, forKey: .revocationOperationID)
    }
    func stored(now: Date) throws -> V2StoredGroupInvite {
        guard v2PostgresTimestampCanEncode(createdAt.date), v2PostgresTimestampCanEncode(expiresAt.date),
              state == "revoked" || v2PostgresTimestampCanEncode(now)
        else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        let visibleState: V2GroupInviteState
        if state == "revoked" {
            visibleState = .revoked
        } else {
            let currentTime = try V2PostgresTimestamp(date: now)
            visibleState = if expiresAt.microseconds <= currentTime.microseconds { .expired }
                else if approvedUseCount >= maximumApprovedUses { .exhausted } else { .active }
        }
        return .init(inviteID: .init(uuid: inviteID), roomID: .init(uuid: roomID), roomTitle: roomTitle, createdByUserID: .init(uuid: createdByUserID), creationOperationID: .init(uuid: creationOperationID), state: visibleState, expiresAt: expiresAt.date, maximumApprovedUses: maximumApprovedUses, approvedUseCount: approvedUseCount, createdAt: createdAt.date, persistedTimestamps: .init(createdAt: createdAt, expiresAt: expiresAt))
    }
}

private struct GroupInvitePreviewRow: Decodable {
    let inviteID: UUID, roomID: UUID, roomTitle: String, expiresAt: Date, requestState: String?, requestID: UUID?, isAlreadyMember: Bool
    enum CodingKeys: String, CodingKey { case inviteID = "invite_id", roomID = "room_id", roomTitle = "room_title", expiresAt = "expires_at", requestState = "request_state", requestID = "request_id", isAlreadyMember = "is_already_member" }
    func preview() throws -> V2GroupInvitePreviewRecord {
        guard v2PostgresTimestampCanEncode(expiresAt) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        return .init(inviteID: .init(uuid: inviteID), roomID: .init(uuid: roomID), roomTitle: roomTitle, expiresAt: expiresAt, requestState: try requestState.map { guard let state = V2GroupJoinRequestState(rawValue: $0) else { throw V2GroupInvitationServiceError.corruptPersistenceState }; return state }, requestID: requestID.map(GroupJoinRequestID.init(uuid:)), isAlreadyMember: isAlreadyMember) }
}

private struct GroupJoinRequestRow: Decodable, Sendable {
    let requestID: UUID, inviteID: UUID, roomID: UUID, applicantUserID: UUID, submissionOperationID: UUID
    let note: String?, state: String, decisionOperationID: UUID?, decidedByUserID: UUID?, approvalMembershipRevision: Int64?, createdAt: Date, decidedAt: Date?
    let cursorCreatedAt: V2GroupJoinCursorTimestamp
    let roomTitle: String, inviteExpiresAt: Date
    enum CodingKeys: String, CodingKey { case requestID = "request_id", inviteID = "invite_id", roomID = "room_id", applicantUserID = "applicant_user_id", submissionOperationID = "submission_operation_id", note, state, decisionOperationID = "decision_operation_id", decidedByUserID = "decided_by_user_id", approvalMembershipRevision = "approval_membership_revision", createdAt = "created_at", decidedAt = "decided_at", cursorCreatedAt = "cursor_created_at", roomTitle = "room_title", inviteExpiresAt = "invite_expires_at" }
    func validateResponseTimes() throws {
        guard v2PostgresTimestampCanEncode(createdAt), decidedAt.map(v2PostgresTimestampCanEncode) ?? true
        else { throw V2GroupInvitationServiceError.corruptPersistenceState }
    }

    func record(identity: V2PublicIdentity) throws -> V2GroupJoinRequestRecord {
        guard identity.userID.uuidValue == applicantUserID, let requestState = V2GroupJoinRequestState(rawValue: state) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        try validateResponseTimes()
        return .init(requestID: .init(uuid: requestID), inviteID: .init(uuid: inviteID), roomID: .init(uuid: roomID), applicant: identity, note: note, state: requestState, decisionOperationID: decisionOperationID.map(GroupJoinDecisionOperationID.init(uuid:)), decidedByUserID: decidedByUserID.map(UserID.init(uuid:)), createdAt: createdAt, decidedAt: decidedAt)
    }
}

private struct GroupInviteAuthorizationRow: Decodable { let membershipRevision: Int64, role: String; enum CodingKeys: String, CodingKey { case membershipRevision = "membership_revision", role } }
private struct GroupInviteBooleanRow: Decodable { let value: Bool }
private struct GroupInviteDigestRow: Decodable { let tokenDigest: Data; enum CodingKeys: String, CodingKey { case tokenDigest = "token_digest" } }
private struct GroupInviteCountRow: Decodable { let value: Int }
private struct GroupInvitePendingCountRow: Decodable { let applicantCount: Int, inviteCount: Int; enum CodingKeys: String, CodingKey { case applicantCount = "applicant_count", inviteCount = "invite_count" } }

private func groupInviteSQL(_ database: any Database) throws -> any SQLDatabase {
    guard let sql = database as? any SQLDatabase else { throw V2GroupInvitationServiceError.corruptPersistenceState }
    return sql
}

private func groupInviteUUID<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let uuid = value.uuidValue else { throw V2GroupInvitationServiceError.invalidRequest }
    return uuid
}

private func submissionOutcome(_ row: GroupJoinRequestRow) throws -> GroupJoinSubmissionResult {
    guard let state = V2GroupJoinRequestState(rawValue: row.state) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
    switch state {
    case .pending:
        try row.validateResponseTimes()
        return .alreadyPending(row)
    case .approving: throw V2GroupInvitationServiceError.corruptPersistenceState
    case .approved:
        guard v2PostgresTimestampCanEncode(row.inviteExpiresAt) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        return .alreadyMember(.init(inviteID: .init(uuid: row.inviteID), roomID: .init(uuid: row.roomID), roomTitle: row.roomTitle, expiresAt: row.inviteExpiresAt, requestState: .approved, requestID: .init(uuid: row.requestID), isAlreadyMember: true))
    case .cancelled:
        try row.validateResponseTimes()
        return .cancelled(row)
    case .rejected:
        try row.validateResponseTimes()
        return .rejected(row)
    }
}

struct V2GroupInvitationOwnerScope: Sendable {
    let roomID: UUID
    let route: V2RoomShardRoute
    let inviteID: UUID?
}

private struct InvitationOwnerRow: Decodable {
    let shardID: String
    let epoch: Int64
    enum CodingKeys: String, CodingKey { case shardID = "room_shard_id", epoch = "owner_epoch" }
}

private enum GroupJoinSubmissionResult: Sendable {
    case submitted(GroupJoinRequestRow), alreadyPending(GroupJoinRequestRow), rejected(GroupJoinRequestRow), cancelled(GroupJoinRequestRow)
    case alreadyMember(V2GroupInvitePreviewRecord), unavailable, rateLimited
}
private enum GroupJoinApprovalResult: Sendable {
    case approved(GroupJoinRequestRow), alreadyDecided(GroupJoinRequestRow)
    case conflict, memberLimitReached, rateLimited(retryAfterSeconds: Int), unavailable
}
private enum GroupJoinDecisionResult: Sendable {
    case rejected(GroupJoinRequestRow), alreadyApproved(GroupJoinRequestRow), alreadyRejected(GroupJoinRequestRow)
    case decisionConflict, inviteExhausted
}

private extension PostgresV2GroupInvitationStore {
    func isActive(_ userID: UserID) async throws -> Bool {
        try await identities.read(userIDs: [userID])[userID]?.isActive == true
    }

    func fence(room: UUID, sql: any SQLDatabase, shared: Bool = false) async throws {
        if let scope, room != scope.roomID { throw V2GroupInvitationServiceError.conflict }
        if let activationScope {
            try await v2SetRoomActivationSQLTimeouts(.default, sql: sql)
            try await activationScope.require([room], sql: sql)
            return
        }
        guard let row = try await sql.raw("""
            SELECT room_shard_id, owner_epoch FROM im_v2.rooms
            WHERE room_id = \(bind: room) \(unsafeRaw: shared ? "FOR SHARE" : "FOR UPDATE")
            """).first(decoding: InvitationOwnerRow.self) else {
            // Local callers retain their domain-specific not-found response;
            // scoped callers must reject a missing selected owner.
            if scope == nil { return }
            throw V2GroupInvitationServiceError.ownerChanged
        }
        if let scope {
            guard row.shardID == scope.route.shardID, row.epoch == scope.route.epoch
            else { throw V2GroupInvitationServiceError.ownerChanged }
        }
    }

    func validateInvite(invite: UUID, room: UUID) throws {
        guard let scope else { return }
        guard scope.roomID == room, scope.inviteID == nil || scope.inviteID == invite else {
            throw V2GroupInvitationServiceError.conflict
        }
    }

    func hydrate(_ row: GroupJoinRequestRow) async throws -> V2GroupJoinRequestRecord {
        let id = UserID(uuid: row.applicantUserID)
        guard let profile = try await identities.read(userIDs: [id])[id]?.profile else {
            throw V2GroupInvitationServiceError.corruptPersistenceState
        }
        return try row.record(identity: profile)
    }

    func hydrate(_ value: GroupJoinSubmissionResult) async throws -> V2GroupJoinSubmissionPersistenceOutcome {
        switch value {
        case .submitted(let row): return .submitted(try await hydrate(row))
        case .alreadyPending(let row): return .alreadyPending(try await hydrate(row))
        case .rejected(let row): return .rejected(try await hydrate(row))
        case .cancelled(let row): return .cancelled(try await hydrate(row))
        case .alreadyMember(let value): return .alreadyMember(value)
        case .unavailable: return .unavailable
        case .rateLimited: return .rateLimited
        }
    }
    func hydrate(_ value: GroupJoinApprovalResult) async throws -> V2GroupJoinApprovalPersistenceOutcome {
        switch value {
        case .approved(let row): return .approved(try await hydrate(row))
        case .alreadyDecided(let row): return .alreadyDecided(try await hydrate(row))
        case .conflict: return .conflict
        case .memberLimitReached: return .memberLimitReached
        case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
        case .unavailable: return .unavailable
        }
    }
    func hydrate(_ value: GroupJoinDecisionResult) async throws -> V2GroupJoinDecisionPreparationOutcome {
        switch value {
        case .rejected(let row): return .rejected(try await hydrate(row))
        case .alreadyApproved(let row): return .alreadyApproved(try await hydrate(row))
        case .alreadyRejected(let row): return .alreadyRejected(try await hydrate(row))
        case .decisionConflict: return .decisionConflict
        case .inviteExhausted: return .inviteExhausted
        }
    }
}

private func validateGroupInviteCreationClock(_ request: V2GroupInviteCreatePersistenceRequest) throws -> V2GroupInviteCreationTimestamps {
    guard let timestamps = request.persistedTimestamps,
          timestamps.createdAt.microseconds < timestamps.expiresAt.microseconds,
          v2PostgresTimestampCanEncode(request.evaluatedAt)
    else { throw V2GroupInvitationServiceError.corruptPersistenceState }
    return timestamps
}

/// Authoritative observation from an immutable owner receipt. Request outcomes
/// may advance to their terminal state; negative admission outcomes never change.
struct V2GroupJoinOwnerSubmission: Sendable {
    let outcome: V2GroupJoinQuotaOutcome
    let targetRequestID: UUID?
    let wasInserted: Bool
}

extension PostgresV2GroupInvitationStore {
    func applyReservedSubmission(_ intent: V2GroupJoinQuotaIntent, now: Date) async throws -> V2GroupJoinOwnerSubmission {
        guard intent.generation > 0, intent.tokenDigest.count == 32, intent.maximumPendingPerInvite > 0,
              v2PostgresTimestampCanEncode(now) else { throw V2GroupInvitationServiceError.invalidRequest }
        guard let scope, scope.roomID == intent.roomID, scope.inviteID == intent.inviteID else {
            throw V2GroupInvitationServiceError.conflict
        }
        let created = try V2PostgresTimestamp(date: intent.createdAt)
        let attempted = try V2PostgresTimestamp(date: intent.attemptCreatedAt)
        let active = try await isActive(.init(uuid: intent.applicantUserID))
        return try await v2WithPostgresTransactionRetry(database: database, maximumRetryCount: 0,
            classifyCommitFailure: activationScope != nil, useRoomDeadline: activationScope != nil) { transaction in
            let sql = try groupInviteSQL(transaction)
            try await lockSubmission(applicant: intent.applicantUserID, sql: sql)
            try validateInvite(invite: intent.inviteID, room: intent.roomID)
            if let prior = try await quotaReceipt(intent, sql: sql) {
                try prior.validate(intent, created: created, attempted: attempted)
                return try await observeQuotaReceipt(prior, sql: sql)
            }
            if let previous = try await sql.raw("""
                SELECT * FROM im_v2.group_join_submission_receipts
                WHERE applicant_user_id = \(bind: intent.applicantUserID) AND operation_id = \(bind: intent.operationID)
                ORDER BY generation DESC LIMIT 1
                """).first(decoding: GroupJoinQuotaReceiptRow.self) {
                guard previous.generation < Int64.max, intent.generation == previous.generation + 1,
                      previous.disposition != "request", previous.disposition != "already_member"
                else { throw V2GroupInvitationServiceError.conflict }
                try previous.validateBinding(intent, created: created)
            } else if intent.generation != 1 {
                throw V2GroupInvitationServiceError.conflict
            }
            // Global capacity was reserved in control. The ordinary local path
            // retains its own limit; reserved submissions use the global slot.
            let request = V2GroupJoinSubmissionPersistenceRequest(
                requestID: .init(uuid: intent.requestID), applicantUserID: .init(uuid: intent.applicantUserID),
                operationID: .init(uuid: intent.operationID), tokenDigest: intent.tokenDigest, note: intent.note,
                createdAt: intent.createdAt, maximumPendingRequestsPerApplicant: Int.max,
                maximumPendingRequestsPerInvite: intent.maximumPendingPerInvite)
            let disposition: String
            let target: UUID?
            var inserted = false
            do {
                let result = try await submitLocked(request, actorIsActive: active, evaluatedAt: now, sql: sql)
                switch result {
                case .submitted(let row): disposition = "request"; target = row.requestID; inserted = true
                case .alreadyPending(let row), .rejected(let row), .cancelled(let row): disposition = "request"; target = row.requestID
                case .alreadyMember(let preview):
                    if let requestID = preview.requestID?.uuidValue { disposition = "request"; target = requestID }
                    else { disposition = "already_member"; target = nil }
                case .unavailable: disposition = "unavailable"; target = nil
                case .rateLimited: disposition = "rate_limited"; target = nil
                }
            } catch V2GroupInvitationServiceError.permissionDenied {
                disposition = "permission_denied"; target = nil
            }
            try await sql.raw("""
                INSERT INTO im_v2.group_join_submission_receipts
                    (applicant_user_id, operation_id, generation, request_id, room_id, invite_id,
                     token_digest, note, maximum_pending_per_invite, intent_created_at, attempt_created_at,
                     disposition, target_request_id, recorded_at)
                VALUES (\(bind: intent.applicantUserID), \(bind: intent.operationID), \(bind: intent.generation),
                        \(bind: intent.requestID), \(bind: intent.roomID), \(bind: intent.inviteID),
                        \(bind: intent.tokenDigest), \(bind: intent.note), \(bind: intent.maximumPendingPerInvite),
                        \(bind: created), \(bind: attempted), \(bind: disposition), \(bind: target), \(bind: now))
                """).run()
            guard let receipt = try await quotaReceipt(intent, sql: sql) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            let observed = try await observeQuotaReceipt(receipt, sql: sql)
            return .init(outcome: observed.outcome, targetRequestID: observed.targetRequestID, wasInserted: inserted)
        }
    }

    /// Hydration is separate from the commit proof. Missing profile data or a
    /// lost response cannot erase the receipt or prevent recovery from reading it.
    func reservedSubmissionResponse(_ intent: V2GroupJoinQuotaIntent, observed: V2GroupJoinOwnerSubmission) async throws -> V2GroupJoinSubmissionPersistenceOutcome {
        switch observed.outcome {
        case .unavailable: return .unavailable
        case .rateLimited: return .rateLimited
        case .permissionDenied: throw V2GroupInvitationServiceError.permissionDenied
        default: break
        }
        let result: GroupJoinSubmissionResult = try await v2WithRoomScopedTransaction(database: database, useRoomDeadline: activationScope != nil) { transaction in
            let sql = try groupInviteSQL(transaction)
            try await fence(room: intent.roomID, sql: sql, shared: true)
            if let target = observed.targetRequestID {
                guard let row = try await requestByID(target, sql: sql), row.roomID == intent.roomID,
                      row.inviteID == intent.inviteID, row.applicantUserID == intent.applicantUserID
                else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                if observed.wasInserted, row.state == "pending" { return .submitted(row) }
                return try submissionOutcome(row)
            }
            guard observed.outcome == .alreadyMember, let invite = try await inviteByID(intent.inviteID, sql: sql),
                  invite.roomID == intent.roomID else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            return .alreadyMember(.init(inviteID: .init(uuid: intent.inviteID), roomID: .init(uuid: intent.roomID),
                roomTitle: invite.roomTitle, expiresAt: invite.expiresAt.date, requestState: nil, requestID: nil, isAlreadyMember: true))
        }
        return try await hydrate(result)
    }

    private func quotaReceipt(_ intent: V2GroupJoinQuotaIntent, sql: any SQLDatabase) async throws -> GroupJoinQuotaReceiptRow? {
        try await sql.raw("""
            SELECT * FROM im_v2.group_join_submission_receipts
            WHERE applicant_user_id = \(bind: intent.applicantUserID) AND operation_id = \(bind: intent.operationID)
              AND generation = \(bind: intent.generation)
            """).first(decoding: GroupJoinQuotaReceiptRow.self)
    }

    private func observeQuotaReceipt(_ receipt: GroupJoinQuotaReceiptRow, sql: any SQLDatabase) async throws -> V2GroupJoinOwnerSubmission {
        if receipt.disposition == "request" {
            guard let id = receipt.targetRequestID, let row = try await requestByID(id, sql: sql),
                  row.roomID == receipt.roomID, row.inviteID == receipt.inviteID,
                  row.applicantUserID == receipt.applicantUserID,
                  let outcome = V2GroupJoinQuotaOutcome(rawValue: row.state), outcome.requiresRequest
            else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            return .init(outcome: outcome, targetRequestID: id, wasInserted: false)
        }
        guard receipt.targetRequestID == nil, let outcome = V2GroupJoinQuotaOutcome(rawValue: receipt.disposition),
              !outcome.requiresRequest else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        return .init(outcome: outcome, targetRequestID: nil, wasInserted: false)
    }
}

private struct GroupJoinQuotaReceiptRow: Decodable {
    let applicantUserID, operationID, requestID, roomID, inviteID: UUID
    let generation: Int64
    let tokenDigest: Data
    let note: String?
    let maximumPendingPerInvite: Int
    let intentCreatedAt, attemptCreatedAt: V2PostgresTimestamp
    let disposition: String
    let targetRequestID: UUID?

    enum CodingKeys: String, CodingKey {
        case applicantUserID = "applicant_user_id", operationID = "operation_id", requestID = "request_id"
        case roomID = "room_id", inviteID = "invite_id", generation, tokenDigest = "token_digest", note
        case maximumPendingPerInvite = "maximum_pending_per_invite", intentCreatedAt = "intent_created_at"
        case attemptCreatedAt = "attempt_created_at", disposition, targetRequestID = "target_request_id"
    }
    func validateBinding(_ intent: V2GroupJoinQuotaIntent, created: V2PostgresTimestamp) throws {
        guard applicantUserID == intent.applicantUserID, operationID == intent.operationID,
              requestID == intent.requestID, roomID == intent.roomID, inviteID == intent.inviteID,
              tokenDigest == intent.tokenDigest, note == intent.note, maximumPendingPerInvite == intent.maximumPendingPerInvite,
              intentCreatedAt == created else { throw V2GroupInvitationServiceError.conflict }
    }
    func validate(_ intent: V2GroupJoinQuotaIntent, created: V2PostgresTimestamp, attempted: V2PostgresTimestamp) throws {
        try validateBinding(intent, created: created)
        guard generation == intent.generation, attemptCreatedAt == attempted else { throw V2GroupInvitationServiceError.conflict }
    }
}

private struct GroupInviteRoomBinding: Decodable {
    let roomID: UUID
    enum CodingKeys: String, CodingKey { case roomID = "room_id" }
}
