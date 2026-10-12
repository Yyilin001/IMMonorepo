@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2ActorCluster
import IMV2ActorRuntime
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("Room Host queue and shared-batch drain against PostgreSQL", .serialized,
       .timeLimit(.minutes(4)))
struct V2RoomHostPostgresOverloadDrainTests {
    @Test("hot room and host queue limits reject without SQL while a healthy room advances; drain keeps queued work fenced",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_HOST_OVERLOAD_DATABASE_IS_DISPOSABLE"] == "1"))
    func saturatedHotRoomAndHostDrain() async throws {
        try await withOverloadDatabase { database, sql, fixture in
            let healthy = RoomID(uuid: UUID()), excess = RoomID(uuid: UUID())
            try await overloadSeedRoom(healthy, sql: sql)
            try await overloadSeedRoom(excess, sql: sql)
            let identity = V2ActorHostIdentity(hostID: try .init("overload-drain-host"), incarnationID: UUID())
            try await withNativePlacementTestControl(host: identity, shardID: "room-a") { control in
            let placement = try await control.register(identity, shard: "room-a")
            let hosted = try overloadHost(database: database, fixture: fixture, identity: identity, placement: placement,
                configuration: overloadConfiguration())
            let host = hosted.host
            let hotLockerGate = OverloadGate(), healthyLockerGate = OverloadGate()
            let advisoryKey: Int64 = 9_240_211
            try await sql.raw("""
                CREATE FUNCTION im_v2.test_block_hot_insert() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    PERFORM pg_advisory_xact_lock(9240211);
                    RETURN NEW;
                END $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER test_block_hot_insert BEFORE INSERT ON im_v2.messages
                FOR EACH ROW EXECUTE FUNCTION im_v2.test_block_hot_insert()
                """).run()
            await host.start()
            var hotLocker: Task<Void, any Error>?
            var healthyLocker: Task<Void, any Error>?
            do {
                let hotToken = try await overloadActivate(host, room: roomID)
                let healthyToken = try await overloadActivate(host, room: healthy)
                let excessToken = try await overloadActivate(host, room: excess)
                hotLocker = Task {
                    try await database.transaction { transaction in
                        let tx = try #require(transaction as? any SQLDatabase)
                        try await tx.raw("SELECT pg_advisory_xact_lock(\(bind: advisoryKey))").run()
                        await hotLockerGate.hold()
                    }
                }
                healthyLocker = Task {
                    try await database.transaction { transaction in
                        let tx = try #require(transaction as? any SQLDatabase)
                        try await tx.raw("""
                            SELECT room_id FROM im_v2.rooms WHERE room_id = \(bind: healthy.uuidValue!)
                            FOR UPDATE
                            """).run()
                        await healthyLockerGate.hold()
                    }
                }
                try await hotLockerGate.waitUntilHeld()
                try await healthyLockerGate.waitUntilHeld()
                let firstID = UUID(), secondID = UUID(), rejectedID = UUID()
                let first = Task {
                    try await host.invoke(token: hotToken,
                        request: try overloadSendBytes(room: roomID, operation: firstID),
                        deadline: .now + .seconds(12))
                }
                try await overloadWaitUntil {
                    try await overloadAdvisoryWait(sql: sql)
                }
                let second = Task {
                    try await host.invoke(token: hotToken,
                        request: try overloadSendBytes(room: roomID, operation: secondID),
                        deadline: .now + .seconds(12))
                }
                try await overloadWaitUntil { await hosted.budget.snapshot().commandCount == 2 }
                // The host still has one free permit. This rejection must be
                // the per-room limit, independently of the later host limit.
                await overloadExpectFailure(.notAccepted(.overloaded), Task {
                    try await host.invoke(token: hotToken,
                        request: try overloadSendBytes(room: roomID, operation: rejectedID),
                        deadline: .now + .seconds(5))
                })
                #expect(try await overloadCompletionCount(sql, room: roomID, operation: rejectedID) == 0)
                #expect(await hosted.budget.snapshot().commandCount == 2)
                let healthyCall = Task {
                    try await host.invoke(token: healthyToken,
                        request: try overloadRecoveryBytes(room: healthy),
                        deadline: .now + .seconds(12))
                }
                try await overloadWaitUntil { await hosted.budget.snapshot().commandCount == 3 }
                // A distinct room has available room-local capacity here; its
                // rejection can only come from the host-wide three-call cap.
                await overloadExpectFailure(.notAccepted(.overloaded), Task {
                    try await host.invoke(token: excessToken,
                        request: try overloadRecoveryBytes(room: excess),
                        deadline: .now + .seconds(5))
                })
                #expect(await hosted.budget.snapshot().commandCount == 3)

                // The healthy room completes through its real executor while
                // the hot room's fenced INSERT is still blocked in PostgreSQL.
                await healthyLockerGate.open()
                try await healthyLocker?.value
                guard case .recovery(.state(.state(let state))) = try await healthyCall.value else {
                    throw OverloadFailure.unexpectedResult
                }
                #expect(state.roomID == healthy)
                #expect(try await overloadAdvisoryWait(sql: sql))
                #expect(await hosted.budget.snapshot().commandCount == 2)

                let drainedEarly = await host.drain(deadline: .now + .milliseconds(60))
                #expect(!drainedEarly.completed)
                #expect(try await overloadCommittedOwner(control, token: hotToken))
                await overloadExpectFailure(.notAccepted(.staleActivation), Task {
                    try await host.invoke(token: hotToken,
                        request: try overloadSendBytes(room: roomID, operation: UUID()),
                        deadline: .now + .seconds(5))
                })
                await hotLockerGate.open()
                try await hotLocker?.value
                try overloadRequireAccepted(try await first.value)
                try overloadRequireAccepted(try await second.value)
                #expect(try await overloadCompletionCount(sql, room: roomID, operation: firstID) == 1)
                #expect(try await overloadCompletionCount(sql, room: roomID, operation: secondID) == 1)
                #expect(try await overloadCompletionCount(sql, room: roomID, operation: rejectedID) == 0)
                #expect((await host.drain(deadline: .now + .seconds(5))).completed)
                try await overloadAssertReleased(hosted)
            } catch {
                await healthyLockerGate.open()
                await hotLockerGate.open()
                _ = try? await healthyLocker?.value
                _ = try? await hotLocker?.value
                try await hosted.stop()
                throw error
            }
            }
        }
    }

    @Test("drain retains both leases until both typed scalar sends commit their permanent proofs",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_HOST_OVERLOAD_DATABASE_IS_DISPOSABLE"] == "1"))
    func pendingSharedBatchDrainsBeforeLeaseRelease() async throws {
        try await withOverloadDatabase(capacityClass: .large) { database, sql, fixture in
            let secondRoom = RoomID(uuid: UUID())
            try await overloadSeedRoom(secondRoom, capacityClass: .large, sql: sql)
            let identity = V2ActorHostIdentity(hostID: try .init("overload-drain-host"), incarnationID: UUID())
            try await withNativePlacementTestControl(host: identity, shardID: "room-a") { control in
            let placement = try await control.register(identity, shard: "room-a")
            let hosted = try overloadHost(database: database, fixture: fixture, identity: identity, placement: placement,
                configuration: overloadConfiguration(), writeCapacity: 2)
            let host = hosted.host
            let gate = OverloadGate()
            let advisoryKey: Int64 = 9_240_212
            try await sql.raw("""
                CREATE FUNCTION im_v2.test_block_scalar_insert() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN PERFORM pg_advisory_xact_lock(9240212); RETURN NEW; END $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER test_block_scalar_insert BEFORE INSERT ON im_v2.messages
                FOR EACH ROW EXECUTE FUNCTION im_v2.test_block_scalar_insert()
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
                let firstToken = try await overloadActivate(host, room: roomID)
                let secondToken = try await overloadActivate(host, room: secondRoom)
                let firstID = UUID(), secondID = UUID()
                let firstRequest = try overloadSendBytes(room: roomID, operation: firstID)
                let secondRequest = try overloadSendBytes(room: secondRoom, operation: secondID)
                let first = Task { try await host.invoke(token: firstToken,
                    request: firstRequest, deadline: .now + .seconds(8)) }
                let second = Task { try await host.invoke(token: secondToken,
                    request: secondRequest, deadline: .now + .seconds(8)) }
                try await overloadWaitUntil {
                    try await sql.raw("""
                        SELECT count(*)::bigint AS value FROM pg_stat_activity
                        WHERE datname = current_database() AND pid <> pg_backend_pid()
                          AND wait_event_type = 'Lock' AND wait_event = 'advisory'
                          AND cardinality(pg_blocking_pids(pid)) > 0
                        """).first(decoding: OverloadCountRow.self)?.value == 2
                }
                #expect(await hosted.budget.snapshot().commandCount == 2)
                #expect(try await overloadCompletionCount(sql, room: roomID, operation: firstID) == 0)
                #expect(try await overloadCompletionCount(sql, room: secondRoom, operation: secondID) == 0)
                #expect(!(await host.drain(deadline: .now + .milliseconds(60))).completed)
                #expect(try await overloadCommittedOwner(control, token: firstToken))
                #expect(try await overloadCommittedOwner(control, token: secondToken))
                await gate.open()
                try await locker.value
                try overloadRequireAccepted(try await first.value)
                try overloadRequireAccepted(try await second.value)
                #expect(try await overloadCompletionCount(sql, room: roomID, operation: firstID) == 1)
                #expect(try await overloadCompletionCount(sql, room: secondRoom, operation: secondID) == 1)
                let batch = await hosted.resources.sendOperationOwnerMetricsSnapshot()
                #expect(batch.retainedItems == 0 && batch.inFlightBatches == 0)
                #expect((await host.drain(deadline: .now + .seconds(5))).completed)
                try await overloadAssertReleased(hosted)
            } catch {
                await gate.open()
                _ = try? await locker.value
                try await hosted.stop()
                throw error
            }
            }
        }
    }

}

private struct OverloadHosted: Sendable {
    let host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>
    let budget: V2RoomCommandBudget
    let resources: V2RoomServerOwnerResources
    let placement: V2RoomActorPlacementRuntime

    func stop() async throws {
        let proof = try #require(await host.stop(deadline: .now + .seconds(30)).proof)
        try await placement.retireAfterDrain(proof, shards: ["room-a"])
        await resources.shutdownDurableSendOperations()
    }
}

private func overloadConfiguration(batchWaitMilliseconds: Int64 = 2) throws -> V2RoomRuntimeConfiguration {
    try .init(maximumActiveRooms: 3, maximumConcurrentRestores: 1,
        maximumQueuedCommandsPerRoom: 2, maximumQueuedCommandsPerHost: 3,
        maximumCommandsPerTurn: 1, maximumConcurrentReservations: 2,
        batchWaitMilliseconds: batchWaitMilliseconds)
}

private func overloadHost(database: any Database,
    fixture: PostgresV2RoomWriteStoreIntegrationTests,
    identity: V2ActorHostIdentity, placement: V2RoomActorPlacementRuntime,
    configuration: V2RoomRuntimeConfiguration, writeCapacity: Int = 1) throws -> OverloadHosted {
    let writes = PostgresV2RoomWriteStore(database: database,
        strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400),
        contentReviewMode: .disabled)
    let resources = try V2RoomServerOwnerResources(database: database, sendDatabase: try v2FixtureMessageWriteDatabase(database, capacity: writeCapacity), writes: writes,
        membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: database),
        invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: database),
        invitationSecretIssuer: try .init(rawKey: Data(repeating: 0x73, count: 32)),
        receiptProjectionDelivery: OverloadProjectionDelivery(),
        capacityProfile: fixture.forwardImportTestProfile(),
        messageLimits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
        contentReviewMode: .disabled, queryBatchConfiguration: .init())
    let factory = try V2RoomServerActivationFactory(owners: ["room-a": resources.usingFixturePolicyAuthorizations(endpoint: "room-a")],
        safetyActorUserID: senderID).runtimeFactory()
    let budget = V2RoomCommandBudget(configuration: configuration)
    return .init(host: .init(identity: identity, placement: placement,
        configuration: configuration, budget: budget,
        classify: { $0.canShareSendTurn ? .send : .barrier }, factory: factory),
        budget: budget, resources: resources, placement: placement)
}

private func overloadActivate(_ host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>,
    room: RoomID) async throws -> V2RoomActivationToken {
    guard case .ready(let token) = try await host.activate(roomID: room,
        owner: .init(shardID: "room-a", epoch: 0), deadline: .now + .seconds(5)) else {
        throw OverloadFailure.unexpectedResult
    }
    return token
}

private func overloadSendBytes(room: RoomID, operation: UUID) throws -> V2RoomRequest {
    try V2RoomRequest.messaging(.sendOperation(.init(command: .init(roomID: room,
        senderUserID: senderID, clientMessageID: .init(uuid: operation), text: "overload",
        media: [], mentions: [], entities: [], replyTo: nil, limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000) + 600_000)))
}

private func overloadRecoveryBytes(room: RoomID) throws -> V2RoomRequest {
    try V2RoomRequest.recovery(.init(roomID: room,
        actorUserID: senderID, kind: .state))
}

private func overloadRequireAccepted(_ response: V2RoomResponse) throws {
    guard case .messaging(.sendOperation(.receipt(let proof))) = response,
          case .accepted = proof.outcome else {
        throw OverloadFailure.unexpectedResult
    }
}

private func overloadExpectFailure<T: Sendable>(_ expected: V2RoomCallFailure,
    _ task: Task<T, any Error>) async {
    do { _ = try await task.value; Issue.record("unexpected success; expected \(expected)") }
    catch { #expect(error as? V2RoomCallFailure == expected) }
}

private func overloadWaitUntil(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try !(await condition()) {
        guard ContinuousClock.now < deadline else { throw OverloadFailure.phaseTimeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func overloadAdvisoryWait(sql: any SQLDatabase) async throws -> Bool {
    try await sql.raw("""
        SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid <> pg_backend_pid()
            AND wait_event_type = 'Lock' AND wait_event = 'advisory') AS value
        """).first(decoding: OverloadBoolRow.self)?.value == true
}

private func overloadCompletionCount(_ sql: any SQLDatabase, room: RoomID,
    operation: UUID) async throws -> Int64 {
    try #require(try await sql.raw("""
        SELECT COUNT(*)::bigint AS value FROM im_v2.message_send_completions
        WHERE room_id = \(bind: room.uuidValue!) AND sender_user_id = \(bind: senderUUID)
          AND client_message_id = \(bind: operation)
        """).first(decoding: OverloadCountRow.self)).value
}

private func overloadCommittedOwner(_ control: V2NativePlacementTestControl,
    token: V2RoomActivationToken) async throws -> Bool {
    let snapshot = try await control.snapshot()
    return snapshot.slots[0].owner.host == token.host && !snapshot.slots[0].retired
}

private func overloadAssertReleased(_ hosted: OverloadHosted) async throws {
    let snapshot = await hosted.budget.snapshot()
    #expect(snapshot.commandCount == 0 && snapshot.byteCount == 0 && snapshot.roomCount == 0)
    #expect(snapshot.peakCommandCount <= 3)
    let batch = await hosted.resources.sendOperationOwnerMetricsSnapshot()
    #expect(batch.retainedItems == 0 && batch.inFlightBatches == 0)
    #expect(await hosted.host.readyTokens().isEmpty)
    #expect(await hosted.host.snapshot().activeRooms == 0)
    #expect(await hosted.host.snapshot().retiringRooms == 0)
    try await hosted.stop()
}

private func overloadSeedRoom(_ room: RoomID,
    capacityClass: V2GroupCapacityClass = .standard,
    sql: any SQLDatabase) async throws {
    let uuid = try #require(room.uuidValue)
    let at = Date(timeIntervalSince1970: 1_750_000_000)
    try await sql.raw("""
        INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id, capacity_class)
        VALUES (\(bind: uuid), 'room-a', 'standard', \(bind: capacityClass.rawValue))
        """).run()
    try await sql.raw("""
        INSERT INTO im_v2.room_owner_routes
            (room_id, room_shard_id, route_epoch, created_at, updated_at)
        VALUES (\(bind: uuid), 'room-a', 0, \(bind: at), \(bind: at))
        """).run()
    try await sql.raw("""
        INSERT INTO im_v2.group_rooms (room_id, owner_user_id, title, created_at)
        VALUES (\(bind: uuid), \(bind: senderUUID), 'Overload fixture', \(bind: at))
        """).run()
    try await sql.raw("""
        INSERT INTO im_v2.room_admission
            (room_id, eligible_member_count, command_window_limit,
             shard_lease_id, shard_lease_generation)
        VALUES (\(bind: uuid), 3, 10, \(bind: leaseUUID), 1)
        """).run()
    try await sql.raw("""
        INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision)
        VALUES (\(bind: uuid), \(bind: senderUUID), 1),
               (\(bind: uuid), \(bind: memberTwoUUID), 1),
               (\(bind: uuid), \(bind: memberThreeUUID), 1)
        """).run()
    try await sql.raw("""
        UPDATE im_v2.rooms SET membership_revision = 1 WHERE room_id = \(bind: uuid)
        """).run()
}

private struct OverloadProjectionDelivery: V2UserShardProjectionDelivering {
    func deliverToCurrentShard(userID: UserID, sourceEventID: EventID,
        projectionKinds: Set<String>) async throws -> UInt64? { nil }
}

private actor OverloadGate {
    private var held = false
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        held = true
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitUntilHeld() async throws {
        try await overloadWaitUntil { await self.held }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private struct OverloadBoolRow: Decodable { let value: Bool }
private struct OverloadCountRow: Decodable { let value: Int64 }
private enum OverloadFailure: Error { case phaseTimeout, unexpectedResult, schemaAlreadyExists }

private func withOverloadDatabase(capacityClass: V2GroupCapacityClass = .standard,
    _ operation: (any Database, any SQLDatabase,
    PostgresV2RoomWriteStoreIntegrationTests) async throws -> Void) async throws {
    let url = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_HOST_OVERLOAD_DATABASE_URL"])
    let resources = makeV2DatabaseTestResources()
    var installed = false
    do {
        resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 8),
            as: .psql, isDefault: true)
        let database = resources.database(.psql)
        let sql = try #require(database as? any SQLDatabase)
        guard try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS value")
            .first(decoding: OverloadBoolRow.self)?.value == false else {
            throw OverloadFailure.schemaAlreadyExists
        }
        let fixture = PostgresV2RoomWriteStoreIntegrationTests()
        installed = true
        try await fixture.installSchema(on: sql)
        try await fixture.seedRoom(capacityClass: capacityClass, on: sql)
        try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 1").run()
        try await sql.raw("UPDATE im_v2.room_memberships SET joined_revision = 1").run()
        try await sql.raw("""
            UPDATE im_v2.shard_admission_pools
            SET valid_until = clock_timestamp() + INTERVAL '1 hour'
            """).run()
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
