import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing

@Suite("Room Host cancellation and maintenance takeover on PostgreSQL", .serialized,
       .timeLimit(.minutes(3)))
struct V2RoomHostPostgresCancellationMaintenanceTests {
    @Test("queued send cancellation never reaches SQL; cancellation after SQL admission retains fence and permit",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_CANCEL_MAINT_DATABASE_IS_DISPOSABLE"] == "1"))
    func queuedAndExecutingCancellation() async throws {
        try await withCancelMaintenanceDatabase { database, sql, fixture in
            let admission = cancelMaintenanceAdmission()
            let hosted = try cancelMaintenanceHost(database: database, fixture: fixture,
                leases: PostgresV2RoomActivationStore(database: database),
                name: "cancel-host", admission: admission)
            let host = hosted.host
            let leases = PostgresV2RoomActivationStore(database: database)
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let gate = CancelMaintenanceGate()
            let advisoryKey: Int64 = 9_240_010
            try await sql.raw("""
                CREATE FUNCTION im_v2.test_block_message_insert() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN PERFORM pg_advisory_xact_lock(9240010); RETURN NEW; END $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER test_block_message_insert BEFORE INSERT ON im_v2.messages
                FOR EACH ROW EXECUTE FUNCTION im_v2.test_block_message_insert()
                """).run()
            let locker = Task {
                try await database.transaction { transaction in
                    let tx = try #require(transaction as? any SQLDatabase)
                    try await tx.raw("SELECT pg_advisory_xact_lock(\(bind: advisoryKey))").run()
                    await gate.hold()
                }
            }
            await host.start()
            do {
                try await gate.waitUntilHeld()
                let token = try await cancelMaintenanceActivate(host: host)
                let firstID = UUID(), queuedID = UUID()
                let first = Task { try await host.invoke(token: token,
                    encodedRequest: try cancelMaintenanceSendBytes(operation: firstID, text: "first"),
                    deadline: .now + .seconds(15)) }
                try await cancelMaintenanceWaitUntil {
                    let waiting = try await cancelMaintenanceAdvisoryWait(sql: sql)
                    let snapshot = await admission.snapshot()
                    return waiting && snapshot.foregroundWrite.inFlight == 1
                }
                let queued = Task { try await host.invoke(token: token,
                    encodedRequest: try cancelMaintenanceSendBytes(operation: queuedID, text: "queued"),
                    deadline: .now + .seconds(15)) }
                try await cancelMaintenanceWaitUntil { await hosted.budget.snapshot().commandCount == 2 }
                queued.cancel()
                await cancelMaintenanceExpectFailure(.notAccepted(.cancelled), queued)
                #expect(try await cancelMaintenanceOperationCount(sql: sql, operation: queuedID) == 0)
                first.cancel()
                await cancelMaintenanceExpectFailure(.outcomeUnknown, first)
                #expect(await hosted.budget.snapshot().commandCount == 1)
                #expect((await admission.snapshot()).foregroundWrite.inFlight == 1)
                #expect(try await cancelMaintenanceLeaseEpoch(sql: sql) == token.activationEpoch.rawValue)
                #expect(!(await host.drain(deadline: .now + .milliseconds(40))).completed)
                #expect(try await cancelMaintenanceLeaseEpoch(sql: sql) == token.activationEpoch.rawValue)

                await gate.open()
                try await locker.value
                try await cancelMaintenanceWaitUntil {
                    let budget = await hosted.budget.snapshot()
                    let snapshot = await admission.snapshot()
                    return budget.commandCount == 0 && snapshot.foregroundWrite.inFlight == 0
                }
                #expect(try await cancelMaintenanceOperationCount(sql: sql, operation: firstID) == 1)
                #expect(try await cancelMaintenanceOperationCount(sql: sql, operation: queuedID) == 0)
                let original = try #require(try await sql.raw("""
                    SELECT message_id AS value FROM im_v2.message_send_completions
                    WHERE room_id = \(bind: roomUUID) AND sender_user_id = \(bind: senderUUID)
                      AND client_message_id = \(bind: firstID)
                    """).first(decoding: CancelMaintenanceUUIDRow.self)).value
                #expect((await host.stop(deadline: .now + .seconds(5))).completed)
                #expect(try await leases.locate(roomID: roomID, owner: owner) == nil)

                // Replaying on a fresh activation resolves the detached caller's
                // unknown result to the exact durable operation, not a second write.
                let successor = try cancelMaintenanceHost(database: database, fixture: fixture,
                    leases: leases, name: "cancel-successor", admission: admission)
                await successor.host.start()
                let fresh = try await cancelMaintenanceActivate(host: successor.host)
                #expect(fresh.activationEpoch.rawValue == token.activationEpoch.rawValue + 1)
                let replay = try await successor.host.invoke(token: fresh,
                    encodedRequest: cancelMaintenanceSendBytes(operation: firstID, text: "first"),
                    deadline: .now + .seconds(5))
                guard case .messaging(.send(.idempotent(let accepted))) = replay else {
                    throw CancelMaintenanceFailure.unexpectedResult
                }
                #expect(accepted.messageID.uuidValue == original)
                #expect(try await cancelMaintenanceOperationCount(sql: sql, operation: firstID) == 1)
                #expect((await successor.host.stop(deadline: .now + .seconds(5))).completed)
            } catch {
                await gate.open()
                _ = try? await locker.value
                _ = await host.stop(deadline: .now + .seconds(5))
                throw error
            }
        }
    }

    @Test("retention holds its complete activation fence until DELETE commits before another host takes over",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_CANCEL_MAINT_DATABASE_IS_DISPOSABLE"] == "1"))
    func retentionCannotOverlapSuccessor() async throws {
        try await withCancelMaintenanceDatabase { database, sql, fixture in
            let oldDate = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("""
                UPDATE im_v2.rooms SET room_sequence = 3, membership_revision = 1
                WHERE room_id = \(bind: roomUUID)
                """).run()
            try await sql.raw("UPDATE im_v2.room_memberships SET joined_revision = 1").run()
            for sequence in 1...3 {
                try await sql.raw("""
                    INSERT INTO im_v2.room_events
                        (event_id, room_id, room_sequence, event_type, actor_user_id,
                         payload, committed_membership_revision, created_at)
                    VALUES (\(bind: UUID()), \(bind: roomUUID), \(bind: Int64(sequence)),
                        'message.accepted', \(bind: senderUUID),
                        jsonb_build_object('event_type', 'message.accepted',
                            'room_id', \(bind: roomUUID.uuidString.lowercased()),
                            'message_id', \(bind: UUID().uuidString.lowercased()),
                            'message_revision', 1, 'is_withdrawn', false),
                        1, \(bind: oldDate))
                    """).run()
            }
            for user in [senderUUID, memberTwoUUID, memberThreeUUID] {
                try await sql.raw("""
                    INSERT INTO im_v2.room_read_receipts
                        (room_id, user_id, read_through_room_sequence, updated_at)
                    VALUES (\(bind: roomUUID), \(bind: user), 3, \(bind: oldDate))
                    """).run()
            }
            let gate = CancelMaintenanceGate()
            let advisoryKey: Int64 = 9_240_021
            try await sql.raw("""
                CREATE FUNCTION im_v2.test_block_retention_delete() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN PERFORM pg_advisory_xact_lock(9240021); RETURN OLD; END $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER test_block_retention_delete BEFORE DELETE ON im_v2.room_events
                FOR EACH ROW EXECUTE FUNCTION im_v2.test_block_retention_delete()
                """).run()
            let locker = Task {
                try await database.transaction { transaction in
                    let tx = try #require(transaction as? any SQLDatabase)
                    try await tx.raw("SELECT pg_advisory_xact_lock(\(bind: advisoryKey))").run()
                    await gate.hold()
                }
            }
            let leases = PostgresV2RoomActivationStore(database: database)
            let first = try cancelMaintenanceHost(database: database, fixture: fixture,
                leases: leases, name: "retention-first", admission: cancelMaintenanceAdmission(),
                now: { oldDate })
            let next = try cancelMaintenanceHost(database: database, fixture: fixture,
                leases: leases, name: "retention-next", admission: cancelMaintenanceAdmission(),
                now: { oldDate })
            await first.host.start()
            await next.host.start()
            do {
                try await gate.waitUntilHeld()
                let old = try await cancelMaintenanceActivate(host: first.host)
                let command = V2RoomRequest.maintenance(.trimLog(.init(roomID: roomID,
                    mode: .permanent, windowSeconds: 3_600)))
                let request = try JSONEncoder().encode(command)
                let trim = Task { try await first.host.invoke(token: old,
                    encodedRequest: request, deadline: .now + .seconds(15)) }
                try await cancelMaintenanceWaitUntil {
                    try await cancelMaintenanceAdvisoryWait(sql: sql)
                }
                #expect(try await cancelMaintenanceFloor(sql: sql) == 0)
                #expect(try await cancelMaintenanceRoomEventCount(sql: sql) == 3)
                let takeover = Task { try await next.host.activate(roomID: roomID,
                    owner: try .init(shardID: "room-a", epoch: 0), deadline: .now + .seconds(15)) }
                try await cancelMaintenanceWaitUntil {
                    try await cancelMaintenanceRoomLockWait(sql: sql)
                }
                #expect(try await cancelMaintenanceLeaseEpoch(sql: sql) == old.activationEpoch.rawValue)
                #expect(try await cancelMaintenanceFloor(sql: sql) == 0)
                #expect(try await cancelMaintenanceRoomEventCount(sql: sql) == 3)
                await gate.open()
                try await locker.value
                guard case .maintenance(.logTrimmed(let report)) = try await trim.value else {
                    throw CancelMaintenanceFailure.unexpectedResult
                }
                #expect(report.advancedFloor && report.deletedEvents == 2)
                guard case .occupied(let occupied) = try await takeover.value else {
                    throw CancelMaintenanceFailure.unexpectedResult
                }
                #expect(occupied.token == old)
                #expect(try await cancelMaintenanceFloor(sql: sql) == 3)
                #expect(try await cancelMaintenanceRoomEventCount(sql: sql) == 1)
                #expect((await first.host.stop(deadline: .now + .seconds(5))).completed)
                let fresh = try await cancelMaintenanceActivate(host: next.host)
                #expect(fresh.activationEpoch.rawValue == old.activationEpoch.rawValue + 1)
                await cancelMaintenanceExpectFailure(.notAccepted(.staleActivation), Task {
                    try await first.host.invoke(token: old, encodedRequest: request,
                        deadline: .now + .seconds(5))
                })
                #expect(try await leases.release(token: old) == false)
                await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                    _ = try await V2ActorRoomMaintenanceExecutor(database: database,
                        now: { oldDate }).execute(.trimLog(.init(roomID: roomID,
                            mode: .permanent, windowSeconds: 3_600)), token: old)
                }
                let freshResponse = try await next.host.invoke(token: fresh,
                    encodedRequest: request, deadline: .now + .seconds(5))
                guard case .maintenance(.logTrimmed(let noOp)) = freshResponse else {
                    throw CancelMaintenanceFailure.unexpectedResult
                }
                #expect(!noOp.advancedFloor && noOp.deletedEvents == 0)
                #expect((await next.host.stop(deadline: .now + .seconds(5))).completed)
            } catch {
                await gate.open()
                _ = try? await locker.value
                _ = await first.host.stop(deadline: .now + .seconds(5))
                _ = await next.host.stop(deadline: .now + .seconds(5))
                throw error
            }
        }
    }
}

private struct CancelMaintenanceHosted: Sendable {
    let host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>
    let budget: V2RoomCommandBudget
}

private func cancelMaintenanceHost(database: any Database,
    fixture: PostgresV2RoomWriteStoreIntegrationTests, leases: PostgresV2RoomActivationStore,
    name: String, admission: V2DatabaseWorkAdmissionController,
    now: @escaping @Sendable () -> Date = Date.init) throws -> CancelMaintenanceHosted {
    let configuration = try V2RoomRuntimeConfiguration(maximumActiveRooms: 2,
        maximumConcurrentRestores: 1, maximumPendingActivations: 2,
        maximumCommandsPerTurn: 1, maximumConcurrentReservations: 2)
    let budget = V2RoomCommandBudget(configuration: configuration)
    let writes = PostgresV2RoomWriteStore(database: database)
    let batcher = V2SendMessageAdmissionBatcher(store: writes,
        configuration: .init(maximumBatchSize: 1, maximumDelay: .milliseconds(2)),
        databaseWorkAdmission: admission, actorGrantedStore: writes)
    let resources = try V2RoomServerOwnerResources(database: database, writes: writes,
        sendBatcher: batcher,
        membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: database),
        invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: database),
        receiptShadowForwarder: CancelMaintenanceShadow(),
        capacityProfile: fixture.forwardImportTestProfile(),
        messageLimits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
        contentReviewMode: .disabled, queryBatchConfiguration: .init(),
        databaseWorkAdmission: admission)
    let factory = try V2RoomServerActivationFactory(owners: ["room-a": resources],
        safetyActorUserID: senderID, now: now).runtimeFactory()
    let identity = V2ActorHostIdentity(hostID: try .init(name), incarnationID: UUID())
    return .init(host: .init(identity: identity, leaseStore: leases,
        configuration: configuration, budget: budget,
        classify: { $0.canShareSendTurn ? .send : .barrier }, factory: factory),
        budget: budget)
}

private func cancelMaintenanceAdmission() -> V2DatabaseWorkAdmissionController {
    .init(policy: .init(maximumForegroundWriteInFlight: 1,
        maximumInteractiveReadInFlight: 1, maximumSyncInFlight: 1,
        maximumForegroundWriteQueued: 2, maximumInteractiveReadQueued: 2,
        maximumSyncQueued: 1, timeout: .seconds(2)))
}

private func cancelMaintenanceActivate(
    host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>) async throws -> V2RoomActivationToken {
    guard case .ready(let token) = try await host.activate(roomID: roomID,
        owner: .init(shardID: "room-a", epoch: 0), deadline: .now + .seconds(5)) else {
        throw CancelMaintenanceFailure.unexpectedResult
    }
    return token
}

private func cancelMaintenanceSendBytes(operation: UUID, text: String) throws -> Data {
    try JSONEncoder().encode(V2RoomRequest.messaging(.send(.init(roomID: roomID,
        actorUserID: senderID, clientMessageID: .init(uuid: operation), text: text,
        media: [], mentions: [], entities: [], replyTo: nil))))
}

private func cancelMaintenanceExpectFailure<T: Sendable>(_ expected: V2RoomCallFailure,
    _ task: Task<T, any Error>) async {
    do { _ = try await task.value; Issue.record("unexpected success; expected \(expected)") }
    catch { #expect(error as? V2RoomCallFailure == expected) }
}

private func cancelMaintenanceWaitUntil(
    _ condition: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try !(await condition()) {
        guard ContinuousClock.now < deadline else { throw CancelMaintenanceFailure.phaseTimeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private actor CancelMaintenanceGate {
    private var held = false
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        held = true
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitUntilHeld() async throws {
        try await cancelMaintenanceWaitUntil { await self.held }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private struct CancelMaintenanceShadow: V2UserShardProjectionShadowing {
    func shadowIfForwarding(userID: UserID, sourceEventID: EventID,
        projectionKinds: Set<String>) async throws -> UInt64? { nil }
}

private struct CancelMaintenanceBoolRow: Decodable { let value: Bool }
private struct CancelMaintenanceCountRow: Decodable { let value: Int64 }
private struct CancelMaintenanceUUIDRow: Decodable { let value: UUID }
private enum CancelMaintenanceFailure: Error { case phaseTimeout, unexpectedResult, schemaAlreadyExists }

private func cancelMaintenanceAdvisoryWait(sql: any SQLDatabase) async throws -> Bool {
    try await sql.raw("""
        SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid <> pg_backend_pid()
            AND wait_event_type = 'Lock' AND wait_event = 'advisory') AS value
        """).first(decoding: CancelMaintenanceBoolRow.self)?.value == true
}

private func cancelMaintenanceRoomLockWait(sql: any SQLDatabase) async throws -> Bool {
    try await sql.raw("""
        SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid <> pg_backend_pid()
            AND wait_event_type = 'Lock' AND query LIKE '%FROM im_v2.rooms%'
            AND query LIKE '%FOR NO KEY UPDATE%') AS value
        """).first(decoding: CancelMaintenanceBoolRow.self)?.value == true
}

private func cancelMaintenanceOperationCount(sql: any SQLDatabase, operation: UUID) async throws -> Int64 {
    try #require(try await sql.raw("""
        SELECT COUNT(*)::bigint AS value FROM im_v2.message_send_completions
        WHERE room_id = \(bind: roomUUID) AND sender_user_id = \(bind: senderUUID)
          AND client_message_id = \(bind: operation)
        """).first(decoding: CancelMaintenanceCountRow.self)).value
}

private func cancelMaintenanceFloor(sql: any SQLDatabase) async throws -> Int64 {
    try #require(try await sql.raw("""
        SELECT log_trimmed_through_room_sequence AS value FROM im_v2.rooms
        WHERE room_id = \(bind: roomUUID)
        """).first(decoding: CancelMaintenanceCountRow.self)).value
}

/// MVCC observation deliberately avoids the production owner's locking locate
/// operation while a fenced writer is paused inside its transaction.
private func cancelMaintenanceLeaseEpoch(sql: any SQLDatabase) async throws -> Int64 {
    try #require(try await sql.raw("""
        SELECT activation_epoch AS value FROM im_v2.room_activation_leases
        WHERE room_id = \(bind: roomUUID) AND expires_at > clock_timestamp()
        """).first(decoding: CancelMaintenanceCountRow.self)).value
}

private func cancelMaintenanceRoomEventCount(sql: any SQLDatabase) async throws -> Int64 {
    try #require(try await sql.raw("""
        SELECT COUNT(*)::bigint AS value FROM im_v2.room_events
        WHERE room_id = \(bind: roomUUID)
        """).first(decoding: CancelMaintenanceCountRow.self)).value
}

private func withCancelMaintenanceDatabase(_ operation: (any Database, any SQLDatabase,
    PostgresV2RoomWriteStoreIntegrationTests) async throws -> Void) async throws {
    let url = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_CANCEL_MAINT_DATABASE_URL"])
    let resources = makeV2DatabaseTestResources()
    var installed = false
    do {
        resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 6),
            as: .psql, isDefault: true)
        let database = resources.database(.psql)
        let sql = try #require(database as? any SQLDatabase)
        guard try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS value")
            .first(decoding: CancelMaintenanceBoolRow.self)?.value == false else {
            throw CancelMaintenanceFailure.schemaAlreadyExists
        }
        let fixture = PostgresV2RoomWriteStoreIntegrationTests()
        installed = true
        try await fixture.installSchema(on: sql)
        try await fixture.seedRoom(on: sql)
        try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until = clock_timestamp() + INTERVAL '1 hour'").run()
        try await operation(database, sql, fixture)
        try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
        installed = false
        try await resources.shutdown()
    } catch {
        if installed, let sql = resources.database(.psql) as? any SQLDatabase {
            try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
        }
        try? await resources.shutdown()
        throw error
    }
}
