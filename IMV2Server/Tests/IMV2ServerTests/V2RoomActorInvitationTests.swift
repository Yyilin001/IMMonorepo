@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("D4 invite intent and quota recovery reuse room turn across approve/cancel race",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_D4_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func v2RoomActorInvitationRecoveryAndDecisionRace() async throws {
        let controlURL = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_D4_CONTROL_DATABASE_URL"])
        let ownerURL = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_D4_OWNER_DATABASE_URL"])
        let resources = makeV2DatabaseTestResources()
        let ownerID = DatabaseID(string: "d4-invite-owner")
        resources.databases.use(try .postgres(url: controlURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
        resources.databases.use(try .postgres(url: ownerURL, maxConnectionsPerEventLoop: 4), as: ownerID)
        let controlDB = resources.database(.psql), ownerDB = resources.database(ownerID)
        let control = try #require(controlDB as? any SQLDatabase)
        let owner = try #require(ownerDB as? any SQLDatabase)
        do {
            for sql in [control, owner] {
                guard try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS value")
                    .first(decoding: D4InviteExistsRow.self)?.value == false else {
                    throw TestConfigurationError.schemaAlreadyExists
                }
                try await installSchema(on: sql)
            }
            try await seedRoom(on: owner)
            try await owner.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            let applicantUUID = UUID()
            let actor = UserID(uuid: senderUUID), applicant = UserID(uuid: applicantUUID)
            try await control.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, created_at, updated_at)
                VALUES (\(bind: senderUUID), 'd4_inviter', 'D4 Inviter', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
                       (\(bind: applicantUUID), 'd4_applicant', 'D4 Applicant', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                """).run()
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let room = RoomID(uuid: roomUUID)
            try await withRoomActivation(database: ownerDB, roomID: room) { token in
            let fixedNow = Date()
            let executor = try V2RoomInvitationDomainExecutor(database: ownerDB,
                token: token,
                identities: PostgresV2GroupInvitationIdentityReader(database: controlDB),
                capacityProfile: profile, now: { fixedNow })
            let drop = D4InviteResponseDrop()
            let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 0x37, count: 32))
            @Sendable func operationStore(_ intent: V2GroupInvitationOperationIntent) throws -> PostgresV2GroupInvitationOperationStore {
                let invite: GroupInviteID?
                switch intent.action { case .submit(let id, _, _), .revoke(let id, _): invite = id; default: invite = nil }
                return try .init(database: ownerDB, activationToken: token,
                    identities: PostgresV2GroupInvitationIdentityReader(database: controlDB), issuer: issuer,
                    policy: .standard, capacity: profile, inviteID: invite)
            }
            let readStore = try PostgresV2GroupInvitationOperationStore(database: ownerDB, activationToken: token,
                identities: PostgresV2GroupInvitationIdentityReader(database: controlDB), issuer: issuer, policy: .standard, capacity: profile)
            let port = V2ActorInvitationRoomPort(query: { query, _ in try await executor.execute(query) })
            let operationPort = V2GroupInvitationOperationRoomPort(baseline: { query, _ in
                try await readStore.baseline(roomID: query.roomID, actorUserID: query.actorUserID)
            }, admit: { intent, _ in try await operationStore(intent).admit(intent, now: fixedNow) }, submit: { request, _ in
                let result = try await operationStore(request.command.intent).submit(request, now: fixedNow)
                if await drop.consume(request.command.intent.action) { throw D4InviteSimulatedResponseLoss() }
                return result
            }, recover: { request, _ in try await operationStore(request.intent).recover(request, now: fixedNow) })
            let coordinator = V2ActorInvitationCoordinator(controlDatabase: controlDB,
                room: port, operations: operationPort, secretIssuer: issuer, now: { fixedNow })
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            let baseline = try await coordinator.operationBaseline(roomID: room, actorUserID: actor, deadline: deadline)
            func intent(_ principal: UserID, reference: V2OperationReference, action: V2GroupInvitationOperationAction) throws -> V2GroupInvitationOperationIntent {
                try .init(identity: .init(accountID: principal, scope: .room(room), operation: reference), action: action,
                    confirmedUntilMilliseconds: UInt64(fixedNow.timeIntervalSince1970 * 1_000) + 120_000)
            }
            func admitted(_ value: V2GroupInvitationOperationIntent, secret: V2GroupInvitationSecretAuthorization? = nil) async throws -> V2GroupInvitationOperationCommand {
                guard case .admitted(let admission) = try await coordinator.admitOperation(.init(intent: value, secretAuthorization: secret), deadline: deadline) else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
                return try .init(intent: value, admission: admission)
            }
            let create = try intent(actor, reference: .groupInvite(.init(uuid: UUID())),
                action: .create(lifetimeSeconds: 3_600, maximumApprovedUses: 1, expectedMembershipRevision: baseline.membershipRevision))
            let createCommand = try await admitted(create)
            await drop.arm(.creation)
            await #expect(throws: D4InviteSimulatedResponseLoss.self) {
                _ = try await coordinator.submitOperation(.init(command: createCommand), deadline: deadline)
            }
            #expect(try await owner.raw("SELECT count(*)::bigint AS value FROM im_v2.group_invite_links")
                .first(decoding: D4InviteCountRow.self)?.value == 1)
            let creationWorker = V2GroupInviteCreationRecoveryWorker(jobs: PostgresV2GroupInviteDirectory(database: controlDB), coordinator: coordinator,
                deadline: { deadline }, now: { fixedNow.addingTimeInterval(31) })
            let creationReport = try await creationWorker.runOnce(limit: 1)
            #expect(creationReport.attempted == 1 && creationReport.completed == 1 && creationReport.deferred == 0)
            guard case .receipt(let created) = try await coordinator.recoverOperation(.init(intent: create, action: .query), deadline: deadline),
                  case .applied(.inviteCreated(let inviteID, _, _, _)) = created.outcome else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
            #expect(created.validates(intent: create))
            let secret = try issuer.secret(actorUserID: actor, operationID: .init(create.identity.operation.rawOperationID))
            let digest = issuer.digest(secret)
            #expect(try await PostgresV2GroupInviteDirectory(database: controlDB).resolve(tokenDigest: digest)?.inviteID == inviteID)
            let submit = try intent(applicant, reference: .groupJoinRequest(.init(uuid: UUID())), action: .submit(inviteID: inviteID, tokenDigest: digest, note: "Please admit"))
            let authorization = V2GroupInvitationSecretAuthorization(secret: secret)
            let submitCommand = try await admitted(submit, secret: authorization)
            await drop.arm(.submission)
            await #expect(throws: D4InviteSimulatedResponseLoss.self) {
                _ = try await coordinator.submitOperation(.init(command: submitCommand, secretAuthorization: authorization), deadline: deadline)
            }
            let recovery = V2GroupJoinQuotaRecoveryWorker(controlDatabase: controlDB, coordinator: coordinator, deadline: { deadline }, now: { fixedNow })
            let report = try await recovery.runOnce(limit: 1)
            #expect(report.attempted == 1 && report.reconciled == 1 && report.deferred == 0)
            guard case .receipt(let submitted) = try await coordinator.recoverOperation(.init(intent: submit, action: .query), deadline: deadline),
                  case .applied(.requestSubmitted(let requestID, _)) = submitted.outcome else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
            #expect(submitted.validates(intent: submit))
            let decisionBaseline = try await coordinator.operationBaseline(roomID: room, actorUserID: actor, deadline: deadline)
            let approve = try intent(actor, reference: .groupJoinDecision(.init(uuid: UUID())), action: .decide(requestID: requestID, decision: .approve, expectedMembershipRevision: decisionBaseline.membershipRevision))
            let cancel = try intent(applicant, reference: .groupJoinRequest(.init(uuid: UUID())), action: .cancel(requestID: requestID))
            let approvalCommand = try await admitted(approve), cancellationCommand = try await admitted(cancel)
            async let approval = coordinator.submitOperation(.init(command: approvalCommand), deadline: deadline)
            async let cancellation = coordinator.submitOperation(.init(command: cancellationCommand), deadline: deadline)
            _ = try await (approval, cancellation)
            let state = try await owner.raw("SELECT state FROM im_v2.group_join_requests WHERE request_id = \(bind: requestID.uuidValue!)")
                .first(decoding: D4InviteStateRow.self)?.state
            #expect(state == "approved" || state == "cancelled")
            let membershipCount = try await owner.raw("""
                SELECT count(*)::bigint AS value FROM im_v2.room_memberships
                WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: applicantUUID) AND left_revision IS NULL
                """).first(decoding: D4InviteCountRow.self)?.value
            #expect(membershipCount == (state == "approved" ? 1 : 0))
            #expect(try await control.raw("SELECT count(*)::bigint AS value FROM im_v2.group_join_quota_intents WHERE phase IN ('held','tracking')")
                .first(decoding: D4InviteCountRow.self)?.value == 0)
            try await owner.raw("UPDATE im_v2.rooms SET owner_epoch=owner_epoch+1 WHERE room_id=\(bind:roomUUID)").run()
            let revoke = try intent(actor, reference: .groupInvite(.init(uuid: UUID())), action: .revoke(inviteID: inviteID, expectedMembershipRevision: decisionBaseline.membershipRevision))
            await #expect(throws: V2RoomActorStateError.ownerChanged) { try await operationStore(revoke).admit(revoke, now: fixedNow) }
            #expect(try await owner.raw("SELECT state FROM im_v2.group_invite_links WHERE invite_id = \(bind: inviteID.uuidValue!)")
                .first(decoding: D4InviteStateRow.self)?.state == "active")
            }
            try await control.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await owner.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            try? await control.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            try? await owner.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            try? await resources.shutdown()
            throw error
        }
    }
}

private struct D4InviteExistsRow: Decodable { let value: Bool }
private struct D4InviteCountRow: Decodable { let value: Int64 }
private struct D4InviteStateRow: Decodable { let state: String }
private struct D4InviteSimulatedResponseLoss: Error {}
private actor D4InviteResponseDrop {
    enum Mode { case creation, submission }
    private var mode: Mode?
    func arm(_ next: Mode) { mode = next }
    func consume(_ command: V2GroupInvitationOperationAction) -> Bool {
        let shouldDrop: Bool
        switch (mode, command) {
        case (.creation?, .create), (.submission?, .submit): shouldDrop = true
        default: shouldDrop = false
        }
        if shouldDrop { mode = nil }
        return shouldDrop
    }
}
