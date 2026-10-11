@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import FluentKit
import IMV2ActorContracts
import IMV2Core
@testable import IMV2ServerInfrastructure
import SQLKit
import Synchronization
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("independent room turns use separate set-wise statements and replay without writes", arguments: [false, true])
    func durableOwnerBatchUsesSetwiseWrites(multipleShards: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let rooms = try await ownerBatchRooms(database: database, profile: profile, now: now)
            if multipleShards {
                let otherLease = UUID()
                try await sql.raw("INSERT INTO im_v2.shard_admission_pools (room_shard_id,capacity_profile_id,lease_id,generation,valid_until,command_window_limit) SELECT 'room-local-b',capacity_profile_id,\(bind: otherLease),generation,valid_until,command_window_limit FROM im_v2.shard_admission_pools WHERE room_shard_id='room-a'").run()
                try await sql.raw("UPDATE im_v2.rooms SET room_shard_id='room-local-b' WHERE room_id=\(bind: rooms[1].uuidValue!)").run()
                try await sql.raw("UPDATE im_v2.room_owner_routes SET room_shard_id='room-local-b' WHERE room_id=\(bind: rooms[1].uuidValue!)").run()
                try await sql.raw("UPDATE im_v2.room_admission SET shard_lease_id=\(bind: otherLease) WHERE room_id=\(bind: rooms[1].uuidValue!)").run()
            }
            let observer = DurableOwnerBatchObserver(), metrics = V2SendOperationBatchMetrics()
            let policies = v2FixtureRoomPolicyAuthorizations(database: database)
            let store = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 100, window: 86_400),
                    contentReviewMode: .disabled).usingControlDatabase(database).usingPolicyAuthorizations(policies),
                clock: { now }, committedMessageObserver: observer, sendOperationMetrics: metrics)
            let prepare = policies.fixtureSendPreparation(store: store, now: { now })
            let commands = try rooms.map { room in try ownerBatchCommand(room: room, text: "first stranger", now: now) }
            // Statement triggers distinguish a real set-wise write from a
            // transaction containing one scalar insert per room.
            try await sql.raw("CREATE TABLE im_v2.fixture_durable_statements (table_name text NOT NULL)").run()
            try await sql.raw("""
                CREATE FUNCTION im_v2.fixture_count_durable_statements() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    INSERT INTO im_v2.fixture_durable_statements VALUES (TG_TABLE_NAME);
                    RETURN NULL;
                END
                $$
                """).run()
            for table in ["messages", "message_send_completions"] {
                try await sql.raw("""
                    CREATE TRIGGER fixture_durable_statement AFTER INSERT ON im_v2.\(unsafeRaw: table)
                    FOR EACH STATEMENT EXECUTE FUNCTION im_v2.fixture_count_durable_statements()
                    """).run()
            }
            try await sql.raw("CREATE TRIGGER fixture_durable_admission_statement AFTER UPDATE ON im_v2.shard_admission_pools FOR EACH STATEMENT EXECUTE FUNCTION im_v2.fixture_count_durable_statements()").run()
            try await withRoomActivation(database: database, roomID: rooms[0]) { firstToken in
                try await withRoomActivation(database: database, roomID: rooms[1], shardID: multipleShards ? "room-local-b" : "room-a") { secondToken in
                    let first = try await prepare([commands[0]], firstToken, .now + .seconds(30))
                    let second = try await prepare([commands[1]], secondToken, .now + .seconds(30))
                    let results = try await store.executeIndependentRoomTurns([first, second], capacityProfile: profile,
                        identifiers: .init(), now: { now })
                    #expect(results.count == 2)
                    let committed = try results.map { try $0.get() }
                    for (index, turn) in committed.enumerated() {
                        guard turn.count == 1, case .sendOperation(.receipt(let receipt)) = turn[0],
                              case .accepted = receipt.outcome else { throw V2RoomWriteStoreError.corruptPersistenceState }
                        #expect(receipt.validates(identity: try commands[index].identity, fingerprint: try commands[index].fingerprint))
                    }
                    #expect(try await count("im_v2.messages", on: sql) == 2)
                    #expect(try await count("im_v2.message_send_completions", on: sql) == 2)
                    #expect(try await count("pg_catalog.pg_class WHERE oid=to_regclass('im_v2.direct_authorization_receipts')", on: sql) == 0)
                    for table in ["messages", "message_send_completions"] {
                        let row = try await sql.raw("SELECT count(*) AS value FROM im_v2.fixture_durable_statements WHERE table_name=\(bind: table)").first(decoding: DurableOwnerBatchCount.self)
                        #expect(row?.value == 2)
                    }
                    #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.fixture_durable_statements WHERE table_name='shard_admission_pools'").first(decoding: DurableOwnerBatchCount.self)?.value == 0)
                    // Current sends persist success with the message and never
                    // write a separate legacy authorization proof.
                    #expect(observer.count == 2)
                    let admissionPath: V2SendOperationAdmissionPath = multipleShards ? .multiGroup : .singleSuccess
                    #expect(metrics.sendOperationBatchMetricsSnapshot().ownerAdmissionHandoffs[admissionPath]?.count == 0)
                    let replay = try await store.executeIndependentRoomTurns([first, second], capacityProfile: profile,
                        identifiers: .init(), now: { now })
                    #expect(try replay.map { try $0.get() } == committed)
                    #expect(metrics.sendOperationBatchMetricsSnapshot().ownerAdmissionHandoffs[admissionPath]?.count == 0)
                    let conflictCommand = try ownerBatchCommand(room: rooms[0], operationID: commands[0].command.clientMessageID,
                        text: "different immutable body", now: now)
                    let conflict = try await prepare([conflictCommand], firstToken, .now + .seconds(30))
                    let conflicts = try await store.executeIndependentRoomTurns([conflict, second], capacityProfile: profile,
                        identifiers: .init(), now: { now })
                    #expect(try conflicts[0].get() == [.sendOperation(.fingerprintConflict)])
                    #expect(try conflicts[1].get() == committed[1])
                    #expect(try await count("im_v2.fixture_durable_statements", on: sql) == 4)
                    #expect(observer.count == 2)
                    let freshCommand = try ownerBatchCommand(room: rooms[0], text: "new operation after replay", now: now)
                    let fresh = try await prepare([freshCommand], firstToken, .now + .seconds(30))
                    let freshResults = try await store.executeIndependentRoomTurns([fresh, second], capacityProfile: profile,
                        identifiers: .init(), now: { now })
                    guard case .success(let values) = freshResults[0], case .sendOperation(.receipt(let receipt)) = values[0], case .accepted = receipt.outcome else {
                        throw V2MessageOperationValidationError.invalidReceipt
                    }
                    #expect(try freshResults[1].get() == committed[1])
                    #expect(try await count("im_v2.messages", on: sql) == 3)
                    #expect(observer.count == 3)
                }
            }
        }
    }

    @Test("durable owner batch rechecks prepared authority and isolates a stale activation", arguments: ["permission", "denial", "stale", "constraint", "receipt_constraint", "late_quota"])
    func durableOwnerBatchRechecksPreparedAuthority(scenario: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let rooms = try await ownerBatchRooms(database: database, profile: profile, now: now)
            let metrics = V2SendOperationBatchMetrics()
            let policies = v2FixtureRoomPolicyAuthorizations(database: database)
            let store = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 100, window: 86_400),
                    contentReviewMode: .disabled).usingControlDatabase(database).usingPolicyAuthorizations(policies), clock: { now }, sendOperationMetrics: metrics)
            let prepare = policies.fixtureSendPreparation(store: store, now: { now })
            let commands = try rooms.map { try ownerBatchCommand(room: $0, text: "authority recheck", now: now) }
            try await withRoomActivation(database: database, roomID: rooms[0]) { firstToken in
                try await withRoomActivation(database: database, roomID: rooms[1]) { secondToken in
                    if scenario == "denial" {
                        try await sql.raw("INSERT INTO im_v2.user_blocks (blocker_user_id,blocked_user_id,created_at) VALUES (\(bind: memberTwoUUID),\(bind: senderUUID),\(bind: now))").run()
                    }
                    let first = try await prepare([commands[0]], firstToken, .now + .seconds(30))
                    let second = try await prepare([commands[1]], secondToken, .now + .seconds(30))
                    if scenario == "stale" {
                        await policies.retire(token: firstToken)
                        _ = try await PostgresV2RoomActivationStore(database: database).release(token: firstToken)
                    } else if scenario == "constraint" || scenario == "receipt_constraint" {
                        try await sql.raw("CREATE TABLE im_v2.fixture_failed_room (room_id uuid NOT NULL)").run()
                        try await sql.raw("INSERT INTO im_v2.fixture_failed_room VALUES (\(bind: rooms[0].uuidValue!))").run()
                        try await sql.raw("""
                            CREATE FUNCTION im_v2.fixture_fail_one_room() RETURNS trigger LANGUAGE plpgsql AS $$
                            BEGIN
                                IF EXISTS (SELECT 1 FROM im_v2.fixture_failed_room WHERE room_id=NEW.room_id) THEN
                                    RAISE EXCEPTION 'one room constraint failure' USING ERRCODE='23514';
                                END IF;
                                RETURN NEW;
                            END
                            $$
                            """).run()
                        let failedTable = scenario == "receipt_constraint" ? "message_send_completions" : "messages"
                        try await sql.raw("CREATE TRIGGER fixture_failed_room BEFORE INSERT ON im_v2.\(unsafeRaw: failedTable) FOR EACH ROW EXECUTE FUNCTION im_v2.fixture_fail_one_room()").run()
                    } else if scenario == "late_quota" {
                        try await sql.raw("CREATE TABLE im_v2.fixture_quota_room (room_id uuid NOT NULL)").run()
                        try await sql.raw("INSERT INTO im_v2.fixture_quota_room VALUES (\(bind: rooms[0].uuidValue!))").run()
                        try await sql.raw("""
                            CREATE FUNCTION im_v2.fixture_exhaust_tail_quota() RETURNS trigger LANGUAGE plpgsql AS $$
                            BEGIN
                                IF EXISTS (SELECT 1 FROM im_v2.fixture_quota_room WHERE room_id=NEW.room_id) THEN
                                    UPDATE im_v2.shard_admission_pools pool SET command_window_used=command_window_limit
                                    FROM im_v2.rooms room WHERE room.room_id=NEW.room_id
                                      AND pool.room_shard_id=room.room_shard_id AND pool.capacity_profile_id=room.capacity_profile_id;
                                END IF;
                                RETURN NEW;
                            END
                            $$
                            """).run()
                        try await sql.raw("CREATE TRIGGER fixture_tail_quota AFTER INSERT ON im_v2.messages FOR EACH ROW EXECUTE FUNCTION im_v2.fixture_exhaust_tail_quota()").run()
                    } else if scenario == "permission" {
                        try await sql.raw("INSERT INTO im_v2.room_member_mutes (room_id,user_id,mute_until,actor_user_id,operation_id,created_at) VALUES (\(bind: rooms[0].uuidValue!),\(bind: senderUUID),\(bind: now.addingTimeInterval(300)),\(bind: memberTwoUUID),\(bind: UUID()),\(bind: now))").run()
                    }
                    let results = try await store.executeIndependentRoomTurns([first, second], capacityProfile: profile,
                        identifiers: .init(), now: { now })
                    #expect(results.count == 2)
                    let stages = metrics.sendOperationBatchMetricsSnapshot().stages
                    #expect(stages.values.allSatisfy { $0.inFlight == 0 })
                    if scenario == "constraint" {
                        #expect((stages[.ownerMessagePersistence]?.count ?? 0) >= 1)
                    } else if scenario == "late_quota" {
                        #expect((stages[.ownerAdmission]?.count ?? 0) == 0)
                        // Retired infrastructure quota rows are not consulted or charged.
                        // A fixture changing them cannot revoke a valid message.
                        let handoffs = metrics.sendOperationBatchMetricsSnapshot().ownerAdmissionHandoffs
                        #expect(handoffs.values.reduce(0) { $0 + $1.count } == 0)
                    }

                    if scenario == "stale" || scenario == "constraint" || scenario == "receipt_constraint" {
                        if case .success = results[0] { Issue.record("invalid activation or constraint must fail its original turn") }
                    } else if scenario == "late_quota" {
                        let accepted = try results[0].get()
                        guard accepted.count == 1, case .sendOperation(.receipt(let receipt)) = accepted[0],
                              case .accepted = receipt.outcome else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                        #expect(try await count("im_v2.message_send_completions", on: sql) == 2)
                        #expect(try await count("pg_catalog.pg_class WHERE oid=to_regclass('im_v2.direct_authorization_receipts')", on: sql) == 0)
                    } else {
                        let result = try results[0].get()
                        guard result.count == 1, case .sendOperation(.receipt(let receipt)) = result[0],
                              case .rejected = receipt.outcome else { throw V2RoomWriteStoreError.corruptPersistenceState }
                        #expect(try await sql.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: rooms[0].uuidValue!)").first(decoding: DurableOwnerBatchCount.self)?.value == 0)
                        #expect(try await retiredDirectDenialTableIsAbsent(on: sql))
                    }
                    let healthy = try results[1].get()
                    guard healthy.count == 1, case .sendOperation(.receipt(let receipt)) = healthy[0],
                          case .accepted = receipt.outcome else { throw V2RoomWriteStoreError.corruptPersistenceState }
                    #expect(try await count("im_v2.messages", on: sql) == (scenario == "late_quota" ? 2 : 1))
                    if scenario == "constraint" || scenario == "receipt_constraint" {
                        // The failing room leaves neither a message nor a success
                        // record; the healthy room commits independently.
                        #expect(try await count("im_v2.message_send_completions", on: sql) == 1)
                        #expect(try await count("pg_catalog.pg_class WHERE oid=to_regclass('im_v2.direct_authorization_receipts')", on: sql) == 0)
                        let failedTable = scenario == "receipt_constraint" ? "message_send_completions" : "messages"
                        try await sql.raw("DROP TRIGGER fixture_failed_room ON im_v2.\(unsafeRaw: failedTable)").run()
                        let retry = try await store.executeIndependentRoomTurns([first], capacityProfile: profile,
                            identifiers: .init(), now: { now })
                        let retried = try retry[0].get()
                        guard case .sendOperation(.receipt(let accepted)) = retried[0], case .accepted = accepted.outcome else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                        #expect(try await count("im_v2.messages", on: sql) == 2)
                    }
                }
            }
        }
    }

    @Test("eligible singleton preserves two-command FIFO and isolates quota rollback only once", arguments: [false, true])
    func durableOwnerSingletonPreservesFIFOAndIsolation(quotaBoundary: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let rooms = try await ownerBatchRooms(database: database, profile: profile, now: now)
            let room = rooms[0]
            // Real persisted first-producer facts, before actual authorization
            // preparation. No synthetic grant or successful domain result.
            try await sql.raw("""
                UPDATE im_v2.direct_room_pairs SET lower_profile_visible_to_higher=false,
                  higher_profile_visible_to_lower=false, lower_can_send=NULL, higher_can_send=NULL,
                  lower_has_replied=false, higher_has_replied=false
                WHERE room_id=\(bind: room.uuidValue!)
                """).run()
            let revision = try #require(try await sql.raw("SELECT direct_policy_revision AS value FROM im_v2.direct_room_pairs WHERE room_id=\(bind: room.uuidValue!)").first(decoding: DurableOwnerBatchCount.self)).value
            let before = try #require(try await sql.raw("SELECT command_window_used AS value FROM im_v2.shard_admission_pools WHERE room_shard_id='room-a' AND capacity_profile_id='standard'").first(decoding: DurableOwnerBatchCount.self)).value
            let metrics = V2SendOperationBatchMetrics(), observer = DurableOwnerBatchObserver()
            let policies = v2FixtureRoomPolicyAuthorizations(database: database)
            let store = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: quotaBoundary ? 1 : 100, window: 86_400),
                    contentReviewMode: .disabled).usingControlDatabase(database).usingPolicyAuthorizations(policies), clock: { now },
                committedMessageObserver: observer, sendOperationMetrics: metrics)
            let prepare = policies.fixtureSendPreparation(store: store, now: { now })
            let commands = try [ownerBatchCommand(room: room, text: "singleton first", now: now),
                                ownerBatchCommand(room: room, text: "singleton second", now: now)]
            try await withRoomActivation(database: database, roomID: room) { token in
                let handle = try await prepare(commands, token, .now + .seconds(30))
                let results = try await store.executeIndependentRoomTurns([handle], capacityProfile: profile,
                    identifiers: .init(), now: { now })
                try #require(results.count == 1)
                let values = try results[0].get()
                try #require(values.count == 2)
                let acceptedCount = quotaBoundary ? 1 : 2
                for ordinal in 0..<acceptedCount {
                    guard case .sendOperation(.receipt(let receipt)) = values[ordinal],
                          case .accepted(let accepted) = receipt.outcome else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    #expect(accepted.roomSequence == UInt64(ordinal + 1))
                    #expect(receipt.validates(identity: try commands[ordinal].identity,
                                              fingerprint: try commands[ordinal].fingerprint))
                }
                if quotaBoundary {
                    guard case .sendOperation(.deferred(let deferred)) = values[1] else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    #expect(deferred.reason == .rateLimited)
                }
                let snapshot = metrics.sendOperationBatchMetricsSnapshot()
                #expect(snapshot.ownerCohortAttempts == 1)
                #expect(snapshot.ownerCohortIsolations == (quotaBoundary ? 1 : 0))
                #expect(snapshot.ownerCohortCommits == (quotaBoundary ? 0 : 1))
                #expect(snapshot.ownerScalarFallbacks[.domainIsolation]?.handles ?? 0 == (quotaBoundary ? 1 : 0))
                #expect(snapshot.ownerScalarFallbacks.values.reduce(0) { $0 + $1.handles } == (quotaBoundary ? 1 : 0))
                #expect(snapshot.stages[.ownerRollback]?.count ?? 0 == (quotaBoundary ? 1 : 0))
                #expect(snapshot.stages[.ownerCommit]?.count == 1)
                #expect(snapshot.ownerAdmissionHandoffs[.singleSuccess]?.count == 0)
                for table in ["messages", "message_send_completions"] {
                    #expect(try await count("im_v2.\(table)", on: sql) == Int64(acceptedCount))
                }
                #expect(try await sql.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: room.uuidValue!)").first(decoding: DurableOwnerBatchCount.self)?.value == Int64(acceptedCount))
                #expect(try await sql.raw("SELECT direct_policy_revision AS value FROM im_v2.direct_room_pairs WHERE room_id=\(bind: room.uuidValue!)").first(decoding: DurableOwnerBatchCount.self)?.value == revision + 1)
                #expect(try await sql.raw("SELECT message_count::bigint AS value FROM im_v2.stranger_message_windows WHERE sender_user_id=\(bind: senderUUID) AND recipient_user_id=\(bind: memberTwoUUID)").first(decoding: DurableOwnerBatchCount.self)?.value == Int64(acceptedCount))
                let producerEvents = try #require(try await sql.raw("""
                    SELECT count(*)::bigint AS value FROM im_v2.user_state_event_outbox AS event
                    JOIN im_v2.message_send_completions AS completion ON completion.event_id=event.source_event_id
                    WHERE completion.room_id=\(bind: room.uuidValue!)
                      AND event.projection_kind IN ('direct_sending_capability','direct_room_profile')
                    """).first(decoding: DurableOwnerBatchCount.self)).value
                #expect(producerEvents == 2)
                #expect(try await sql.raw("""
                    SELECT count(*)::bigint AS value FROM im_v2.user_state_event_outbox AS event
                    JOIN im_v2.message_send_completions AS completion ON completion.event_id=event.source_event_id
                    WHERE completion.room_id=\(bind: room.uuidValue!) AND completion.room_sequence<>1
                      AND event.projection_kind IN ('direct_sending_capability','direct_room_profile')
                    """).first(decoding: DurableOwnerBatchCount.self)?.value == 0)
                let replay = try await store.executeIndependentRoomTurns([handle], capacityProfile: profile,
                    identifiers: .init(), now: { now })
                #expect(try replay[0].get() == values)
                #expect(try await count("im_v2.messages", on: sql) == Int64(acceptedCount))
                #expect(try await sql.raw("SELECT command_window_used AS value FROM im_v2.shard_admission_pools WHERE room_shard_id='room-a' AND capacity_profile_id='standard'").first(decoding: DurableOwnerBatchCount.self)?.value == before)
                #expect(try await sql.raw("SELECT message_count::bigint AS value FROM im_v2.stranger_message_windows WHERE sender_user_id=\(bind: senderUUID) AND recipient_user_id=\(bind: memberTwoUUID)").first(decoding: DurableOwnerBatchCount.self)?.value == Int64(acceptedCount))
                #expect(observer.count == acceptedCount)
            }
        }
    }

    @Test("durable owner COMMIT uncertainty preserves every operation without hidden fallback", arguments: [false, true])
    func durableOwnerBatchPreservesCommitUnknown(singleton: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let rooms = try await ownerBatchRooms(database: database, profile: profile, now: now)
            let metrics = V2SendOperationBatchMetrics(), observer = DurableOwnerBatchObserver()
            let policies = v2FixtureRoomPolicyAuthorizations(database: database)
            let store = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 100, window: 86_400),
                    contentReviewMode: .disabled).usingControlDatabase(database).usingPolicyAuthorizations(policies), clock: { now },
                committedMessageObserver: observer, sendOperationMetrics: metrics)
            let prepare = policies.fixtureSendPreparation(store: store, now: { now })
            try await sql.raw("""
                CREATE FUNCTION im_v2.fixture_durable_commit_wait() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    PERFORM pg_sleep(2);
                    RETURN NEW;
                END
                $$
                """).run()
            try await sql.raw("""
                CREATE CONSTRAINT TRIGGER fixture_durable_commit_wait AFTER INSERT ON im_v2.messages
                DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION im_v2.fixture_durable_commit_wait()
                """).run()
            let commands = try rooms.map { try ownerBatchCommand(room: $0, text: "uncertain cohort", now: now) }
            try await withRoomActivation(database: database, roomID: rooms[0]) { firstToken in
                try await withRoomActivation(database: database, roomID: rooms[1]) { secondToken in
                    let first = try await prepare([commands[0]], firstToken, .now + .seconds(30))
                    let second = try await prepare([commands[1]], secondToken, .now + .seconds(30))
                    // Closing the client during deferred COMMIT proves missing
                    // acknowledgement, not whether PostgreSQL finally commits.
                    let results = try await V2RoomSQLDeadline.withDeadline(.now + .milliseconds(900)) {
                        try await store.executeIndependentRoomTurns(singleton ? [first] : [first, second], capacityProfile: profile,
                            identifiers: .init(), now: { now })
                    }
                    #expect(results.count == (singleton ? 1 : 2))
                    for result in results {
                        guard case .failure(let error) = result, error is V2RoomTransactionOutcomeUnknown else {
                            Issue.record("every submitted identity must retain COMMIT uncertainty")
                            continue
                        }
                    }
                    let snapshot = metrics.sendOperationBatchMetricsSnapshot()
                    #expect(snapshot.ownerCohortAttempts == (singleton ? 1 : 2))
                    // Handoff counts the actual COMMIT API dispatch even when
                    // its acknowledgement is lost. It cannot claim success.
                    #expect(snapshot.ownerAdmissionHandoffs[.singleSuccess]?.count == 0)
                    #expect(snapshot.ownerAdmissionHandoffs.values.reduce(0) { $0 + $1.count } == 0)
                    #expect(snapshot.ownerCohortIsolations == 0)
                    #expect(snapshot.ownerScalarFallbacks.values.reduce(0) { $0 + $1.handles } == 0)
                    // The actual body settled before COMMIT uncertainty. Every
                    // measured child completed; none claims the unknown commit.
                    for stage: V2SendOperationStage in [.ownerLocks, .ownerReceiptRead,
                        .ownerPreflight, .ownerReduction, .ownerPolicy, .ownerMessagePersistence,
                        .ownerProjection, .ownerProof, .ownerReceiptPersistence] {
                        #expect(snapshot.stages[stage]?.count ?? 0 == ([V2SendOperationStage.ownerReceiptRead, .ownerProof, .ownerReceiptPersistence].contains(stage) ? 0 : (singleton ? 1 : 2)))
                        #expect(snapshot.stages[stage]?.inFlight == 0)
                    }
                    #expect(snapshot.stages[.ownerAdmission]?.count ?? 0 == 0)
                    let stages = snapshot.stages
                    #expect(stages[.ownerCommit]?.count == (singleton ? 1 : 2))
                    #expect(stages[.ownerRollback]?.count ?? 0 == 0)
                    #expect(observer.count == 0)
                    // The server may still finish COMMIT after its client was
                    // closed. Observe actual settlement before the fixture
                    // releases activation locks; do not infer rollback.
                    var settled = false
                    for _ in 0..<600 {
                        let row = try await sql.raw("SELECT NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND state='active' AND query='COMMIT') AS value").first(decoding: DurableOwnerBatchBool.self)
                        if row?.value == true { settled = true; break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    #expect(settled)
                }
            }
        }
    }

    private func ownerBatchRooms(database: any FluentKit.Database, profile: V2CapacityProfile, now: Date) async throws -> [RoomID] {
        var rooms: [RoomID] = []
        for recipient in [memberTwoUUID, memberThreeUUID] {
            let room = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { now }).openedIdentity(
                    actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: recipient),
                    firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
            rooms.append(room.roomID)
        }
        return rooms
    }

    private func ownerBatchCommand(room: RoomID, operationID: ClientMessageID = .init(uuid: UUID()), text: String, now: Date) throws -> V2MessageSendOperationCommand {
        try .init(command: .init(roomID: room, senderUserID: senderID, clientMessageID: operationID,
            text: text, limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: UInt64(now.timeIntervalSince1970 * 1000) + 60_000)
    }
}

private struct DurableOwnerBatchCount: Decodable { let value: Int64 }
private final class DurableOwnerBatchObserver: V2CommittedMessageBatchObserving, Sendable {
    private let messages = Mutex<Int>(0)
    var count: Int { messages.withLock { $0 } }
    func observeCommittedMessages(_ outcomes: [V2SendMessageOutcome], activation: V2RoomActivationToken) { messages.withLock { $0 += outcomes.count } }
}

private struct DurableOwnerBatchBool: Decodable { let value: Bool }
