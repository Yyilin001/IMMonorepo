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
                        .ownerProjection] {
                        #expect(snapshot.stages[stage]?.count ?? 0 == (stage == .ownerReceiptRead ? 0 : (singleton ? 1 : 2)))
                        #expect(snapshot.stages[stage]?.inFlight == 0)
                    }
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

    @Test("cross-room commit shares one transaction, fences stale rooms and recovers lost ACKs",
          arguments: ["commit", "stale", "retiredPermit", "constraint", "unknown", "scheduler", "byteLimit"])
    func crossRoomPlainCommit(scenario: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let rooms = try await ownerBatchRooms(database: database, profile: profile, now: now)
            for recipient in [memberTwoUUID, memberThreeUUID] {
                try await sql.raw("""
                    INSERT INTO im_v2.user_relationships VALUES
                    (LEAST(\(bind: senderUUID)::uuid,\(bind: recipient)::uuid),
                     GREATEST(\(bind: senderUUID)::uuid,\(bind: recipient)::uuid),'accepted',\(bind: senderUUID),\(bind: now))
                    """).run()
            }
            let policies = v2FixtureRoomPolicyAuthorizations(database: database)
            let metrics = V2SendOperationBatchMetrics(), observer = DurableOwnerBatchObserver()
            let store = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database, contentReviewMode: .disabled)
                    .usingControlDatabase(database).usingPolicyAuthorizations(policies),
                clock: { now }, committedMessageObserver: observer, sendOperationMetrics: metrics)
            let prepare = policies.fixtureSendPreparation(store: store, now: { now })
            try await withRoomActivation(database: database, roomID: rooms[0]) { first in
                try await withRoomActivation(database: database, roomID: rooms[1]) { second in
                    let tokens = [first, second]
                    for token in tokens {
                        let warm = try ownerBatchCommand(room: token.roomID, text: "initialize", now: now)
                        let handle = try await prepare([warm], token, .now + .seconds(30))
                        let result = try await store.executeIndependentRoomTurns([handle], capacityProfile: profile,
                            identifiers: .init(), now: { now })
                        _ = try result[0].get()
                    }
                    let text = scenario == "byteLimit" ? String(repeating: "a", count: 18_000) : "batch"
                    let firstID = try ClientMessageID("FFFFFFFF-0000-4000-8000-000000000002")
                    let secondID = try ClientMessageID("00000000-0000-4000-8000-000000000001")
                    let commands = try rooms.map { try ownerBatchCommand(room: $0, operationID: firstID, text: text, now: now) }
                    let firstCommands = scenario == "commit"
                        ? try [commands[0], ownerBatchCommand(room: rooms[0], operationID: secondID, text: "next in room", now: now)]
                        : [commands[0]]
                    let a = try await prepare(firstCommands, first, .now + .seconds(30))
                    let b = try await prepare([commands[1]], second, .now + .seconds(30))
                    if scenario == "stale" {
                        try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=owner_epoch+1 WHERE room_id=\(bind: rooms[1].uuidValue!)").run()
                    } else if scenario == "retiredPermit" {
                        await policies.retire(token: second)
                    } else if scenario == "constraint" {
                        // Reject only the second message after the first room could have advanced.
                        let room = try #require(rooms[1].uuidValue)
                        let operation = try #require(commands[1].command.clientMessageID.uuidValue)
                        try await sql.raw("""
                            ALTER TABLE im_v2.message_send_completions ADD CHECK
                            ((room_id,client_message_id) <> (\(literal: room.uuidString)::uuid,\(literal: operation.uuidString)::uuid))
                            """).run()
                    } else if scenario == "unknown" {
                        try await sql.raw("""
                            CREATE FUNCTION im_v2.fixture_slow_commit() RETURNS trigger LANGUAGE plpgsql AS $$
                            BEGIN PERFORM pg_sleep(1); RETURN NEW; END $$
                            """).run()
                        try await sql.raw("""
                            CREATE CONSTRAINT TRIGGER fixture_slow_commit AFTER INSERT ON im_v2.messages
                            DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION im_v2.fixture_slow_commit()
                            """).run()
                    }
                    let before = try await count("im_v2.messages", on: sql)
                    let outboxBefore = try await count("im_v2.room_dispatch_outbox", on: sql)
                    let observed = Mutex<[Int]>([])
                    let instrumented = store.observingOwnerTransactions { _, _, count in observed.withLock { $0.append(count) } }
                    if scenario == "scheduler" || scenario == "byteLimit" {
                        let (gate, signal) = AsyncStream<Void>.makeStream()
                        let scheduler = V2DurableSendOperationOwnerBatcher(store: store,
                            configuration: .init(maximumPendingRequests: 8, maximumCrossRoomMessages: 4),
                            maximumRetainedBytes: 262_144, resourceDemandLimit: 1,
                            scheduledConnection: { deadline, body in
                                for await _ in gate { break }
                                try await instrumented.withMessageWriteConnection(deadline: deadline, body)
                            }, scheduledGroup: { turn, group in
                                try await turn.executeGroup?(group, profile, .init(), { now })
                            }, scheduledExecute: { turn, handle in try await turn.execute(handle, profile, .init(), { now }) })
                        async let firstACK = scheduler.execute(a)
                        async let secondACK = scheduler.execute(b)
                        let cutoff = ContinuousClock.now + .seconds(3)
                        while scheduler.pressureSnapshot().queuedTurns < 2 && ContinuousClock.now < cutoff { await Task.yield() }
                        signal.finish()
                        let received = try await [firstACK, secondACK]
                        await scheduler.shutdown()
                        #expect(observed.withLock { $0 } == (scenario == "byteLimit" ? [1, 1] : [2]))
                        #expect(received.map(\.count) == [1, 1])
                        #expect(observer.count == 4)
                        #expect(try await count("im_v2.messages", on: sql) == before + 2)
                        #expect(try await count("im_v2.message_send_completions", on: sql) == before + 2)
                        return
                    }
                    let deadline = ContinuousClock.now + (scenario == "unknown" ? .milliseconds(600) : .seconds(10))
                    let outcomes: [V2ScheduledSendOutcome]?
                    do {
                        outcomes = try await instrumented.withMessageWriteConnection(deadline: .now + .seconds(10), pipelineDepth: 2) { executor in
                            let execute = try #require(executor.makeTurn().executeGroup)
                            if scenario == "commit" {
                                let duplicateRoom = try await execute([b, b], profile, .init(), { now })
                                #expect(duplicateRoom == nil)
                            }
                            return try await V2RoomSQLDeadline.withDeadline(deadline) {
                                try await execute([a, b], profile, .init(), { now })
                            }
                        }
                        #expect(scenario != "unknown")
                    } catch is V2RoomTransactionOutcomeUnknown {
                        #expect(scenario == "unknown")
                        #expect(observer.count == 2)
                        #expect(metrics.sendOperationBatchMetricsSnapshot().ownerCohortIsolations == 0)
                        // Wait for the server's deferred COMMIT to settle after its client disconnected.
                        for _ in 0..<200 {
                            if try await count("pg_stat_activity WHERE datname=current_database() AND query='COMMIT' AND state='active'", on: sql) == 0 { break }
                            try await Task.sleep(for: .milliseconds(25))
                        }
                        let committed = try await count("im_v2.messages", on: sql) - before
                        #expect(committed == 0 || committed == 2)
                        try await sql.raw("DROP TRIGGER fixture_slow_commit ON im_v2.messages").run()
                        let retried = try await store.executeIndependentRoomTurns([a, b], capacityProfile: profile, identifiers: .init(), now: { now })
                        for result in retried { _ = try result.get() }
                        #expect(try await count("im_v2.messages", on: sql) == before + 2)
                        #expect(try await count("im_v2.message_send_completions", on: sql) == before + 2)
                        return
                    }
                    let reachedAppend = scenario != "stale" && scenario != "retiredPermit"
                    #expect(observed.withLock { $0 } == (reachedAppend ? [2] : []))
                    if scenario == "commit" {
                        let committed = try #require(outcomes)
                        #expect(committed.count == 2)
                        #expect(observer.count == 2)
                        // An ACK can be lost after COMMIT, before either Actor applies its result.
                        // Read the permanent receipts through a fresh store, without a live room cache.
                        let restarted = v2FixtureMessageSendOperationStore(database: database, writes: .init(database: database), clock: { now })
                        for (i, inputs) in [firstCommands, [commands[1]]].enumerated() {
                            let values = try committed[i].result.get()
                            #expect(values.count == inputs.count)
                            var sequence: UInt64?
                            for (command, value) in zip(inputs, values) {
                                let query = try V2MessageSendOperationRecoveryRequest(identity: command.identity,
                                    fingerprint: command.fingerprint, domainFingerprint: command.command.fingerprint)
                                let durable = try await restarted.recover(query, token: tokens[i])
                                #expect(value == .sendOperation(durable))
                                guard case .receipt(let receipt) = durable, case .accepted(let ack) = receipt.outcome else {
                                    throw V2MessageOperationValidationError.invalidReceipt
                                }
                                if let sequence { #expect(ack.roomSequence == sequence + 1) }
                                sequence = ack.roomSequence
                                let changed = try ownerBatchCommand(room: rooms[i], operationID: command.command.clientMessageID, text: "different", now: now)
                                let mismatch = try V2MessageSendOperationRecoveryRequest(identity: changed.identity,
                                    fingerprint: changed.fingerprint, domainFingerprint: changed.command.fingerprint)
                                #expect(try await restarted.recover(mismatch, token: tokens[i]) == .fingerprintConflict)
                            }
                        }
                        // Finish the two rooms independently, including in reverse order.
                        for outcome in committed.reversed() { await outcome.finalize() }
                        #expect(observer.count == 5)
                        let replay = try await store.executeIndependentRoomTurns([a, b], capacityProfile: profile, identifiers: .init(), now: { now })
                        for i in commands.indices {
                            let values = try committed[i].result.get()
                            guard case .sendOperation(.receipt(let receipt)) = values.first,
                                  case .accepted = receipt.outcome else { throw V2MessageOperationValidationError.invalidReceipt }
                            #expect(receipt.validates(identity: try commands[i].identity, fingerprint: try commands[i].fingerprint))
                            #expect(try replay[i].get() == values)
                        }
                        #expect(try await count("im_v2.messages", on: sql) == before + 3)
                        #expect(try await count("im_v2.room_dispatch_outbox", on: sql) == outboxBefore + 3)
                        #expect(try await count("im_v2.message_send_completions", on: sql) == before + 3)
                    } else {
                        #expect(outcomes == nil)
                        #expect(observer.count == 2)
                        #expect(try await count("im_v2.messages", on: sql) == before)
                        #expect(try await count("im_v2.room_dispatch_outbox", on: sql) == outboxBefore)
                        #expect(try await count("im_v2.message_send_completions", on: sql) == before)
                        let healthy = try await store.executeIndependentRoomTurns([a], capacityProfile: profile, identifiers: .init(), now: { now })
                        _ = try healthy[0].get()
                        #expect(try await count("im_v2.messages", on: sql) == before + 1)
                    }
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
            text: text, limits: .init(maxUTF8Bytes: max(64, text.utf8.count))), firstSubmissionDeadlineMilliseconds: UInt64(now.timeIntervalSince1970 * 1000) + 60_000)
    }
}

private struct DurableOwnerBatchCount: Decodable { let value: Int64 }
private final class DurableOwnerBatchObserver: V2CommittedMessageBatchObserving, Sendable {
    private let messages = Mutex<Int>(0)
    var count: Int { messages.withLock { $0 } }
    func observeCommittedMessages(_ outcomes: [V2SendMessageOutcome], activation: V2RoomActivationToken) { messages.withLock { $0 += outcomes.count } }
}

private struct DurableOwnerBatchBool: Decodable { let value: Bool }
