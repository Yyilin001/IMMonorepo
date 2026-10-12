@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
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
@testable import IMV2ServerInfrastructure
import SQLKit
import Synchronization
import Testing
import Vapor
import VaporTesting

#if os(macOS)
import Darwin
internal final class GroupJoinQuotaCrashBundleMarker: NSObject {}
private enum GroupJoinQuotaChildLifecycleError: Error { case exitTimedOut, cleanupTimedOut }
#endif

extension PostgresV2RoomWriteStoreIntegrationTests {
    #if os(macOS)
    @Test("SIGKILL at distributed submission checkpoints preserves quota and resumes exact receipts",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1" && ProcessInfo.processInfo.environment["IMV2_JOIN_QUOTA_CRASH_STAGE"] == nil),
          arguments: ["reserved", "owner", "confirmed", "terminal", "approved", "rejected"])
    func groupJoinQuotaKilledRecovery(_ stage: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, sql, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000), applicant = UserID(uuid: UUID())
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            try await sql.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at) VALUES (\(bind: applicant.uuidValue!), 'crash_quota', 'Applicant', \(bind: now), \(bind: now))").run()
            // Production path: the control coordinator with a room turn on the owner.
            let clock = TestSequenceClock([now])
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let policy = try V2GroupInvitationPolicy(maximumPendingRequestsPerApplicant: 1, maximumPendingRequestsPerInvite: 1)
            let fixture = try QuotaInvitationFixture(control: control, owner: { _ in (owner, "room-b", 0) },
                profile: profile, policy: policy, now: now, clock: { clock.now() })
            let coordinator = fixture.coordinator
            let link = try await fixture.create(room: room, actor: senderID)
            let requestID = GroupJoinRequestID(uuid: UUID())
            let submission = try await fixture.submission(room: room, actor: applicant, invite: link.id, secret: link.secret)
            let operation = try GroupJoinRequestOperationID(submission.command.identity.operation.rawOperationID)
            try await PostgresV2GroupInvitationControlCommandStore(database: control).save(submission.command)
            let digest = fixture.issuer.digest(link.secret)
            let process = Process(), host = URL(fileURLWithPath: CommandLine.arguments[0])
            let binary = try #require(Bundle(for: GroupJoinQuotaCrashBundleMarker.self).executableURL)
            try #require(host.lastPathComponent == "swiftpm-testing-helper")
            process.executableURL = host
            process.arguments = ["--test-bundle-path", binary.path, binary.path, "--testing-library", "swift-testing", "--filter", "groupJoinQuotaCrashChild"]
            var environment = ProcessInfo.processInfo.environment
            environment["IMV2_JOIN_QUOTA_CRASH_STAGE"] = stage
            let fields = ["room": room.rawValue, "invite": link.id.rawValue, "applicant": applicant.rawValue, "request": requestID.rawValue,
                          "operation": operation.rawValue, "digest": digest.base64EncodedString(),
                          "command": try JSONEncoder().encode(submission.command).base64EncodedString()]
            environment["IMV2_JOIN_QUOTA_CRASH_INPUT"] = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            // Do not suspend solely on Foundation's termination callback: if
            // that notification is lost, the already-dead child cannot resume it.
            try process.run()
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                while process.isRunning {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else { throw GroupJoinQuotaChildLifecycleError.exitTimedOut }
                    try await Task.sleep(for: .milliseconds(10))
                }
            } catch {
                // A fixture timeout/cancellation must not leave a helper writing
                // into schemas which the enclosing fixture is about to remove.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                while process.isRunning && ContinuousClock.now < cleanupDeadline {
                    // Cleanup remains bounded even when the test task is cancelled.
                    await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
                }
                guard !process.isRunning else { throw GroupJoinQuotaChildLifecycleError.cleanupTimedOut }
                throw error
            }
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
            let replay = try await coordinator.recoverOperation(.init(intent: submission.command.intent, action: .query), deadline: invitationTestDeadline())
            guard case .receipt(let proof) = replay else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            #expect(proof.validates(intent: submission.command.intent))
            #expect(try fixture.requestID(proof) == requestID)
            let expected = stage == "terminal" ? "cancelled" : stage == "approved" ? "approved" : stage == "rejected" ? "rejected" : "pending"
            #expect(try await count("im_v2.group_join_requests WHERE state = '\(expected)'", on: ownerSQL) == 1)

        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_JOIN_QUOTA_CRASH_STAGE"] != nil))
    func groupJoinQuotaCrashChild() async throws {
        let stage = try #require(ProcessInfo.processInfo.environment["IMV2_JOIN_QUOTA_CRASH_STAGE"])
        let raw = try #require(ProcessInfo.processInfo.environment["IMV2_JOIN_QUOTA_CRASH_INPUT"])
        let fields = try JSONDecoder().decode([String: String].self, from: Data(raw.utf8))
        let resources = makeV2DatabaseTestResources()
        do {
            let controlURL = try #require(ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"]), ownerURL = try #require(ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"])
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
                let fixture = try QuotaInvitationFixture(control: control, owner: { _ in (owner, "room-b", 0) },
                    profile: profile, policy: try .init(maximumPendingRequestsPerApplicant: 1, maximumPendingRequestsPerInvite: 1), now: now)
                let encodedCommand = try #require(fields["command"])
                let data = try #require(Data(base64Encoded: encodedCommand))
                let command = try JSONDecoder().decode(V2GroupInvitationOperationCommand.self, from: data)
                guard case .receipt(let proof) = try await fixture.operations.submit(.init(command: command, quotaIntent: .init(domain: intent)), invitationTestDeadline()),
                      proof.validates(intent: command.intent), try fixture.requestID(proof) == requestID else {
                    throw V2GroupInvitationServiceError.corruptPersistenceState
                }
                if ["confirmed", "terminal", "approved", "rejected"].contains(stage) {
                    _ = try await quota.resolve(intent, outcome: .pending, targetRequestID: requestID.uuidValue!, now: now)
                }
                // Execute only the owner half; SIGKILL interrupts control quota release.
                let terminal: V2GroupInvitationSubmission?
                if stage == "terminal" { terminal = try await fixture.cancel(room: room, actor: applicant, request: requestID) }
                else if stage == "approved" || stage == "rejected" {
                    terminal = try await fixture.decision(room: room, actor: senderID, request: requestID, decision: stage == "approved" ? .approve : .reject)
                } else { terminal = nil }
                if let terminal {
                    guard case .receipt(let proof) = try await fixture.operations.submit(.init(command: terminal.command), invitationTestDeadline()),
                          proof.validates(intent: terminal.command.intent) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
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
        try await withForwardOwnerDatabases(mode: .standard) { ownerA, secondOwner, sql, secondSQL, secondRoom in
            let controlResources = makeV2DatabaseTestResources()
            do {
                let primaryURL = try #require(ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"])
                // Owner transactions may read control identity while holding a room lock.
                // Control work must not compete for those same owner connections.
                controlResources.databases.use(try .postgres(url: primaryURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
                let control = controlResources.database(.psql)
                let now = Date(timeIntervalSince1970: 1_750_000_000), applicant = UserID(uuid: UUID())
                for db in [sql, secondSQL] { try await db.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run() }
                try await sql.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at) VALUES (\(bind: applicant.uuidValue!), 'global_applicant', 'Applicant', \(bind: now), \(bind: now))").run()
                let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
                let fixture = try QuotaInvitationFixture(control: control, owner: { $0 == roomID ? (ownerA, "room-a", 0) : (secondOwner, "room-b", 0) }, profile: profile, now: now)
                var submissions: [V2GroupInvitationSubmission] = []
                var links: [(id: GroupInviteID, secret: V2GroupInviteSecret)] = []
                for index in 0..<40 {
                    let room = index.isMultiple(of: 2) ? roomID : secondRoom
                    let link = try await fixture.create(room: room, actor: senderID); links.append(link)
                    submissions.append(try await fixture.submission(room: room, actor: applicant, invite: link.id, secret: link.secret))
                }
                let seeded = [(0, try await fixture.execute(submissions[0])), (1, try await fixture.execute(submissions[1]))]
                let concurrent = try await withThrowingTaskGroup(of: (Int, V2GroupInvitationOperationRecoveryResult).self) { group in
                    for (index, input) in submissions.enumerated().dropFirst(2) { group.addTask { (index, try await fixture.execute(input)) } }
                    var results: [(Int, V2GroupInvitationOperationRecoveryResult)] = []
                    for try await result in group { results.append(result) }; return results
                }
                let outcomes = seeded + concurrent
                let accepted = try outcomes.compactMap { index, value -> (Int, GroupJoinRequestID)? in
                    guard case .receipt(let proof) = value else { return nil }; return (index, try fixture.requestID(proof))
                }
                let limited = outcomes.filter { if case .deferred(let hint) = $0.1 { return hint.reason == .rateLimited }; return false }
                #expect(accepted.count == 20 && limited.count == 20)
                let localCount = try await count("im_v2.group_join_requests", on: sql)
                let remoteCount = try await count("im_v2.group_join_requests", on: secondSQL)
                #expect(localCount > 0 && remoteCount > 0 && localCount + remoteCount == 20)
                #expect(try await count("im_v2.group_join_quota_intents WHERE phase = 'tracking'", on: sql) == 20)
                let first = try #require(accepted.first), refused = try #require(limited.first)
                let original = try await fixture.proof(submissions[first.0])
                let firstRoom = submissions[first.0].command.intent.roomID
                let duplicate = try await fixture.submission(room: firstRoom, actor: applicant,
                    invite: links[first.0].id, secret: links[first.0].secret, note: "duplicate operation")
                let duplicateProof = try await fixture.proof(duplicate)
                #expect(try fixture.requestID(duplicateProof) == first.1)
                _ = try await fixture.proof(fixture.cancel(room: firstRoom, actor: applicant, request: first.1))
                #expect(try await fixture.proof(submissions[first.0]) == original)
                #expect(try await fixture.proof(duplicate) == duplicateProof)
                _ = try await fixture.proof(submissions[refused.0])
                let rejected = accepted[1], approved = accepted[2]
                _ = try await fixture.proof(fixture.decision(room: submissions[rejected.0].command.intent.roomID,
                    actor: senderID, request: rejected.1, decision: .reject))
                _ = try await fixture.proof(fixture.decision(room: submissions[approved.0].command.intent.roomID,
                    actor: senderID, request: approved.1, decision: .approve))
                #expect(try await count("im_v2.group_join_quota_intents WHERE phase IN ('held','tracking')", on: sql) == 18)
                let remainingA = try await count("im_v2.group_join_requests WHERE state = 'pending'", on: sql)
                let remainingB = try await count("im_v2.group_join_requests WHERE state = 'pending'", on: secondSQL)
                #expect(remainingA + remainingB == 18)
                try await controlResources.shutdown()
            } catch {
                try? await controlResources.shutdown()
                throw error
            }
        }
    }

    @Test("reserved admission persists negative results and fences retries", arguments: ["expired", "rate", "disabled"])
    func groupJoinReservedNegativeReceipt(_ scenario: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, controlSQL, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000), applicant = UserID(uuid: UUID())
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            try await controlSQL.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at) VALUES (\(bind: applicant.uuidValue!), 'receipt_applicant', 'Applicant', \(bind: now), \(bind: now))").run()
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let typed = try QuotaInvitationFixture(control: control, owner: { _ in (owner, "room-b", 0) }, profile: profile, now: now)
            let link = try await typed.create(room: room, actor: senderID)
            let inviteID = link.id, digest = typed.issuer.digest(link.secret)
            let original = try await typed.submission(room: room, actor: applicant, invite: inviteID, secret: link.secret)
            let quota = PostgresV2GroupJoinQuotaStore(database: control)
            let request = V2GroupJoinSubmissionPersistenceRequest(requestID: .init(uuid: UUID()), applicantUserID: applicant,
                operationID: try .init(original.command.identity.operation.rawOperationID), tokenDigest: digest, note: nil, createdAt: now,
                maximumPendingRequestsPerApplicant: 1, maximumPendingRequestsPerInvite: 1)
            guard case .reserved(let intent) = try await quota.reserve(request, roomID: room, inviteID: inviteID, now: now) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            if scenario == "rate" {
                try await ownerSQL.raw("INSERT INTO im_v2.group_join_requests(request_id,invite_id,room_id,applicant_user_id,submission_operation_id,created_at,updated_at) VALUES (\(bind: UUID()),\(bind: inviteID.uuidValue!),\(bind: room.uuidValue!),\(bind: UUID()),\(bind: UUID()),\(bind: now),\(bind: now))").run()
            } else if scenario == "disabled" {
                try await controlSQL.raw("INSERT INTO im_v2.account_disables(user_id,operation_id,reason,operator_principal,disabled_at) VALUES (\(bind: applicant.uuidValue!),\(bind: UUID()),'policy_enforcement','receipt-test',\(bind: now))").run()
            }
            let evaluatedAt = scenario == "expired" ? now.addingTimeInterval(4000) : now
            let evaluated = try QuotaInvitationFixture(control: control, owner: { _ in (owner, "room-b", 0) }, profile: profile, now: now, clock: { evaluatedAt })
            let execution = V2GroupInvitationExecutionRequest(command: original.command, quotaIntent: .init(domain: intent))
            let result = try await evaluated.operations.submit(execution, invitationTestDeadline())
            if scenario == "rate" { guard case .deferred(let hint) = result else { throw V2GroupInviteDirectoryError.ownerResultMismatch }; #expect(hint.reason == .rateLimited) }
            else {
                guard case .receipt(let proof) = result else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
                #expect(proof.validates(intent: original.command.intent))
                #expect(proof.outcome == .rejected(scenario == "expired" ? .admissionExpired : .permissionDenied))
            }
            #expect(try await count("im_v2.group_join_requests WHERE applicant_user_id = '\(applicant.uuidValue!)'", on: ownerSQL) == 0)
            try await ownerSQL.raw("DELETE FROM im_v2.group_join_requests").run()
            try await controlSQL.raw("DELETE FROM im_v2.account_disables WHERE user_id = \(bind: applicant.uuidValue!)").run()
            if scenario != "rate" {
                // Restored authority cannot replace an original terminal rejection.
                #expect(try await typed.operations.submit(execution, invitationTestDeadline()) == result)
            } else {
                #expect(try await count("im_v2.group_join_submission_receipts", on: ownerSQL) == 0)
                _ = try await quota.resolve(intent, outcome: .rateLimited, targetRequestID: nil, now: now)
                guard case .reserved(let retry) = try await quota.reserve(request, roomID: room, inviteID: inviteID, now: now.addingTimeInterval(1)) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                #expect(retry.operationID == intent.operationID && retry.requestID == intent.requestID && retry.generation == intent.generation)
                #expect(retry.attemptCreatedAt == intent.attemptCreatedAt && retry.createdAt == intent.createdAt)
                guard case .receipt(let proof) = try await typed.operations.submit(.init(command: original.command, quotaIntent: .init(domain: retry)), invitationTestDeadline()) else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
                #expect(proof.validates(intent: original.command.intent))
                #expect(try typed.requestID(proof).uuidValue == intent.requestID)
                #expect(try await count("im_v2.group_join_requests", on: ownerSQL) == 1)
                #expect(try await typed.operations.submit(execution, invitationTestDeadline()) == .receipt(proof))
                #expect(try await count("im_v2.group_join_submission_receipts", on: ownerSQL) == 1)
                #expect(try await quota.resolve(intent, outcome: .pending, targetRequestID: intent.requestID, now: now))
                #expect(try await !quota.resolve(intent, outcome: .rateLimited, targetRequestID: nil, now: now))
            }

        }
    }

    @Test("request and owner receipt commit together, and terminal replay never creates another request")
    func groupJoinReservedReceiptAtomicity() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, controlSQL, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000), applicant = UserID(uuid: UUID())
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            try await controlSQL.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at) VALUES (\(bind: applicant.uuidValue!), 'receipt_atomic', 'Applicant', \(bind: now), \(bind: now))").run()
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let typed = try QuotaInvitationFixture(control: control, owner: { _ in (owner, "room-b", 0) }, profile: profile, now: now)
            let link = try await typed.create(room: room, actor: senderID)
            let inviteID = link.id, digest = typed.issuer.digest(link.secret)
            let original = try await typed.submission(room: room, actor: applicant, invite: inviteID, secret: link.secret)
            let quota = PostgresV2GroupJoinQuotaStore(database: control)
            let request = V2GroupJoinSubmissionPersistenceRequest(requestID: .init(uuid: UUID()), applicantUserID: applicant,
                operationID: try .init(original.command.identity.operation.rawOperationID), tokenDigest: digest, note: nil, createdAt: now,
                maximumPendingRequestsPerApplicant: 1, maximumPendingRequestsPerInvite: 1)
            guard case .reserved(let intent) = try await quota.reserve(request, roomID: room, inviteID: inviteID, now: now) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            let execution = V2GroupInvitationExecutionRequest(command: original.command, quotaIntent: .init(domain: intent))
            try await ownerSQL.raw("CREATE FUNCTION im_v2.fail_quota_receipt() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'receipt rollback fixture'; END; $$").run()
            try await ownerSQL.raw("CREATE TRIGGER fail_quota_receipt BEFORE INSERT ON im_v2.group_join_submission_receipts FOR EACH ROW EXECUTE FUNCTION im_v2.fail_quota_receipt()").run()
            await #expect(throws: PSQLError.self) { _ = try await typed.operations.submit(execution, invitationTestDeadline()) }
            #expect(try await count("im_v2.group_join_requests", on: ownerSQL) == 0)
            #expect(try await count("im_v2.group_join_submission_receipts", on: ownerSQL) == 0)
            #expect(try await count("im_v2.group_invitation_receipts WHERE actor_user_id = '\(applicant.uuidValue!)'", on: ownerSQL) == 0)
            try await ownerSQL.raw("DROP TRIGGER fail_quota_receipt ON im_v2.group_join_submission_receipts").run()
            async let a = typed.operations.submit(execution, invitationTestDeadline())
            async let b = typed.operations.submit(execution, invitationTestDeadline())
            let (left, right) = try await (a, b)
            #expect(left == right)
            guard case .receipt(let proof) = left else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
            #expect(proof.validates(intent: original.command.intent))
            #expect(try typed.requestID(proof) == request.requestID)
            #expect(try await count("im_v2.group_join_requests", on: ownerSQL) == 1)
            #expect(try await count("im_v2.group_join_submission_receipts", on: ownerSQL) == 1)
            _ = try await quota.resolve(intent, outcome: .pending, targetRequestID: request.requestID.uuidValue!, now: now)
            _ = try await typed.proof(typed.cancel(room: room, actor: applicant, request: request.requestID))
            #expect(try await typed.operations.submit(execution, invitationTestDeadline()) == left)
            let changed = try typed.intent(room: room, actor: applicant, reference: original.command.identity.operation,
                action: .submit(inviteID: inviteID, tokenDigest: digest, note: "changed binding"))
            #expect(try await typed.coordinator.recoverOperation(.init(intent: changed, action: .query), deadline: invitationTestDeadline()) == .fingerprintConflict)
            #expect(try await count("im_v2.group_join_requests", on: ownerSQL) == 1)

        }
    }



    @Test("cancellation uses the room owner and control identity and fences stale owner epochs")
    func invitationCancellationRouting() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, sql, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000), applicant = UserID(uuid: UUID())
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            try await sql.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at) VALUES (\(bind: applicant.uuidValue!), 'routed_cancel', 'Control Applicant', \(bind: now), \(bind: now))").run()
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let current = try QuotaInvitationFixture(control: control, owner: { _ in (owner, "room-b", 0) }, profile: profile, now: now)
            let link = try await current.create(room: room, actor: senderID)
            let submission = try await current.submission(room: room, actor: applicant, invite: link.id, secret: link.secret)
            let original = try await current.proof(submission), requestID = try current.requestID(original)
            let cancel = try await current.cancel(room: room, actor: applicant, request: requestID)
            try await ownerSQL.raw("UPDATE im_v2.rooms SET owner_epoch = 1 WHERE room_id = \(bind: room.uuidValue!)").run()
            await #expect(throws: V2RoomActorStateError.ownerChanged) { _ = try await current.execute(cancel) }
            #expect(try await count("im_v2.group_join_requests WHERE state = 'pending'", on: ownerSQL) == 1)
            let moved = try QuotaInvitationFixture(control: control, owner: { _ in (owner, "room-b", 1) }, profile: profile, now: now)
            let proof = try await moved.proof(cancel)
            #expect(proof.outcome == .applied(.requestCancelled(requestID: requestID)))
            #expect(try await moved.proof(cancel) == proof)
            #expect(try await moved.proof(submission) == original)
            #expect(try await count("im_v2.group_join_requests", on: sql) == 0)
            #expect(try await count("im_v2.group_join_requests WHERE state = 'cancelled'", on: ownerSQL) == 1)
            #expect(try await count("im_v2.group_join_quota_intents WHERE phase IN ('held','tracking')", on: sql) == 0)
        }
    }

    @Test("applicant cancellation preserves decisions, releases quota, and serializes with approval", arguments: ["pending", "expired", "revoked", "approve-first", "reject-first", "race"])
    func invitationApplicantCancellation(_ scenario: String) async throws {
        guard let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1" else { return }
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
            let database = resources.database(.psql)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, retryAfterSeconds: 3))
            var fixture = try QuotaInvitationFixture(control: database, owner: { _ in (database, "room-a", 0) },
                profile: profile, policy: try .init(maximumPendingRequestsPerApplicant: 1, maximumPendingRequestsPerInvite: 1), now: now)
            let link = try await fixture.create(room: roomID, actor: senderID, uses: 2)
            let original = try await fixture.submission(room: roomID, actor: applicant, invite: link.id, secret: link.secret)
            let submitted = try await fixture.proof(original), requestID = try fixture.requestID(submitted)
            var cancel = try await fixture.cancel(room: roomID, actor: applicant, request: requestID)
            let approve = try await fixture.decision(room: roomID, actor: senderID, request: requestID, decision: .approve)
            let reject = try await fixture.decision(room: roomID, actor: senderID, request: requestID, decision: .reject)
            let wrong = try fixture.intent(room: roomID, actor: senderID, reference: .groupJoinRequest(.init(uuid: UUID())), action: .cancel(requestID: requestID))
            #expect(try await fixture.coordinator.admitOperation(.init(intent: wrong), deadline: invitationTestDeadline()) == .currentUnavailable(.requestNotFound))
            if scenario == "expired" {
                // Advance the actual coordinator/owner clock past the original
                // legal lifetime; do not manufacture an invalid persisted expiry.
                fixture = try QuotaInvitationFixture(control: database, owner: { _ in (database, "room-a", 0) },
                    profile: profile, policy: try .init(maximumPendingRequestsPerApplicant: 1, maximumPendingRequestsPerInvite: 1),
                    now: now.addingTimeInterval(3_601))
                cancel = try await fixture.cancel(room: roomID, actor: applicant, request: requestID)
            } else if scenario == "revoked" {
                let baseline = try await fixture.coordinator.operationBaseline(roomID: roomID, actorUserID: senderID, deadline: invitationTestDeadline())
                _ = try await fixture.proof(fixture.admitted(fixture.intent(room: roomID, actor: senderID,
                    reference: .groupInvite(.init(uuid: UUID())), action: .revoke(inviteID: link.id, expectedMembershipRevision: baseline.membershipRevision))))
            }
            if scenario == "approve-first" { _ = try await fixture.proof(approve) }
            if scenario == "reject-first" { _ = try await fixture.proof(reject) }
            let cancellation: V2GroupInvitationOperationReceipt
            if scenario == "race" {
                let racingFixture = fixture
                let cancelSubmission = cancel
                async let left = racingFixture.proof(cancelSubmission)
                async let right = racingFixture.proof(approve)
                let (a, b) = try await (left, right)
                cancellation = a
                #expect(a.validates(intent: cancel.command.intent) && b.validates(intent: approve.command.intent))
            } else { cancellation = try await fixture.proof(cancel) }
            #expect(try await fixture.proof(cancel) == cancellation)
            #expect(try await fixture.proof(original) == submitted)
            let state = try #require(try await sql.raw("SELECT state AS value FROM im_v2.group_join_requests WHERE request_id = \(bind: requestID.uuidValue!)").first(decoding: StringValueRow.self)?.value)
            #expect(state == "cancelled" || state == "approved" || state == "rejected")
            #expect(state == (scenario == "approve-first" ? "approved" : scenario == "reject-first" ? "rejected" : scenario == "race" ? state : "cancelled"))
            let uses = try await sql.raw("SELECT approved_use_count::text AS value FROM im_v2.group_invite_links WHERE invite_id = \(bind: link.id.uuidValue!)").first(decoding: StringValueRow.self)?.value
            #expect(uses == (state == "approved" ? "1" : "0"))
            let isMember = try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.room_memberships WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: applicant.uuidValue!) AND left_revision IS NULL) AS exists").first(decoding: ExistsRow.self)?.exists
            #expect(isMember == (state == "approved"))
            #expect(try await count("im_v2.room_events", on: sql) == (state == "approved" ? 1 : 0))
            #expect(try await count("im_v2.group_join_quota_intents WHERE phase IN ('held','tracking')", on: sql) == 0)
            if state == "cancelled" {
                let next = try await fixture.create(room: roomID, actor: senderID, uses: 2)
                let fresh = try await fixture.submission(room: roomID, actor: applicant, invite: next.id, secret: next.secret)
                #expect(try await fixture.requestID(fixture.proof(fresh)) != requestID)
                #expect(try await fixture.proof(cancel) == cancellation)
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

private struct QuotaInvitationFixture: Sendable {
    let coordinator: V2ActorInvitationCoordinator
    let operations: V2GroupInvitationOperationRoomPort
    let issuer: V2GroupInviteSecretIssuer
    let now: Date
    init(control: any Database, owner: @escaping @Sendable (RoomID) throws -> (database: any Database, shardID: String, epoch: Int64),
         profile: V2CapacityProfile, policy: V2GroupInvitationPolicy = .standard, now: Date,
         clock: (@Sendable () -> Date)? = nil) throws {
        let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 35, count: 32))
        let time: @Sendable () -> Date = clock ?? { now }
        self.issuer = issuer; self.now = now
        operations = invitationOperationPort(control: control, owner: owner, issuer: issuer, policy: policy, capacityProfile: profile, now: time)
        coordinator = .init(controlDatabase: control,
            room: invitationRoomPort(control: control, owner: owner, capacityProfile: profile, now: time),
            operations: operations, secretIssuer: issuer, policy: policy, now: time)
    }
    func intent(room: RoomID, actor: UserID, reference: V2OperationReference, action: V2GroupInvitationOperationAction) throws -> V2GroupInvitationOperationIntent {
        try .init(identity: .init(accountID: actor, scope: .room(room), operation: reference), action: action,
            confirmedUntilMilliseconds: UInt64(now.timeIntervalSince1970 * 1_000) + 120_000)
    }
    func admitted(_ value: V2GroupInvitationOperationIntent, secret: V2GroupInviteSecret? = nil) async throws -> V2GroupInvitationSubmission {
        let authorization = secret.map(V2GroupInvitationSecretAuthorization.init(secret:))
        guard case .admitted(let context) = try await coordinator.admitOperation(.init(intent: value, secretAuthorization: authorization), deadline: invitationTestDeadline()) else {
            throw V2GroupInviteDirectoryError.ownerResultMismatch
        }
        return try .init(command: .init(intent: value, admission: context), secretAuthorization: authorization)
    }
    func execute(_ submission: V2GroupInvitationSubmission) async throws -> V2GroupInvitationOperationRecoveryResult {
        let result = try await coordinator.submitOperation(submission, deadline: invitationTestDeadline())
        if case .receipt(let proof) = result { guard proof.validates(intent: submission.command.intent) else { throw V2GroupInviteDirectoryError.ownerResultMismatch } }
        return result
    }
    func proof(_ submission: V2GroupInvitationSubmission) async throws -> V2GroupInvitationOperationReceipt {
        guard case .receipt(let proof) = try await execute(submission) else { throw V2GroupInviteDirectoryError.ownerResultMismatch }; return proof
    }
    func create(room: RoomID, actor: UserID, uses: Int = 10) async throws -> (id: GroupInviteID, secret: V2GroupInviteSecret) {
        let baseline = try await coordinator.operationBaseline(roomID: room, actorUserID: actor, deadline: invitationTestDeadline())
        let value = try intent(room: room, actor: actor, reference: .groupInvite(.init(uuid: UUID())),
            action: .create(lifetimeSeconds: 3_600, maximumApprovedUses: uses, expectedMembershipRevision: baseline.membershipRevision))
        let receipt = try await proof(admitted(value))
        guard case .applied(.inviteCreated(let id, _, _, _)) = receipt.outcome else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
        return (id, try issuer.secret(actorUserID: actor, operationID: .init(value.identity.operation.rawOperationID)))
    }
    func submission(room: RoomID, actor: UserID, invite: GroupInviteID, secret: V2GroupInviteSecret, note: String? = nil) async throws -> V2GroupInvitationSubmission {
        try await admitted(intent(room: room, actor: actor, reference: .groupJoinRequest(.init(uuid: UUID())),
            action: .submit(inviteID: invite, tokenDigest: issuer.digest(secret), note: note)), secret: secret)
    }
    func requestID(_ proof: V2GroupInvitationOperationReceipt) throws -> GroupJoinRequestID {
        switch proof.outcome { case .applied(.requestSubmitted(let id, _)), .alreadySatisfied(.requestSubmitted(let id, _)): return id
        default: throw V2GroupInviteDirectoryError.ownerResultMismatch }
    }
    func cancel(room: RoomID, actor: UserID, request: GroupJoinRequestID) async throws -> V2GroupInvitationSubmission {
        try await admitted(intent(room: room, actor: actor, reference: .groupJoinRequest(.init(uuid: UUID())), action: .cancel(requestID: request)))
    }
    func decision(room: RoomID, actor: UserID, request: GroupJoinRequestID, decision: V2GroupJoinDecision) async throws -> V2GroupInvitationSubmission {
        let baseline = try await coordinator.operationBaseline(roomID: room, actorUserID: actor, deadline: invitationTestDeadline())
        return try await admitted(intent(room: room, actor: actor, reference: .groupJoinDecision(.init(uuid: UUID())),
            action: .decide(requestID: request, decision: decision, expectedMembershipRevision: baseline.membershipRevision)))
    }
}
