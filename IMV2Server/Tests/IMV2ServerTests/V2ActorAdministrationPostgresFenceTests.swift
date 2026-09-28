import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing

/// Run only against a dedicated disposable database, never the shared P0 database.
extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("D2 nickname writer fences old-token replay and concurrent handoff",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_D2_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func v2ActorAdministrationOldTokenNicknameFence() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_D2_TEST_DATABASE_URL"])
        let resources = makeV2DatabaseTestResources()
        resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
        let database = resources.database(.psql)
        let sql = try #require(database as? any SQLDatabase)
        do {
            let exists = try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS value")
                .first(decoding: D2ExistsRow.self)?.value == true
            guard !exists else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '1 hour'").run()
            let room = RoomID(uuid: roomUUID), actor = UserID(uuid: senderUUID)
            let confirmedAt = Date()
            let nameDeadline = try V2DirectRoomOperationTestFixture.deadline(confirmedAt)
            let moderationDeadline = UInt64(try v2GatewayMilliseconds(confirmedAt)) + 120_000
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let leases = PostgresV2RoomActivationStore(database: database)
            let hostA = V2ActorHostIdentity(hostID: try .init("d2-host-a"), incarnationID: UUID())
            guard case .acquired(let first) = try await leases.acquire(
                roomID: room, owner: owner, host: hostA, duration: try .init(30_000)
            ) else { throw V2RoomActivationLeaseError.activationChanged }
            let old = PostgresV2ProfilePresentationStore(database: database,
                activationScope: try .init(tokens: [first.token]), nicknameCapacityProfile: try forwardImportTestProfile())
            let initialOperation = GroupNicknameOperationID(uuid: UUID())
            let initial = try await old.updateOwnGroupNickname(.init(actorUserID: actor, roomID: room,
                operationID: initialOperation, expectedRevision: nil, nickname: "Alice",firstSubmissionDeadlineMilliseconds:nameDeadline)).committedValue
            #expect(initial.groupNickname == "Alice")
            #expect(try await old.updateOwnGroupNickname(.init(actorUserID: actor, roomID: room,
                operationID: initialOperation, expectedRevision: nil, nickname: "Alice",firstSubmissionDeadlineMilliseconds:nameDeadline)).committedValue == initial)

            let blockedOperation = GroupNicknameOperationID(uuid: UUID())
            let blocked = D2NicknameOperationGate()
            let holder = Task {
                try await database.transaction { transaction in
                    let txSQL = try #require(transaction as? any SQLDatabase)
                    let key = senderUUID.uuidString + ":presentation-operation:groupNickname:" + blockedOperation.uuidValue!.uuidString
                    try await txSQL.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
                    await blocked.signalHeld()
                    await blocked.waitForRelease()
                }
            }
            await blocked.waitUntilHeld()
            let oldWrite = Task {
                try await old.updateOwnGroupNickname(.init(actorUserID: actor, roomID: room,
                    operationID: blockedOperation, expectedRevision: initial.revision, nickname: "Stale",firstSubmissionDeadlineMilliseconds:nameDeadline)).committedValue
            }
            // The old operation is waiting on its exact advisory lock; activation may change meanwhile.
            try await Task.sleep(for: .milliseconds(60))
            #expect(try await leases.release(token: first.token))
            let hostB = V2ActorHostIdentity(hostID: try .init("d2-host-b"), incarnationID: UUID())
            guard case .acquired(let successor) = try await leases.acquire(
                roomID: room, owner: owner, host: hostB, duration: try .init(30_000)
            ) else { await blocked.release(); throw V2RoomActivationLeaseError.activationChanged }
            await blocked.release()
            try await holder.value
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) { _ = try await oldWrite.value }
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                _ = try await old.updateOwnGroupNickname(.init(actorUserID: actor, roomID: room,
                    operationID: initialOperation, expectedRevision: nil, nickname: "Alice",firstSubmissionDeadlineMilliseconds:nameDeadline)).committedValue
            }
            let current = PostgresV2ProfilePresentationStore(database: database,
                activationScope: try .init(tokens: [successor.token]), nicknameCapacityProfile: try forwardImportTestProfile())
            #expect(try await current.updateOwnGroupNickname(.init(actorUserID: actor, roomID: room,
                operationID: initialOperation, expectedRevision: nil, nickname: "Alice",firstSubmissionDeadlineMilliseconds:nameDeadline)).committedValue == initial)
            let oldScope = try V2RoomActivationWriteScope(tokens: [first.token])
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let eventID = try EventID(UUID().uuidString)
            // Freeze current owner gates, then prove stale activations cannot
            // execute those same immutable commands or create domain facts.
            try await sql.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE room_id=\(bind: roomUUID) AND user_id=\(bind: senderUUID)").run()
            let membership = PostgresV2MembershipOperationStore(database: database, clock: { confirmedAt })
            let target = UserID(uuid: memberTwoUUID)
            let identity = try await V2PostgresMembershipIdentitySnapshotValidator(database: database)
                .snapshot(actorUserID: actor, targetUserID: target)
            let membershipIntent = try V2MembershipIntent(roomID: room, actorUserID: actor,
                operationID: .init(uuid: UUID()), targetUserID: target, action: .remove,
                expectedMembershipRevision: 0, confirmedUntilMilliseconds: moderationDeadline)
            guard case .admitted(let memberAdmission) = try await membership.admit(membershipIntent,
                identitySnapshot: identity, token: successor.token) else { throw V2MembershipOperationValidationError.invalidAdmission }
            let memberCommand = try V2MembershipOperationCommand(intent: membershipIntent, admission: memberAdmission)
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                _ = try await membership.submit(memberCommand, token: first.token, capacityProfile: profile,
                    eventID: eventID, identitySnapshot: identity)
            }
            let capabilities = PostgresV2GroupCapabilityOperationStore(database: database, clock: { confirmedAt })
            let announcementIntent = try V2GroupCapabilityIntent(identity: .init(accountID: actor, scope: .room(room),
                operation: .groupAnnouncement(.init(uuid: UUID()))), action: .announcement(body: "stale", expectedRevision: 0),
                confirmedUntilMilliseconds: moderationDeadline)
            guard case .admitted(let announcementAdmission) = try await capabilities.admit(announcementIntent,
                token: successor.token) else { throw V2GroupCapabilityValidationError.invalidAdmission }
            let announcement = try V2GroupCapabilityCommand(intent: announcementIntent, admission: announcementAdmission)
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                _ = try await capabilities.submit(announcement, token: first.token,
                    capacityProfile: profile, eventID: eventID)
            }
            let moderation = PostgresV2ModerationStore(database: database, activationScope: oldScope)
            let freeze = try V2ModerationCommand(roomID: room, actorUserID: actor,
                operationID: .init(uuid: UUID()), action: .freezeRoom,
                reasonCode: .init("review"))
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                _ = try await moderation.applyTrustedSafety(command: freeze, capacityProfile: profile,
                    eventID: eventID, now: Date())
            }
            let executor = try V2RoomAdministrationDomainExecutor(database: database, invitationSecretIssuer: try .init(rawKey: Data(repeating: 0x73, count: 32)), invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: database),
                token: successor.token, capacityProfile: profile,
                membershipIdentities: D2IdentityReader(), makeEventID: { eventID })
            let update = V2RoomAdministrationCommand.groupNickname(.init(command: try .init(actorUserID: actor, roomID: room,
                operationID: .init(uuid: UUID()),
                expectedRevision: initial.revision, nickname: "Alice B", firstSubmissionDeadlineMilliseconds: nameDeadline)))
            guard case .groupNickname(let updated) = try await executor.executeUser(update) else {
                throw V2ActorAdministrationWireError.trustedActionOnUserLane
            }
            #expect(try updated.committedValue.groupNickname == "Alice B")
            #expect(try await count("im_v2.group_nickname_operation_receipts", on: sql) == 2)
            #expect(try await sql.raw("""
                SELECT EXISTS(SELECT 1 FROM im_v2.room_events WHERE event_id=\(bind: eventID.uuidValue!)
                    AND room_id=\(bind: roomUUID) AND event_type='group.nickname_changed') AS value
                """).first(decoding: D2ExistsRow.self)?.value == true)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            try? await resources.shutdown()
            throw error
        }
    }
}

private struct D2ExistsRow: Decodable { let value: Bool }

private struct D2IdentityReader: V2MembershipIdentitySnapshotValidating {
    func snapshot(actorUserID: UserID, targetUserID: UserID) async throws -> V2MembershipIdentitySnapshot {
        .init(actorUserID: actorUserID, targetUserID: targetUserID,
              actorIsActive: true, targetIsActive: true)
    }
}

private actor D2NicknameOperationGate {
    private var held = false
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private var released = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func signalHeld() { held = true; heldWaiter?.resume(); heldWaiter = nil }
    func waitUntilHeld() async {
        if !held { await withCheckedContinuation { heldWaiter = $0 } }
    }
    func waitForRelease() async {
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}
