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
    @Test("group creation delivers personal room identity without any public fanout plan")
    func groupCreationDeliversRoomProfileAndRetainsItInSnapshot() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_300_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10,
                maxCommandsPerWindow: 10,

                retryAfterSeconds: 3
            ))
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
                VALUES ('rooms-primary', 'standard', \(bind: leaseUUID), 1, \(bind: now.addingTimeInterval(600)), 10)
                """).run()
            let invitedUser = try UserID(memberTwoUUID.uuidString)
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, revision, created_at, updated_at)
                VALUES
                    (\(bind: senderUUID), 'groupowner82', '群主', 1, \(bind: now), \(bind: now)),
                    (\(bind: memberTwoUUID), 'groupmember82', '群成员', 1, \(bind: now), \(bind: now))
                """).run()
            let canonical = try V2GroupCreationAudience.canonical([invitedUser], actorUserID: senderID)
            let intent = try V2GroupCreationIntent(identity: .init(accountID: senderID, scope: .account(senderID),
                operation: .groupRoom(.init("00000000-0000-0000-0000-000000000082"))), title: "  V2 项目群  ",
                capacityClass: .standard, initialMemberCount: canonical.count, audienceDigest: V2GroupCreationAudience.digest(canonical),
                firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            let group = try V2GroupCreationOperationTestFixture(control: resources.database(.psql), owner: resources.database(.psql),
                shardID: "rooms-primary", capacityProfile: profile, now: { now })
            let created = try await group.create(intent: intent, canonicalMembers: canonical, now: now)
            let createdRoute = try await V2PostgresRoomShardRouter(database: resources.database(.psql)).route(for: created.roomID)
            #expect(createdRoute.shardID == "rooms-primary" && createdRoute.epoch == 0)


            let source = try #require(try await sql.raw("SELECT event_id::text AS value FROM im_v2.room_events WHERE event_type = 'room.created'").first(decoding: StringValueRow.self)).value
            let delivery = try await V2UserStateEventWorker(
                outbox: PostgresV2UserStateEventOutbox(database: resources.database(.psql)),
                projector: PostgresV2UserStateEventProjector(database: resources.database(.psql)),
                now: { now.addingTimeInterval(2) }
            ).runOnce(limit: 8)
            let sync = V2SyncService(store: PostgresV2SyncStore(database: resources.database(.psql)), now: { now.addingTimeInterval(3) })
            let pull = try await sync.pull(userID: invitedUser, deviceID: deviceID, syncToken: nil, requestedMaxRecords: 10)
            guard case .ready(_, let records, _, _, _) = pull,
                  let roomRecord = records.first(where: { $0.projectionKind == "room" })
            else { Issue.record("expected delivered room profile"); return }
            let payload = try #require(try JSONSerialization.jsonObject(with: Data(roomRecord.payloadJSON.utf8)) as? [String: Any])
            try await drainV3Projection(database: resources.database(.psql))
            let profiles = try await currentV3ProjectionItems(sql: sql, userID: invitedUser, kind: "room")

            #expect(created.title == "V2 项目群")
            #expect(delivery == 2)
            #expect(roomRecord.sourceEventID.rawValue.lowercased() == source.lowercased())
            #expect(payload["event_type"] as? String == "room.created")
            #expect(payload["room_id"] as? String == created.roomID.rawValue)
            #expect(payload["title"] as? String == "V2 项目群")
            #expect(payload["member_user_ids"] == nil)
            #expect(profiles.count == 1)
            #expect(profiles.first?.entityKey == created.roomID.rawValue)
            #expect(profiles.first?.string("title") == "V2 项目群")

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("relationship and block mutations are durable, private, and synchronize both sides")
    func relationshipAndBlockLifecycle() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_200_000)
            let sender = senderID
            let recipient = try UserID(memberTwoUUID.uuidString)
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, revision, created_at, updated_at)
                VALUES
                    (\(bind: senderUUID), 'sender012', '发送者', 1, \(bind: now), \(bind: now)),
                    (\(bind: memberTwoUUID), 'member015', '成员二', 1, \(bind: now), \(bind: now)),
                    (\(bind: memberThreeUUID), 'member016', '成员三', 1, \(bind: now), \(bind: now))
                """).run()
            let database = resources.database(.psql)
            let service = PostgresV2SocialRelationshipStore(database: database, projectionDelivery: SuccessfulProjectionDelivery())
            let requestOperation = try RelationshipOperationID("00000000-0000-0000-0000-000000000091")
            let frozenRequest = try await service.freezeSocialFixture(actorUserID: sender, targetUserID: recipient,
                operation: .relationship(requestOperation), action: .relationship(.request), now: now)
            let requested = try await service.submitSocialOperation(frozenRequest, now: now)
            let replay = try await service.submitSocialOperation(frozenRequest, now: now)
            let accepted = try await service.executeSocialFixture(actorUserID: recipient, targetUserID: sender,
                operation: .relationship(.init("00000000-0000-0000-0000-000000000092")), action: .relationship(.accept), now: now)
            let blocked = try await service.executeSocialFixture(actorUserID: recipient, targetUserID: sender,
                operation: .userBlock(.init("00000000-0000-0000-0000-000000000093")), action: .userBlock(.block), now: now)
            let blockedRequest = try await service.executeSocialFixture(actorUserID: sender, targetUserID: recipient,
                operation: .relationship(.init("00000000-0000-0000-0000-000000000094")), action: .relationship(.request), now: now)
            let unblocked = try await service.executeSocialFixture(actorUserID: recipient, targetUserID: sender,
                operation: .userBlock(.init("00000000-0000-0000-0000-000000000095")), action: .userBlock(.unblock), now: now)
            let requestedAgain = try await service.executeSocialFixture(actorUserID: sender, targetUserID: recipient,
                operation: .relationship(.init("00000000-0000-0000-0000-000000000096")), action: .relationship(.request), now: now)
            guard case .receipt(let first) = requested, case .receipt(let replayed) = replay,
                  case .receipt(let acceptedProof) = accepted, case .receipt(let blockedProof) = blocked,
                  case .receipt(let unblockedProof) = unblocked, case .receipt(let second) = requestedAgain,
                  case .receipt(let denied) = blockedRequest else { throw CancellationError() }
            #expect(first == replayed)
            #expect(first.outcome == .applied(.relationship(state: .pending, revision: 1)))
            #expect(acceptedProof.outcome == .applied(.relationship(state: .accepted, revision: 2)))
            #expect(blockedProof.outcome == .applied(.userBlock(isBlocked: true, revision: 1)))
            #expect(denied.outcome == .rejected(.permissionDenied))
            #expect(unblockedProof.outcome == .applied(.userBlock(isBlocked: false, revision: 2)))
            guard case .applied(.relationship(let state, _)) = second.outcome else { throw CancellationError() }
            #expect(state == .pending)
            let relation = try #require(try await sql.raw("SELECT state, requested_by_user_id FROM im_v2.user_relationships WHERE lower_user_id = \(bind: senderUUID) AND higher_user_id = \(bind: memberTwoUUID)").first(decoding: RelationshipAssertionRow.self))
            #expect(relation.state == "pending" && relation.requestedByUserID == senderUUID)
            #expect(try await count("im_v2.social_operation_receipts", on: sql) == 6)
            #expect(try await count("im_v2.user_blocks", on: sql) == 0)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 10)
            let targetHasNoBlockProjection = try #require(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE user_id = \(bind: senderUUID) AND projection_kind = 'user_block'").first(decoding: CountRow.self)).value
            #expect(targetHasNoBlockProjection == 0)
            let ownBlock = try await service.executeSocialFixture(actorUserID: sender, targetUserID: .init(uuid: memberThreeUUID),
                operation: .userBlock(.init("00000000-0000-0000-0000-000000000097")), action: .userBlock(.block), now: now)
            let preferences = PostgresV2AccountPreferenceOperationStore(database: database, projectionDelivery: SuccessfulProjectionDelivery(),
                authorizationCoordinator: .init(controlDatabase: database, ownerDatabases: ["room-a": database]))
            let preference = try await preferences.executePreferenceFixture(owner: sender,
                operation: .strangerMessagePreference(.init("00000000-0000-0000-0000-000000000098")), value: .strangerMessage(.deny), now: now)
            guard case .receipt(let ownBlockProof) = ownBlock, case .applied(.userBlock(let ownIsBlocked, _)) = ownBlockProof.outcome,
                  case .receipt(let preferenceProof) = preference, case .applied(.strangerMessage(let permissionValue), _) = preferenceProof.outcome else { throw CancellationError() }

            try await drainV3Projection(database: resources.database(.psql))
            let snapshotRelationships = try await currentV3ProjectionItems(sql: sql, userID: sender, kind: "relationship")
            let snapshotBlocks = try await currentV3ProjectionItems(sql: sql, userID: sender, kind: "user_block")
            let snapshotPreference = try await currentV3ProjectionItems(sql: sql, userID: sender, kind: "stranger_message_permission")

            #expect(ownIsBlocked)
            #expect(permissionValue == .deny)
            #expect(snapshotRelationships.count == 1)
            #expect(snapshotRelationships.first?.entityKey == recipient.rawValue)
            #expect(snapshotRelationships.first?.string("state") == "pending")
            #expect(snapshotBlocks.count == 1)
            #expect(snapshotBlocks.first?.entityKey == memberThreeUUID.uuidString.lowercased())
            #expect(snapshotBlocks.first?.bool("is_blocked") == true)
            #expect(snapshotPreference.first?.bool("allows_stranger_messages") == false)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown(); throw error
        }
    }

    @Test("membership add atomically queues its affected user and replays after authorization changes")
    func membershipWriteUsesFrozenAudienceAndDurableIdempotency() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else {
            return
        }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let schemaExists = try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self)
            guard schemaExists?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").run()

            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let target = try UserID("00000000-0000-0000-0000-000000000025")
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, revision, created_at, updated_at)
                VALUES (\(bind: UUID(uuidString: target.rawValue)!), 'member025', '新成员', 1, \(bind: now), \(bind: now))
                """).run()
            let operation = try MembershipOperationID("00000000-0000-0000-0000-000000000026")
            let database = resources.database(.psql)
            let store = PostgresV2MembershipOperationStore(database: database, clock: { now })
            let snapshot = try await V2PostgresMembershipIdentitySnapshotValidator(database: database).snapshot(actorUserID: senderID, targetUserID: target)
            let request = try await withRoomActivation(database: database, roomID: roomID) { token in
                let intent = try V2MembershipIntent(roomID: roomID, actorUserID: senderID, operationID: operation,
                    targetUserID: target, action: .add, expectedMembershipRevision: 0,
                    confirmedUntilMilliseconds: UInt64(now.timeIntervalSince1970 * 1000) + 120_000)
                guard case .admitted(let admission) = try await store.admit(intent, identitySnapshot: snapshot, token: token) else {
                    throw V2MembershipOperationValidationError.invalidAdmission
                }
                return try V2MembershipOperationCommand(intent: intent, admission: admission)
            }
            func submit() async throws -> V2MembershipRecoveryResult {
                try await withRoomActivation(database: database, roomID: roomID) { token in
                    try await store.submit(request, token: token, capacityProfile: .init(id: "standard", limits: profile),
                        eventID: .init("00000000-0000-0000-0000-000000000027"), identitySnapshot: snapshot)
                }
            }
            let first = try await submit()
            guard case .receipt(let receipt) = first, case .changed(let change) = receipt.outcome else {
                Issue.record("expected an accepted membership change")
                return
            }

            // The replay must not re-evaluate current authorization. A lost
            // response can occur after the actor has itself left the room.
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision = 1 WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").run()
            let replay = try await submit()

            let delivery = try await V2UserStateEventWorker(
                outbox: PostgresV2UserStateEventOutbox(database: resources.database(.psql)),
                projector: PostgresV2UserStateEventProjector(database: resources.database(.psql)),
                now: { now.addingTimeInterval(2) }
            ).runOnce(limit: 8)

            let persisted = try #require(try await sql.raw("SELECT membership_revision, room_sequence FROM im_v2.rooms WHERE room_id = \(bind: roomUUID)").first(decoding: MembershipRevisionRow.self))
            let targetCount = try #require(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_state_event_outbox WHERE source_event_id = \(bind: UUID(uuidString: change.eventID.rawValue)!)").first(decoding: CountRow.self)).value
            let targetMembership = try #require(try await sql.raw("SELECT role, joined_revision FROM im_v2.room_memberships WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: UUID(uuidString: target.rawValue)!)").first(decoding: MembershipTargetStateRow.self))
            try await drainV3Projection(database: resources.database(.psql))
            let addedMemberProfiles = try await currentV3ProjectionItems(sql: sql, userID: target, kind: "room")

            #expect(replay == .receipt(receipt))
            #expect(persisted.membershipRevision == 1)
            #expect(persisted.roomSequence == 1)
            #expect(targetMembership.role == "member")
            #expect(targetMembership.joinedRevision == 1)
            #expect(targetCount == 1) // Only the affected user receives a personal event.
            #expect(delivery == 1)
            #expect(try await count("im_v2.membership_operation_receipts", on: sql) == 1)
            #expect(try await count("im_v2.room_events", on: sql) == 1)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 1)
            #expect(addedMemberProfiles.count == 1)
            #expect(addedMemberProfiles.first?.entityKey == roomID.rawValue)
            #expect(addedMemberProfiles.first?.string("title") == "集成测试群")

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("an admin can remove a non-owner through the durable membership path")
    func adminMayRemoveMember() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let schemaExists = try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self)
            guard schemaExists?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'admin' WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: memberThreeUUID)").run()

            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let target = try UserID(memberTwoUUID.uuidString)
            let operation = try MembershipOperationID("00000000-0000-0000-0000-000000000028")
            let database = resources.database(.psql)
            let store = PostgresV2MembershipOperationStore(database: database, clock: { now })
            let snapshot = try await V2PostgresMembershipIdentitySnapshotValidator(database: database).snapshot(actorUserID: senderID, targetUserID: target)
            let request = try await withRoomActivation(database: database, roomID: roomID) { token in
                let intent = try V2MembershipIntent(roomID: roomID, actorUserID: senderID, operationID: operation,
                    targetUserID: target, action: .remove, expectedMembershipRevision: 0,
                    confirmedUntilMilliseconds: UInt64(now.timeIntervalSince1970 * 1000) + 120_000)
                guard case .admitted(let admission) = try await store.admit(intent, identitySnapshot: snapshot, token: token) else {
                    throw V2MembershipOperationValidationError.invalidAdmission
                }
                return try V2MembershipOperationCommand(intent: intent, admission: admission)
            }
            func submit() async throws -> V2MembershipRecoveryResult {
                try await withRoomActivation(database: database, roomID: roomID) { token in
                    try await store.submit(request, token: token, capacityProfile: .init(id: "standard", limits: profile),
                        eventID: .init("00000000-0000-0000-0000-000000000029"), identitySnapshot: snapshot)
                }
            }
            let first = try await submit()
            guard case .receipt(let receipt) = first, case .changed(let change) = receipt.outcome else { Issue.record("expected admin removal"); return }
            let replay = try await submit()
            let membership = try #require(try await sql.raw("SELECT left_revision FROM im_v2.room_memberships WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: UUID(uuidString: target.rawValue)!)").first(decoding: LeftRevisionRow.self))
            let auditMembershipEvent = try #require(try await sql.raw("SELECT event_type, payload->>'action' AS action FROM im_v2.room_events WHERE event_id = \(bind: UUID(uuidString: change.eventID.rawValue)!)").first(decoding: MembershipEventRow.self))

            #expect(replay == .receipt(receipt))
            #expect(change.membershipRevision == 1)
            #expect(membership.leftRevision == 1)
            #expect(auditMembershipEvent.eventType == "membership_changed")
            #expect(auditMembershipEvent.action == "remove")
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown(); throw error
        }
    }

    @Test("message withdrawal atomically writes a tombstone fanout plan and durable replay result")
    func withdrawalWritesTombstoneTransaction() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)
            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: resources.database(.psql)), capacityProfile: try .init(id: "standard", limits: profile), limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let accepted) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "withdraw me")) else { Issue.record("expected accepted message"); return }
            let operation = try MessageWithdrawalOperationID("00000000-0000-0000-0000-000000000028")
            let withdrawal = MembershipTypedWithdrawalFixture(database: resources.database(.psql), capacityProfile: try .init(id: "standard", limits: profile), identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000029")! }), now: { now.addingTimeInterval(1) })
            let request = V2AuthenticatedMessageWithdrawal(roomID: roomID, actorUserID: senderID, operationID: operation, messageID: accepted.messageID, expectedMessageRevision: 1)
            let first = try await withdrawal.withdraw(request)
            guard case .withdrawn(let result) = first else { Issue.record("expected withdrawn result"); return }
            let replay = try await withdrawal.withdraw(request)
            let tombstone = try #require(try await sql.raw("SELECT content_revision, withdrawn_by_user_id FROM im_v2.messages WHERE message_id = \(bind: UUID(uuidString: accepted.messageID.rawValue)!)").first(decoding: WithdrawalMessageStateRow.self))
            let event = try #require(try await sql.raw("SELECT event_type, payload->>'message_id' AS message_id, payload->>'is_withdrawn' AS withdrawn FROM im_v2.room_events WHERE event_id = \(bind: UUID(uuidString: result.eventID.rawValue)!)").first(decoding: WithdrawalEventRow.self))
            #expect(replay == .idempotent(result))
            #expect(tombstone.contentRevision == 2)
            #expect(tombstone.withdrawnByUserID == senderUUID)
            #expect(event.eventType == "message.withdrawn")
            #expect(event.messageID == accepted.messageID.rawValue)
            #expect(event.withdrawn == "true")
            #expect(try await count("im_v2.message_mutation_receipts WHERE kind = 'withdrawMessage' AND receipt->'outcome' ? 'committed'", on: sql) == 1)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown(); throw error
        }
    }

    @Test("explicit personal baseline repair works above retention floor and for an empty account", arguments: [false, true])
    func explicitPersonalSnapshotRebuild(empty: Bool) async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let userUUID = UUID(); let deviceUUID = UUID()
            let user = UserID(uuid: userUUID); let device = DeviceID(uuid: deviceUUID)
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: userUUID), \(bind: deviceUUID), \(bind: now), \(bind: now))").run()
            if !empty {
                try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: userUUID), 1)").run()
                try await sql.raw("INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at) VALUES (\(bind: userUUID), 1, \(bind: UUID()), 'stranger_message_permission', '{\"allows_stranger_messages\":true,\"revision\":1,\"updated_at_ms\":1750000000000}'::jsonb, \(bind: now))").run()
                try await drainV3Projection(database: resources.database(.psql))
            }
            let sync = V2SyncService(store: PostgresV2SyncStore(database: resources.database(.psql)), now: { now })
            guard case .ready(let generation, let records, _, let receipt, _) = try await sync.pull(userID: user, deviceID: device, syncToken: nil, requestedMaxRecords: 20) else { throw V2SyncStoreError.snapshotCheckpointUnavailable }
            #expect(generation == 1 && records.count == (empty ? 0 : 1))
            if !empty { try await sync.acknowledge(userID: user, deviceID: device, generation: 1, highestContiguousSequence: 1, receipt: receipt) }
            guard case .ready(_, let ordinary, _, _, _) = try await sync.pull(userID: user, deviceID: device, syncToken: nil, requestedMaxRecords: 20) else { throw V2SyncStoreError.snapshotCheckpointUnavailable }
            #expect(ordinary.isEmpty)
            let first = try await sync.pull(userID: user, deviceID: device, syncToken: .init("discarded-token"), requestedMaxRecords: 20, requireSnapshot: true)
            guard case .resetPreparing(let snapshot, let resetGeneration, _) = first else { throw V2SyncStoreError.snapshotCheckpointUnavailable }
            #expect(resetGeneration == 2)
            #expect(try await sync.pull(userID: user, deviceID: device, syncToken: nil, requestedMaxRecords: 20, requireSnapshot: true) == first)
            #expect(try await sync.pull(userID: user, deviceID: device, syncToken: nil, requestedMaxRecords: 20) == first)
            #expect(try await count("im_v2.device_snapshot_resets", on: sql) == 1)
            let builder = PostgresV2SnapshotArtifactBuilder(database: resources.database(.psql))
            while try await builder.runOnce(now: now).claimed { try Task.checkCancellation() }
            guard case .resetRequired(let published, let publishedGeneration, let base, _) = try await sync.pull(userID: user, deviceID: device, syncToken: nil, requestedMaxRecords: 20, requireSnapshot: true) else { throw V2SyncStoreError.snapshotCheckpointUnavailable }
            #expect(published == snapshot && publishedGeneration == 2 && base == (empty ? 0 : 1))
            let manifest = try await sync.fetchSnapshotManifest(userID: user, deviceID: device, snapshotID: published, generation: publishedGeneration)
            #expect(manifest.totalItems == (empty ? 0 : 1))
            #expect(try await count("im_v2.device_snapshot_resets", on: sql) == 1)
            try await sync.acknowledgeSnapshot(userID: user, deviceID: device, snapshotID: snapshot, generation: 2, baseSequence: base, receipt: manifest.receipt)
            try await sync.acknowledgeSnapshot(userID: user, deviceID: device, snapshotID: snapshot, generation: 2, baseSequence: base, receipt: manifest.receipt)
            guard case .ready(let resumedGeneration, let resumedRecords, _, _, _) = try await sync.pull(userID: user, deviceID: device, syncToken: manifest.nextSyncToken, requestedMaxRecords: 20) else { throw V2SyncStoreError.snapshotCheckpointUnavailable }
            #expect(resumedGeneration == 2 && resumedRecords.isEmpty)
            try await sql.raw("INSERT INTO im_v2.revoked_device_projection_tombstones (user_id, device_id, revoked_at) VALUES (\(bind: userUUID), \(bind: deviceUUID), \(bind: now))").run()
            await #expect(throws: V2SyncStoreError.deviceRevoked) {
                try await sync.pull(userID: user, deviceID: device, syncToken: nil, requestedMaxRecords: 20, requireSnapshot: true)
            }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("explicit empty group policy and permanent proof survive housekeeping", arguments: [V2GroupCapacityClass.standard, .large])
    func groupPolicySurvivesReceiptCleanup(capacityClass: V2GroupCapacityClass) async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            // The writer and policy-baseline reader run on separate tasks.
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(capacityClass: capacityClass, on: sql)
            // This scenario now includes four additional concurrent writes;
            // provision its window for both real writes and batched credits.
            try await sql.raw("UPDATE im_v2.room_admission SET command_window_limit = 20").run()
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET command_window_limit = 20").run()
            let baselineStore = PostgresV2GroupRolePolicyBaselineStore(database: resources.database(.psql))
            let originalBaseline = try await baselineStore.readRolePolicyBaseline(roomID: roomID, actorUserID: senderID)
            #expect(originalBaseline.permissionRevision == 1)
            #expect(originalBaseline.adminPermissions == V2GroupPermissionDefaults.permissions(for: .admin))
            #expect(originalBaseline.memberPermissions == V2GroupPermissionDefaults.permissions(for: .member))
            try await sql.raw("DELETE FROM im_v2.room_owner_routes WHERE room_id = \(bind: roomUUID)").run()
            await #expect(throws: V2GroupRolePolicyBaselineError.actorNotMember) {
                try await baselineStore.readRolePolicyBaseline(roomID: roomID, actorUserID: .init(uuid: UUID()))
            }
            await #expect(throws: V2GroupRolePolicyBaselineError.roomNotFound) {
                try await baselineStore.readRolePolicyBaseline(roomID: .init(uuid: UUID()), actorUserID: senderID)
            }
            try await V2SchemaReadiness.verify(database: resources.database(.psql))
            try await assertSQLSchemaGate(true, on: sql)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").run()
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 20,    retryAfterSeconds: 3))
            let writer = PostgresV2RoomWriteStore(database: resources.database(.psql), strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled, shardAdmissionCommandCreditPool: .init(database: resources.database(.psql), batchSize: 2))
            func request() throws -> V2RoomWriteRequest {
                try .init(command: .init(roomID: roomID, senderUserID: .init(uuid: memberThreeUUID), clientMessageID: .init(uuid: UUID()), text: "permission boundary", limits: .init(maxUTF8Bytes: 64)), capacityProfile: profile, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now)
            }
            #expect(try await v2ResolvedGroupPermissions(roomID: roomUUID, role: .member, sql: sql) == nil)
            if capacityClass == .large {
                let accepted = try await writer.acceptAtomically(requests: [request(), request()])
                #expect(accepted.count == 2 && accepted.allSatisfy { $0.acceptanceReceipt != nil })
            } else {
                let value = try request()
                #expect(try await writer.accept(command: value.command, capacityProfile: profile, identifiers: value.identifiers, now: now).acceptanceReceipt != nil)
            }
            let initialMessages = try await count("im_v2.messages", on: sql)
            let service = MembershipTypedGroupFixture(database: resources.database(.psql), capacityProfile: profile, now: { now })
            guard case .applied = try await service.setRolePermissions(actorUserID: senderID, command: .init(operationID: .init(uuid: UUID()), roomID: roomID, role: .member, permissions: [], expectedRevision: 1)) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            guard case .applied = try await service.setRolePermissions(actorUserID: senderID, command: .init(operationID: .init(uuid: UUID()), roomID: roomID, role: .admin, permissions: [.inviteMembers], expectedRevision: 2)) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            func assertDenied() async throws {
                #expect(try await v2ResolvedGroupPermissions(roomID: roomUUID, role: .member, sql: sql) == [])
                #expect(try await v2ResolvedGroupPermissions(roomID: roomUUID, role: .admin, sql: sql) == [.inviteMembers])
                #expect(try await v2ResolvedGroupPermissions(roomID: roomUUID, role: .owner, sql: sql) == nil)
                let value = try request()
                await #expect(throws: V2RoomWriteStoreError.actorNotEligible) {
                    try await writer.accept(command: value.command, capacityProfile: profile, identifiers: value.identifiers, now: now)
                }
                if capacityClass == .large {
                    await #expect(throws: V2AtomicRoomWriteBatchError(reason: .authorizationState, isolatedRequestIndices: [0, 1])) {
                        try await writer.acceptAtomically(requests: [request(), request()])
                    }
                }
                #expect(try await count("im_v2.messages", on: sql) == initialMessages)
            }
            try await assertDenied()
            let explicitBaseline = try await baselineStore.readRolePolicyBaseline(roomID: roomID, actorUserID: senderID)
            #expect(explicitBaseline.permissionRevision == 3)
            #expect(explicitBaseline.memberPermissions.isEmpty)
            #expect(explicitBaseline.adminPermissions == [.inviteMembers])
            // Permanent original-operation proofs and current role policies both
            // survive control and activation-fenced room maintenance.
            let report = try await V2ControlPlaneHousekeepingWorker(store: PostgresV2ControlPlaneHousekeepingStore(database: resources.database(.psql)), now: { now }).runOnce(limit: 65_536)
            #expect(report.purgedIdempotencyRows == 0)
            #expect(try await count("im_v2.group_capability_receipts WHERE kind = 'groupPermission'", on: sql) == 2)
            let roomReport = try await purgeRoomBookkeeping(database: resources.database(.psql), roomID: roomUUID, now: now)
            #expect(roomReport.deletedOperationRows == 0)
            #expect(try await count("im_v2.group_capability_receipts WHERE kind = 'groupPermission'", on: sql) == 2)
            #expect(try await count("im_v2.group_role_policies", on: sql) == 2)
            #expect(try await baselineStore.readRolePolicyBaseline(roomID: roomID, actorUserID: senderID) == explicitBaseline)
            try await assertDenied()

            try await V2SchemaReadiness.verify(database: resources.database(.psql))
            try await assertSQLSchemaGate(true, on: sql)
            try await sql.raw("ALTER TABLE im_v2.group_role_policies DROP CONSTRAINT group_role_policies_role_check").run()
            await #expect(throws: V2SchemaReadinessError.self) { try await V2SchemaReadiness.verify(database: resources.database(.psql)) }
            try await assertSQLSchemaGate(false, on: sql)
            try await sql.raw("ALTER TABLE im_v2.group_role_policies ADD CONSTRAINT group_role_policies_role_check CHECK (role IN ('admin', 'member'))").run()
            // A new explicit grant can still replace the durable empty policy.
            guard case .applied = try await service.setRolePermissions(actorUserID: senderID, command: .init(operationID: .init(uuid: UUID()), roomID: roomID, role: .member, permissions: [.sendMessages], expectedRevision: 3)) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let permitted = try request()
            #expect(try await writer.accept(command: permitted.command, capacityProfile: profile, identifiers: permitted.identifiers, now: now).acceptanceReceipt != nil)
            #expect(try await count("im_v2.messages", on: sql) == initialMessages + 1)
            let grantedBaseline = try await baselineStore.readRolePolicyBaseline(roomID: roomID, actorUserID: senderID)
            #expect(grantedBaseline.permissionRevision == 4)
            #expect(grantedBaseline.memberPermissions == [.sendMessages])
            #expect(grantedBaseline.adminPermissions == [.inviteMembers])
            // Real policy commits and baseline reads may overlap. Every
            // observed revision must match its complete effective policy.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for revision in UInt64(5)...8 {
                        let permissions: Set<V2GroupPermission> = revision.isMultiple(of: 2) ? [.sendMessages] : []
                        let result = try await service.setRolePermissions(actorUserID: senderID, command: .init(operationID: .init(uuid: UUID()), roomID: roomID, role: .member, permissions: permissions, expectedRevision: revision - 1))
                        guard case .applied = result else {
                            Issue.record("Concurrent policy commit at revision \(revision) returned \(result)")
                            throw V2GroupCapabilitiesStoreError.corruptPersistenceState
                        }
                    }
                }
                group.addTask {
                    for _ in 0..<32 {
                        let read = try await baselineStore.readRolePolicyBaseline(roomID: roomID, actorUserID: senderID)
                        #expect((4...8).contains(read.permissionRevision))
                        #expect(read.memberPermissions == (read.permissionRevision.isMultiple(of: 2) ? [.sendMessages] : []))
                        #expect(read.adminPermissions == [.inviteMembers])
                    }
                }
                try await group.waitForAll()
            }
            let afterConcurrentWrites = try await baselineStore.readRolePolicyBaseline(roomID: roomID, actorUserID: senderID)
            #expect(afterConcurrentWrites.permissionRevision == 8)
            // A read after removal must not reuse the previous authorized
            // baseline; rejoining acquires a distinct membership fence.
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = membership_revision + 1 WHERE room_id = \(bind: roomUUID)").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision = (SELECT membership_revision FROM im_v2.rooms WHERE room_id = \(bind: roomUUID)) WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").run()
            await #expect(throws: V2GroupRolePolicyBaselineError.actorNotMember) {
                try await baselineStore.readRolePolicyBaseline(roomID: roomID, actorUserID: senderID)
            }
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = membership_revision + 1 WHERE room_id = \(bind: roomUUID)").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision = NULL, joined_revision = (SELECT membership_revision FROM im_v2.rooms WHERE room_id = \(bind: roomUUID)) WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").run()
            let rejoined = try await baselineStore.readRolePolicyBaseline(roomID: roomID, actorUserID: senderID)
            #expect(rejoined.membershipRevision == grantedBaseline.membershipRevision + 2)
            #expect(rejoined.permissionRevision == afterConcurrentWrites.permissionRevision)
            #expect(rejoined.memberPermissions == grantedBaseline.memberPermissions)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("group controls preserve source versions in room log without personal copies", arguments: [V2GroupCapacityClass.standard, .large])
    func groupCapabilitySourceVersions(capacityClass: V2GroupCapacityClass) async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(capacityClass: capacityClass, on: sql)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 1 WHERE room_id = \(bind: roomUUID)").run()
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3))
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: resources.database(.psql)), capacityProfile: profile, limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "group controls")) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let service = MembershipTypedGroupFixture(database: resources.database(.psql), capacityProfile: profile, now: { now })
            let pin = V2PinnedMessageCommand(operationID: .init(uuid: UUID()), roomID: roomID, messageID: message.messageID, isPinned: true)
            guard case .applied(let pinned) = try await service.setPinnedMessage(actorUserID: senderID, command: pin) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            #expect(pinned.roomSequence == 2)
            #expect(try await service.setPinnedMessage(actorUserID: senderID, command: pin) == .idempotent(pinned))
            let announcement = try V2GroupAnnouncementCommand(operationID: .init(uuid: UUID()), roomID: roomID, body: "版本公告", expectedRevision: 0)
            guard case .applied(let announced) = try await service.setAnnouncement(actorUserID: senderID, command: announcement) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            #expect(announced.roomSequence == 3 && announced.revision == 1)
            #expect(try await service.setAnnouncement(actorUserID: senderID, command: announcement) == .idempotent(announced))
            let permissions = try V2GroupRolePermissionsCommand(operationID: .init(uuid: UUID()), roomID: roomID, role: .member, permissions: [.sendMessages, .inviteMembers], expectedRevision: 1)
            guard case .applied(let policy) = try await service.setRolePermissions(actorUserID: senderID, command: permissions) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            #expect(policy.roomSequence == 4 && policy.revision == 2)
            #expect(try await service.setRolePermissions(actorUserID: senderID, command: permissions) == .idempotent(policy))
            let role = try V2GroupMemberRoleCommand(operationID: .init(uuid: UUID()), roomID: roomID, targetUserID: .init(uuid: memberTwoUUID), role: .admin, expectedMembershipRevision: 1)
            guard case .applied(let promoted) = try await service.changeMemberRole(actorUserID: senderID, command: role) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            #expect(promoted.roomSequence == 5 && promoted.membershipRevision == 2)
            #expect(try await service.changeMemberRole(actorUserID: senderID, command: role) == .idempotent(promoted))
            guard case .applied(let unpinned) = try await service.setPinnedMessage(actorUserID: senderID, command: .init(operationID: .init(uuid: UUID()), roomID: roomID, messageID: message.messageID, isPinned: false)) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            #expect(unpinned.roomSequence == 6 && !unpinned.isPinned)
            let empty = try V2GroupRolePermissionsCommand(operationID: .init(uuid: UUID()), roomID: roomID, role: .member, permissions: [], expectedRevision: 2)
            guard case .applied(let cleared) = try await service.setRolePermissions(actorUserID: senderID, command: empty) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            #expect(cleared.roomSequence == 7 && cleared.permissions.isEmpty)
            #expect(try await service.setRolePermissions(actorUserID: senderID, command: empty) == .idempotent(cleared))
            let conflict = try V2GroupRolePermissionsCommand(operationID: permissions.operationID, roomID: roomID, role: .member, permissions: [], expectedRevision: 1)
            #expect(try await service.setRolePermissions(actorUserID: senderID, command: conflict) == .idempotencyConflict)
            let stale = try V2GroupAnnouncementCommand(operationID: .init(uuid: UUID()), roomID: roomID, body: "stale", expectedRevision: 0)
            #expect(try await service.setAnnouncement(actorUserID: senderID, command: stale) == .revisionConflict)

            struct Source: Decodable {
                let eventID: UUID; let roomSequence: Int64; let payloadJSON: String
                enum CodingKeys: String, CodingKey { case eventID = "event_id", roomSequence = "room_sequence", payloadJSON = "payload_json" }
            }
            struct Version: Decodable { let roomSequence: Int64; enum CodingKeys: String, CodingKey { case roomSequence = "room_sequence" } }
            let sources = try await sql.raw("SELECT event_id, room_sequence, payload::text AS payload_json FROM im_v2.room_events WHERE room_id = \(bind: roomUUID) AND event_type IN ('message.pinned_changed', 'group.announcement_changed', 'group.role_permissions_changed', 'group.member_role_changed') ORDER BY room_sequence").all(decoding: Source.self)
            #expect(sources.map(\.roomSequence) == [2, 3, 4, 5, 6, 7])
            for source in sources {
                #expect(try JSONDecoder().decode(Version.self, from: Data(source.payloadJSON.utf8)).roomSequence == source.roomSequence)
            }
            let page = try await PostgresV2GroupEventLogStore(database: resources.database(.psql)).pull(roomID: roomID, actorUserID: senderID, afterRoomSequence: 1, pageSize: 20)
            #expect(page.events.count == sources.count && page.nextRoomSequence == 7 && !page.hasMore)
            for entry in page.events {
                let source = try #require(sources.first { $0.eventID == entry.sourceEventID.uuidValue })
                #expect(entry.projectionKind == "group_capability" && entry.roomSequence == UInt64(source.roomSequence))
                #expect(try JSONDecoder().decode(Version.self, from: entry.payload).roomSequence == source.roomSequence)
                #expect(try (JSONSerialization.jsonObject(with: entry.payload) as? NSDictionary) == (JSONSerialization.jsonObject(with: Data(source.payloadJSON.utf8)) as? NSDictionary))
            }
            #expect(try await count("im_v2.user_sync_log", on: sql) == 0)
            #expect(try await count("im_v2.group_capability_receipts WHERE kind = 'pinnedMessage'", on: sql) == 2)
            #expect(try await count("im_v2.group_capability_receipts WHERE kind = 'groupAnnouncement'", on: sql) == 1)
            #expect(try await count("im_v2.group_capability_receipts WHERE kind = 'groupPermission'", on: sql) == 2)
            #expect(try await count("im_v2.group_capability_receipts WHERE kind = 'groupRole'", on: sql) == 1)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("message reactions and withdrawal persist ordered room events without personal copies")
    func reactionWritesSetChangeAndDeliversIt() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)

            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: resources.database(.psql)), capacityProfile: try .init(id: "standard", limits: profile), limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "react to me")) else { Issue.record("expected accepted message"); return }
            guard case .acquired(let lease)=try await PostgresV2RoomActivationStore(database:resources.database(.psql)).acquire(roomID:roomID,owner:.init(shardID:"room-a",epoch:0),host:.init(hostID:.init("reaction-events"),incarnationID:UUID()),duration:.init(30_000)) else { throw CancellationError() }
            let reaction=PostgresV2MessageReactionOperationStore(database:resources.database(.psql),clock:{now})
            let request=try V2MessageReactionOperationCommand(command:.init(roomID:roomID,actorUserID:senderID,operationID:.init(uuid:UUID()),messageID:message.messageID,reaction:"👍",action:.add),expectedReactionRevision:0,firstSubmissionDeadlineMilliseconds:UInt64(now.timeIntervalSince1970*1000)+60_000)
            let first=try await reaction.change(request,token:lease.token,capacityProfile:.init(id:"standard",limits:profile),eventID:.init(uuid:UUID()),now:now.addingTimeInterval(1))
            guard case .receipt(let original)=first,case .committed(let commit)=original.outcome,let change=commit.event else { throw CancellationError() }
            let replay=try await reaction.change(request,token:lease.token,capacityProfile:.init(id:"standard",limits:profile),eventID:.init(uuid:UUID()),now:now.addingTimeInterval(2))

            let reactionState = try #require(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.message_reactions WHERE message_id = \(bind: UUID(uuidString: message.messageID.rawValue)!) AND actor_user_id = \(bind: senderUUID) AND reaction = '👍'").first(decoding: CountRow.self))
            let event = try #require(try await sql.raw("SELECT event_type, payload->>'message_id' AS message_id, payload->>'reaction' AS reaction, payload->>'action' AS action FROM im_v2.room_events WHERE event_id = \(bind: UUID(uuidString: change.eventID.rawValue)!)").first(decoding: ReactionEventRow.self))
            let delivered = try #require(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE source_event_id = \(bind: UUID(uuidString: change.eventID.rawValue)!)").first(decoding: CountRow.self))
            #expect(replay == .receipt(original))
            #expect(change.roomSequence == 2)
            #expect(reactionState.value == 1)
            #expect(event.eventType == "message.reaction_changed")
            #expect(event.messageID == message.messageID.rawValue)
            #expect(event.reaction == "👍")
            #expect(event.action == "add")
            #expect(delivered.value == 0)
            #expect(try await count("im_v2.message_reaction_receipts", on: sql) == 1)

            let removal=try V2MessageReactionOperationCommand(command:.init(roomID:roomID,actorUserID:senderID,operationID:.init(uuid:UUID()),messageID:message.messageID,reaction:"👍",action:.remove),expectedReactionRevision:1,firstSubmissionDeadlineMilliseconds:UInt64(now.timeIntervalSince1970*1000)+60_000)
            guard case .receipt(let removedReceipt)=try await reaction.change(removal,token:lease.token,capacityProfile:.init(id:"standard",limits:profile),eventID:.init(uuid:UUID()),now:now.addingTimeInterval(4)),case .committed(let removedCommit)=removedReceipt.outcome,let removed=removedCommit.event else { throw CancellationError() }
            #expect(try await count("im_v2.message_reactions", on: sql) == 0)
            let removedEvent = try #require(try await sql.raw("SELECT event_type, payload->>'message_id' AS message_id, payload->>'reaction' AS reaction, payload->>'action' AS action FROM im_v2.room_events WHERE event_id = \(bind: removed.eventID.uuidValue!)").first(decoding: ReactionEventRow.self))
            #expect(removedEvent.action == "remove")
            #expect(removed.roomSequence > change.roomSequence)
            let withdrawal = V2MessageWithdrawalService(store: PostgresV2MessageWithdrawalStore(database: resources.database(.psql)), capacityProfile: try .init(id: "standard", limits: profile), now: { now.addingTimeInterval(8) })
            guard case .withdrawn(let withdrawn) = try await withdrawal.withdraw(.init(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), messageID: message.messageID, expectedMessageRevision: 1)) else { throw V2UserProjectionWorkerError.invalidPayload }
            #expect(withdrawn.roomSequence > removed.roomSequence)
            #expect(withdrawn.messageRevision == 2)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 0)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown(); throw error
        }
    }

    @Test("message edit atomically updates content and room log, and replays its canonical result")
    func editWritesRevisionFencedTransaction() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)
            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: resources.database(.psql)), capacityProfile: try .init(id: "standard", limits: profile), limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "before")) else { Issue.record("expected accepted message"); return }
            let edit = MembershipTypedEditFixture(database: resources.database(.psql), capacityProfile: try .init(id: "standard", limits: profile), maximumTextUTF8Bytes: 64, identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000033")! }), now: { now.addingTimeInterval(1) })
            let request = V2AuthenticatedMessageEdit(roomID: roomID, actorUserID: senderID, operationID: try .init("00000000-0000-0000-0000-000000000032"), messageID: message.messageID, expectedMessageRevision: 1, text: "after")
            let first = try await edit.edit(request)
            guard case .edited(let result) = first else { Issue.record("expected edit result"); return }
            let replay = try await edit.edit(request)
            let persisted = try #require(try await sql.raw("SELECT text_body, content_revision FROM im_v2.messages WHERE message_id = \(bind: UUID(uuidString: message.messageID.rawValue)!)").first(decoding: EditMessageStateRow.self))
            let event = try #require(try await sql.raw("SELECT event_type, payload->>'text' AS text, payload->>'message_revision' AS revision FROM im_v2.room_events WHERE event_id = \(bind: UUID(uuidString: result.eventID.rawValue)!)").first(decoding: EditEventRow.self))
            let delivered = try #require(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE source_event_id = \(bind: UUID(uuidString: result.eventID.rawValue)!)").first(decoding: CountRow.self))
            #expect(replay == .idempotent(result))
            #expect(result.messageRevision == 2)
            #expect(result.roomSequence == 2)
            #expect(persisted.text == "after")
            #expect(persisted.revision == 2)
            #expect(event.eventType == "message.edited")
            #expect(event.text == "after")
            #expect(event.revision == "2")
            #expect(delivered.value == 0)
            #expect(try await count("im_v2.message_mutation_receipts WHERE kind = 'editMessage' AND receipt->'outcome' ? 'committed'", on: sql) == 1)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown(); throw error
        }
    }

    @Test("send and edit share current room publication authorization", arguments: ["frozen", "muted", "removed", "permission", "inactive"], [V2GroupCapacityClass.standard, .large])
    func editsRespectCurrentContentWriteAuthorization(_ restriction: String, capacityClass: V2GroupCapacityClass) async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(capacityClass: capacityClass, on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3))
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: resources.database(.psql)), capacityProfile: profile, limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "original")) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let edit = MembershipTypedEditFixture(database: resources.database(.psql), capacityProfile: profile, maximumTextUTF8Bytes: 64, now: { now.addingTimeInterval(1) })
            let original = V2AuthenticatedMessageEdit(roomID: roomID, actorUserID: senderID, operationID: try .init(UUID().uuidString), messageID: message.messageID, expectedMessageRevision: 1, text: "authorized edit")
            guard case .edited(let acceptedEdit) = try await edit.edit(original) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let deniedEdit = V2MessageEditService(store: PostgresV2MessageEditStore(database: resources.database(.psql)), capacityProfile: profile, maximumTextUTF8Bytes: 64, now: { now.addingTimeInterval(1) })
            let expected: V2RoomWriteStoreError
            switch restriction {
            case "frozen":
                try await sql.raw("UPDATE im_v2.rooms SET frozen_at = \(bind: now), frozen_by_user_id = \(bind: memberTwoUUID) WHERE room_id = \(bind: roomUUID)").run()
                expected = .roomFrozen
            case "muted":
                try await sql.raw("INSERT INTO im_v2.room_member_mutes (room_id, user_id, mute_until, actor_user_id, operation_id, created_at) VALUES (\(bind: roomUUID), \(bind: senderUUID), \(bind: now.addingTimeInterval(300)), \(bind: memberTwoUUID), \(bind: UUID()), \(bind: now))").run()
                expected = .actorMuted
            case "removed":
                try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 1 WHERE room_id = \(bind: roomUUID)").run()
                try await sql.raw("UPDATE im_v2.room_memberships SET left_revision = 1 WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").run()
                expected = .actorNotEligible
            case "permission":
                try await sql.raw("INSERT INTO im_v2.group_role_permissions (room_id, role, permission) VALUES (\(bind: roomUUID), 'member', 'invite_members')").run()
                expected = .actorNotEligible
            case "inactive":
                try await sql.raw("UPDATE im_v2.public_user_profiles SET state = 'suspended' WHERE user_id = \(bind: senderUUID)").run()
                expected = .actorNotEligible
            default:
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let before = try await directWriteArtifactCounts(sql: sql)
            func admissionSnapshot() async throws -> PublicationAdmissionSnapshot {
                try #require(try await sql.raw("""
                    SELECT (SELECT sum(command_window_used)::bigint FROM im_v2.room_admission) AS room,
                           (SELECT sum(command_window_used)::bigint FROM im_v2.shard_admission_pools) AS shard,
                           (SELECT sum(room_sequence)::bigint FROM im_v2.rooms) AS sequence
                    """).first(decoding: PublicationAdmissionSnapshot.self))
            }
            let admissionBefore = try await admissionSnapshot()
            await #expect(throws: expected) {
                _ = try await deniedEdit.edit(.init(roomID: roomID, actorUserID: senderID, operationID: .init(UUID().uuidString), messageID: message.messageID, expectedMessageRevision: 2, text: "must not publish"))
            }
            await #expect(throws: expected) {
                _ = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(UUID().uuidString), text: "must not publish"))
            }
            #expect(try await edit.edit(original) == .idempotent(acceptedEdit))
            #expect(try await send.send(.init(roomID: roomID, actorUserID: senderID,
                clientMessageID: clientMessageID, text: "original")) == .idempotent(message.receipt))
            #expect(try await send.send(.init(roomID: roomID, actorUserID: senderID,
                clientMessageID: clientMessageID, text: "changed replay")) == .idempotencyConflict)
            #expect(try await edit.edit(.init(roomID: roomID, actorUserID: senderID,
                operationID: original.operationID, messageID: message.messageID,
                expectedMessageRevision: 1, text: "changed replay")) == .idempotencyConflict)
            let batcher = V2SendMessageAdmissionBatcher(store: PostgresV2RoomWriteStore(database: resources.database(.psql)),
                configuration: .init(maximumBatchSize: 3, maximumDelay: .milliseconds(10)))
            let batched = V2SendMessageService(store: PostgresV2RoomWriteStore(database: resources.database(.psql)),
                capacityProfile: profile, limits: try .init(maxUTF8Bytes: 64), batcher: batcher, now: { now })
            // The admission queue must isolate a rejected new command from
            // completed replay/conflict results, including scalar fallbacks.
            async let replay = batched.send(.init(roomID: roomID, actorUserID: senderID,
                clientMessageID: clientMessageID, text: "original"))
            async let conflict = batched.send(.init(roomID: roomID, actorUserID: senderID,
                clientMessageID: clientMessageID, text: "changed replay"))
            async let rejected: Void = { () async -> Void in
                await #expect(throws: expected) {
                    try await batched.send(.init(roomID: roomID, actorUserID: senderID,
                        clientMessageID: .init(uuid: UUID()), text: "must not publish"))
                }
            }()
            let (replayed, conflicted, _) = try await (replay, conflict, rejected)
            #expect(replayed == .idempotent(message.receipt))
            #expect(conflicted == .idempotencyConflict)
            #expect(try await admissionSnapshot() == admissionBefore)
            #expect(try await count("im_v2.message_send_completions", on: sql) == 1)
            #expect(try await directWriteArtifactCounts(sql: sql) == before)
            let persisted = try #require(try await sql.raw("SELECT text_body, content_revision FROM im_v2.messages WHERE message_id = \(bind: UUID(uuidString: message.messageID.rawValue)!)").first(decoding: EditMessageStateRow.self))
            #expect(persisted.text == "authorized edit")
            #expect(persisted.revision == 2)
            #expect(try await count("im_v2.message_mutation_receipts WHERE kind = 'editMessage' AND receipt->'outcome' ? 'committed'", on: sql) == 1)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("editing a claimed message resets review work to the new content revision")
    func editReplacesTheClaimedContentReviewJob() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let limits = try RoomCapacityProfile(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10,
                  retryAfterSeconds: 3
            )
            let profile = try V2CapacityProfile(id: "standard", limits: limits)
            let send = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: resources.database(.psql)),
                capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64),
                now: { now }
            )
            guard case .accepted(let message) = try await send.send(.init(
                roomID: roomID,
                actorUserID: senderID,
                clientMessageID: clientMessageID,
                text: "before review reset"
            )) else {
                Issue.record("expected accepted message")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }

            let oldToken = UUID(uuidString: "00000000-0000-0000-0000-000000000d21")!
            let reviewStore = PostgresV2ContentReviewStore(database: resources.database(.psql), makeUUID: { oldToken })
            let oldLease = try #require(try await reviewStore.claimPending(now: now.addingTimeInterval(1), leaseDuration: 30, limit: 1).first)
            #expect(oldLease.input.messageID == message.messageID)
            #expect(oldLease.input.contentRevision == 1)
            #expect(oldLease.input.text == "before review reset")

            let edit = V2MessageEditService(
                store: PostgresV2MessageEditStore(database: resources.database(.psql)),
                capacityProfile: profile,
                maximumTextUTF8Bytes: 64,
                identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000d22")! }),
                now: { now.addingTimeInterval(2) }
            )
            guard case .edited(let editResult) = try await edit.edit(.init(
                roomID: roomID,
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000d23"),
                messageID: message.messageID,
                expectedMessageRevision: 1,
                text: "after review reset"
            )) else {
                Issue.record("expected edit")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            #expect(editResult.messageRevision == 2)

            let messageUUID = try #require(UUID(uuidString: message.messageID.rawValue))
            let resetJob = try #require(try await sql.raw("""
                SELECT state, expected_content_revision, decision,
                       claim_token IS NULL AS claim_released,
                       lease_expires_at IS NULL AS lease_released,
                       completed_at IS NULL AS is_uncompleted
                FROM im_v2.content_review_jobs
                WHERE message_id = \(bind: messageUUID)
                """).first(decoding: ContentReviewResetAssertionRow.self))
            #expect(resetJob.state == "pending")
            #expect(resetJob.revision == 2)
            #expect(resetJob.decision == nil)
            #expect(resetJob.claimReleased)
            #expect(resetJob.leaseReleased)
            #expect(resetJob.isUncompleted)

            // The pre-edit worker loses authority, but its late check must
            // not mark the replacement job superseded or release it.
            #expect(try await reviewStore.validateAndRenew(oldLease, now: now.addingTimeInterval(3), leaseDuration: 10) == .lostLease)
            let preserved = try #require(try await sql.raw("""
                SELECT state, expected_content_revision, decision,
                       claim_token IS NULL AS claim_released,
                       lease_expires_at IS NULL AS lease_released,
                       completed_at IS NULL AS is_uncompleted
                FROM im_v2.content_review_jobs
                WHERE message_id = \(bind: messageUUID)
                """).first(decoding: ContentReviewResetAssertionRow.self))
            #expect(preserved == resetJob)

            let replacementStore = PostgresV2ContentReviewStore(
                database: resources.database(.psql),
                makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000d24")! }
            )
            let replacementLease = try #require(try await replacementStore.claimPending(now: now.addingTimeInterval(3), leaseDuration: 30, limit: 1).first)
            #expect(replacementLease.input.messageID == message.messageID)
            #expect(replacementLease.input.contentRevision == 2)
            #expect(replacementLease.input.text == "after review reset")

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("a tombstone rejects an older edit without creating replacement delivery work")
    func withdrawalWinsOverOlderEdit() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)

            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let capacityProfile = try V2CapacityProfile(id: "standard", limits: profile)
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: resources.database(.psql)), capacityProfile: capacityProfile, limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "before withdrawal")) else { Issue.record("expected accepted message"); return }

            let withdrawal = MembershipTypedWithdrawalFixture(
                database: resources.database(.psql),
                capacityProfile: capacityProfile,
                identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000036")! }),
                now: { now.addingTimeInterval(1) }
            )
            let withdrawalRequest = V2AuthenticatedMessageWithdrawal(
                roomID: roomID,
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000035"),
                messageID: message.messageID,
                expectedMessageRevision: 1
            )
            guard case .withdrawn = try await withdrawal.withdraw(withdrawalRequest) else { Issue.record("expected withdrawal"); return }

            let edit = MembershipTypedEditFixture(
                database: resources.database(.psql),
                capacityProfile: capacityProfile,
                maximumTextUTF8Bytes: 64,
                identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000038")! }),
                now: { now.addingTimeInterval(2) }
            )
            let olderEdit = try await edit.edit(.init(
                roomID: roomID,
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000037"),
                messageID: message.messageID,
                expectedMessageRevision: 1,
                text: "must not replace tombstone"
            ))
            let persisted = try #require(try await sql.raw("SELECT text_body, content_revision, withdrawn_at IS NOT NULL AS is_withdrawn FROM im_v2.messages WHERE message_id = \(bind: UUID(uuidString: message.messageID.rawValue)!)").first(decoding: TombstonedEditStateRow.self))

            #expect(olderEdit == .alreadyWithdrawn)
            #expect(try await count("im_v2.message_mutation_receipts WHERE kind = 'editMessage'", on: sql) == 1)
            #expect(persisted.text == "before withdrawal")
            #expect(persisted.revision == 2)
            #expect(persisted.isWithdrawn)
            #expect(try await count("im_v2.message_mutation_receipts WHERE kind = 'editMessage' AND receipt->'outcome' ? 'committed'", on: sql) == 0)
            #expect(try await count("im_v2.room_events", on: sql) == 2)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown(); throw error
        }
    }

    @Test("concurrent edit and withdrawal commit exactly one terminal message mutation")
    func concurrentEditAndWithdrawalDoNotCreateConflictingHistory() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)

            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let capacityProfile = try V2CapacityProfile(id: "standard", limits: profile)
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: resources.database(.psql)), capacityProfile: capacityProfile, limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "original")) else { Issue.record("expected accepted message"); return }

            let edit = MembershipTypedEditFixture(
                database: resources.database(.psql),
                capacityProfile: capacityProfile,
                maximumTextUTF8Bytes: 64,
                identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000040")! }),
                now: { now.addingTimeInterval(1) }
            )
            let editRequest = V2AuthenticatedMessageEdit(
                roomID: roomID,
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000039"),
                messageID: message.messageID,
                expectedMessageRevision: 1,
                text: "edited"
            )
            let withdrawal = MembershipTypedWithdrawalFixture(
                database: resources.database(.psql),
                capacityProfile: capacityProfile,
                identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000042")! }),
                now: { now.addingTimeInterval(1) }
            )
            let withdrawalRequest = V2AuthenticatedMessageWithdrawal(
                roomID: roomID,
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000041"),
                messageID: message.messageID,
                expectedMessageRevision: 1
            )

            let outcomes = await withTaskGroup(of: MessageMutationRaceOutcome.self, returning: [MessageMutationRaceOutcome].self) { group in
                group.addTask {
                    do {
                        switch try await edit.edit(editRequest) {
                        case .edited: return .edited
                        case .alreadyWithdrawn: return .alreadyWithdrawn
                        case .revisionConflict: return .revisionConflict
                        default: return .unexpectedOutcome
                        }
                    } catch { return .unexpectedFailure }
                }
                group.addTask {
                    do {
                        switch try await withdrawal.withdraw(withdrawalRequest) {
                        case .withdrawn: return .withdrawn
                        case .alreadyWithdrawn: return .alreadyWithdrawn
                        case .revisionConflict: return .revisionConflict
                        default: return .unexpectedOutcome
                        }
                    } catch { return .unexpectedFailure }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            let state = try #require(try await sql.raw("SELECT text_body, content_revision, withdrawn_at IS NOT NULL AS is_withdrawn FROM im_v2.messages WHERE message_id = \(bind: UUID(uuidString: message.messageID.rawValue)!)").first(decoding: TombstonedEditStateRow.self))

            let editWins = outcomes.filter { $0 == .edited }.count == 1 && outcomes.filter { $0 == .revisionConflict }.count == 1
            let withdrawalWins = outcomes.filter { $0 == .withdrawn }.count == 1 && outcomes.filter { $0 == .alreadyWithdrawn }.count == 1
            #expect(editWins || withdrawalWins)
            #expect(try await count("im_v2.message_mutation_receipts", on: sql) == 2)
            #expect(!outcomes.contains(.unexpectedOutcome))
            #expect(!outcomes.contains(.unexpectedFailure))
            #expect(state.revision == 2)
            #expect(editWins ? state.text == "edited" && !state.isWithdrawn : state.text == "original" && state.isWithdrawn)
            #expect(try await count("im_v2.message_mutation_receipts WHERE kind = 'editMessage' AND receipt->'outcome' ? 'committed'", on: sql) + count("im_v2.message_mutation_receipts WHERE kind = 'withdrawMessage' AND receipt->'outcome' ? 'committed'", on: sql) == 1)
            #expect(try await count("im_v2.room_events", on: sql) == 2)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown(); throw error
        }
    }

    @Test("read receipt is monotonic user state and never creates delivery work")
    func readReceiptDoesNotBecomeASyncAcknowledgement() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            let receiptControlPool = DatabaseID(string: "receipt-control")
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: receiptControlPool)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)
            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: resources.database(.psql)), capacityProfile: try .init(id: "standard", limits: profile), limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "read me")) else { Issue.record("expected accepted message"); return }
            let receipt = V2ReadReceiptService(store: PostgresV2ReadReceiptStore(database: resources.database(.psql)), now: { now.addingTimeInterval(1) })
            let request = V2AuthenticatedReadReceipt(roomID: roomID, actorUserID: senderID, operationID: try .init("00000000-0000-0000-0000-000000000034"), readThroughRoomSequence: message.roomSequence)
            let first = try await receipt.record(request)
            guard case .recorded(let result) = first else { Issue.record("expected receipt"); return }
            let replay = try await receipt.record(request)
            let state = try #require(try await sql.raw("SELECT read_through_room_sequence FROM im_v2.room_read_receipts WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").first(decoding: ReceiptStateAssertionRow.self))
            #expect(replay == .idempotent(result))
            #expect(state.sequence == 1)
            #expect(try await count("im_v2.read_receipt_operations", on: sql) == 1)
            #expect(try await count("im_v2.room_events", on: sql) == 1)
            // 已读回执只把读者自己的水位写回该账号的同步流，绝不产生任何投递投影。
            #expect(try await count("im_v2.user_sync_log WHERE projection_kind <> 'own_read_watermark'", on: sql) == 0)
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.user_sync_log WHERE projection_kind = 'own_read_watermark' AND (payload->>'room_id')::uuid = \(bind: roomUUID)").first(decoding: CountRow.self)?.value == 0)
            #expect(try await count("im_v2.user_state_event_outbox WHERE projection_kind = 'own_read_watermark'", on: sql) == 1)
            guard case .accepted(let secondMessage) = try await send.send(.init(
                roomID: roomID,
                actorUserID: senderID,
                clientMessageID: try .init("00000000-0000-0000-0000-000000000035"),
                text: "read me next"
            )) else {
                Issue.record("expected second accepted message")
                return
            }
            let advancedRequest = V2AuthenticatedReadReceipt(
                roomID: roomID,
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000036"),
                readThroughRoomSequence: secondMessage.roomSequence
            )
            guard case .recorded(let advancedReceipt) = try await receipt.record(advancedRequest)
            else {
                Issue.record("expected advanced receipt")
                return
            }
            #expect(advancedReceipt.readThroughRoomSequence == secondMessage.roomSequence)
            let staleRequest = V2AuthenticatedReadReceipt(
                roomID: roomID,
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000037"),
                readThroughRoomSequence: message.roomSequence
            )
            guard case .recorded(let staleReceipt) = try await receipt.record(staleRequest)
            else {
                Issue.record("expected monotonic stale receipt")
                return
            }
            #expect(staleReceipt.readThroughRoomSequence == secondMessage.roomSequence)
            #expect(try await receipt.record(.init(
                roomID: roomID,
                actorUserID: senderID,
                operationID: staleRequest.operationID,
                readThroughRoomSequence: secondMessage.roomSequence
            )) == .idempotencyConflict)
            let advancedState = try #require(try await sql.raw(
                "SELECT read_through_room_sequence FROM im_v2.room_read_receipts WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)"
            ).first(decoding: ReceiptStateAssertionRow.self))
            #expect(advancedState.sequence == Int64(secondMessage.roomSequence))
            #expect(try await count("im_v2.read_receipt_operations", on: sql) == 3)
            #expect(try await count("im_v2.user_sync_log WHERE projection_kind <> 'own_read_watermark'", on: sql) == 0)
            // Two timestamps inside the same millisecond exercise the cursor
            // precision boundary that previously truncated through Date-ms.
            try await sql.raw("""
                INSERT INTO im_v2.room_read_receipts
                    (room_id, user_id, read_through_room_sequence, updated_at)
                VALUES
                    (\(bind: roomUUID), \(bind: memberTwoUUID), 1,
                     TIMESTAMPTZ '2025-06-15 15:06:41.123100+00'),
                    (\(bind: roomUUID), \(bind: memberThreeUUID), 1,
                     TIMESTAMPTZ '2025-06-15 15:06:41.123900+00')
                """).run()
            let readerStore = PostgresV2ReadReceiptStore(database: resources.database(.psql))
            let batchRequests = try [
                V2ReadReceiptRecordRequest(
                    command: .init(
                        roomID: roomID,
                        actorUserID: senderID,
                        operationID: .init("00000000-0000-0000-0000-000000000038"),
                        readThroughRoomSequence: message.roomSequence
                    ),
                    now: now.addingTimeInterval(2)
                ),
                V2ReadReceiptRecordRequest(
                    command: .init(
                        roomID: roomID,
                        actorUserID: .init(memberTwoUUID.uuidString),
                        operationID: .init("00000000-0000-0000-0000-000000000039"),
                        readThroughRoomSequence: message.roomSequence
                    ),
                    now: now.addingTimeInterval(3)
                ),
                V2ReadReceiptRecordRequest(
                    command: .init(
                        roomID: roomID,
                        actorUserID: .init(memberThreeUUID.uuidString),
                        operationID: .init("00000000-0000-0000-0000-000000000040"),
                        readThroughRoomSequence: secondMessage.roomSequence + 1
                    ),
                    now: now.addingTimeInterval(4)
                ),
            ]
            let batchResults = try await readerStore.recordGroups(batchRequests)
            guard case .success(.handled(.recorded(let batchStale))) = batchResults[0],
                  case .success(.handled(.recorded(let batchMember))) = batchResults[1]
            else {
                Issue.record("expected independent batch receipt successes")
                return
            }
            #expect(batchStale.readThroughRoomSequence == secondMessage.roomSequence)
            #expect(batchMember.readThroughRoomSequence == message.roomSequence)
            #expect(batchResults[2] == .failure(.roomSequenceNotFound))
            let batchReplay = try await readerStore.recordGroups(
                Array(batchRequests.prefix(2))
            )
            guard case .success(.handled(.idempotent(let replayStale))) = batchReplay[0],
                  case .success(.handled(.idempotent(let replayMember))) = batchReplay[1]
            else {
                Issue.record("expected stable batch receipt replay")
                return
            }
            #expect(replayStale == batchStale)
            #expect(replayMember == batchMember)
            await #expect(throws: V2ReadReceiptStoreError.messageNotFound) {
                _ = try await readerStore.readers(
                    roomID: roomID,
                    messageID: try .init("00000000-0000-0000-0000-000000000099"),
                    actorUserID: senderID,
                    cursor: nil,
                    pageSize: 1
                )
            }
            let firstReaders = try await readerStore.readers(
                roomID: roomID, messageID: message.messageID,
                actorUserID: senderID, cursor: nil, pageSize: 1
            )
            #expect(firstReaders.messageID == message.messageID)
            #expect(firstReaders.readers.map(\.userID) == [try .init(memberThreeUUID.uuidString)])
            let readerCursor = try #require(firstReaders.nextCursor)
            let secondReaders = try await readerStore.readers(
                roomID: roomID, messageID: message.messageID,
                actorUserID: senderID, cursor: readerCursor, pageSize: 1
            )
            #expect(secondReaders.readers.map(\.userID) == [try .init(memberTwoUUID.uuidString)])
            #expect(secondReaders.nextCursor == nil)
            let ownerCandidates = try await readerStore.readerCandidates(
                roomID: roomID,
                messageID: message.messageID,
                actorUserID: senderID,
                cursor: nil,
                pageSize: 2
            )
            #expect(ownerCandidates.candidates.map(\.userID) == [
                try .init(memberThreeUUID.uuidString),
                try .init(memberTwoUUID.uuidString),
            ])
            let controlIdentities = try await readerStore.visibleReaderIdentities(
                actorUserID: senderID,
                candidateUserIDs: ownerCandidates.candidates.map(\.userID)
            )
            #expect(Set(controlIdentities.keys) == Set(
                ownerCandidates.candidates.map(\.userID)
            ))
            guard case .handled(.idempotent(let ownerReplay)) = try await readerStore.recordGroup(
                command: .init(
                    roomID: request.roomID,
                    actorUserID: request.actorUserID,
                    operationID: request.operationID,
                    readThroughRoomSequence: request.readThroughRoomSequence
                ),
                now: now.addingTimeInterval(1)
            ) else {
                Issue.record("expected owner-local group receipt replay")
                return
            }
            #expect(ownerReplay == result)
            let directory = PostgresV2RoomMembershipDirectoryStore(database: resources.database(.psql))
            let firstMemberPage = try await directory.list(.init(
                roomID: roomID,
                actorUserID: senderID,
                cursor: nil,
                pageSize: 1
            ))
            let rosterCursor = try #require(firstMemberPage.nextCursor)
            #expect(UUID(uuidString: rosterCursor) == nil)
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 1 WHERE room_id = \(bind: roomUUID)").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision = 1 WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: memberThreeUUID)").run()
            let continuedReaders = try await readerStore.readers(
                roomID: roomID,
                messageID: message.messageID,
                actorUserID: senderID,
                cursor: readerCursor,
                pageSize: 1
            )
            #expect(continuedReaders.readers.map(\.userID) == [try .init(memberTwoUUID.uuidString)])
            #expect(continuedReaders.nextCursor == nil)
            let currentReaders = try await readerStore.readers(
                roomID: roomID,
                messageID: message.messageID,
                actorUserID: senderID,
                cursor: nil,
                pageSize: 10
            )
            #expect(currentReaders.readers.map(\.userID) == [try .init(memberTwoUUID.uuidString)])

            let lateMemberUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000017")!
            let lateMemberID = try UserID(lateMemberUUID.uuidString)
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, revision, created_at, updated_at)
                VALUES
                    (\(bind: lateMemberUUID), 'member017', '后加入成员', 1, \(bind: now), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision)
                VALUES (\(bind: roomUUID), \(bind: lateMemberUUID), 1)
                """).run()
            await #expect(throws: V2ReadReceiptStoreError.actorNotMember) {
                _ = try await readerStore.readers(
                    roomID: roomID,
                    messageID: message.messageID,
                    actorUserID: lateMemberID,
                    cursor: nil,
                    pageSize: 10
                )
            }

            try await sql.raw("UPDATE im_v2.public_user_profiles SET state = 'hidden' WHERE user_id = \(bind: memberTwoUUID)").run()
            let visibleReaders = try await readerStore.readers(
                roomID: roomID,
                messageID: message.messageID,
                actorUserID: senderID,
                cursor: nil,
                pageSize: 10
            )
            #expect(visibleReaders.readers.isEmpty)
            let hiddenMemberID = try UserID(memberTwoUUID.uuidString)
            let visibleMembers = try await directory.list(.init(
                roomID: roomID,
                actorUserID: senderID,
                cursor: nil,
                pageSize: 10
            ))
            #expect(!visibleMembers.entries.contains { $0.userID == hiddenMemberID })
            #expect(visibleMembers.entries.allSatisfy { $0.publicIdentity.userID == $0.userID })
            await #expect(throws: V2RoomMembershipDirectoryError.revisionConflict(currentRevision: 1)) {
                _ = try await directory.list(.init(
                    roomID: roomID,
                    actorUserID: senderID,
                    cursor: rosterCursor,
                    pageSize: 1
                ))
            }
            try await sql.raw(
                "UPDATE im_v2.public_user_profiles SET state = 'active' WHERE user_id = \(bind: memberTwoUUID)"
            ).run()
            let directMessaging = try V2DirectRoomOperationTestFixture(
                store: PostgresV2DirectMessagingStore(database: resources.database(.psql), identityReader: PostgresV2DirectRoomIdentityReader(database: resources.database(receiptControlPool)), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: try .init(id: "standard", limits: profile),
                roomShardID: "room-a",
                now: { now.addingTimeInterval(2) }
            )
            let directRoom = try await directMessaging.openedIdentity(
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000038"),
                targetUserID: try .init(memberTwoUUID.uuidString)
            , firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now.addingTimeInterval(2)))
            guard case .accepted(let directMessage) = try await send.send(.init(
                roomID: directRoom.roomID,
                actorUserID: senderID,
                clientMessageID: try .init("00000000-0000-0000-0000-000000000039"),
                text: "direct receipt fallback"
            )) else {
                Issue.record("expected direct message")
                return
            }
            let directReceiptRequest = V2AuthenticatedReadReceipt(
                roomID: directRoom.roomID,
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000040"),
                readThroughRoomSequence: directMessage.roomSequence
            )
            guard case .recorded(let directReceipt) = try await receipt.record(
                directReceiptRequest
            ) else {
                Issue.record("expected direct receipt")
                return
            }
            #expect(try await receipt.record(directReceiptRequest) == .idempotent(
                directReceipt
            ))
            let directReceiptProjectionCount = try #require(try await sql.raw("""
                SELECT COUNT(*)::bigint AS value
                FROM im_v2.user_sync_log
                WHERE user_id = \(bind: memberTwoUUID)
                  AND projection_kind = 'direct_read_receipt'
                  AND source_event_id = \(bind: UUID(uuidString: directReceiptRequest.operationID.rawValue)!)
                """).first(decoding: CountRow.self))
            #expect(directReceiptProjectionCount.value == 0)
            let crossKindConflict = try V2RecordReadReceiptCommand(roomID: roomID,
                actorUserID: senderID, operationID: directReceiptRequest.operationID,
                readThroughRoomSequence: message.roomSequence)
            #expect(try await readerStore.record(command: crossKindConflict, now: now) == .idempotencyConflict)
            #expect(try await readerStore.recordGroups([.init(command: crossKindConflict, now: now)]) == [.success(.handled(.idempotencyConflict))])

            #expect(try await count("im_v2.user_state_event_outbox WHERE projection_kind = 'own_read_watermark'", on: sql) == 3)
            let coalescedRequests = try [0, 1].map { offset in
                try V2ReadReceiptRecordRequest(command: .init(roomID: roomID,
                    actorUserID: .init(uuid: memberTwoUUID), operationID: .init(uuid: UUID()),
                    readThroughRoomSequence: secondMessage.roomSequence),
                    now: now.addingTimeInterval(20 + Double(offset)))
            }
            let coalesced = try await readerStore.recordGroups(coalescedRequests)
            #expect(coalesced.allSatisfy { if case .success(.handled(.recorded)) = $0 { return true }; return false })
            #expect(try await count("im_v2.user_state_event_outbox WHERE projection_kind = 'own_read_watermark'", on: sql) == 4)
            let repeated = try await readerStore.recordGroups(coalescedRequests)
            #expect(repeated.allSatisfy { if case .success(.handled(.idempotent)) = $0 { return true }; return false })
            #expect(try await count("im_v2.user_state_event_outbox WHERE projection_kind = 'own_read_watermark'", on: sql) == 4)
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.user_sync_log WHERE projection_kind = 'own_read_watermark' AND (payload->>'room_id')::uuid = \(bind: roomUUID)").first(decoding: CountRow.self)?.value == 0)
            if let targetURL = Environment.get("IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL") {
                #expect(targetURL != databaseURL)
                try await withUserEventDatabase(databaseURL: targetURL) { targetDatabase, targetSQL, targetSchema in
                    let outbox = try PostgresV2UserStateEventOutbox(database: resources.database(.psql))
                    let deliveryTime = now.addingTimeInterval(60)
                    struct Fence: V2UserShardRouteFencing {
                        let database: any Database
                        func withCurrentRoute<Result: Sendable>(for userID: UserID,
                            _ operation: @escaping @Sendable (V2UserShardRoute, any Database) async throws -> Result) async throws -> Result {
                            try await database.transaction { transaction in
                                try await operation(.init(bucket: "user", observedRouterEpoch: 1), transaction)
                            }
                        }
                    }
                    let projector = try V2RoutedUserStateEventProjector(routeFence: Fence(database: resources.database(.psql)),
                        registry: V2StaticUserShardStorageRegistry(locations: [.init(bucket: "user", database: targetDatabase, schema: targetSchema)]))
                    let leases = try await deliverUserStateEvents(outbox, projector: projector, now: deliveryTime)
                        .filter { $0.event.kind == .ownReadWatermark || $0.event.kind == .directReadReceipt }
                    #expect(leases.count == 5)
                    #expect(try await targetSQL.raw("""
                        SELECT count(*)::bigint AS value FROM \(unsafeRaw: targetSchema).user_sync_log
                        WHERE projection_kind = 'own_read_watermark'
                        """).first(decoding: CountRow.self)?.value == 4)
                    #expect(try await targetSQL.raw("""
                        SELECT count(*)::bigint AS value FROM \(unsafeRaw: targetSchema).user_sync_log
                        WHERE projection_kind = 'direct_read_receipt' AND user_id = \(bind: memberTwoUUID)
                            AND source_event_id = \(bind: directReceiptRequest.operationID.uuidValue!)
                            AND (payload->>'is_visible')::boolean
                            AND (payload->>'read_through_room_sequence')::bigint = \(bind: Int64(directMessage.roomSequence))
                        """).first(decoding: CountRow.self)?.value == 1)
                }
            }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown(); throw error
        }
    }

    @Test("available owner media is referenced atomically and unavailable media cannot create a message")
    func persistsAuthorizedMediaReferencesWithMessageAcceptance() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let availableID = try MediaID("00000000-0000-0000-0000-000000000090")
            let unavailableID = try MediaID("00000000-0000-0000-0000-000000000091")
            let mentionedUser = try UserID(memberTwoUUID.uuidString)
            let mediaStore = PostgresV2MediaStore(database: resources.database(.psql))
            try await sql.raw("""
                INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, session_expires_at)
                VALUES (\(bind: senderUUID), \(bind: deviceID.uuidValue!), \(bind: now), \(bind: now), \(bind: Date().addingTimeInterval(3600)))
                """).run()
            let uploads = PostgresV2ResourceLifecycleStore(database: resources.database(.psql), authorize: { _ in })
            func createUpload(_ mediaID: MediaID) async throws -> V2PersistedResourceUpload {
                let input = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: mediaID, usage: .messageAttachment(roomID),
                    contentType: "image/png", byteCount: 42, checksum: .init(value: String(repeating: "a", count: 64)))
                return try await uploads.create(homeKind: "room", homeID: roomUUID, usageKind: "message_attachment", actor: senderUUID,
                    device: deviceID.uuidValue!, operation: input.operationID.uuidValue!, mediaID: mediaID.uuidValue!, contentType: input.contentType,
                    byteCount: input.byteCount, requestJSON: String(decoding: JSONEncoder().encode(input), as: UTF8.self),
                    allocate: { try .init(placementID: UUID(), binding: .init(id: "message-acceptance", configurationRevision: 1), handle: Data(mediaID.rawValue.utf8)) },
                    expiresAt: now.addingTimeInterval(600), now: now)
            }
            let availableUpload = try await createUpload(availableID)
            let uploadClaim = try await uploads.claimFinalize(session: availableUpload.sessionID, generation: 1,
                actor: senderUUID, device: deviceID.uuidValue!, now: now.addingTimeInterval(1))
            try await uploads.publish(uploadClaim, facts: .init(reference: uploadClaim.placement, byteCount: 42, sha256: Data(repeating: 0xaa, count: 32)),
                actor: senderUUID, device: deviceID.uuidValue!, now: now.addingTimeInterval(1))
            #expect(try await uploads.status(session: availableUpload.sessionID, actor: senderUUID, device: deviceID.uuidValue!).mediaState == "scanning")
            let scanStore = PostgresV2MediaScanStore(database: resources.database(.psql), makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000092")! })
            let scanLease = try #require(try await scanStore.claimPending(now: now.addingTimeInterval(2), leaseDuration: 10, limit: 1).first)
            #expect(scanLease.mediaID == availableID)
            try await scanStore.complete(scanLease, result: .passed, now: now.addingTimeInterval(2))
            let completedScan = try #require(try await sql.raw("SELECT state FROM im_v2.media_scan_outbox WHERE media_id = \(bind: UUID(uuidString: availableID.rawValue)!)").first(decoding: PushStateRow.self))
            #expect(completedScan.state == "completed")
            #expect(try await uploads.status(session: availableUpload.sessionID, actor: senderUUID, device: deviceID.uuidValue!).mediaState == "available")
            _ = try await createUpload(unavailableID)

            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3))
            let service = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: resources.database(.psql)),
                capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64),
                idFactory: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000095")! }),
                now: { now.addingTimeInterval(3) }
            )
            let accepted = try await service.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "", media: [.init(mediaID: availableID)], mentions: [.user(mentionedUser)]))
            guard case .accepted(let message) = accepted else { Issue.record("expected media message acceptance"); return }
            let persistedReference = try #require(try await sql.raw("SELECT message_id, media_id, ordinal FROM im_v2.message_media_references").first(decoding: MediaReferenceAssertionRow.self))
            let mention = try #require(try await sql.raw("SELECT mentioned_user_id FROM im_v2.message_mentions WHERE message_id = \(bind: UUID(uuidString: message.messageID.rawValue)!)").first(decoding: MentionAssertionRow.self))
            let event = try #require(try await sql.raw("SELECT payload @> jsonb_build_object('media_ids', jsonb_build_array(\(bind: availableID.rawValue)) ) AS contains FROM im_v2.room_events WHERE event_id = \(bind: UUID(uuidString: "00000000-0000-0000-0000-000000000095")!)").first(decoding: MediaEventContainsRow.self))
            #expect(persistedReference.messageID.uuidString == message.messageID.rawValue)
            #expect(persistedReference.mediaID.uuidString == availableID.rawValue)
            #expect(persistedReference.ordinal == 0)
            #expect(event.contains)
            #expect(mention.userID.uuidString == mentionedUser.rawValue)

            // Download authorization requires an accessible canonical message
            // reference. Seed the device at
            // the same identity boundary the media edge will authenticate.
            try await sql.raw("""
                INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at)
                VALUES (\(bind: senderUUID), \(bind: UUID(uuidString: deviceID.rawValue)!), \(bind: now), \(bind: now))
                ON CONFLICT (user_id, device_id) DO NOTHING
                """).run()
            #expect(try await count("im_v2.user_sync_log", on: sql) == 0)

            let download = try await mediaStore.requestDownload(
                requesterUserID: senderID,
                deviceID: deviceID,
                mediaID: availableID,
                expiresAt: now.addingTimeInterval(60),
                now: now.addingTimeInterval(6)
            )
            #expect(download.mediaID == availableID)
            #expect(download.expiresAt == now.addingTimeInterval(60))
            let downloadSessions = PostgresV2MediaDownloadSessionStore(database: resources.database(.psql))
            let claimedDownload = try await downloadSessions.claimDownload(
                requesterUserID: senderID,
                deviceID: deviceID,
                downloadSessionID: download.downloadSessionID,
                now: now.addingTimeInterval(6),
                leaseDuration: 10
            )
            try await downloadSessions.completeDownload(claimedDownload, now: now.addingTimeInterval(7))
            let consumedGrant = try #require(try await sql.raw("SELECT state FROM im_v2.media_download_grants WHERE download_session_id = \(bind: UUID(uuidString: download.downloadSessionID.rawValue)!)").first(decoding: PushStateRow.self))
            #expect(consumedGrant.state == "consumed")
            await #expect(throws: V2MediaDownloadSessionStoreError.sessionUnavailable) {
                _ = try await downloadSessions.claimDownload(requesterUserID: senderID, deviceID: deviceID, downloadSessionID: download.downloadSessionID, now: now.addingTimeInterval(8), leaseDuration: 10)
            }
            let unexchangedDownload = try await mediaStore.requestDownload(
                requesterUserID: senderID,
                deviceID: deviceID,
                mediaID: availableID,
                expiresAt: now.addingTimeInterval(60),
                now: now.addingTimeInterval(8)
            )

            await #expect(throws: V2MediaStoreError.mediaUnavailable) {
                _ = try await service.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: try .init("00000000-0000-0000-0000-000000000096"), text: "", media: [.init(mediaID: unavailableID)]))
            }

            // A newly-issued grant must fail after a withdrawal even though a
            // previously handed-off provider target may naturally expire.
            try await sql.raw("UPDATE im_v2.messages SET withdrawn_at = \(bind: now.addingTimeInterval(7)), withdrawn_by_user_id = \(bind: senderUUID) WHERE message_id = \(bind: UUID(uuidString: message.messageID.rawValue)!)").run()
            await #expect(throws: V2MediaStoreError.downloadNotAuthorized) {
                _ = try await mediaStore.requestDownload(requesterUserID: senderID, deviceID: deviceID, mediaID: availableID, expiresAt: now.addingTimeInterval(60), now: now.addingTimeInterval(9))
            }
            await #expect(throws: V2MediaDownloadSessionStoreError.sessionUnavailable) {
                _ = try await downloadSessions.claimDownload(requesterUserID: senderID, deviceID: deviceID, downloadSessionID: unexchangedDownload.downloadSessionID, now: now.addingTimeInterval(9), leaseDuration: 10)
            }
            try await sql.raw("UPDATE im_v2.messages SET withdrawn_at = NULL, withdrawn_by_user_id = NULL WHERE message_id = \(bind: UUID(uuidString: message.messageID.rawValue)!)").run()

            // Removal has the same effect for subsequent grants, while the
            // row above remains a bounded record of the already-issued grant.
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 1 WHERE room_id = \(bind: roomUUID)").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision = 1 WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID) AND joined_revision = 0").run()
            await #expect(throws: V2MediaStoreError.downloadNotAuthorized) {
                _ = try await mediaStore.requestDownload(requesterUserID: senderID, deviceID: deviceID, mediaID: availableID, expiresAt: now.addingTimeInterval(60), now: now.addingTimeInterval(10))
            }
            #expect(try await count("im_v2.media_download_grants", on: sql) == 2)

            // Retention changes metadata to a terminal state and emits a
            // provider-owned cleanup task; it does not destroy message or
            // audit history in the chat transaction.
            try await sql.raw("UPDATE im_v2.messages SET withdrawn_at = \(bind: now.addingTimeInterval(-31 * 86_400)), withdrawn_by_user_id = \(bind: senderUUID) WHERE message_id = \(bind: UUID(uuidString: message.messageID.rawValue)!)").run()
            let retention = try V2MediaRetentionWorker(
                store: PostgresV2MediaRetentionStore(database: resources.database(.psql)),
                now: { now }
            )
            #expect(try await retention.runOnce(limit: 1) == 1)
            #expect(try await retention.runOnce(limit: 1) == 0)
            let retainedState = try #require(try await sql.raw("SELECT state FROM im_v2.media_objects WHERE media_id = \(bind: UUID(uuidString: availableID.rawValue)!)").first(decoding: PushStateRow.self))
            #expect(retainedState.state == "expired")
            #expect(try await count("im_v2.media_purge_outbox", on: sql) == 1)
            let purgeStore = PostgresV2MediaPurgeStore(database: resources.database(.psql), makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000097")! })
            let purgeLease = try #require(try await purgeStore.claimPending(now: now, leaseDuration: 10, limit: 1).first)
            #expect(purgeLease.mediaID == availableID)
            #expect(purgeLease.reason == .withdrawnRetentionElapsed)
            try await purgeStore.markCompleted(purgeLease, now: now.addingTimeInterval(1))
            let completedPurge = try #require(try await sql.raw("SELECT state FROM im_v2.media_purge_outbox WHERE media_id = \(bind: UUID(uuidString: availableID.rawValue)!)").first(decoding: PushStateRow.self))
            #expect(completedPurge.state == "completed")
            #expect(try await count("im_v2.messages", on: sql) == 1)
            #expect(try await count("im_v2.message_media_references", on: sql) == 1)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("moderator redaction atomically tombstones, audits, appends a room event, and replays")
    func moderatorRedactionIsDurableAndExplicit() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3))
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: resources.database(.psql)), capacityProfile: profile, limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "requires moderation")) else { Issue.record("expected accepted message"); return }
            let messageUUID = try #require(UUID(uuidString: message.messageID.rawValue))
            let mediaUUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
            try await sql.raw("""
                INSERT INTO im_v2.media_objects
                    (media_id, owner_user_id, content_type, byte_count, state, upload_session_id, expires_at, state_updated_at, created_at)
                VALUES
                    (\(bind: mediaUUID), \(bind: senderUUID), 'image/png', 1, 'available',
                     \(bind: UUID(uuidString: "00000000-0000-0000-0000-0000000000a2")!),
                     \(bind: now.addingTimeInterval(3_600)), \(bind: now), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.message_media_references (message_id, media_id, ordinal, referenced_at)
                VALUES (\(bind: messageUUID), \(bind: mediaUUID), 0, \(bind: now))
                """).run()
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID) AND joined_revision = 0").run()
            let command = try await freezeMessageModerationFixture(database: resources.database(.psql), roomID: roomID,
                actorUserID: senderID, operationID: .init("00000000-0000-0000-0000-000000000097"),
                messageID: message.messageID, reasonCode: .init("abuse_spam"), now: now)
            let first = try await submitMessageModerationFixture(database: resources.database(.psql), command: command,
                profile: profile, eventID: .init("00000000-0000-0000-0000-000000000098"), now: now.addingTimeInterval(1))
            guard case .receipt(let proof) = first,
                  case .redacted(let redactedMessage, let revision, _, let eventID) = proof.outcome else { throw CancellationError() }
            #expect(proof.validates(intent: command.intent) && redactedMessage == message.messageID && revision == 2)
            let replay = try await submitMessageModerationFixture(database: resources.database(.psql), command: command,
                profile: profile, eventID: .init("00000000-0000-0000-0000-000000000100"), now: now.addingTimeInterval(2))
            let event = try #require(try await sql.raw("SELECT event_type, payload->>'message_id' AS message_id FROM im_v2.room_events WHERE event_id = \(bind: UUID(uuidString: eventID.rawValue)!)").first(decoding: ModerationEventAssertionRow.self))
            let audit = try #require(try await sql.raw("SELECT action, reason_code FROM im_v2.moderation_audit_entries WHERE actor_user_id = \(bind: senderUUID)").first(decoding: ModerationAuditAssertionRow.self))
            let state = try #require(try await sql.raw("SELECT withdrawn_at IS NOT NULL AS withdrawn, content_revision FROM im_v2.messages WHERE message_id = \(bind: UUID(uuidString: message.messageID.rawValue)!)").first(decoding: ModerationMessageAssertionRow.self))
            let mediaReference = try #require(try await sql.raw("""
                SELECT revoked_at IS NOT NULL AS exists
                FROM im_v2.message_media_references
                WHERE message_id = \(bind: messageUUID) AND media_id = \(bind: mediaUUID)
                """).first(decoding: ExistsRow.self))
            #expect(replay == first)
            #expect(event.eventType == "message.redacted")
            #expect(event.messageID == message.messageID.rawValue)
            #expect(audit.action == "redact_message")
            #expect(audit.reasonCode == "abuse_spam")
            #expect(state.withdrawn)
            #expect(state.revision == 2)
            #expect(mediaReference.exists)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 0)
            #expect(try await count("im_v2.message_moderation_receipts", on: sql) == 1)
            try await sql.raw("UPDATE im_v2.moderation_audit_entries SET retain_until = \(bind: now.addingTimeInterval(-1))").run()
            let retention = V2ModerationAuditRetentionWorker(
                store: PostgresV2ModerationAuditRetentionStore(database: resources.database(.psql)),
                now: { now }
            )
            #expect(try await retention.runOnce(limit: 1) == 1)
            #expect(try await retention.runOnce(limit: 1) == 0)
            #expect(try await count("im_v2.moderation_audit_entries", on: sql) == 0)
            #expect(try await count("im_v2.message_moderation_receipts", on: sql) == 1)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown(); throw error
        }
    }

    @Test("frozen rooms and active member mutes reject new messages before any write")
    func moderationAdmissionStatesBlockMessages() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3))
            let messages = V2SendMessageService(store: PostgresV2RoomWriteStore(database: resources.database(.psql)), capacityProfile: profile, limits: try .init(maxUTF8Bytes: 64), now: { now })

            try await sql.raw("UPDATE im_v2.rooms SET frozen_at = \(bind: now), frozen_by_user_id = \(bind: memberTwoUUID) WHERE room_id = \(bind: roomUUID)").run()
            await #expect(throws: V2RoomWriteStoreError.roomFrozen) {
                _ = try await messages.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "blocked-by-freeze"))
            }

            try await sql.raw("UPDATE im_v2.rooms SET frozen_at = NULL, frozen_by_user_id = NULL WHERE room_id = \(bind: roomUUID)").run()
            let muteOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000070")!
            try await sql.raw("INSERT INTO im_v2.room_member_mutes (room_id, user_id, mute_until, actor_user_id, operation_id, created_at) VALUES (\(bind: roomUUID), \(bind: senderUUID), \(bind: now.addingTimeInterval(300)), \(bind: memberTwoUUID), \(bind: muteOperationID), \(bind: now))").run()
            await #expect(throws: V2RoomWriteStoreError.actorMuted) {
                _ = try await messages.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: try .init("00000000-0000-0000-0000-000000000071"), text: "blocked-by-mute"))
            }
            #expect(try await count("im_v2.messages", on: sql) == 0)
            #expect(try await count("im_v2.room_events", on: sql) == 0)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown(); throw error
        }
    }

    @Test("trusted safety service freezes and unfreezes a room with durable audit and fan-out")
    func trustedSafetyRoomControlIsDurableAndEnforced() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3))
            let safetyActor = try UserID("00000000-0000-0000-0000-000000000110")
            let safety = V2TrustedSafetyModerationService(
                store: PostgresV2ModerationStore(database: resources.database(.psql)),
                safetyActorUserID: safetyActor,
                capacityProfile: profile,
                now: { now }
            )
            let freeze = try V2TrustedSafetyRoomControl(roomID: roomID, operationID: .init("00000000-0000-0000-0000-000000000112"), action: .freezeRoom, reasonCode: .init("safety_review"))
            let first = try await safety.apply(freeze)
            guard case .applied(let frozen) = first else { Issue.record("expected room freeze"); return }
            let replay = try await safety.apply(freeze)
            let state = try #require(try await sql.raw("SELECT frozen_at, frozen_by_user_id FROM im_v2.rooms WHERE room_id = \(bind: roomUUID)").first(decoding: FrozenRoomAssertionRow.self))
            let audit = try #require(try await sql.raw("SELECT action, reason_code FROM im_v2.moderation_audit_entries WHERE actor_user_id = \(bind: UUID(uuidString: safetyActor.rawValue)!)").first(decoding: ModerationAuditAssertionRow.self))
            let messages = V2SendMessageService(store: PostgresV2RoomWriteStore(database: resources.database(.psql)), capacityProfile: profile, limits: try .init(maxUTF8Bytes: 64), now: { now })
            await #expect(throws: V2RoomWriteStoreError.roomFrozen) {
                _ = try await messages.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "frozen"))
            }
            let frozenEvent = try #require(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.room_events WHERE event_id = \(bind: frozen.eventID.uuidValue!) AND event_type = 'room.frozen'").first(decoding: CountRow.self))

            let unfreeze = try V2TrustedSafetyRoomControl(roomID: roomID, operationID: .init("00000000-0000-0000-0000-000000000113"), action: .unfreezeRoom, reasonCode: .init("safety_review"))
            let unfrozen = try await safety.apply(unfreeze)
            guard case .applied(let result) = unfrozen else { Issue.record("expected room unfreeze"); return }
            let finalState = try #require(try await sql.raw("SELECT frozen_at, frozen_by_user_id FROM im_v2.rooms WHERE room_id = \(bind: roomUUID)").first(decoding: FrozenRoomAssertionRow.self))

            #expect(replay == .idempotent(frozen))
            #expect(state.frozenAt == now)
            #expect(state.frozenByUserID == UUID(uuidString: safetyActor.rawValue))
            #expect(audit.action == "freeze_room")
            #expect(audit.reasonCode == "safety_review")
            #expect(frozenEvent.value == 1)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 0)
            #expect(result.action == .unfreezeRoom)
            #expect(finalState.frozenAt == nil)
            #expect(finalState.frozenByUserID == nil)
            #expect(try await count("im_v2.moderation_operations", on: sql) == 2)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown(); throw error
        }
    }

    @Test("moderator mute persists its room event and audit, replays, and blocks the target")
    func moderatorMuteIsDurableAndEnforced() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").run()
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3))
            let domain = try V2ModerationCommand(roomID: roomID, actorUserID: senderID,
                operationID: .init("00000000-0000-0000-0000-000000000074"), action: .muteMember,
                targetUserID: .init(memberTwoUUID.uuidString), muteUntil: now.addingTimeInterval(300), reasonCode: .init("abuse_spam"))
            let first = try await applyAdmittedMemberFixture(database:resources.database(.psql),command:domain,profile:profile,eventID:.init(uuid:UUID()),now:now)
            guard case .applied(let result) = first else { Issue.record("expected mute application"); return }
            let replay = try await applyAdmittedMemberFixture(database:resources.database(.psql),command:domain,profile:profile,eventID:.init(uuid:UUID()),now:now)
            let mute = try #require(try await sql.raw("SELECT mute_until, actor_user_id FROM im_v2.room_member_mutes WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: memberTwoUUID)").first(decoding: MuteAssertionRow.self))
            let audit = try #require(try await sql.raw("SELECT action, reason_code FROM im_v2.moderation_audit_entries WHERE actor_user_id = \(bind: senderUUID)").first(decoding: ModerationAuditAssertionRow.self))
            let event = try #require(try await sql.raw("SELECT event_type, payload->>'target_user_id' AS target_user_id FROM im_v2.room_events WHERE event_id = \(bind: UUID(uuidString: result.eventID.rawValue)!)").first(decoding: MuteEventAssertionRow.self))
            let messages = V2SendMessageService(store: PostgresV2RoomWriteStore(database: resources.database(.psql)), capacityProfile: profile, limits: try .init(maxUTF8Bytes: 64), now: { now })
            await #expect(throws: V2RoomWriteStoreError.actorMuted) {
                _ = try await messages.send(.init(roomID: roomID, actorUserID: try .init(memberTwoUUID.uuidString), clientMessageID: try .init("00000000-0000-0000-0000-000000000075"), text: "must-not-send"))
            }
            #expect(replay == .idempotent(result))
            #expect(mute.actorUserID == senderUUID)
            #expect(mute.muteUntil == now.addingTimeInterval(300))
            #expect(audit.action == "mute_member")
            #expect(audit.reasonCode == "abuse_spam")
            #expect(event.eventType == "member.muted")
            #expect(event.targetUserID == memberTwoUUID.uuidString)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 0)
            #expect(try await count("im_v2.member_administration_receipts", on: sql) == 1)
            #expect(try await count("im_v2.messages", on: sql) == 0)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown(); throw error
        }
    }

}

private struct ContentReviewResetAssertionRow: Decodable, Equatable {
    let state: String
    let revision: Int64
    let decision: String?
    let claimReleased: Bool
    let leaseReleased: Bool
    let isUncompleted: Bool

    enum CodingKeys: String, CodingKey {
        case state, decision
        case revision = "expected_content_revision"
        case claimReleased = "claim_released"
        case leaseReleased = "lease_released"
        case isUncompleted = "is_uncompleted"
    }
}
private enum MessageMutationRaceOutcome: Equatable, Sendable {
    case edited
    case withdrawn
    case revisionConflict
    case alreadyWithdrawn
    case unexpectedOutcome
    case unexpectedFailure
}
private struct RelationshipAssertionRow: Decodable {
    let state: String; let requestedByUserID: UUID
    enum CodingKeys: String, CodingKey { case state; case requestedByUserID = "requested_by_user_id" }
}
private struct MembershipRevisionRow: Decodable {
    let membershipRevision: Int64
    let roomSequence: Int64
    enum CodingKeys: String, CodingKey { case membershipRevision = "membership_revision", roomSequence = "room_sequence" }
}
private struct MembershipTargetStateRow: Decodable {
    let role: String
    let joinedRevision: Int64
    enum CodingKeys: String, CodingKey { case role, joinedRevision = "joined_revision" }
}
private struct LeftRevisionRow: Decodable {
    let leftRevision: Int64?
    enum CodingKeys: String, CodingKey { case leftRevision = "left_revision" }
}
private struct MembershipEventRow: Decodable {
    let eventType: String
    let action: String
    enum CodingKeys: String, CodingKey { case eventType = "event_type", action }
}
private struct WithdrawalMessageStateRow: Decodable {
    let contentRevision: Int64
    let withdrawnByUserID: UUID
    enum CodingKeys: String, CodingKey { case contentRevision = "content_revision", withdrawnByUserID = "withdrawn_by_user_id" }
}
private struct WithdrawalEventRow: Decodable {
    let eventType: String
    let messageID: String
    let withdrawn: String
    enum CodingKeys: String, CodingKey { case eventType = "event_type", messageID = "message_id", withdrawn }
}
private struct ReactionEventRow: Decodable {
    let eventType: String
    let messageID: String
    let reaction: String
    let action: String
    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case messageID = "message_id"
        case reaction, action
    }
}
private struct TombstonedEditStateRow: Decodable {
    let text: String; let revision: Int64; let isWithdrawn: Bool
    enum CodingKeys: String, CodingKey { case text = "text_body", revision = "content_revision", isWithdrawn = "is_withdrawn" }
}
private struct EditEventRow: Decodable {
    let eventType: String; let text: String; let revision: String
    enum CodingKeys: String, CodingKey { case eventType = "event_type", text, revision }
}
private struct ReceiptStateAssertionRow: Decodable {
    let sequence: Int64
    enum CodingKeys: String, CodingKey { case sequence = "read_through_room_sequence" }
}

private struct MediaEventContainsRow: Decodable { let contains: Bool }
private struct MentionAssertionRow: Decodable { let userID: UUID; enum CodingKeys: String, CodingKey { case userID = "mentioned_user_id" } }
private struct ModerationEventAssertionRow: Decodable { let eventType: String; let messageID: String; enum CodingKeys: String, CodingKey { case eventType = "event_type", messageID = "message_id" } }
private struct ModerationMessageAssertionRow: Decodable { let withdrawn: Bool; let revision: Int64; enum CodingKeys: String, CodingKey { case withdrawn; case revision = "content_revision" } }
private struct MuteAssertionRow: Decodable { let muteUntil: Date; let actorUserID: UUID; enum CodingKeys: String, CodingKey { case muteUntil = "mute_until", actorUserID = "actor_user_id" } }
private struct MuteEventAssertionRow: Decodable { let eventType: String; let targetUserID: String; enum CodingKeys: String, CodingKey { case eventType = "event_type", targetUserID = "target_user_id" } }
private struct FrozenRoomAssertionRow: Decodable { let frozenAt: Date?; let frozenByUserID: UUID?; enum CodingKeys: String, CodingKey { case frozenAt = "frozen_at", frozenByUserID = "frozen_by_user_id" } }
private struct PublicationAdmissionSnapshot: Decodable, Equatable {
    let room: Int64
    let shard: Int64
    let sequence: Int64
}

// These fixtures retain the domain assertions while obtaining execution facts
// exclusively from the current permanent, activation-fenced operation store.
private struct MembershipTypedEditFixture: Sendable {
    let database: any Database
    let capacityProfile: V2CapacityProfile
    let maximumTextUTF8Bytes: Int
    var identifiers: V2MessageEditIDFactory = .init()
    let now: @Sendable () -> Date

    func edit(_ request: V2AuthenticatedMessageEdit) async throws -> V2MessageEditOutcome {
        let date = now()
        let command = try V2MessageEditOperationCommand(command: .init(roomID: request.roomID,
            actorUserID: request.actorUserID, operationID: request.operationID, messageID: request.messageID,
            expectedMessageRevision: request.expectedMessageRevision, text: request.text,
            maximumUTF8Bytes: maximumTextUTF8Bytes),
            firstSubmissionDeadlineMilliseconds: UInt64(date.timeIntervalSince1970 * 1000) + 60_000)
        return try await withRoomActivation(database: database, roomID: request.roomID) { token in
            let store = PostgresV2MessageMutationOperationStore(database: database, contentReviewMode: .enabled, clock: { date })
            let prior = try await store.recover(.init(identity: command.identity, fingerprint: command.fingerprint, action: .query), token: token, now: date)
            let replay: Bool
            let response: V2MessageMutationRecoveryResult
            switch prior {
            case .unresolved:
                replay = false
                response = try await store.edit(command, token: token, capacityProfile: capacityProfile,
                    eventID: identifiers.make(), now: date, maximumUTF8Bytes: maximumTextUTF8Bytes)
            default: replay = true; response = prior
            }
            switch response {
            case .fingerprintConflict: return .idempotencyConflict
            case .receipt(let proof):
                guard proof.validates(identity: try command.identity, fingerprint: try command.fingerprint) else { throw V2MessageEditStoreError.corruptPersistenceState }
                switch proof.outcome {
                case .committed(let value):
                    let result = try V2MessageEdit(roomID: request.roomID, messageID: value.messageID, text: request.text,
                        messageRevision: value.messageRevision, roomSequence: value.roomSequence, eventID: value.eventID,
                        createdAt: Date(timeIntervalSince1970: Double(proof.resolvedAtMilliseconds) / 1000))
                    return replay ? .idempotent(result) : .edited(result)
                case .rejected(.revisionConflict(let revision)): return .revisionConflict(current: revision)
                case .rejected(.alreadyWithdrawn): return .alreadyWithdrawn
                default: throw V2MessageEditStoreError.corruptPersistenceState
                }
            default: throw V2MessageEditStoreError.corruptPersistenceState
            }
        }
    }
}

private struct MembershipTypedWithdrawalFixture: Sendable {
    let database: any Database
    let capacityProfile: V2CapacityProfile
    var identifiers: V2MessageWithdrawalIDFactory = .init()
    let now: @Sendable () -> Date

    func withdraw(_ request: V2AuthenticatedMessageWithdrawal) async throws -> V2MessageWithdrawalOutcome {
        let date = now()
        let command = try V2MessageWithdrawalOperationCommand(command: .init(roomID: request.roomID,
            actorUserID: request.actorUserID, operationID: request.operationID, messageID: request.messageID,
            expectedMessageRevision: request.expectedMessageRevision),
            firstSubmissionDeadlineMilliseconds: UInt64(date.timeIntervalSince1970 * 1000) + 60_000)
        return try await withRoomActivation(database: database, roomID: request.roomID) { token in
            let store = PostgresV2MessageMutationOperationStore(database: database, contentReviewMode: .enabled, clock: { date })
            let prior = try await store.recover(.init(identity: command.identity, fingerprint: command.fingerprint, action: .query), token: token, now: date)
            let replay: Bool
            let response: V2MessageMutationRecoveryResult
            switch prior {
            case .unresolved:
                replay = false
                response = try await store.withdraw(command, token: token, capacityProfile: capacityProfile,
                    eventID: identifiers.make(), now: date)
            default: replay = true; response = prior
            }
            switch response {
            case .fingerprintConflict: return .idempotencyConflict
            case .receipt(let proof):
                guard proof.validates(identity: try command.identity, fingerprint: try command.fingerprint) else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }
                switch proof.outcome {
                case .committed(let value):
                    let result = try V2MessageWithdrawal(roomID: request.roomID, messageID: value.messageID,
                        messageRevision: value.messageRevision, roomSequence: value.roomSequence, eventID: value.eventID,
                        createdAt: Date(timeIntervalSince1970: Double(proof.resolvedAtMilliseconds) / 1000))
                    return replay ? .idempotent(result) : .withdrawn(result)
                case .rejected(.revisionConflict(let revision)): return .revisionConflict(current: revision)
                case .rejected(.alreadyWithdrawn): return .alreadyWithdrawn
                default: throw V2MessageWithdrawalStoreError.corruptPersistenceState
                }
            default: throw V2MessageWithdrawalStoreError.corruptPersistenceState
            }
        }
    }
}

private actor MembershipTypedGroupFixture {
    let database: any Database
    let capacityProfile: V2CapacityProfile
    let now: @Sendable () -> Date
    // Frozen commands only: all outcomes/replays are read from the SQL ledger.
    private var commands: [String: V2GroupCapabilityCommand] = [:]

    init(database: any Database, capacityProfile: V2CapacityProfile, now: @escaping @Sendable () -> Date) {
        self.database = database; self.capacityProfile = capacityProfile; self.now = now
    }

    private func perform<Value: Equatable & Sendable>(_ intent: V2GroupCapabilityIntent,
        value: @escaping @Sendable (V2GroupCapabilityValue, Date) throws -> Value) async throws -> V2GroupCapabilitiesOutcome<Value> {
        let date = now()
        let database = database, profile = capacityProfile
        let frozen = commands[intent.identity.storageKey]
        let pair: (V2GroupCapabilityCommand?, V2GroupCapabilitiesOutcome<Value>) = try await withRoomActivation(database: database, roomID: intent.roomID) { token in
            let store = PostgresV2GroupCapabilityOperationStore(database: database, clock: { date })
            // Recovery binds the frozen admission, not the preparation intent.
            let prior: V2GroupCapabilityRecoveryResult
            if let frozen, frozen.intent == intent {
                prior = try await store.recover(.init(identity: frozen.identity,
                    fingerprint: frozen.fingerprint, action: .query), token: token)
            } else {
                prior = .unresolved
            }
            let replay: Bool
            let response: V2GroupCapabilityRecoveryResult
            var command: V2GroupCapabilityCommand? = frozen
            switch prior {
            case .unresolved:
                replay = false
                if command == nil || command?.intent != intent {
                    switch try await store.admit(intent, token: token) {
                    case .admitted(let admission): command = try .init(intent: intent, admission: admission)
                    case .fingerprintConflict: return (nil, .idempotencyConflict)
                    case .currentUnavailable(.current(.revisionChanged)):
                        return (nil, .revisionConflict)
                    default: throw V2GroupCapabilitiesStoreError.corruptPersistenceState
                    }
                }
                guard let command else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
                response = try await store.submit(command, token: token, capacityProfile: profile, eventID: .init(uuid: UUID()))
            default: replay = true; response = prior
            }
            switch response {
            case .fingerprintConflict: return (command, .idempotencyConflict)
            case .receipt(let proof):
                guard let command, proof.validates(command: command) else {
                    throw V2GroupCapabilitiesStoreError.corruptPersistenceState
                }
                switch proof.outcome {
                case .applied(let result):
                    let mapped = try value(result, Date(timeIntervalSince1970: Double(proof.resolvedAtMilliseconds) / 1000))
                    return (command, replay ? .idempotent(mapped) : .applied(mapped))
                case .alreadySatisfied: return (command, .alreadyInDesiredState)
                case .rejected(.revisionChanged): return (command, .revisionConflict)
                default: throw V2GroupCapabilitiesStoreError.corruptPersistenceState
                }
            default: throw V2GroupCapabilitiesStoreError.corruptPersistenceState
            }
        }
        if let command = pair.0 { commands[intent.identity.storageKey] = command }
        return pair.1
    }

    func setPinnedMessage(actorUserID: UserID, command: V2PinnedMessageCommand) async throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage> {
        let identity = try V2OperationIdentity(accountID: actorUserID, scope: .message(command.roomID, command.messageID), operation: .pinnedMessage(command.operationID))
        let revision: UInt64
        if let frozen = commands[identity.storageKey], case .pin(_, _, let expected) = frozen.intent.action { revision = expected }
        else {
            let database = database, date = now()
            revision = try await withRoomActivation(database: database, roomID: command.roomID) { token in
                try await PostgresV2GroupCapabilityOperationStore(database: database, clock: { date })
                    .pinnedBaseline(.init(roomID: command.roomID, actorUserID: actorUserID, messageID: command.messageID), token: token).roomSequence
            }
        }
        let intent = try V2GroupCapabilityIntent(identity: identity, action: .pin(messageID: command.messageID, isPinned: command.isPinned, expectedRoomSequence: revision), confirmedUntilMilliseconds: UInt64(now().timeIntervalSince1970 * 1000) + 120_000)
        return try await perform(intent) { value, date in
            guard case .pinned(let message, let pinned, let sequence) = value else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            return try .init(roomID: command.roomID, messageID: message, isPinned: pinned, roomSequence: sequence, updatedAt: date)
        }
    }

    func setAnnouncement(actorUserID: UserID, command: V2GroupAnnouncementCommand) async throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement> {
        let intent = try V2GroupCapabilityIntent(identity: .init(accountID: actorUserID, scope: .room(command.roomID), operation: .groupAnnouncement(command.operationID)), action: .announcement(body: command.body, expectedRevision: command.expectedRevision), confirmedUntilMilliseconds: UInt64(now().timeIntervalSince1970 * 1000) + 120_000)
        return try await perform(intent) { value, date in
            guard case .announcement(let body, let revision, let sequence) = value else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            return try .init(roomID: command.roomID, body: body, revision: revision, roomSequence: sequence, updatedAt: date)
        }
    }

    func setRolePermissions(actorUserID: UserID, command: V2GroupRolePermissionsCommand) async throws -> V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange> {
        let intent = try V2GroupCapabilityIntent(identity: .init(accountID: actorUserID, scope: .room(command.roomID), operation: .groupPermission(command.operationID)), action: .rolePermissions(role: command.role, permissions: command.permissions, expectedRevision: command.expectedRevision), confirmedUntilMilliseconds: UInt64(now().timeIntervalSince1970 * 1000) + 120_000)
        return try await perform(intent) { value, _ in
            guard case .rolePermissions(let role, let permissions, let revision, let sequence) = value else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            return try .init(roomID: command.roomID, role: role, permissions: permissions, revision: revision, roomSequence: sequence)
        }
    }

    func changeMemberRole(actorUserID: UserID, command: V2GroupMemberRoleCommand) async throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange> {
        let intent = try V2GroupCapabilityIntent(identity: .init(accountID: actorUserID, scope: .room(command.roomID), operation: .groupRole(command.operationID)), action: .memberRole(targetUserID: command.targetUserID, role: command.role, expectedMembershipRevision: command.expectedMembershipRevision), confirmedUntilMilliseconds: UInt64(now().timeIntervalSince1970 * 1000) + 120_000)
        return try await perform(intent) { value, _ in
            guard case .memberRole(let target, let role, let revision, let sequence) = value else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            return try .init(roomID: command.roomID, targetUserID: target, role: role, membershipRevision: revision, roomSequence: sequence)
        }
    }
}
