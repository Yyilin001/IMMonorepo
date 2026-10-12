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

@Suite("Room actor maintenance on PostgreSQL", .serialized)
struct V2RoomActorMaintenanceTests {
    @Test("retention scanner grants no authority; native execution and data ownership fence floor and delete")
    func activationFencedRetention() async throws {
        try await withMaintenanceDatabase { database, sql in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let room = UUID(), user = UUID()
            try await insertSummaryFixtureRoom(on: sql, room: room, kind: "group",
                sequence: 4, revision: 1, lastEventAt: now, createdAt: now)
            try await insertSummaryFixtureMembership(on: sql, room: room, user: user,
                joined: 1, left: nil)
            try await insertSummaryFixtureReadReceipt(on: sql, room: room, user: user,
                readThrough: 3, at: now)
            let firstEvent = UUID(), firstMessage = UUID(), stateID = UUID()
            try await sql.raw("""
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id,
                     payload, committed_membership_revision, created_at)
                VALUES (\(bind: firstEvent), \(bind: room), 1, 'message.accepted', \(bind: user),
                    jsonb_build_object('event_type', 'message.accepted',
                        'room_id', \(bind: room.uuidString.lowercased()),
                        'message_id', \(bind: firstMessage.uuidString.lowercased()),
                        'message_revision', 1, 'is_withdrawn', false), 1, \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.message_projection_states
                    (state_id, message_id, room_id, message_revision, variant_key,
                     origin_event_id, state_event_id, is_withdrawn,
                     payload_schema_version, payload, created_at, payload_storage)
                VALUES (\(bind: stateID), \(bind: firstMessage), \(bind: room), 1, 0,
                    \(bind: firstEvent), \(bind: firstEvent), false,
                    1, NULL, \(bind: now), 'room_event')
                """).run()
            #expect(try await maintenanceCount(sql, "im_v2.message_projection_state_values") == 1)
            for sequence in 2...4 {
                try await insertSummaryFixtureRoomEvent(on: sql, room: room,
                    sequence: Int64(sequence), revision: 1, message: UUID(), createdAt: now)
            }
            let scanner = PostgresV2RoomMaintenanceScanner(database: database)
            #expect(try await scanner.retentionCandidates(limit: 10) == [.init(uuid: room)])
            let executor = V2ActorRoomMaintenanceExecutor(database: database, now: { now })
            let command = V2RoomMaintenanceCommand.trimLog(.init(roomID: .init(uuid: room),
                mode: .permanent, windowSeconds: 3_600))
            try await withRoomActivation(database: database, roomID: .init(uuid: room)) { old in
            let worker = V2RoomActorMaintenanceWorker(scanner: scanner,
                invoker: LocalMaintenanceInvoker(executor: executor, token: old))
            let worked = try await worker.runRetention(limit: 10, mode: .permanent,
                window: 3_600)
            #expect(worked.scannedRooms == 1 && worked.advancedFloors == 1 && worked.deletedEvents == 2)
            guard case .logTrimmed(let first) = try await executor.execute(command, token: old) else {
                Issue.record("retention result kind mismatch"); return
            }
            #expect(!first.advancedFloor && first.deletedEvents == 0)
            #expect(try await maintenanceCount(sql, "im_v2.room_events") == 2)
            #expect(try await maintenanceFloor(sql, room) == 3)
            #expect(try await maintenanceCount(sql, "im_v2.message_projection_state_values") == 1)
            let body = try #require(try await sql.raw("""
                SELECT payload_storage AS value FROM im_v2.message_projection_states
                WHERE state_id = \(bind: stateID)
                """).first(decoding: MaintenanceStringRow.self))
            #expect(body.value == "inline")

            try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind:room)").run()
            await #expect(throws: V2RoomActorStateError.ownerChanged) {
                _ = try await executor.execute(command, token: old)
            }
            #expect(try await maintenanceCount(sql, "im_v2.room_events") == 2)
            }
            try await withRoomActivation(database: database, roomID: .init(uuid: room), epoch: 1) { successor in
            guard case .logTrimmed(let replay) = try await executor.execute(command, token: successor) else {
                Issue.record("retention replay kind mismatch"); return
            }
            #expect(!replay.advancedFloor && replay.deletedEvents == 0)
            }
        }
    }

    @Test("compactor cannot recreate a room-event body reference between materialization and delete")
    func compactorSkipsMaterializingRetention() async throws {
        try await withMaintenanceDatabase { database, sql in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let room = UUID(), user = UUID(), event = UUID(), message = UUID(), state = UUID()
            try await insertSummaryFixtureRoom(on: sql, room: room, kind: "group",
                sequence: 3, revision: 1, lastEventAt: now, createdAt: now)
            try await insertSummaryFixtureMembership(on: sql, room: room, user: user,
                joined: 1, left: nil)
            try await insertSummaryFixtureReadReceipt(on: sql, room: room, user: user,
                readThrough: 3, at: now)
            try await sql.raw("""
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id,
                     payload, committed_membership_revision, created_at)
                VALUES (\(bind: event), \(bind: room), 1, 'message.accepted', \(bind: user),
                    jsonb_build_object('event_type', 'message.accepted',
                        'room_id', \(bind: room.uuidString.lowercased()),
                        'message_id', \(bind: message.uuidString.lowercased()),
                        'message_revision', 1, 'is_withdrawn', false), 1, \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.message_projection_states
                    (state_id, message_id, room_id, message_revision, variant_key,
                     origin_event_id, state_event_id, is_withdrawn,
                     payload_schema_version, payload, created_at, payload_storage)
                VALUES (\(bind: state), \(bind: message), \(bind: room), 1, 0,
                    \(bind: event), \(bind: event), false, 1, NULL, \(bind: now), 'room_event')
                """).run()
            for sequence in 2...3 {
                try await insertSummaryFixtureRoomEvent(on: sql, room: room,
                    sequence: Int64(sequence), revision: 1, message: UUID(), createdAt: now)
            }
            let lockKey = Int64.random(in: 10_000_000...Int64.max / 2)
            try await sql.raw("""
                CREATE FUNCTION im_v2.test_pause_retention_delete() RETURNS trigger
                LANGUAGE plpgsql AS $$
                BEGIN
                    PERFORM pg_advisory_xact_lock(\(unsafeRaw: String(lockKey)));
                    RETURN OLD;
                END;
                $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER aa_test_pause_retention_delete BEFORE DELETE ON im_v2.room_events
                FOR EACH ROW EXECUTE FUNCTION im_v2.test_pause_retention_delete()
                """).run()
            try await withRoomActivation(database: database, roomID: .init(uuid: room)) { token in
            let locked = MaintenanceGate(), release = MaintenanceGate()
            let blocker = Task {
                try await database.transaction { transaction in
                    let tx = try #require(transaction as? any SQLDatabase)
                    try await tx.raw("SELECT pg_advisory_xact_lock(\(bind: lockKey))").run()
                    await locked.signal()
                    await release.wait()
                }
            }
            await locked.wait()
            let executor = V2ActorRoomMaintenanceExecutor(database: database, now: { now })
            let command = V2RoomMaintenanceCommand.trimLog(.init(roomID: .init(uuid: room),
                mode: .permanent, windowSeconds: 3_600))
            let trimmer = Task { try await executor.execute(command, token: token) }
            do {
            try await maintenanceWaitForDeleteLock(sql)
            let compaction = try await PostgresV2MessageProjectionStateBodyCompactionWorker(
                database: database).runOnce(limit: 10)
            #expect(compaction.compactedCount == 0)
            await release.signal()
            try await blocker.value
            guard case .logTrimmed(let outcome) = try await trimmer.value else {
                Issue.record("retention outcome kind mismatch"); return
            }
            #expect(outcome.advancedFloor && outcome.deletedEvents == 2)
            #expect(try await maintenanceCount(sql, "im_v2.message_projection_state_values") == 1)
            let storage = try #require(try await sql.raw("""
                SELECT payload_storage AS value FROM im_v2.message_projection_states
                WHERE state_id = \(bind: state)
                """).first(decoding: MaintenanceStringRow.self))
            #expect(storage.value == "inline")
            } catch {
                await release.signal()
                _ = await blocker.result
                _ = await trimmer.result
                throw error
            }
            }
        }
    }

    @Test("retention waits for an in-flight inline-to-event compaction before deleting source")
    func retentionWaitsForCompactorFirst() async throws {
        try await withMaintenanceDatabase { database, sql in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let room = UUID(), user = UUID(), event = UUID(), message = UUID(), state = UUID()
            try await insertSummaryFixtureRoom(on: sql, room: room, kind: "group",
                sequence: 2, revision: 1, lastEventAt: now, createdAt: now)
            try await insertSummaryFixtureMembership(on: sql, room: room, user: user,
                joined: 1, left: nil)
            try await insertSummaryFixtureReadReceipt(on: sql, room: room, user: user,
                readThrough: 2, at: now)
            try await sql.raw("""
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id,
                     payload, committed_membership_revision, created_at)
                VALUES (\(bind: event), \(bind: room), 1, 'message.accepted', \(bind: user),
                    jsonb_build_object('event_type', 'message.accepted',
                        'room_id', \(bind: room.uuidString.lowercased()),
                        'message_id', \(bind: message.uuidString.lowercased()),
                        'message_revision', 1, 'is_withdrawn', false), 1, \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.message_projection_states
                    (state_id, message_id, room_id, message_revision, variant_key,
                     origin_event_id, state_event_id, is_withdrawn,
                     payload_schema_version, payload, created_at, payload_storage)
                SELECT \(bind: state), \(bind: message), \(bind: room), 1, 0,
                       \(bind: event), \(bind: event), false, 1, payload, \(bind: now), 'inline'
                FROM im_v2.room_events WHERE event_id = \(bind: event)
                """).run()
            try await insertSummaryFixtureRoomEvent(on: sql, room: room,
                sequence: 2, revision: 1, message: UUID(), createdAt: now)
            try await withRoomActivation(database: database, roomID: .init(uuid: room)) { token in
            let compacted = MaintenanceGate(), release = MaintenanceGate()
            // Reproduce the compactor's UPDATE while its row lock is still
            // held. The other schedule uses the actual compactor with SKIP LOCKED.
            let compactorTransaction = Task {
                try await database.transaction { transaction in
                    let tx = try #require(transaction as? any SQLDatabase)
                    try await tx.raw("""
                        UPDATE im_v2.message_projection_states
                        SET payload = NULL, payload_storage = 'room_event'
                        WHERE state_id = \(bind: state)
                        """).run()
                    await compacted.signal()
                    await release.wait()
                }
            }
            await compacted.wait()
            let executor = V2ActorRoomMaintenanceExecutor(database: database, now: { now })
            let command = V2RoomMaintenanceCommand.trimLog(.init(roomID: .init(uuid: room),
                mode: .permanent, windowSeconds: 3_600))
            let trimmer = Task { try await executor.execute(command, token: token) }
            do {
            try await maintenanceWaitForMaterializationLock(sql)
            await release.signal()
            try await compactorTransaction.value
            guard case .logTrimmed(let result) = try await trimmer.value else {
                Issue.record("retention outcome kind mismatch"); return
            }
            #expect(result.advancedFloor && result.deletedEvents == 1)
            #expect(try await maintenanceCount(sql, "im_v2.message_projection_state_values") == 1)
            let storage = try #require(try await sql.raw("""
                SELECT payload_storage AS value FROM im_v2.message_projection_states
                WHERE state_id = \(bind: state)
                """).first(decoding: MaintenanceStringRow.self))
            #expect(storage.value == "inline")
            } catch {
                await release.signal()
                _ = await compactorTransaction.result
                _ = await trimmer.result
                throw error
            }
            }
        }
    }

    @Test("control cleanup excludes room rows; old data owner cannot delete terminal jobs or operations")
    func activationFencedBookkeeping() async throws {
        try await withMaintenanceDatabase { database, sql in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let oldDate = now.addingTimeInterval(-45 * 86_400)
            let room = UUID(), actor = UUID(), message = UUID()
            try await insertSummaryFixtureRoom(on: sql, room: room, kind: "group",
                sequence: 1, revision: 1, lastEventAt: oldDate, createdAt: oldDate)
            try await insertSummaryFixtureMembership(on: sql, room: room, user: actor,
                joined: 1, left: nil)
            try await insertSummaryFixtureMessage(on: sql, room: room, message: message,
                sender: actor, roomSequence: 1, timelineSequence: 1, text: "reviewed",
                createdAt: oldDate, storage: .roomEvent, revision: nil)
            try await sql.raw("""
                INSERT INTO im_v2.content_review_jobs
                    (message_id, room_id, expected_content_revision, state, decision, created_at, completed_at)
                VALUES (\(bind: message), \(bind: room), 1, 'completed', 'clear',
                        \(bind: oldDate), \(bind: oldDate))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.read_receipt_operations
                    (user_id, operation_id, room_id, requested_room_sequence,
                     resulting_room_sequence, recorded_at)
                VALUES (\(bind: actor), \(bind: UUID()), \(bind: room), 1, 1, \(bind: oldDate))
                """).run()
            let control = PostgresV2ControlPlaneHousekeepingStore(database: database)
            _ = try await control.purgeTerminal(now: now, retention: 7 * 86_400,
                idempotencyRetention: V2IdempotencyPolicy.minimumServerRetention, limit: 1_000)
            #expect(try await maintenanceCount(sql, "im_v2.content_review_jobs") == 1)
            #expect(try await maintenanceCount(sql, "im_v2.read_receipt_operations") == 1)

            let executor = V2ActorRoomMaintenanceExecutor(database: database, now: { now })
            let command = V2RoomMaintenanceCommand.purgeBookkeeping(.init(roomID: .init(uuid: room),
                retentionSeconds: 7 * 86_400,
                idempotencyRetentionSeconds: V2IdempotencyPolicy.minimumServerRetention,
                rowLimit: 100))
            try await withRoomActivation(database: database, roomID: .init(uuid: room)) { old in
            try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind:room)").run()
            await #expect(throws: V2RoomActorStateError.ownerChanged) {
                _ = try await executor.execute(command, token: old)
            }
            #expect(try await maintenanceCount(sql, "im_v2.content_review_jobs") == 1)
            #expect(try await maintenanceCount(sql, "im_v2.read_receipt_operations") == 1)
            }
            try await withRoomActivation(database: database, roomID: .init(uuid: room), epoch: 1) { current in
            guard case .bookkeepingPurged(let purged) = try await executor.execute(command,
                token: current) else { Issue.record("bookkeeping result kind mismatch"); return }
            #expect(purged.deletedReviewJobs == 1 && purged.deletedOperationRows == 1)
            #expect(try await maintenanceCount(sql, "im_v2.content_review_jobs") == 0)
            #expect(try await maintenanceCount(sql, "im_v2.read_receipt_operations") == 0)
            }
        }
    }

    @Test("typed trusted-safety failure leaves a review job retryable")
    func failedReviewApplyDoesNotResolveJob() async throws {
        try await withMaintenanceDatabase { database, sql in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let room = UUID(), actor = UUID(), message = UUID()
            try await insertSummaryFixtureRoom(on: sql, room: room, kind: "group",
                sequence: 1, revision: 1, lastEventAt: now, createdAt: now)
            try await insertSummaryFixtureMembership(on: sql, room: room, user: actor,
                joined: 1, left: nil)
            try await insertSummaryFixtureMessage(on: sql, room: room, message: message,
                sender: actor, roomSequence: 1, timelineSequence: 1, text: "blocked",
                createdAt: now, storage: .roomEvent, revision: nil)
            try await sql.raw("""
                INSERT INTO im_v2.content_review_jobs
                    (message_id, room_id, expected_content_revision, state, created_at)
                VALUES (\(bind: message), \(bind: room), 1, 'pending', \(bind: now))
                """).run()
            let invocation = MaintenanceSafetyInvocation()
            let safety = V2RoomContentReviewSafetyApplicator { request, deadline in
                await invocation.record(request, deadline: deadline)
                return .administration(.failure(.moderation(.roomNotFound)))
            }
            let worker = try V2ContentReviewWorker(
                store: PostgresV2ContentReviewStore(database: database),
                reviewer: V2ConfiguredContentReviewer(violatingTerms: ["blocked"]),
                moderation: safety, now: { now })
            let report = try await worker.runOnce(limit: 1)
            #expect(report.claimedCount == 1 && report.resolvedCount == 0 && report.releasedCount == 1)
            #expect(await invocation.appliedMessageID() == .init(uuid: message))
            #expect(await invocation.usedFutureDeadline())
            let row = try #require(try await sql.raw("""
                SELECT state, decision, completed_at IS NULL AS incomplete
                FROM im_v2.content_review_jobs WHERE message_id = \(bind: message)
                """).first(decoding: MaintenanceReviewJobRow.self))
            #expect(row.state == "pending" && row.decision == "violation" && row.incomplete)
            #expect(try await maintenanceCount(sql, "im_v2.content_review_decisions") == 0)
        }
    }
}

private actor MaintenanceSafetyInvocation {
    private var messageID: MessageID?
    private var deadlineWasFuture = false
    func record(_ request: V2RoomRequest, deadline: ContinuousClock.Instant) {
        if case .administration(.trustedSafety(let command)) = request {
            messageID = command.messageID
        }
        deadlineWasFuture = deadline > .now
    }
    func appliedMessageID() -> MessageID? { messageID }
    func usedFutureDeadline() -> Bool { deadlineWasFuture }
}

private actor MaintenanceGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        open = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private struct LocalMaintenanceInvoker: V2RoomMaintenanceInvoking {
    let executor: V2ActorRoomMaintenanceExecutor
    let token: V2RoomActivationToken
    func invoke(_ command: V2RoomMaintenanceCommand,
                deadline: ContinuousClock.Instant) async throws -> V2RoomMaintenanceResult {
        guard deadline > .now else { throw V2HostRoomRecoveryBatchError.deadlineExceeded }
        return try await executor.execute(command, token: token)
    }
}

private struct MaintenanceReviewJobRow: Decodable {
    let state: String
    let decision: String?
    let incomplete: Bool
}
private struct MaintenanceCountRow: Decodable { let value: Int64 }
private struct MaintenanceStringRow: Decodable { let value: String }
private struct MaintenanceSchemaRow: Decodable { let exists: Bool }
private struct MaintenanceLockWaitRow: Decodable { let waiting: Bool }

private func maintenanceWaitForDeleteLock(_ sql: any SQLDatabase) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        let waiting = try await sql.raw("""
            SELECT EXISTS (
                SELECT 1 FROM pg_stat_activity
                WHERE pid <> pg_backend_pid() AND wait_event_type = 'Lock'
                  AND query LIKE '%DELETE FROM im_v2.room_events%'
            ) AS waiting
            """).first(decoding: MaintenanceLockWaitRow.self)?.waiting == true
        if waiting { return }
        await Task.yield()
    }
    throw V2ControlPlaneHousekeepingError.corruptPersistenceState
}

private func maintenanceWaitForMaterializationLock(_ sql: any SQLDatabase) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        let waiting = try await sql.raw("""
            SELECT EXISTS (
                SELECT 1 FROM pg_stat_activity
                WHERE pid <> pg_backend_pid() AND wait_event_type = 'Lock'
                  AND query LIKE '%SET payload = CASE WHEN state.payload_storage%'
            ) AS waiting
            """).first(decoding: MaintenanceLockWaitRow.self)?.waiting == true
        if waiting { return }
        await Task.yield()
    }
    throw V2ControlPlaneHousekeepingError.corruptPersistenceState
}

private func maintenanceCount(_ sql: any SQLDatabase, _ table: String) async throws -> Int64 {
    try #require(try await sql.raw("SELECT count(*) AS value FROM \(unsafeRaw: table)")
        .first(decoding: MaintenanceCountRow.self)).value
}

private func maintenanceFloor(_ sql: any SQLDatabase, _ room: UUID) async throws -> Int64 {
    try #require(try await sql.raw("""
        SELECT log_trimmed_through_room_sequence AS value
        FROM im_v2.rooms WHERE room_id = \(bind: room)
        """).first(decoding: MaintenanceCountRow.self)).value
}

private func withMaintenanceDatabase(
    _ operation: (any Database, any SQLDatabase) async throws -> Void
) async throws {
    guard let url = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
          ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1" else { return }
    let resources = makeV2DatabaseTestResources()
    resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
    let database = resources.database(.psql)
    let sql = try #require(database as? any SQLDatabase)
    let schemaExists = try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists")
        .first(decoding: MaintenanceSchemaRow.self)?.exists ?? true
    guard !schemaExists else { throw V2ControlPlaneHousekeepingError.corruptPersistenceState }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: root.appending(path: "IMV2/sql/schema.sql"), encoding: .utf8)
    do {
        let executable = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }.joined(separator: "\n")
        for statement in postgresStatements(in: executable)
        where !statement.isEmpty && statement != "BEGIN" && statement != "COMMIT" {
            try await sql.raw("\(unsafeRaw: statement)").run()
        }
        try await operation(database, sql)
        try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
        try await resources.shutdown()
    } catch {
        try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
        try? await resources.shutdown()
        throw error
    }
}
