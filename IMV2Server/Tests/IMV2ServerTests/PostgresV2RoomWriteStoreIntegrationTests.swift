import Crypto
import FluentKit
import FluentPostgresDriver
import Foundation
import HTTPTypes
#if os(macOS)
import Darwin
internal final class GroupJoinQuotaCrashBundleMarker: NSObject {}
#endif
import IMV2ActorContracts
import IMV2Core
import IMV2ServerHTTP
import PostgresNIO
@testable import IMV2Server
import SQLKit
import Synchronization
import Testing
import Vapor
import VaporTesting


@Suite("V2 PostgreSQL room write", .serialized)
struct PostgresV2RoomWriteStoreIntegrationTests {
    #if os(macOS)
    @Test("SIGKILL at distributed submission checkpoints preserves quota and resumes exact receipts",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1" && ProcessInfo.processInfo.environment["IMV2_JOIN_QUOTA_CRASH_STAGE"] == nil),
          arguments: ["reserved", "owner", "confirmed", "terminal", "approved", "rejected"])
    func groupJoinQuotaKilledRecovery(_ stage: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, sql, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000), applicant = UserID(uuid: UUID()), inviteID = GroupInviteID(uuid: UUID())
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            try await sql.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at) VALUES (\(bind: applicant.uuidValue!), 'crash_quota', 'Applicant', \(bind: now), \(bind: now))").run()
            try await sql.raw("INSERT INTO im_v2.room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES (\(bind: room.uuidValue!), 'room-b',0,\(bind: now),\(bind: now)) ON CONFLICT (room_id) DO UPDATE SET room_shard_id = EXCLUDED.room_shard_id, route_epoch = EXCLUDED.route_epoch, updated_at = EXCLUDED.updated_at").run()
            let routed = V2RoutedGroupInvitationStore(controlDatabase: control, router: V2PostgresRoomShardRouter(database: control), owners: try V2StaticRoomShardStorageRegistry(locations: [.init(shardID: "room-b", database: owner, schema: "im_v2")]))
            let digest = Data(repeating: 35, count: 32), requestID = GroupJoinRequestID(uuid: UUID()), operation = GroupJoinRequestOperationID(uuid: UUID())
            _ = try await routed.create(.init(inviteID: inviteID, roomID: room, actorUserID: senderID, operationID: .init(uuid: UUID()), tokenDigest: digest, requestedLifetimeSeconds: 3600, expiresAt: now.addingTimeInterval(3600), maximumApprovedUses: 10, maximumActiveInvitesPerRoom: 20, createdAt: now))
            let process = Process(), host = URL(fileURLWithPath: CommandLine.arguments[0])
            let binary = try #require(Bundle(for: GroupJoinQuotaCrashBundleMarker.self).executableURL)
            try #require(host.lastPathComponent == "swiftpm-testing-helper")
            process.executableURL = host
            process.arguments = ["--test-bundle-path", binary.path, binary.path, "--testing-library", "swift-testing", "--filter", "groupJoinQuotaCrashChild"]
            var environment = ProcessInfo.processInfo.environment
            environment["IMV2_JOIN_QUOTA_CRASH_STAGE"] = stage
            let fields = ["room": room.rawValue, "invite": inviteID.rawValue, "applicant": applicant.rawValue, "request": requestID.rawValue, "operation": operation.rawValue]
            environment["IMV2_JOIN_QUOTA_CRASH_INPUT"] = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    process.terminationHandler = { _ in continuation.resume() }
                    do { try process.run() } catch { continuation.resume(throwing: error) }
                }
            } onCancel: { if process.isRunning { process.terminate() } }
            try #require(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL)
            #expect(try await count("im_v2.group_join_quota_intents WHERE phase IN ('held','tracking')", on: sql) == 1)
            #expect(try await count("im_v2.group_join_requests", on: ownerSQL) == (stage == "reserved" ? 0 : 1))
            // A new process owner uses only durable rows, not the child's tasks or responses.
            let worker = V2GroupJoinQuotaRecoveryWorker(controlDatabase: control, invitations: routed, now: { now.addingTimeInterval(61) })
            let report = try await worker.runOnce(limit: 8)
            #expect(report.attempted == 1 && report.reconciled == 1 && report.deferred == 0)
            #expect(try await worker.runOnce(limit: 8).attempted == 0)
            #expect(try await count("im_v2.group_join_requests", on: ownerSQL) == 1)
            #expect(try await count("im_v2.group_join_submission_receipts", on: ownerSQL) == 1)
            #expect(try await count("im_v2.group_join_quota_intents WHERE phase IN ('held','tracking')", on: sql) == (["terminal", "approved", "rejected"].contains(stage) ? 0 : 1))
            let replay = try await routed.submit(.init(requestID: requestID, applicantUserID: applicant, operationID: operation, tokenDigest: digest, note: nil, createdAt: now.addingTimeInterval(62), maximumPendingRequestsPerApplicant: 1, maximumPendingRequestsPerInvite: 1))
            switch replay {
            case .cancelled: #expect(stage == "terminal")
            case .alreadyMember: #expect(stage == "approved")
            case .rejected: #expect(stage == "rejected")
            case .alreadyPending: #expect(!["terminal", "approved", "rejected"].contains(stage))
            default: Issue.record("Unexpected recovered result: \(replay)")
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_JOIN_QUOTA_CRASH_STAGE"] != nil))
    func groupJoinQuotaCrashChild() async throws {
        let stage = try #require(ProcessInfo.processInfo.environment["IMV2_JOIN_QUOTA_CRASH_STAGE"])
        let raw = try #require(ProcessInfo.processInfo.environment["IMV2_JOIN_QUOTA_CRASH_INPUT"])
        let fields = try JSONDecoder().decode([String: String].self, from: Data(raw.utf8))
        let resources = makeV2DatabaseTestResources()
        do {
            let controlURL = try #require(Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL")), ownerURL = try #require(Environment.get("IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"))
            let ownerID = DatabaseID(string: "quota-child-owner")
            resources.databases.use(try .postgres(url: controlURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            resources.databases.use(try .postgres(url: ownerURL, maxConnectionsPerEventLoop: 2), as: ownerID)
            let control = resources.database(.psql), owner = resources.database(ownerID)
            let room = try RoomID(#require(fields["room"])), invite = try GroupInviteID(#require(fields["invite"]))
            let applicant = try UserID(#require(fields["applicant"])), requestID = try GroupJoinRequestID(#require(fields["request"]))
            let operation = try GroupJoinRequestOperationID(#require(fields["operation"])), now = Date(timeIntervalSince1970: 1_750_000_000)
            let quota = PostgresV2GroupJoinQuotaStore(database: control)
            let request = V2GroupJoinSubmissionPersistenceRequest(requestID: requestID, applicantUserID: applicant, operationID: operation, tokenDigest: Data(repeating: 35, count: 32), note: nil, createdAt: now, maximumPendingRequestsPerApplicant: 1, maximumPendingRequestsPerInvite: 1)
            guard case .reserved(let intent) = try await quota.reserve(request, roomID: room, inviteID: invite, now: now) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            if stage != "reserved" {
                let store = PostgresV2GroupInvitationStore(database: owner, identities: PostgresV2GroupInvitationIdentityReader(database: control), scope: .init(roomID: room.uuidValue!, route: try .init(shardID: "room-b", epoch: 0), inviteID: invite.uuidValue!))
                let receipt = try await store.applyReservedSubmission(intent, now: now)
                if ["confirmed", "terminal", "approved", "rejected"].contains(stage) {
                    try await quota.resolve(intent, outcome: receipt.outcome, targetRequestID: receipt.targetRequestID, now: now)
                }
                if stage == "terminal" { _ = try await store.cancel(roomID: room, requestID: requestID, applicantUserID: applicant, now: now) }
                if stage == "approved" {
                    let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
                    guard case .approved = try await store.approve(roomID: room, requestID: requestID, reviewerUserID: senderID, operationID: .init(uuid: UUID()), capacityProfile: profile, eventID: .init(uuid: UUID()), now: now) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                } else if stage == "rejected" {
                    guard case .rejected = try await store.reject(roomID: room, requestID: requestID, reviewerUserID: senderID, operationID: .init(uuid: UUID()), now: now) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                }
            }
            kill(getpid(), SIGKILL)
            fatalError("SIGKILL must terminate the child")
        } catch {
            try? await resources.shutdown()
            throw error
        }
    }
    #endif




    @Test("submissions enforce twenty pending requests across two owner databases")
    func groupJoinGlobalQuotaAcrossOwners() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, secondOwner, sql, secondSQL, secondRoom in
            let now = Date(timeIntervalSince1970: 1_750_000_000), applicant = UserID(uuid: UUID())
            for db in [sql, secondSQL] { try await db.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run() }
            try await sql.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at) VALUES (\(bind: applicant.uuidValue!), 'global_applicant', 'Applicant', \(bind: now), \(bind: now))").run()
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            // Production path: the control coordinator calls each room owner
            // through a room turn; the first room's owner is the control database.
            let port = invitationRoomPort(control: control, owner: { $0 == roomID ? (control, "room-a", 0) : (secondOwner, "room-b", 0) },
                                          capacityProfile: profile, now: { now })
            let coordinator = V2ActorInvitationCoordinator(controlDatabase: control, room: port,
                secretIssuer: try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 0x5a, count: 32)), now: { now })
            var submissions: [V2ActorSubmitGroupJoinWire] = []
            for index in 0..<40 {
                let room = index.isMultiple(of: 2) ? roomID : secondRoom
                guard case .created(let link) = try await coordinator.create(.init(roomID: room, actorUserID: senderID,
                    operationID: .init(uuid: UUID()), lifetime: 3600, maximumApprovedUses: 10), deadline: invitationTestDeadline()) else {
                    throw V2GroupInvitationServiceError.corruptPersistenceState
                }
                submissions.append(.init(applicantUserID: applicant, operationID: .init(uuid: UUID()), secret: link.secret, note: nil))
            }
            @Sendable func submit(_ input: V2ActorSubmitGroupJoinWire) async throws -> V2ActorGroupJoinSubmissionOutcomeWire {
                guard case .submission(let value) = try await coordinator.submitBySecret(input, deadline: invitationTestDeadline()) else {
                    throw V2GroupInvitationServiceError.corruptPersistenceState
                }
                return value
            }
            let seeded: [(Int, V2ActorGroupJoinSubmissionOutcomeWire)] = [(0, try await submit(submissions[0])), (1, try await submit(submissions[1]))]
            let concurrent = try await withThrowingTaskGroup(of: (Int, V2ActorGroupJoinSubmissionOutcomeWire).self) { group in
                for (index, input) in submissions.enumerated().dropFirst(2) { group.addTask { (index, try await submit(input)) } }
                var results: [(Int, V2ActorGroupJoinSubmissionOutcomeWire)] = []
                for try await result in group { results.append(result) }
                return results
            }
            let outcomes = seeded + concurrent
            let accepted = outcomes.compactMap { index, value -> (Int, V2ActorGroupJoinRequestRecordWire)? in
                if case .submitted(let record) = value { return (index, record) }; return nil
            }
            let limited = outcomes.filter { $0.1 == .rateLimited }
            #expect(accepted.count == 20 && limited.count == 20)
            let localCount = try await count("im_v2.group_join_requests", on: sql)
            let remoteCount = try await count("im_v2.group_join_requests", on: secondSQL)
            #expect(localCount > 0 && remoteCount > 0 && localCount + remoteCount == 20)
            #expect(try await count("im_v2.group_join_quota_intents WHERE phase = 'tracking'", on: sql) == 20)
            let first = try #require(accepted.first), refused = try #require(limited.first)
            guard case .alreadyPending = try await submit(submissions[first.0]) else { Issue.record("Expected alreadyPending during global quota lifecycle"); return }
            let duplicate = V2ActorSubmitGroupJoinWire(applicantUserID: applicant, operationID: .init(uuid: UUID()),
                secret: submissions[first.0].secret, note: "duplicate operation")
            guard case .alreadyPending(let shared) = try await submit(duplicate) else { Issue.record("Duplicate at full quota must return existing request"); return }
            #expect(shared.requestID == first.1.requestID)
            _ = try await coordinator.cancel(.init(roomID: first.1.roomID, requestID: first.1.requestID, applicantUserID: applicant), deadline: invitationTestDeadline())
            guard case .cancelled(let replay) = try await submit(duplicate) else { Issue.record("Cancelled duplicate must not create a new request"); return }
            #expect(replay.requestID == first.1.requestID)
            guard case .submitted = try await submit(submissions[refused.0]) else { Issue.record("Expected submitted during global quota lifecycle"); return }
            let rejected = accepted[1].1, approved = accepted[2].1
            guard case .decided(.rejected) = try await coordinator.decide(.init(roomID: rejected.roomID, requestID: rejected.requestID,
                reviewerUserID: senderID, operationID: .init(uuid: UUID()), decision: .reject), deadline: invitationTestDeadline()) else {
                Issue.record("Expected rejected during global quota lifecycle"); return
            }
            guard case .decided(.approved) = try await coordinator.decide(.init(roomID: approved.roomID, requestID: approved.requestID,
                reviewerUserID: senderID, operationID: .init(uuid: UUID()), decision: .approve), deadline: invitationTestDeadline()) else {
                Issue.record("Expected approved during global quota lifecycle"); return
            }
            #expect(try await count("im_v2.group_join_quota_intents WHERE phase IN ('held','tracking')", on: sql) == 18)
            let remainingA = try await count("im_v2.group_join_requests WHERE state = 'pending'", on: sql)
            let remainingB = try await count("im_v2.group_join_requests WHERE state = 'pending'", on: secondSQL)
            #expect(remainingA + remainingB == 18)
        }
    }


    @Test("reserved admission persists negative results and fences retries", arguments: ["expired", "rate", "disabled"])
    func groupJoinReservedNegativeReceipt(_ scenario: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, controlSQL, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000), applicant = UserID(uuid: UUID()), inviteID = GroupInviteID(uuid: UUID())
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            try await controlSQL.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at) VALUES (\(bind: applicant.uuidValue!), 'receipt_applicant', 'Applicant', \(bind: now), \(bind: now))").run()
            let local = PostgresV2GroupInvitationStore(database: owner)
            let digest = Data(repeating: 33, count: 32)
            _ = try await local.create(.init(inviteID: inviteID, roomID: room, actorUserID: senderID, operationID: .init(uuid: UUID()), tokenDigest: digest, requestedLifetimeSeconds: 3600, expiresAt: now.addingTimeInterval(3600), maximumApprovedUses: 10, maximumActiveInvitesPerRoom: 20, createdAt: now))
            let store = PostgresV2GroupInvitationStore(database: owner, identities: PostgresV2GroupInvitationIdentityReader(database: control), scope: .init(roomID: room.uuidValue!, route: try .init(shardID: "room-b", epoch: 0), inviteID: inviteID.uuidValue!))
            let quota = try PostgresV2GroupJoinQuotaStore(database: control)
            let request = V2GroupJoinSubmissionPersistenceRequest(requestID: .init(uuid: UUID()), applicantUserID: applicant, operationID: .init(uuid: UUID()), tokenDigest: digest, note: nil, createdAt: now, maximumPendingRequestsPerApplicant: 1, maximumPendingRequestsPerInvite: 1)
            guard case .reserved(let intent) = try await quota.reserve(request, roomID: room, inviteID: inviteID, now: now) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            if scenario == "rate" {
                try await ownerSQL.raw("INSERT INTO im_v2.group_join_requests(request_id,invite_id,room_id,applicant_user_id,submission_operation_id,created_at,updated_at) VALUES (\(bind: UUID()),\(bind: inviteID.uuidValue!),\(bind: room.uuidValue!),\(bind: UUID()),\(bind: UUID()),\(bind: now),\(bind: now))").run()
            } else if scenario == "disabled" {
                try await controlSQL.raw("INSERT INTO im_v2.account_disables(user_id,operation_id,reason,operator_principal,disabled_at) VALUES (\(bind: applicant.uuidValue!),\(bind: UUID()),'policy_enforcement','receipt-test',\(bind: now))").run()
            }
            let evaluatedAt = scenario == "expired" ? now.addingTimeInterval(4000) : now
            let result = try await store.applyReservedSubmission(intent, now: evaluatedAt)
            #expect(result.outcome == (scenario == "expired" ? .unavailable : scenario == "rate" ? .rateLimited : .permissionDenied))
            #expect(result.targetRequestID == nil && !result.wasInserted)
            #expect(try await count("im_v2.group_join_submission_receipts", on: ownerSQL) == 1)
            try await ownerSQL.raw("DELETE FROM im_v2.group_join_requests").run()
            try await ownerSQL.raw("UPDATE im_v2.group_invite_links SET expires_at = \(bind: now.addingTimeInterval(8000))").run()
            try await controlSQL.raw("DELETE FROM im_v2.account_disables WHERE user_id = \(bind: applicant.uuidValue!)").run()
            #expect(try await store.applyReservedSubmission(intent, now: evaluatedAt).outcome == result.outcome)
            #expect(try await count("im_v2.group_join_requests", on: ownerSQL) == 0)
            try await quota.resolve(intent, outcome: result.outcome, targetRequestID: nil, now: evaluatedAt)
            guard case .reserved(let retry) = try await quota.reserve(request, roomID: room, inviteID: inviteID, now: evaluatedAt.addingTimeInterval(1)) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            #expect(retry.generation == 2)
            let accepted = try await store.applyReservedSubmission(retry, now: evaluatedAt.addingTimeInterval(1))
            #expect(accepted.outcome == .pending && accepted.wasInserted && accepted.targetRequestID == intent.requestID)
            #expect(try await store.applyReservedSubmission(intent, now: evaluatedAt).outcome == result.outcome)
            #expect(try await count("im_v2.group_join_requests", on: ownerSQL) == 1)
            #expect(try await count("im_v2.group_join_submission_receipts", on: ownerSQL) == 2)
            #expect(try await !quota.resolve(intent, outcome: result.outcome, targetRequestID: nil, now: evaluatedAt))
        }
    }

    @Test("request and owner receipt commit together, and terminal replay never creates another request")
    func groupJoinReservedReceiptAtomicity() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, controlSQL, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000), applicant = UserID(uuid: UUID()), inviteID = GroupInviteID(uuid: UUID())
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            try await controlSQL.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at) VALUES (\(bind: applicant.uuidValue!), 'receipt_atomic', 'Applicant', \(bind: now), \(bind: now))").run()
            let local = PostgresV2GroupInvitationStore(database: owner), digest = Data(repeating: 34, count: 32)
            _ = try await local.create(.init(inviteID: inviteID, roomID: room, actorUserID: senderID, operationID: .init(uuid: UUID()), tokenDigest: digest, requestedLifetimeSeconds: 3600, expiresAt: now.addingTimeInterval(3600), maximumApprovedUses: 10, maximumActiveInvitesPerRoom: 20, createdAt: now))
            let store = PostgresV2GroupInvitationStore(database: owner, identities: PostgresV2GroupInvitationIdentityReader(database: control), scope: .init(roomID: room.uuidValue!, route: try .init(shardID: "room-b", epoch: 0), inviteID: inviteID.uuidValue!))
            let quota = try PostgresV2GroupJoinQuotaStore(database: control)
            let request = V2GroupJoinSubmissionPersistenceRequest(requestID: .init(uuid: UUID()), applicantUserID: applicant, operationID: .init(uuid: UUID()), tokenDigest: digest, note: nil, createdAt: now, maximumPendingRequestsPerApplicant: 1, maximumPendingRequestsPerInvite: 1)
            guard case .reserved(let intent) = try await quota.reserve(request, roomID: room, inviteID: inviteID, now: now) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            try await ownerSQL.raw("CREATE FUNCTION im_v2.fail_quota_receipt() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'receipt rollback fixture'; END; $$").run()
            try await ownerSQL.raw("CREATE TRIGGER fail_quota_receipt BEFORE INSERT ON im_v2.group_join_submission_receipts FOR EACH ROW EXECUTE FUNCTION im_v2.fail_quota_receipt()").run()
            await #expect(throws: PSQLError.self) { _ = try await store.applyReservedSubmission(intent, now: now) }
            #expect(try await count("im_v2.group_join_requests", on: ownerSQL) == 0)
            #expect(try await count("im_v2.group_join_submission_receipts", on: ownerSQL) == 0)
            try await ownerSQL.raw("DROP TRIGGER fail_quota_receipt ON im_v2.group_join_submission_receipts").run()
            async let a = store.applyReservedSubmission(intent, now: now)
            async let b = store.applyReservedSubmission(intent, now: now)
            let (left, right) = try await (a, b)
            #expect(left.outcome == .pending && right.outcome == .pending && left.wasInserted != right.wasInserted)
            #expect(try await count("im_v2.group_join_requests", on: ownerSQL) == 1)
            #expect(try await count("im_v2.group_join_submission_receipts", on: ownerSQL) == 1)
            _ = try await store.cancel(roomID: room, requestID: request.requestID, applicantUserID: applicant, now: now)
            let replay = try await store.applyReservedSubmission(intent, now: now)
            #expect(replay.outcome == .cancelled && replay.targetRequestID == intent.requestID && !replay.wasInserted)
            guard case .cancelled = try await store.reservedSubmissionResponse(intent, observed: replay) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            try await ownerSQL.raw("UPDATE im_v2.group_join_submission_receipts SET note = 'corrupt binding'").run()
            await #expect(throws: V2GroupInvitationServiceError.conflict) { _ = try await store.applyReservedSubmission(intent, now: now) }
        }
    }



    @Test("cancellation uses the room owner and control identity and fences stale owner epochs")
    func invitationCancellationRouting() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, sql, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000), applicant = UserID(uuid: UUID())
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            try await sql.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at) VALUES (\(bind: applicant.uuidValue!), 'routed_cancel', 'Control Applicant', \(bind: now), \(bind: now))").run()
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 23, count: 32))
            func coordinator(epoch: Int64) -> V2ActorInvitationCoordinator {
                .init(controlDatabase: control, room: invitationRoomPort(control: control, owner: owner, shardID: "room-b",
                    epoch: epoch, capacityProfile: profile, now: { now }), secretIssuer: issuer, now: { now })
            }
            let current = coordinator(epoch: 0)
            guard case .created(let link) = try await current.create(.init(roomID: room, actorUserID: senderID, operationID: .init(uuid: UUID()),
                lifetime: 3600, maximumApprovedUses: 10), deadline: invitationTestDeadline()) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            guard case .submission(.submitted(let request)) = try await current.submitBySecret(.init(applicantUserID: applicant,
                operationID: .init(uuid: UUID()), secret: link.secret, note: nil), deadline: invitationTestDeadline()) else {
                throw V2GroupInvitationServiceError.corruptPersistenceState
            }
            let cancel = V2ActorCancelGroupJoinWire(roomID: room, requestID: request.requestID, applicantUserID: applicant)
            try await ownerSQL.raw("UPDATE im_v2.rooms SET owner_epoch = 1 WHERE room_id = \(bind: room.uuidValue!)").run()
            // A room turn for the previous owner epoch cannot be granted.
            await #expect(throws: V2RoomActivationLeaseError.ownerChanged) {
                _ = try await current.cancel(cancel, deadline: invitationTestDeadline())
            }
            #expect(try await count("im_v2.group_join_requests WHERE state = 'pending'", on: ownerSQL) == 1)
            let moved = coordinator(epoch: 1)
            guard case .cancelled(let result) = try await moved.cancel(cancel, deadline: invitationTestDeadline()) else {
                throw V2GroupInvitationServiceError.corruptPersistenceState
            }
            #expect(result.state == .cancelled && result.applicant.displayName == "Control Applicant")
            #expect(try await moved.cancel(cancel, deadline: invitationTestDeadline()) == .cancelled(result))
            #expect(try await count("im_v2.group_join_requests", on: sql) == 0)
            #expect(try await count("im_v2.group_join_requests WHERE state = 'cancelled'", on: ownerSQL) == 1)
        }
    }

    @Test("applicant cancellation preserves decisions, releases quota, and serializes with approval", arguments: ["pending", "expired", "revoked", "approve-first", "reject-first", "race"])
    func invitationApplicantCancellation(_ scenario: String) async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        var installed = false
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            installed = true
            try await seedRoom(capacityClass: .standard, on: sql)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            let now = Date(timeIntervalSince1970: 1_750_000_000), applicant = UserID(uuid: UUID())
            try await sql.raw("INSERT INTO im_v2.public_user_profiles (user_id, public_handle, display_name, created_at, updated_at) VALUES (\(bind: applicant.uuidValue!), 'cancel_applicant', 'Applicant', \(bind: now), \(bind: now))").run()
            let store = PostgresV2GroupInvitationStore(database: resources.database(.psql))
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, retryAfterSeconds: 3))
            let inviteID = GroupInviteID(uuid: UUID()), digest = Data(repeating: 19, count: 32)
            _ = try await store.create(.init(inviteID: inviteID, roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), tokenDigest: digest, requestedLifetimeSeconds: 3600, expiresAt: now.addingTimeInterval(3600), maximumApprovedUses: 2, maximumActiveInvitesPerRoom: 20, createdAt: now))
            func submission(_ digest: Data = Data(repeating: 19, count: 32)) -> V2GroupJoinSubmissionPersistenceRequest {
                .init(requestID: .init(uuid: UUID()), applicantUserID: applicant, operationID: .init(uuid: UUID()), tokenDigest: digest, note: nil, createdAt: now, maximumPendingRequestsPerApplicant: 1, maximumPendingRequestsPerInvite: 1)
            }
            let original = submission()
            guard case .submitted(let request) = try await store.submit(original) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            await #expect(throws: V2GroupInvitationServiceError.requestNotFound) {
                _ = try await store.cancel(roomID: roomID, requestID: request.requestID, applicantUserID: senderID, now: now)
            }
            await #expect(throws: V2GroupInvitationServiceError.requestNotFound) {
                _ = try await store.cancel(roomID: .init(uuid: UUID()), requestID: request.requestID, applicantUserID: applicant, now: now)
            }
            if scenario == "expired" || scenario == "revoked" {
                if scenario == "expired" {
                    try await sql.raw("UPDATE im_v2.group_invite_links SET expires_at = \(bind: now.addingTimeInterval(1)) WHERE invite_id = \(bind: inviteID.uuidValue!)").run()
                } else {
                    try await store.revoke(inviteID: inviteID, roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), now: now)
                }
                guard case .available(let preview) = try await store.preview(tokenDigest: digest, applicantUserID: applicant, now: now.addingTimeInterval(2)) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                #expect(preview.requestID == request.requestID && preview.requestState == .pending)
                #expect(try await store.preview(tokenDigest: digest, applicantUserID: senderID, now: now.addingTimeInterval(2)) == .unavailable)
            }
            let operation = GroupJoinDecisionOperationID(uuid: UUID())
            if scenario == "approve-first" {
                guard case .approved = try await store.approve(roomID: roomID, requestID: request.requestID, reviewerUserID: senderID, operationID: operation, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            } else if scenario == "reject-first" {
                guard case .rejected = try await store.reject(roomID: roomID, requestID: request.requestID, reviewerUserID: senderID, operationID: operation, now: now) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            }
            let terminal: V2GroupJoinRequestRecord
            if scenario == "race" {
                async let cancel = store.cancel(roomID: roomID, requestID: request.requestID, applicantUserID: applicant, now: now)
                async let approve = store.approve(roomID: roomID, requestID: request.requestID, reviewerUserID: senderID, operationID: operation, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now)
                let (cancelled, approved) = try await (cancel, approve)
                terminal = cancelled
                switch approved {
                case .approved(let value), .alreadyDecided(let value): #expect(value == terminal)
                default: Issue.record("Unexpected approval result: \(approved)")
                }
            } else {
                terminal = try await store.cancel(roomID: roomID, requestID: request.requestID, applicantUserID: applicant, now: now)
            }
            let replay = try await store.cancel(roomID: roomID, requestID: request.requestID, applicantUserID: applicant, now: now.addingTimeInterval(10))
            #expect(replay == terminal)
            #expect(terminal.state == (scenario == "approve-first" ? .approved : scenario == "reject-first" ? .rejected : scenario == "race" ? terminal.state : .cancelled))
            #expect(terminal.state == .cancelled || terminal.state == .approved || terminal.state == .rejected)
            let uses = try await sql.raw("SELECT approved_use_count::text AS value FROM im_v2.group_invite_links WHERE invite_id = \(bind: inviteID.uuidValue!)").first(decoding: StringValueRow.self)?.value
            #expect(uses == (terminal.state == .approved ? "1" : "0"))
            let isMember = try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.room_memberships WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: applicant.uuidValue!) AND left_revision IS NULL) AS exists").first(decoding: ExistsRow.self)?.exists
            #expect(isMember == (terminal.state == .approved))
            #expect(try await count("im_v2.room_events", on: sql) == (terminal.state == .approved ? 1 : 0))
            if terminal.state == .cancelled {
                guard case .cancelled(let prior) = try await store.submit(original) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                #expect(prior == terminal)
                guard case .alreadyDecided(let prior) = try await store.approve(roomID: roomID, requestID: request.requestID, reviewerUserID: senderID, operationID: .init(uuid: UUID()), capacityProfile: profile, eventID: .init(uuid: UUID()), now: now) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                #expect(prior == terminal)
                #expect(try await store.reject(roomID: roomID, requestID: request.requestID, reviewerUserID: senderID, operationID: .init(uuid: UUID()), now: now) == .decisionConflict)
                let nextDigest: Data
                if scenario == "expired" || scenario == "revoked" {
                    nextDigest = Data(repeating: 20, count: 32)
                    _ = try await store.create(.init(inviteID: .init(uuid: UUID()), roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), tokenDigest: nextDigest, requestedLifetimeSeconds: 3600, expiresAt: now.addingTimeInterval(3600), maximumApprovedUses: 2, maximumActiveInvitesPerRoom: 20, createdAt: now))
                } else { nextDigest = digest }
                guard case .submitted(let fresh) = try await store.submit(submission(nextDigest)) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                #expect(fresh.requestID != request.requestID && fresh.state == .pending)
                guard case .available(let preview) = try await store.preview(tokenDigest: nextDigest, applicantUserID: applicant, now: now) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                #expect(preview.requestID == fresh.requestID)
                #expect(try await store.cancel(roomID: roomID, requestID: request.requestID, applicantUserID: applicant, now: now) == terminal)
            }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            installed = false
            try await resources.shutdown()
        } catch {
            if installed, let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }


    @Test("a real accepted message is visible to NATS wake authorization during installation",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_REAL_NATS_URL"] != nil
            && ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"), arguments: [(V2GroupCapacityClass.standard, false), (.large, false), (.large, true), (.standard, true)])
    func acceptedMessageDuringNATSInstallation(scenario: (V2GroupCapacityClass, Bool)) async throws {
        let (mode, beforeSubscription) = scenario
        let address = try #require(ProcessInfo.processInfo.environment["IMV2_REAL_NATS_URL"])
        let url = try #require(URL(string: address))
        try await withForwardOwnerDatabases(mode: mode) { database, _, sql, _, _ in
            // The shared legacy write fixture uses revision zero. Recovery
            // requires the nonzero membership revision produced by real creation.
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 1 WHERE room_id = \(bind: roomID.uuidValue!)").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET joined_revision = 1 WHERE room_id = \(bind: roomID.uuidValue!)").run()
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let sender = V2SendMessageService(store: PostgresV2RoomWriteStore(database: database),
                capacityProfile: try forwardImportTestProfile(), limits: try .init(maxUTF8Bytes: 64), now: { now })
            let publish: ((any V2GroupEventWakePublishing) async throws -> Void)?
            if mode == .large {
                publish = { publisher in
                    let relay = V2GroupEventWakeRelay(store: PostgresV2GroupEventWakeStore(database: database),
                        publisher: publisher)
                    let report = try await relay.runOnce(limit: 10)
                    #expect(report.claimed == 1 && report.published == 1 && report.retryScheduled == 0)
                    #expect(try await count("im_v2.group_event_wake_outbox", on: sql) == 0)
                }
            } else { publish = { _ in } }
            try await PostgresV2NATSInstallationTests.verifyInstallation(database: database,
                user: senderID, room: roomID, url: url, beforeSubscription: beforeSubscription, awaitForegroundPublication: beforeSubscription && mode == .standard, publish: publish) { dispatcher in
                if mode == .standard {
                    let handler = makeGatewayDomainCommandHandler(sendMessage: sender,
                        groupEventLog: .init(store: PostgresV2GroupEventLogStore(database: database)),
                        foregroundGroupEventHints: dispatcher,
                        sync: .init(store: PostgresV2SyncStore(database: database)))
                    var request = IMV2Envelope()
                    request.sendMessage.roomID = roomID.rawValue
                    request.sendMessage.clientMessageID = UUID().uuidString
                    request.sendMessage.content.text = "installation-body"
                    let response = try await handler.handle(envelope: request,
                        identity: .init(userID: senderID, deviceID: .init(uuid: UUID()), capabilityProfile: "base"))
                    guard case .messageAccepted(let accepted)? = response.body else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    let messageID = try #require(UUID(uuidString: accepted.messageID))
                    let row = try #require(try await sql.raw("""
                        SELECT text_body, room_sequence FROM im_v2.messages WHERE message_id = \(bind: messageID)
                        """).first())
                    #expect(try row.decode(column: "text_body", as: String.self) == "installation-body")
                    #expect(try row.decode(column: "room_sequence", as: Int64.self) == Int64(accepted.roomSequence))
                    return accepted.roomSequence
                }
                guard case .accepted(let message) = try await sender.send(.init(roomID: roomID,
                    actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "installation-body")) else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                let row = try #require(try await sql.raw("""
                    SELECT text_body, room_sequence FROM im_v2.messages
                    WHERE message_id = \(bind: message.messageID.uuidValue!)
                    """).first())
                #expect(try row.decode(column: "text_body", as: String.self) == "installation-body")
                #expect(try row.decode(column: "room_sequence", as: Int64.self) == Int64(message.roomSequence))
                return message.roomSequence
            }
        }
    }

    @Test("media authorization refuses content from a membership gap even with a stale projection")
    func mediaAuthorizationFollowsTheMembershipGap() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"), Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? SQLDatabase)
            try await installSchema(on: sql)
            let requester = UUID()
            let peer = UUID()
            let device = UUID()
            let room = UUID(uuidString: "00000000-0000-0000-0000-00000000f001")!
            let base = Date(timeIntervalSince1970: 1_750_030_000)

            // 成员区间：第 2 个修订加入、第 5 个修订离开、第 9 个修订重新加入。
            // 两个区间之间的内容对请求者从未可见。
            try await insertSummaryFixtureRoom(on: sql, room: room, kind: "group", sequence: 4,
                                               revision: 9, lastEventAt: base, createdAt: base)
            try await insertSummaryFixtureMembership(on: sql, room: room, user: requester, joined: 2, left: 5)
            try await insertSummaryFixtureMembership(on: sql, room: room, user: requester, joined: 9, left: nil)
            try await insertSummaryFixtureMembership(on: sql, room: room, user: peer, joined: 1, left: nil)
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, revision, visibility_revision, created_at, updated_at)
                VALUES (\(bind: requester), 'gap_requester', '区间请求者', 1, 1, \(bind: base), \(bind: base))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at)
                VALUES (\(bind: requester), \(bind: device), \(bind: base), \(bind: base))
                """).run()

            // 一条可见消息（接受于第 2 个修订）与一条空档期消息（接受于第 6 个修订），
            // 两条都带可用媒体。
            let visibleMessage = UUID()
            let gapMessage = UUID()
            try await insertSummaryFixtureRoomEvent(on: sql, room: room, sequence: 2, revision: 2,
                                                    message: visibleMessage, createdAt: base)
            try await insertSummaryFixtureRoomEvent(on: sql, room: room, sequence: 3, revision: 6,
                                                    message: gapMessage, createdAt: base.addingTimeInterval(1))
            var clientMessageIDByMessage: [UUID: UUID] = [:]
            for (message, sequence) in [(visibleMessage, Int64(2)), (gapMessage, Int64(3))] {
                clientMessageIDByMessage[message] = try await insertSummaryFixtureMessage(
                    on: sql, room: room, message: message, sender: peer,
                    roomSequence: sequence, timelineSequence: sequence,
                    text: "text-\(sequence)", createdAt: base,
                    storage: .roomEvent, revision: nil
                )
            }
            // 接受事实是历史可见性的权威：区间内消息在修订 2 被接受，空档期消息在修订 6 被接受。
            for (message, sequence, revision) in [(visibleMessage, Int64(2), Int64(2)), (gapMessage, Int64(3), Int64(6))] {
                let clientMessageID = try #require(clientMessageIDByMessage[message])
                try await sql.raw("""
                    INSERT INTO im_v2.message_send_completions
                        (room_id, sender_user_id, client_message_id, fingerprint_version, request_fingerprint,
                         message_id, event_id, room_sequence, timeline_sequence, accepted_membership_revision,
                         group_capacity_class, created_at)
                    VALUES (\(bind: room), \(bind: peer), \(bind: clientMessageID), 3, \(bind: Data(repeating: 7, count: 32)),
                            \(bind: message), \(bind: UUID()), \(bind: sequence), \(bind: sequence), \(bind: revision),
                            'standard', \(bind: base))
                    """).run()
            }
            var mediaByMessage: [UUID: UUID] = [:]
            for message in [visibleMessage, gapMessage] {
                let media = UUID()
                mediaByMessage[message] = media
                try await insertSummaryFixtureMediaObject(on: sql, media: media, owner: peer, at: base)
                try await sql.raw("""
                    INSERT INTO im_v2.message_media_references (message_id, media_id, ordinal, referenced_at)
                    VALUES (\(bind: message), \(bind: media), 0, \(bind: base))
                    """).run()
                // 刻意伪造一条"已投递"投影：媒体授权不得到此为止，必须再检查历史成员区间。
                try await sql.raw("""
                    INSERT INTO im_v2.user_projection_versions
                        (user_id, projection_kind, entity_key, scope_room_id, valid_from_sequence,
                         source_event_id, payload, created_at)
                    VALUES (\(bind: requester), 'message', \(bind: message.uuidString), \(bind: room), 1,
                            \(bind: UUID()),
                            jsonb_build_object(
                                'event_type', 'message.accepted',
                                'message_id', \(bind: message.uuidString),
                                'room_id', \(bind: room.uuidString),
                                'is_withdrawn', false,
                                'media_ids', jsonb_build_array(\(bind: media.uuidString))),
                            \(bind: base))
                    """).run()
            }
            let visibleMedia = try #require(mediaByMessage[visibleMessage])
            let gapMedia = try #require(mediaByMessage[gapMessage])

            // 正例：区间内的消息媒体仍可用——证明拒绝不是因为夹具整体不可用。
            #expect(try await V2PostgresMediaVisibilityAuthorization.isAuthorized(
                mediaID: visibleMedia, requesterUserID: requester, deviceID: device, on: sql
            ))
            // 反例：空档期的消息即便有陈旧投影也必须拒绝。
            #expect(try await V2PostgresMediaVisibilityAuthorization.isAuthorized(
                mediaID: gapMedia, requesterUserID: requester, deviceID: device, on: sql
            ) == false)

            // 同一条可见性结论必须与房间日志读取一致：空档期事件不出现。
            let log = try await PostgresV2GroupEventLogStore(database: resources.database(.psql))
                .pull(roomID: RoomID(uuid: room), actorUserID: UserID(uuid: requester), afterRoomSequence: 0, pageSize: 10)
            #expect(log.events.map(\.roomSequence) == [2])
            // 摘要预览同样不得泄漏空档期内容。
            let summaries = try await PostgresV2RoomLatestVisibleStore(database: resources.database(.psql))
                .latestVisible(roomIDs: [RoomID(uuid: room)], actorUserID: UserID(uuid: requester))
            guard case .snapshot(let summary) = summaries[RoomID(uuid: room)] else {
                Issue.record("authorized latest-visible result missing")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            #expect(summary.latest?.id == MessageID(uuid: visibleMessage))

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("startup rejects obsolete room and completion delivery selectors", arguments: ["rooms", "message_send_completions"])
    func schemaReadinessRejectsDeliverySelectors(_ table: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            try await V2SchemaReadiness.verify(database: database)
            try await assertSQLSchemaGate(true, on: sql)
            try await sql.raw("ALTER TABLE im_v2.\(ident: table) ADD COLUMN delivery_authority text").run()
            await #expect(throws: V2SchemaReadinessError.self) {
                try await V2SchemaReadiness.verify(database: database)
            }
            try await assertSQLSchemaGate(false, on: sql)
        }
    }

    @Test("startup rejects obsolete admission budget columns",
          arguments: ["room_admission", "shard_admission_pools"],
          ["fanout_window_limit", "fanout_window_used", "max_outstanding_fanout_units",
           "outstanding_fanout_units", "max_outstanding_plans", "outstanding_plans"])
    func schemaReadinessRejectsFanoutBudgets(_ table: String, _ column: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            try await V2SchemaReadiness.verify(database: database)
            try await assertSQLSchemaGate(true, on: sql)
            try await sql.raw("ALTER TABLE im_v2.\(ident: table) ADD COLUMN \(ident: column) bigint").run()
            await #expect(throws: V2SchemaReadinessError.self) {
                try await V2SchemaReadiness.verify(database: database)
            }
            try await assertSQLSchemaGate(false, on: sql)
        }
    }

    @Test("public sends use room logs for every room kind",
          arguments: ["standard", "hybrid", "direct"])
    func allPublicSendsUseRoomLog(_ kind: String) async throws {
        try await withForwardOwnerDatabases(mode: kind == "hybrid" ? .large : .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            var destination = roomID
            if kind.hasPrefix("direct") {
                guard case .opened(let room) = try await PostgresV2DirectMessagingStore(database: database).open(
                    command: .init(actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID)),
                    capacityProfile: profile, roomShardID: "room-a", roomID: .init(uuid: UUID()), now: now) else { throw CancellationError() }
                destination = room.roomID
            }
            let service = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database,
                strangerMessagePolicy: .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled), capacityProfile: profile, limits: .init(maxUTF8Bytes: 128), now: { now })
            // A first direct send may publish a private capability change;
            // public content must never add a personal message copy.
            let initialUserRows = try await count("im_v2.user_sync_log WHERE projection_kind NOT IN ('direct_sending_capability', 'direct_room_profile')", on: sql)
            for rich in [false, true] {
                let request = try V2AuthenticatedSendMessage(roomID: destination, actorUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: rich ? "Rich mention" : "Plain message",
                    mentions: rich ? [.user(.init(uuid: memberTwoUUID))] : [])
                guard case .accepted(let message) = try await service.send(request) else { throw CancellationError() }

                #expect(try await service.send(request) == .idempotent(message.receipt))
                let page = try await PostgresV2GroupEventLogStore(database: database).pull(
                    roomID: destination, actorUserID: .init(uuid: memberTwoUUID), afterRoomSequence: message.roomSequence - 1, pageSize: 10)
                #expect(page.events.map(\.roomSequence).contains(message.roomSequence))
            }
            for table in ["fanout_plans", "fanout_plan_targets", "fanout_deliveries", "fanout_completion_units", "room_outbox", "consumer_inbox", "fanout_sync_payloads"] {
                #expect(try await sql.raw("SELECT to_regclass(\(bind: "im_v2." + table)) IS NULL AS exists").first(decoding: ExistsRow.self)?.exists == true)
            }
            #expect(try await count("im_v2.user_sync_log WHERE projection_kind NOT IN ('direct_sending_capability', 'direct_room_profile')", on: sql) == initialUserRows)
            #expect(try await count("im_v2.message_send_completions", on: sql) == 2)
        }
    }

    @Test("room activity time tracks sequence advances and ignores unrelated updates")
    func roomActivityTimestampTracksSequenceAdvances() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            try await installSchema(on: sql)
            let room = UUID()
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("""
                INSERT INTO im_v2.rooms
                    (room_id, room_kind, room_shard_id, room_sequence,
                     membership_revision, capacity_profile_id, created_at, last_event_at)
                VALUES (\(bind: room), 'group', 'room-a', 0, 1, 'standard', \(bind: base), \(bind: base))
                """).run()
            // Membership-only changes must not make a room look recently active;
            // conversation ordering depends on this remaining precise.
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 2 WHERE room_id = \(bind: room)").run()
            #expect(try await sql.raw("""
                SELECT (last_event_at = \(bind: base)) AS exists
                FROM im_v2.rooms WHERE room_id = \(bind: room)
                """).first(decoding: ExistsRow.self)?.exists == true)
            // Advancing the room sequence is the single activity signal, no
            // matter which physical table carries the event.
            try await sql.raw("UPDATE im_v2.rooms SET room_sequence = 1 WHERE room_id = \(bind: room)").run()
            #expect(try await sql.raw("""
                SELECT (last_event_at > \(bind: base)) AS exists
                FROM im_v2.rooms WHERE room_id = \(bind: room)
                """).first(decoding: ExistsRow.self)?.exists == true)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await resources.shutdown(); throw error
        }
    }







    @Test("a newly created standard group recovers accepted content from its room log")
    func newStandardGroupUsesRoomLog() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let service = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: database),
                capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 128),
                now: { base }
            )
            func makeStandardGroup(title: String) async throws -> RoomID {
                let room = RoomID(uuid: UUID())
                let outcome = try await PostgresV2GroupMessagingStore(
                    database: database).create(
                    command: try V2CreateGroupRoomCommand(
                        actorUserID: senderID,
                        operationID: GroupRoomOperationID(uuid: UUID()),
                        title: title,
                        capacityClass: .standard,
                        initialMemberUserIDs: [.init(uuid: memberTwoUUID)]
                    ),
                    capacityProfile: profile,
                    roomShardID: "room-a",
                    roomID: room,
                    eventID: EventID(uuid: UUID()),
                    now: base
                )
                guard case .created(_) = outcome else {
                    Issue.record("expected \(title) to be created")
                    throw CancellationError()
                }
                return room
            }
            func message(_ room: RoomID, clientID: String) throws -> V2AuthenticatedSendMessage {
                try .init(
                    roomID: room, actorUserID: senderID,
                    clientMessageID: try .init(clientID), text: "群消息"
                )
            }

            let logRoom = try await makeStandardGroup(title: "Room-log group")
            guard case .accepted(let logMessage) = try await service.send(message(logRoom, clientID: "00000000-0000-0000-0000-00000000d102")) else {
                Issue.record("expected the room-log message to be accepted")
                return
            }
            // 权威副本确实可恢复：按房间游标拉取能看到这条消息。
            let page = try await PostgresV2GroupEventLogStore(database: database)
                .pull(roomID: logRoom, actorUserID: senderID, afterRoomSequence: 0, pageSize: 10)
            #expect(page.events.map(\.roomSequence).contains(logMessage.roomSequence))
        }
    }

    @Test("a mention in a room-log room becomes a push notification, not a per-user delivery")
    func mentionInRoomLogRoomBecomesPushNotification() async throws {
        try await withForwardOwnerDatabases(mode: .large) { database, _, sql, _, _ in
            // 必须落在夹具预置的分片租约窗口内，否则群创建会被准入拒绝。
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            // 夹具已为该用户提供公开身份；提及授权还要求他是房间成员。
            let mentioned = memberTwoUUID
            let secondDevice = UUID()
            let revokedDevice = UUID()
            for (device, revokedAt) in [(secondDevice, nil), (revokedDevice, base.addingTimeInterval(-60))] as [(UUID, Date?)] {
                try await sql.raw("""
                    INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, revoked_at)
                    VALUES (\(bind: mentioned), \(bind: device), \(bind: base), \(bind: base), \(bind: revokedAt))
                    """).run()
            }

            let payload = try forwardImportTestProfile()
            // 被 @ 的人必须是房间成员，否则提及授权会先拒绝。
            let room = RoomID(uuid: UUID())
            let groupStore = PostgresV2GroupMessagingStore(database: database)
            let created = try await groupStore.create(
                command: try V2CreateGroupRoomCommand(
                    actorUserID: senderID,
                    operationID: GroupRoomOperationID(uuid: UUID()),
                    title: "Mention room",
                    capacityClass: .large,
                    initialMemberUserIDs: [.init(uuid: mentioned)]
                ),
                capacityProfile: payload,
                roomShardID: "room-a",
                roomID: room,
                eventID: EventID(uuid: UUID()),
                now: base
            )
            guard case .created(_) = created else {
                Issue.record("expected the mention room to be created")
                return
            }
            // 群创建本身会给初始成员建一次投递；这里只关心提及带来的增量。
            let service = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: database),
                capacityProfile: payload,
                limits: try .init(maxUTF8Bytes: 512),
                now: { base }
            )
            func message(clientID: String) throws -> V2AuthenticatedSendMessage {
                try .init(
                    roomID: room, actorUserID: senderID,
                    clientMessageID: try .init(clientID), text: "@被点名的人",
                    mentions: [.user(try .init(mentioned.uuidString))]
                )
            }

            // 没有启用的推送活动时，提及仍然只是一条普通房间事件：不接受、不失败、不建投递。
            guard case .accepted = try await service.send(message(clientID: "00000000-0000-0000-0000-00000000c101")) else {
                Issue.record("expected the mention to be accepted")
                return
            }
            #expect(try await count("im_v2.push_wake_outbox", on: sql) == 0)

            // 配置并启用通知活动后，被 @ 成员的**有效**设备各自收到一条唤醒通知；
            // 已撤销设备不在其中，也不会因此产生任何逐用户投递。
            try await sql.raw("""
                INSERT INTO im_v2.push_campaigns (campaign_id, state, updated_at)
                VALUES ('mention_wake', 'enabled', \(bind: base))
                """).run()
            guard case .accepted = try await service.send(message(clientID: "00000000-0000-0000-0000-00000000c102")) else {
                Issue.record("expected the mention to be accepted")
                return
            }
            let wakes = try await sql.raw("""
                SELECT target_device_id, target_user_id, campaign_id, state
                FROM im_v2.push_wake_outbox ORDER BY target_device_id
                """).all(decoding: MentionWakeAssertionRow.self)
            #expect(wakes.count == 1)
            #expect(wakes.first?.targetDeviceID == secondDevice)
            #expect(wakes.first?.targetUserID == mentioned)
            #expect(wakes.first?.campaignID == "mention_wake")
            #expect(wakes.first?.state == "pending")
            // 提及内容仍可按房间游标恢复：权威副本没有因为通知路径而改变。
            let page = try await PostgresV2GroupEventLogStore(database: database)
                .pull(roomID: room, actorUserID: senderID, afterRoomSequence: 0, pageSize: 10)
            #expect(page.events.count == 3)
        }
    }

    @Test("room projections carry capacity classes without a delivery selector")
    func roomProjectionsDeclareCapacityClass() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            for mode in [V2GroupCapacityClass.standard, .large] {
                let store = PostgresV2GroupMessagingStore(database: database)
                let newRoom = RoomID(uuid: UUID())
                let outcome = try await store.create(
                    command: try V2CreateGroupRoomCommand(
                        actorUserID: senderID,
                        operationID: GroupRoomOperationID(uuid: UUID()),
                        title: "Capacity \(mode.rawValue)",
                        capacityClass: mode,
                        initialMemberUserIDs: [.init(uuid: memberTwoUUID)]
                    ),
                    capacityProfile: profile,
                    roomShardID: "room-a",
                    roomID: newRoom,
                    eventID: EventID(uuid: UUID()),
                    now: base
                )
                guard case .created(_) = outcome else {
                    Issue.record("group creation did not report a created room")
                    return
                }
                let room = try #require(newRoom.uuidValue)
                #expect(try await sql.raw("""
                    SELECT payload->>'capacity_class' AS value FROM im_v2.room_events
                    WHERE room_id = \(bind: room) AND event_type = 'room.created'
                    """).first(decoding: StringValueRow.self)?.value == mode.rawValue)
                #expect(try await sql.raw("""
                    SELECT NOT (payload ? 'delivery_authority') AS exists FROM im_v2.room_events
                    WHERE room_id = \(bind: room) AND event_type = 'room.created'
                    """).first(decoding: ExistsRow.self)?.exists == true)
            }
        }
    }

    @Test("Group creation initializes every initial member's read watermark at the room head")
    func groupCreationInitializesMemberReadWatermarks() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let store = PostgresV2GroupMessagingStore(database: database)
            let operation = GroupRoomOperationID(uuid: UUID())
            let newRoom = RoomID(uuid: UUID())
            let command = try V2CreateGroupRoomCommand(
                actorUserID: senderID,
                operationID: operation,
                title: "Watermark group",
                capacityClass: .standard,
                initialMemberUserIDs: [.init(uuid: memberTwoUUID)]
            )
            let outcome = try await store.create(
                command: command,
                capacityProfile: profile,
                roomShardID: "room-a",
                roomID: newRoom,
                eventID: EventID(uuid: UUID()),
                now: base
            )
            guard case .created(_) = outcome else {
                Issue.record("group creation did not report a created room")
                return
            }
            let room = try #require(newRoom.uuidValue)
            // The room head after creation is the room.created event at
            // sequence 1. Every initial member must already have read it,
            // otherwise a brand-new group opens with one unread event.
            #expect(try await sql.raw("""
                SELECT COUNT(*) AS value FROM im_v2.room_read_receipts
                WHERE room_id = \(bind: room) AND read_through_room_sequence = 1
                """).first(decoding: CountRow.self)?.value == 2)
        }
    }

    @Test("Joined-member read watermark follows the room head without ever moving backwards")
    func joinedMemberReadWatermarkSemantics() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { _, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let joiner = UUID()
            try await sql.raw("UPDATE im_v2.rooms SET room_sequence = 7 WHERE room_id = \(bind: roomUUID)").run()
            try await v2InitializeJoinedMemberReadWatermark(
                roomID: roomUUID, userID: joiner, now: base, sql: sql
            )
            #expect(try await sql.raw("""
                SELECT read_through_room_sequence AS value FROM im_v2.room_read_receipts
                WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: joiner)
                """).first(decoding: CountRow.self)?.value == 7)
            // A later join must never lower a watermark that already advanced
            // past the current head (for example after a delayed replay).
            try await sql.raw("UPDATE im_v2.rooms SET room_sequence = 3 WHERE room_id = \(bind: roomUUID)").run()
            try await v2InitializeJoinedMemberReadWatermark(
                roomID: roomUUID, userID: joiner, now: base.addingTimeInterval(60), sql: sql
            )
            #expect(try await sql.raw("""
                SELECT read_through_room_sequence AS value FROM im_v2.room_read_receipts
                WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: joiner)
                """).first(decoding: CountRow.self)?.value == 7)
            // An empty room carries no content to mark as read, and a
            // zero watermark cannot be persisted, so no row may appear.
            let emptyRoom = UUID(), emptyJoiner = UUID()
            try await sql.raw("""
                INSERT INTO im_v2.rooms (room_id, room_kind, room_shard_id, room_sequence, membership_revision, capacity_profile_id, created_at)
                VALUES (\(bind: emptyRoom), 'direct', 'room-a', 0, 1, 'standard', \(bind: base))
                """).run()
            try await v2InitializeJoinedMemberReadWatermark(
                roomID: emptyRoom, userID: emptyJoiner, now: base, sql: sql
            )
            #expect(try await sql.raw("""
                SELECT COUNT(*) AS value FROM im_v2.room_read_receipts WHERE room_id = \(bind: emptyRoom)
                """).first(decoding: CountRow.self)?.value == 0)
        }
    }

    @Test("An unrepresentable lockout preserves the prior budget and audit, then recovers with a valid duration")
    func passwordLockoutPrecisionRollback() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let device = DeviceID(uuid: UUID())
            let limiter = V2PostgresPasswordLoginAttemptLimiter(database: database,
                policy: try .init(maximumFailures: 2, window: 60, lockout: 1e-12))
            try await limiter.recordRejectedAttempt(accountHandle: "precision-budget", userID: nil, deviceID: device)
            func snapshot() async throws -> String {
                try #require(try await sql.raw("""
                    SELECT jsonb_build_object(
                        'budget', (SELECT to_jsonb(b) FROM im_v2.account_password_login_rate_limits b
                                   WHERE account_handle = 'precision-budget'),
                        'audits', (SELECT jsonb_agg(to_jsonb(a) ORDER BY event_id)
                                   FROM im_v2.account_password_authentication_audit a
                                   WHERE device_id = \(bind: device.uuidValue!)))::text AS value
                    """).first(decoding: StringValueRow.self)).value
            }
            let before = try await snapshot()
            await #expect(throws: V2PasswordLoginRateLimitError.unavailable) {
                try await limiter.recordRejectedAttempt(accountHandle: "precision-budget", userID: nil, deviceID: device)
            }
            #expect(try await snapshot() == before)
            let corrected = V2PostgresPasswordLoginAttemptLimiter(database: database,
                policy: try .init(maximumFailures: 2, window: 60, lockout: 0.5))
            try await corrected.recordRejectedAttempt(accountHandle: "precision-budget", userID: nil, deviceID: device)
            #expect(try await sql.raw("""
                SELECT 1 FROM im_v2.account_password_login_rate_limits
                WHERE account_handle = 'precision-budget' AND failure_count = 2
                  AND blocked_until > updated_at
                  AND blocked_until - updated_at BETWEEN INTERVAL '0.499999 seconds' AND INTERVAL '0.500001 seconds'
                  AND (SELECT count(*) FROM im_v2.account_password_authentication_audit
                       WHERE device_id = \(bind: device.uuidValue!)) = 2
                """).first() != nil)
        }
    }

    @Test("Failure-accounting timestamps are sampled after the handle lock is acquired", arguments: [false, true])
    func passwordBudgetClockAfterLock(success: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let handle = "clock-after-lock"
            let user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
            let limiter = V2PostgresPasswordLoginAttemptLimiter(database: database,
                policy: try .init(maximumFailures: 1, window: 60, lockout: 60))
            let gate = PostgreSQLTransactionGate()
            let blocker = Task {
                try await database.transaction { transaction in
                    guard let lockedSQL = transaction as? any SQLDatabase else {
                        throw V2PasswordLoginRateLimitError.unavailable
                    }
                    try await v2LockPasswordAttempts(lockedSQL, handle: handle)
                    await gate.holdTransaction()
                }
            }
            await gate.waitUntilHeld()
            let pending = Task {
                if success {
                    try await limiter.recordSuccessfulAttempt(accountHandle: handle, userID: user, deviceID: device)
                } else {
                    try await limiter.recordRejectedAttempt(accountHandle: handle, userID: nil, deviceID: device)
                }
            }
            struct ObservedClock: Decodable { let value: V2PostgresTimestamp }
            let releaseBoundary: V2PostgresTimestamp
            do {
                try await waitForAdvisoryWaiters(1, on: sql)
                // No timed sleep: the worker is already waiting in its
                // transaction, and this native timestamp precedes release.
                releaseBoundary = try #require(try await sql.raw("SELECT clock_timestamp() AS value")
                    .first(decoding: ObservedClock.self)).value
            } catch {
                pending.cancel()
                await gate.releaseTransaction()
                _ = try? await blocker.value
                _ = try? await pending.value
                throw error
            }
            await gate.releaseTransaction()
            try await blocker.value
            try await pending.value
            let outcome = success ? "assertion_succeeded" : "assertion_rejected"
            #expect(try await sql.raw("""
                SELECT 1 FROM im_v2.account_password_authentication_audit
                WHERE device_id = \(bind: device.uuidValue!) AND outcome = \(bind: outcome)
                  AND occurred_at >= \(bind: releaseBoundary)
                """).first() != nil)
            if success {
                #expect(try await limiter.blockedRetryAfterSeconds(accountHandle: handle) == nil)
            } else {
                #expect(try await sql.raw("""
                    SELECT 1 FROM im_v2.account_password_login_rate_limits
                    WHERE account_handle = \(bind: handle) AND failure_count = 1
                      AND window_started_at >= \(bind: releaseBoundary)
                      AND updated_at >= \(bind: releaseBoundary)
                      AND blocked_until >= \(bind: releaseBoundary)::timestamptz + INTERVAL '60 seconds'
                    """).first() != nil)
            }
        }
    }

    @Test("Registration budget counts survive a clock rollback without moving the window or violating its timestamp constraint",
          arguments: 0..<5)
    func registrationBudgetRollbackKeepsWindow(clock: Int) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, _, _, _ in
            try await database.transaction { transaction in
                let sql = try #require(transaction as? any SQLDatabase)
                let instants: [Double] = [1_750_000_000, 1_750_000_000.1234567, 946_684_800.1234567,
                    9_224_318_016_000 - 30, -210_866_803_200 + 1000]
                let now = Date(timeIntervalSince1970: instants[clock]), user = UUID()
                let budget = PostgresV2DeviceRegistrationBudget(policy: try .init(maximumActiveDevices: 8, maximumNewDevicesPerWindow: 3, window: 60.5))
                try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "account-state:" + user.uuidString), 0))").run()
                try await budget.recordSuccess(sql, userID: user, now: now)
                let earlier = now.addingTimeInterval(-1)
                for expectedCount in 2...3 {
                    #expect(try await budget.retryAfter(sql, userID: user, now: earlier) == nil)
                    try await budget.recordSuccess(sql, userID: user, now: earlier)
                    #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.device_registration_rate_limits WHERE user_id = \(bind: user) AND successful_registrations = \(bind: expectedCount) AND window_started_at = \(bind: now) AND updated_at = \(bind: now)").first(decoding: CountRow.self)?.value == 1)
                }
                #expect(try await budget.retryAfter(sql, userID: user, now: earlier) == 61)
                #expect(try await budget.retryAfter(sql, userID: user, now: now) == 61)
            }
        }
    }

    @Test("Fractional registration windows retain every successful registration until the full window ends",
          arguments: 0..<5)
    func registrationBudgetFractionalWindow(clock: Int) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, _, _, _ in
            try await database.transaction { transaction in
                let sql = try #require(transaction as? any SQLDatabase)
                let instants: [Double] = [1_750_000_000, 1_750_000_000.1234567, 946_684_800.1234567,
                    9_224_318_016_000 - 1000, -210_866_803_200 + 1000]
                let now = Date(timeIntervalSince1970: instants[clock]), user = UUID()
                let budget = PostgresV2DeviceRegistrationBudget(policy: try .init(maximumActiveDevices: 8, maximumNewDevicesPerWindow: 4, window: 60.5))
                try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "account-state:" + user.uuidString), 0))").run()
                #expect(try await budget.retryAfter(sql, userID: user, now: now) == nil)
                try await budget.recordSuccess(sql, userID: user, now: now)
                let later = now.addingTimeInterval(60.25)
                for expectedCount in 2...4 {
                    #expect(try await budget.retryAfter(sql, userID: user, now: later) == nil)
                    try await budget.recordSuccess(sql, userID: user, now: later)
                    #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.device_registration_rate_limits WHERE user_id = \(bind: user) AND successful_registrations = \(bind: expectedCount) AND window_started_at = \(bind: now)").first(decoding: CountRow.self)?.value == 1)
                }
                #expect(try await budget.retryAfter(sql, userID: user, now: later) == 1)
                let resumed = now.addingTimeInterval(61)
                #expect(try await budget.retryAfter(sql, userID: user, now: resumed) == nil)
                try await budget.recordSuccess(sql, userID: user, now: resumed)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.device_registration_rate_limits WHERE user_id = \(bind: user) AND successful_registrations = 1 AND window_started_at = \(bind: resumed)").first(decoding: CountRow.self)?.value == 1)
            }
        }
    }

    @Test("Registration budget retry hints and successful-window resets use one native cutoff",
          arguments: 0..<5, [-1, 0, 1])
    func registrationBudgetRetryPrecision(clock: Int, microseconds: Int64) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, _, _, _ in
            try await database.transaction { transaction in
                let sql = try #require(transaction as? any SQLDatabase)
                let instants: [Double] = [1_750_000_000, 1_750_000_000.1234567, 946_684_800.1234567,
                    9_224_318_016_000 - 1000, -210_866_803_200 + 1000]
                let now = Date(timeIntervalSince1970: instants[clock]), user = UUID()
                let window: Double = 60.5
                let budget = PostgresV2DeviceRegistrationBudget(policy: try .init(maximumActiveDevices: 8, maximumNewDevicesPerWindow: 4, window: window))
                let cutoff = try #require(v2PostgresPastTimestamp(now: now, interval: window))
                try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "account-state:" + user.uuidString), 0))").run()
                try await sql.raw("INSERT INTO im_v2.device_registration_rate_limits(user_id, window_started_at, successful_registrations, updated_at) VALUES (\(bind: user), \(bind: cutoff)::timestamptz + INTERVAL '1 second' + \(bind: microseconds) * INTERVAL '1 microsecond', 4, \(bind: now))").run()
                func snapshot() async throws -> String {
                    try #require(try await sql.raw("SELECT to_jsonb(r)::text AS value FROM im_v2.device_registration_rate_limits r WHERE user_id = \(bind: user)").first(decoding: StringValueRow.self)).value
                }
                let before = try await snapshot()
                var expectedRetry: Int?
                for seconds in 1...61 {
                    let candidate = try #require(v2PostgresPastTimestamp(now: now.addingTimeInterval(Double(seconds)), interval: window))
                    if try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.device_registration_rate_limits WHERE user_id = \(bind: user) AND window_started_at <= \(bind: candidate)").first(decoding: CountRow.self)?.value == 1 {
                        expectedRetry = seconds; break
                    }
                }
                let expected = try #require(expectedRetry)
                #expect(try await budget.retryAfter(sql, userID: user, now: now) == expected)
                #expect(try await snapshot() == before)
                let resumed = now.addingTimeInterval(Double(expected))
                #expect(try await budget.retryAfter(sql, userID: user, now: resumed) == nil)
                try await budget.recordSuccess(sql, userID: user, now: resumed)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.device_registration_rate_limits WHERE user_id = \(bind: user) AND successful_registrations = 1 AND window_started_at = \(bind: resumed)").first(decoding: CountRow.self)?.value == 1)
            }
        }
    }

    @Test("Invalid registration budget clocks preserve rows and recover without invoking credential issuance",
          arguments: [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
              1e14, -1e14, -210_866_803_200 + 30])
    func registrationBudgetInvalidClock(seconds: Double) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, _, _, _ in
            try await database.transaction { transaction in
                let sql = try #require(transaction as? any SQLDatabase)
                let now = Date(timeIntervalSince1970: 1_750_000_000), user = UUID()
                let budget = PostgresV2DeviceRegistrationBudget(policy: try .init(maximumActiveDevices: 8, maximumNewDevicesPerWindow: 4, window: 60.5))
                try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "account-state:" + user.uuidString), 0))").run()
                try await budget.recordSuccess(sql, userID: user, now: now)
                let before = try #require(try await sql.raw("SELECT to_jsonb(r)::text AS value FROM im_v2.device_registration_rate_limits r WHERE user_id = \(bind: user)").first(decoding: StringValueRow.self)).value
                let invalid = Date(timeIntervalSince1970: seconds)
                await #expect(throws: V2DeviceCredentialServiceError.unavailable) {
                    try await budget.retryAfter(sql, userID: user, now: invalid)
                }
                await #expect(throws: V2DeviceCredentialServiceError.unavailable) {
                    try await budget.recordSuccess(sql, userID: user, now: invalid)
                }
                #expect(try await sql.raw("SELECT to_jsonb(r)::text AS value FROM im_v2.device_registration_rate_limits r WHERE user_id = \(bind: user)").first(decoding: StringValueRow.self)?.value == before)
                #expect(try await budget.retryAfter(sql, userID: user, now: now.addingTimeInterval(1)) == nil)
                try await budget.recordSuccess(sql, userID: user, now: now.addingTimeInterval(1))
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.device_registration_rate_limits WHERE user_id = \(bind: user) AND successful_registrations = 2 AND window_started_at = \(bind: now)").first(decoding: CountRow.self)?.value == 1)
            }
        }
    }

    @Test("Budget retry seconds match native window cutoffs without timestamp round trips",
          arguments: 0..<5, [-1, 0, 1])
    func budgetRetryTimestampPrecision(clock: Int, microseconds: Int64) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let instants: [Double] = [1_750_000_000, 1_750_000_000.1234567,
                946_684_800.1234567, 9_224_318_016_000 - 1000, -210_866_803_200 + 1000]
            let now = Date(timeIntervalSince1970: instants[clock])
            let window: Double = 5.25
            let cutoff = try #require(v2PostgresPastTimestamp(now: now, interval: window))
            let key = try V2AccountEdgeClientRateLimitKey(base64Encoded: Data(repeating: 9, count: 32).base64EncodedString())
            let address = try V2AccountEdgeClientAddress("192.0.2.46")
            let missingHandle = try V2PublicHandle("retry_clock_missing")
            func edge(at date: Date) throws -> V2PostgresAccountEdgeClientRateLimiter {
                .init(database: database, policy: try .init(maximumRequests: 1, window: window), key: key, now: { date })
            }
            func directory(at date: Date) throws -> V2PostgresPublicIdentityDirectory {
                .init(database: database, policy: try .init(maximumQueries: 1, window: window), now: { date })
            }
            let initialEdge = try edge(at: now), initialDirectory = try directory(at: now)
            #expect(try await initialEdge.consume(address: address) == .allowed)
            #expect(try await initialDirectory.resolve(handle: missingHandle, actorUserID: senderID) == nil)
            for table in ["account_edge_client_rate_limits", "public_identity_lookup_rate_limits"] {
                try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET window_started_at = \(bind: cutoff)::timestamptz + INTERVAL '1 second' + \(bind: microseconds) * INTERVAL '1 microsecond'").run()
            }
            var expectedRetry: Int?
            for seconds in 1...6 {
                let later = now.addingTimeInterval(Double(seconds))
                let candidateCutoff = try #require(v2PostgresPastTimestamp(now: later, interval: window))
                let expired = try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.account_edge_client_rate_limits WHERE window_started_at <= \(bind: candidateCutoff)").first(decoding: CountRow.self)?.value == 1
                if expired { expectedRetry = seconds; break }
            }
            let expected = try #require(expectedRetry)
            #expect(try await initialEdge.consume(address: address) == .rateLimited(retryAfterSeconds: expected))
            await #expect(throws: V2PublicIdentityDirectoryError.rateLimited(retryAfterSeconds: expected)) {
                try await initialDirectory.resolve(handle: missingHandle, actorUserID: senderID)
            }
            for table in ["account_edge_client_rate_limits", "public_identity_lookup_rate_limits"] {
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table) WHERE window_started_at = \(bind: cutoff)::timestamptz + INTERVAL '1 second' + \(bind: microseconds) * INTERVAL '1 microsecond'").first(decoding: CountRow.self)?.value == 1)
            }
            // Waiting the reported whole seconds reaches the same SQL reset
            // boundary; the existing window is never moved by a denial.
            let resumed = now.addingTimeInterval(Double(expected))
            #expect(try await edge(at: resumed).consume(address: address) == .allowed)
            #expect(try await directory(at: resumed).resolve(handle: missingHandle, actorUserID: senderID) == nil)
            // Preserve the established bounded retry hint on clock rollback,
            // including a difference wider than a signed microsecond interval.
            let future = clock == 4 ? Date(timeIntervalSince1970: 9_224_318_016_000 - 1000) : now.addingTimeInterval(60)
            try await sql.raw("UPDATE im_v2.account_edge_client_rate_limits SET window_started_at = \(bind: future), request_count = 2").run()
            try await sql.raw("UPDATE im_v2.public_identity_lookup_rate_limits SET window_started_at = \(bind: future), query_count = 2").run()
            #expect(try await initialEdge.consume(address: address) == .rateLimited(retryAfterSeconds: 6))
            await #expect(throws: V2PublicIdentityDirectoryError.rateLimited(retryAfterSeconds: 6)) {
                try await initialDirectory.resolve(handle: missingHandle, actorUserID: senderID)
            }
        }
    }

    @Test("An expired device reset recovers while a shared snapshot remains valid for another device",
          arguments: [false, true])
    func sharedSnapshotAssignmentExpiry(published: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let userUUID = UUID(), firstUUID = UUID(), secondUUID = UUID()
            let user = UserID(uuid: userUUID), first = DeviceID(uuid: firstUUID), second = DeviceID(uuid: secondUUID)
            for device in [firstUUID, secondUUID] {
                try await sql.raw("INSERT INTO im_v2.auth_devices(user_id, device_id, created_at, last_active_at) VALUES (\(bind: userUUID), \(bind: device), \(bind: base), \(bind: base))").run()
                try await sql.raw("INSERT INTO im_v2.device_sync_cursors(user_id, device_id, state, reset_generation, acknowledged_sequence) VALUES (\(bind: userUUID), \(bind: device), 'ready', 1, 5)").run()
            }
            // A compacted history has projected through 9, but each device has
            // only acknowledged 5. Recovery must keep 5 until a new snapshot ACK.
            try await sql.raw("INSERT INTO im_v2.user_sync_sequences(user_id, next_sequence) VALUES (\(bind: userUUID), 10)").run()
            try await sql.raw("INSERT INTO im_v2.user_projection_checkpoints(user_id, projected_sequence, updated_at) VALUES (\(bind: userUUID), 9, \(bind: base))").run()
            try await sql.raw("INSERT INTO im_v2.user_sync_retention(user_id, compacted_through_sequence, updated_at) VALUES (\(bind: userUUID), 9, \(bind: base))").run()
            let sync = PostgresV2SyncStore(database: database, capabilityLifetime: 60)
            let builder = PostgresV2SnapshotArtifactBuilder(database: database)
            let housekeeping = PostgresV2SyncHousekeepingStore(database: database)
            guard case .resetPreparing(let snapshotID, let generation, _) = try await sync.pull(userID: user, deviceID: first, syncToken: nil, maxRecords: 20, requireSnapshot: true, now: base) else { throw CancellationError() }
            let oldReceipt = try V2SyncReceipt(try #require(try await sql.raw("SELECT snapshot_receipt AS value FROM im_v2.device_snapshot_resets WHERE device_id = \(bind: firstUUID)").first(decoding: StringValueRow.self)).value)
            let oldToken = try V2SyncToken(try #require(try await sql.raw("SELECT next_sync_token AS value FROM im_v2.device_snapshot_resets WHERE device_id = \(bind: firstUUID)").first(decoding: StringValueRow.self)).value)
            if published { while try await builder.runOnce(now: base).claimed { try Task.checkCancellation() } }
            guard case .resetPreparing(let shared, let secondGeneration, _) = try await sync.pull(userID: user, deviceID: second, syncToken: nil, maxRecords: 20, requireSnapshot: true, now: base.addingTimeInterval(30)) else { throw CancellationError() }
            #expect(shared == snapshotID && secondGeneration == generation)
            func snapshot(_ table: String, key: String, id: UUID) async throws -> String {
                try #require(try await sql.raw("SELECT to_jsonb(r)::text AS value FROM im_v2.\(unsafeRaw: table) r WHERE \(unsafeRaw: key) = \(bind: id)").first(decoding: StringValueRow.self)).value
            }
            let artifactBefore = try await snapshot("sync_snapshot_artifacts", key: "snapshot_id", id: snapshotID.uuidValue!)
            let secondBefore = try await snapshot("device_snapshot_resets", key: "device_id", id: secondUUID)
            let firstBefore = try await snapshot("device_snapshot_resets", key: "device_id", id: firstUUID)
            let firstCursorBefore = try await snapshot("device_sync_cursors", key: "device_id", id: firstUUID)
            let expiry = base.addingTimeInterval(60)
            #expect(try await housekeeping.purgeExpired(now: expiry.addingTimeInterval(-0.000001), projectionEffectRetention: V2IdempotencyPolicy.minimumServerRetention, limit: 1).recoveredResetCount == 0)
            let recovered = try await housekeeping.purgeExpired(now: expiry, projectionEffectRetention: V2IdempotencyPolicy.minimumServerRetention, limit: 1)
            #expect(recovered.recoveredResetCount == 1 && recovered.purgedSnapshotCount == 0)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.device_sync_cursors WHERE device_id = \(bind: firstUUID) AND state = 'ready' AND reset_generation = 1 AND acknowledged_sequence = 5 AND pending_snapshot_id IS NULL").first(decoding: CountRow.self)?.value == 1)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.device_snapshot_resets WHERE device_id = \(bind: firstUUID)").first(decoding: CountRow.self)?.value == 0)
            #expect(try await snapshot("device_snapshot_resets", key: "device_id", id: secondUUID) == secondBefore)
            #expect(try await snapshot("sync_snapshot_artifacts", key: "snapshot_id", id: snapshotID.uuidValue!) == artifactBefore)
            #expect(try await !housekeeping.purgeExpired(now: expiry, projectionEffectRetention: V2IdempotencyPolicy.minimumServerRetention, limit: 1).didWork)
            // The recovered device can reuse the live payload with a new receipt.
            guard case .resetPreparing(let reused, let newGeneration, _) = try await sync.pull(userID: user, deviceID: first, syncToken: nil, maxRecords: 20, requireSnapshot: true, now: expiry) else { throw CancellationError() }
            #expect(reused == snapshotID && newGeneration == generation)
            if !published { while try await builder.runOnce(now: expiry).claimed { try Task.checkCancellation() } }
            let resumedAt = expiry.addingTimeInterval(1)
            let firstManifest = try await sync.fetchSnapshotManifest(userID: user, deviceID: first, snapshotID: snapshotID, generation: generation, now: resumedAt)
            let secondManifest = try await sync.fetchSnapshotManifest(userID: user, deviceID: second, snapshotID: snapshotID, generation: generation, now: resumedAt)
            #expect(firstManifest.baseSequence == 9 && firstManifest.receipt != oldReceipt)
            #expect(firstManifest.expiresAt == expiry.addingTimeInterval(60) && secondManifest.expiresAt == base.addingTimeInterval(90))
            await #expect(throws: V2SyncStoreError.snapshotExpiredOrInvalid) {
                try await sync.acknowledgeSnapshot(userID: user, deviceID: first, snapshotID: snapshotID, generation: generation, baseSequence: 9, receipt: oldReceipt, now: resumedAt)
            }
            for (device, manifest) in [(first, firstManifest), (second, secondManifest)] {
                try await sync.acknowledgeSnapshot(userID: user, deviceID: device, snapshotID: snapshotID, generation: generation, baseSequence: 9, receipt: manifest.receipt, now: resumedAt)
                guard case .ready(let current, let records, _, _, _) = try await sync.pull(userID: user, deviceID: device, syncToken: manifest.nextSyncToken, maxRecords: 20, now: resumedAt) else { throw CancellationError() }
                #expect(current == generation && records.isEmpty)
            }
            await #expect(throws: V2SyncStoreError.invalidOrExpiredSyncToken) {
                try await sync.pull(userID: user, deviceID: first, syncToken: oldToken, maxRecords: 20, now: resumedAt)
            }
            #expect(try await count("im_v2.device_sync_cursors WHERE state = 'ready' AND reset_generation = 2 AND acknowledged_sequence = 9", on: sql) == 2)
        }
    }

    @Test("Creation coordination rejects native timestamp mismatches without publishing or completing recovery",
          arguments: 0..<6, ["created_before", "created_after", "expires_before", "expires_after", "matching"])
    func inviteCoordinatorTimestampPrecision(clock: Int, difference: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, sql, ownerSQL, room in
            let instants: [Double] = [1_750_000_000, 946_684_800 + 0.00000125,
                946_684_800 - 0.00000125, 1_750_000_000.1234567,
                -210_866_803_200 + 10.223, 9_224_318_016_000 - 1000.223]
            let base = Date(timeIntervalSince1970: instants[clock])
            let matches = difference == "matching"
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            // Production path: coordinator plus a room turn on the owner. Each
            // request carries the digest the issuer derives for its operation.
            let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 0x12, count: 32))
            let sequence = TestSequenceClock([base])
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let coordinator = V2ActorInvitationCoordinator(controlDatabase: control,
                room: invitationRoomPort(control: control, owner: owner, shardID: "room-b", capacityProfile: profile, now: { sequence.now() }),
                secretIssuer: issuer, now: { sequence.now() })
            func create(_ request: V2GroupInviteCreatePersistenceRequest, at time: Date) async throws -> V2ActorGroupInviteLinkWire {
                sequence.set([time])
                guard case .created(let link) = try await coordinator.create(.init(roomID: room, actorUserID: senderID,
                    operationID: request.operationID, lifetime: TimeInterval(request.requestedLifetimeSeconds),
                    maximumApprovedUses: request.maximumApprovedUses), deadline: invitationTestDeadline()) else {
                    throw V2GroupInvitationServiceError.corruptPersistenceState
                }
                return link
            }
            func request() throws -> V2GroupInviteCreatePersistenceRequest {
                let operation = GroupInviteOperationID(uuid: UUID())
                return .init(inviteID: .init(uuid: UUID()), roomID: room, actorUserID: senderID, operationID: operation,
                    tokenDigest: issuer.digest(try issuer.secret(actorUserID: senderID, operationID: operation)), requestedLifetimeSeconds: 300,
                    expiresAt: base.addingTimeInterval(300), maximumApprovedUses: 5, maximumActiveInvitesPerRoom: 20, createdAt: base)
            }
            let first = try request(), healthy = try request()
            _ = try await PostgresV2GroupInvitationStore(database: owner).create(first)
            if !matches {
                let column = difference.hasPrefix("created") ? "created_at" : "expires_at"
                let delta: Int64 = difference.hasSuffix("before") ? -1 : 1
                // Model a disagreement between independently persisted legacy
                // bindings; both timestamps remain valid and encodable.
                try await ownerSQL.raw("UPDATE im_v2.group_invite_links SET \(unsafeRaw: column) = \(unsafeRaw: column) + \(bind: delta) * INTERVAL '1 microsecond' WHERE invite_id = \(bind: first.inviteID.uuidValue!)").run()
            }
            let directory = PostgresV2GroupInviteDirectory(database: control)
            _ = try await directory.prepare(first)
            _ = try await directory.prepare(healthy)
            func snapshot(_ database: any SQLDatabase, table: String, key: String, id: UUID) async throws -> String {
                try #require(try await database.raw("SELECT to_jsonb(r)::text AS value FROM im_v2.\(unsafeRaw: table) r WHERE \(unsafeRaw: key) = \(bind: id)").first(decoding: StringValueRow.self)).value
            }
            let ownerBefore = try await snapshot(ownerSQL, table: "group_invite_links", key: "invite_id", id: first.inviteID.uuidValue!)
            let directoryBefore = try await snapshot(sql, table: "group_invite_directory", key: "invite_id", id: first.inviteID.uuidValue!)
            let jobBefore = try await snapshot(sql, table: "group_invite_creation_recovery", key: "operation_id", id: first.operationID.uuidValue!)
            for _ in 0..<2 {
                if matches {
                    #expect(try await create(first, at: base.addingTimeInterval(1)).inviteID == first.inviteID)
                } else {
                    await #expect(throws: V2GroupInviteDirectoryError.ownerResultMismatch) {
                        _ = try await create(first, at: base.addingTimeInterval(1))
                    }
                    #expect(try await snapshot(sql, table: "group_invite_directory", key: "invite_id", id: first.inviteID.uuidValue!) == directoryBefore)
                    #expect(try await snapshot(sql, table: "group_invite_creation_recovery", key: "operation_id", id: first.operationID.uuidValue!) == jobBefore)
                }
            }
            let recoveredAt = base.addingTimeInterval(31)
            sequence.set([recoveredAt])
            let worker = V2GroupInviteCreationRecoveryWorker(jobs: directory, coordinator: coordinator, deadline: invitationTestDeadline, now: { recoveredAt })
            let report = try await worker.runOnce(limit: 2)
            #expect(report.attempted == (matches ? 1 : 2) && report.completed == 1 && report.paused == (matches ? 0 : 1))
            #expect(report.deferred == 0 && report.lostClaim == 0)
            #expect(try await worker.runOnce(limit: 2).attempted == 0)
            #expect(try await directory.resolve(tokenDigest: healthy.tokenDigest)?.inviteID == healthy.inviteID)
            #expect((try await directory.resolve(tokenDigest: first.tokenDigest) != nil) == matches)
            if !matches {
                #expect(try await snapshot(sql, table: "group_invite_directory", key: "invite_id", id: first.inviteID.uuidValue!) == directoryBefore)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_creation_recovery WHERE operation_id = \(bind: first.operationID.uuidValue!) AND state = 'paused' AND last_error_code = 'conflicting_evidence' AND attempt_count = 1 AND claim_token IS NULL AND lease_expires_at IS NULL").first(decoding: CountRow.self)?.value == 1)
                await #expect(throws: V2GroupInviteDirectoryError.ownerResultMismatch) {
                    _ = try await create(first, at: recoveredAt)
                }
            }
            #expect(try await snapshot(ownerSQL, table: "group_invite_links", key: "invite_id", id: first.inviteID.uuidValue!) == ownerBefore)
            #expect(try await count("im_v2.group_invite_links", on: ownerSQL) == 2)
            #expect(try await count("im_v2.group_invite_directory WHERE state = 'ready'", on: sql) == (matches ? 2 : 1))
        }
    }


    @Test("Invite creation preserves exact control and owner timestamps across foreground, recovery and legacy adoption",
          arguments: 0..<6, ["foreground", "recovery", "legacy"])
    func inviteCreationBindingPrecision(clock: Int, path: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, sql, ownerSQL, room in
            let instants: [Double] = [1_750_000_000, 946_684_800 + 0.00000125,
                946_684_800 - 0.00000125, 1_750_000_000.1234567,
                -210_866_803_200 + 10.223, 9_224_318_016_000 - 1000.223]
            let base = Date(timeIntervalSince1970: instants[clock])
            let deadline = base.addingTimeInterval(300)
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            let directory = PostgresV2GroupInviteDirectory(database: control)
            // Production path: coordinator plus a room turn on the owner. The
            // request carries the issued digest, and foreground creation mints
            // its preset invite ID at `base`, so every path binds identically.
            let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 0x62, count: 32))
            let operation = GroupInviteOperationID(uuid: UUID()), inviteID = GroupInviteID(uuid: UUID())
            let sequence = TestSequenceClock([base])
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let coordinator = V2ActorInvitationCoordinator(controlDatabase: control,
                room: invitationRoomPort(control: control, owner: owner, shardID: "room-b", capacityProfile: profile, now: { sequence.now() }),
                secretIssuer: issuer, makeUUID: { inviteID.uuidValue! }, now: { sequence.now() })
            func create(at time: Date) async throws -> V2ActorGroupInviteLinkWire {
                sequence.set([time])
                guard case .created(let link) = try await coordinator.create(.init(roomID: room, actorUserID: senderID,
                    operationID: operation, lifetime: 300, maximumApprovedUses: 5), deadline: invitationTestDeadline()) else {
                    throw V2GroupInvitationServiceError.corruptPersistenceState
                }
                return link
            }
            func active(at time: Date) async throws -> [V2ActorGroupInviteLinkWire] {
                sequence.set([time])
                guard case .active(let links) = try await coordinator.active(.init(roomID: room, actorUserID: senderID),
                    deadline: invitationTestDeadline()) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                return links
            }
            let request = V2GroupInviteCreatePersistenceRequest(inviteID: inviteID, roomID: room,
                actorUserID: senderID, operationID: operation, tokenDigest: issuer.digest(try issuer.secret(actorUserID: senderID, operationID: operation)),
                requestedLifetimeSeconds: 300, expiresAt: deadline, maximumApprovedUses: 5,
                maximumActiveInvitesPerRoom: 20, createdAt: base)
            if path == "legacy" {
                _ = try await PostgresV2GroupInvitationStore(database: owner).create(request)
            } else if path == "recovery" {
                _ = try await directory.prepare(request)
                let recoveredAt = base.addingTimeInterval(31)
                sequence.set([recoveredAt])
                let result = try await V2GroupInviteCreationRecoveryWorker(jobs: directory, coordinator: coordinator,
                    deadline: invitationTestDeadline, now: { recoveredAt }).runOnce(limit: 1)
                #expect(result.attempted == 1 && result.completed == 1 && result.deferred == 0 && result.paused == 0)
            }
            let first = try await create(at: path == "foreground" ? base : base.addingTimeInterval(32))
            #expect(first.inviteID == request.inviteID && first.state == .active)
            for (database, table) in [(sql, "group_invite_directory"), (ownerSQL, "group_invite_links")] {
                #expect(try await database.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table) WHERE created_at = \(bind: base) AND expires_at = \(bind: deadline)").first(decoding: CountRow.self)?.value == 1)
            }
            func binding(_ database: any SQLDatabase, table: String) async throws -> String {
                try #require(try await database.raw("SELECT jsonb_build_object('created', created_at, 'expires', expires_at)::text AS value FROM im_v2.\(unsafeRaw: table)").first(decoding: StringValueRow.self)).value
            }
            let controlBinding = try await binding(sql, table: "group_invite_directory")
            let ownerBinding = try await binding(ownerSQL, table: "group_invite_links")
            #expect(controlBinding == ownerBinding)
            #expect(try await count("im_v2.group_invite_directory WHERE state = 'ready'", on: sql) == 1)
            #expect(try await count("im_v2.group_invite_creation_recovery WHERE state = 'completed'", on: sql) == 1)
            let later = base.addingTimeInterval(40)
            let replay = try await create(at: later)
            #expect(replay == first)
            #expect(try await active(at: later) == [replay])
            #expect(try await V2GroupInviteCreationRecoveryWorker(jobs: directory, coordinator: coordinator,
                deadline: invitationTestDeadline, now: { later }).runOnce().attempted == 0)
            let edge = deadline.addingTimeInterval(-0.00000025)
            let stillLive = try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_directory WHERE expires_at > \(bind: edge)").first(decoding: CountRow.self)?.value == 1
            let atEdge = try await create(at: edge)
            #expect(atEdge.state == (stillLive ? .active : .expired))
            #expect(try await active(at: edge).count == (stillLive ? 1 : 0))
            #expect(try await binding(sql, table: "group_invite_directory") == controlBinding)
            #expect(try await binding(ownerSQL, table: "group_invite_links") == ownerBinding)
            #expect(try await count("im_v2.group_invite_links", on: ownerSQL) == 1)
        }
    }

    @Test("Terminal housekeeping preserves fresh rows when retention disappears in timestamp encoding",
          arguments: [false, true], [0, 1, 2])
    func housekeepingRetentionPrecision(worker: Bool, clock: Int) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let instants: [Double] = [1_750_000_000, 946_684_800 + 0.00000075, 9_224_318_016_000 - 10]
            let intervals: [Double] = [0.000000001, 0.00000025, 0.0001]
            let now = Date(timeIntervalSince1970: instants[clock])
            let old = now.addingTimeInterval(-1)
            let retention = intervals[clock]
            let replayRetention = V2IdempotencyPolicy.minimumServerRetention
            let oldID = UUID(), freshID = UUID(), pendingID = UUID()
            for (id, time, state) in [(oldID, old, "completed"), (freshID, now, "completed"), (pendingID, old, "pending")] {
                let completedAt: Date? = state == "completed" ? time : nil
                try await sql.raw("""
                    INSERT INTO im_v2.public_profile_update_outbox
                        (source_event_id, source_user_id, public_handle, display_name, revision,
                         profile_updated_at, state, created_at, completed_at)
                    VALUES (\(bind: id), \(bind: senderUUID), 'sender012', 'Clock fixture', 1,
                            \(bind: time), \(bind: state), \(bind: time), \(bind: completedAt))
                    """).run()
            }
            func snapshot() async throws -> String {
                guard let row = try await sql.raw("""
                    SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY source_event_id), '[]'::jsonb)::text AS value
                    FROM im_v2.public_profile_update_outbox r
                    """).first(decoding: StringValueRow.self) else { throw CancellationError() }
                return row.value
            }
            let store = PostgresV2ControlPlaneHousekeepingStore(database: database)
            let before = try await snapshot()
            for _ in 0..<2 {
                await #expect(throws: V2ControlPlaneHousekeepingError.corruptPersistenceState) {
                    if worker {
                        return try await V2ControlPlaneHousekeepingWorker(store: store, retention: retention, now: { now }).runOnce(limit: 1_024)
                    }
                    return try await store.purgeTerminal(now: now, retention: retention,
                        idempotencyRetention: replayRetention, limit: 1_024)
                }
                #expect(try await snapshot() == before)
            }
            let first = try await V2ControlPlaneHousekeepingWorker(store: store, retention: 0.5, now: { now }).runOnce(limit: 1_024)
            #expect(first == .init(deletedRows: 1))
            let remaining = try await snapshot()
            #expect(remaining.contains(freshID.uuidString.lowercased()))
            #expect(remaining.contains(pendingID.uuidString.lowercased()))
            #expect(!remaining.contains(oldID.uuidString.lowercased()))
            let repeated = try await store.purgeTerminal(now: now, retention: 0.5,
                idempotencyRetention: replayRetention, limit: 1_024)
            #expect(!repeated.didWork)
            #expect(try await snapshot() == remaining)
            let later = now.addingTimeInterval(1)
            let second = try await V2ControlPlaneHousekeepingWorker(store: store, retention: 0.5, now: { later }).runOnce(limit: 1_024)
            #expect(second == .init(deletedRows: 1))
            #expect(try await count("im_v2.public_profile_update_outbox WHERE state = 'pending'", on: sql) == 1)
            #expect(try await count("im_v2.public_profile_update_outbox", on: sql) == 1)
        }
    }

    @Test("Budget windows must remain strictly positive after PostgreSQL encoding and recover without changing prior rows",
          arguments: [0, 1, 2])
    func budgetCutoffPrecision(clock: Int) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let instants: [Double] = [1_750_000_000, 946_684_800 + 0.00000075, 9_224_318_016_000 - 10]
            let windows: [Double] = [0.000000001, 0.00000025, 0.0001]
            let invalidNow = Date(timeIntervalSince1970: instants[clock])
            let invalidWindow = windows[clock]
            let initialNow = invalidNow.addingTimeInterval(-1)
            let key = try V2AccountEdgeClientRateLimitKey(base64Encoded: Data(repeating: 8, count: 32).base64EncodedString())
            let address = try V2AccountEdgeClientAddress("192.0.2.44")
            let newAddress = try V2AccountEdgeClientAddress("192.0.2.45")
            let missingHandle = try V2PublicHandle("clock_missing")
            func edge(at date: Date, window: Double) throws -> V2PostgresAccountEdgeClientRateLimiter {
                .init(database: database, policy: try .init(maximumRequests: 1, window: window), key: key, now: { date })
            }
            func directory(at date: Date, window: Double) throws -> V2PostgresPublicIdentityDirectory {
                .init(database: database, policy: try .init(maximumQueries: 1, window: window), now: { date })
            }
            func snapshot() async throws -> String {
                let row = try await sql.raw("""
                    SELECT jsonb_build_object(
                        'edge', (SELECT jsonb_agg(to_jsonb(r) ORDER BY client_key) FROM im_v2.account_edge_client_rate_limits r),
                        'lookup', (SELECT jsonb_agg(to_jsonb(r) ORDER BY actor_user_id) FROM im_v2.public_identity_lookup_rate_limits r)
                    )::text AS value
                    """).first(decoding: StringValueRow.self)
                guard let decoded = row else { throw CancellationError() }
                return decoded.value
            }
            let initialEdge = try edge(at: initialNow, window: 0.5)
            let initialDirectory = try directory(at: initialNow, window: 0.5)
            #expect(try await initialEdge.consume(address: address) == .allowed)
            #expect(try await initialDirectory.resolve(handle: missingHandle, actorUserID: senderID) == nil)
            let before = try await snapshot()
            let invalidEdge = try edge(at: invalidNow, window: invalidWindow)
            let invalidDirectory = try directory(at: invalidNow, window: invalidWindow)
            for candidate in [address, newAddress] {
                await #expect(throws: V2AccountEdgeClientRateLimitError.unavailable) {
                    try await invalidEdge.consume(address: candidate)
                }
                #expect(try await snapshot() == before)
            }
            for actor in [senderID, UserID(uuid: memberTwoUUID)] {
                await #expect(throws: V2PublicIdentityDirectoryError.unavailable) {
                    try await invalidDirectory.resolve(handle: missingHandle, actorUserID: actor)
                }
                #expect(try await snapshot() == before)
            }
            await #expect(throws: V2AccountEdgeClientRateLimitError.unavailable) {
                try await invalidEdge.purgeExpired(limit: 10)
            }
            #expect(try await snapshot() == before)
            // Even a cutoff that fits cannot make an out-of-range current clock valid.
            let outside = try edge(at: Date(timeIntervalSince1970: 9_224_318_016_000), window: 60)
            await #expect(throws: V2AccountEdgeClientRateLimitError.unavailable) {
                try await outside.purgeExpired(limit: 10)
            }
            #expect(try await snapshot() == before)
            #expect(try await initialEdge.consume(address: address) == .rateLimited(retryAfterSeconds: 1))
            await #expect(throws: V2PublicIdentityDirectoryError.rateLimited(retryAfterSeconds: 1)) {
                try await initialDirectory.resolve(handle: missingHandle, actorUserID: senderID)
            }
            let recoveredEdge = try edge(at: invalidNow, window: 0.5)
            let recoveredDirectory = try directory(at: invalidNow, window: 0.5)
            #expect(try await recoveredEdge.consume(address: address) == .allowed)
            #expect(try await recoveredDirectory.resolve(handle: missingHandle, actorUserID: senderID) == nil)
            #expect(try await recoveredEdge.consume(address: address) == .rateLimited(retryAfterSeconds: 1))
            await #expect(throws: V2PublicIdentityDirectoryError.rateLimited(retryAfterSeconds: 1)) {
                try await recoveredDirectory.resolve(handle: missingHandle, actorUserID: senderID)
            }
            #expect(try await recoveredEdge.purgeExpired(limit: 10) == 0)
            let later = try edge(at: invalidNow.addingTimeInterval(1), window: 0.5)
            #expect(try await later.purgeExpired(limit: 10) == 1)
        }
    }

    @Test("Shared snapshot expiry never precedes a device assignment or shrinks during reuse",
          arguments: 0..<6, [false, true])
    func snapshotExtensionTimestampPrecision(index: Int, published: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let clocks: [Double] = [1_750_000_000, -210_866_803_200 + 10, 9_224_318_016_000 - 10,
                -210_866_803_200 + 10, 9_224_318_016_000 - 10, 1_750_000_000]
            let lifetimes: [Double] = [1, 1, 1, 0.223, 1, 1]
            let deltas: [Int64] = [-1, -1, -1, 1, 1, 0]
            let now = Date(timeIntervalSince1970: clocks[index])
            let firstAt = now.addingTimeInterval(-1), deadline = now.addingTimeInterval(lifetimes[index])
            let delta = deltas[index]
            let userUUID = UUID(), firstUUID = UUID(), secondUUID = UUID()
            let user = UserID(uuid: userUUID), first = DeviceID(uuid: firstUUID), second = DeviceID(uuid: secondUUID)
            for device in [firstUUID, secondUUID] {
                try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: userUUID), \(bind: device), \(bind: firstAt), \(bind: firstAt))").run()
            }
            let store = PostgresV2SyncStore(database: database, capabilityLifetime: lifetimes[index])
            guard case .resetPreparing(let snapshotID, let generation, _) = try await store.pull(userID: user, deviceID: first,
                syncToken: nil, maxRecords: 20, requireSnapshot: true, now: firstAt) else { throw CancellationError() }
            let builder = PostgresV2SnapshotArtifactBuilder(database: database, leaseDuration: 1)
            var originalDigest: String?
            if published {
                while try await builder.runOnce(now: firstAt).claimed { try Task.checkCancellation() }
                originalDigest = try await store.fetchSnapshotManifest(userID: user, deviceID: first, snapshotID: snapshotID, generation: generation, now: firstAt).rootDigest
            }
            // Seed an exact retained artifact deadline. It remains later than
            // the earlier device's assignment; the new assignment must extend
            // it when needed and must never shorten it.
            try await sql.raw("UPDATE im_v2.sync_snapshot_artifacts SET expires_at = \(bind: deadline)::timestamptz + \(bind: delta) * INTERVAL '1 microsecond'").run()
            #expect(try await count("im_v2.sync_snapshot_artifacts a JOIN im_v2.device_snapshot_resets r USING (snapshot_id) WHERE a.expires_at >= r.expires_at", on: sql) == 1)
            let firstAssignment = try #require(try await sql.raw("SELECT to_jsonb(r)::text AS value FROM im_v2.device_snapshot_resets r WHERE device_id = \(bind: firstUUID)").first(decoding: StringValueRow.self)).value
            guard case .resetPreparing(let reused, let secondGeneration, _) = try await store.pull(userID: user, deviceID: second,
                syncToken: nil, maxRecords: 20, requireSnapshot: true, now: now) else { throw CancellationError() }
            #expect(reused == snapshotID && secondGeneration == generation)
            #expect(try await count("im_v2.sync_snapshot_artifacts", on: sql) == 1)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.sync_snapshot_artifacts WHERE expires_at = \(bind: deadline)::timestamptz + \(bind: max(delta, 0)) * INTERVAL '1 microsecond'").first(decoding: CountRow.self)?.value == 1)
            #expect(try await count("im_v2.sync_snapshot_artifacts a JOIN im_v2.device_snapshot_resets r USING (snapshot_id) WHERE a.expires_at >= r.expires_at", on: sql) == 2)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.device_snapshot_resets WHERE device_id = \(bind: secondUUID) AND expires_at = \(bind: deadline)").first(decoding: CountRow.self)?.value == 1)
            #expect(try await sql.raw("SELECT to_jsonb(r)::text AS value FROM im_v2.device_snapshot_resets r WHERE device_id = \(bind: firstUUID)").first(decoding: StringValueRow.self)?.value == firstAssignment)
            if !published {
                while try await builder.runOnce(now: now).claimed { try Task.checkCancellation() }
            }
            let manifest = try await store.fetchSnapshotManifest(userID: user, deviceID: second, snapshotID: snapshotID, generation: generation, now: now)
            if let originalDigest { #expect(manifest.rootDigest == originalDigest) }
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.sync_snapshot_artifacts WHERE state = 'published' AND expires_at = \(bind: deadline)::timestamptz + \(bind: max(delta, 0)) * INTERVAL '1 microsecond'").first(decoding: CountRow.self)?.value == 1)
            try await store.acknowledgeSnapshot(userID: user, deviceID: second, snapshotID: snapshotID, generation: generation, baseSequence: manifest.baseSequence, receipt: manifest.receipt, now: now)
            guard case .ready(let resumed, let records, _, _, _) = try await store.pull(userID: user, deviceID: second, syncToken: manifest.nextSyncToken, maxRecords: 20, now: now) else { throw CancellationError() }
            #expect(resumed == generation && records.isEmpty)
        }
    }



    @Test("Profile and receipt propagation recover at retry limits without duplicating recipient effects",
          arguments: ["profile", "receipt"], 0..<12)
    func propagationRetryCounterBoundary(path: String, index: Int) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, userDatabase, sql, userSQL, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000.1234567)
            let now = base.addingTimeInterval(30)
            let counterIndex = index % 6, fails = index >= 6, expired = counterIndex >= 3
            let counters: [Int64] = [0, Int64.max - 1, Int64.max, 1, Int64.max - 1, Int64.max]
            let starting = counters[counterIndex]
            let profile = try forwardImportTestProfile()
            let primary = UUID(), healthy = UUID()
            var primaryRoom = UUID()
            for (offset, actor) in [senderUUID, memberThreeUUID].enumerated() {
                let time = base.addingTimeInterval(Double(offset))
                let direct = try V2DirectMessagingService(store: PostgresV2DirectMessagingStore(database: database), capacityProfile: profile, roomShardID: "room-a", now: { time })
                guard case .opened(let room) = try await direct.open(actorUserID: .init(uuid: actor), operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID)) else { throw CancellationError() }
                if offset == 0 { primaryRoom = try #require(room.roomID.uuidValue) }
                let sender = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database), capacityProfile: profile, limits: .init(maxUTF8Bytes: 64), now: { time })
                guard case .accepted = try await sender.send(.init(roomID: room.roomID, actorUserID: .init(uuid: actor), clientMessageID: .init(uuid: UUID()), text: "propagation retry")) else { throw CancellationError() }
                let operation = offset == 0 ? primary : healthy
                if path == "profile" {
                    let directory = V2PostgresPublicIdentityDirectory(database: database, policy: try .init(maximumQueries: 10, window: 60), makeUUID: { operation }, now: { time })
                    _ = try await directory.updateDisplayName(for: .init(uuid: actor), displayName: "Retry profile \(offset)")
                } else {
                    let preferences = V2ReadReceiptService(store: PostgresV2ReadReceiptStore(database: database), now: { time })
                    guard case .updated = try await preferences.setPreferences(actorUserID: .init(uuid: actor), operationID: .init(uuid: operation), allowsDirectReadReceipts: false, allowsGroupReadReceipts: true) else { throw CancellationError() }
                }
            }
            if path == "receipt" {
                try await sql.raw("""
                    INSERT INTO im_v2.direct_room_owner_routes
                        (lower_user_id, higher_user_id, room_id, room_shard_id, route_epoch, created_at, updated_at)
                    SELECT pair.lower_user_id, pair.higher_user_id, pair.room_id, room.room_shard_id,
                           room.owner_epoch, \(bind: base), \(bind: base)
                    FROM im_v2.direct_room_pairs AS pair JOIN im_v2.rooms AS room USING (room_id)
                    """).run()
                try await sql.raw("CREATE TABLE im_v2.test_retry_receipt_failure(operation_id uuid PRIMARY KEY)").run()
                if fails {
                    try await sql.raw("INSERT INTO im_v2.test_retry_receipt_failure VALUES (\(bind: primary))").run()
                }
                try await sql.raw("""
                    CREATE FUNCTION im_v2.test_retry_receipt_finalize() RETURNS trigger LANGUAGE plpgsql AS $$
                    BEGIN
                        IF NEW.state = 'completed' AND EXISTS (
                            SELECT 1 FROM im_v2.test_retry_receipt_failure f WHERE f.operation_id = NEW.operation_id
                        ) THEN
                            RAISE EXCEPTION 'injected receipt completion failure' USING ERRCODE = '08006';
                        END IF;
                        RETURN NEW;
                    END $$
                    """).run()
                try await sql.raw("CREATE TRIGGER test_retry_receipt_finalize BEFORE UPDATE ON im_v2.read_receipt_preference_propagation_outbox FOR EACH ROW EXECUTE FUNCTION im_v2.test_retry_receipt_finalize()").run()
            }
            let table = path == "profile" ? "public_profile_update_outbox" : "read_receipt_preference_propagation_outbox"
            let key = path == "profile" ? "source_event_id" : "operation_id"
            try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET retry_count = CASE WHEN \(unsafeRaw: key) = \(bind: primary) THEN \(bind: starting) ELSE 0 END").run()
            if expired { try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET state = 'claimed', claim_token = \(bind: UUID()), lease_expires_at = \(bind: now)").run() }
            let event = path == "profile" ? primary : receiptTombstoneSourceEventID(operationID: primary, roomID: primaryRoom)
            actor Shadow: V2UserShardProjectionShadowing {
                let event: UUID
                var fails: Bool
                init(event: UUID, fails: Bool) { self.event = event; self.fails = fails }
                func shadowIfForwarding(userID: UserID, sourceEventID: EventID, projectionKinds: Set<String>) async throws -> UInt64? {
                    fails && sourceEventID.uuidValue == event ? nil : 1
                }
                func recover() { fails = false }
            }
            let shadow = Shadow(event: event, fails: fails)
            let clock = TestSequenceClock([now])
            let profileWorker = V2DirectRoomProfilePropagationWorker(database: database, shadowForwarder: shadow, now: { clock.now() })
            let receiptWorker = V2ReadReceiptPreferencePropagationWorker(database: database, retryPolicy: .init(initialDelay: 2, maximumDelay: 2, maximumAttempts: 10, jitterFraction: 0), now: { clock.now() })
            // 瞬时失败不再因预算耗尽而暂停，因此失败路径只释放重试；
            // 下面的 replay 覆盖改为显式构造暂停行。
            let pauses = false
            if path == "profile" {
                if fails {
                    await #expect(throws: V2DirectRoomProfilePropagationError.missingControlProjection) { try await profileWorker.runOnce(limit: 2) }
                } else {
                    #expect(try await profileWorker.runOnce(limit: 2) == .init(claimedUpdateCount: 2, projectedRecipientCount: 2, completedUpdateCount: 2))
                }
            } else {
                #expect(try await receiptWorker.runOnce(limit: 2) == .init(claimedOperationCount: 2,
                    projectedRoomCount: 2, completedOperationCount: fails ? 1 : 2,
                    releasedOperationCount: fails && !pauses ? 1 : 0, pausedOperationCount: pauses ? 1 : 0))
                let expected = fails ? (starting == Int64.max ? Int64.max : starting + 1) : starting
                #expect(try await sql.raw("SELECT retry_count AS value FROM im_v2.read_receipt_preference_propagation_outbox WHERE operation_id = \(bind: primary)").first(decoding: CountRow.self)?.value == expected)
            }
            func primaryEffects() async throws -> String {
                if path == "receipt" {
                    return try #require(try await sql.raw("SELECT jsonb_agg(to_jsonb(e) ORDER BY user_id, projection_kind)::text AS value FROM im_v2.user_state_event_outbox e WHERE source_event_id = \(bind: event) AND projection_kind = 'direct_read_receipt'").first(decoding: StringValueRow.self)).value
                }
                let row = try await sql.raw("SELECT jsonb_agg(to_jsonb(e) ORDER BY user_id, projection_kind)::text AS value FROM im_v2.user_projection_effects e WHERE source_event_id = \(bind: event) AND projection_kind IN ('direct_room_profile', 'profile_invalidation', 'direct_read_receipt')").first(decoding: StringValueRow.self)
                return try #require(row).value
            }
            let firstEffects = try await primaryEffects()
            let effectsTable = path == "receipt" ? "user_state_event_outbox" : "user_projection_effects"
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: effectsTable) WHERE source_event_id = \(bind: event) AND projection_kind IN ('direct_room_profile', 'profile_invalidation', 'direct_read_receipt')").first(decoding: CountRow.self)?.value == 2)
            if path == "receipt" {
                #expect(try await count("im_v2.user_sync_log WHERE projection_kind = 'direct_read_receipt'", on: sql) == 0)
                try await sql.raw("DELETE FROM im_v2.test_retry_receipt_failure").run()
            }
            await shadow.recover()
            if fails {
                clock.set([now.addingTimeInterval(1)])
                if path == "profile" {
                    // The failed lease still owns the first update; the other
                    // update can finish before that lease becomes reclaimable.
                    #expect(try await profileWorker.runOnce(limit: 2) == .init(claimedUpdateCount: 1, projectedRecipientCount: 1, completedUpdateCount: 1))
                } else {
                    #expect(try await receiptWorker.runOnce(limit: 2).claimedOperationCount == 0)
                    if fails {
                        // 新契约下暂停只来自确定性失败；这里显式构造暂停行，
                        // 以便仍然覆盖 operator replay 的恢复路径。
                        try await sql.raw("""
                            UPDATE im_v2.read_receipt_preference_propagation_outbox
                            SET state = 'paused', paused_at = \(bind: now), next_attempt_at = NULL,
                                claim_token = NULL, lease_expires_at = NULL
                            WHERE operation_id = \(bind: primary)
                            """).run()
                        let command = V2DurableWorkReplayCommand(operationID: UUID(), target: try .init(kind: .readReceiptPreferencePropagation, sourceEventID: .init(uuid: primary), targetUserID: senderID), reason: .dependencyRecovered)
                        let replay = try await PostgresV2DurableWorkReplayStore(database: database).replay(command, operatorPrincipal: "integration-test", now: now.addingTimeInterval(2))
                        #expect(replay.outcome == .requeued)
                    }
                }
                clock.set([now.addingTimeInterval(30)])
                if path == "profile" {
                    #expect(try await profileWorker.runOnce(limit: 2) == .init(claimedUpdateCount: 1, projectedRecipientCount: 1, completedUpdateCount: 1))
                } else {
                    #expect(try await receiptWorker.runOnce(limit: 2) == .init(claimedOperationCount: 1, projectedRoomCount: 1, completedOperationCount: 1))
                }
            }
            #expect(try await primaryEffects() == firstEffects)
            #expect(try await count("im_v2.\(table) WHERE state = 'completed' AND claim_token IS NULL AND lease_expires_at IS NULL", on: sql) == 2)
            if path == "profile" {
                let increments: Int64 = (expired ? 1 : 0) + (fails ? 1 : 0)
                let expected = starting > Int64.max - increments ? Int64.max : starting + increments
                #expect(try await sql.raw("SELECT retry_count AS value FROM im_v2.public_profile_update_outbox WHERE source_event_id = \(bind: primary)").first(decoding: CountRow.self)?.value == expected)
                #expect(try await profileWorker.runOnce(limit: 2).claimedUpdateCount == 0)
            } else { #expect(try await receiptWorker.runOnce(limit: 2).claimedOperationCount == 0) }
            if path == "receipt" {
                struct Fence: V2UserShardRouteFencing {
                    let database: any Database
                    func withCurrentRoute<Result: Sendable>(for userID: UserID,
                        _ operation: @escaping @Sendable (V2UserShardRoute, any Database) async throws -> Result) async throws -> Result {
                        try await database.transaction { transaction in
                            try await operation(.init(bucket: "user", observedRouterEpoch: 1), transaction)
                        }
                    }
                }
                let outbox = try PostgresV2UserStateEventOutbox(database: database)
                let projector = try V2RoutedUserStateEventProjector(routeFence: Fence(database: database),
                    registry: V2StaticUserShardStorageRegistry(locations: [.init(bucket: "user", database: userDatabase, schema: "im_v2")]))
                let deliveryTime = now.addingTimeInterval(31)
                let leases = try await outbox.claim(now: deliveryTime, leaseDuration: 30, limit: 100)
                let candidates = leases.filter { $0.event.kind == .directReadReceipt }
                #expect(candidates.count == 4)
                for lease in candidates {
                    let sequence = try await projector.project(lease.event)
                    #expect(try await projector.project(lease.event) == sequence)
                    #expect(try await outbox.acknowledge(lease, sequence: sequence, now: deliveryTime))
                }
                #expect(try await count("im_v2.user_sync_log WHERE projection_kind = 'direct_read_receipt'", on: userSQL) == 4)
                #expect(try await count("im_v2.user_sync_log WHERE projection_kind = 'direct_read_receipt' AND (payload->>'is_visible')::boolean = false AND (payload->>'read_through_room_sequence')::bigint = 0", on: userSQL) == 4)
                #expect(try await count("im_v2.user_state_event_outbox WHERE projection_kind = 'direct_read_receipt' AND state = 'delivered'", on: sql) == 4)
            }
        }
    }

    @Test("Invite response states and existing-member submissions agree with the persisted expiry",
          arguments: ["active", "exhausted", "revoked"], 0..<6)
    func inviteResponseExpiryPrecision(state: String, boundary: Int) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let epoch = Date(timeIntervalSince1970: 946_684_800)
            let offsets: [Double] = [0.000001, -0.00000125, -0.000001, 0.00000125, 0.00000225, -0.00000225]
            let deadlines: [Double] = [0.00000125, -0.00000125, 0.00000125, 0.00000125, 0.00000125, -0.00000125]
            let expires = epoch.addingTimeInterval(deadlines[boundary])
            let base = expires.addingTimeInterval(-300), now = epoch.addingTimeInterval(offsets[boundary])
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            let store = PostgresV2GroupInvitationStore(database: database)
            let request = V2GroupInviteCreatePersistenceRequest(inviteID: .init(uuid: UUID()), roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), tokenDigest: Data(repeating: 0x61, count: 32), requestedLifetimeSeconds: 300, expiresAt: expires, maximumApprovedUses: 1, maximumActiveInvitesPerRoom: 20, createdAt: base)
            #expect(try await store.create(request).state == .active)
            if state == "revoked" { try await store.revoke(inviteID: request.inviteID, roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), now: base.addingTimeInterval(1)) }
            if state == "exhausted" { try await sql.raw("UPDATE im_v2.group_invite_links SET approved_use_count = maximum_approved_uses").run() }
            let live = try #require(try await sql.raw("SELECT expires_at > \(bind: now) AS exists FROM im_v2.group_invite_links").first(decoding: ExistsRow.self)).exists
            let expected: V2GroupInviteState = state == "revoked" ? .revoked : !live ? .expired : state == "exhausted" ? .exhausted : .active
            let before = try #require(try await sql.raw("SELECT to_jsonb(i)::text AS value FROM im_v2.group_invite_links i").first(decoding: StringValueRow.self)).value
            let replay = try await store.create(request.evaluated(at: now))
            #expect(replay.state == expected)
            #expect(try await store.preflightCreation(request.evaluated(at: now)) == replay)
            let list = try await store.activeInvites(roomID: roomID, actorUserID: senderID, now: now)
            #expect(list.count == (live && state == "active" ? 1 : 0))
            #expect(list.allSatisfy { $0.state == .active })
            // An existing fixture member exercises normal submission response
            // mapping without adding a member or changing invitation capacity.
            let submitted = try await store.submit(.init(requestID: .init(uuid: UUID()), applicantUserID: .init(uuid: memberTwoUUID), operationID: .init(uuid: UUID()), tokenDigest: request.tokenDigest, note: nil, createdAt: now, maximumPendingRequestsPerApplicant: 20, maximumPendingRequestsPerInvite: 100))
            if live && state == "active" {
                guard case .alreadyMember(let preview) = submitted else { Issue.record("Expected existing-member response for the live invite"); return }
                #expect(preview.inviteID == request.inviteID && preview.isAlreadyMember)
                #expect(preview.expiresAt == replay.expiresAt)
            } else { #expect(submitted == .unavailable) }
            if state == "revoked" {
                for time in [Double.nan, .infinity] {
                    #expect(try await store.create(request.evaluated(at: Date(timeIntervalSince1970: time))) == replay)
                    #expect(try await store.preflightCreation(request.evaluated(at: Date(timeIntervalSince1970: time))) == replay)
                }
            }
            #expect(try await sql.raw("SELECT to_jsonb(i)::text AS value FROM im_v2.group_invite_links i").first(decoding: StringValueRow.self)?.value == before)
            #expect(try await count("im_v2.group_join_requests", on: sql) == 0)
            #expect(try await count("im_v2.room_memberships", on: sql) == 3)
        }
    }

    @Test("Invite creation rejects deadlines that have already elapsed at database precision", arguments: 0..<6)
    func inviteCreationExpiryPrecision(boundary: Int) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let epoch = Date(timeIntervalSince1970: 946_684_800)
            let offsets: [Double] = [0.000001, -0.0000015, -0.000001, 0.00000125, 0.00000225, -0.00000225]
            let deadlines: [Double] = [0.00000125, -0.00000125, 0.00000125, 0.00000125, 0.00000125, -0.00000125]
            let expires = epoch.addingTimeInterval(deadlines[boundary])
            let base = expires.addingTimeInterval(-300), now = epoch.addingTimeInterval(offsets[boundary])
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            let store = PostgresV2GroupInvitationStore(database: database)
            let request = V2GroupInviteCreatePersistenceRequest(inviteID: .init(uuid: UUID()), roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), tokenDigest: Data(repeating: 0x62, count: 32), requestedLifetimeSeconds: 300, expiresAt: expires, maximumApprovedUses: 1, maximumActiveInvitesPerRoom: 20, createdAt: base, evaluatedAt: now)
            let live = try #require(try await sql.raw("SELECT \(bind: expires)::timestamptz > \(bind: now)::timestamptz AS exists").first(decoding: ExistsRow.self)).exists
            if live {
                #expect(try await store.preflightCreation(request) == nil)
                let created = try await store.create(request)
                #expect(created.state == .active)
                #expect(try await store.activeInvites(roomID: roomID, actorUserID: senderID, now: now) == [created])
                #expect(try await store.create(request) == created)
            } else {
                for _ in 0..<2 {
                    await #expect(throws: V2GroupInvitationServiceError.creationExpired) { try await store.preflightCreation(request) }
                    await #expect(throws: V2GroupInvitationServiceError.creationExpired) { try await store.create(request) }
                    #expect(try await count("im_v2.group_invite_links", on: sql) == 0)
                }
                // A corrected attempt clock can still commit the original operation.
                #expect(try await store.preflightCreation(request.evaluated(at: base)) == nil)
                #expect(try await store.create(request.evaluated(at: base)).state == .active)
            }
            #expect(try await count("im_v2.group_invite_links", on: sql) == 1)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_links WHERE expires_at = \(bind: expires) AND created_at = \(bind: base)").first(decoding: CountRow.self)?.value == 1)
        }
    }

    @Test("Forward media deadlines agree with PostgreSQL precision across export and import transitions",
          arguments: ["export", "claim", "retry-due", "copy", "complete", "reject", "retry"], 0..<6)
    func forwardMediaDeadlinePrecision(path: String, boundary: Int) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { sourceDB, targetDB, sourceSQL, targetSQL, targetRoom in
            let epoch = Date(timeIntervalSince1970: 946_684_800)
            let base = epoch.addingTimeInterval(-10)
            let offsets: [Double] = [0.000001, -0.00000125, -0.000001, 0.00000125, 0.00000225, -0.00000225]
            let deadlineMicros: [Int64] = [1, -1, 1, 1, 1, -1]
            let now = epoch.addingTimeInterval(offsets[boundary])
            let deadline = deadlineMicros[boundary]
            let media = MediaID(uuid: UUID())
            try await sourceSQL.raw("INSERT INTO im_v2.media_objects (media_id, owner_user_id, content_type, byte_count, state, upload_session_id, expires_at, state_updated_at, created_at) VALUES (\(bind: media.uuidValue!), \(bind: senderUUID), 'text/plain', 42, 'available', \(bind: UUID()), \(bind: base.addingTimeInterval(600)), \(bind: base), \(bind: base))").run()
            let profile = try forwardImportTestProfile(), limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let sender = V2SendMessageService(store: PostgresV2RoomWriteStore(database: sourceDB), capacityProfile: profile, limits: limits, now: { base })
            guard case .accepted(let message) = try await sender.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "forward deadline", media: [.init(mediaID: media)])) else { throw CancellationError() }
            let exporter = PostgresV2ForwardExportStore(database: sourceDB)
            let operation = MessageForwardOperationID(uuid: UUID())
            func prepare(_ time: Date) async throws -> V2ForwardExport {
                try await exporter.prepare(actorUserID: .init(uuid: memberTwoUUID), operationID: operation,
                    source: .init(roomID: roomID, messageID: message.messageID, revision: .init(1)),
                    sourceRoute: .init(shardID: "room-a", epoch: 0), targetRoomID: targetRoom,
                    targetRoute: .init(shardID: "room-b", epoch: 0), now: time)
            }
            let live = try #require(try await sourceSQL.raw("SELECT (\(bind: epoch)::timestamptz + \(bind: deadline) * INTERVAL '1 microsecond') > \(bind: now) AS exists").first(decoding: ExistsRow.self)).exists
            if path == "export" {
                try await sourceSQL.raw("UPDATE im_v2.media_objects SET expires_at = \(bind: epoch)::timestamptz + \(bind: deadline) * INTERVAL '1 microsecond'").run()
                if live {
                    let export = try await prepare(now)
                    #expect(export.intent.media.map(\.mediaID) == [media.uuidValue!])
                    for invalid in [Double.nan, .infinity] { #expect(try await prepare(Date(timeIntervalSince1970: invalid)) == export) }
                } else {
                    await #expect(throws: V2ForwardExportError.mediaUnavailable) { try await prepare(now) }
                }
                #expect(try await count("im_v2.message_forward_exports", on: sourceSQL) == (live ? 1 : 0))
                #expect(try await count("im_v2.message_forward_delivery_jobs", on: sourceSQL) == (live ? 1 : 0))
                #expect(try await count("im_v2.media_objects WHERE state = 'available'", on: sourceSQL) == 1)
                #expect(try await sourceSQL.raw("SELECT COUNT(*) AS value FROM im_v2.media_objects WHERE expires_at = \(bind: epoch)::timestamptz + \(bind: deadline) * INTERVAL '1 microsecond'").first(decoding: CountRow.self)?.value == 1)
                return
            }
            let export = try await prepare(base)
            let inbox = PostgresV2ForwardInboxStore(database: targetDB)
            try await inbox.receive(export, now: base)
            let importer = try PostgresV2ForwardMediaImportStore(database: targetDB, temporaryLifetime: 600)
            let old = try #require(try await importer.claim(exportID: export.intent.exportID, now: base, leaseDuration: 30))
            // A deterministic receipt isolates database state transitions from provider I/O.
            let receipt = try V2ForwardMediaCopyReceipt(byteCount: 42, digest: Data(repeating: 7, count: 32))
            #expect(try await importer.recordCopied(old, receipt: receipt, now: base))
            if path == "retry-due" {
                #expect(try await importer.retry(old, disposition: .retry(at: epoch), now: base))
                try await targetSQL.raw("UPDATE im_v2.message_forward_media_imports SET next_attempt_at = \(bind: epoch)::timestamptz + \(bind: deadline) * INTERVAL '1 microsecond'").run()
            } else {
                try await targetSQL.raw("UPDATE im_v2.message_forward_media_imports SET lease_expires_at = \(bind: epoch)::timestamptz + \(bind: deadline) * INTERVAL '1 microsecond'").run()
            }
            func snapshot() async throws -> String {
                let row = try await targetSQL.raw("""
                    SELECT jsonb_build_object(
                        'inbox', (SELECT jsonb_agg(to_jsonb(r) ORDER BY export_id) FROM im_v2.message_forward_inbox r),
                        'bindings', (SELECT jsonb_agg(to_jsonb(r) ORDER BY export_id, ordinal) FROM im_v2.message_forward_inbox_media r),
                        'imports', (SELECT jsonb_agg(to_jsonb(r) ORDER BY export_id, ordinal) FROM im_v2.message_forward_media_imports r),
                        'media', (SELECT jsonb_agg(to_jsonb(r) ORDER BY media_id) FROM im_v2.media_objects r)
                    )::text AS value
                    """).first(decoding: StringValueRow.self)
                return try #require(row).value
            }
            let before = try await snapshot()
            var replacement: V2ForwardMediaImportLease?
            var completed = false
            if path == "claim" || path == "retry-due" {
                replacement = try await importer.claim(exportID: export.intent.exportID, now: now, leaseDuration: 30)
                #expect((replacement != nil) == !live)
                if live { #expect(try await snapshot() == before) }
            } else {
                let applied: Bool
                switch path {
                case "copy": applied = try await importer.recordCopied(old, receipt: receipt, now: now)
                case "complete": applied = try await importer.complete(old, receipt: receipt, result: .passed, now: now)
                case "reject": applied = try await importer.reject(old, now: now)
                default: applied = try await importer.retry(old, disposition: .retry(at: now), now: now)
                }
                #expect(applied == live)
                if !live { #expect(try await snapshot() == before) }
                if live && path == "reject" {
                    #expect(try await inbox.status(exportID: export.intent.exportID) == .rejected(code: "MEDIA_UNAVAILABLE"))
                    #expect(try await count("im_v2.media_objects WHERE state = 'failed'", on: targetSQL) == 1)
                    #expect(try await count("im_v2.messages", on: targetSQL) == 0)
                    return
                }
                completed = live && path == "complete"
            }
            let recoveredAt = now.addingTimeInterval(1)
            if !completed {
                if replacement == nil { replacement = try await importer.claim(exportID: export.intent.exportID, now: recoveredAt, leaseDuration: 30) }
                let lease = try #require(replacement)
                #expect(lease.targetMediaID == old.targetMediaID && lease.targetUploadSessionID == old.targetUploadSessionID)
                #expect(lease.claimToken != old.claimToken && lease.attempt == 2)
                let held = try await snapshot()
                #expect(try await importer.recordCopied(old, receipt: receipt, now: recoveredAt) == false)
                #expect(try await importer.complete(old, receipt: receipt, result: .passed, now: recoveredAt) == false)
                #expect(try await snapshot() == held)
                #expect(try await importer.recordCopied(lease, receipt: receipt, now: recoveredAt))
                #expect(try await importer.complete(lease, receipt: receipt, result: .passed, now: recoveredAt))
            }
            #expect(try await count("im_v2.message_forward_media_imports WHERE state = 'ready' AND claim_token IS NULL AND lease_expires_at IS NULL", on: targetSQL) == 1)
            #expect(try await count("im_v2.media_objects WHERE state = 'available'", on: targetSQL) == 1)
            let ready = try await snapshot()
            #expect(try await importer.complete(old, receipt: receipt, result: .passed, now: Date(timeIntervalSince1970: .nan)) == false)
            #expect(try await snapshot() == ready)
            let accepted = try await PostgresV2RoomWriteStore(database: targetDB).importForwardExport(export, capacityProfile: profile, limits: limits, identifiers: V2AcceptanceIDFactory().make(at: recoveredAt), now: recoveredAt)
            guard case .accepted = accepted else { throw CancellationError() }
            #expect(try await count("im_v2.messages", on: targetSQL) == 1)
            #expect(try await count("im_v2.message_media_references", on: targetSQL) == 1)
        }
    }

}

private struct MentionWakeAssertionRow: Decodable {
    let targetDeviceID: UUID
    let targetUserID: UUID
    let campaignID: String
    let state: String
    enum CodingKeys: String, CodingKey {
        case targetDeviceID = "target_device_id", targetUserID = "target_user_id"
        case campaignID = "campaign_id", state
    }
}
