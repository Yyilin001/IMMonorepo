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
    @Test("one room-shard transaction accepts a message without public fanout")
    func atomicallyPersistsAcceptanceWriteSet() async throws {
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
            guard schemaExists?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            let nonFanoutSyncIdentityIndexExists = try #require(try await sql.raw("""
                SELECT to_regclass('im_v2.user_sync_log_nonfanout_identity_idx') IS NOT NULL AS exists
                """).first(decoding: ExistsRow.self))
            #expect(nonFanoutSyncIdentityIndexExists.exists)
            // The message table's room-sequence uniqueness indexes already
            // cover the only room-only existence probe.  A second
            // `(room_id, sender_user_id)` btree would add write amplification
            // to every accepted message without a selective read consumer.
            let redundantMessageRoomSenderIndexIsAbsent = try #require(
                try await sql.raw("""
                    SELECT to_regclass('im_v2.messages_room_sender_idx') IS NULL AS exists
                    """).first(decoding: ExistsRow.self)
            )
            #expect(redundantMessageRoomSenderIndexIsAbsent.exists)
            // A message accepted at a room sequence is represented by exactly
            // one `message.accepted` room event in the same transaction. The
            // room-event uniqueness constraint owns that invariant, while the
            // message table retains only its timeline-order index for reads.
            let redundantMessageRoomSequenceConstraintIsAbsent = try #require(
                try await sql.raw("""
                    SELECT NOT EXISTS (
                        SELECT 1
                        FROM pg_constraint
                        WHERE conname = 'messages_room_id_room_sequence_key'
                          AND conrelid = 'im_v2.messages'::regclass
                    ) AS exists
                    """).first(decoding: ExistsRow.self)
            )
            #expect(redundantMessageRoomSequenceConstraintIsAbsent.exists)
            let projectionReadyOrderIndexExists = try #require(try await sql.raw("""
                SELECT to_regclass(
                    'im_v2.user_projection_checkpoints_ready_order_idx'
                ) IS NOT NULL AS exists
                """).first(decoding: ExistsRow.self))
            #expect(projectionReadyOrderIndexExists.exists)
            let fullSyncIdentityConstraintIsAbsent = try #require(try await sql.raw("""
                SELECT NOT EXISTS (
                    SELECT 1 FROM pg_constraint
                    WHERE conname = 'user_sync_log_user_id_source_event_id_projection_kind_key'
                      AND conrelid = 'im_v2.user_sync_log'::regclass
                ) AS exists
                """).first(decoding: ExistsRow.self))
            #expect(fullSyncIdentityConstraintIsAbsent.exists)
            // Personal writers preserve their own immutable effect, so they
            // retain source-event semantic uniqueness.
            let nonFanoutUserID = UUID(uuidString: "00000000-0000-0000-0000-000000000e01")!
            let nonFanoutSourceEventID = UUID(uuidString: "00000000-0000-0000-0000-000000000e02")!
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                VALUES
                    (\(bind: nonFanoutUserID), 1, \(bind: nonFanoutSourceEventID), 'relationship', '{}'::jsonb, now())
                """).run()
            await #expect(throws: (any Error).self) {
                try await sql.raw("""
                    INSERT INTO im_v2.user_sync_log
                        (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                    VALUES
                        (\(bind: nonFanoutUserID), 2, \(bind: nonFanoutSourceEventID), 'relationship', '{}'::jsonb, now())
                    """).run()
            }
            try await sql.raw("""
                DELETE FROM im_v2.user_sync_log
                WHERE user_id = \(bind: nonFanoutUserID)
                  AND source_event_id = \(bind: nonFanoutSourceEventID)
                  AND projection_kind = 'relationship'
                """).run()
            // Current creation manifests enforce the real three-operation
            // quota and release temporary pages when the original ID closes.
            let audienceActor = try UserID("00000000-0000-0000-0000-000000000e10")
            let audienceOperationA = try GroupRoomOperationID("00000000-0000-0000-0000-000000000e11")
            let audienceOperationB = try GroupRoomOperationID("00000000-0000-0000-0000-000000000e12")
            let audienceMembers = [
                try UserID("00000000-0000-0000-0000-000000000e13"),
                try UserID("00000000-0000-0000-0000-000000000e14")
            ]
            let audienceNow = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, revision, created_at, updated_at)
                VALUES
                    (\(bind: UUID(uuidString: audienceActor.rawValue)!), 'audience_actor', '临时群创建者', 1, \(bind: audienceNow), \(bind: audienceNow)),
                    (\(bind: UUID(uuidString: audienceMembers[0].rawValue)!), 'audience_member_1', '临时群成员一', 1, \(bind: audienceNow), \(bind: audienceNow)),
                    (\(bind: UUID(uuidString: audienceMembers[1].rawValue)!), 'audience_member_2', '临时群成员二', 1, \(bind: audienceNow), \(bind: audienceNow))
                """).run()
            let creation = try V2GroupCreationOperationTestFixture(control: resources.database(.psql),
                owner: resources.database(.psql), shardID: "room-a", capacityProfile: forwardImportTestProfile(), now: { audienceNow })
            let canonical = try V2GroupCreationAudience.canonical(audienceMembers, actorUserID: audienceActor)
            func intent(_ operation: GroupRoomOperationID, at time: Date) throws -> V2GroupCreationIntent {
                try .init(identity: .init(accountID: audienceActor, scope: .account(audienceActor), operation: .groupRoom(operation)),
                    title: "临时群", capacityClass: .standard, initialMemberCount: canonical.count,
                    audienceDigest: V2GroupCreationAudience.digest(canonical),
                    firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(time))
            }
            let first = try intent(audienceOperationA, at: audienceNow)
            let second = try intent(audienceOperationB, at: audienceNow)
            let third = try intent(.init(uuid: UUID()), at: audienceNow)
            let fourth = try intent(.init(uuid: UUID()), at: audienceNow)
            for command in [first, second, third] {
                guard case .progress = try await creation.store.begin(command, now: audienceNow) else { throw CancellationError() }
            }
            guard case .deferred = try await creation.store.begin(fourth, now: audienceNow) else { throw CancellationError() }
            _ = try await creation.store.append(.init(intent: first, offset: 0, memberUserIDs: canonical), now: audienceNow)
            #expect(try await count("im_v2.group_creation_pages", on: sql) == 1)
            guard case .receipt(let closed) = try await creation.store.recover(.init(intent: first, action: .closeIfAbsent), now: audienceNow),
                  case .closed = closed.outcome else { throw CancellationError() }
            #expect(closed.validates(intent: first))
            #expect(try await count("im_v2.group_creation_pages", on: sql) == 0)
            #expect(try await creation.store.recover(.init(intent: first, action: .query), now: audienceNow.addingTimeInterval(700)) == .receipt(closed))
            let later = audienceNow.addingTimeInterval(700)
            guard case .progress = try await creation.store.begin(intent(.init(uuid: UUID()), at: later), now: later) else { throw CancellationError() }
            for expired in [second, third] {
                guard case .receipt(let proof) = try await creation.store.recover(.init(intent: expired, action: .query), now: later),
                      case .rejected(.submissionExpired) = proof.outcome else { throw CancellationError() }
                #expect(proof.validates(intent: expired))
            }
            try await seedRoom(on: sql)

            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3)
            let store = PostgresV2RoomWriteStore(database: resources.database(.psql))
            let service = V2SendMessageService(store: store, capacityProfile: try .init(id: "standard", limits: profile), limits: try .init(maxUTF8Bytes: 64), now: { Date(timeIntervalSince1970: 1_750_000_000) })
            let outcome = try await service.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "transactional"))
            guard case .accepted(let message) = outcome else {
                Issue.record("expected accepted message")
                return
            }
            // Every accepted public message is immediately readable from the
            // durable room log, without per-user message copies.
            let groupLog = V2GroupEventLogService(store: PostgresV2GroupEventLogStore(database: resources.database(.psql)))
            let roomPage = try await groupLog.pull(
                roomID: roomID,
                actorUserID: senderID,
                afterRoomSequence: 0,
                pageSize: 10
            )
            let standardSubscription = try await groupLog.subscribe(roomID: roomID, actorUserID: senderID)
            #expect(roomPage.events.map(\.roomSequence) == [message.roomSequence])
            #expect(roomPage.events.first?.projectionKind == "message")
            #expect(standardSubscription.highWatermark == message.roomSequence)
            try await sql.raw("""
                UPDATE im_v2.rooms SET membership_revision = 1 WHERE room_id = \(bind: roomUUID)
                """).run()
            try await sql.raw("""
                UPDATE im_v2.room_memberships
                SET left_revision = 1
                WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID) AND joined_revision = 0
                """).run()
            let replayAfterLeave = try await service.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "transactional"))

            let acceptedEvent = try await v2MessageAcceptanceFact(
                messageID: message.messageID.uuidValue!, roomID: roomUUID, sql: sql)
            let pushWindow = Date(timeIntervalSince1970: 1_750_000_001)
            let pushDispatchID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
            try await sql.raw("""
                INSERT INTO im_v2.push_campaigns (campaign_id, state, updated_at)
                VALUES ('sync-wake', 'enabled', \(bind: pushWindow))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.push_device_budgets
                    (device_id, campaign_id, window_started_at, max_work_units, max_new_key_operations)
                VALUES (\(bind: UUID(uuidString: deviceID.rawValue)!), 'sync-wake', \(bind: pushWindow), 1, 1)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.push_wake_outbox
                    (dispatch_id, source_event_id, target_user_id, target_device_id, campaign_id, budget_window_started_at, created_at)
                VALUES (\(bind: pushDispatchID), \(bind: acceptedEvent.eventID), \(bind: senderUUID), \(bind: UUID(uuidString: deviceID.rawValue)!), 'sync-wake', \(bind: pushWindow), \(bind: pushWindow))
            """).run()
            let pushStore = PostgresV2PushWakeStore(database: resources.database(.psql), makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000021")! })
            let pushLease = try #require(try await pushStore.claimAdmitted(now: pushWindow, leaseDuration: 30, limit: 1).first)
            try await pushStore.markSent(pushLease, now: pushWindow.addingTimeInterval(1))
            #expect(message.roomSequence == 1)
            #expect(replayAfterLeave == .idempotent(message.receipt))
            #expect(try await count("im_v2.messages", on: sql) == 1)
            #expect(try await count("im_v2.room_events", on: sql) == 1)
            #expect(try await count("im_v2.message_send_completions", on: sql) == 1)
            for table in ["user_sync_log"] {
                #expect(try await count("im_v2." + table, on: sql) == 0)
            }
            let canonicalMessage = try #require(try await sql.raw("SELECT text_body AS value FROM im_v2.messages WHERE message_id = \(bind: message.messageID.uuidValue!)").first(decoding: StringValueRow.self))
            #expect(canonicalMessage.value == "transactional")
            #expect(String(data: try #require(roomPage.events.first).payload, encoding: .utf8)?.contains("transactional") == true)
            await #expect(throws: (any Error).self) {
                try await sql.raw("UPDATE im_v2.room_events SET payload = payload || '{\"text\":\"tampered\"}'::jsonb WHERE event_id = \(bind: acceptedEvent.eventID)").run()
            }
            let capacity = try #require(try await sql.raw("SELECT command_window_used FROM im_v2.room_admission WHERE room_id = \(bind: roomUUID)").first(decoding: CapacityRow.self))
            #expect(capacity.commandWindowUsed == 1)
            let pushState = try #require(try await sql.raw("SELECT state FROM im_v2.push_wake_outbox WHERE dispatch_id = \(bind: pushDispatchID)").first(decoding: PushStateRow.self))
            let pushBudget = try #require(try await sql.raw("SELECT used_work_units, used_new_key_operations FROM im_v2.push_device_budgets WHERE device_id = \(bind: UUID(uuidString: deviceID.rawValue)!)").first(decoding: PushBudgetRow.self))
            #expect(pushLease.wake.deviceID == deviceID)
            #expect(pushState.state == "sent")
            #expect(pushBudget.usedWorkUnits == 1)
            #expect(pushBudget.usedNewKeyOperations == 0)

            let replacementID = UUID(uuidString: "00000000-0000-0000-0000-000000000019")!
            try await sql.raw("""
                UPDATE im_v2.shard_admission_pools
                SET lease_id = \(bind: replacementID), generation = 2,
                    valid_until = \(bind: Date(timeIntervalSince1970: 1_750_000_230)), command_window_used = 0
                WHERE room_shard_id = 'room-a' AND capacity_profile_id = 'standard'
                """).run()
            let cascadedFence = try #require(try await sql.raw("""
                SELECT shard_lease_id, shard_lease_generation
                FROM im_v2.room_admission WHERE room_id = \(bind: roomUUID)
                """).first(decoding: AdmissionFenceRow.self))
            #expect(cascadedFence.shardLeaseID.uuidString == replacementID.uuidString)
            #expect(cascadedFence.shardLeaseGeneration == 2)
            let resetCapacity = try #require(try await sql.raw("""
                SELECT command_window_used
                FROM im_v2.room_admission WHERE room_id = \(bind: roomUUID)
                """).first(decoding: CapacityRow.self))
            #expect(resetCapacity.commandWindowUsed == 0)

            // No explicit policy rows means the group uses its role
            // default. An explicit empty policy has the same materialized
            // row shape, so its current policy identity is the deny-all marker.
            #expect(try await v2ResolvedGroupPermissions(roomID: roomUUID, role: .member, sql: sql) == nil)
            try await sql.raw("INSERT INTO im_v2.group_role_policies (room_id, role) VALUES (\(bind: roomUUID), 'member')").run()
            #expect(try await v2ResolvedGroupPermissions(roomID: roomUUID, role: .member, sql: sql) == [])

            try await assertAllAcceptedMessagesHaveCompletions(sql: sql)
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

    @Test("sync-log statement triggers deduplicate users and preserve immutable effects")
    func syncLogStatementTriggersAreSetBased() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1),
                as: .psql, isDefault: true
            )
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw(
                "SELECT to_regnamespace('im_v2') IS NOT NULL AS exists"
            ).first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let firstUser = UUID(uuidString: "00000000-0000-0000-0000-000000000d01")!
            let secondUser = UUID(uuidString: "00000000-0000-0000-0000-000000000d02")!
            let events = (1 ... 9).map {
                UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", 0xd10 + $0))!
            }
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let later = now.addingTimeInterval(10)
            let backdated = now.addingTimeInterval(-10)
            try await sql.raw(
                "CREATE TABLE im_v2.test_checkpoint_updates (user_id uuid NOT NULL)"
            ).run()
            try await sql.raw(
                "CREATE TABLE im_v2.test_ready_updates (user_id uuid NOT NULL)"
            ).run()
            try await sql.raw("""
                CREATE FUNCTION im_v2.record_test_checkpoint_update() RETURNS trigger
                    LANGUAGE plpgsql AS $$
                BEGIN
                    INSERT INTO im_v2.test_checkpoint_updates (user_id) VALUES (NEW.user_id);
                    RETURN NEW;
                END;
                $$
                """).run()
            try await sql.raw("""
                CREATE FUNCTION im_v2.record_test_ready_update() RETURNS trigger
                    LANGUAGE plpgsql AS $$
                BEGIN
                    INSERT INTO im_v2.test_ready_updates (user_id) VALUES (NEW.user_id);
                    RETURN NEW;
                END;
                $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER record_test_checkpoint_update
                    AFTER UPDATE ON im_v2.user_projection_checkpoints
                    FOR EACH ROW EXECUTE FUNCTION im_v2.record_test_checkpoint_update()
                """).run()
            try await sql.raw("""
                CREATE TRIGGER record_test_ready_update
                    AFTER UPDATE ON im_v2.user_projection_ready
                    FOR EACH ROW EXECUTE FUNCTION im_v2.record_test_ready_update()
                """).run()

            // Four rows and two users produce exactly two checkpoint/retention
            // inserts and no redundant conflict UPDATE.
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id,
                     projection_kind, payload, created_at)
                VALUES
                    (\(bind: firstUser), 1, \(bind: events[0]), 'relationship',
                     '{"state":"pending"}'::jsonb, \(bind: now)),
                    (\(bind: firstUser), 2, \(bind: events[1]), 'relationship',
                     '{"state":"accepted"}'::jsonb, \(bind: now)),
                    (\(bind: secondUser), 1, \(bind: events[2]), 'relationship',
                     '{"state":"pending"}'::jsonb, \(bind: now)),
                    (\(bind: secondUser), 2, \(bind: events[3]), 'relationship',
                     '{"state":"accepted"}'::jsonb, \(bind: now))
                """).run()
            #expect(try await count("im_v2.user_projection_checkpoints", on: sql) == 2)
            #expect(try await count("im_v2.user_sync_retention", on: sql) == 2)
            #expect(try await count("im_v2.user_projection_effects", on: sql) == 4)
            #expect(try await count("im_v2.test_checkpoint_updates", on: sql) == 0)
            #expect(try await count("im_v2.test_ready_updates", on: sql) == 0)

            // Existing per-user control rows must not even enter an INSERT
            // conflict path. In PostgreSQL that path can wait behind an
            // unrelated UPDATE of the same checkpoint before DO NOTHING.
            try await sql.raw("""
                CREATE FUNCTION im_v2.reject_existing_projection_control_insert()
                RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    RAISE EXCEPTION 'existing projection control row must be read, not inserted';
                END;
                $$
                """).run()
            for table in [
                "user_projection_checkpoints",
                "user_projection_ready",
                "user_sync_retention",
            ] {
                try await sql.raw("""
                    CREATE TRIGGER reject_existing_projection_control_insert
                    BEFORE INSERT ON im_v2.\(unsafeRaw: table)
                    FOR EACH ROW
                    EXECUTE FUNCTION im_v2.reject_existing_projection_control_insert()
                    """).run()
            }

            // Newer work must neither insert nor rewrite an unchanged
            // checkpoint/retention/wake tuple.
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id,
                     projection_kind, payload, created_at)
                VALUES
                    (\(bind: firstUser), 3, \(bind: events[4]), 'relationship',
                     '{"state":"accepted"}'::jsonb, \(bind: later)),
                    (\(bind: firstUser), 4, \(bind: events[5]), 'relationship',
                     '{"state":"accepted"}'::jsonb, \(bind: later)),
                    (\(bind: secondUser), 3, \(bind: events[6]), 'relationship',
                     '{"state":"accepted"}'::jsonb, \(bind: later)),
                    (\(bind: secondUser), 4, \(bind: events[7]), 'relationship',
                     '{"state":"accepted"}'::jsonb, \(bind: later))
                """).run()
            #expect(try await count("im_v2.test_checkpoint_updates", on: sql) == 0)
            #expect(try await count("im_v2.test_ready_updates", on: sql) == 0)

            // Backdated restoration work is already represented by the
            // durable wake row. It must not rewrite either row or contend
            // with a projector that currently owns them.
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id,
                     projection_kind, payload, created_at)
                VALUES
                    (\(bind: firstUser), 5, \(bind: events[8]), 'relationship',
                     '{"state":"accepted"}'::jsonb, \(bind: backdated))
                """).run()
            #expect(try await count("im_v2.test_checkpoint_updates", on: sql) == 0)
            #expect(try await count("im_v2.test_ready_updates", on: sql) == 0)
            let backdatedCheckpoint = try #require(try await sql.raw("""
                SELECT COUNT(*) AS value
                FROM im_v2.user_projection_checkpoints
                WHERE user_id = \(bind: firstUser) AND updated_at = \(bind: now)
                """).first(decoding: CountRow.self))
            #expect(backdatedCheckpoint.value == 1)

            // Compaction may remove a sync-log row while its stable projection
            // effect remains. Reusing that immutable identity with a different
            // body must still abort the complete statement.
            try await sql.raw("""
                DELETE FROM im_v2.user_sync_log
                WHERE user_id = \(bind: firstUser) AND user_sync_sequence = 1
                """).run()
            await #expect(throws: (any Error).self) {
                try await sql.raw("""
                    INSERT INTO im_v2.user_sync_log
                        (user_id, user_sync_sequence, source_event_id,
                         projection_kind, payload, created_at)
                    VALUES
                        (\(bind: firstUser), 6, \(bind: events[0]), 'relationship',
                         '{"state":"conflicting"}'::jsonb, \(bind: later))
                    """).run()
            }
            let conflictingRow = try #require(try await sql.raw("""
                SELECT COUNT(*) AS value FROM im_v2.user_sync_log
                WHERE user_id = \(bind: firstUser) AND user_sync_sequence = 6
                """).first(decoding: CountRow.self))
            #expect(conflictingRow.value == 0)

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

    @Test("projection completion cannot lose a concurrent durable ready enqueue")
    func projectionCompletionFencesConcurrentReadyEnqueue() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4),
                as: .psql,
                isDefault: true
            )
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw(
                "SELECT to_regnamespace('im_v2') IS NOT NULL AS exists"
            ).first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let user = UUID(uuidString: "00000000-0000-0000-0000-000000000d61")!
            let firstEvent = UUID(uuidString: "00000000-0000-0000-0000-000000000d62")!
            let secondEvent = UUID(uuidString: "00000000-0000-0000-0000-000000000d63")!
            let invalidatedUser = UUID(uuidString: "00000000-0000-0000-0000-000000000d64")!
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let payload = """
            {"user_id":"\(invalidatedUser.uuidString)"}
            """
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence)
                VALUES (\(bind: user), 1)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind,
                     payload, created_at)
                VALUES
                    (\(bind: user), 1, \(bind: firstEvent), 'profile_invalidation',
                     \(bind: payload)::jsonb, \(bind: now))
                """).run()

            // The v7 enqueue trigger runs first. This test-only trigger then
            // holds the same INSERT transaction open so the projector can
            // exercise the exact delete-versus-commit race that previously
            // lost the durable ready row.
            let blockerLock: Int64 = 7_316_204_982
            try await sql.raw("""
                CREATE FUNCTION im_v2.zz_test_block_after_projection_enqueue()
                RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    PERFORM pg_advisory_xact_lock(7316204982);
                    RETURN NULL;
                END;
                $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER zz_test_block_after_projection_enqueue
                AFTER INSERT ON im_v2.user_sync_log
                REFERENCING NEW TABLE AS inserted_user_sync_rows
                FOR EACH STATEMENT
                EXECUTE FUNCTION im_v2.zz_test_block_after_projection_enqueue()
                """).run()

            let gate = PostgreSQLTransactionGate()
            let blocker = Task {
                try await resources.database(.psql).transaction { transaction in
                    guard let transactionSQL = transaction as? any SQLDatabase else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    try await transactionSQL.raw(
                        "SELECT pg_advisory_xact_lock(\(bind: blockerLock))"
                    ).run()
                    await gate.holdTransaction()
                }
            }
            await gate.waitUntilHeld()

            var enqueuer: Task<Void, Error>?
            var projector: Task<V2UserProjectionWorkerReport, Error>?
            do {
                enqueuer = Task {
                    try await resources.database(.psql).transaction { transaction in
                        guard let transactionSQL = transaction as? any SQLDatabase else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                        try await transactionSQL.raw("""
                            UPDATE im_v2.user_sync_sequences
                            SET next_sequence = 2
                            WHERE user_id = \(bind: user)
                            """).run()
                        try await transactionSQL.raw("""
                            INSERT INTO im_v2.user_sync_log
                                (user_id, user_sync_sequence, source_event_id,
                                 projection_kind, payload, created_at)
                            VALUES
                                (\(bind: user), 2, \(bind: secondEvent),
                                 'profile_invalidation', \(bind: payload)::jsonb,
                                 \(bind: now.addingTimeInterval(1)))
                            """).run()
                    }
                }
                try await waitForPostgreSQLLockWaiters(
                    1, lockType: "advisory", on: sql
                )
                let worker = PostgresV2UserProjectionWorker(
                    database: resources.database(.psql), batchSize: 1
                )
                projector = Task {
                    try await worker.runOnce(now: now.addingTimeInterval(2))
                }
                try await waitForPostgreSQLLockWaiters(
                    1, lockType: "transactionid", on: sql
                )
            } catch {
                enqueuer?.cancel()
                projector?.cancel()
                await gate.releaseTransaction()
                _ = try? await blocker.value
                _ = try? await enqueuer?.value
                _ = try? await projector?.value
                throw error
            }

            await gate.releaseTransaction()
            try await blocker.value
            try await enqueuer?.value
            let projectionReport = try #require(try await projector?.value)
            #expect(projectionReport == .init(claimed: true, appliedRecordCount: 1))
            #expect(try await count("im_v2.user_projection_ready", on: sql) == 1)
            let lag = try #require(try await sql.raw("""
                SELECT sequence.next_sequence - checkpoint.projected_sequence AS value
                FROM im_v2.user_sync_sequences AS sequence
                JOIN im_v2.user_projection_checkpoints AS checkpoint USING (user_id)
                WHERE sequence.user_id = \(bind: user)
                """).first(decoding: CountRow.self)).value
            #expect(lag == 1)

            let finalWorker = PostgresV2UserProjectionWorker(
                database: resources.database(.psql), batchSize: 1
            )
            #expect(try await finalWorker.runOnce(
                now: now.addingTimeInterval(3)
            ) == .init(claimed: true, appliedRecordCount: 1))
            #expect(try await count("im_v2.user_projection_ready", on: sql) == 0)

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

    @Test("concurrent projectors claim distinct users without duplicate versions")
    func concurrentUserProjectionClaimsRemainExclusive() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4),
                as: .psql,
                isDefault: true
            )
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw(
                "SELECT to_regnamespace('im_v2') IS NOT NULL AS exists"
            ).first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let users = [
                UUID(uuidString: "00000000-0000-0000-0000-000000000d81")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000d82")!,
            ]
            let events = [
                UUID(uuidString: "00000000-0000-0000-0000-000000000d83")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000d84")!,
            ]
            let targets = [
                UUID(uuidString: "00000000-0000-0000-0000-000000000d85")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000d86")!,
            ]
            for index in users.indices {
                try await sql.raw("""
                    INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence)
                    VALUES (\(bind: users[index]), 1)
                    """).run()
                let payload = """
                {"target_user_id":"\(targets[index].uuidString)","state":"accepted","updated_at_ms":1750000000000}
                """
                try await sql.raw("""
                    INSERT INTO im_v2.user_sync_log
                        (user_id, user_sync_sequence, source_event_id, projection_kind,
                         payload, created_at)
                    VALUES (\(bind: users[index]), 1, \(bind: events[index]),
                            'relationship', \(bind: payload)::jsonb, \(bind: now))
                    """).run()
            }

            let worker = PostgresV2UserProjectionWorker(
                database: resources.database(.psql), batchSize: 10
            )
            async let first = worker.runOnce(now: now)
            async let second = worker.runOnce(now: now)
            let (firstReport, secondReport) = try await (first, second)
            #expect(firstReport.appliedRecordCount + secondReport.appliedRecordCount == 2)
            #expect(firstReport.claimed)
            #expect(secondReport.claimed)
            #expect(try await count("im_v2.user_projection_versions", on: sql) == 2)
            #expect(try await worker.runOnce(now: now).claimed == false)

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





    @Test("Push wake retries reclaim expired leases without double-spending admission")
    func pushWakeRetryRecoveryPreservesAdmissionBudget() async throws {
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

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let room = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
            let event = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
            let user = UUID(uuidString: "00000000-0000-0000-0000-000000000303")!
            let device = UUID(uuidString: "00000000-0000-0000-0000-000000000304")!
            let dispatch = UUID(uuidString: "00000000-0000-0000-0000-000000000305")!
            try await sql.raw("""
                INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id)
                VALUES (\(bind: room), 'room-a', 'standard')
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
                VALUES (\(bind: event), \(bind: room), 1, 'message.accepted', \(bind: user), '{}'::jsonb, 0, \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.push_campaigns (campaign_id, state, updated_at)
                VALUES ('wake', 'enabled', \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.push_device_budgets
                    (device_id, campaign_id, window_started_at, max_work_units, max_new_key_operations)
                VALUES (\(bind: device), 'wake', \(bind: now), 1, 1)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.push_wake_outbox
                    (dispatch_id, source_event_id, target_user_id, target_device_id, campaign_id, budget_window_started_at, created_at)
                VALUES (\(bind: dispatch), \(bind: event), \(bind: user), \(bind: device), 'wake', \(bind: now), \(bind: now))
                """).run()

            let store = PostgresV2PushWakeStore(
                database: resources.database(.psql),
                makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000306")! }
            )
            let providerFailed = try #require(try await store.claimAdmitted(now: now, leaseDuration: 30, limit: 1).first)
            try await store.release(providerFailed)
            _ = try #require(try await store.claimAdmitted(now: now.addingTimeInterval(1), leaseDuration: 30, limit: 1).first)
            let reclaimed = try #require(try await store.claimAdmitted(now: now.addingTimeInterval(32), leaseDuration: 30, limit: 1).first)
            try await store.markSent(reclaimed, now: now.addingTimeInterval(33))

            let state = try #require(try await sql.raw("SELECT state, retry_count, admitted_at FROM im_v2.push_wake_outbox WHERE dispatch_id = \(bind: dispatch)").first(decoding: PushRecoveryStateRow.self))
            let budget = try #require(try await sql.raw("SELECT used_work_units, used_new_key_operations FROM im_v2.push_device_budgets WHERE device_id = \(bind: device)").first(decoding: PushBudgetRow.self))
            #expect(state.state == "sent")
            #expect(state.retryCount == 3)
            #expect(state.admittedAt == now)
            #expect(budget.usedWorkUnits == 1)
            #expect(budget.usedNewKeyOperations == 0)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("muted conversation suppresses a generic Push wake before budget admission")
    func mutedConversationSuppressesPushWake() async throws {
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

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let room = UUID(uuidString: "00000000-0000-0000-0000-000000000311")!
            let event = UUID(uuidString: "00000000-0000-0000-0000-000000000312")!
            let user = UUID(uuidString: "00000000-0000-0000-0000-000000000313")!
            let device = UUID(uuidString: "00000000-0000-0000-0000-000000000314")!
            let dispatch = UUID(uuidString: "00000000-0000-0000-0000-000000000315")!
            try await sql.raw("""
                INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id)
                VALUES (\(bind: room), 'room-muted', 'standard')
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
                VALUES (\(bind: event), \(bind: room), 1, 'message.accepted', \(bind: user), '{}'::jsonb, 0, \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.user_room_preferences (revision, user_id, room_id, pinned_at, archived_at, mute_until, updated_at)
                VALUES (1, \(bind: user), \(bind: room), NULL, NULL, \(bind: now.addingTimeInterval(3600)), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.push_campaigns (campaign_id, state, updated_at)
                VALUES ('wake', 'enabled', \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.push_device_budgets
                    (device_id, campaign_id, window_started_at, max_work_units, max_new_key_operations)
                VALUES (\(bind: device), 'wake', \(bind: now), 1, 1)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.push_wake_outbox
                    (dispatch_id, source_event_id, target_user_id, target_device_id, campaign_id, budget_window_started_at, created_at)
                VALUES (\(bind: dispatch), \(bind: event), \(bind: user), \(bind: device), 'wake', \(bind: now), \(bind: now))
                """).run()

            let store = PostgresV2PushWakeStore(database: resources.database(.psql))
            #expect(try await store.claimAdmitted(now: now, leaseDuration: 30, limit: 1).isEmpty)
            let state = try #require(try await sql.raw("SELECT state, suppression_reason FROM im_v2.push_wake_outbox WHERE dispatch_id = \(bind: dispatch)").first(decoding: PushSuppressionStateRow.self))
            let budget = try #require(try await sql.raw("SELECT used_work_units, used_new_key_operations FROM im_v2.push_device_budgets WHERE device_id = \(bind: device)").first(decoding: PushBudgetRow.self))
            #expect(state.state == "suppressed")
            #expect(state.suppressionReason == "conversation_muted")
            #expect(budget.usedWorkUnits == 0)
            #expect(budget.usedNewKeyOperations == 0)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("versioned Push intent survives reordering, replay, session changes and APNs rejection")
    func pushIntentConditionalWrites() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"), Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        let app = try await Application(.testing)
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let device = DeviceID(uuid: UUID())
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: senderUUID), \(bind: device.uuidValue), \(bind: now), \(bind: now))").run()
            let key = try V2PushEndpointEnvelopeKey(rawBytes: Data(repeating: 17, count: 32))
            let store = PostgresV2PushDeviceEndpointStore(database: resources.database(.psql), envelopeKey: key)
            let firstToken = try V2PushDeviceEndpointRegistration(provider: .apns, environment: .development, token: String(repeating: "1", count: 64))
            let secondToken = try V2PushDeviceEndpointRegistration(provider: .apns, environment: .development, token: String(repeating: "2", count: 64))
            // Register a real encrypted endpoint before exercising ordered intent writes.
            try await store.register(actorUserID: senderID, deviceID: device, endpoint: firstToken, now: now)
            try await V2SchemaReadiness.verify(database: resources.database(.psql))
            try await assertSQLSchemaGate(true, on: sql)
            let constraints = [
                ("push_device_intents_pkey", "PRIMARY KEY (device_id)"),
                ("push_device_intents_session_epoch_check", "CHECK (session_epoch > 0)"),
                ("push_device_intents_intent_revision_check", "CHECK (intent_revision >= 0)"),
                ("push_device_intents_digest_check", "CHECK ((intent_revision = 0 AND intent_digest IS NULL) OR (intent_revision > 0 AND intent_digest IS NOT NULL AND octet_length(intent_digest) = 32))"),
                ("push_device_intents_device_id_fkey", "FOREIGN KEY (device_id) REFERENCES im_v2.auth_devices(device_id) ON DELETE RESTRICT"),
            ]
            for (name, definition) in constraints {
                try await sql.raw("ALTER TABLE im_v2.push_device_intents DROP CONSTRAINT \(unsafeRaw: name)").run()
                await #expect(throws: V2SchemaReadinessError.self) { try await V2SchemaReadiness.verify(database: resources.database(.psql)) }
                try await assertSQLSchemaGate(false, on: sql)
                try await sql.raw("ALTER TABLE im_v2.push_device_intents ADD CONSTRAINT \(unsafeRaw: name) \(unsafeRaw: definition)").run()
            }
            // Use a fresh device for the disable-before-any-registration case.
            try await sql.raw("DELETE FROM im_v2.push_device_endpoints WHERE device_id = \(bind: device.uuidValue)").run()
            #expect(try await store.intentEpoch(actorUserID: senderID, deviceID: device) == 0)
            let firstClaim = try V2PushIntentSessionClaim(requestID: UUID(), expectedEpoch: 0)
            #expect(try await store.claimIntentSession(actorUserID: senderID, deviceID: device, claim: firstClaim, now: now) == 1)
            #expect(try await store.claimIntentSession(actorUserID: senderID, deviceID: device, claim: firstClaim, now: now) == 1)
            await #expect(throws: V2PushDeviceEndpointError.staleIntent) {
                try await store.claimIntentSession(actorUserID: senderID, deviceID: device, claim: .init(requestID: UUID(), expectedEpoch: 0), now: now)
            }
            // Disable arrives before any endpoint exists. Its revision is
            // still durable and prevents a delayed enable from creating one.
            try await store.publishIntent(actorUserID: senderID, deviceID: device, version: .init(epoch: 1, revision: 2), intent: .disabled, now: now)
            await #expect(throws: V2PushDeviceEndpointError.staleIntent) {
                try await store.publishIntent(actorUserID: senderID, deviceID: device, version: .init(epoch: 1, revision: 1), intent: .enabled(firstToken), now: now)
            }
            #expect(try await store.endpoint(for: device) == nil)
            try await store.publishIntent(actorUserID: senderID, deviceID: device, version: .init(epoch: 1, revision: 2), intent: .disabled, now: now)
            await #expect(throws: V2PushDeviceEndpointError.intentConflict) {
                try await store.publishIntent(actorUserID: senderID, deviceID: device, version: .init(epoch: 1, revision: 2), intent: .enabled(firstToken), now: now)
            }
            try await store.publishIntent(actorUserID: senderID, deviceID: device, version: .init(epoch: 1, revision: 3), intent: .enabled(firstToken), now: now)
            let firstEndpoint = try #require(try await store.endpoint(for: device))
            try await store.publishIntent(actorUserID: senderID, deviceID: device, version: .init(epoch: 1, revision: 4), intent: .enabled(secondToken), now: now)
            let secondEndpoint = try #require(try await store.endpoint(for: device))
            #expect(firstEndpoint.generation != secondEndpoint.generation)
            try await store.disable(firstEndpoint, now: now)
            try await store.publishIntent(actorUserID: senderID, deviceID: device, version: .init(epoch: 1, revision: 4), intent: .enabled(secondToken), now: now)
            #expect(try await store.endpoint(for: device) == secondEndpoint)
            await #expect(throws: V2PushDeviceEndpointError.intentVersionRequired) { try await store.register(actorUserID: senderID, deviceID: device, endpoint: firstToken, now: now) }
            await #expect(throws: V2PushDeviceEndpointError.intentVersionRequired) { try await store.disableOwnedEndpoint(actorUserID: senderID, deviceID: device, now: now) }

            let secondClaim = try V2PushIntentSessionClaim(requestID: UUID(), expectedEpoch: 1)
            #expect(try await store.claimIntentSession(actorUserID: senderID, deviceID: device, claim: secondClaim, now: now) == 2)
            await #expect(throws: V2PushDeviceEndpointError.staleIntent) { try await store.claimIntentSession(actorUserID: senderID, deviceID: device, claim: firstClaim, now: now) }
            await #expect(throws: V2PushDeviceEndpointError.staleIntent) { try await store.publishIntent(actorUserID: senderID, deviceID: device, version: .init(epoch: 1, revision: UInt64(Int64.max)), intent: .enabled(firstToken), now: now) }
            try await store.publishIntent(actorUserID: senderID, deviceID: device, version: .init(epoch: 2, revision: 1), intent: .disabled, now: now)
            // Retrying a successful session claim must not reset revisions.
            #expect(try await store.claimIntentSession(actorUserID: senderID, deviceID: device, claim: secondClaim, now: now) == 2)
            await #expect(throws: V2PushDeviceEndpointError.intentConflict) { try await store.publishIntent(actorUserID: senderID, deviceID: device, version: .init(epoch: 2, revision: 1), intent: .enabled(firstToken), now: now) }
            let reopened = PostgresV2PushDeviceEndpointStore(database: resources.database(.psql), envelopeKey: key)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for revision in 2...40 {
                    group.addTask {
                        do {
                            try await reopened.publishIntent(actorUserID: senderID, deviceID: device, version: .init(epoch: 2, revision: UInt64(revision)), intent: revision.isMultiple(of: 2) ? .disabled : .enabled(firstToken), now: now)
                        } catch V2PushDeviceEndpointError.staleIntent { }
                    }
                }
                try await group.waitForAll()
            }
            #expect(try await reopened.endpoint(for: device) == nil)
            #expect(try await sql.raw("SELECT intent_revision AS value FROM im_v2.push_device_intents WHERE device_id = \(bind: device.uuidValue)").first(decoding: CountRow.self)?.value == 40)
            try await reopened.publishIntent(actorUserID: senderID, deviceID: device, version: .init(epoch: 2, revision: 41), intent: .enabled(firstToken), now: now)
            let rejected = try #require(try await reopened.endpoint(for: device))
            try await reopened.disable(rejected, now: now)
            try await reopened.publishIntent(actorUserID: senderID, deviceID: device, version: .init(epoch: 2, revision: 41), intent: .enabled(firstToken), now: now)
            #expect(try await reopened.endpoint(for: device) == nil)
            try await reopened.publishIntent(actorUserID: senderID, deviceID: device, version: .init(epoch: 2, revision: 42), intent: .enabled(secondToken), now: now)
            try await reopened.disable(rejected, now: now)
            let finalEndpoint = try #require(try await reopened.endpoint(for: device))
            #expect(finalEndpoint.token == secondToken.token)
            // Fail the version receipt after the endpoint write. Both must
            // roll back together, preserving the prior endpoint generation.
            try await sql.raw("ALTER TABLE im_v2.push_device_intents ADD CONSTRAINT test_intent_rollback CHECK (intent_revision <> 43)").run()
            await #expect(throws: (any Error).self) { try await reopened.publishIntent(actorUserID: senderID, deviceID: device, version: .init(epoch: 2, revision: 43), intent: .enabled(firstToken), now: now) }
            #expect(try await reopened.endpoint(for: device) == finalEndpoint)
            try await sql.raw("ALTER TABLE im_v2.push_device_intents DROP CONSTRAINT test_intent_rollback").run()
            await #expect(throws: V2PushDeviceEndpointError.deviceUnavailable) { try await reopened.publishIntent(actorUserID: .init(uuid: memberTwoUUID), deviceID: device, version: .init(epoch: 2, revision: 43), intent: .disabled, now: now) }
            try await sql.raw("UPDATE im_v2.auth_devices SET revoked_at = \(bind: now) WHERE device_id = \(bind: device.uuidValue)").run()
            await #expect(throws: V2PushDeviceEndpointError.deviceUnavailable) { try await reopened.claimIntentSession(actorUserID: senderID, deviceID: device, claim: .init(requestID: UUID(), expectedEpoch: 2), now: now) }
            #expect(try await reopened.endpoint(for: device) == nil)
            // Exercise the actual HTTP decoder/status boundary against the
            // PostgreSQL conditional writer, including a delayed legacy PUT.
            let httpIdentity = PushIntentRouteAuthenticator()
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: httpIdentity.user.uuidValue), \(bind: httpIdentity.device.uuidValue), \(bind: now), \(bind: now))").run()
            V2VaporPushIntentRoutes(authenticator: httpIdentity, store: reopened).register(on: app)
            V2VaporPushEndpointRoutes(authenticator: httpIdentity, store: reopened).register(on: app)
            var headers: HTTPFields = [:]
            headers[.authorization] = "Bearer access-token"
            headers[.init("X-IM-Device-ID")!] = httpIdentity.device.rawValue
            headers.contentType = .json
            let requestID = UUID()
            try await app.testing { client in
                let response = try await client.send(.post, headers: headers, to: "v2/push-endpoint/session", beforeSend: {
                    $0.body = .init(string: "{\"requestID\":\"\(requestID)\",\"expectedEpoch\":0}")
                })
                #expect(response.status == .ok)
            }
            let enabled = "{\"epoch\":1,\"revision\":1,\"enabled\":true,\"provider\":\"apns\",\"environment\":\"development\",\"token\":\"\(firstToken.token)\"}"
            for (body, status) in [("{\"epoch\":1,\"revision\":2,\"enabled\":false}", 204), (enabled, 409), (enabled.replacingOccurrences(of: "\"revision\":1", with: "\"revision\":3"), 204)] {
                try await app.testing { client in
                    let response = try await client.send(.put, headers: headers, to: "v2/push-endpoint/intent", beforeSend: { $0.body = .init(string: body) })
                    #expect(response.status.code == status)
                    #expect(response.headers[.cacheControl] == "no-store")
                }
                #expect(try await reopened.endpoint(for: httpIdentity.device) == nil || body.contains("\"revision\":3"))
            }
            let httpEndpoint = try #require(try await reopened.endpoint(for: httpIdentity.device))
            try await app.testing { client in
                let response = try await client.send(.put, headers: headers, to: "v2/push-endpoint", beforeSend: {
                    $0.body = .init(string: "{\"provider\":\"apns\",\"environment\":\"development\",\"token\":\"\(secondToken.token)\"}")
                })
                #expect(response.status == .preconditionRequired)
            }
            #expect(try await reopened.endpoint(for: httpIdentity.device) == httpEndpoint)
            try await V2SchemaReadiness.verify(database: resources.database(.psql))
            try await assertSQLSchemaGate(true, on: sql)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.shutdown(); try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.shutdown(); try? await resources.shutdown(); throw error
        }
    }

    @Test("Push endpoint encryption is device-bound and late rejection cannot disable a fresh registration")
    func pushEndpointRegistrationUsesGenerationFence() async throws {
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
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("""
                INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at)
                VALUES (\(bind: senderUUID), \(bind: UUID(uuidString: deviceID.rawValue)!), \(bind: now), \(bind: now))
                """).run()
            let key = try V2PushEndpointEnvelopeKey(rawBytes: Data(repeating: 7, count: 32))
            let store = PostgresV2PushDeviceEndpointStore(
                database: resources.database(.psql),
                envelopeKey: key
            )
            let firstToken = String(repeating: "a", count: 64)
            try await store.register(
                actorUserID: senderID,
                deviceID: deviceID,
                endpoint: try .init(provider: .apns, environment: .development, token: firstToken),
                now: now
            )
            let first = try #require(try await store.endpoint(for: deviceID))
            try await store.register(
                actorUserID: senderID,
                deviceID: deviceID,
                endpoint: try .init(provider: .apns, environment: .production, token: String(repeating: "b", count: 64)),
                now: now.addingTimeInterval(1)
            )
            try await store.disable(first, now: now.addingTimeInterval(2))
            let current = try #require(try await store.endpoint(for: deviceID))
            let encrypted = try #require(try await sql.raw("""
                SELECT encrypted_token FROM im_v2.push_device_endpoints
                WHERE device_id = \(bind: UUID(uuidString: deviceID.rawValue)!)
                """).first(decoding: EncryptedPushEndpointRow.self))

            #expect(current.generation != first.generation)
            #expect(current.environment == .production)
            #expect(current.token == String(repeating: "b", count: 64))
            #expect(encrypted.encryptedToken != current.token)

            try await store.disable(current, now: now.addingTimeInterval(3))
            #expect(try await store.endpoint(for: deviceID) == nil)
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

    @Test("direct rooms enforce recipient setting and stranger quota transactionally")
    func enforcesStrangerDirectMessagePolicy() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let schemaExists = try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self)
            guard schemaExists?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_100_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 100,    retryAfterSeconds: 3))
            let leaseID = UUID(uuidString: "00000000-0000-0000-0000-000000000071")!
            try await sql.raw("INSERT INTO im_v2.shard_admission_pools (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit) VALUES ('rooms-primary', 'standard', \(bind: leaseID), 1, \(bind: now.addingTimeInterval(600)), 100)").run()
            try await sql.raw("INSERT INTO im_v2.public_user_profiles (user_id, public_handle, display_name, revision, created_at, updated_at) VALUES (\(bind: senderUUID), 'sender012', '发送者', 1, \(bind: now), \(bind: now)), (\(bind: memberTwoUUID), 'member015', '成员二', 1, \(bind: now), \(bind: now)), (\(bind: memberThreeUUID), 'member016', '成员三', 1, \(bind: now), \(bind: now))").run()
            let directStore = PostgresV2DirectMessagingStore(database: resources.database(.psql), identityReader: PostgresV2DirectRoomIdentityReader(database: resources.database(.psql)), projectionDelivery: SuccessfulProjectionDelivery())
            let directService = try V2DirectRoomOperationTestFixture(store: directStore, capacityProfile: profile, roomShardID: "rooms-primary", now: { now })
            let recipient = try UserID(memberTwoUUID.uuidString)
            let openingOperation = try DirectRoomOperationID("00000000-0000-0000-0000-000000000072")
            let room = try await directService.openedIdentity(actorUserID: senderID, operationID: openingOperation,
                targetUserID: recipient, firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            let replayed = try await directService.openedReceipt(actorUserID: senderID, operationID: openingOperation,
                targetUserID: recipient, firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            #expect(replayed == room.receipt)
            let accountPreferences = PostgresV2AccountPreferenceOperationStore(database: resources.database(.psql),
                projectionDelivery: SuccessfulProjectionDelivery(), authorizationCoordinator:
                    V2DirectAuthorizationCoordinator(controlDatabase: resources.database(.psql),
                        ownerDatabases: ["rooms-primary": resources.database(.psql)]))
            // This fixture co-locates the user owner. Materialize the durable
            // opening event explicitly before asserting its user snapshot.
            let openingOutbox = try PostgresV2UserStateEventOutbox(database: resources.database(.psql))
            let openingProjector = try PostgresV2UserStateEventProjector(database: resources.database(.psql))
            let openingEligible = try #require(try await sql.raw("SELECT MAX(next_attempt_at) AS value FROM im_v2.user_state_event_outbox WHERE state = 'pending'").first(decoding: ProjectionEligibleDate.self)).value
            let openingLeases = try await openingOutbox.claim(now: openingEligible, leaseDuration: 30, limit: 16)
            #expect(openingLeases.count == 1)
            for lease in openingLeases {
                let sequence = try await openingProjector.project(lease.event)
                #expect(try await openingOutbox.acknowledge(lease, sequence: sequence, now: openingEligible))
            }
            let directProfiles = try await sql.raw("""
                SELECT user_id, payload->>'room_id' AS room_id, payload->>'target_user_id' AS target_user_id,
                       payload->>'public_handle' AS public_handle, payload->>'display_name' AS display_name,
                       (payload->>'revision')::bigint AS revision
                FROM im_v2.user_sync_log
                WHERE projection_kind = 'direct_room_profile'
                ORDER BY user_id
                """).all(decoding: DirectProfileSyncAssertionRow.self)
            #expect(directProfiles == [
                .init(userID: senderUUID, roomID: room.roomID.rawValue.uppercased(), targetUserID: memberTwoUUID, publicHandle: "member015", displayName: "成员二", revision: 1),
            ])
            let openedPairState = try #require(try await sql.raw("""
                SELECT lower_profile_visible_to_higher, higher_profile_visible_to_lower,
                       lower_can_send, higher_can_send
                FROM im_v2.direct_room_pairs
                WHERE room_id = \(bind: UUID(uuidString: room.roomID.rawValue)!)
                """).first(decoding: DirectPairProjectionStateAssertionRow.self))
            #expect(openedPairState == .init(
                lowerProfileVisibleToHigher: false,
                higherProfileVisibleToLower: true,
                lowerCanSend: nil,
                higherCanSend: nil
            ))
            try await drainV3Projection(database: resources.database(.psql))
            let snapshotDirectProfiles = try await currentV3ProjectionItems(sql: sql, userID: senderID, kind: "direct_room_profile")
            #expect(snapshotDirectProfiles.count == 1)
            #expect(snapshotDirectProfiles.first?.entityKey == room.roomID.rawValue)
            #expect(snapshotDirectProfiles.first?.string("target_user_id") == recipient.rawValue)
            // Account-owned add permissions are present in delivered history,
            // but a reset must rebuild them from their authoritative table.
            // This also proves the materializer accepts the non-message record.
            _ = try await accountPreferences.executePreferenceFixture(owner: senderID,
                operation: .userAddPreference(try .init("00000000-0000-0000-0000-000000000082")), value: .userAdd(.deny), now: now)
            try await drainV3Projection(database: resources.database(.psql))
            let userAddPreferences = try await currentV3ProjectionItems(sql: sql, userID: senderID, kind: "user_add_permission")
            #expect(userAddPreferences.count == 1)
            #expect(userAddPreferences.first?.bool("allows_being_added") == false)

            _ = try await accountPreferences.executePreferenceFixture(owner: recipient, operation: .strangerMessagePreference(try .init("00000000-0000-0000-0000-000000000073")), value: .strangerMessage(.deny), now: now)
            let otherRecipient = try UserID(memberThreeUUID.uuidString)
            let otherRoom = try await directService.openedIdentity(actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000083"), targetUserID: otherRecipient,
                firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            let preferenceOperationID = try ReadReceiptPreferenceOperationID("00000000-0000-0000-0000-000000000084")
            let frozenPreferences = try await accountPreferences.freezePreferenceFixture(owner: senderID,
                operation: .readReceiptPreference(preferenceOperationID),
                value: .readReceipt(allowsDirectReadReceipts: false, allowsGroupReadReceipts: true), now: now)
            let disabledReceipts = try await accountPreferences.submit(frozenPreferences, now: now)
            guard case .receipt(let receiptPreferences) = disabledReceipts,
                  case .applied = receiptPreferences.outcome else { throw CancellationError() }
            #expect(try await accountPreferences.submit(frozenPreferences, now: now) == disabledReceipts)
            try await sql.raw("""
                INSERT INTO im_v2.direct_room_owner_routes
                    (lower_user_id, higher_user_id, room_id, room_shard_id, route_epoch, created_at, updated_at)
                SELECT pair.lower_user_id, pair.higher_user_id, pair.room_id, room.room_shard_id,
                       room.owner_epoch, \(bind: now), \(bind: now)
                FROM im_v2.direct_room_pairs AS pair JOIN im_v2.rooms AS room USING (room_id)
                """).run()
            struct ReceiptFence: V2UserShardRouteFencing {
                let database: any Database
                func withCurrentRoute<Result: Sendable>(for userID: UserID,
                    _ operation: @escaping @Sendable (V2UserShardRoute, any Database) async throws -> Result) async throws -> Result {
                    try await database.transaction { transaction in
                        try await operation(.init(bucket: "receipt-user", observedRouterEpoch: 1), transaction)
                    }
                }
            }
            let receiptProjector = try V2RoutedUserStateEventProjector(routeFence: ReceiptFence(database: resources.database(.psql)),
                registry: V2StaticUserShardStorageRegistry(locations: [.init(bucket: "receipt-user", database: resources.database(.psql), schema: "im_v2")]))
            func deliverReceiptCandidates() async throws -> Int {
                let outbox = try PostgresV2UserStateEventOutbox(database: resources.database(.psql))
                let eligible = try #require(try await sql.raw("SELECT MAX(next_attempt_at) AS value FROM im_v2.user_state_event_outbox WHERE state = 'pending'").first(decoding: ProjectionEligibleDate.self)).value
                let leases = try await deliverUserStateEvents(outbox, projector: receiptProjector, now: eligible)
                    .filter { $0.event.kind == .directReadReceipt }
                return leases.count
            }
            let beforePropagation = try #require(try await sql.raw("SELECT COUNT(*)::int AS value, COUNT(DISTINCT source_event_id)::int AS distinct_sources FROM im_v2.user_sync_log WHERE projection_kind = 'direct_read_receipt'").first(decoding: ReceiptTombstoneCountAssertionRow.self))
            #expect(beforePropagation.value == 0)
            let receiptPropagation = V2ReadReceiptPreferencePropagationWorker(
                database: resources.database(.psql),
                now: { now }
            )
            #expect(try await receiptPropagation.runOnce(limit: 1) == .init(
                claimedOperationCount: 1,
                projectedRoomCount: 1,
                completedOperationCount: 0
            ))
            #expect(try await receiptPropagation.runOnce(limit: 1) == .init(
                claimedOperationCount: 1,
                projectedRoomCount: 1,
                completedOperationCount: 1
            ))
            #expect(try await count("im_v2.user_sync_log WHERE projection_kind = 'direct_read_receipt'", on: sql) == 0)
            #expect(try await deliverReceiptCandidates() == 4)
            let receiptTombstones = try #require(try await sql.raw("SELECT COUNT(*)::int AS value, COUNT(DISTINCT source_event_id)::int AS distinct_sources FROM im_v2.user_sync_log WHERE projection_kind = 'direct_read_receipt'").first(decoding: ReceiptTombstoneCountAssertionRow.self))
            #expect(receiptTombstones.value == 4)
            #expect(receiptTombstones.distinctSources == 2)
            _ = try await accountPreferences.executePreferenceFixture(owner: senderID,
                operation: .readReceiptPreference(try .init("00000000-0000-0000-0000-000000000085")),
                value: .readReceipt(allowsDirectReadReceipts: true, allowsGroupReadReceipts: true), now: now)
            let retryPreferenceOperationID = try ReadReceiptPreferenceOperationID("00000000-0000-0000-0000-000000000086")
            _ = try await accountPreferences.executePreferenceFixture(owner: senderID,
                operation: .readReceiptPreference(retryPreferenceOperationID),
                value: .readReceipt(allowsDirectReadReceipts: false, allowsGroupReadReceipts: true), now: now)
            try await sql.raw("""
                CREATE FUNCTION im_v2.test_interrupt_receipt_page() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    RAISE EXCEPTION 'injected receipt checkpoint interruption' USING ERRCODE = '08006';
                END $$
                """).run()
            try await sql.raw("CREATE TRIGGER test_interrupt_receipt_page BEFORE UPDATE OF enumeration_checkpoint ON im_v2.read_receipt_preference_propagation_outbox FOR EACH ROW EXECUTE FUNCTION im_v2.test_interrupt_receipt_page()").run()
            let interruptedPropagation = V2ReadReceiptPreferencePropagationWorker(
                database: resources.database(.psql),
                retryPolicy: .init(maximumAttempts: 1),
                now: { now }
            )
            #expect(try await interruptedPropagation.runOnce(limit: 1) == .init(
                claimedOperationCount: 1,
                projectedRoomCount: 1,
                completedOperationCount: 0,
                releasedOperationCount: 1
            ))
            try await sql.raw("DROP TRIGGER test_interrupt_receipt_page ON im_v2.read_receipt_preference_propagation_outbox").run()
            // The real checkpoint failure preserves committed candidates. Explicitly
            // pause that retry to exercise operator recovery after the fault is removed.
            try await sql.raw("""
                UPDATE im_v2.read_receipt_preference_propagation_outbox
                SET state = 'paused', paused_at = \(bind: now), claim_token = NULL,
                    lease_expires_at = NULL, next_attempt_at = NULL
                WHERE actor_user_id = \(bind: senderUUID)
                  AND operation_id = \(bind: UUID(uuidString: retryPreferenceOperationID.rawValue)!)
                """).run()
            let pausedPropagation = try #require(try await sql.raw("SELECT state, retry_count FROM im_v2.read_receipt_preference_propagation_outbox WHERE actor_user_id = \(bind: senderUUID) AND operation_id = \(bind: UUID(uuidString: retryPreferenceOperationID.rawValue)!)").first(decoding: DurableRetryStateRow.self))
            #expect(pausedPropagation.state == "paused")
            #expect(pausedPropagation.retryCount == 1)
            let replayResult = try await PostgresV2DurableWorkReplayStore(database: resources.database(.psql)).replay(
                .init(
                    operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000087")!,
                    target: try .init(
                        kind: .readReceiptPreferencePropagation,
                        sourceEventID: .init(retryPreferenceOperationID.rawValue),
                        targetUserID: senderID
                    ),
                    reason: .dependencyRecovered
                ),
                operatorPrincipal: "integration-test",
                now: now
            )
            #expect(replayResult.outcome == .requeued)
            #expect(try await receiptPropagation.runOnce(limit: 1) == .init(claimedOperationCount: 1, projectedRoomCount: 1, completedOperationCount: 0))
            #expect(try await receiptPropagation.runOnce(limit: 1) == .init(claimedOperationCount: 1, projectedRoomCount: 1, completedOperationCount: 1))
            #expect(try await deliverReceiptCandidates() == 4)
            #expect(try await count("im_v2.user_sync_log WHERE projection_kind = 'direct_read_receipt'", on: sql) == 8)
            try await V2PostgresUserShardRouter(database: resources.database(.psql)).bootstrap(
                defaultRoute: try .init(bucket: "test-users", observedRouterEpoch: 9)
            )
            let writer = PostgresV2RoomWriteStore(
                database: resources.database(.psql),
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 3, window: 86_400),
                contentReviewMode: .enabled)
            let messages = V2SendMessageService(store: writer, capacityProfile: profile, limits: try .init(maxUTF8Bytes: 64), now: { now })
            let deniedOutcome = try await messages.send(.init(roomID: room.roomID, actorUserID: senderID, clientMessageID: try .init("00000000-0000-0000-0000-000000000074"), text: "blocked-by-setting"))
            guard case .denied(let denial) = deniedOutcome else {
                Issue.record("expected a durable private denial")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            #expect(denial.reason == .generic)
            let crossRoomReplay = try await messages.send(.init(
                roomID: otherRoom.roomID,
                actorUserID: senderID,
                clientMessageID: try .init("00000000-0000-0000-0000-000000000074"),
                text: "independent-room-operation"
            ))
            guard case .accepted = crossRoomReplay else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let originalDenialReplay = try await messages.send(.init(
                roomID: room.roomID,
                actorUserID: senderID,
                clientMessageID: try .init("00000000-0000-0000-0000-000000000074"),
                text: "blocked-by-setting"
            ))
            #expect(originalDenialReplay == .denied(denial))
            let changedDeniedIntent = try await messages.send(.init(
                roomID: room.roomID,
                actorUserID: senderID,
                clientMessageID: try .init("00000000-0000-0000-0000-000000000074"),
                text: "different-denied-intent"
            ))
            #expect(changedDeniedIntent == .idempotencyConflict)
            let denialActivity = try #require(try await sql.raw("SELECT activity_type FROM im_v2.room_timeline_activities WHERE source_event_id = \(bind: UUID(uuidString: denial.sourceEventID.rawValue)!)").first(decoding: TimelineActivityTypeAssertionRow.self))
            #expect(denialActivity.activityType == "direct_message_restricted")
            let denialSource = try #require(denial.sourceEventID.uuidValue)
            #expect(try await sql.raw("""
                SELECT count(*)::bigint AS value FROM im_v2.user_sync_log
                WHERE source_event_id = \(bind: denialSource)
                """).first(decoding: CountRow.self)?.value == 0)
            #expect(try await sql.raw("""
                SELECT count(*)::bigint AS value FROM im_v2.user_state_event_outbox
                WHERE source_event_id = \(bind: denialSource) AND user_id = \(bind: senderUUID)
                """).first(decoding: CountRow.self)?.value == 2)
            if let targetURL = Environment.get("IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL") {
                #expect(targetURL != databaseURL)
                try await withUserEventDatabase(databaseURL: targetURL) { targetDatabase, targetSQL, targetSchema in
                    let outbox = try PostgresV2UserStateEventOutbox(database: resources.database(.psql))
                    let projector = try PostgresV2UserStateEventProjector(database: targetDatabase, schema: targetSchema)
                    let leases = try await deliverUserStateEvents(outbox, projector: projector, now: now)
                        .filter { $0.event.sourceEventID == denial.sourceEventID }
                    #expect(leases.count == 2)
                    var sequences = Set<UInt64>()
                    for lease in leases {
                        #expect(lease.event.userID == senderID)
                        let sequence = try await projector.project(lease.event)
                        sequences.insert(sequence)
                        // A lost source ACK reuses the target receipt and sequence.
                        #expect(try await projector.project(lease.event) == sequence)
                    }
                    // Earlier, unrelated stream heads must also be delivered. The
                    // two denial effects remain consecutive and reuse their receipts.
                    #expect(sequences.count == 2 && sequences.max() == sequences.min().map { $0 + 1 })
                    #expect(try await targetSQL.raw("""
                        SELECT count(*)::bigint AS value FROM \(unsafeRaw: targetSchema).user_sync_log
                        WHERE user_id = \(bind: senderUUID) AND source_event_id = \(bind: denialSource)
                        """).first(decoding: CountRow.self)?.value == 2)
                    #expect(try await targetSQL.raw("""
                        SELECT count(*)::bigint AS value FROM \(unsafeRaw: targetSchema).user_sync_log
                        WHERE user_id = \(bind: memberTwoUUID)
                        """).first(decoding: CountRow.self)?.value == 0)
                }
            }
            let deniedRecipientProfiles = try #require(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE user_id = \(bind: memberTwoUUID) AND projection_kind = 'direct_room_profile'").first(decoding: CountRow.self))
            #expect(deniedRecipientProfiles.value == 0)
            let deniedPairState = try #require(try await sql.raw("""
                SELECT lower_profile_visible_to_higher, higher_profile_visible_to_lower,
                       lower_can_send, higher_can_send
                FROM im_v2.direct_room_pairs
                WHERE room_id = \(bind: UUID(uuidString: room.roomID.rawValue)!)
                """).first(decoding: DirectPairProjectionStateAssertionRow.self))
            #expect(deniedPairState.lowerCanSend == false)

            _ = try await accountPreferences.executePreferenceFixture(owner: recipient, operation: .strangerMessagePreference(try .init("00000000-0000-0000-0000-000000000075")), value: .strangerMessage(.allow), now: now)
            let attempts = await withTaskGroup(of: StrangerMessageAttempt.self, returning: [StrangerMessageAttempt].self) { group in
                for suffix in 76...79 {
                    group.addTask {
                        do {
                            let result = try await messages.send(.init(roomID: room.roomID, actorUserID: senderID, clientMessageID: try .init("00000000-0000-0000-0000-0000000000\(suffix)"), text: "stranger"))
                            if case .accepted = result { return .accepted }
                            return .unexpectedOutcome
                        } catch V2RoomWriteStoreError.strangerMessageLimitReached {
                            return .limited
                        } catch {
                            return .unexpectedFailure
                        }
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            #expect(attempts.filter { $0 == .accepted }.count == 3)
            #expect(attempts.filter { $0 == .limited }.count == 1)
            #expect(!attempts.contains(.unexpectedOutcome))
            #expect(!attempts.contains(.unexpectedFailure))
            let acceptedRecipientProfiles = try #require(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_state_event_outbox WHERE user_id = \(bind: memberTwoUUID) AND projection_kind = 'direct_room_profile' AND (payload->>'room_id')::uuid = \(bind: UUID(uuidString: room.roomID.rawValue)!)").first(decoding: CountRow.self))
            #expect(acceptedRecipientProfiles.value == 1)
            #expect(try await sql.raw("""
                SELECT count(*)::bigint AS value FROM im_v2.user_state_event_outbox
                WHERE projection_kind IN ('direct_room_profile', 'direct_sending_capability')
                  AND payload->>'room_id' <> upper(payload->>'room_id')
                """).first(decoding: CountRow.self)?.value == 0)

            #expect(try await sql.raw("""
                SELECT count(*)::bigint AS value FROM im_v2.user_sync_log
                WHERE user_id = \(bind: memberTwoUUID)
                  AND projection_kind = 'direct_room_profile'
                  AND (payload->>'room_id')::uuid = \(bind: UUID(uuidString: room.roomID.rawValue)!)
                """).first(decoding: CountRow.self)?.value == 0)
            if let targetURL = Environment.get("IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL") {
                try await withUserEventDatabase(databaseURL: targetURL) { targetDatabase, targetSQL, targetSchema in
                    let outbox = try PostgresV2UserStateEventOutbox(database: resources.database(.psql))
                    let projector = try PostgresV2UserStateEventProjector(database: targetDatabase, schema: targetSchema)
                    let leases = try await deliverUserStateEvents(outbox, projector: projector, now: now.addingTimeInterval(60))
                        .filter { $0.event.kind == .directRoomProfile && $0.event.userID == recipient }
                    #expect(leases.count == 1)
                    for lease in leases {
                        let sequence = try await projector.project(lease.event)
                        #expect(sequence == 1)
                        #expect(try await projector.project(lease.event) == sequence)
                    }
                    #expect(try await targetSQL.raw("""
                        SELECT count(*)::bigint AS value FROM \(unsafeRaw: targetSchema).user_sync_log
                        WHERE user_id = \(bind: memberTwoUUID) AND projection_kind = 'direct_room_profile'
                        """).first(decoding: CountRow.self)?.value == 1)
                }
            }
            let acceptedPairState = try #require(try await sql.raw("""
                SELECT lower_profile_visible_to_higher, higher_profile_visible_to_lower,
                       lower_can_send, higher_can_send
                FROM im_v2.direct_room_pairs
                WHERE room_id = \(bind: UUID(uuidString: room.roomID.rawValue)!)
                """).first(decoding: DirectPairProjectionStateAssertionRow.self))
            #expect(acceptedPairState.lowerProfileVisibleToHigher)
            #expect(acceptedPairState.higherProfileVisibleToLower)
            #expect(acceptedPairState.lowerCanSend == true)
            #expect(acceptedPairState.higherCanSend == nil)
            let reply = try await messages.send(.init(roomID: room.roomID, actorUserID: recipient, clientMessageID: try .init("00000000-0000-0000-0000-000000000080"), text: "reply"))
            guard case .accepted = reply else { Issue.record("expected reply"); return }
            let repliedPairState = try #require(try await sql.raw("""
                SELECT lower_profile_visible_to_higher, higher_profile_visible_to_lower,
                       lower_can_send, higher_can_send
                FROM im_v2.direct_room_pairs
                WHERE room_id = \(bind: UUID(uuidString: room.roomID.rawValue)!)
                """).first(decoding: DirectPairProjectionStateAssertionRow.self))
            #expect(repliedPairState.lowerCanSend == true)
            #expect(repliedPairState.higherCanSend == true)
            let pendingBeforeEstablishedMessage = try await count("im_v2.user_state_event_outbox", on: sql)
            let afterReply = try await messages.send(.init(roomID: room.roomID, actorUserID: senderID, clientMessageID: try .init("00000000-0000-0000-0000-000000000081"), text: "unlimited-after-reply"))
            guard case .accepted = afterReply else { Issue.record("expected post-reply message"); return }
            #expect(try await count("im_v2.user_state_event_outbox", on: sql) == pendingBeforeEstablishedMessage)
            let afterReplyReplay = try await messages.send(.init(roomID: room.roomID, actorUserID: senderID, clientMessageID: try .init("00000000-0000-0000-0000-000000000081"), text: "unlimited-after-reply"))
            guard case .idempotent = afterReplyReplay else { Issue.record("expected idempotent post-reply message"); return }
            // Replay must reuse the original durable facts without producing more work.
            #expect(try await count("im_v2.user_state_event_outbox", on: sql) == pendingBeforeEstablishedMessage)
            let window = try #require(try await sql.raw("SELECT message_count FROM im_v2.stranger_message_windows WHERE sender_user_id = \(bind: senderUUID) AND recipient_user_id = \(bind: memberTwoUUID)").first(decoding: StrangerWindowAssertionRow.self))
            #expect(window.messageCount == 3)
            let racedClientID = try ClientMessageID("00000000-0000-0000-0000-000000000089")
            async let firstRoomRace = messages.send(.init(
                roomID: room.roomID,
                actorUserID: senderID,
                clientMessageID: racedClientID,
                text: "independent-room-namespace"
            ))
            async let secondRoomRace = messages.send(.init(
                roomID: otherRoom.roomID,
                actorUserID: senderID,
                clientMessageID: racedClientID,
                text: "independent-room-namespace"
            ))
            let racedOutcomes = try await [firstRoomRace, secondRoomRace]
            #expect(racedOutcomes.filter {
                if case .accepted = $0 { return true }
                return false
            }.count == 2)
            #expect(racedOutcomes.filter { $0 == .idempotencyConflict }.isEmpty)
            let racedClientUUID = UUID(uuidString: racedClientID.rawValue)!
            let racedPersistence = try #require(try await sql.raw("""
                SELECT
                    (SELECT COUNT(*) FROM im_v2.messages
                     WHERE sender_user_id = \(bind: senderUUID)
                       AND client_message_id = \(bind: racedClientUUID)) AS accepted_count,
                    (SELECT COUNT(*) FROM im_v2.direct_message_denials
                     WHERE sender_user_id = \(bind: senderUUID)
                       AND client_message_id = \(bind: racedClientUUID)) AS denied_count
                """).first(decoding: MessageOperationCardinalityAssertionRow.self))
            #expect(racedPersistence == .init(acceptedCount: 2, deniedCount: 0))
            let sameRoomClientID = try ClientMessageID("ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEF01")
            let sameRoomResults = try await withThrowingTaskGroup(of: V2SendMessageOutcome.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        try await messages.send(.init(
                            roomID: room.roomID,
                            actorUserID: senderID,
                            clientMessageID: sameRoomClientID,
                            text: "same-room-retry"
                        ))
                    }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
            #expect(sameRoomResults.filter {
                if case .accepted = $0 { return true }
                return false
            }.count == 1)
            #expect(sameRoomResults.filter {
                if case .idempotent = $0 { return true }
                return false
            }.count == 7)
            let originalReceipt = try #require(sameRoomResults.first?.acceptanceReceipt)
            #expect(sameRoomResults.allSatisfy { $0.acceptanceReceipt == originalReceipt })
            let sameRoomConflict = try await messages.send(.init(
                roomID: room.roomID,
                actorUserID: senderID,
                clientMessageID: sameRoomClientID,
                text: "changed-room-retry"
            ))
            #expect(sameRoomConflict == .idempotencyConflict)
            let acceptedEventCount = try await count(
                "im_v2.room_events WHERE event_type = 'message.accepted'",
                on: sql
            )
            #expect(acceptedEventCount > 0)
            #expect(try await count("im_v2.user_sync_log WHERE projection_kind = 'message'", on: sql) == 0)

            // Public message acceptance and room-log reads do not depend on
            // the user projection router after the direct room is established.
            try await sql.raw("DELETE FROM im_v2.user_shard_router_configuration").run()
            let withoutUserRoute = try await messages.send(.init(
                roomID: room.roomID, actorUserID: senderID,
                clientMessageID: .init("00000000-0000-0000-0000-000000000091"),
                text: "room-log-without-user-route"
            ))
            guard case .accepted(let acceptedWithoutRoute) = withoutUserRoute else {
                Issue.record("expected room-log acceptance without user projection route")
                return
            }
            let roomPage = try await PostgresV2GroupEventLogStore(database: resources.database(.psql)).pull(
                roomID: room.roomID, actorUserID: recipient,
                afterRoomSequence: acceptedWithoutRoute.roomSequence - 1, pageSize: 10)
            #expect(roomPage.events.map(\.roomSequence) == [acceptedWithoutRoute.roomSequence])
            #expect(roomPage.events.first?.projectionKind == "message")
            #expect(try await count("im_v2.user_sync_log WHERE projection_kind = 'message'", on: sql) == 0)
            try await configureDefaultUserShardRoute(
                .init(bucket: "test-users", observedRouterEpoch: 9),
                now: now.addingTimeInterval(3), on: sql)

            // A corrupt direct audience must fail closed. The authoritative
            // pair still names two users, but the revision-fenced membership
            // set below contains one. Verify that the surrounding transaction
            // leaves no accepted message or partial write artifacts.
            try await sql.raw("""
                UPDATE im_v2.rooms
                SET membership_revision = 1
                WHERE room_id = \(bind: UUID(uuidString: room.roomID.rawValue)!)
                """).run()
            try await sql.raw("""
                UPDATE im_v2.room_memberships
                SET left_revision = 1
                WHERE room_id = \(bind: UUID(uuidString: room.roomID.rawValue)!)
                  AND user_id = \(bind: memberTwoUUID)
                """).run()
            let beforeCorruptWrite = try await directWriteArtifactCounts(sql: sql)
            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                try await messages.send(.init(
                    roomID: room.roomID,
                    actorUserID: senderID,
                    clientMessageID: try .init("00000000-0000-0000-0000-000000000092"),
                    text: "must-rollback"
                ))
            }
            #expect(try await directWriteArtifactCounts(sql: sql) == beforeCorruptWrite)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown(); throw error
        }
    }

    @Test("independent direct-room creation shares the shard fence and rejects an existing pair under another profile")
    func directRoomCreationUsesSharedShardFence() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4),
                as: .psql,
                isDefault: true
            )
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_150_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10,
                maxCommandsPerWindow: 100,

                retryAfterSeconds: 3
            ))
            let leaseID = UUID(uuidString: "00000000-0000-0000-0000-000000000151")!
            try await sql.raw("INSERT INTO im_v2.shard_admission_pools (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit) VALUES ('rooms-concurrent-direct', 'standard', \(bind: leaseID), 1, \(bind: now.addingTimeInterval(600)), 100)").run()

            let users = (0..<4).map {
                UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", 0x160 + $0))!
            }
            for (index, userID) in users.enumerated() {
                try await sql.raw("INSERT INTO im_v2.public_user_profiles (user_id, public_handle, display_name, revision, created_at, updated_at) VALUES (\(bind: userID), \(bind: "direct_probe_\(index)"), \(bind: "并发用户\(index)"), 1, \(bind: now), \(bind: now))").run()
            }

            // The trigger sleeps after `open` has acquired the shard fence.
            // A sequence is deliberately used as a non-transactional probe:
            // both inserts can reach the trigger during the same sleep only
            // when their shard row locks are compatible.
            try await sql.raw("CREATE SEQUENCE im_v2.direct_room_shared_lock_probe").run()
            try await sql.raw("""
                CREATE FUNCTION im_v2.pause_direct_room_insert()
                RETURNS trigger
                LANGUAGE plpgsql
                AS $$
                BEGIN
                    PERFORM nextval('im_v2.direct_room_shared_lock_probe');
                    PERFORM pg_sleep(0.75);
                    RETURN NEW;
                END;
                $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER pause_direct_room_insert
                BEFORE INSERT ON im_v2.rooms
                FOR EACH ROW
                WHEN (NEW.room_kind = 'direct')
                EXECUTE FUNCTION im_v2.pause_direct_room_insert()
                """).run()

            let service = try V2DirectRoomOperationTestFixture(
                store: PostgresV2DirectMessagingStore(database: resources.database(.psql), identityReader: PostgresV2DirectRoomIdentityReader(database: resources.database(.psql)), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: profile,
                roomShardID: "rooms-concurrent-direct",
                now: { now }
            )
            let firstOperation = try DirectRoomOperationID("00000000-0000-0000-0000-000000000170")
            let secondOperation = try DirectRoomOperationID("00000000-0000-0000-0000-000000000171")
            let first = Task {
                try await service.openedReceipt(
                    actorUserID: try .init(users[0].uuidString),
                    operationID: firstOperation,
                    targetUserID: try .init(users[1].uuidString),
                    firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now)
                )
            }

            let firstDeadline = Date().addingTimeInterval(2)
            while Date() < firstDeadline {
                let probe = try await sql.raw("SELECT last_value, is_called FROM im_v2.direct_room_shared_lock_probe").first(decoding: DirectRoomLockProbeRow.self)
                if probe?.isCalled == true { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let second = Task {
                try await service.openedReceipt(
                    actorUserID: try .init(users[2].uuidString),
                    operationID: secondOperation,
                    targetUserID: try .init(users[3].uuidString),
                    firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now)
                )
            }

            var bothReachedInsert = false
            let sharedLockDeadline = Date().addingTimeInterval(0.5)
            while Date() < sharedLockDeadline {
                let probe = try await sql.raw("SELECT last_value, is_called FROM im_v2.direct_room_shared_lock_probe").first(decoding: DirectRoomLockProbeRow.self)
                if probe?.isCalled == true, probe?.lastValue ?? 0 >= 2 {
                    bothReachedInsert = true
                    break
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(bothReachedInsert)

            let firstReceipt = try await first.value
            _ = try await second.value

            let otherProfile = try V2CapacityProfile(id: "next-profile", limits: profile.limits)
            let otherProfileService = try V2DirectRoomOperationTestFixture(
                store: PostgresV2DirectMessagingStore(database: resources.database(.psql), identityReader: PostgresV2DirectRoomIdentityReader(database: resources.database(.psql)), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: otherProfile,
                roomShardID: "rooms-concurrent-direct",
                now: { now }
            )
            let mismatched = try await otherProfileService.submit(
                actorUserID: try .init(users[0].uuidString),
                operationID: try .init("00000000-0000-0000-0000-000000000172"),
                targetUserID: try .init(users[1].uuidString),
                    firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now)
            )
            #expect(mismatched == .unresolved)

            // A response-loss retry of the original immutable operation must
            // still return its canonical result after a deployment change.
            let replay = try await otherProfileService.openedReceipt(
                actorUserID: try .init(users[0].uuidString), operationID: firstOperation,
                targetUserID: try .init(users[1].uuidString),
                firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            #expect(replay == firstReceipt)

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

}

private struct DirectRoomLockProbeRow: Decodable {
    let lastValue: Int64
    let isCalled: Bool
    enum CodingKeys: String, CodingKey {
        case lastValue = "last_value"
        case isCalled = "is_called"
    }
}
private struct MessageOperationCardinalityAssertionRow: Decodable, Equatable {
    let acceptedCount: Int64
    let deniedCount: Int64

    enum CodingKeys: String, CodingKey {
        case acceptedCount = "accepted_count"
        case deniedCount = "denied_count"
    }
}

private struct DirectProfileSyncAssertionRow: Decodable, Equatable {
    let userID: UUID
    let roomID: String
    let targetUserID: UUID
    let publicHandle: String
    let displayName: String
    let revision: Int64

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case roomID = "room_id"
        case targetUserID = "target_user_id"
        case publicHandle = "public_handle"
        case displayName = "display_name"
        case revision
    }
}
private struct DurableRetryStateRow: Decodable {
    let state: String
    let retryCount: Int64
    enum CodingKeys: String, CodingKey { case state; case retryCount = "retry_count" }
}
private struct AdmissionFenceRow: Decodable {
    let shardLeaseID: UUID
    let shardLeaseGeneration: Int64
    enum CodingKeys: String, CodingKey { case shardLeaseID = "shard_lease_id", shardLeaseGeneration = "shard_lease_generation" }
}
private struct StrangerWindowAssertionRow: Decodable {
    let messageCount: Int
    enum CodingKeys: String, CodingKey { case messageCount = "message_count" }
}
private enum StrangerMessageAttempt: Equatable, Sendable {
    case accepted
    case limited
    case unexpectedOutcome
    case unexpectedFailure
}
private struct ReceiptTombstoneCountAssertionRow: Decodable {
    let value: Int
    let distinctSources: Int
    enum CodingKeys: String, CodingKey {
        case value
        case distinctSources = "distinct_sources"
    }
}

private struct PushSuppressionStateRow: Decodable {
    let state: String
    let suppressionReason: String?
    enum CodingKeys: String, CodingKey { case state; case suppressionReason = "suppression_reason" }
}
private struct EncryptedPushEndpointRow: Decodable {
    let encryptedToken: String
    enum CodingKeys: String, CodingKey { case encryptedToken = "encrypted_token" }
}
private struct PushRecoveryStateRow: Decodable {
    let state: String
    let retryCount: Int64
    let admittedAt: Date?
    enum CodingKeys: String, CodingKey {
        case state
        case retryCount = "retry_count"
        case admittedAt = "admitted_at"
    }
}
private struct PushBudgetRow: Decodable {
    let usedWorkUnits: Int
    let usedNewKeyOperations: Int
    enum CodingKeys: String, CodingKey { case usedWorkUnits = "used_work_units", usedNewKeyOperations = "used_new_key_operations" }
}
private struct TimelineActivityTypeAssertionRow: Decodable {
    let activityType: String
    enum CodingKeys: String, CodingKey { case activityType = "activity_type" }
}

private struct ProjectionEligibleDate: Decodable { let value: Date }

private struct ProfileFixtureAvatarDelivery: V2ResourceDelivery {
    func issue(_ request: V2AuthorizedResourceDelivery) async throws -> V2ResourceTransferPlan {
        try .init(mode: .httpGet, url: #require(URL(string: "https://profile.invalid/avatar")),
            expiresAt: request.expiresAt, expectedByteCount: request.facts.byteCount,
            checksum: .init(value: request.facts.sha256.map { String(format: "%02x", $0) }.joined()))
    }
}
