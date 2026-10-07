@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
import IMV2ActorContracts
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("combined owner fence samples policy expiry after every policy lock", arguments: [false, true])
    func combinedOwnerPolicyFenceRejectsExpiry(expireBlockedHolder: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            try await withRoomActivation(database: database, roomID: roomID, shardID: "room-a") { token in
                let expiry = Date().addingTimeInterval(0.5)
                let first = V2PolicyAuthorizationHolder(registrationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    roomID: token.roomID.uuidValue!, activationID: UUID(), roomOwnerEpoch: token.owner.epoch,
                    generation: 1, endpoint: "room-a", validUntil: expireBlockedHolder ? Date().addingTimeInterval(30) : expiry)
                let last = V2PolicyAuthorizationHolder(registrationID: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
                    roomID: token.roomID.uuidValue!, activationID: UUID(), roomOwnerEpoch: token.owner.epoch,
                    generation: 2, endpoint: "room-a", validUntil: expireBlockedHolder ? expiry : Date().addingTimeInterval(30))
                let policyFence = PostgresV2RoomPolicyLeaseFence(database: database)
                try await policyFence.install(first); try await policyFence.install(last)
                let check = try policyFence.combinedCheck([last, first, first])
                let gate = DurableWaveTupleQueueGate()
                let deadline = ContinuousClock.now + .seconds(8)
                let blocker = Task {
                    do {
                        try await v2WithRoomScopedTransaction(database: database) { transaction in
                            let connection = try #require(transaction as? any SQLDatabase)
                            _ = try await connection.raw("SELECT registration_id FROM im_v2.room_policy_authorization_leases WHERE registration_id=\(bind: last.registrationID) FOR UPDATE").all()
                            await gate.holdUpdatedRow()
                        }
                    } catch { await gate.release(); throw error }
                }
                await gate.waitUntilHolderReady()
                let waiter = Task {
                    try await v2WithRoomActivationTransactionWithContext(database: database, deadline: deadline) { transaction, fence in
                        let connection = try #require(transaction as? any SQLDatabase)
                        let pid = try #require(try await connection.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: DurableWaveCount.self)).value
                        await gate.registerTail(pid)
                        try await fence.requireDurableOwnersAndActivations(tokens: [token], operations: [
                            .init(roomID: token.roomID.uuidValue!, senderID: senderUUID, clientMessageID: UUID())], policyCheck: check)
                    }
                }
                do {
                    var blocked = false
                    while ContinuousClock.now < deadline {
                        if let pid = await gate.tailPIDs.first,
                           try await sql.raw("SELECT cardinality(pg_blocking_pids(\(bind: pid)::integer))::bigint AS value")
                            .first(decoding: DurableWaveCount.self)?.value ?? 0 > 0 { blocked = true; break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    #expect(blocked)
                    while try await sql.raw("SELECT CASE WHEN clock_timestamp()>=\(bind: expiry) THEN 1 ELSE 0 END::bigint AS value")
                        .first(decoding: DurableWaveCount.self)?.value ?? 0 == 0 {
                        guard ContinuousClock.now < deadline else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    await gate.release(); try await blocker.value
                    await #expect(throws: V2PolicyAuthorizationLifecycleError.staleVersion) { try await waiter.value }
                } catch {
                    await gate.release(); _ = await blocker.result; _ = await waiter.result
                    throw error
                }
            }
        }
    }

    @Test("configured durable fence rejects expiry observed after the lock wait", arguments: [false, true])
    func durableConfiguredFenceRejectsExpiryAfterLockWait(expiresDuringWait: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            try await withRoomActivation(database: database, roomID: roomID, shardID: "room-a") { token in
                let gate = DurableWaveTupleQueueGate()
                let deadline = ContinuousClock.now + .seconds(5)
                let expiryRow = try #require(try await sql.raw("SELECT clock_timestamp()+make_interval(secs => \(bind: expiresDuringWait ? 0.3 : -1.0)) AS expiry").first())
                let expiry = try expiryRow.decode(column: "expiry", as: Date.self)
                let holder = Task {
                    do {
                        try await V2RoomSQLDeadline.withDeadline(deadline) {
                            try await v2WithRoomScopedTransaction(database: database) { transaction in
                                let connection = try #require(transaction as? any SQLDatabase)
                                try await connection.raw("UPDATE im_v2.room_activation_leases SET expires_at=\(bind: expiry) WHERE room_id=\(bind: token.roomID.uuidValue!)").run()
                                await gate.holdUpdatedRow()
                            }
                        }
                    } catch { await gate.release(); throw error }
                }
                await gate.waitUntilHolderReady()
                let waiter = Task {
                    try await v2WithRoomActivationTransactionWithContext(database: database, deadline: deadline) { transaction, fence in
                        let connection = try #require(transaction as? any SQLDatabase)
                        let entered = try #require(try await connection.raw("SELECT pg_backend_pid()::bigint AS value, clock_timestamp()<\(bind: expiry) AS valid_before_wait").first())
                        let pid = try entered.decode(column: "value", as: Int64.self)
                        if expiresDuringWait { #expect(try entered.decode(column: "valid_before_wait", as: Bool.self)) }
                        await gate.registerTail(pid)
                        try await fence.requireDurableOwnersAndActivations(tokens: [token], operations: [
                            .init(roomID: token.roomID.uuidValue!, senderID: senderUUID, clientMessageID: UUID())])
                    }
                }
                do {
                    var observed = false
                    while ContinuousClock.now < deadline {
                        if let pid = await gate.tailPIDs.first {
                            let count = try await sql.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE pid=\(bind: pid) AND wait_event_type='Lock'").first(decoding: DurableWaveCount.self)
                            if count?.value == 1 { observed = true; break }
                        }
                        await Task.yield()
                    }
                    if observed, expiresDuringWait {
                        var expired = false
                        while ContinuousClock.now < deadline {
                            let clock = try #require(try await sql.raw("SELECT clock_timestamp()>=\(bind: expiry) AS expired").first())
                            if try clock.decode(column: "expired", as: Bool.self) { expired = true; break }
                            try await Task.sleep(for: .milliseconds(5))
                        }
                        #expect(expired)
                    }
                    await gate.release()
                    try await holder.value
                    #expect(observed)
                    await #expect(throws: V2RoomActivationLeaseError.leaseExpired) { try await waiter.value }
                } catch {
                    await gate.release()
                    _ = try? await holder.value
                    _ = try? await waiter.value
                    throw error
                }
            }
        }
    }

    @Test("two real prepared owner cohorts share one quota pool through concurrent multi-command waves")
    func durableOwnerConcurrentCohortsPreserveQuotaAndReceipts() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, controlSQL, sql, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let extraRecipients = [UUID(), UUID()]
            for databaseSQL in [controlSQL, sql] {
                for (index, user) in extraRecipients.enumerated() {
                    try await databaseSQL.raw("""
                        INSERT INTO im_v2.public_user_profiles
                          (user_id,public_handle,display_name,revision,created_at,updated_at)
                        VALUES (\(bind: user),\(bind: "wavepeer0\(index)"),'wave recipient',1,\(bind: now),\(bind: now))
                        """).run()
                }
            }
            var openedRooms: [RoomID] = []
            for recipient in [memberTwoUUID, memberThreeUUID] + extraRecipients {
                let opened = try await V2DirectRoomOperationTestFixture(database: owner, capacityProfile: profile,
                    roomShardID: "room-b", roomID: .init(uuid: UUID()), now: { now }).openedIdentity(
                        actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: recipient),
                        firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
                openedRooms.append(opened.roomID)
            }
            let rooms = openedRooms
            let commands = try rooms.enumerated().map { index, room in
                try (0..<2).map { sequence in
                    try V2MessageSendOperationCommand(command: .init(roomID: room, senderUserID: senderID,
                        clientMessageID: .init(uuid: UUID()), text: "cohort \(index) wave \(sequence)",
                        limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
                }
            }
            let metrics = V2SendOperationBatchMetrics()
            let store = PostgresV2MessageSendOperationStore(database: owner,
                writes: PostgresV2RoomWriteStore(database: owner,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 100, window: 86_400),
                    contentReviewMode: .disabled).usingControlDatabase(control), clock: { now },
                sendOperationMetrics: metrics, combineOwnerPreflight: true)
            let before = try #require(try await sql.raw("SELECT command_window_used AS value FROM im_v2.shard_admission_pools WHERE room_shard_id='room-b' AND capacity_profile_id='standard'").first(decoding: DurableWaveCount.self))
            try await withRoomActivation(database: owner, roomID: rooms[0], shardID: "room-b") { token0 in
                try await withRoomActivation(database: owner, roomID: rooms[1], shardID: "room-b") { token1 in
                    try await withRoomActivation(database: owner, roomID: rooms[2], shardID: "room-b") { token2 in
                        try await withRoomActivation(database: owner, roomID: rooms[3], shardID: "room-b") { token3 in
                            let tokens = [token0, token1, token2, token3]
                            let deadline = ContinuousClock.now + .seconds(30)
                            let prepared = try await store.prepareOwnerBatches(rooms.indices.map {
                                .init(commands: commands[$0], token: tokens[$0], deadline: deadline)
                            }, now: { now })
                            let handles = try prepared.map { try $0.get() }
                            // Preparation has fully committed before either
                            // owner transaction starts. No artificial row-lock
                            // gate or success result stands in for the chain.
                            let turns = try await withThrowingTaskGroup(
                                of: (Int, [Result<[V2RoomMessagingResult], any Error>]).self
                            ) { group in
                                for cohort in 0..<2 {
                                    group.addTask {
                                        let selected = Array(handles[(cohort * 2)..<(cohort * 2 + 2)])
                                        return (cohort, try await store.executeIndependentRoomTurns(selected,
                                            capacityProfile: profile, identifiers: .init(), now: { now }))
                                    }
                                }
                                var result: [Int: [Result<[V2RoomMessagingResult], any Error>]] = [:]
                                for try await (cohort, values) in group { result[cohort] = values }
                                return result
                            }
                            for cohort in 0..<2 {
                                let values = try #require(turns[cohort])
                                try #require(values.count == 2)
                                for index in 0..<2 {
                                    try assertWaveReceipts(try values[index].get(),
                                        commands: commands[cohort * 2 + index], sequences: [1, 2])
                                }
                            }
                            for table in ["messages", "message_send_completions", "direct_authorization_receipts"] {
                                #expect(try await count("im_v2.\(table)", on: sql) == 8)
                            }
                            let after = try #require(try await sql.raw("SELECT command_window_used AS value FROM im_v2.shard_admission_pools WHERE room_shard_id='room-b' AND capacity_profile_id='standard'").first(decoding: DurableWaveCount.self))
                            #expect(after.value == before.value)
                            for room in rooms {
                                #expect(try await sql.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: room.uuidValue!)").first(decoding: DurableWaveCount.self)?.value == 2)
                            }
                            let snapshot = metrics.sendOperationBatchMetricsSnapshot()
                            #expect(snapshot.ownerCohortCommits == 4)
                            #expect(snapshot.ownerCohortAcceptedCommands == 8)
                            #expect(snapshot.ownerCohortIsolations == 0)
                            #expect(snapshot.stages[.ownerCommit]?.count == 4)
                            #expect(snapshot.stages[.ownerRollback]?.count ?? 0 == 0)
                        }
                    }
                }
            }
        }
    }

    @Test("full cohort preserves first producers, reciprocal replies and cumulative stranger quota", arguments: [false, true])
    func durableOwnerFullCohortProducerAndQuotaBoundaries(quotaBoundary: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, _, sql, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            var openedRooms: [RoomID] = []
            for recipient in [memberTwoUUID, memberThreeUUID] {
                let opened = try await V2DirectRoomOperationTestFixture(database: owner, capacityProfile: profile,
                    roomShardID: "room-b", roomID: .init(uuid: UUID()), now: { now }).openedIdentity(
                        actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: recipient),
                        firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
                openedRooms.append(opened.roomID)
            }
            let rooms = openedRooms
            // These new rooms contain no messages. Exercise both still-missing
            // producer directions without fabricating grants or operation state.
            for room in rooms {
                try await sql.raw("""
                    UPDATE im_v2.direct_room_pairs SET lower_profile_visible_to_higher=false,
                        higher_profile_visible_to_lower=false, lower_can_send=NULL, higher_can_send=NULL,
                        lower_has_replied=false, higher_has_replied=false
                    WHERE room_id=\(bind: room.uuidValue!)
                    """).run()
            }
            @Sendable func command(_ room: RoomID, sender: UserID, text: String) throws -> V2MessageSendOperationCommand {
                try .init(command: .init(roomID: room, senderUserID: sender, clientMessageID: .init(uuid: UUID()),
                    text: text, limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            }
            var buildingCommands = try [command(rooms[0], sender: senderID, text: "A first"),
                                     command(rooms[0], sender: senderID, text: "A second")]
            if quotaBoundary {
                buildingCommands.append(try command(rooms[0], sender: senderID, text: "A beyond quota"))
            } else {
                let peer = UserID(uuid: memberTwoUUID)
                buildingCommands += try [command(rooms[0], sender: peer, text: "B first reply"),
                                      command(rooms[0], sender: peer, text: "B second reply")]
            }
            let firstCommands = buildingCommands
            let secondCommands = try [command(rooms[1], sender: senderID, text: "healthy other room")]
            let initialRevision = try #require(try await sql.raw("SELECT direct_policy_revision AS value FROM im_v2.direct_room_pairs WHERE room_id=\(bind: rooms[0].uuidValue!)").first(decoding: DurableWaveCount.self)).value
            let metrics = V2SendOperationBatchMetrics()
            let store = PostgresV2MessageSendOperationStore(database: owner,
                writes: PostgresV2RoomWriteStore(database: owner,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: quotaBoundary ? 2 : 100, window: 86_400),
                    contentReviewMode: .disabled).usingControlDatabase(control), clock: { now },
                sendOperationMetrics: metrics, combineOwnerPreflight: true)
            try await withRoomActivation(database: owner, roomID: rooms[0], shardID: "room-b") { firstToken in
                try await withRoomActivation(database: owner, roomID: rooms[1], shardID: "room-b") { secondToken in
                    let prepared = try await store.prepareOwnerBatches([
                        .init(commands: firstCommands, token: firstToken, deadline: .now + .seconds(30)),
                        .init(commands: secondCommands, token: secondToken, deadline: .now + .seconds(30))
                    ], now: { now })
                    let handles = try prepared.map { try $0.get() }
                    let results = try await store.executeIndependentRoomTurns(handles, capacityProfile: profile,
                        identifiers: .init(), now: { now })
                    let first = try results[0].get()
                    let acceptedCount: Int64 = quotaBoundary ? 3 : 5
                    if quotaBoundary {
                        // Original scalar semantics preserve eligible items and
                        // defer a quota-exhausted identity; do not strengthen it
                        // into an all-turn domain denial or accept it past quota.
                        try #require(first.count == 3)
                        try assertWaveReceipts(Array(first.prefix(2)), commands: Array(firstCommands.prefix(2)), sequences: [1, 2])
                        guard case .sendOperation(.deferred(let deferred)) = first[2] else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                        #expect(deferred.reason == .rateLimited)
                    } else {
                        try assertWaveReceipts(first, commands: firstCommands, sequences: [1, 2, 3, 4])
                        #expect(metrics.sendOperationBatchMetricsSnapshot().ownerCohortCommits == 2)
                        #expect(metrics.sendOperationBatchMetricsSnapshot().stages[.ownerCommit]?.count == 2)
                        #expect(try await count("im_v2.direct_room_pairs WHERE room_id='\(rooms[0].uuidValue!)' AND lower_has_replied AND higher_has_replied", on: sql) == 1)
                        // B replies after A within this cohort, so B must not
                        // consume the stranger quota for an already replied peer.
                        #expect(try await count("im_v2.stranger_message_windows WHERE sender_user_id='\(memberTwoUUID)' AND recipient_user_id='\(senderUUID)'", on: sql) == 0)
                    }
                    try assertWaveReceipts(try results[1].get(), commands: secondCommands, sequences: [1])
                    #expect(try await sql.raw("SELECT direct_policy_revision AS value FROM im_v2.direct_room_pairs WHERE room_id=\(bind: rooms[0].uuidValue!)").first(decoding: DurableWaveCount.self)?.value == initialRevision + (quotaBoundary ? 1 : 2))
                    #expect(try await sql.raw("SELECT message_count::bigint AS value FROM im_v2.stranger_message_windows WHERE sender_user_id=\(bind: senderUUID) AND recipient_user_id=\(bind: memberTwoUUID)").first(decoding: DurableWaveCount.self)?.value == 2)
                    for table in ["messages", "message_send_completions", "direct_authorization_receipts"] {
                        #expect(try await count("im_v2.\(table)", on: sql) == acceptedCount)
                    }
                    // Ignore opening projections: only the source events of
                    // actual accepted messages belong to the producer assertions.
                    let eventCount = try #require(try await sql.raw("""
                        SELECT count(*)::bigint AS value FROM im_v2.user_state_event_outbox AS event
                        JOIN im_v2.message_send_completions AS completion ON completion.event_id=event.source_event_id
                        WHERE completion.room_id IN (\(bind: rooms[0].uuidValue!),\(bind: rooms[1].uuidValue!))
                          AND event.projection_kind IN ('direct_sending_capability','direct_room_profile')
                        """).first(decoding: DurableWaveCount.self)).value
                    #expect(eventCount == (quotaBoundary ? 4 : 6))
                    let lateEvents = try #require(try await sql.raw("""
                        SELECT count(*)::bigint AS value FROM im_v2.user_state_event_outbox AS event
                        JOIN im_v2.message_send_completions AS completion ON completion.event_id=event.source_event_id
                        WHERE completion.room_id IN (\(bind: rooms[0].uuidValue!),\(bind: rooms[1].uuidValue!))
                          AND event.projection_kind IN ('direct_sending_capability','direct_room_profile')
                          AND completion.room_sequence > (
                            SELECT min(first.room_sequence) FROM im_v2.message_send_completions AS first
                            WHERE first.room_id=completion.room_id AND first.sender_user_id=completion.sender_user_id)
                        """).first(decoding: DurableWaveCount.self)).value
                    #expect(lateEvents == 0)
                    let replay = try await store.executeIndependentRoomTurns(handles, capacityProfile: profile,
                        identifiers: .init(), now: { now })
                    #expect(try replay[0].get() == first)
                    #expect(try replay[1].get() == results[1].get())
                    for table in ["messages", "message_send_completions", "direct_authorization_receipts"] {
                        #expect(try await count("im_v2.\(table)", on: sql) == acceptedCount)
                    }
                    let replayEvents = try #require(try await sql.raw("""
                        SELECT count(*)::bigint AS value FROM im_v2.user_state_event_outbox AS event
                        JOIN im_v2.message_send_completions AS completion ON completion.event_id=event.source_event_id
                        WHERE completion.room_id IN (\(bind: rooms[0].uuidValue!),\(bind: rooms[1].uuidValue!))
                          AND event.projection_kind IN ('direct_sending_capability','direct_room_profile')
                        """).first(decoding: DurableWaveCount.self)).value
                    #expect(replayEvents == eventCount)
                    #expect(try await sql.raw("SELECT message_count::bigint AS value FROM im_v2.stranger_message_windows WHERE sender_user_id=\(bind: senderUUID) AND recipient_user_id=\(bind: memberTwoUUID)").first(decoding: DurableWaveCount.self)?.value == 2)
                }
            }
        }
    }

    @Test("durable quota tail survives two old-snapshot waiters behind an actual pool update")
    func durableOwnerQuotaSurvivesTupleQueue() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { _, owner, _, sql, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            // The shared fixture has one EventLoop and four connections: one
            // holder, two tails, one observer. Four tails would deadlock the
            // fixture's pool before PostgreSQL can expose their lock queue.
            // Allocate only the test quota needed by three rounds (6 each).
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET command_window_limit=30 WHERE room_shard_id='room-b' AND capacity_profile_id='standard'").run()
            for _ in 0..<3 {
                let original = try #require(try await sql.raw("SELECT lease_id,generation,command_window_used AS value FROM im_v2.shard_admission_pools WHERE room_shard_id='room-b' AND capacity_profile_id='standard'").first(decoding: DurableWaveQuotaLease.self))
                let gate = DurableWaveTupleQueueGate()
                let metrics = V2SendOperationBatchMetrics()
                let deadline = ContinuousClock.now + .seconds(5)
                let holder = Task {
                    do {
                        try await V2RoomSQLDeadline.withDeadline(deadline) {
                            try await v2WithRoomScopedTransaction(database: owner) { transaction in
                                let connection = try #require(transaction as? any SQLDatabase)
                                // A real non-key UPDATE creates the newer tuple
                                // version. Neither test participant adds read locks.
                                try await connection.raw("UPDATE im_v2.shard_admission_pools SET command_window_used=command_window_used+1 WHERE lease_id=\(bind: original.lease_id) AND generation=\(bind: original.generation)").run()
                                await gate.holdUpdatedRow()
                            }
                        }
                    } catch { await gate.release(); throw error }
                }
                await gate.waitUntilHolderReady()
                @Sendable func tail(_ delta: Int) async throws {
                    try await V2RoomSQLDeadline.withDeadline(deadline) {
                        try await v2WithRoomScopedTransaction(database: owner, sendOperationMetrics: metrics) { transaction in
                            let connection = try #require(transaction as? any SQLDatabase)
                            let pid = try #require(try await connection.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: DurableWaveCount.self))
                            try await connection.raw("SAVEPOINT v2_durable_owner_cohort").run()
                            await gate.registerTail(pid.value)
                            try await v2ReserveDurableOwnerBatchAdmission([
                                .init(leaseID: original.lease_id, generation: original.generation,
                                    commandDelta: delta, roomShardID: "room-b", capacityProfileID: "standard")
                            ], retryAfterSeconds: 1, now: now, sql: connection)
                            try await connection.raw("RELEASE SAVEPOINT v2_durable_owner_cohort").run()
                        }
                    }
                }
                let first = Task { try await tail(2) }
                let second = Task { try await tail(3) }
                do {
                    var observedBoth = false
                    // Synchronize on actual PostgreSQL state, never a guessed
                    // sleep: both original statement snapshots must be waiting.
                    while ContinuousClock.now < deadline {
                        let pids = await gate.tailPIDs
                        if pids.count == 2 {
                            let waiting = try await sql.raw("""
                                SELECT count(*)::bigint AS value FROM pg_stat_activity
                                WHERE datname=current_database() AND pid IN (\(bind: pids[0]),\(bind: pids[1]))
                                  AND state='active' AND wait_event_type='Lock'
                                  AND query LIKE '%shard_admission_pools%'
                                """).first(decoding: DurableWaveCount.self)
                            if waiting?.value == 2 { observedBoth = true; break }
                        }
                        await Task.yield()
                    }
                    // Always release before recording failure or awaiting workers.
                    await gate.release()
                    try await holder.value
                    try await first.value
                    try await second.value
                    try #require(observedBoth, "both owned tail statements must actually wait behind the updated pool row")
                    let after = try #require(try await sql.raw("SELECT lease_id,generation,command_window_used AS value FROM im_v2.shard_admission_pools WHERE room_shard_id='room-b' AND capacity_profile_id='standard'").first(decoding: DurableWaveQuotaLease.self))
                    #expect(after.lease_id == original.lease_id)
                    #expect(after.generation == original.generation)
                    #expect(after.value == original.value + 6)
                    #expect(metrics.sendOperationBatchMetricsSnapshot().stages[.ownerCommit]?.count == 2)
                    #expect(metrics.sendOperationBatchMetricsSnapshot().stages[.ownerRollback]?.count ?? 0 == 0)
                } catch {
                    await gate.release()
                    // Preserve the first diagnostic, but retain ownership until
                    // every physical transaction has actually returned.
                    _ = await holder.result
                    _ = await first.result
                    _ = await second.result
                    throw error
                }
            }
        }
    }

    @Test("durable owner quota permits concurrent FK key-share holders without lock upgrade deadlock")
    func durableOwnerQuotaDoesNotUpgradeForeignKeyLocks() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { _, owner, _, sql, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let original = try #require(try await sql.raw("SELECT lease_id,generation,command_window_used AS value FROM im_v2.shard_admission_pools WHERE room_shard_id='room-b' AND capacity_profile_id='standard'").first(decoding: DurableWaveQuotaLease.self))
            let gate = DurableWaveKeyShareGate()
            let metrics = V2SendOperationBatchMetrics()
            @Sendable func reserve(_ delta: Int) async throws {
                do {
                try await V2RoomSQLDeadline.withDeadline(.now + .seconds(5)) {
                    try await v2WithRoomScopedTransaction(database: owner, sendOperationMetrics: metrics) { transaction in
                        let connection = try #require(transaction as? any SQLDatabase)
                        // This is the real PostgreSQL lock mode acquired by a
                        // referencing room_admission row's FK check. Both
                        // transactions must hold it before either enters tail.
                        let locked = try await connection.raw("SELECT lease_id,generation,command_window_used AS value FROM im_v2.shard_admission_pools WHERE lease_id=\(bind: original.lease_id) AND generation=\(bind: original.generation) FOR KEY SHARE").all(decoding: DurableWaveQuotaLease.self)
                        try #require(locked.count == 1)
                        try await gate.arrive()
                        try await v2ReserveDurableOwnerBatchAdmission([
                            .init(leaseID: original.lease_id, generation: original.generation,
                                commandDelta: delta, roomShardID: "room-b", capacityProfileID: "standard")
                        ], retryAfterSeconds: 1, now: now, sql: connection)
                    }
                }
                } catch {
                    // A setup/SQL failure must also unblock the other fixture
                    // participant; no orphan continuation can retain its SQL.
                    await gate.abort()
                    throw error
                }
            }
            async let first: Void = reserve(2)
            async let second: Void = reserve(3)
            _ = try await (first, second)
            let after = try #require(try await sql.raw("SELECT lease_id,generation,command_window_used AS value FROM im_v2.shard_admission_pools WHERE room_shard_id='room-b' AND capacity_profile_id='standard'").first(decoding: DurableWaveQuotaLease.self))
            #expect(after.lease_id == original.lease_id)
            #expect(after.generation == original.generation)
            #expect(after.value == original.value + 5)
            #expect(await gate.arrivalCount == 2)
            let stages = metrics.sendOperationBatchMetricsSnapshot().stages
            #expect(stages[.ownerCommit]?.count == 2)
            #expect(stages[.ownerRollback]?.count ?? 0 == 0)
        }
    }

    @Test("multi-command room turns use atomic collection waves and isolate a failing whole turn", arguments: [false, true])
    func durableOwnerWavesPreserveWholeTurns(badSecondCommand: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, _, sql, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            var openedRooms: [RoomID] = []
            for recipient in [memberTwoUUID, memberThreeUUID] {
                let opened = try await V2DirectRoomOperationTestFixture(database: owner, capacityProfile: profile,
                    roomShardID: "room-b", roomID: .init(uuid: UUID()), now: { now }).openedIdentity(
                        actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: recipient),
                        firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
                openedRooms.append(opened.roomID)
            }
            let rooms = openedRooms
            let aliasLease = UUID()
            try await sql.raw("INSERT INTO im_v2.shard_admission_pools (room_shard_id,capacity_profile_id,lease_id,generation,valid_until,command_window_limit) SELECT 'room-wave-b',capacity_profile_id,\(bind: aliasLease),generation,valid_until,command_window_limit FROM im_v2.shard_admission_pools WHERE room_shard_id='room-b'").run()
            try await sql.raw("UPDATE im_v2.rooms SET room_shard_id='room-wave-b' WHERE room_id=\(bind: rooms[1].uuidValue!)").run()
            try await sql.raw("UPDATE im_v2.room_owner_routes SET room_shard_id='room-wave-b' WHERE room_id=\(bind: rooms[1].uuidValue!)").run()
            try await sql.raw("UPDATE im_v2.room_admission SET shard_lease_id=\(bind: aliasLease) WHERE room_id=\(bind: rooms[1].uuidValue!)").run()
            @Sendable func command(_ room: RoomID, _ text: String) throws -> V2MessageSendOperationCommand {
                try .init(command: .init(roomID: room, senderUserID: senderID, clientMessageID: .init(uuid: UUID()),
                    text: text, limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            }
            let firstCommands = try [command(rooms[0], "wave A one"), command(rooms[0], "wave A two")]
            let secondCommands = try [command(rooms[1], "wave B one"), command(rooms[1], "wave B two")]
            let metrics = V2SendOperationBatchMetrics()
            let store = PostgresV2MessageSendOperationStore(database: owner,
                writes: PostgresV2RoomWriteStore(database: owner,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 100, window: 86_400),
                    contentReviewMode: .disabled).usingControlDatabase(control), clock: { now },
                sendOperationMetrics: metrics, combineOwnerPreflight: true)
            try await sql.raw("CREATE TABLE im_v2.fixture_wave_statements (table_name text NOT NULL, transaction_id bigint NOT NULL)").run()
            try await sql.raw("""
                CREATE FUNCTION im_v2.fixture_count_wave_statements() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    INSERT INTO im_v2.fixture_wave_statements VALUES (TG_TABLE_NAME, txid_current());
                    RETURN NULL;
                END
                $$
                """).run()
            for table in ["messages", "message_send_completions", "direct_authorization_receipts"] {
                try await sql.raw("CREATE TRIGGER fixture_wave_statement AFTER INSERT ON im_v2.\(unsafeRaw: table) FOR EACH STATEMENT EXECUTE FUNCTION im_v2.fixture_count_wave_statements()").run()
            }
            try await sql.raw("CREATE TRIGGER fixture_wave_admission AFTER UPDATE ON im_v2.shard_admission_pools FOR EACH STATEMENT EXECUTE FUNCTION im_v2.fixture_count_wave_statements()").run()
            if badSecondCommand {
                try await sql.raw("CREATE TABLE im_v2.fixture_bad_wave_operation (operation_id uuid NOT NULL)").run()
                try await sql.raw("INSERT INTO im_v2.fixture_bad_wave_operation VALUES (\(bind: firstCommands[1].command.clientMessageID.uuidValue!))").run()
                try await sql.raw("""
                    CREATE FUNCTION im_v2.fixture_reject_second_wave() RETURNS trigger LANGUAGE plpgsql AS $$
                    BEGIN
                        IF EXISTS (SELECT 1 FROM im_v2.fixture_bad_wave_operation WHERE operation_id=NEW.client_message_id) THEN
                            RAISE EXCEPTION 'second wave constraint' USING ERRCODE='23514';
                        END IF;
                        RETURN NEW;
                    END
                    $$
                    """).run()
                try await sql.raw("CREATE TRIGGER fixture_bad_wave BEFORE INSERT ON im_v2.messages FOR EACH ROW EXECUTE FUNCTION im_v2.fixture_reject_second_wave()").run()
            }
            let before = try await sql.raw("SELECT room_shard_id,command_window_used AS value FROM im_v2.shard_admission_pools WHERE room_shard_id IN ('room-b','room-wave-b') ORDER BY room_shard_id").all(decoding: DurableWaveAdmission.self)
            try await withRoomActivation(database: owner, roomID: rooms[0], shardID: "room-b") { firstToken in
                try await withRoomActivation(database: owner, roomID: rooms[1], shardID: "room-wave-b") { secondToken in
                    let prepared = try await store.prepareOwnerBatches([
                        .init(commands: firstCommands, token: firstToken, deadline: .now + .seconds(30)),
                        .init(commands: secondCommands, token: secondToken, deadline: .now + .seconds(30))
                    ], now: { now })
                    let handles = try prepared.map { try $0.get() }
                    let results = try await store.executeIndependentRoomTurns(handles, capacityProfile: profile, identifiers: .init(), now: { now })
                    #expect(results.count == 2)
                    let healthy = try results[1].get()
                    try assertWaveReceipts(healthy, commands: secondCommands, sequences: [1, 2])
                    if badSecondCommand {
                        if case .success = results[0] { Issue.record("a failing second command must fail its whole original room turn") }
                        #expect(try await count("im_v2.messages WHERE room_id='\(rooms[0].uuidValue!)'", on: sql) == 0)
                        #expect(try await count("im_v2.message_send_completions WHERE room_id='\(rooms[0].uuidValue!)'", on: sql) == 0)
                        #expect(try await sql.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: rooms[0].uuidValue!)").first(decoding: DurableWaveCount.self)?.value == 0)
                        #expect(try await count("im_v2.messages", on: sql) == 2)
                    } else {
                        let original = try results.map { try $0.get() }
                        try assertWaveReceipts(original[0], commands: firstCommands, sequences: [1, 2])
                        #expect(metrics.sendOperationBatchMetricsSnapshot().stages[.ownerCommit]?.count == 2)
                        for table in ["messages", "message_send_completions"] {
                            #expect(try await waveStatementCount(table, sql: sql) == 2)
                        }
                        for table in ["direct_authorization_receipts", "message_send_completions"] {
                            #expect(try await waveStatementCount(table, sql: sql) == 2)
                        }
                        #expect(try await waveStatementCount("shard_admission_pools", sql: sql) == 0)
                        #expect(try await sql.raw("SELECT count(DISTINCT transaction_id)::bigint AS value FROM im_v2.fixture_wave_statements").first(decoding: DurableWaveCount.self)?.value == 2)
                        #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.fixture_wave_statements budget JOIN im_v2.fixture_wave_statements message USING(transaction_id) WHERE budget.table_name='shard_admission_pools' AND message.table_name='messages'").first(decoding: DurableWaveCount.self)?.value == 0)
                        let replay = try await store.executeIndependentRoomTurns(handles, capacityProfile: profile, identifiers: .init(), now: { now })
                        #expect(try replay.map { try $0.get() } == original)
                        #expect(try await waveStatementCount("messages", sql: sql) == 2)
                        let freshFirst = try command(rooms[0], "wave A three")
                        let freshSecond = try command(rooms[1], "wave B three")
                        let mixed = try await store.prepareOwnerBatches([
                            .init(commands: [firstCommands[0], freshFirst], token: firstToken, deadline: .now + .seconds(30)),
                            .init(commands: [secondCommands[0], freshSecond], token: secondToken, deadline: .now + .seconds(30))
                        ], now: { now })
                        let mixedResults = try await store.executeIndependentRoomTurns(try mixed.map { try $0.get() }, capacityProfile: profile, identifiers: .init(), now: { now })
                        try assertWaveReceipts(try mixedResults[0].get(), commands: [firstCommands[0], freshFirst], sequences: [1, 3])
                        try assertWaveReceipts(try mixedResults[1].get(), commands: [secondCommands[0], freshSecond], sequences: [1, 3])
                        #expect(try await count("im_v2.messages", on: sql) == 6)
                        #expect(try await waveStatementCount("messages", sql: sql) == 4)
                        #expect(try await waveStatementCount("message_send_completions", sql: sql) == 4)
                    }
                    let after = try await sql.raw("SELECT room_shard_id,command_window_used AS value FROM im_v2.shard_admission_pools WHERE room_shard_id IN ('room-b','room-wave-b') ORDER BY room_shard_id").all(decoding: DurableWaveAdmission.self)
                    for index in before.indices {
                        #expect(after[index].room_shard_id == before[index].room_shard_id)
                        // Sending no longer mutates infrastructure quota rows.
                        #expect(after[index].value == before[index].value)
                    }
                }
            }
        }
    }
}

private func assertWaveReceipts(_ values: [V2RoomMessagingResult], commands: [V2MessageSendOperationCommand], sequences: [UInt64]) throws {
    try #require(values.count == commands.count)
    for index in commands.indices {
        guard case .sendOperation(.receipt(let receipt)) = values[index], case .accepted(let accepted) = receipt.outcome else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        #expect(receipt.validates(identity: try commands[index].identity, fingerprint: try commands[index].fingerprint))
        #expect(accepted.roomSequence == sequences[index])
    }
}
private func waveStatementCount(_ table: String, sql: any SQLDatabase) async throws -> Int64 {
    try #require(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.fixture_wave_statements WHERE table_name=\(bind: table)").first(decoding: DurableWaveCount.self)).value
}
private struct DurableWaveCount: Decodable { let value: Int64 }
private struct DurableWaveAdmission: Decodable { let room_shard_id: String; let value: Int64 }
private struct DurableWaveQuotaLease: Decodable, Sendable {
    let lease_id: UUID
    let generation: Int64
    let value: Int64
}
private actor DurableWaveKeyShareGate {
    private(set) var arrivalCount = 0
    private var first: CheckedContinuation<Void, any Error>?
    private var failed = false
    func arrive() async throws {
        guard !failed else { throw V2RoomWriteStoreError.corruptPersistenceState }
        arrivalCount += 1
        if arrivalCount == 2 {
            let waiting = first
            first = nil
            waiting?.resume(returning: ())
        } else {
            try await withCheckedThrowingContinuation { first = $0 }
        }
    }
    func abort() {
        failed = true
        let waiting = first
        first = nil
        waiting?.resume(throwing: V2RoomWriteStoreError.corruptPersistenceState)
    }
}
private actor DurableWaveTupleQueueGate {
    private var ready = false
    private var released = false
    private var readyWaiter: CheckedContinuation<Void, Never>?
    private var holderWaiter: CheckedContinuation<Void, Never>?
    private(set) var tailPIDs: [Int64] = []
    func holdUpdatedRow() async {
        ready = true
        let waiting = readyWaiter
        readyWaiter = nil
        waiting?.resume()
        guard !released else { return }
        await withCheckedContinuation { holderWaiter = $0 }
    }
    func waitUntilHolderReady() async {
        guard !ready, !released else { return }
        await withCheckedContinuation { readyWaiter = $0 }
    }
    func registerTail(_ pid: Int64) { tailPIDs.append(pid) }
    func release() {
        released = true
        let holder = holderWaiter, ready = readyWaiter
        holderWaiter = nil; readyWaiter = nil
        holder?.resume(); ready?.resume()
    }
}
