import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
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
            let ownerIdentity = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let leases = PostgresV2RoomActivationStore(database: ownerDB)
            let host = V2ActorHostIdentity(hostID: try .init("d4-invite-host"), incarnationID: UUID())
            guard case .acquired(let grant) = try await leases.acquire(roomID: room,
                owner: ownerIdentity, host: host, duration: try .init(30_000)) else {
                throw V2RoomActivationLeaseError.activationChanged
            }
            let fixedNow = Date()
            let executor = try V2RoomInvitationDomainExecutor(database: ownerDB,
                token: grant.token,
                identities: PostgresV2GroupInvitationIdentityReader(database: controlDB),
                capacityProfile: profile, now: { fixedNow })
            let drop = D4InviteResponseDrop()
            let port = V2ActorInvitationRoomPort(command: { command, _ in
                let result = try await executor.execute(command)
                if await drop.consume(command) { throw D4InviteSimulatedResponseLoss() }
                return result
            }, query: { query, _ in try await executor.execute(query) })
            let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 0x37, count: 32))
            let coordinator = V2ActorInvitationCoordinator(controlDatabase: controlDB,
                room: port, secretIssuer: issuer, now: { fixedNow })
            let deadline = ContinuousClock().now.advanced(by: .seconds(30))
            let create = V2ActorCreateGroupInviteWire(roomID: room, actorUserID: actor,
                operationID: .init(uuid: UUID()), lifetime: 3600, maximumApprovedUses: 1)
            await drop.arm(.creation)
            await #expect(throws: D4InviteSimulatedResponseLoss.self) {
                _ = try await coordinator.create(create, deadline: deadline)
            }
            #expect(try await owner.raw("SELECT count(*)::bigint AS value FROM im_v2.group_invite_links")
                .first(decoding: D4InviteCountRow.self)?.value == 1)
            let creationWorker = V2GroupInviteCreationRecoveryWorker(
                jobs: PostgresV2GroupInviteDirectory(database: controlDB), coordinator: coordinator,
                deadline: { deadline }, now: { fixedNow.addingTimeInterval(31) })
            let creationReport = try await creationWorker.runOnce(limit: 1)
            #expect(creationReport.attempted == 1 && creationReport.completed == 1 && creationReport.deferred == 0)
            guard case .created(let link) = try await coordinator.create(create, deadline: deadline) else {
                throw V2GroupInviteDirectoryError.ownerResultMismatch
            }
            let digest = issuer.digest(try link.secret.toDomain())
            #expect(try await PostgresV2GroupInviteDirectory(database: controlDB)
                .resolve(tokenDigest: digest)?.inviteID == link.inviteID)
            let submit = V2ActorSubmitGroupJoinWire(applicantUserID: applicant,
                operationID: .init(uuid: UUID()), secret: link.secret, note: "Please admit")
            await drop.arm(.submission)
            await #expect(throws: D4InviteSimulatedResponseLoss.self) {
                _ = try await coordinator.submitBySecret(submit, deadline: deadline)
            }
            let recovery = V2GroupJoinQuotaRecoveryWorker(controlDatabase: controlDB,
                coordinator: coordinator, deadline: { deadline }, now: { fixedNow })
            let report = try await recovery.runOnce(limit: 1)
            #expect(report.attempted == 1 && report.reconciled == 1 && report.deferred == 0)
            guard case .submission(let settled) = try await coordinator.submitBySecret(submit, deadline: deadline) else {
                throw V2GroupInviteDirectoryError.ownerResultMismatch
            }
            let request: V2ActorGroupJoinRequestRecordWire
            switch settled {
            case .submitted(let value), .alreadyPending(let value): request = value
            default: throw V2GroupInviteDirectoryError.ownerResultMismatch
            }
            let approve = V2ActorDecideGroupJoinWire(roomID: room, requestID: request.requestID,
                reviewerUserID: actor, operationID: .init(uuid: UUID()), decision: .approve)
            let cancel = V2ActorCancelGroupJoinWire(roomID: room, requestID: request.requestID,
                applicantUserID: applicant)
            async let approval = coordinator.decide(approve, deadline: deadline)
            async let cancellation = coordinator.cancel(cancel, deadline: deadline)
            _ = try await (approval, cancellation)
            let state = try await owner.raw("SELECT state FROM im_v2.group_join_requests WHERE request_id = \(bind: request.requestID.uuidValue!)")
                .first(decoding: D4InviteStateRow.self)?.state
            #expect(state == "approved" || state == "cancelled")
            let membershipCount = try await owner.raw("""
                SELECT count(*)::bigint AS value FROM im_v2.room_memberships
                WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: applicantUUID) AND left_revision IS NULL
                """).first(decoding: D4InviteCountRow.self)?.value
            #expect(membershipCount == (state == "approved" ? 1 : 0))
            #expect(try await control.raw("SELECT count(*)::bigint AS value FROM im_v2.group_join_quota_intents WHERE phase IN ('held','tracking')")
                .first(decoding: D4InviteCountRow.self)?.value == 0)
            #expect(try await leases.release(token: grant.token))
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                _ = try await executor.execute(.revoke(.init(roomID: room,
                    actorUserID: actor, operationID: .init(uuid: UUID()), inviteID: link.inviteID)))
            }
            #expect(try await owner.raw("SELECT state FROM im_v2.group_invite_links WHERE invite_id = \(bind: link.inviteID.uuidValue!)")
                .first(decoding: D4InviteStateRow.self)?.state == "active")
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
    func consume(_ command: V2RoomInvitationCommand) -> Bool {
        let shouldDrop: Bool
        switch (mode, command) {
        case (.creation?, .commitCreation), (.submission?, .submitReserved): shouldDrop = true
        default: shouldDrop = false
        }
        if shouldDrop { mode = nil }
        return shouldDrop
    }
}
