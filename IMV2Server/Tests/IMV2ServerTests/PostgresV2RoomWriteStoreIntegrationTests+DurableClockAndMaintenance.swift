@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Crypto
import FluentKit
import FluentPostgresDriver
import Foundation
import HTTPTypes
#if os(macOS)
import Darwin
#endif
import IMV2ActorContracts
import IMV2Core
import IMV2ServerHTTP
import PostgresNIO
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Synchronization
import Testing
import Vapor
import VaporTesting


extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("Personal event operator replay is audited, bounded and fences previous leases")
    func userStateOperatorReplay() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let source = EventID(uuid: UUID())
            let outbox = try PostgresV2UserStateEventOutbox(database: database)
            for _ in 0..<3 {
                let event = try V2UserStateEvent(sourceEventID: source, userID: .init(uuid: UUID()),
                    kind: .membership, payload: Data("{}".utf8), createdAt: now)
                try await outbox.enqueue(event, in: sql)
            }
            let leases = try await outbox.claim(now: now, leaseDuration: 30, limit: 10)
            #expect(leases.count == 3)
            for lease in leases { try await outbox.retry(lease, disposition: .pause) }
            let first = try #require(leases.first)
            let store = PostgresV2DurableWorkReplayStore(database: database)
            let command = V2DurableWorkReplayCommand(operationID: UUID(), target: try .init(
                kind: .userStateEvent, sourceEventID: source, targetUserID: first.event.userID,
                projectionKind: "membership"), reason: .dataRepaired)
            let result = try await store.replay(command, operatorPrincipal: "test-operator", now: now)
            #expect(result.outcome == .requeued && !result.wasIdempotent)
            #expect(try await store.replay(command, operatorPrincipal: "test-operator", now: now).wasIdempotent)
            #expect(try await outbox.acknowledge(first, sequence: 1, now: now) == false)
            let batch = try V2DurableWorkEventReplayCommand(operationID: UUID(), kind: .userStateEvent,
                sourceEventID: source, reason: .dataRepaired, limit: 1)
            let pageOne = try await store.replayEvent(batch, operatorPrincipal: "test-operator", now: now)
            #expect(pageOne.requeued == 1 && pageOne.hasMore)
            let pageTwo = try await store.replayEvent(batch, operatorPrincipal: "test-operator", now: now)
            #expect(pageTwo.requeued == 1 && !pageTwo.hasMore)
            #expect(try await store.replayEvent(batch, operatorPrincipal: "test-operator", now: now).requeued == 0)
            #expect(try await count("im_v2.durable_work_replay_audit WHERE target_kind = 'user_state_event' AND outcome = 'requeued'", on: sql) == 3)
            #expect(try await count("im_v2.user_state_event_outbox WHERE state = 'pending' AND attempt = 0 AND delivered_at IS NULL AND user_sync_sequence IS NULL", on: sql) == 3)
            let replacements = try await outbox.claim(now: now, leaseDuration: 30, limit: 10)
            #expect(replacements.count == 3)
            for replacement in replacements {
                #expect(replacement.attempt == 1)
                #expect(!leases.contains { $0.token == replacement.token })
            }
            for lease in leases {
                try await outbox.retry(lease, disposition: .pause)
                #expect(try await outbox.acknowledge(lease, sequence: 1, now: now) == false)
            }
            #expect(try await count("im_v2.user_state_event_outbox WHERE state = 'leased'", on: sql) == 3)
            let conflict = V2DurableWorkReplayCommand(operationID: command.operationID, target: command.target,
                reason: .falsePositive)
            await #expect(throws: V2DurableWorkReplayStoreError.idempotencyConflict) {
                _ = try await store.replay(conflict, operatorPrincipal: "test-operator", now: now)
            }
        }
    }

    @Test("Durable replay audit clocks preserve not-paused results at database bounds", arguments: [946_684_800.0 - 211_813_488_000, 1_750_000_000.0, 946_684_800.0 + 9_223_371_331_200 - 10])
    func durableReplayAuditClockBounds(seconds: Double) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: seconds)
            let store = PostgresV2DurableWorkReplayStore(database: database)
            for kind in V2DurableWorkReplayTargetKind.allCases {
                let needsUser = kind == .userStateEvent || kind == .readReceiptPreferencePropagation || kind == .userProjection
                let target = try V2DurableWorkReplayTarget(kind: kind, sourceEventID: .init(uuid: UUID()), targetUserID: needsUser ? senderID : nil, projectionKind: kind == .userStateEvent ? "membership" : nil)
                let command = V2DurableWorkReplayCommand(operationID: UUID(), target: target, reason: .dependencyRecovered)
                let result = try await verifyDurableReplayClockRecovery(command, store: store, sql: sql, operatorPrincipal: "clock-replay", now: now, expected: .notPaused)
                #expect(result.outcome == .notPaused && !result.wasIdempotent)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.durable_work_replay_audit WHERE operation_id = \(bind: command.operationID) AND requested_at = \(bind: now)").first(decoding: CountRow.self)?.value == 1)
            }
            #expect(try await count("im_v2.durable_work_replay_audit WHERE outcome = 'not_paused'", on: sql) == Int64(V2DurableWorkReplayTargetKind.allCases.count))
            #expect(try await count("im_v2.durable_work_replay_audit WHERE outcome = 'processing'", on: sql) == 0)
        }
    }

    @Test("Invitation business clocks reject partial writes and preserve committed retries", arguments: ["approve", "reject"])
    func invitationStoreClockBounds(decision: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let applicant = UserID(uuid: UUID())
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            try await sql.raw("INSERT INTO im_v2.public_user_profiles (user_id, public_handle, display_name, created_at, updated_at) VALUES (\(bind: applicant.uuidValue!), 'invitation_clock_applicant', 'Clock Applicant', \(bind: base), \(bind: base))").run()
            let store = PostgresV2GroupInvitationStore(database: database)
            let profile = try forwardImportTestProfile()
            let inviteID = GroupInviteID(uuid: UUID())
            let creationID = GroupInviteOperationID(uuid: UUID())
            let submissionID = GroupJoinRequestOperationID(uuid: UUID())
            let requestID = GroupJoinRequestID(uuid: UUID())
            let decisionID = GroupJoinDecisionOperationID(uuid: UUID())
            let revocationID = GroupInviteOperationID(uuid: UUID())
            let digest = Data(repeating: 0x73, count: 32)
            func creation(createdAt: Date? = nil, evaluatedAt: Date? = nil, expiresAt: Date? = nil) -> V2GroupInviteCreatePersistenceRequest {
                .init(inviteID: inviteID, roomID: roomID, actorUserID: senderID, operationID: creationID, tokenDigest: digest, requestedLifetimeSeconds: 3600, expiresAt: expiresAt ?? base.addingTimeInterval(3600), maximumApprovedUses: 5, maximumActiveInvitesPerRoom: 20, createdAt: createdAt ?? base, evaluatedAt: evaluatedAt ?? base)
            }
            func submit(at date: Date, actor: UserID? = nil, freshIdentity: Bool = false) async throws -> V2GroupInvitationOperationRecoveryResult {
                let actor = actor ?? applicant
                // Validate the deliberately corrupted invitation before acquiring a
                // control quota reservation that has no owner execution to resolve.
                if freshIdentity { _ = try await store.activeInvites(roomID: roomID, actorUserID: senderID, now: date) }
                let operation = freshIdentity ? GroupJoinRequestOperationID(uuid: UUID()) : submissionID
                let intent = try V2GroupInvitationOperationIntent(identity: .init(accountID: actor, scope: .room(roomID),
                    operation: .groupJoinRequest(operation)), action: .submit(inviteID: inviteID, tokenDigest: digest, note: "clock test"),
                    confirmedUntilMilliseconds: 1_750_000_120_000)
                let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 0x73, count: 32))
                let operations = invitationOperationPort(control: database, owner: database, issuer: issuer,
                    capacityProfile: profile, now: { date })
                switch try await operations.admit(intent, invitationTestDeadline()) {
                case .terminal(let proof):
                    try #require(proof.validates(intent: intent))
                    return .receipt(proof)
                case .admitted(let admission):
                    let request = V2GroupJoinSubmissionPersistenceRequest(requestID: freshIdentity ? .init(uuid: UUID()) : requestID, applicantUserID: actor,
                        operationID: operation, tokenDigest: digest, note: "clock test", createdAt: date,
                        maximumPendingRequestsPerApplicant: 20, maximumPendingRequestsPerInvite: 100)
                    guard case .reserved(let quota) = try await PostgresV2GroupJoinQuotaStore(database: database)
                        .reserve(request, roomID: roomID, inviteID: inviteID, now: date) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                    let command = try V2GroupInvitationOperationCommand(intent: intent, admission: admission)
                    let result = try await operations.submit(.init(command: command, quotaIntent: .init(domain: quota)), invitationTestDeadline())
                    if case .receipt(let proof) = result { try #require(proof.validates(intent: intent)) }
                    return result
                default: throw V2GroupInvitationServiceError.corruptPersistenceState
                }
            }
            func approve(at date: Date) async throws -> V2GroupJoinApprovalPersistenceOutcome {
                try await store.approve(roomID: roomID, requestID: requestID, reviewerUserID: senderID, operationID: decisionID, capacityProfile: profile, eventID: .init(uuid: UUID()), now: date)
            }
            func reject(at date: Date) async throws -> V2GroupJoinDecisionPreparationOutcome {
                try await store.reject(roomID: roomID, requestID: requestID, reviewerUserID: senderID, operationID: decisionID, now: date)
            }
            func snapshot() async throws -> String {
                try #require(try await sql.raw("""
                    SELECT jsonb_build_object(
                        'room', (SELECT to_jsonb(r) FROM im_v2.rooms r WHERE room_id = \(bind: roomUUID)),
                        'admission', (SELECT to_jsonb(r) FROM im_v2.room_admission r WHERE room_id = \(bind: roomUUID)),
                        'shard', (SELECT to_jsonb(r) FROM im_v2.shard_admission_pools r WHERE room_shard_id = 'room-a'),
                        'members', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id, joined_revision) FROM im_v2.room_memberships r),
                        'invites', (SELECT jsonb_agg(to_jsonb(r) ORDER BY invite_id) FROM im_v2.group_invite_links r),
                        'requests', (SELECT jsonb_agg(to_jsonb(r) ORDER BY request_id) FROM im_v2.group_join_requests r),
                        'events', (SELECT count(*) FROM im_v2.room_events),
                        'operations', (SELECT count(*) FROM im_v2.room_membership_operations)
                    )::text AS value
                    """).first(decoding: StringValueRow.self)).value
            }
            let badDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            let initial = try await snapshot()
            for bad in badDates {
                for request in [creation(createdAt: bad), creation(evaluatedAt: bad), creation(expiresAt: bad)] {
                    await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { _ = try await store.preflightCreation(request) }
                    await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { _ = try await store.create(request) }
                }
            }
            for request in [creation(expiresAt: base), creation(expiresAt: base.addingTimeInterval(-1)), creation(createdAt: Date(timeIntervalSince1970: 946_684_800.00000025), expiresAt: Date(timeIntervalSince1970: 946_684_800.00000075))] {
                await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { _ = try await store.preflightCreation(request) }
                await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { _ = try await store.create(request) }
            }
            #expect(try await snapshot() == initial)
            let invite = try await store.create(creation())
            #expect(invite.state == .active && invite.inviteID == inviteID)
            let invalidStoredTimes = ["infinity", "-infinity", "294276-12-31 23:59:59.999999+00"]
            for column in ["created_at", "expires_at"] {
                let literals = column == "created_at" ? ["-infinity", "294276-12-31 23:59:59.999999+00"] : ["infinity", "294276-12-31 23:59:59.999999+00"]
                for literal in literals {
                    // Preserve the production expiry > creation constraint.
                    try await sql.raw("UPDATE im_v2.group_invite_links SET created_at = \(bind: base), expires_at = \(bind: invite.expiresAt) WHERE invite_id = \(bind: inviteID.uuidValue!)").run()
                    if column == "created_at" && literal != "-infinity" {
                        try await sql.raw("UPDATE im_v2.group_invite_links SET created_at = \(bind: literal)::timestamptz, expires_at = 'infinity'::timestamptz WHERE invite_id = \(bind: inviteID.uuidValue!)").run()
                    } else {
                        try await sql.raw("UPDATE im_v2.group_invite_links SET \(unsafeRaw: column) = \(bind: literal)::timestamptz WHERE invite_id = \(bind: inviteID.uuidValue!)").run()
                    }
                    let before = try await snapshot()
                    await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { try await store.create(creation()) }
                    await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { try await store.preflightCreation(creation()) }
                    do {
                        await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { try await store.activeInvites(roomID: roomID, actorUserID: senderID, now: base) }
                        if column == "expires_at" {
                            await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { try await store.preview(tokenDigest: digest, applicantUserID: applicant, now: base) }
                            await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { try await submit(at: base, freshIdentity: true) }
                            await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) {
                                try await submit(at: base, actor: senderID, freshIdentity: true)
                            }
                        }
                    }
                    try #require(try await snapshot() == before)
                }
                try await sql.raw("UPDATE im_v2.group_invite_links SET created_at = \(bind: base), expires_at = \(bind: invite.expiresAt) WHERE invite_id = \(bind: inviteID.uuidValue!)").run()
            }
            let created = try await snapshot()
            for bad in badDates {
                await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { _ = try await store.activeInvites(roomID: roomID, actorUserID: senderID, now: bad) }
                await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { _ = try await store.preview(tokenDigest: digest, applicantUserID: applicant, now: bad) }
                await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { _ = try await store.create(creation(evaluatedAt: bad)) }
                await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { _ = try await store.preflightCreation(creation(evaluatedAt: bad)) }
                await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { _ = try await submit(at: bad) }
                await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { try await store.revoke(inviteID: inviteID, roomID: roomID, actorUserID: senderID, operationID: revocationID, now: bad) }
                // Invalid replacement candidates do not replace a committed binding.
                let replay = try await store.create(creation(createdAt: bad, expiresAt: bad))
                #expect(replay.inviteID == inviteID && replay.createdAt == base && replay.expiresAt == invite.expiresAt)
                #expect(try await store.preflightCreation(creation(createdAt: bad, expiresAt: bad))?.inviteID == inviteID)
            }
            #expect(try await snapshot() == created)
            #expect(try await store.activeInvites(roomID: roomID, actorUserID: senderID, now: base).count == 1)
            guard case .available = try await store.preview(tokenDigest: digest, applicantUserID: applicant, now: base) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            guard case .receipt(let submissionProof) = try await submit(at: base.addingTimeInterval(10)),
                  case .applied(.requestSubmitted(let originalRequest, _)) = submissionProof.outcome else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            #expect(originalRequest == requestID)
            let pending = try #require(try await store.pendingRequests(roomID: roomID, reviewerUserID: senderID,
                cursor: nil, pageSize: 10, now: base).requests.first)
            #expect(pending.requestID == requestID && pending.state == .pending)
            for literal in invalidStoredTimes {
                try await sql.raw("UPDATE im_v2.group_join_requests SET created_at = \(bind: literal)::timestamptz WHERE request_id = \(bind: requestID.uuidValue!)").run()
                let before = try await snapshot()
                await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { try await store.pendingRequests(roomID: roomID, reviewerUserID: senderID, cursor: nil, pageSize: 10, now: base) }
                // Canonical submission proof remains authoritative despite a corrupt
                // mutable display record; a fresh ID cannot rewrite the existing request.
                guard case .receipt(let proof) = try await submit(at: base, freshIdentity: true) else { throw CancellationError() }
                #expect(proof.outcome == .alreadySatisfied(.requestSubmitted(requestID: requestID, inviteID: inviteID)))
                await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { try await approve(at: base.addingTimeInterval(20)) }
                try #require(try await snapshot() == before)
                await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { try await reject(at: base.addingTimeInterval(20)) }
                try #require(try await snapshot() == before)
            }
            try await sql.raw("UPDATE im_v2.group_join_requests SET created_at = \(bind: pending.createdAt) WHERE request_id = \(bind: requestID.uuidValue!)").run()
            let submitted = try await snapshot()
            for bad in badDates {
                await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { _ = try await approve(at: bad) }
                await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { _ = try await reject(at: bad) }
                // The original committed proof replays before evaluating replacement clocks.
                #expect(try await submit(at: bad) == .receipt(submissionProof))
                let page = try await store.pendingRequests(roomID: roomID, reviewerUserID: senderID, cursor: nil, pageSize: 10, now: bad)
                #expect(page.requests == [pending] && page.nextCursor == nil)
            }
            #expect(try await snapshot() == submitted)
            if decision == "approve" {
                guard case .approved(let result) = try await approve(at: base.addingTimeInterval(20)) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                #expect(result.state == .approved && result.decidedAt == base.addingTimeInterval(20))
                let completed = try await snapshot()
                for bad in badDates {
                    #expect(try await approve(at: bad) == .approved(result))
                    #expect(try await reject(at: bad) == .decisionConflict)
                }
                #expect(try await snapshot() == completed)
            } else {
                guard case .rejected(let result) = try await reject(at: base.addingTimeInterval(20)) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                #expect(result.state == .rejected && result.decidedAt == base.addingTimeInterval(20))
                let completed = try await snapshot()
                for bad in badDates {
                    #expect(try await reject(at: bad) == .rejected(result))
                    #expect(try await approve(at: bad) == .conflict)
                }
                #expect(try await snapshot() == completed)
            }
            func completedResponse() async throws -> V2GroupJoinRequestRecord {
                if decision == "approve" {
                    guard case .approved(let value) = try await approve(at: base) else { throw CancellationError() }
                    return value
                }
                guard case .rejected(let value) = try await reject(at: base) else { throw CancellationError() }
                return value
            }
            let originalResult = try await completedResponse()
            for column in ["created_at", "decided_at"] {
                for literal in invalidStoredTimes {
                    try await sql.raw("UPDATE im_v2.group_join_requests SET \(unsafeRaw: column) = \(bind: literal)::timestamptz WHERE request_id = \(bind: requestID.uuidValue!)").run()
                    let before = try await snapshot()
                    await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { try await completedResponse() }
                    if decision == "approve" { #expect(try await reject(at: base) == .decisionConflict) }
                    else {
                        #expect(try await approve(at: base) == .conflict)
                        guard case .receipt(let proof) = try await submit(at: base, freshIdentity: true) else { throw CancellationError() }
                        #expect(proof.outcome == .rejected(.requestAlreadyDecided))
                    }
                    #expect(try await snapshot() == before)
                }
                for date in [Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000),
                             Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)] {
                    try await sql.raw("UPDATE im_v2.group_join_requests SET \(unsafeRaw: column) = \(bind: date) WHERE request_id = \(bind: requestID.uuidValue!)").run()
                    let before = try await snapshot()
                    let value = try await completedResponse()
                    #expect((column == "created_at" ? value.createdAt : value.decidedAt) == date)
                    #expect(value.requestID == originalResult.requestID && value.state == originalResult.state)
                    #expect(try await snapshot() == before)
                }
                let restored = column == "created_at" ? originalResult.createdAt : try #require(originalResult.decidedAt)
                try await sql.raw("UPDATE im_v2.group_join_requests SET \(unsafeRaw: column) = \(bind: restored) WHERE request_id = \(bind: requestID.uuidValue!)").run()
            }
            if decision == "approve" {
                for literal in ["infinity", "294276-12-31 23:59:59.999999+00"] {
                    try await sql.raw("UPDATE im_v2.group_invite_links SET expires_at = \(bind: literal)::timestamptz WHERE invite_id = \(bind: inviteID.uuidValue!)").run()
                    let before = try await snapshot()
                    await #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { try await submit(at: base, freshIdentity: true) }
                    #expect(try await snapshot() == before)
                }
                try await sql.raw("UPDATE im_v2.group_invite_links SET expires_at = \(bind: invite.expiresAt) WHERE invite_id = \(bind: inviteID.uuidValue!)").run()
            }
            #expect(try await count("im_v2.room_membership_operations", on: sql) == (decision == "approve" ? 1 : 0))
            #expect(try await sql.raw("SELECT approved_use_count::bigint AS value FROM im_v2.group_invite_links").first(decoding: CountRow.self)?.value == (decision == "approve" ? 1 : 0))
            // Exact expiry remains a normal business result, not a clock error.
            #expect(try await store.create(creation(evaluatedAt: invite.expiresAt)).state == .expired)
            #expect(try await store.activeInvites(roomID: roomID, actorUserID: senderID, now: invite.expiresAt).isEmpty)
            #expect(try await store.preview(tokenDigest: digest, applicantUserID: applicant, now: invite.expiresAt) == .unavailable)
            try await store.revoke(inviteID: inviteID, roomID: roomID, actorUserID: senderID, operationID: revocationID, now: base.addingTimeInterval(30))
            let revoked = try await snapshot()
            for bad in badDates {
                try await store.revoke(inviteID: inviteID, roomID: roomID, actorUserID: senderID, operationID: revocationID, now: bad)
                #expect(try await store.create(creation(evaluatedAt: bad)).state == .revoked)
            }
            #expect(try await snapshot() == revoked)
        }
    }

    @Test("Invite creation clocks retain recoverable work and preserve published bindings", arguments: ["resume", "retry", "pause"])
    func inviteCreationClockBounds(phase: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, sql, ownerSQL, room in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            try await ownerSQL.raw("DELETE FROM im_v2.public_user_profiles").run()
            let directory = PostgresV2GroupInviteDirectory(database: control)
            let operation = GroupInviteOperationID(uuid: UUID())
            // Production path: the control coordinator with a room turn on the
            // owner. The intent carries the digest issued for its operation.
            let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 0x65, count: 32))
            let digest = issuer.digest(try issuer.secret(actorUserID: .init(uuid: senderUUID), operationID: operation))
            let clock = TestSequenceClock([base])
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let coordinator = V2ActorInvitationCoordinator(controlDatabase: control,
                room: invitationRoomPort(control: control, owner: owner, shardID: "room-b", capacityProfile: profile, now: { clock.now() }),
                operations: invitationOperationPort(control: control, owner: owner, shardID: "room-b", issuer: issuer, capacityProfile: profile, now: { clock.now() }),
                secretIssuer: issuer, now: { clock.now() })
            let baseline = try await coordinator.operationBaseline(roomID: room, actorUserID: senderID, deadline: invitationTestDeadline())
            let frozenIntent = try V2GroupInvitationOperationIntent(identity: .init(accountID: senderID, scope: .room(room), operation: .groupInvite(operation)),
                action: .create(lifetimeSeconds: 3600, maximumApprovedUses: 5, expectedMembershipRevision: baseline.membershipRevision),
                confirmedUntilMilliseconds: UInt64(base.timeIntervalSince1970 * 1000) + 120_000)
            guard case .admitted(let admission) = try await coordinator.admitOperation(.init(intent: frozenIntent), deadline: invitationTestDeadline()) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            let command = try V2GroupInvitationOperationCommand(intent: frozenIntent, admission: admission)
            let original = try v2GroupInvitationCreationRequest(command, issuer: issuer, policy: .standard, now: base)
            let invite = original.inviteID
            func candidate(createdAt: Date? = nil, evaluatedAt: Date? = nil, expiresAt: Date? = nil) -> V2GroupInviteCreatePersistenceRequest {
                .init(inviteID: invite, roomID: room, actorUserID: .init(uuid: senderUUID), operationID: operation, tokenDigest: digest, requestedLifetimeSeconds: 3600, expiresAt: expiresAt ?? base.addingTimeInterval(3600), maximumApprovedUses: 5, maximumActiveInvitesPerRoom: 20, createdAt: createdAt ?? base, evaluatedAt: evaluatedAt ?? base)
            }
            func snapshot() async throws -> [String] {
                struct State: Decodable { let value: String }
                let controlState = try #require(try await sql.raw("""
                    SELECT jsonb_build_object(
                        'directory', (SELECT jsonb_agg(to_jsonb(r) ORDER BY operation_id) FROM im_v2.group_invite_directory r),
                        'jobs', (SELECT jsonb_agg(to_jsonb(r) ORDER BY operation_id) FROM im_v2.group_invite_creation_recovery r)
                    )::text AS value
                    """).first(decoding: State.self)).value
                let ownerState = try #require(try await ownerSQL.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY invite_id), '[]'::jsonb)::text AS value FROM im_v2.group_invite_links r").first(decoding: State.self)).value
                return [controlState, ownerState]
            }
            let invalidDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            let nearUpperBound = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)
            let initial = try await snapshot()
            for bad in invalidDates {
                for request in [candidate(createdAt: bad), candidate(evaluatedAt: bad), candidate(expiresAt: bad)] {
                    await #expect(throws: V2GroupInviteDirectoryError.invalidRequest) { _ = try await directory.prepare(request) }
                }
            }
            for request in [candidate(evaluatedAt: nearUpperBound), candidate(expiresAt: base), candidate(expiresAt: base.addingTimeInterval(-1)), candidate(createdAt: Date(timeIntervalSince1970: 946_684_800.00000025), expiresAt: Date(timeIntervalSince1970: 946_684_800.00000075))] {
                await #expect(throws: V2GroupInviteDirectoryError.invalidRequest) { _ = try await directory.prepare(request) }
            }
            #expect(try await snapshot() == initial)
            try await PostgresV2GroupInvitationControlCommandStore(database: control).save(command)
            let intent = try await directory.prepare(candidate())
            let prepared = try await snapshot()
            for bad in invalidDates {
                await #expect(throws: V2GroupInviteDirectoryError.invalidRequest) { _ = try await directory.claim(limit: 1, now: bad, lease: 60, maximumActiveInvitesPerRoom: 20) }
                await #expect(throws: V2GroupInviteDirectoryError.invalidRequest) { try await directory.finalize(intent, now: bad) }
            }
            for duration in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, .leastNonzeroMagnitude, 1e-9, 0, -1, 301] {
                await #expect(throws: V2GroupInviteDirectoryError.invalidRequest) { _ = try await directory.claim(limit: 1, now: base, lease: duration, maximumActiveInvitesPerRoom: 20) }
            }
            await #expect(throws: V2GroupInviteDirectoryError.invalidRequest) { _ = try await directory.claim(limit: 1, now: nearUpperBound, lease: 60, maximumActiveInvitesPerRoom: 20) }
            #expect(try await snapshot() == prepared)
            #expect(try await directory.claim(limit: 1, now: base.addingTimeInterval(29), lease: 60, maximumActiveInvitesPerRoom: 20).isEmpty)
            let first = try #require(try await directory.claim(limit: 1, now: base.addingTimeInterval(30), lease: 60, maximumActiveInvitesPerRoom: 20).first)
            #expect(first.attemptCount == 1)
            let claimed = try await snapshot()
            for bad in invalidDates {
                await #expect(throws: V2GroupInviteDirectoryError.invalidRequest) { _ = try await directory.fail(first, reason: .dependencyUnavailable, retryAt: bad, now: base.addingTimeInterval(31)) }
                await #expect(throws: V2GroupInviteDirectoryError.invalidRequest) { _ = try await directory.fail(first, reason: .permissionDenied, retryAt: nil, now: bad) }
            }
            for retry in [base, base.addingTimeInterval(31)] {
                await #expect(throws: V2GroupInviteDirectoryError.invalidRequest) { _ = try await directory.fail(first, reason: .dependencyUnavailable, retryAt: retry, now: base.addingTimeInterval(31)) }
            }
            await #expect(throws: V2GroupInviteDirectoryError.invalidRequest) {
                _ = try await directory.fail(first, reason: .dependencyUnavailable, retryAt: Date(timeIntervalSince1970: 946_684_800.00000075), now: Date(timeIntervalSince1970: 946_684_800.00000025))
            }
            #expect(try await snapshot() == claimed)
            #expect(try await directory.claim(limit: 1, now: base.addingTimeInterval(89), lease: 60, maximumActiveInvitesPerRoom: 20).isEmpty)
            let second = try #require(try await directory.claim(limit: 1, now: base.addingTimeInterval(90), lease: 60, maximumActiveInvitesPerRoom: 20).first)
            #expect(second.attemptCount == 2 && second.claimToken != first.claimToken)
            let reclaimed = try await snapshot()
            #expect(try await !directory.fail(first, reason: .permissionDenied, retryAt: nil, now: base.addingTimeInterval(91)))
            #expect(try await snapshot() == reclaimed)
            #expect(try await directory.fail(second, reason: .dependencyUnavailable, retryAt: base.addingTimeInterval(105), now: base.addingTimeInterval(91)))
            #expect(try await directory.claim(limit: 1, now: base.addingTimeInterval(104), lease: 60, maximumActiveInvitesPerRoom: 20).isEmpty)
            struct FailingResumer: V2GroupInviteCreationResuming {
                let shouldPause: Bool
                func resumeCreation(_ intent: V2GroupInviteCreationIntent, now: Date) async throws {
                    if shouldPause { throw V2GroupInvitationServiceError.permissionDenied }
                    throw ProfilePropagationShadowFailure.interrupted
                }
            }
            let worker = phase == "resume"
                ? V2GroupInviteCreationRecoveryWorker(jobs: directory, coordinator: coordinator, deadline: invitationTestDeadline, now: { clock.now() })
                : V2GroupInviteCreationRecoveryWorker(jobs: directory, invitations: FailingResumer(shouldPause: phase == "pause"), now: { clock.now() })
            let attemptDates = phase == "pause" ? invalidDates : invalidDates + [nearUpperBound]
            for (index, bad) in attemptDates.enumerated() {
                let time = base.addingTimeInterval(105 + Double(index) * 60)
                clock.set(phase == "resume" ? [time, bad] : [time, time, bad])
                await #expect(throws: V2GroupInviteDirectoryError.invalidRequest) { _ = try await worker.runOnce(limit: 1) }
                #expect(try await count("im_v2.group_invite_creation_recovery WHERE state = 'claimed' AND completed_at IS NULL AND last_error_code = 'dependency_unavailable'", on: sql) == 1)
                #expect(try await sql.raw("SELECT attempt_count AS value FROM im_v2.group_invite_creation_recovery").first(decoding: CountRow.self)?.value == Int64(index + 3))
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_creation_recovery WHERE lease_expires_at = \(bind: time.addingTimeInterval(60))").first(decoding: CountRow.self)?.value == 1)
                #expect(try await count("im_v2.group_invite_directory WHERE state = 'prepared'", on: sql) == 1)
                #expect(try await count("im_v2.group_invite_links", on: ownerSQL) == 0)
            }
            // The original operation recovers through the real current owner.
            // Its immutable creation/expiry dates are not replaced by retries.
            clock.set([base.addingTimeInterval(1000)])
            let healthy = V2GroupInviteCreationRecoveryWorker(jobs: directory, coordinator: coordinator, deadline: invitationTestDeadline, now: { clock.now() })
            let report = try await healthy.runOnce()
            #expect(report.attempted == 1 && report.completed == 1 && report.deferred == 0 && report.paused == 0 && report.lostClaim == 0)
            #expect(try await healthy.runOnce().attempted == 0)
            #expect(try await directory.resolve(tokenDigest: digest) == nil)
            #expect(try await count("im_v2.group_invite_links", on: ownerSQL) == 0)
            #expect(try await count("im_v2.group_invite_creation_recovery WHERE state = 'completed'", on: sql) == 1)
            clock.set([base.addingTimeInterval(1001)])
            guard case .receipt(let replay) = try await coordinator.recoverOperation(.init(intent: frozenIntent, action: .query), deadline: invitationTestDeadline()) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            #expect(replay.validates(intent: frozenIntent) && replay.outcome == .rejected(.admissionExpired))
            let completed = try await snapshot()
            #expect(try await !directory.fail(second, reason: .permissionDenied, retryAt: nil, now: base.addingTimeInterval(1001)))
            #expect(try await snapshot() == completed)
        }
    }

    @Test("Content review clocks preserve leases, retry recovery and durable decisions", arguments: ["clear", "review", "violation", "superseded"])
    func contentReviewClockBounds(scenario: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until = \(bind: base.addingTimeInterval(2000))").run()
            let sender = try V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                store: PostgresV2RoomWriteStore(database: database), shardID: "room-a", epoch: 0), capacityProfile: profile, limits: .init(maxUTF8Bytes: 64), now: { base })
            guard case .accepted(let message) = try await sender.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "review clock boundary")) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let store = PostgresV2ContentReviewStore(database: database)
            let finding = try V2ContentReviewFinding(category: "clock_policy", severity: 2, confidence: 0.8)
            func snapshot() async throws -> String {
                struct State: Decodable { let value: String }
                return try #require(try await sql.raw("""
                    SELECT jsonb_build_object(
                        'jobs', (SELECT jsonb_agg(to_jsonb(r) ORDER BY message_id) FROM im_v2.content_review_jobs r),
                        'decisions', (SELECT jsonb_agg(to_jsonb(r) ORDER BY message_id) FROM im_v2.content_review_decisions r),
                        'findings', (SELECT jsonb_agg(to_jsonb(r) ORDER BY message_id, category) FROM im_v2.content_review_findings r),
                        'cases', (SELECT jsonb_agg(to_jsonb(r) ORDER BY message_id) FROM im_v2.content_review_cases r),
                        'messages', (SELECT jsonb_agg(to_jsonb(r) ORDER BY message_id) FROM im_v2.messages r),
                        'moderation', (SELECT jsonb_agg(to_jsonb(r) ORDER BY operation_id) FROM im_v2.moderation_operations r)
                    )::text AS value
                    """).first(decoding: State.self)).value
            }
            let badDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            let initial = try await snapshot()
            for invalid in badDates {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.claimPending(now: invalid, leaseDuration: 30, limit: 1) }
            }
            for duration in [Double.infinity, .greatestFiniteMagnitude, .leastNonzeroMagnitude, 0.000000001] {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.claimPending(now: base, leaseDuration: duration, limit: 1) }
            }
            let upper = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)
            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.claimPending(now: upper, leaseDuration: 30, limit: 1) }
            #expect(try await store.claimPending(now: badDates[0], leaseDuration: 30, limit: 0).isEmpty)
            #expect(try await snapshot() == initial)
            let first = try #require(try await store.claimPending(now: base, leaseDuration: 30, limit: 1).first)
            let claimed = try await snapshot()
            for invalid in badDates {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.validateAndRenew(first, now: invalid, leaseDuration: 30) }
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.resolve(first, verdict: .reviewRequired(finding), now: invalid) }
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.scheduleRetry(first, disposition: .retry(at: invalid), now: base) }
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.scheduleRetry(first, disposition: .pause, now: invalid) }
                #expect(try await snapshot() == claimed)
            }
            for duration in [Double.infinity, .greatestFiniteMagnitude, .leastNonzeroMagnitude, 0.000000001] {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.validateAndRenew(first, now: base, leaseDuration: duration) }
            }
            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.validateAndRenew(first, now: upper, leaseDuration: 30) }
            #expect(try await snapshot() == claimed)
            #expect(try await store.validateAndRenew(first, now: base.addingTimeInterval(-20), leaseDuration: 30) == .current)
            #expect(try await sql.raw("SELECT lease_expires_at = \(bind: base.addingTimeInterval(30)) AS exists FROM im_v2.content_review_jobs").first(decoding: ExistsRow.self)?.exists == true)
            #expect(try await store.validateAndRenew(first, now: base.addingTimeInterval(5), leaseDuration: 30) == .current)
            #expect(try await store.validateAndRenew(first, now: base.addingTimeInterval(1), leaseDuration: 1) == .current)
            #expect(try await store.claimPending(now: base.addingTimeInterval(34), leaseDuration: 30, limit: 1).isEmpty)
            let second = try #require(try await store.claimPending(now: base.addingTimeInterval(35), leaseDuration: 30, limit: 1).first)
            #expect(second.claimToken != first.claimToken && second.attempt == 2)
            let reclaimed = try await snapshot()
            #expect(try await store.validateAndRenew(first, now: base.addingTimeInterval(36), leaseDuration: 30) == .lostLease)
            #expect(try await store.resolve(first, verdict: .clear, now: base.addingTimeInterval(36)) == false)
            #expect(try await store.stageViolation(first, finding: finding) == false)
            try await store.scheduleRetry(first, disposition: .retry(at: base), now: badDates[0])
            #expect(try await snapshot() == reclaimed)
            if scenario == "superseded" {
                try await sql.raw("UPDATE im_v2.messages SET content_revision = 2 WHERE message_id = \(bind: message.messageID.uuidValue!)").run()
                let edited = try await snapshot()
                for invalid in badDates {
                    await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.validateAndRenew(second, now: invalid, leaseDuration: 30) }
                    #expect(try await snapshot() == edited)
                }
                #expect(try await store.validateAndRenew(second, now: base.addingTimeInterval(36), leaseDuration: 30) == .superseded)
                #expect(try await count("im_v2.content_review_jobs WHERE state = 'superseded' AND claim_token IS NULL AND completed_at IS NOT NULL", on: sql) == 1)
                #expect(try await count("im_v2.content_review_decisions", on: sql) == 0)
                return
            }
            try await store.scheduleRetry(second, disposition: .retry(at: base.addingTimeInterval(-1)), now: badDates[0])
            let retry = try #require(try await store.claimPending(now: base.addingTimeInterval(35), leaseDuration: 30, limit: 1).first)
            #expect(retry.attempt == 3)
            try await store.scheduleRetry(retry, disposition: .pause, now: base.addingTimeInterval(36))
            #expect(try await store.claimPending(now: base.addingTimeInterval(100), leaseDuration: 30, limit: 1).isEmpty)
            let replay = try await verifyDurableReplayClockRecovery(.init(operationID: UUID(), target: .init(kind: .contentReview, sourceEventID: .init(message.messageID.rawValue)), reason: .dependencyRecovered), store: PostgresV2DurableWorkReplayStore(database: database), sql: sql, operatorPrincipal: "integration-test", now: base.addingTimeInterval(40))
            #expect(replay.outcome == .requeued)
            let clock = TestSequenceClock([base])
            let moderation = V2TrustedSafetyModerationService(store: PostgresV2ModerationStore(database: database), safetyActorUserID: .init(uuid: UUID()), capacityProfile: profile, now: { clock.now() })
            struct Reviewer: V2ContentReviewing {
                let verdict: V2ContentReviewVerdict
                func review(_ input: V2ContentReviewInput) async throws -> V2ContentReviewVerdict { verdict }
            }
            let clearingWorker = try V2ContentReviewWorker(store: store, reviewer: Reviewer(verdict: .clear), moderation: moderation, retryPolicy: .init(initialDelay: 2, maximumDelay: 2, maximumAttempts: 100, jitterFraction: 0), now: { clock.now() })
            for (index, invalid) in badDates.enumerated() {
                for phase in 0..<2 {
                    let time = base.addingTimeInterval(100 + Double(index * 80 + phase * 40))
                    clock.set(phase == 0 ? [time, invalid] : [time, time, invalid])
                    await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await clearingWorker.runOnce(limit: 1) }
                    #expect(try await sql.raw("SELECT state = 'claimed' AND retry_count = \(bind: Int64(index * 2 + phase + 1)) AND lease_expires_at = \(bind: time.addingTimeInterval(30)) AND completed_at IS NULL AND decision IS NULL AS exists FROM im_v2.content_review_jobs").first(decoding: ExistsRow.self)?.exists == true)
                    #expect(try await count("im_v2.content_review_decisions", on: sql) == 0)
                    #expect(try await count("im_v2.content_review_findings", on: sql) == 0)
                    #expect(try await count("im_v2.content_review_cases", on: sql) == 0)
                    #expect(try await count("im_v2.moderation_operations", on: sql) == 0)
                }
            }
            clock.set([base.addingTimeInterval(800)])
            let verdict: V2ContentReviewVerdict = scenario == "violation" ? .violation(finding) : (scenario == "review" ? .reviewRequired(finding) : .clear)
            let healthy = try V2ContentReviewWorker(store: store, reviewer: Reviewer(verdict: verdict), moderation: moderation, now: { clock.now() })
            #expect(try await healthy.runOnce(limit: 1) == .init(claimedCount: 1, resolvedCount: 1, redactedCount: scenario == "violation" ? 1 : 0, releasedCount: 0))
            #expect(try await healthy.runOnce(limit: 1) == .init(claimedCount: 0, resolvedCount: 0, redactedCount: 0, releasedCount: 0))
            #expect(try await count("im_v2.content_review_decisions", on: sql) == 1)
            #expect(try await count("im_v2.content_review_findings", on: sql) == (scenario == "clear" ? 0 : 1))
            #expect(try await count("im_v2.content_review_cases", on: sql) == (scenario == "review" ? 1 : 0))
            #expect(try await count("im_v2.moderation_operations", on: sql) == (scenario == "violation" ? 1 : 0))
            #expect(try await sql.raw("SELECT (withdrawn_at IS NOT NULL) = \(bind: scenario == "violation") AS exists FROM im_v2.messages WHERE message_id = \(bind: message.messageID.uuidValue!)").first(decoding: ExistsRow.self)?.exists == true)
        }
    }

    @Test("Forward clocks preserve exports, copied bytes, leases and terminal replay", arguments: [false, true])
    func forwardClockBounds(passed: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { sourceDB, targetDB, sourceSQL, targetSQL, targetRoom in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let root = FileManager.default.temporaryDirectory.appending(path: "forward-clock-\(UUID())", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: root) }
            let resource = try ConcurrentMediaResourceFixture(root: root, now: { base })
            let bytes = Data("forward clock regression".utf8), media = MediaID(uuid: UUID())
            try await sourceSQL.raw("INSERT INTO im_v2.media_objects (media_id, owner_user_id, content_type, byte_count, state, upload_session_id, expires_at, state_updated_at, created_at) VALUES (\(bind: media.uuidValue!), \(bind: senderUUID), 'text/plain', \(bind: Int64(bytes.count)), 'available', \(bind: UUID()), \(bind: base.addingTimeInterval(600)), \(bind: base), \(bind: base))").run()
            try await resource.seedPlacement(mediaID: media.uuidValue!, roomID: roomID, bytes: bytes, sql: sourceSQL, now: base)
            let profile = try forwardImportTestProfile(), limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let sender = V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: sourceDB, controlDatabase: sourceDB,
                store: PostgresV2RoomWriteStore(database: sourceDB), shardID: "room-a", epoch: 0), capacityProfile: profile, limits: limits, now: { base })
            guard case .accepted(let message) = try await sender.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "forward clocks", media: [.init(mediaID: media)])) else { throw V2ForwardInboxError.corruptPersistenceState }
            let exporter = PostgresV2ForwardExportStore(database: sourceDB)
            let operation = MessageForwardOperationID(uuid: UUID())
            func prepare(_ time: Date) async throws -> V2ForwardExport {
                try await exporter.prepare(actorUserID: .init(uuid: memberTwoUUID), operationID: operation, source: .init(roomID: roomID, messageID: message.messageID, revision: .init(1)), sourceRoute: .init(shardID: "room-a", epoch: 0), targetRoomID: targetRoom, targetRoute: .init(shardID: "room-b", epoch: 0), now: time)
            }
            func snapshot(_ sql: any SQLDatabase) async throws -> String {
                struct State: Decodable { let value: String }
                return try #require(try await sql.raw("""
                    SELECT jsonb_build_object(
                        'exports', (SELECT jsonb_agg(to_jsonb(r) ORDER BY export_id) FROM im_v2.message_forward_exports r),
                        'delivery', (SELECT jsonb_agg(to_jsonb(r) ORDER BY export_id) FROM im_v2.message_forward_delivery_jobs r),
                        'receipts', (SELECT jsonb_agg(to_jsonb(r) ORDER BY export_id) FROM im_v2.message_forward_export_receipts r),
                        'inbox', (SELECT jsonb_agg(to_jsonb(r) ORDER BY export_id) FROM im_v2.message_forward_inbox r),
                        'bindings', (SELECT jsonb_agg(to_jsonb(r) ORDER BY export_id, ordinal) FROM im_v2.message_forward_inbox_media r),
                        'imports', (SELECT jsonb_agg(to_jsonb(r) ORDER BY export_id, ordinal) FROM im_v2.message_forward_media_imports r),
                        'media', (SELECT jsonb_agg(to_jsonb(r) ORDER BY media_id) FROM im_v2.media_objects r),
                        'resources', (SELECT jsonb_agg(to_jsonb(r) ORDER BY media_id) FROM im_v2.resource_catalog r),
                        'placements', (SELECT jsonb_agg(to_jsonb(r) ORDER BY placement_id) FROM im_v2.resource_blob_placements r),
                        'copy_outputs', (SELECT jsonb_agg(to_jsonb(r) ORDER BY export_id,ordinal) FROM im_v2.resource_forward_outputs r)
                    )::text AS value
                    """).first(decoding: State.self)).value
            }
            let badDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            let initialSource = try await snapshot(sourceSQL)
            for invalid in badDates {
                await #expect(throws: V2ForwardExportError.corruptPersistenceState) { try await prepare(invalid) }
                #expect(try await snapshot(sourceSQL) == initialSource)
            }
            let export = try await prepare(base)
            let inbox = PostgresV2ForwardInboxStore(database: targetDB), receipts = PostgresV2ForwardReceiptStore(database: sourceDB)
            let initialTarget = try await snapshot(targetSQL)
            for invalid in badDates {
                #expect(try await prepare(invalid) == export)
                await #expect(throws: V2ForwardInboxError.corruptPersistenceState) { try await inbox.receive(export, now: invalid) }
                #expect(try await snapshot(targetSQL) == initialTarget)
            }
            try await inbox.receive(export, now: base)
            let received = try await snapshot(targetSQL)
            for invalid in badDates { try await inbox.receive(export, now: invalid) }
            #expect(try await snapshot(targetSQL) == received)
            let jobs = PostgresV2ForwardDeliveryStore(database: sourceDB)
            let queued = try await snapshot(sourceSQL)
            let upper = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)
            for invalid in badDates + [upper] {
                await #expect(throws: V2ForwardExportError.corruptPersistenceState) { try await jobs.claim(sourceShardID: "room-a", now: invalid, leaseDuration: 30, limit: 1) }
            }
            for duration in [Double.leastNonzeroMagnitude, 0.000000001] {
                await #expect(throws: V2ForwardExportError.corruptPersistenceState) { try await jobs.claim(sourceShardID: "room-a", now: base, leaseDuration: duration, limit: 1) }
            }
            #expect(try await snapshot(sourceSQL) == queued)
            let first = try #require(try await jobs.claim(sourceShardID: "room-a", now: base, leaseDuration: 30, limit: 1).first)
            let claimed = try await snapshot(sourceSQL)
            for invalid in badDates {
                await #expect(throws: V2ForwardExportError.corruptPersistenceState) { try await jobs.isCurrent(first, now: invalid) }
                await #expect(throws: V2ForwardExportError.corruptPersistenceState) { try await jobs.complete(first, now: invalid) }
                await #expect(throws: V2ForwardExportError.corruptPersistenceState) { try await jobs.reschedule(first, disposition: .pause, now: invalid) }
                await #expect(throws: V2ForwardExportError.corruptPersistenceState) { try await jobs.reschedule(first, disposition: .retry(at: invalid), resetAttempts: true, now: base) }
                #expect(try await snapshot(sourceSQL) == claimed)
            }
            #expect(try await jobs.claim(sourceShardID: "room-a", now: base.addingTimeInterval(29), leaseDuration: 30, limit: 1).isEmpty)
            #expect(try await jobs.isCurrent(first, now: base.addingTimeInterval(30)) == false)
            #expect(try await jobs.complete(first, now: base.addingTimeInterval(30)) == false)
            let second = try #require(try await jobs.claim(sourceShardID: "room-a", now: base.addingTimeInterval(30), leaseDuration: 30, limit: 1).first)
            #expect(second.claimToken != first.claimToken && second.attempt == 2)
            let reclaimed = try await snapshot(sourceSQL)
            #expect(try await jobs.reschedule(first, disposition: .retry(at: base), now: base.addingTimeInterval(31)) == false)
            #expect(try await snapshot(sourceSQL) == reclaimed)
            #expect(try await jobs.reschedule(second, disposition: .retry(at: base.addingTimeInterval(-1)), now: base.addingTimeInterval(31)))
            struct PendingTarget: V2ForwardExportDelivering {
                func deliver(_ export: V2ForwardExport) async throws -> V2ForwardTerminalReceipt? { nil }
            }
            let clock = TestSequenceClock([base])
            let delivery = try V2ForwardDeliveryWorker(store: jobs, receipts: receipts, target: PendingTarget(), sourceCommand: forwardSourceCommandUnexpected, deadline: { .now + .seconds(10) }, leaseDuration: 30, pendingDelay: 10, maximumConcurrency: 1, retryPolicy: .init(initialDelay: 2, maximumDelay: 2, maximumAttempts: 100, jitterFraction: 0), now: { clock.now() })
            for (index, invalid) in badDates.enumerated() {
                let time = base.addingTimeInterval(100 + Double(index) * 40)
                clock.set([time, time, invalid])
                await #expect(throws: V2ForwardExportError.corruptPersistenceState) { try await delivery.runOnce(sourceShardID: "room-a", limit: 1) }
                #expect(try await sourceSQL.raw("SELECT state = 'claimed' AND retry_count = \(bind: Int64(index + 3)) AND lease_expires_at = \(bind: time.addingTimeInterval(30)) AND next_attempt_at IS NULL AS exists FROM im_v2.message_forward_delivery_jobs").first(decoding: ExistsRow.self)?.exists == true)
                #expect(try await receipts.status(exportID: export.intent.exportID) == nil)
            }
            for (index, delay) in [Double.leastNonzeroMagnitude, .greatestFiniteMagnitude].enumerated() {
                let time = base.addingTimeInterval(430 + Double(index) * 20)
                let invalidDelay = try V2ForwardDeliveryWorker(store: jobs, receipts: receipts, target: PendingTarget(), sourceCommand: forwardSourceCommandUnexpected, deadline: { .now + .seconds(10) }, leaseDuration: 30, pendingDelay: delay, maximumConcurrency: 1, retryPolicy: .init(initialDelay: 2, maximumDelay: 2, maximumAttempts: 100, jitterFraction: 0), now: { time })
                let report = try await invalidDelay.runOnce(sourceShardID: "room-a", limit: 1)
                #expect(report.retried == 1 && report.deferred == 0)
                #expect(try await sourceSQL.raw("SELECT state = 'pending' AND next_attempt_at = \(bind: time.addingTimeInterval(2)) AS exists FROM im_v2.message_forward_delivery_jobs").first(decoding: ExistsRow.self)?.exists == true)
            }
            clock.set([base.addingTimeInterval(500)])
            let deferred = try await delivery.runOnce(sourceShardID: "room-a", limit: 1)
            #expect(deferred.deferred == 1 && deferred.completed == 0)
            #expect(try await sourceSQL.raw("SELECT state = 'pending' AND retry_count = 0 AND next_attempt_at = \(bind: base.addingTimeInterval(510)) AS exists FROM im_v2.message_forward_delivery_jobs").first(decoding: ExistsRow.self)?.exists == true)
            #expect(try await jobs.claim(sourceShardID: "room-a", now: base.addingTimeInterval(509), leaseDuration: 30, limit: 1).isEmpty)

            let importer = try PostgresV2ForwardMediaImportStore(database: targetDB, temporaryLifetime: 600)
            for invalid in badDates + [upper] {
                await #expect(throws: V2ForwardInboxError.corruptPersistenceState) { try await importer.claim(exportID: export.intent.exportID, now: invalid, leaseDuration: 30) }
            }
            for duration in [Double.leastNonzeroMagnitude, 0.000000001] {
                await #expect(throws: V2ForwardInboxError.corruptPersistenceState) { try await importer.claim(exportID: export.intent.exportID, now: base, leaseDuration: duration) }
            }
            for lifetime in [Double.greatestFiniteMagnitude, .leastNonzeroMagnitude] {
                let invalidLifetime = try PostgresV2ForwardMediaImportStore(database: targetDB, temporaryLifetime: lifetime)
                await #expect(throws: V2ForwardInboxError.corruptPersistenceState) { try await invalidLifetime.claim(exportID: export.intent.exportID, now: base, leaseDuration: 30) }
            }
            #expect(try await snapshot(targetSQL) == received)
            let oldImport = try #require(try await importer.claim(exportID: export.intent.exportID, now: base.addingTimeInterval(10), leaseDuration: 30))
            let beforeCopy = try await snapshot(targetSQL)
            func resourceCopier(at time: Date) throws -> V2ResourceForwardMediaCopier {
                try .init(sources: ["room-a": sourceDB], target: importer, registry: resource.registry,
                    maximumBytes: 1024, allocate: { _ in try resource.storage.allocate() }, now: { time })
            }
            for invalid in badDates {
                let copier = try resourceCopier(at: invalid)
                await #expect(throws: V2ForwardInboxError.corruptPersistenceState) { try await copier.copy(oldImport) }
                #expect(try await snapshot(targetSQL) == beforeCopy)
            }
            let expiredCopier = try resourceCopier(at: upper)
            await #expect(throws: V2ResourceProviderError.preconditionFailed) { try await expiredCopier.copy(oldImport) }
            #expect(try await snapshot(targetSQL) == beforeCopy)
            let copier = try resourceCopier(at: base.addingTimeInterval(10))
            let copied = try await copier.copy(oldImport)
            let afterCopy = try await snapshot(targetSQL)
            for invalid in badDates {
                await #expect(throws: V2ForwardInboxError.corruptPersistenceState) { try await importer.recordCopied(oldImport, receipt: copied, now: invalid) }
                #expect(try await snapshot(targetSQL) == afterCopy)
            }
            #expect(try await importer.recordCopied(oldImport, receipt: copied, now: base.addingTimeInterval(11)))
            let beforeComplete = try await snapshot(targetSQL)
            for invalid in badDates {
                await #expect(throws: V2ForwardInboxError.corruptPersistenceState) { try await importer.complete(oldImport, receipt: copied, result: .passed, now: invalid) }
                await #expect(throws: V2ForwardInboxError.corruptPersistenceState) { try await importer.reject(oldImport, now: invalid) }
                await #expect(throws: V2ForwardInboxError.corruptPersistenceState) { try await importer.retry(oldImport, disposition: .pause, now: invalid) }
                await #expect(throws: V2ForwardInboxError.corruptPersistenceState) { try await importer.retry(oldImport, disposition: .retry(at: invalid), now: base.addingTimeInterval(12)) }
                #expect(try await snapshot(targetSQL) == beforeComplete)
            }
            let badLifetime = try PostgresV2ForwardMediaImportStore(database: targetDB, temporaryLifetime: .greatestFiniteMagnitude)
            await #expect(throws: V2ForwardInboxError.corruptPersistenceState) { try await badLifetime.complete(oldImport, receipt: copied, result: .passed, now: base.addingTimeInterval(12)) }
            #expect(try await snapshot(targetSQL) == beforeComplete)
            let nextImport = try #require(try await importer.claim(exportID: export.intent.exportID, now: base.addingTimeInterval(40), leaseDuration: 30))
            #expect(nextImport.targetMediaID == oldImport.targetMediaID && nextImport.targetUploadSessionID == oldImport.targetUploadSessionID && nextImport.claimToken != oldImport.claimToken)
            let importReclaimed = try await snapshot(targetSQL)
            #expect(try await importer.complete(oldImport, receipt: copied, result: .passed, now: badDates[0]) == false)
            #expect(try await importer.reject(oldImport, now: badDates[0]) == false)
            #expect(try await importer.retry(oldImport, disposition: .retry(at: badDates[0]), now: badDates[0]) == false)
            #expect(try await snapshot(targetSQL) == importReclaimed)
            let invalidRecoveredCopier = try resourceCopier(at: badDates[0])
            await #expect(throws: V2ForwardInboxError.corruptPersistenceState) { try await invalidRecoveredCopier.copy(nextImport) }
            #expect(try await snapshot(targetSQL) == importReclaimed)
            let recoveredCopier = try resourceCopier(at: base.addingTimeInterval(40))
            #expect(try await recoveredCopier.copy(nextImport) == copied)
            // Completion after a wall-clock rollback must not shorten the
            // already reserved object's retention deadline.
            #expect(try await importer.complete(nextImport, receipt: copied, result: passed ? .passed : .failed, now: base.addingTimeInterval(9)))
            if passed {
                #expect(try await targetSQL.raw("SELECT state = 'available' AND expires_at = \(bind: base.addingTimeInterval(610)) AS exists FROM im_v2.media_objects WHERE media_id = \(bind: nextImport.targetMediaID.uuidValue!)").first(decoding: ExistsRow.self)?.exists == true)
                let ready = try await snapshot(targetSQL)
                for invalid in badDates {
                    // Receipt reception is already durable; a failed activated
                    // import round must report uncertainty and recover its result.
                    await #expect(throws: V2RoomTransactionOutcomeUnknown.self) {
                        try await V2PolicyAuthorizedTestWriteStore(database: targetDB, controlDatabase: sourceDB,
                store: PostgresV2RoomWriteStore(database: targetDB), shardID: "room-b", epoch: 0).importForwardExport(export, capacityProfile: profile, limits: limits, identifiers: V2AcceptanceIDFactory().make(at: base), now: invalid)
                    }
                    #expect(try await snapshot(targetSQL) == ready)
                    #expect(try await count("im_v2.messages", on: targetSQL) == 0)
                }
            }
            let outcome = try await V2PolicyAuthorizedTestWriteStore(database: targetDB, controlDatabase: sourceDB,
                store: PostgresV2RoomWriteStore(database: targetDB), shardID: "room-b", epoch: 0).importForwardExport(export, capacityProfile: profile, limits: limits, identifiers: V2AcceptanceIDFactory().make(at: base.addingTimeInterval(50)), now: base.addingTimeInterval(50))
            if passed { guard case .accepted = outcome else { throw V2ForwardInboxError.corruptPersistenceState } }
            else { #expect(outcome == .rejected(code: "MEDIA_UNAVAILABLE")) }
            let terminal = try #require(try await inbox.terminalReceipt(exportID: export.intent.exportID))
            let beforeReceipt = try await snapshot(sourceSQL)
            for invalid in badDates {
                await #expect(throws: V2ForwardExportError.corruptPersistenceState) { try await receipts.record(terminal, now: invalid) }
                #expect(try await snapshot(sourceSQL) == beforeReceipt)
            }
            try await receipts.record(terminal, now: base.addingTimeInterval(520))
            let receivedTerminal = try await snapshot(sourceSQL), finalTarget = try await snapshot(targetSQL)
            for invalid in badDates {
                try await receipts.record(terminal, now: invalid)
                #expect(try await prepare(invalid) == export)
                #expect(try await V2PolicyAuthorizedTestWriteStore(database: targetDB, controlDatabase: sourceDB,
                store: PostgresV2RoomWriteStore(database: targetDB), shardID: "room-b", epoch: 0).importForwardExport(export, capacityProfile: profile, limits: limits, identifiers: V2AcceptanceIDFactory().make(at: base), now: invalid) == outcome)
                #expect(try await importer.claim(exportID: export.intent.exportID, now: invalid, leaseDuration: 30) == nil)
                #expect(try await importer.reject(nextImport, now: invalid) == false)
            }
            #expect(try await snapshot(sourceSQL) == receivedTerminal)
            #expect(try await snapshot(targetSQL) == finalTarget)
            clock.set([base.addingTimeInterval(521)])
            let finished = try await delivery.runOnce(sourceShardID: "room-a", limit: 1)
            #expect(finished.completed == 1 && finished.deferred == 0)
            #expect(try await delivery.runOnce(sourceShardID: "room-a", limit: 1).claimed == 0)
            #expect(try await count("im_v2.message_forward_export_receipts", on: sourceSQL) == 1)
            #expect(try await count("im_v2.messages", on: targetSQL) == (passed ? 1 : 0))
        }
    }

    @Test("Resource lifecycle clocks preserve replay and scan claims respect scheduling", arguments: ["pending", "claimed", "retry", "paused"], [false, true])
    func mediaLifecycleClockBounds(schedule: String, passed: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let device = DeviceID(uuid: UUID()), mediaID = MediaID(uuid: UUID()), operation = MediaUploadOperationID(uuid: UUID())
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, session_expires_at) VALUES (\(bind: senderUUID), \(bind: device.uuidValue!), \(bind: base), \(bind: base), \(bind: Date().addingTimeInterval(3600)))").run()
            let store = PostgresV2MediaStore(database: database)
            let uploads = PostgresV2ResourceLifecycleStore(database: database, authorize: { _ in })
            let input = try V2ResourceUploadRequest(operationID: operation, mediaID: mediaID, usage: .messageAttachment(roomID),
                contentType: "image/png", byteCount: 42, checksum: .init(value: String(repeating: "a", count: 64)))
            func snapshot() async throws -> String {
                struct State: Decodable { let value: String }
                return try #require(try await sql.raw("""
                    SELECT jsonb_build_object(
                        'media', (SELECT jsonb_agg(to_jsonb(r) ORDER BY media_id) FROM im_v2.media_objects r),
                        'catalog', (SELECT jsonb_agg(to_jsonb(r) ORDER BY media_id) FROM im_v2.resource_catalog r),
                        'uploads', (SELECT jsonb_agg(to_jsonb(r) ORDER BY session_id) FROM im_v2.resource_upload_sessions r),
                        'placements', (SELECT jsonb_agg(to_jsonb(r) ORDER BY placement_id) FROM im_v2.resource_blob_placements r),
                        'downloads', (SELECT jsonb_agg(to_jsonb(r) ORDER BY download_session_id) FROM im_v2.media_download_grants r),
                        'scans', (SELECT jsonb_agg(to_jsonb(r) ORDER BY media_id) FROM im_v2.media_scan_outbox r)
                    )::text AS value
                    """).first(decoding: State.self)).value
            }
            let badDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            let invalidPairs = [(base, base), (base, base.addingTimeInterval(-1)), (Date(timeIntervalSince1970: 946_684_800.00000025), Date(timeIntervalSince1970: 946_684_800.00000075))]
            let initial = try await snapshot()
            for invalid in badDates {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await createResourceUpload(input, device: device, store: uploads, expiresAt: base.addingTimeInterval(600), now: invalid) }
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await createResourceUpload(input, device: device, store: uploads, expiresAt: invalid, now: base) }
                #expect(try await snapshot() == initial)
            }
            for (start, end) in invalidPairs {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await createResourceUpload(input, device: device, store: uploads, expiresAt: end, now: start) }
            }
            #expect(try await snapshot() == initial)
            let upload = try await createResourceUpload(input, device: device, store: uploads, expiresAt: base.addingTimeInterval(600), now: base)
            let registered = try await snapshot()
            let conflict = try V2ResourceUploadRequest(operationID: operation, mediaID: mediaID, usage: input.usage, contentType: input.contentType, byteCount: 43, checksum: input.checksum)
            for invalid in badDates {
                let replay = try await createResourceUpload(input, device: device, store: uploads, expiresAt: invalid, now: invalid)
                #expect(replay.sessionID == upload.sessionID && replay.expiresAt == upload.expiresAt)
                await #expect(throws: V2MediaStoreError.idempotencyConflict) { try await createResourceUpload(conflict, device: device, store: uploads, expiresAt: invalid, now: invalid) }
                #expect(try await snapshot() == registered)
            }
            let claim = try await uploads.claimFinalize(session: upload.sessionID, generation: 1, actor: senderUUID, device: device.uuidValue!, now: base)
            let facts = try V2StoredObjectFacts(reference: claim.placement, byteCount: 42, sha256: Data(repeating: 0xaa, count: 32))
            let claimed = try await snapshot()
            for invalid in badDates {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await uploads.publish(claim, facts: facts, actor: senderUUID, device: device.uuidValue!, now: invalid) }
                #expect(try await snapshot() == claimed)
            }
            try await uploads.publish(claim, facts: facts, actor: senderUUID, device: device.uuidValue!, now: base.addingTimeInterval(2))
            let scans = PostgresV2MediaScanStore(database: database)
            let result: V2MediaScanResult = passed ? .passed : .failed
            var lease = try #require(try await scans.claimPending(now: base.addingTimeInterval(3), leaseDuration: 30, limit: 1).first)
            var completedAt = base.addingTimeInterval(4)
            if schedule == "retry" || schedule == "paused" {
                try await scans.scheduleRetry(lease, disposition: schedule == "retry" ? .retry(at: base.addingTimeInterval(60)) : .pause, now: base.addingTimeInterval(3))
                let released = try await snapshot()
                try await scans.complete(lease, result: result, now: completedAt)
                #expect(try await snapshot() == released)
                #expect(try await scans.claimPending(now: base.addingTimeInterval(59), leaseDuration: 30, limit: 1).isEmpty)
                if schedule == "paused" {
                    #expect(try await scans.claimPending(now: base.addingTimeInterval(61), leaseDuration: 30, limit: 1).isEmpty)
                    #expect(try await snapshot() == released)
                    return
                }
                let oldLease = lease
                lease = try #require(try await scans.claimPending(now: base.addingTimeInterval(60), leaseDuration: 30, limit: 1).first)
                #expect(lease.claimToken != oldLease.claimToken)
                let reclaimed = try await snapshot()
                try await scans.complete(oldLease, result: result, now: base.addingTimeInterval(61))
                #expect(try await snapshot() == reclaimed)
                completedAt = base.addingTimeInterval(61)
            }
            let scanning = try await snapshot()
            for invalid in badDates {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await scans.complete(lease, result: result, now: invalid) }
                #expect(try await snapshot() == scanning)
            }
            try await scans.complete(lease, result: result, now: completedAt)
            #expect(try await sql.raw("SELECT state = 'completed' AND completed_at = \(bind: completedAt) AND claim_token IS NULL AND lease_expires_at IS NULL AND next_attempt_at IS NULL AND paused_at IS NULL AS exists FROM im_v2.media_scan_outbox").first(decoding: ExistsRow.self)?.exists == true)
            #expect(try await uploads.status(session: upload.sessionID, actor: senderUUID, device: device.uuidValue!).mediaState == (passed ? "available" : "failed"))
            let scanned = try await snapshot()
            try await scans.complete(lease, result: passed ? .failed : .passed, now: completedAt.addingTimeInterval(1))
            #expect(try await snapshot() == scanned)
            if !passed { return }
            let sender = try V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                store: PostgresV2RoomWriteStore(database: database), shardID: "room-a", epoch: 0), capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64), now: { [completedAt] in completedAt.addingTimeInterval(1) })
            guard case .accepted(let message) = try await sender.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "media lifecycle", media: [.init(mediaID: mediaID)])) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            #expect(try await count("im_v2.user_sync_log", on: sql) == 0)
            let beforeDownload = try await snapshot()
            for invalid in badDates {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.requestDownload(requesterUserID: senderID, deviceID: device, mediaID: mediaID, expiresAt: base.addingTimeInterval(120), now: invalid) }
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.requestDownload(requesterUserID: senderID, deviceID: device, mediaID: mediaID, expiresAt: invalid, now: base) }
                #expect(try await snapshot() == beforeDownload)
            }
            for (start, end) in invalidPairs {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.requestDownload(requesterUserID: senderID, deviceID: device, mediaID: mediaID, expiresAt: end, now: start) }
            }
            #expect(try await snapshot() == beforeDownload)
            let download = try await store.requestDownload(requesterUserID: senderID, deviceID: device, mediaID: mediaID, expiresAt: base.addingTimeInterval(120), now: completedAt.addingTimeInterval(2))
            let downloads = PostgresV2MediaDownloadSessionStore(database: database)
            let downloadClaim = try await downloads.claimDownload(requesterUserID: senderID, deviceID: device, downloadSessionID: download.downloadSessionID, now: completedAt.addingTimeInterval(3), leaseDuration: 15)
            try await downloads.completeDownload(downloadClaim, now: completedAt.addingTimeInterval(4))
            #expect(try await count("im_v2.media_download_grants WHERE state = 'consumed'", on: sql) == 1)
            #expect(try await count("im_v2.messages", on: sql) == 1)
        }
    }

    @Test("Current resource download clock failures preserve leases and provider exchange recovers")
    func resourceDownloadSessionClockBounds() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let device = DeviceID(uuid: UUID()), downloadMedia = MediaID(uuid: UUID())
            // A fresh, live local device fixture; only business timestamps vary.
            let deviceExpiry = Date().addingTimeInterval(3600)
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, session_expires_at) VALUES (\(bind: senderUUID), \(bind: device.uuidValue!), \(bind: base), \(bind: base), \(bind: deviceExpiry))").run()
            let media = PostgresV2MediaStore(database: database)
            let uploads = PostgresV2ResourceLifecycleStore(database: database, authorize: { _ in })
            let reference = try V2StoredObjectReference(placementID: UUID(), binding: .init(id: "download-clock", configurationRevision: 1), handle: Data("exact-object".utf8))
            let input = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: downloadMedia, usage: .messageAttachment(roomID),
                contentType: "text/plain", byteCount: 42, checksum: .init(value: String(repeating: "a", count: 64)))
            let upload = try await uploads.create(homeKind: "room", homeID: roomUUID, usageKind: "message_attachment", actor: senderUUID,
                device: device.uuidValue!, operation: input.operationID.uuidValue!, mediaID: downloadMedia.uuidValue!, contentType: input.contentType,
                byteCount: input.byteCount, requestJSON: String(decoding: JSONEncoder().encode(input), as: UTF8.self), allocate: { reference },
                expiresAt: base.addingTimeInterval(600), now: base)
            let uploadClaim = try await uploads.claimFinalize(session: upload.sessionID, generation: 1, actor: senderUUID, device: device.uuidValue!, now: base)
            try await uploads.publish(uploadClaim, facts: .init(reference: reference, byteCount: 42, sha256: Data(repeating: 0xaa, count: 32)),
                actor: senderUUID, device: device.uuidValue!, now: base)
            let scans = PostgresV2MediaScanStore(database: database)
            let scan = try #require(try await scans.claimPending(now: base, leaseDuration: 30, limit: 1).first)
            try await scans.complete(scan, result: .passed, now: base)
            let sender = try V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                store: PostgresV2RoomWriteStore(database: database), shardID: "room-a", epoch: 0), capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64), now: { base })
            guard case .accepted(let message) = try await sender.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "media session clock", media: [.init(mediaID: downloadMedia)])) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            #expect(try await count("im_v2.user_sync_log", on: sql) == 0)
            let download = try await media.requestDownload(requesterUserID: senderID, deviceID: device, mediaID: downloadMedia, expiresAt: base.addingTimeInterval(600), now: base)
            let downloads = PostgresV2MediaDownloadSessionStore(database: database)
            func claimDownload(at time: Date, duration: TimeInterval = 30) async throws -> V2ClaimedMediaDownload {
                try await downloads.claimDownload(requesterUserID: senderID, deviceID: device, downloadSessionID: download.downloadSessionID, now: time, leaseDuration: duration)
            }
            func snapshot() async throws -> String {
                struct State: Decodable { let value: String }
                return try #require(try await sql.raw("""
                    SELECT jsonb_build_object(
                        'media', (SELECT jsonb_agg(to_jsonb(r) ORDER BY media_id) FROM im_v2.media_objects r),
                        'catalog', (SELECT jsonb_agg(to_jsonb(r) ORDER BY media_id) FROM im_v2.resource_catalog r),
                        'uploads', (SELECT jsonb_agg(to_jsonb(r) ORDER BY session_id) FROM im_v2.resource_upload_sessions r),
                        'downloads', (SELECT jsonb_agg(to_jsonb(r) ORDER BY download_session_id) FROM im_v2.media_download_grants r)
                    )::text AS value
                    """).first(decoding: State.self)).value
            }
            let badDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            let initial = try await snapshot()
            for invalid in badDates {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await claimDownload(at: invalid) }
            }
            for duration in [Double.infinity, .greatestFiniteMagnitude, .leastNonzeroMagnitude, 0.000000001] {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await claimDownload(at: base, duration: duration) }
            }
            for duration in [Double.nan, 0, -1] {
                await #expect(throws: V2MediaDownloadSessionStoreError.invalidRequest) { try await claimDownload(at: base, duration: duration) }
            }
            let upper = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)
            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await claimDownload(at: upper) }
            #expect(try await snapshot() == initial)
            let firstDownload = try await claimDownload(at: base)
            let claimed = try await snapshot()
            for invalid in badDates {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await downloads.completeDownload(firstDownload, now: invalid) }
                #expect(try await snapshot() == claimed)
            }
            await #expect(throws: V2MediaDownloadSessionStoreError.sessionUnavailable) { try await claimDownload(at: base.addingTimeInterval(29)) }
            await #expect(throws: V2MediaDownloadSessionStoreError.sessionUnavailable) { try await downloads.completeDownload(firstDownload, now: base.addingTimeInterval(30)) }
            #expect(try await snapshot() == claimed)
            let nextDownload = try await claimDownload(at: base.addingTimeInterval(30))
            #expect(nextDownload.claimToken != firstDownload.claimToken)
            let reclaimed = try await snapshot()
            await #expect(throws: V2MediaDownloadSessionStoreError.sessionUnavailable) { try await downloads.completeDownload(firstDownload, now: badDates[0]) }
            try await downloads.releaseDownload(firstDownload)
            #expect(try await snapshot() == reclaimed)
            try await downloads.releaseDownload(nextDownload)
            struct Provider: V2MediaObjectProvider {
                func issueDownloadTarget(mediaID: MediaID, expiresAt: Date) async throws -> V2ResourceTransferPlan {
                    try resourceDownloadTestPlan(url: URL(string: "https://media.invalid/download")!, expiresAt: expiresAt, expectedByteCount: 42)
                }
            }
            let clock = TestSequenceClock([base.addingTimeInterval(60)])
            let downloadService = try V2MediaProviderSessionService(store: downloads, provider: Provider(), now: { clock.now() })
            for (index, invalid) in badDates.enumerated() {
                // Signing succeeds, then the completion clock becomes invalid.
                // The service must release its exact claim so a healthy retry works.
                clock.set([base.addingTimeInterval(60), base.addingTimeInterval(60), invalid])
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await downloadService.exchangeDownload(actorUserID: senderID, deviceID: device, downloadSessionID: download.downloadSessionID) }
                for table in ["media_download_grants"] {
                    #expect(try await sql.raw("SELECT state = 'pending' AND claim_token IS NULL AND lease_expires_at IS NULL AND redeemed_at IS NULL AND retry_count = \(bind: Int64(index + 3)) AS exists FROM im_v2.\(unsafeRaw: table)").first(decoding: ExistsRow.self)?.exists == true)
                }
            }
            clock.set([base.addingTimeInterval(61)])
            #expect(try await downloadService.exchangeDownload(actorUserID: senderID, deviceID: device, downloadSessionID: download.downloadSessionID).expiresAt == download.expiresAt)
            for table in ["media_download_grants"] {
                #expect(try await sql.raw("SELECT state = 'consumed' AND claim_token IS NULL AND lease_expires_at IS NULL AND redeemed_at = \(bind: base.addingTimeInterval(61)) AS exists FROM im_v2.\(unsafeRaw: table)").first(decoding: ExistsRow.self)?.exists == true)
            }
            let completed = try await snapshot()
            await #expect(throws: V2MediaDownloadSessionStoreError.sessionUnavailable) { try await claimDownload(at: base.addingTimeInterval(62)) }
            try await downloads.releaseDownload(firstDownload)
            #expect(try await snapshot() == completed)
            #expect(try await count("im_v2.messages", on: sql) == 1)
            #expect(try await count("im_v2.message_media_references", on: sql) == 1)
        }
    }


    @Test("Media maintenance validates clocks and preserves scan, purge and retention state", arguments: ["passed", "failed", "expired"])
    func mediaMaintenanceClockBounds(scenario: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let scanID = UUID(), purgeID = UUID(), unreferencedID = UUID(), referencedID = UUID()
            for (id, state, expiry) in [(scanID, "scanning", base.addingTimeInterval(1000)), (purgeID, "expired", base), (unreferencedID, "available", base.addingTimeInterval(-1))] {
                try await sql.raw("""
                    INSERT INTO im_v2.media_objects (media_id, owner_user_id, content_type, byte_count, state, upload_session_id, expires_at, state_updated_at, created_at)
                    VALUES (\(bind: id), \(bind: senderUUID), 'image/png', 42, \(bind: state), \(bind: UUID()), \(bind: expiry), \(bind: base), \(bind: base))
                    """).run()
            }
            try await prepareDownloadableResource(mediaID: .init(uuid: referencedID), device: .init(uuid: UUID()), database: database)
            // Its completed scan bookkeeping has already been collected.
            try await sql.raw("DELETE FROM im_v2.media_scan_outbox WHERE media_id = \(bind: referencedID)").run()
            try await sql.raw("INSERT INTO im_v2.media_scan_outbox (media_id, state, created_at) VALUES (\(bind: scanID), 'pending', \(bind: base))").run()
            try await sql.raw("INSERT INTO im_v2.media_purge_outbox (media_id, reason, state, created_at) VALUES (\(bind: purgeID), 'unreferenced_expired', 'pending', \(bind: base))").run()
            try await sql.raw("UPDATE im_v2.messages SET withdrawn_at = \(bind: base.addingTimeInterval(20)), withdrawn_by_user_id = \(bind: senderUUID) WHERE message_id IN (SELECT message_id FROM im_v2.message_media_references WHERE media_id = \(bind: referencedID))").run()
            let scan = PostgresV2MediaScanStore(database: database)
            let purge = PostgresV2MediaPurgeStore(database: database)
            let retention = PostgresV2MediaRetentionStore(database: database)
            func snapshot() async throws -> String {
                struct State: Decodable { let value: String }
                return try #require(try await sql.raw("""
                    SELECT jsonb_build_object(
                        'media', (SELECT jsonb_agg(to_jsonb(r) ORDER BY media_id) FROM im_v2.media_objects r),
                        'scans', (SELECT jsonb_agg(to_jsonb(r) ORDER BY media_id) FROM im_v2.media_scan_outbox r),
                        'purges', (SELECT jsonb_agg(to_jsonb(r) ORDER BY media_id) FROM im_v2.media_purge_outbox r),
                        'messages', (SELECT jsonb_agg(to_jsonb(r) ORDER BY message_id) FROM im_v2.messages r),
                        'references', (SELECT jsonb_agg(to_jsonb(r) ORDER BY message_id, media_id) FROM im_v2.message_media_references r)
                    )::text AS value
                    """).first(decoding: State.self)).value
            }
            let badDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            let initial = try await snapshot()
            for invalid in badDates {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await scan.claimPending(now: invalid, leaseDuration: 30, limit: 1) }
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await purge.claimPending(now: invalid, leaseDuration: 30, limit: 1) }
                await #expect(throws: V2MediaRetentionStoreError.invalidRequest) { try await retention.expireEligibleMedia(now: invalid, withdrawnRetention: 60, limit: 10) }
            }
            for duration in [Double.infinity, .greatestFiniteMagnitude, .leastNonzeroMagnitude, 0.000000001] {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await scan.claimPending(now: base, leaseDuration: duration, limit: 1) }
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await purge.claimPending(now: base, leaseDuration: duration, limit: 1) }
                // The reference was withdrawn exactly now. A positive age
                // that vanishes must not expire this newly withdrawn media.
                await #expect(throws: V2MediaRetentionStoreError.invalidRequest) { try await retention.expireEligibleMedia(now: base.addingTimeInterval(20), withdrawnRetention: duration, limit: 10) }
            }
            let upper = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)
            let lower = Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000 + 30)
            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await scan.claimPending(now: upper, leaseDuration: 30, limit: 1) }
            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await purge.claimPending(now: upper, leaseDuration: 30, limit: 1) }
            await #expect(throws: V2MediaRetentionStoreError.invalidRequest) { try await retention.expireEligibleMedia(now: lower, withdrawnRetention: 60, limit: 10) }
            #expect(try await scan.claimPending(now: badDates[0], leaseDuration: 30, limit: 0).isEmpty)
            #expect(try await purge.claimPending(now: badDates[0], leaseDuration: 30, limit: 0).isEmpty)
            #expect(try await snapshot() == initial)
            let firstScan = try #require(try await scan.claimPending(now: base, leaseDuration: 30, limit: 1).first)
            let firstPurge = try #require(try await purge.claimPending(now: base, leaseDuration: 30, limit: 1).first)
            let claimed = try await snapshot()
            for invalid in badDates {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await scan.complete(firstScan, result: .passed, now: invalid) }
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await purge.markCompleted(firstPurge, now: invalid) }
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await scan.scheduleRetry(firstScan, disposition: .retry(at: invalid), now: base) }
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await purge.scheduleRetry(firstPurge, disposition: .retry(at: invalid), now: base) }
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await scan.scheduleRetry(firstScan, disposition: .pause, now: invalid) }
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await purge.scheduleRetry(firstPurge, disposition: .pause, now: invalid) }
                #expect(try await snapshot() == claimed)
            }
            #expect(try await scan.claimPending(now: base.addingTimeInterval(29), leaseDuration: 30, limit: 1).isEmpty)
            #expect(try await purge.claimPending(now: base.addingTimeInterval(29), leaseDuration: 30, limit: 1).isEmpty)
            let nextScan = try #require(try await scan.claimPending(now: base.addingTimeInterval(30), leaseDuration: 30, limit: 1).first)
            let nextPurge = try #require(try await purge.claimPending(now: base.addingTimeInterval(30), leaseDuration: 30, limit: 1).first)
            #expect(nextScan.attempt == 2 && nextScan.claimToken != firstScan.claimToken)
            #expect(nextPurge.attempt == 2 && nextPurge.claimToken != firstPurge.claimToken)
            let reclaimed = try await snapshot()
            try await scan.complete(firstScan, result: .passed, now: badDates[0])
            try await purge.markCompleted(firstPurge, now: base)
            try await scan.scheduleRetry(firstScan, disposition: .retry(at: base), now: badDates[0])
            try await purge.scheduleRetry(firstPurge, disposition: .retry(at: base), now: badDates[0])
            #expect(try await snapshot() == reclaimed)
            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                try await scan.scheduleRetry(nextScan, disposition: .retry(at: base.addingTimeInterval(-1)), now: badDates[0])
            }
            #expect(try await snapshot() == reclaimed)
            try await scan.scheduleRetry(nextScan, disposition: .retry(at: base.addingTimeInterval(-1)), now: base.addingTimeInterval(30))
            try await purge.scheduleRetry(nextPurge, disposition: .retry(at: base.addingTimeInterval(-1)), now: badDates[0])
            let retryScan = try #require(try await scan.claimPending(now: base.addingTimeInterval(30), leaseDuration: 30, limit: 1).first)
            let retryPurge = try #require(try await purge.claimPending(now: base.addingTimeInterval(30), leaseDuration: 30, limit: 1).first)
            #expect(retryScan.attempt == 3 && retryPurge.attempt == 3)
            try await scan.scheduleRetry(retryScan, disposition: .pause, now: base.addingTimeInterval(31))
            try await purge.scheduleRetry(retryPurge, disposition: .pause, now: base.addingTimeInterval(31))
            #expect(try await scan.claimPending(now: base.addingTimeInterval(100), leaseDuration: 30, limit: 1).isEmpty)
            #expect(try await purge.claimPending(now: base.addingTimeInterval(100), leaseDuration: 30, limit: 1).isEmpty)
            let replay = PostgresV2DurableWorkReplayStore(database: database)
            for (kind, id) in [(V2DurableWorkReplayTargetKind.mediaScan, scanID), (.mediaPurge, purgeID)] {
                let result = try await verifyDurableReplayClockRecovery(.init(operationID: UUID(), target: try .init(kind: kind, sourceEventID: .init(uuid: id)), reason: .dependencyRecovered), store: replay, sql: sql, operatorPrincipal: "integration-test", now: base.addingTimeInterval(32))
                #expect(result.outcome == .requeued)
            }
            struct Scanner: V2MediaScanProvider {
                let result: V2MediaScanResult
                func scan(mediaID: MediaID) async throws -> V2MediaScanResult { result }
            }
            struct Purger: V2MediaPurgeProvider { func purge(mediaID: MediaID) async throws {} }
            if scenario == "expired" {
                // Expire only after claim fencing and operator replay have been exercised.
                // Current scanning never invokes a provider for an already expired object.
                try await sql.raw("UPDATE im_v2.media_objects SET expires_at=\(bind: base.addingTimeInterval(33)) WHERE media_id=\(bind: scanID)").run()
            }
            let scanner = try V2MediaScanWorker(store: scan, provider: Scanner(result: scenario == "failed" ? .failed : .passed), maximumConcurrency: 1, now: { base.addingTimeInterval(33) })
            #expect(try await scanner.runOnce(limit: 1) == .init(claimedCount: scenario == "expired" ? 0 : 1, completedCount: scenario == "expired" ? 0 : 1, releasedCount: 0))
            let expectedState = scenario == "expired" ? "scanning" : (scenario == "passed" ? "available" : "failed")
            #expect(try await sql.raw("SELECT state = \(bind: expectedState) AS exists FROM im_v2.media_objects WHERE media_id = \(bind: scanID)").first(decoding: ExistsRow.self)?.exists == true)
            let purger = try V2MediaPurgeWorker(store: purge, provider: Purger(), maximumConcurrency: 1, now: { base.addingTimeInterval(33) })
            #expect(try await purger.runOnce(limit: 1) == .init(claimedCount: 1, completedCount: 1, releasedCount: 0))
            #expect(try await count("im_v2.media_scan_outbox WHERE state = 'completed'", on: sql) == 1)
            #expect(try await count("im_v2.media_purge_outbox WHERE state = 'completed'", on: sql) == 1)
            #expect(try await retention.expireEligibleMedia(now: base.addingTimeInterval(79), withdrawnRetention: 60, limit: 10) == (scenario == "expired" ? 2 : 1))
            #expect(try await sql.raw("SELECT state = 'available' AS exists FROM im_v2.media_objects WHERE media_id = \(bind: referencedID)").first(decoding: ExistsRow.self)?.exists == true)
            #expect(try await retention.expireEligibleMedia(now: base.addingTimeInterval(80), withdrawnRetention: 60, limit: 10) == 1)
            #expect(try await retention.expireEligibleMedia(now: base.addingTimeInterval(80), withdrawnRetention: 60, limit: 10) == 0)
            let finalPurger = try V2MediaPurgeWorker(store: purge, provider: Purger(), maximumConcurrency: 1, now: { base.addingTimeInterval(81) })
            let pendingPurges = scenario == "expired" ? 3 : 2
            #expect(try await finalPurger.runOnce(limit: 10) == .init(claimedCount: pendingPurges, completedCount: pendingPurges, releasedCount: 0))
            #expect(try await count("im_v2.media_purge_outbox WHERE state = 'completed'", on: sql) == Int64(pendingPurges + 1))
            #expect(try await count("im_v2.messages", on: sql) == 1)
            #expect(try await count("im_v2.message_media_references", on: sql) == 1)
        }
    }

    @Test("Push endpoint clock failures preserve state and completed version replays", arguments: [false, true])
    func pushEndpointClockBounds(ownedDisable: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            // The device is a fresh, owned fixture with a live database-clock
            // session. Only the mutation timestamp is varied by this test.
            let base = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let deviceUUID = UUID(), device = DeviceID(uuid: deviceUUID)
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, session_expires_at) VALUES (\(bind: senderUUID), \(bind: deviceUUID), \(bind: base), \(bind: base), \(bind: base.addingTimeInterval(3600)))").run()
            let store = PostgresV2PushDeviceEndpointStore(database: database, envelopeKey: try .init(rawBytes: Data(repeating: 0x6a, count: 32)))
            let firstRegistration = try V2PushDeviceEndpointRegistration(provider: .apns, environment: .development, token: String(repeating: "a", count: 64))
            let replacement = try V2PushDeviceEndpointRegistration(provider: .apns, environment: .production, token: String(repeating: "b", count: 64))
            let badDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            func snapshot() async throws -> String {
                struct State: Decodable { let value: String }
                return try #require(try await sql.raw("""
                    SELECT jsonb_build_object(
                        'devices', (SELECT jsonb_agg(to_jsonb(r) ORDER BY device_id) FROM im_v2.auth_devices r),
                        'endpoints', (SELECT jsonb_agg(to_jsonb(r) ORDER BY device_id, provider) FROM im_v2.push_device_endpoints r),
                        'intents', (SELECT jsonb_agg(to_jsonb(r) ORDER BY device_id) FROM im_v2.push_device_intents r)
                    )::text AS value
                    """).first(decoding: State.self)).value
            }
            func disable(_ endpoint: V2PushDeviceEndpoint, at time: Date) async throws {
                if ownedDisable {
                    try await store.disableOwnedEndpoint(actorUserID: senderID, deviceID: device, now: time)
                } else { try await store.disable(endpoint, now: time) }
            }
            let empty = try await snapshot()
            for invalid in badDates {
                await #expect(throws: V2PushDeviceEndpointError.unavailable) { try await store.register(actorUserID: senderID, deviceID: device, endpoint: firstRegistration, now: invalid) }
                #expect(try await snapshot() == empty)
            }
            try await store.register(actorUserID: senderID, deviceID: device, endpoint: firstRegistration, now: base)
            let first = try #require(try await store.endpoint(for: device))
            let registered = try await snapshot()
            for invalid in badDates {
                await #expect(throws: V2PushDeviceEndpointError.unavailable) { try await store.register(actorUserID: senderID, deviceID: device, endpoint: replacement, now: invalid) }
                await #expect(throws: V2PushDeviceEndpointError.unavailable) { try await disable(first, at: invalid) }
                #expect(try await snapshot() == registered)
            }
            try await disable(first, at: base.addingTimeInterval(1))
            #expect(try await store.endpoint(for: device) == nil)
            try await store.register(actorUserID: senderID, deviceID: device, endpoint: replacement, now: base.addingTimeInterval(2))
            let replaced = try #require(try await store.endpoint(for: device))
            #expect(replaced.generation != first.generation)
            try await store.disable(first, now: base.addingTimeInterval(3))
            #expect(try await store.endpoint(for: device) == replaced)

            let firstClaim = try V2PushIntentSessionClaim(requestID: UUID(), expectedEpoch: 0)
            let beforeClaim = try await snapshot()
            for invalid in badDates {
                await #expect(throws: V2PushDeviceEndpointError.unavailable) { try await store.claimIntentSession(actorUserID: senderID, deviceID: device, claim: firstClaim, now: invalid) }
                #expect(try await snapshot() == beforeClaim)
            }
            #expect(try await store.claimIntentSession(actorUserID: senderID, deviceID: device, claim: firstClaim, now: base.addingTimeInterval(4)) == 1)
            let secondClaim = try V2PushIntentSessionClaim(requestID: UUID(), expectedEpoch: 1)
            let versionOne = try V2PushIntentVersion(epoch: 1, revision: 1)
            let claimed = try await snapshot()
            for invalid in badDates {
                #expect(try await store.claimIntentSession(actorUserID: senderID, deviceID: device, claim: firstClaim, now: invalid) == 1)
                await #expect(throws: V2PushDeviceEndpointError.unavailable) { try await store.claimIntentSession(actorUserID: senderID, deviceID: device, claim: secondClaim, now: invalid) }
                await #expect(throws: V2PushDeviceEndpointError.unavailable) { try await store.publishIntent(actorUserID: senderID, deviceID: device, version: versionOne, intent: .enabled(firstRegistration), now: invalid) }
                await #expect(throws: V2PushDeviceEndpointError.unavailable) { try await store.publishIntent(actorUserID: senderID, deviceID: device, version: versionOne, intent: .disabled, now: invalid) }
                #expect(try await snapshot() == claimed)
            }
            try await store.publishIntent(actorUserID: senderID, deviceID: device, version: versionOne, intent: .enabled(firstRegistration), now: base.addingTimeInterval(5))
            let enabled = try await snapshot()
            let versionTwo = try V2PushIntentVersion(epoch: 1, revision: 2)
            for invalid in badDates {
                try await store.publishIntent(actorUserID: senderID, deviceID: device, version: versionOne, intent: .enabled(firstRegistration), now: invalid)
                await #expect(throws: V2PushDeviceEndpointError.intentConflict) { try await store.publishIntent(actorUserID: senderID, deviceID: device, version: versionOne, intent: .disabled, now: invalid) }
                await #expect(throws: V2PushDeviceEndpointError.unavailable) { try await store.publishIntent(actorUserID: senderID, deviceID: device, version: versionTwo, intent: .disabled, now: invalid) }
                #expect(try await snapshot() == enabled)
            }
            try await store.publishIntent(actorUserID: senderID, deviceID: device, version: versionTwo, intent: .disabled, now: base.addingTimeInterval(6))
            #expect(try await store.endpoint(for: device) == nil)
            let disabled = try await snapshot()
            for invalid in badDates {
                #expect(try await store.claimIntentSession(actorUserID: senderID, deviceID: device, claim: firstClaim, now: invalid) == 1)
                try await store.publishIntent(actorUserID: senderID, deviceID: device, version: versionTwo, intent: .disabled, now: invalid)
                #expect(try await snapshot() == disabled)
            }
            #expect(try await store.claimIntentSession(actorUserID: senderID, deviceID: device, claim: secondClaim, now: base.addingTimeInterval(7)) == 2)
            try await store.publishIntent(actorUserID: senderID, deviceID: device, version: .init(epoch: 2, revision: 1), intent: .enabled(replacement), now: base.addingTimeInterval(8))
            let restored = try #require(try await store.endpoint(for: device))
            #expect(restored.environment == .production && restored.token == replacement.token)
            let final = try await snapshot()
            for invalid in badDates {
                await #expect(throws: V2PushDeviceEndpointError.staleIntent) { try await store.publishIntent(actorUserID: senderID, deviceID: device, version: versionTwo, intent: .disabled, now: invalid) }
                #expect(try await store.claimIntentSession(actorUserID: senderID, deviceID: device, claim: secondClaim, now: invalid) == 2)
                #expect(try await snapshot() == final)
            }
        }
    }

    @Test("Push wake clock failures preserve admission and recover without double spending", arguments: ["sent", "failed", "suppressed"])
    func pushWakeClockBounds(outcome: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let event = UUID()
            // This regression exercises push admission clocks, independently of message-send setup.
            try await sql.raw("""
                INSERT INTO im_v2.room_events
                    (event_id,room_id,room_sequence,event_type,actor_user_id,payload,committed_membership_revision,created_at)
                VALUES (\(bind: event),\(bind: roomUUID),1,'message.accepted',\(bind: senderUUID),'{}',0,\(bind: base))
                """).run()
            let device = UUID(), mutedDevice = UUID(), dispatch = UUID(), mutedDispatch = UUID()
            try await sql.raw("INSERT INTO im_v2.push_campaigns (campaign_id, state, updated_at) VALUES ('wake', 'enabled', \(bind: base))").run()
            try await sql.raw("""
                INSERT INTO im_v2.push_device_budgets (device_id, campaign_id, window_started_at, max_work_units, max_new_key_operations)
                VALUES (\(bind: device), 'wake', \(bind: base), 1, 1), (\(bind: mutedDevice), 'wake', \(bind: base), 1, 1)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.push_wake_outbox (dispatch_id, source_event_id, source_room_id, target_user_id, target_device_id, campaign_id, budget_window_started_at, requires_new_key_operation, created_at)
                VALUES (\(bind: dispatch), \(bind: event), (SELECT room_id FROM im_v2.room_events WHERE event_id=\(bind: event)), \(bind: memberTwoUUID), \(bind: device), 'wake', \(bind: base), TRUE, \(bind: base)),
                       (\(bind: mutedDispatch), \(bind: event), \(bind: roomUUID), \(bind: memberThreeUUID), \(bind: mutedDevice), 'wake', \(bind: base), TRUE, \(bind: base))
                """).run()
            try await sql.raw("INSERT INTO im_v2.user_room_preferences (revision, user_id, room_id, mute_until, updated_at) VALUES (1, \(bind: memberThreeUUID), \(bind: roomUUID), \(bind: base.addingTimeInterval(3600)), \(bind: base))").run()
            func snapshot() async throws -> String {
                struct State: Decodable { let value: String }
                return try #require(try await sql.raw("""
                    SELECT jsonb_build_object(
                        'wakes', (SELECT jsonb_agg(to_jsonb(r) ORDER BY dispatch_id) FROM im_v2.push_wake_outbox r),
                        'budgets', (SELECT jsonb_agg(to_jsonb(r) ORDER BY device_id, campaign_id, window_started_at) FROM im_v2.push_device_budgets r)
                    )::text AS value
                    """).first(decoding: State.self)).value
            }
            let store = v2FixturePushWakeStore(database: database)
            let initial = try await snapshot()
            let badSeconds: [Double] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12]
            for seconds in badSeconds {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.claimAdmitted(now: Date(timeIntervalSince1970: seconds), leaseDuration: 30, limit: 1) }
                #expect(try await snapshot() == initial)
            }
            for duration in [Double.infinity, .greatestFiniteMagnitude, .leastNonzeroMagnitude, 0.0000001] {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.claimAdmitted(now: base, leaseDuration: duration, limit: 1) }
            }
            let upper = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)
            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.claimAdmitted(now: upper, leaseDuration: 30, limit: 1) }
            for limit in [Int.min, 0] {
                #expect(try await store.claimAdmitted(now: .init(timeIntervalSince1970: .nan), leaseDuration: 30, limit: limit).isEmpty)
            }
            for duration in [Double.nan, 0, -1] {
                #expect(try await store.claimAdmitted(now: .init(timeIntervalSince1970: .nan), leaseDuration: duration, limit: 1).isEmpty)
            }
            #expect(try await snapshot() == initial)
            // The upper bound controls SQL work, not an eager allocation when
            // only one wake is eligible after muted work is suppressed.
            let first = try #require(try await store.claimAdmitted(now: base.addingTimeInterval(1), leaseDuration: 30, limit: Int.max).first)
            #expect(first.wake.dispatchID == dispatch)
            let claimed = try await snapshot()
            for seconds in badSeconds {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.markSent(first, now: Date(timeIntervalSince1970: seconds)) }
                #expect(try await snapshot() == claimed)
            }
            #expect(try await store.claimAdmitted(now: base.addingTimeInterval(30), leaseDuration: 30, limit: 1).isEmpty)
            let second = try #require(try await store.claimAdmitted(now: base.addingTimeInterval(31), leaseDuration: 30, limit: 1).first)
            #expect(second.claimToken != first.claimToken)
            let reclaimed = try await snapshot()
            try await store.release(first)
            try await store.suppress(first, reason: .endpointUnavailable)
            try await store.markSent(first, now: base.addingTimeInterval(32))
            #expect(try await snapshot() == reclaimed)
            try await store.release(second)

            let clock = TestSequenceClock([base])
            let provider = PushTimestampProvider(outcome: outcome)
            let worker = V2PushWakeWorker(store: store, provider: provider, maximumConcurrency: 1, now: { clock.now() })
            let invalidCompletions = outcome == "suppressed" ? [Double.nan] : badSeconds
            for (index, seconds) in invalidCompletions.enumerated() {
                clock.set([base.addingTimeInterval(40 + Double(index) * 40), Date(timeIntervalSince1970: seconds)])
                #expect(try await worker.runOnce(limit: 1) == .init(admittedCount: 1, sentCount: 0, releasedCount: outcome == "suppressed" ? 0 : 1))
                let state = outcome == "suppressed" ? "suppressed" : "pending"
                #expect(try await sql.raw("SELECT state = \(bind: state) AND claim_token IS NULL AND lease_expires_at IS NULL AND sent_at IS NULL AS exists FROM im_v2.push_wake_outbox WHERE dispatch_id = \(bind: dispatch)").first(decoding: ExistsRow.self)?.exists == true)
            }
            #expect(await provider.dispatches() == Array(repeating: dispatch, count: invalidCompletions.count))
            let recovery = PushTimestampProvider(outcome: "sent")
            clock.set([base.addingTimeInterval(400)])
            let healthy = V2PushWakeWorker(store: store, provider: recovery, maximumConcurrency: 1, now: { clock.now() })
            if outcome == "suppressed" {
                #expect(try await healthy.runOnce(limit: 1) == .init(admittedCount: 0, sentCount: 0, releasedCount: 0))
                #expect(await recovery.dispatches().isEmpty)
            } else {
                #expect(try await healthy.runOnce(limit: 1) == .init(admittedCount: 1, sentCount: 1, releasedCount: 0))
                #expect(await recovery.dispatches() == [dispatch])
                #expect(try await sql.raw("SELECT state = 'sent' AND sent_at = \(bind: base.addingTimeInterval(400)) AS exists FROM im_v2.push_wake_outbox WHERE dispatch_id = \(bind: dispatch)").first(decoding: ExistsRow.self)?.exists == true)
            }
            #expect(try await store.claimAdmitted(now: base.addingTimeInterval(401), leaseDuration: 30, limit: Int.max).isEmpty)
            #expect(try await sql.raw("SELECT used_work_units = 1 AND used_new_key_operations = 1 AS exists FROM im_v2.push_device_budgets WHERE device_id = \(bind: device)").first(decoding: ExistsRow.self)?.exists == true)
            #expect(try await sql.raw("SELECT used_work_units = 0 AND used_new_key_operations = 0 AS exists FROM im_v2.push_device_budgets WHERE device_id = \(bind: mutedDevice)").first(decoding: ExistsRow.self)?.exists == true)
            #expect(try await sql.raw("SELECT state = 'suppressed' AND suppression_reason = 'conversation_muted' AND admitted_at IS NULL AS exists FROM im_v2.push_wake_outbox WHERE dispatch_id = \(bind: mutedDispatch)").first(decoding: ExistsRow.self)?.exists == true)
            #expect(try await count("im_v2.messages", on: sql) == 0)
        }
    }

    @Test("Propagation sequence exhaustion preserves whole recipient effects and does not advance the checkpoint",
          arguments: ["profile", "receipt-actor", "receipt-peer"])
    func propagationSequenceBoundary(path: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, userDatabase, sql, userSQL, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let direct = try V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: database), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: forwardImportTestProfile(), roomShardID: "room-a", now: { now })
            let room = try await direct.openedIdentity(actorUserID: senderID,
                operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID), firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            let messages = try V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                store: PostgresV2RoomWriteStore(database: database), shardID: "room-a", epoch: 0),
                capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted = try await messages.send(.init(roomID: room.roomID, actorUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "propagation sequence")) else { throw CancellationError() }
            let operation = UUID()
            let outbox = path == "profile" ? "public_profile_update_outbox" : "read_receipt_preference_propagation_outbox"
            let key = path == "profile" ? "source_event_id" : "operation_id"
            if path == "profile" {
                let directory = V2PostgresPublicIdentityDirectory(database: database,
                    policy: try .init(maximumQueries: 10, window: 60), makeUUID: { operation }, now: { now })
                _ = try await directory.updateDisplayName(for: senderID, displayName: "Sequence profile")
            } else {
                _ = try await V2PostgresAccountPreferencePersistence(database: database, projectionDelivery: SuccessfulProjectionDelivery())
                    .executePreferenceFixture(owner: senderID, operation: .readReceiptPreference(.init(uuid: operation)), value: .readReceipt(allowsDirectReadReceipts: false, allowsGroupReadReceipts: true), now: now)
            }
            if path != "profile" {
                let recipient = path == "receipt-actor" ? senderUUID : memberTwoUUID
                try await sql.raw("""
                    INSERT INTO im_v2.direct_room_owner_routes
                        (lower_user_id, higher_user_id, room_id, room_shard_id, route_epoch, created_at, updated_at)
                    SELECT pair.lower_user_id, pair.higher_user_id, pair.room_id, room.room_shard_id,
                           room.owner_epoch, \(bind: now), \(bind: now)
                    FROM im_v2.direct_room_pairs AS pair JOIN im_v2.rooms AS room USING (room_id)
                    """).run()
                struct Fence: V2UserShardRouteFencing {
                    let database: any Database
                    func withCurrentRoute<Result: Sendable>(for userID: UserID,
                        _ operation: @escaping @Sendable (V2UserShardRoute, any Database) async throws -> Result) async throws -> Result {
                        try await database.transaction { transaction in
                            try await operation(.init(bucket: "user", observedRouterEpoch: 1), transaction)
                        }
                    }
                }
                let source = try PostgresV2UserStateEventOutbox(database: database)
                let projector = try V2RoutedUserStateEventProjector(routeFence: Fence(database: database),
                    registry: V2StaticUserShardStorageRegistry(locations: [.init(bucket: "user", database: userDatabase, schema: "im_v2")]))
                // Consume opening, message and preference stream heads with real
                // delivery before testing the tombstone's allocation failure.
                _ = try await deliverUserStateEvents(source, projector: projector,
                    now: Date().addingTimeInterval(1), leaseDuration: 30, limit: 100)
                #expect(try await count("im_v2.user_state_event_outbox WHERE state IN ('pending','leased')", on: sql) == 0)
                let previousReceiptCount = try #require(try await userSQL.raw("SELECT COUNT(*) AS value FROM im_v2.user_state_event_receipts WHERE user_id = \(bind: recipient)").first(decoding: CountRow.self)).value
                try await userSQL.raw("INSERT INTO im_v2.user_sync_sequences(user_id, next_sequence) VALUES (\(bind: recipient), \(bind: Int64.max)) ON CONFLICT (user_id) DO UPDATE SET next_sequence = EXCLUDED.next_sequence").run()
                let worker = V2ReadReceiptPreferencePropagationWorker(database: database, now: { now })
                #expect(try await worker.runOnce(limit: 1) == .init(claimedOperationCount: 1, projectedRoomCount: 1, completedOperationCount: 1))
                let event = receiptTombstoneSourceEventID(operationID: operation, roomID: try #require(room.roomID.uuidValue))
                // The typed producer samples its elapsed commit time. Candidate
                // eligibility follows that persisted timestamp, not the earlier
                // test clock used to start the preference operation.
                struct CandidateEligibility: Decodable { let value: Date }
                let eligibleAt = try #require(try await sql.raw("SELECT MAX(next_attempt_at) AS value FROM im_v2.user_state_event_outbox WHERE source_event_id = \(bind: event)").first(decoding: CandidateEligibility.self)).value
                let candidates = try await source.claim(now: eligibleAt, leaseDuration: 30, limit: 100)
                    .filter { $0.event.sourceEventID.uuidValue == event }
                #expect(candidates.count == 2)
                for lease in candidates {
                    if lease.event.userID.uuidValue == recipient {
                        for _ in 0..<2 {
                            await #expect(throws: V2UserStateEventError.corruptPersistenceState) { try await projector.project(lease.event) }
                        }
                        try await source.retry(lease, disposition: .pause)
                        #expect(try await userSQL.raw("SELECT COUNT(*) AS value FROM im_v2.user_state_event_receipts WHERE user_id = \(bind: recipient)").first(decoding: CountRow.self)?.value == previousReceiptCount)
                    } else {
                        let sequence = try await projector.project(lease.event)
                        #expect(try await source.acknowledge(lease, sequence: sequence, now: eligibleAt))
                    }
                }
                #expect(try await count("im_v2.user_sync_log WHERE projection_kind = 'direct_read_receipt'", on: userSQL) == 1)
                #expect(try await count("im_v2.read_receipt_preference_propagation_outbox WHERE state = 'completed'", on: sql) == 1)
                try await userSQL.raw("UPDATE im_v2.user_sync_sequences SET next_sequence = \(bind: Int64.max - 1) WHERE user_id = \(bind: recipient)").run()
                try await sql.raw("UPDATE im_v2.user_state_event_outbox SET state = 'pending', next_attempt_at = \(bind: eligibleAt) WHERE source_event_id = \(bind: event) AND user_id = \(bind: recipient)").run()
                let resumed = try await source.claim(now: eligibleAt, leaseDuration: 30, limit: 100)
                    .filter { $0.event.sourceEventID.uuidValue == event }
                #expect(resumed.count == 1)
                let lease = try #require(resumed.first)
                let sequence = try await projector.project(lease.event)
                #expect(sequence == UInt64(Int64.max))
                #expect(try await projector.project(lease.event) == sequence)
                #expect(try await source.acknowledge(lease, sequence: sequence, now: eligibleAt))
                #expect(try await count("im_v2.user_sync_log WHERE projection_kind = 'direct_read_receipt'", on: userSQL) == 2)
                #expect(try await userSQL.raw("SELECT next_sequence AS value FROM im_v2.user_sync_sequences WHERE user_id = \(bind: recipient)").first(decoding: CountRow.self)?.value == Int64.max)
                let committed = try await crossStoreClockState(on: userSQL)
                try await sql.raw("UPDATE im_v2.read_receipt_preference_propagation_outbox SET state = 'pending', completed_at = NULL, enumeration_checkpoint = NULL WHERE operation_id = \(bind: operation)").run()
                #expect(try await worker.runOnce(limit: 1) == .init(claimedOperationCount: 1, projectedRoomCount: 1, completedOperationCount: 1))
                #expect(try await crossStoreClockState(on: userSQL) == committed)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_state_event_outbox WHERE source_event_id = \(bind: event) AND state = 'delivered'").first(decoding: CountRow.self)?.value == 2)
                return
            }
            let recipient = path == "receipt-actor" ? senderUUID : memberTwoUUID
            let needed: Int64 = path == "profile" ? 2 : 1
            try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: recipient), \(bind: Int64.max - needed + 1)) ON CONFLICT (user_id) DO UPDATE SET next_sequence = EXCLUDED.next_sequence").run()
            let before = try await crossStoreClockState(on: sql)
            func run(at date: Date, fails: Bool) async throws {
                if path == "profile" {
                    let worker = V2DirectRoomProfilePropagationWorker(database: database,
                        projectionDelivery: SuccessfulProjectionDelivery(), leaseDuration: 1, now: { date })
                    if fails {
                        await #expect(throws: V2DirectRoomProfilePropagationError.corruptPersistenceState) { try await worker.runOnce(limit: 1) }
                    } else {
                        #expect(try await worker.runOnce(limit: 1) == .init(claimedUpdateCount: 1, projectedRecipientCount: 1, completedUpdateCount: 1))
                    }
                } else {
                    let worker = V2ReadReceiptPreferencePropagationWorker(database: database,
                        leaseDuration: 1,
                        retryPolicy: .init(initialDelay: 1, maximumDelay: 1, maximumAttempts: 10, jitterFraction: 0), now: { date })
                    let report = try await worker.runOnce(limit: 1)
                    #expect(report == .init(claimedOperationCount: 1,
                        projectedRoomCount: fails ? 0 : 1, completedOperationCount: fails ? 0 : 1,
                        releasedOperationCount: fails ? 1 : 0))
                }
            }
            for seconds in [0.0, 2.0] {
                try await run(at: now.addingTimeInterval(seconds), fails: true)
                #expect(try await crossStoreClockState(on: sql) == before)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: outbox) WHERE \(unsafeRaw: key) = \(bind: operation) AND enumeration_checkpoint IS NULL AND completed_at IS NULL AND state = \(bind: path == "profile" ? "claimed" : "pending")").first(decoding: CountRow.self)?.value == 1)
            }
            try await sql.raw("UPDATE im_v2.user_sync_sequences SET next_sequence = \(bind: Int64.max - needed) WHERE user_id = \(bind: recipient)").run()
            try await run(at: now.addingTimeInterval(4), fails: false)
            let event = path == "profile" ? operation : receiptTombstoneSourceEventID(operationID: operation, roomID: try #require(room.roomID.uuidValue))
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_projection_effects WHERE source_event_id = \(bind: event)").first(decoding: CountRow.self)?.value == 2)
            #expect(try await sql.raw("SELECT next_sequence AS value FROM im_v2.user_sync_sequences WHERE user_id = \(bind: recipient)").first(decoding: CountRow.self)?.value == Int64.max)
            let committed = try await crossStoreClockState(on: sql)
            // Revisit the completed page at the exhausted counter. Durable
            // effects must satisfy replay without another allocation.
            try await sql.raw("UPDATE im_v2.\(unsafeRaw: outbox) SET state = 'pending', completed_at = NULL, enumeration_checkpoint = NULL WHERE \(unsafeRaw: key) = \(bind: operation)").run()
            try await run(at: now.addingTimeInterval(6), fails: false)
            #expect(try await crossStoreClockState(on: sql) == committed)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: outbox) WHERE \(unsafeRaw: key) = \(bind: operation) AND state = 'completed'").first(decoding: CountRow.self)?.value == 1)
        }
    }

    @Test("Profile and receipt propagation retain source timestamp bytes across completed-work replay", arguments: ["profile", "receipt"])
    func propagationPersistedTimestampPrecision(path: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, userDatabase, sql, userSQL, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let direct = try V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: database), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: forwardImportTestProfile(), roomShardID: "room-a", now: { now })
            let room = try await direct.openedIdentity(actorUserID: senderID,
                operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID), firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            let messages = try V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                store: PostgresV2RoomWriteStore(database: database), shardID: "room-a", epoch: 0),
                capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted = try await messages.send(.init(roomID: room.roomID, actorUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "propagation clock")) else { throw CancellationError() }
            if path == "receipt" {
                try await sql.raw("""
                    INSERT INTO im_v2.direct_room_owner_routes
                        (lower_user_id, higher_user_id, room_id, room_shard_id, route_epoch, created_at, updated_at)
                    SELECT pair.lower_user_id, pair.higher_user_id, pair.room_id, room.room_shard_id,
                           room.owner_epoch, \(bind: now), \(bind: now)
                    FROM im_v2.direct_room_pairs AS pair JOIN im_v2.rooms AS room USING (room_id)
                    """).run()
            }
            struct Fence: V2UserShardRouteFencing {
                let database: any Database
                func withCurrentRoute<Result: Sendable>(for userID: UserID,
                    _ operation: @escaping @Sendable (V2UserShardRoute, any Database) async throws -> Result) async throws -> Result {
                    try await database.transaction { transaction in
                        try await operation(.init(bucket: "user", observedRouterEpoch: 1), transaction)
                    }
                }
            }
            let projector = try V2RoutedUserStateEventProjector(routeFence: Fence(database: database),
                registry: V2StaticUserShardStorageRegistry(locations: [.init(bucket: "user", database: userDatabase, schema: "im_v2")]))
            let preferences = V2PostgresAccountPreferencePersistence(database: database, projectionDelivery: SuccessfulProjectionDelivery())
            let offsets: [Int64] = [-1, 1, 803_315_200_123_457, -211_813_487_999_999_999, 9_223_371_331_199_999_999]
            for (index, offset) in offsets.enumerated() {
                var buffer = ByteBuffer()
                buffer.writeInteger(offset)
                let timestamp = try V2PersistenceTimestamp(from: &buffer, type: .timestamptz, format: .binary, context: .default)
                let operation = UUID()
                let event: UUID
                let outbox: String
                if path == "profile" {
                    let directory = V2PostgresPublicIdentityDirectory(database: database,
                        policy: try .init(maximumQueries: 10, window: 60), makeUUID: { operation }, now: { now })
                    _ = try await directory.updateDisplayName(for: senderID, displayName: "Clock profile \(index)")
                    event = operation
                    outbox = "public_profile_update_outbox"
                    try await sql.raw("UPDATE im_v2.public_profile_update_outbox SET profile_updated_at = \(bind: timestamp) WHERE source_event_id = \(bind: operation)").run()
                } else {
                    _ = try await preferences.executePreferenceFixture(owner: senderID, operation: .readReceiptPreference(.init(uuid: UUID())), value: .readReceipt(allowsDirectReadReceipts: true, allowsGroupReadReceipts: true), now: now)
                    _ = try await preferences.executePreferenceFixture(owner: senderID, operation: .readReceiptPreference(.init(uuid: operation)), value: .readReceipt(allowsDirectReadReceipts: false, allowsGroupReadReceipts: true), now: now)
                    event = receiptTombstoneSourceEventID(operationID: operation, roomID: try #require(room.roomID.uuidValue))
                    outbox = "read_receipt_preference_propagation_outbox"
                    try await sql.raw("UPDATE im_v2.read_receipt_preference_propagation_outbox SET recorded_at = \(bind: timestamp) WHERE operation_id = \(bind: operation)").run()
                }
                var original: [String]?
                for replay in [false, true] {
                    if replay {
                        let key = path == "profile" ? "source_event_id" : "operation_id"
                        try await sql.raw("UPDATE im_v2.\(unsafeRaw: outbox) SET state = 'pending', completed_at = NULL, enumeration_checkpoint = NULL WHERE \(unsafeRaw: key) = \(bind: operation)").run()
                    }
                    if path == "profile" {
                        let worker = V2DirectRoomProfilePropagationWorker(database: database,
                            projectionDelivery: SuccessfulProjectionDelivery(), now: { now })
                        #expect(try await worker.runOnce(limit: 1) == .init(claimedUpdateCount: 1, projectedRecipientCount: 1, completedUpdateCount: 1))
                    } else {
                        let worker = V2ReadReceiptPreferencePropagationWorker(database: database,
                            now: { now })
                        #expect(try await worker.runOnce(limit: 1) == .init(claimedOperationCount: 1, projectedRoomCount: 1, completedOperationCount: 1))
                    }
                    if path == "receipt" {
                        struct Candidate: Decodable {
                            let userID: UUID
                            let payload: String
                            let createdAt: V2PersistenceTimestamp
                        }
                        let candidates = try await sql.raw("SELECT user_id AS \"userID\", payload::text AS payload, created_at AS \"createdAt\" FROM im_v2.user_state_event_outbox WHERE source_event_id = \(bind: event)").all(decoding: Candidate.self)
                        #expect(candidates.count == 2)
                        for candidate in candidates {
                            #expect(candidate.createdAt == timestamp)
                            let personal = try V2UserStateEvent(sourceEventID: .init(uuid: event), userID: .init(uuid: candidate.userID), kind: .directReadReceipt, payload: Data(candidate.payload.utf8), createdAt: candidate.createdAt)
                            let sequence = try await projector.project(personal)
                            #expect(try await projector.project(personal) == sequence)
                        }
                    }
                    let projectionSQL = path == "profile" ? sql : userSQL
                    var current: [String] = []
                    for table in ["user_sync_log", "user_projection_effects"] {
                        #expect(try await projectionSQL.raw("SELECT COUNT(*) = 2 AND bool_and(created_at = \(bind: timestamp)) AS exists FROM im_v2.\(unsafeRaw: table) WHERE source_event_id = \(bind: event)").first(decoding: ExistsRow.self)?.exists == true)
                        guard let rows = try await projectionSQL.raw("SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id, projection_kind)::text AS value FROM im_v2.\(unsafeRaw: table) r WHERE source_event_id = \(bind: event)").first(decoding: StringValueRow.self) else { throw CancellationError() }
                        current.append(rows.value)
                    }
                    if let original { #expect(current == original) } else { original = current }
                    let column = path == "profile" ? "updated_at_ms" : "recorded_at_ms"
                    let kind = path == "profile" ? "direct_room_profile" : "direct_read_receipt"
                    #expect(try await projectionSQL.raw("SELECT bool_and((payload->>\(bind: column))::bigint = \(bind: try v2GatewayMilliseconds(timestamp.date))) AS exists FROM im_v2.user_sync_log WHERE source_event_id = \(bind: event) AND projection_kind = \(bind: kind)").first(decoding: ExistsRow.self)?.exists == true)
                }
            }
        }
    }

    @Test("Profile propagation bounds clocks, empty work and replayed pages", arguments: [false, true])
    func profilePropagationClockBounds(hasTargets: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            if hasTargets {
                let direct = try V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: database), projectionDelivery: SuccessfulProjectionDelivery()), capacityProfile: forwardImportTestProfile(), roomShardID: "room-a", now: { base })
                let messages = V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                    store: PostgresV2RoomWriteStore(database: database,
                        strangerMessagePolicy: try .init(maximumMessagesPerWindow: 3, window: 86_400)),
                    shardID: "room-a", epoch: 0), capacityProfile: try forwardImportTestProfile(), limits: try .init(maxUTF8Bytes: 64), now: { base })
                for peer in [memberTwoUUID, memberThreeUUID] {
                    let room = try await direct.openedIdentity(actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: peer), firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(base))
                    guard case .accepted = try await messages.send(.init(roomID: room.roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "existing conversation")) else { throw V2RoomWriteStoreError.corruptPersistenceState }
                }
            }
            let event = UUID()
            let clock = TestSequenceClock([base.addingTimeInterval(1)])
            let directory = V2PostgresPublicIdentityDirectory(database: database, policy: try .init(maximumQueries: 10, window: 60), makeUUID: { event }, now: { clock.now() })
            func worker(lifetime: TimeInterval = 30) -> V2DirectRoomProfilePropagationWorker {
                .init(database: database, projectionDelivery: SuccessfulProjectionDelivery(), leaseDuration: lifetime, now: { clock.now() })
            }
            func snapshot() async throws -> String {
                struct State: Decodable { let value: String }
                return try #require(try await sql.raw("""
                    SELECT jsonb_build_object(
                        'profiles', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id) FROM im_v2.public_user_profiles r),
                        'outbox', (SELECT jsonb_agg(to_jsonb(r) ORDER BY source_event_id) FROM im_v2.public_profile_update_outbox r),
                        'sequences', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id) FROM im_v2.user_sync_sequences r),
                        'logs', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id, user_sync_sequence) FROM im_v2.user_sync_log r),
                        'effects', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id, source_event_id, projection_kind) FROM im_v2.user_projection_effects r)
                    )::text AS value
                    """).first(decoding: State.self)).value
            }
            let badSeconds: [Double] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12]
            let beforeUpdate = try await snapshot()
            for seconds in badSeconds {
                clock.set([Date(timeIntervalSince1970: seconds)])
                await #expect(throws: V2PublicIdentityDirectoryError.unavailable) { try await directory.updateDisplayName(for: senderID, displayName: "new profile") }
                #expect(try await directory.updateDisplayName(for: senderID, displayName: "发送者").displayName == "发送者")
                #expect(try await snapshot() == beforeUpdate)
            }
            clock.set([base.addingTimeInterval(1)])
            #expect(try await directory.updateDisplayName(for: senderID, displayName: "new profile").displayName == "new profile")
            let pending = try await snapshot()
            for limit in [Int.min, -1, 0, Int.max] {
                await #expect(throws: V2DirectRoomProfilePropagationError.invalidLimit) { try await worker().runOnce(limit: limit) }
            }
            for seconds in badSeconds {
                clock.set([Date(timeIntervalSince1970: seconds)])
                await #expect(throws: V2DirectRoomProfilePropagationError.corruptPersistenceState) { try await worker().runOnce(limit: 2) }
                #expect(try await snapshot() == pending)
            }
            clock.set([Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)])
            await #expect(throws: V2DirectRoomProfilePropagationError.corruptPersistenceState) { try await worker().runOnce(limit: 2) }
            clock.set([base])
            for lifetime in [Double.infinity, .greatestFiniteMagnitude, .leastNonzeroMagnitude, 0.0000001] {
                await #expect(throws: V2DirectRoomProfilePropagationError.corruptPersistenceState) { try await worker(lifetime: lifetime).runOnce(limit: 2) }
            }
            #expect(try await snapshot() == pending)

            for (index, seconds) in badSeconds.enumerated() {
                let claimTime = base.addingTimeInterval(2 + Double(index) * 40)
                clock.set([claimTime, Date(timeIntervalSince1970: seconds)])
                await #expect(throws: V2DirectRoomProfilePropagationError.corruptPersistenceState) { try await worker().runOnce(limit: hasTargets ? 2 : 1) }
                #expect(try await sql.raw("""
                    SELECT state = 'claimed' AND retry_count = \(bind: index)
                        AND enumeration_checkpoint IS NULL AND completed_at IS NULL
                        AND claim_token IS NOT NULL AND lease_expires_at = \(bind: claimTime.addingTimeInterval(30)) AS exists
                    FROM im_v2.public_profile_update_outbox WHERE source_event_id = \(bind: event)
                    """).first(decoding: ExistsRow.self)?.exists == true)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE source_event_id = \(bind: event)").first(decoding: CountRow.self)?.value == (hasTargets ? 4 : 0))
            }
            let resumedAt = base.addingTimeInterval(400)
            clock.set([resumedAt, Date(timeIntervalSince1970: .nan)])
            if hasTargets {
                // A partial-page checkpoint has no timestamp to bind. Its
                // progress remains valid even if that unused sample fails.
                #expect(try await worker().runOnce(limit: 1) == .init(claimedUpdateCount: 1, projectedRecipientCount: 1, completedUpdateCount: 0))
                #expect(try await count("im_v2.public_profile_update_outbox WHERE state = 'pending' AND enumeration_checkpoint IS NOT NULL", on: sql) == 1)
            }
            clock.set([resumedAt.addingTimeInterval(1)])
            #expect(try await worker().runOnce(limit: 1) == .init(claimedUpdateCount: 1, projectedRecipientCount: hasTargets ? 1 : 0, completedUpdateCount: 1))
            #expect(try await worker().runOnce(limit: 1).claimedUpdateCount == 0)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE source_event_id = \(bind: event)").first(decoding: CountRow.self)?.value == (hasTargets ? 4 : 0))
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_projection_effects WHERE source_event_id = \(bind: event)").first(decoding: CountRow.self)?.value == (hasTargets ? 4 : 0))
            #expect(try await sql.raw("""
                SELECT state = 'completed' AND claim_token IS NULL AND lease_expires_at IS NULL
                    AND completed_at = \(bind: resumedAt.addingTimeInterval(1)) AS exists
                FROM im_v2.public_profile_update_outbox WHERE source_event_id = \(bind: event)
                """).first(decoding: ExistsRow.self)?.exists == true)
            if !hasTargets {
                // No direct recipients must not allow an unlimited number of
                // source updates to evade a one-item worker budget.
                for peer in [memberTwoUUID, memberThreeUUID] {
                    let other = V2PostgresPublicIdentityDirectory(database: database, policy: try .init(maximumQueries: 10, window: 60), now: { resumedAt })
                    _ = try await other.updateDisplayName(for: .init(uuid: peer), displayName: "empty graph")
                }
                #expect(try await count("im_v2.public_profile_update_outbox WHERE state = 'pending'", on: sql) == 2)
                #expect(try await worker().runOnce(limit: 1) == .init(claimedUpdateCount: 1, projectedRecipientCount: 0, completedUpdateCount: 1))
                #expect(try await count("im_v2.public_profile_update_outbox WHERE state = 'pending'", on: sql) == 1)
                #expect(try await worker().runOnce(limit: 1) == .init(claimedUpdateCount: 1, projectedRecipientCount: 0, completedUpdateCount: 1))
                #expect(try await count("im_v2.public_profile_update_outbox WHERE state = 'pending'", on: sql) == 0)
            }
        }
    }

    @Test("Receipt propagation rejects invalid clocks and recovers without duplicate tombstones", arguments: ["complete", "retry", "pause"])
    func receiptPropagationClockBounds(path: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let direct = try V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: database), projectionDelivery: SuccessfulProjectionDelivery()), capacityProfile: forwardImportTestProfile(), roomShardID: "room-a", now: { base })
            _ = try await direct.openedReceipt(actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID), firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(base))
            try await sql.raw("""
                INSERT INTO im_v2.direct_room_owner_routes
                    (lower_user_id, higher_user_id, room_id, room_shard_id, route_epoch, created_at, updated_at)
                SELECT pair.lower_user_id, pair.higher_user_id, pair.room_id, room.room_shard_id,
                       room.owner_epoch, \(bind: base), \(bind: base)
                FROM im_v2.direct_room_pairs AS pair JOIN im_v2.rooms AS room USING (room_id)
                """).run()
            try await sql.raw("CREATE TABLE im_v2.test_receipt_finalize_failure(enabled boolean NOT NULL)").run()
            try await sql.raw("INSERT INTO im_v2.test_receipt_finalize_failure VALUES (false)").run()
            try await sql.raw("""
                CREATE FUNCTION im_v2.test_reject_receipt_finalize() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    IF NEW.state = 'completed' AND (SELECT enabled FROM im_v2.test_receipt_finalize_failure) THEN
                        RAISE EXCEPTION 'injected receipt finalization interruption' USING ERRCODE = '08006';
                    END IF;
                    RETURN NEW;
                END $$
                """).run()
            try await sql.raw("CREATE TRIGGER test_receipt_finalize BEFORE UPDATE ON im_v2.read_receipt_preference_propagation_outbox FOR EACH ROW EXECUTE FUNCTION im_v2.test_reject_receipt_finalize()").run()
            let operation = UUID()
            let preferences = V2PostgresAccountPreferencePersistence(database: database, projectionDelivery: SuccessfulProjectionDelivery())
            guard case .receipt(let proof) = try await preferences.executePreferenceFixture(owner: senderID, operation: .readReceiptPreference(.init(uuid: operation)), value: .readReceipt(allowsDirectReadReceipts: false, allowsGroupReadReceipts: true), now: base), case .applied = proof.outcome else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let clock = TestSequenceClock([base])
            let policy = V2DurableRetryPolicy(initialDelay: 2, maximumDelay: 2, maximumAttempts: path == "pause" ? 1 : 3, jitterFraction: 0)
            func run(limit: Int = 1, lifetime: TimeInterval = 30, retry: V2DurableRetryPolicy? = nil,
                     fails: Bool = false) async throws -> V2ReadReceiptPreferencePropagationReport {
                try await sql.raw("UPDATE im_v2.test_receipt_finalize_failure SET enabled = \(bind: fails)").run()
                return try await V2ReadReceiptPreferencePropagationWorker(database: database,
                    leaseDuration: lifetime, retryPolicy: retry ?? policy, now: { clock.now() }).runOnce(limit: limit)
            }
            func snapshot() async throws -> String {
                struct State: Decodable { let value: String }
                return try #require(try await sql.raw("""
                    SELECT jsonb_build_object(
                        'outbox', (SELECT jsonb_agg(to_jsonb(r) ORDER BY actor_user_id, operation_id) FROM im_v2.read_receipt_preference_propagation_outbox r),
                        'events', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id, source_event_id, projection_kind) FROM im_v2.user_state_event_outbox r),
                        'sequences', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id) FROM im_v2.user_sync_sequences r),
                        'logs', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id, user_sync_sequence) FROM im_v2.user_sync_log r),
                        'effects', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id, source_event_id, projection_kind) FROM im_v2.user_projection_effects r)
                    )::text AS value
                    """).first(decoding: State.self)).value
            }
            let initial = try await snapshot()
            for limit in [Int.min, -1, 0, Int.max] {
                await #expect(throws: V2ReadReceiptPreferencePropagationError.invalidLimit) { try await run(limit: limit) }
            }
            let badSeconds: [Double] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12]
            for seconds in badSeconds {
                clock.set([Date(timeIntervalSince1970: seconds)])
                await #expect(throws: V2ReadReceiptPreferencePropagationError.corruptPersistenceState) { try await run() }
                #expect(try await snapshot() == initial)
            }
            clock.set([Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)])
            await #expect(throws: V2ReadReceiptPreferencePropagationError.corruptPersistenceState) { try await run() }
            clock.set([base])
            for lifetime in [Double.infinity, .greatestFiniteMagnitude, .leastNonzeroMagnitude, 0.0000001] {
                await #expect(throws: V2ReadReceiptPreferencePropagationError.corruptPersistenceState) { try await run(lifetime: lifetime) }
            }
            #expect(try await snapshot() == initial)

            // Each attempt owns a valid lease. The clock fails only after
            // candidates have committed and the finalization transaction fails.
            // Advancing real time lets the next worker recover that lease.
            for (index, seconds) in badSeconds.enumerated() {
                let claimTime = base.addingTimeInterval(Double(index) * 40)
                let invalid = Date(timeIntervalSince1970: seconds)
                clock.set(path == "complete" ? [claimTime, invalid, invalid] : [claimTime, invalid])
                await #expect(throws: V2ReadReceiptPreferencePropagationError.corruptPersistenceState) {
                    try await run(fails: path != "complete")
                }
                #expect(try await sql.raw("""
                    SELECT state = 'claimed' AND retry_count = 0 AND enumeration_checkpoint IS NULL
                        AND next_attempt_at IS NULL AND paused_at IS NULL AND completed_at IS NULL
                        AND claim_token IS NOT NULL AND lease_expires_at = \(bind: claimTime.addingTimeInterval(30)) AS exists
                    FROM im_v2.read_receipt_preference_propagation_outbox
                    WHERE actor_user_id = \(bind: senderUUID) AND operation_id = \(bind: operation)
                    """).first(decoding: ExistsRow.self)?.exists == true)
                #expect(try await count("im_v2.user_sync_log WHERE projection_kind = 'direct_read_receipt'", on: sql) == 0)
                #expect(try await count("im_v2.user_state_event_outbox WHERE projection_kind = 'direct_read_receipt'", on: sql) == 2)
            }
            var resumedAt = base.addingTimeInterval(400)
            if path == "retry" {
                // The clock can encode while the derived retry deadline cannot.
                clock.set([resumedAt, Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 0.5)])
                await #expect(throws: V2ReadReceiptPreferencePropagationError.corruptPersistenceState) { try await run(fails: true) }
                resumedAt = resumedAt.addingTimeInterval(40)
                clock.set([resumedAt])
                let excessive = V2DurableRetryPolicy(initialDelay: .greatestFiniteMagnitude, maximumDelay: .greatestFiniteMagnitude, maximumAttempts: 3, jitterFraction: 0)
                await #expect(throws: V2ReadReceiptPreferencePropagationError.corruptPersistenceState) { try await run(retry: excessive, fails: true) }
                #expect(try await count("im_v2.read_receipt_preference_propagation_outbox WHERE state = 'claimed' AND retry_count = 0 AND next_attempt_at IS NULL", on: sql) == 1)
                resumedAt = resumedAt.addingTimeInterval(40)
            }
            clock.set([resumedAt])
            if path != "complete" {
                // 依赖缺失是瞬时失败：两条路径都只安排重试，不再因预算耗尽而暂停。
                #expect(try await run(fails: true) == .init(claimedOperationCount: 1, projectedRoomCount: 1, completedOperationCount: 0, releasedOperationCount: 1))
                clock.set([resumedAt.addingTimeInterval(1)])
                #expect(try await run().claimedOperationCount == 0)
                if path == "pause" {
                    // 新契约下暂停只来自确定性失败；这里显式构造暂停行，
                    // 以继续覆盖 replay 的时钟恢复路径。
                    try await sql.raw("""
                        UPDATE im_v2.read_receipt_preference_propagation_outbox
                        SET state = 'paused', paused_at = \(bind: resumedAt), next_attempt_at = NULL,
                            claim_token = NULL, lease_expires_at = NULL
                        WHERE actor_user_id = \(bind: senderUUID) AND operation_id = \(bind: operation)
                        """).run()
                    let result = try await verifyDurableReplayClockRecovery(
                        .init(operationID: UUID(), target: try .init(kind: .readReceiptPreferencePropagation, sourceEventID: .init(uuid: operation), targetUserID: senderID), reason: .dependencyRecovered),
                        store: PostgresV2DurableWorkReplayStore(database: database), sql: sql, operatorPrincipal: "integration-test", now: resumedAt.addingTimeInterval(2))
                    #expect(result.outcome == .requeued)
                }
                resumedAt = resumedAt.addingTimeInterval(2)
                clock.set([resumedAt])
            }
            #expect(try await run() == .init(claimedOperationCount: 1, projectedRoomCount: 1, completedOperationCount: 1))
            #expect(try await run(limit: Int.max - 1).claimedOperationCount == 0)
            #expect(try await count("im_v2.user_sync_log WHERE projection_kind = 'direct_read_receipt'", on: sql) == 0)
            #expect(try await count("im_v2.user_state_event_outbox WHERE projection_kind = 'direct_read_receipt'", on: sql) == 2)
            #expect(try await sql.raw("""
                SELECT state = 'completed' AND claim_token IS NULL AND lease_expires_at IS NULL
                    AND completed_at = \(bind: resumedAt) AS exists
                FROM im_v2.read_receipt_preference_propagation_outbox
                WHERE actor_user_id = \(bind: senderUUID) AND operation_id = \(bind: operation)
                """).first(decoding: ExistsRow.self)?.exists == true)
        }
    }

    @Test("Shadow forwarding retains exact source timestamps across scalar and batch replay",
          arguments: [false, true], ["scalar", "batch", "batch-fallback"])
    func shadowForwardingTimestampPrecision(coLocated: Bool, path: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, target, controlSQL, targetSQL, _ in
            let user = UUID(), userID = UserID(uuid: user)
            let liveSchema = coLocated ? "im_v2" : "im_v2_live_clock"
            if !coLocated { try await installSchema(on: targetSQL, schema: liveSchema) }
            do {
                let now = Date(timeIntervalSince1970: 1_750_000_000)
                try await configureDefaultUserShardRoute(.init(bucket: "users-source", observedRouterEpoch: 1), now: now, on: controlSQL)
                let registry = try V2StaticUserShardStorageRegistry(locations: [
                    .init(bucket: "users-source", database: coLocated ? control : target, schema: liveSchema)])
                let router = V2PostgresUserShardRouter(database: control)
                let shadow = V2PostgresUserShardProjectionDelivery(registry: registry, routeFence: router,
                    batchRouteFence: path == "batch" ? router : nil,
                    coLocatedControlBuckets: coLocated ? ["users-source"] : [])
                let offsets: [Int64] = [-1, 1, 803_315_200_123_457, -211_813_487_999_999_999, 9_223_371_331_199_999_999]
                try await controlSQL.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: user), \(bind: Int64(offsets.count * 2)))").run()
                func snapshot(schema: String, on sql: any SQLDatabase) async throws -> String {
                    guard let row = try await sql.raw("""
                        SELECT jsonb_build_object(
                            'log', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_sync_sequence) FROM \(unsafeRaw: schema).user_sync_log r WHERE user_id = \(bind: user)),
                            'effects', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_sync_sequence) FROM \(unsafeRaw: schema).user_projection_effects r WHERE user_id = \(bind: user))
                        )::text AS value
                        """).first(decoding: StringValueRow.self) else { throw CancellationError() }
                    return row.value
                }
                for (index, offset) in offsets.enumerated() {
                    var buffer = ByteBuffer()
                    buffer.writeInteger(offset)
                    let timestamp = try V2PersistenceTimestamp(from: &buffer, type: .timestamptz, format: .binary, context: .default)
                    var requests: [V2UserShardProjectionDeliveryRequest] = []
                    for item in 0..<2 {
                        let event = UUID()
                        let sequence = Int64(index * 2 + item + 1)
                        try await controlSQL.raw("""
                            INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                            VALUES (\(bind: user), \(bind: sequence), \(bind: event), 'stranger_message_permission',
                                '{"permission":"allow","updated_at_ms":1000}'::jsonb, \(bind: timestamp))
                            """).run()
                        requests.append(.init(userID: userID, sourceEventID: .init(uuid: event), projectionKinds: ["stranger_message_permission"]))
                    }
                    let expected = try await snapshot(schema: "im_v2", on: controlSQL)
                    for _ in 0..<2 {
                        var sequences: [UInt64?] = []
                        if path == "scalar" {
                            for request in requests {
                                sequences.append(try await shadow.deliverToCurrentShard(userID: request.userID, sourceEventID: request.sourceEventID, projectionKinds: request.projectionKinds))
                            }
                        } else { sequences = try await shadow.deliverToCurrentShard(requests) }
                        #expect(sequences == [UInt64(index * 2 + 1), UInt64(index * 2 + 2)])
                        #expect(try await snapshot(schema: liveSchema, on: coLocated ? controlSQL : targetSQL) == expected)
                        #expect(try await snapshot(schema: "im_v2", on: controlSQL) == expected)
                    }
                }
            } catch {
                if !coLocated { try? await targetSQL.raw("DROP SCHEMA IF EXISTS im_v2_live_clock CASCADE").run() }
                throw error
            }
            if !coLocated { try await targetSQL.raw("DROP SCHEMA im_v2_live_clock CASCADE").run() }
        }
    }








    @Test("Cross-store writes reject invalid clocks before effects and preserve durable replay", arguments: ["mirror", "allocated"])
    func crossStoreWriteClockBoundaries(path: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { _, database, _, sql, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let user = UserID(uuid: UUID()), event = EventID(uuid: UUID()), nextEvent = EventID(uuid: UUID())
            let projector = try PostgresV2UserProjectionStore(database: database, schema: "im_v2")
            func write(_ source: EventID, at date: Date) async throws -> UInt64 {
                switch path {
                case "mirror":
                    return try await projector.mirror(.init(userID: user, sequence: source == event ? 1 : 2, sourceEventID: source, projectionKind: "stranger_permission", payloadJSON: "{}", createdAt: date))
                default:
                    return try await projector.projectAllocated(userID: user, sourceEventID: source, projectionKind: "stranger_permission", payloadJSON: "{}", createdAt: date)
                }
            }
            let invalidDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            let empty = try await crossStoreClockState(on: sql)
            for invalid in invalidDates {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await write(event, at: invalid) }
            }
            #expect(try await crossStoreClockState(on: sql) == empty)
            #expect(try await write(event, at: now) == 1)
            #expect(try await write(event, at: now.addingTimeInterval(1)) == 1)
            let committed = try await crossStoreClockState(on: sql)
            for invalid in invalidDates {
                if path == "mirror" || path == "allocated" {
                    // These paths find the immutable effect before writing
                    // any timestamp. Preserve their clock-independent replay.
                    #expect(try await write(event, at: invalid) == 1)
                } else {
                    await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await write(event, at: invalid) }
                }
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await write(nextEvent, at: invalid) }
            }
            #expect(try await crossStoreClockState(on: sql) == committed)
            #expect(try await write(nextEvent, at: now.addingTimeInterval(2)) == 2)
            #expect(try await write(event, at: now.addingTimeInterval(3)) == 1)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 2)
            #expect(try await count("im_v2.user_projection_effects", on: sql) == 2)
            #expect(try await count("im_v2.user_sync_sequences WHERE next_sequence = 2", on: sql) == 1)
        }
    }

}

private actor PushTimestampProvider: V2PushWakeProvider {
    private let outcome: String
    private var values: [UUID] = []
    init(outcome: String) { self.outcome = outcome }
    func send(_ wake: V2GenericPushWake) async throws -> V2PushWakeProviderOutcome {
        values.append(wake.dispatchID)
        if outcome == "failed" { throw V2RoomWriteStoreError.corruptPersistenceState }
        return outcome == "suppressed" ? .suppressed(.endpointRejected) : .sent
    }
    func dispatches() -> [UUID] { values }
}

/// Exercise real paused jobs through clock failure, concurrent recovery and
/// retry. Callers continue their normal workers after this recovery succeeds.
