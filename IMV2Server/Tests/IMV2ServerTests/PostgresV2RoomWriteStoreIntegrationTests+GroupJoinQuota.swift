import Crypto
import FluentKit
import FluentPostgresDriver
import Foundation
import HTTPTypes
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

#if os(macOS)
import Darwin
internal final class GroupJoinQuotaCrashBundleMarker: NSObject {}
#endif

extension PostgresV2RoomWriteStoreIntegrationTests {
    #if os(macOS)
    @Test("SIGKILL at distributed submission checkpoints preserves quota and resumes exact receipts",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1" && ProcessInfo.processInfo.environment["IMV2_JOIN_QUOTA_CRASH_STAGE"] == nil),
          arguments: ["reserved", "owner", "confirmed", "terminal", "approved", "rejected"])
    func groupJoinQuotaKilledRecovery(_ stage: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, sql, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000), applicant = UserID(uuid: UUID()), inviteID = GroupInviteID(uuid: UUID())
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            try await sql.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at) VALUES (\(bind: applicant.uuidValue!), 'crash_quota', 'Applicant', \(bind: now), \(bind: now))").run()
            // Production path: the control coordinator with a room turn on the owner.
            let clock = TestSequenceClock([now])
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 35, count: 32))
            let coordinator = V2ActorInvitationCoordinator(controlDatabase: control,
                room: invitationRoomPort(control: control, owner: owner, shardID: "room-b", capacityProfile: profile, now: { clock.now() }),
                secretIssuer: issuer, policy: try V2GroupInvitationPolicy(maximumPendingRequestsPerApplicant: 1, maximumPendingRequestsPerInvite: 1),
                makeUUID: { inviteID.uuidValue! }, now: { clock.now() })
            let requestID = GroupJoinRequestID(uuid: UUID()), operation = GroupJoinRequestOperationID(uuid: UUID())
            guard case .created(let link) = try await coordinator.create(.init(roomID: room, actorUserID: senderID, operationID: .init(uuid: UUID()),
                lifetime: 3600, maximumApprovedUses: 10), deadline: invitationTestDeadline()) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            let digest = issuer.digest(try link.secret.toDomain())
            let process = Process(), host = URL(fileURLWithPath: CommandLine.arguments[0])
            let binary = try #require(Bundle(for: GroupJoinQuotaCrashBundleMarker.self).executableURL)
            try #require(host.lastPathComponent == "swiftpm-testing-helper")
            process.executableURL = host
            process.arguments = ["--test-bundle-path", binary.path, binary.path, "--testing-library", "swift-testing", "--filter", "groupJoinQuotaCrashChild"]
            var environment = ProcessInfo.processInfo.environment
            environment["IMV2_JOIN_QUOTA_CRASH_STAGE"] = stage
            let fields = ["room": room.rawValue, "invite": inviteID.rawValue, "applicant": applicant.rawValue, "request": requestID.rawValue,
                          "operation": operation.rawValue, "digest": digest.base64EncodedString()]
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
            clock.set([now.addingTimeInterval(61)])
            let worker = V2GroupJoinQuotaRecoveryWorker(controlDatabase: control, coordinator: coordinator,
                deadline: invitationTestDeadline, now: { now.addingTimeInterval(61) })
            let report = try await worker.runOnce(limit: 8)
            #expect(report.attempted == 1 && report.reconciled == 1 && report.deferred == 0)
            #expect(try await worker.runOnce(limit: 8).attempted == 0)
            #expect(try await count("im_v2.group_join_requests", on: ownerSQL) == 1)
            #expect(try await count("im_v2.group_join_submission_receipts", on: ownerSQL) == 1)
            #expect(try await count("im_v2.group_join_quota_intents WHERE phase IN ('held','tracking')", on: sql) == (["terminal", "approved", "rejected"].contains(stage) ? 0 : 1))
            // Retrying the same operation replays its settled outcome, including
            // terminal intents that must cross the actor wire.
            clock.set([now.addingTimeInterval(62)])
            guard case .submission(let replay) = try await coordinator.submitBySecret(.init(applicantUserID: applicant, operationID: operation,
                secret: link.secret, note: nil), deadline: invitationTestDeadline()) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
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
            let encodedDigest = try #require(fields["digest"])
            let digest = try #require(Data(base64Encoded: encodedDigest))
            let request = V2GroupJoinSubmissionPersistenceRequest(requestID: requestID, applicantUserID: applicant, operationID: operation, tokenDigest: digest, note: nil, createdAt: now, maximumPendingRequestsPerApplicant: 1, maximumPendingRequestsPerInvite: 1)
            guard case .reserved(let intent) = try await quota.reserve(request, roomID: room, inviteID: invite, now: now) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            if stage != "reserved" {
                // The owner half runs as the room actor executes it; the process
                // then dies before the control side finishes its bookkeeping.
                let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
                let port = invitationRoomPort(control: control, owner: owner, shardID: "room-b", capacityProfile: profile, now: { now })
                guard case .reservedSubmission(let applied) = try await port.command(.submitReserved(.init(domain: intent)), invitationTestDeadline()) else {
                    throw V2GroupInvitationServiceError.corruptPersistenceState
                }
                let receipt = try applied.toDomain()
                if ["confirmed", "terminal", "approved", "rejected"].contains(stage) {
                    try await quota.resolve(intent, outcome: receipt.outcome, targetRequestID: receipt.targetRequestID, now: now)
                }
                if stage == "terminal" {
                    guard case .cancelledRecord = try await port.command(.cancel(.init(roomID: room, requestID: requestID, applicantUserID: applicant)), invitationTestDeadline()) else {
                        throw V2GroupInvitationServiceError.corruptPersistenceState
                    }
                }
                if stage == "approved" {
                    guard case .approval(.approved) = try await port.command(.decide(.init(roomID: room, requestID: requestID, reviewerUserID: senderID,
                        operationID: .init(uuid: UUID()), decision: .approve)), invitationTestDeadline()) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                } else if stage == "rejected" {
                    guard case .rejection(.rejected) = try await port.command(.decide(.init(roomID: room, requestID: requestID, reviewerUserID: senderID,
                        operationID: .init(uuid: UUID()), decision: .reject)), invitationTestDeadline()) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
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
}
