import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing

/// The proxy only sees the business writer. Lease acquire, concrete restore,
/// credit refill, and the phase-barrier connection use the direct database.
@Suite("Two Host turns share a committed transaction whose ACK is lost", .serialized,
       .timeLimit(.minutes(4)))
struct V2RoomHostSharedSendCommitAckLossTests {
    @Test("both executing turns become unknown, queued turns stop, and new epochs replay once",
          .enabled(if: ProcessInfo.processInfo.environment[
            "IMV2_ACTOR_HOST_SHARED_ACK_LOSS_DATABASE_IS_DISPOSABLE"] == "1"))
    func twoRoomsOneUnknownCommit() async throws {
        let directURL = try #require(ProcessInfo.processInfo.environment[
            "IMV2_ACTOR_HOST_SHARED_ACK_LOSS_DATABASE_URL"])
        let components = try #require(URLComponents(string: directURL))
        let proxy = try await V2PostgresCommitAckLossProxy.start(
            backendHost: try #require(components.host), backendPort: components.port ?? 5432)
        let direct = makeV2DatabaseTestResources()
        let proxied = makeV2DatabaseTestResources()
        var schemaInstalled = false
        var old: HostSharedAckHosted?
        var successor: HostSharedAckHosted?
        var locker: Task<Void, any Error>?
        let lockGate = HostSharedAckGate()
        do {
            direct.databases.use(try .postgres(url: directURL, maxConnectionsPerEventLoop: 8),
                as: .psql, isDefault: true)
            var proxyURL = components
            proxyURL.host = "127.0.0.1"
            proxyURL.port = proxy.port
            proxyURL.queryItems = (proxyURL.queryItems ?? []).filter {
                !["tlsmode", "sslmode", "tls", "ssl"].contains($0.name.lowercased())
            } + [URLQueryItem(name: "sslmode", value: "disable")]
            proxied.databases.use(try .postgres(
                url: try #require(proxyURL.url?.absoluteString),
                maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            let database = direct.database(.psql)
            let sql = try #require(database as? any SQLDatabase)
            guard try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS value")
                .first(decoding: HostSharedAckBoolRow.self)?.value == false else {
                throw HostSharedAckFailure.schemaAlreadyExists
            }
            let fixture = PostgresV2RoomWriteStoreIntegrationTests()
            schemaInstalled = true
            try await fixture.installSchema(on: sql)
            try await fixture.seedRoom(capacityClass: .large, on: sql)
            let secondRoom = RoomID(uuid: UUID())
            try await hostSharedAckSeedPeerRoom(secondRoom, sql: sql)
            // Concrete restore requires the current creation invariant; the
            // older generic write fixture seeds membership generation zero.
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 1").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET joined_revision = 1").run()

            let leases = PostgresV2RoomActivationStore(database: database)
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let runtime = try V2RoomRuntimeConfiguration(maximumActiveRooms: 2,
                maximumConcurrentRestores: 1, maximumQueuedCommandsPerRoom: 2,
                maximumQueuedCommandsPerHost: 4, maximumCommandsPerTurn: 1,
                maximumConcurrentReservations: 2, batchWaitMilliseconds: 4_000)
            let firstHost = try hostSharedAckHost(database: database,
                writeDatabase: proxied.database(.psql), fixture: fixture, leases: leases,
                configuration: runtime)
            old = firstHost
            await firstHost.host.start()
            let firstToken = try await hostSharedAckActivate(firstHost.host, room: roomID, owner: owner)
            let secondToken = try await hostSharedAckActivate(firstHost.host, room: secondRoom, owner: owner)

            // The trigger blocks the first INSERT within the shared transaction.
            // Both original turns have left their room lanes; successors can now
            // be proved queued before the successful COMMIT loses its ACK.
            try await sql.raw("""
                CREATE FUNCTION im_v2.test_block_shared_ack_insert() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    PERFORM pg_advisory_xact_lock(9240313);
                    RETURN NEW;
                END $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER test_block_shared_ack_insert BEFORE INSERT ON im_v2.messages
                FOR EACH ROW EXECUTE FUNCTION im_v2.test_block_shared_ack_insert()
                """).run()
            let advisoryKey: Int64 = 9_240_313
            locker = Task {
                try await database.transaction { transaction in
                    let tx = try #require(transaction as? any SQLDatabase)
                    try await tx.raw("SELECT pg_advisory_xact_lock(\(bind: advisoryKey))").run()
                    await lockGate.hold()
                }
            }
            try await lockGate.waitUntilHeld()

            let firstID = UUID(), secondID = UUID()
            let queuedFirstID = UUID(), queuedSecondID = UUID()
            let firstRequest = try hostSharedAckSend(room: roomID, operation: firstID, text: "first")
            let secondRequest = try hostSharedAckSend(room: secondRoom, operation: secondID, text: "second")
            let deadline = ContinuousClock.now + .seconds(25)
            let first = Task {
                try await firstHost.host.invoke(token: firstToken,
                    encodedRequest: firstRequest, deadline: deadline)
            }
            try await hostSharedAckWaitUntil {
                await firstHost.batcher.snapshot().pendingRequests == 1
            }
            let second = Task {
                try await firstHost.host.invoke(token: secondToken,
                    encodedRequest: secondRequest, deadline: deadline)
            }
            try await hostSharedAckWaitUntil {
                let batch = await firstHost.batcher.snapshot()
                guard batch.inFlightBatches == 1 else { return false }
                return try await hostSharedAckAdvisoryWait(sql: sql)
            }
            let queuedFirst = Task {
                try await firstHost.host.invoke(token: firstToken,
                    encodedRequest: try hostSharedAckSend(room: roomID,
                        operation: queuedFirstID, text: "queued first"), deadline: deadline)
            }
            let queuedSecond = Task {
                try await firstHost.host.invoke(token: secondToken,
                    encodedRequest: try hostSharedAckSend(room: secondRoom,
                        operation: queuedSecondID, text: "queued second"), deadline: deadline)
            }
            try await hostSharedAckWaitUntil { await firstHost.budget.snapshot().commandCount == 4 }
            #expect(try await hostSharedAckCount(sql, table: "messages", room: roomID,
                operation: firstID) == 0)
            #expect(try await hostSharedAckCount(sql, table: "messages", room: secondRoom,
                operation: secondID) == 0)
            await lockGate.open()
            try await locker?.value
            locker = nil

            await hostSharedAckExpect(.outcomeUnknown, first)
            await hostSharedAckExpect(.outcomeUnknown, second)
            await hostSharedAckExpect(.notAccepted(.leaseLost), queuedFirst)
            await hostSharedAckExpect(.notAccepted(.leaseLost), queuedSecond)
            #expect(proxy.observedSuccessfulCommit)
            let batch = await firstHost.batcher.snapshot()
            #expect(batch.atomicBatchAttempts == 1)
            #expect(batch.atomicBatchFallbacks == 0)
            #expect(batch.atomicBatchCommitted == 0)
            #expect(batch.singletonDispatches == 0)
            #expect(batch.completedBatches == 1)
            #expect(batch.pendingRequests == 0 && batch.inFlightBatches == 0)

            for (room, operation) in [(roomID, firstID), (secondRoom, secondID)] {
                #expect(try await hostSharedAckCount(sql, table: "messages", room: room,
                    operation: operation) == 1)
                #expect(try await hostSharedAckCount(sql, table: "message_send_completions", room: room,
                    operation: operation) == 1)
            }
            for (room, operation) in [(roomID, queuedFirstID), (secondRoom, queuedSecondID)] {
                #expect(try await hostSharedAckCount(sql, table: "messages", room: room,
                    operation: operation) == 0)
                #expect(try await hostSharedAckCount(sql, table: "message_send_completions", room: room,
                    operation: operation) == 0)
            }
            try await hostSharedAckWaitUntil {
                guard await firstHost.host.readyTokens().isEmpty else { return false }
                guard try await leases.locate(roomID: roomID, owner: owner) == nil else { return false }
                guard try await leases.locate(roomID: secondRoom, owner: owner) == nil else { return false }
                return await firstHost.budget.snapshot().commandCount == 0
            }
            let lateFirstID = UUID(), lateSecondID = UUID()
            await hostSharedAckExpectRetired(Task {
                try await firstHost.host.invoke(token: firstToken,
                    encodedRequest: try hostSharedAckSend(room: roomID,
                        operation: lateFirstID, text: "late first"), deadline: .now + .seconds(5))
            })
            await hostSharedAckExpectRetired(Task {
                try await firstHost.host.invoke(token: secondToken,
                    encodedRequest: try hostSharedAckSend(room: secondRoom,
                        operation: lateSecondID, text: "late second"), deadline: .now + .seconds(5))
            })
            #expect(try await hostSharedAckCount(sql, table: "messages", room: roomID,
                operation: lateFirstID) == 0)
            #expect(try await hostSharedAckCount(sql, table: "messages", room: secondRoom,
                operation: lateSecondID) == 0)
            #expect((await firstHost.host.stop(deadline: .now + .seconds(5))).completed)

            // A new process incarnation reacquires both rooms. Its concrete
            // Factory returns the durable original receipt, not a new message.
            let nextHost = try hostSharedAckHost(database: database, writeDatabase: database,
                fixture: fixture, leases: leases, configuration: runtime)
            successor = nextHost
            await nextHost.host.start()
            let nextFirst = try await hostSharedAckActivate(nextHost.host, room: roomID, owner: owner)
            let nextSecond = try await hostSharedAckActivate(nextHost.host, room: secondRoom, owner: owner)
            #expect(nextFirst.activationEpoch > firstToken.activationEpoch)
            #expect(nextSecond.activationEpoch > secondToken.activationEpoch)
            #expect(nextFirst.host.incarnationID != firstToken.host.incarnationID)
            for (token, request, room, operation) in [
                (nextFirst, firstRequest, roomID, firstID),
                (nextSecond, secondRequest, secondRoom, secondID),
            ] {
                let response = try await nextHost.host.invoke(token: token,
                    encodedRequest: request, deadline: .now + .seconds(10))
                guard case .messaging(.send(.idempotent(let receipt))) = response else {
                    throw HostSharedAckFailure.replayNotIdempotent
                }
                let persisted = try await hostSharedAckMessageID(sql, room: room, operation: operation)
                #expect(receipt.messageID.uuidValue == persisted)
            }
            #expect(try await fixture.count("im_v2.messages", on: sql) == 2)
            #expect(try await fixture.count("im_v2.message_send_completions", on: sql) == 2)
            for (room, operation) in [(roomID, queuedFirstID), (secondRoom, queuedSecondID)] {
                #expect(try await hostSharedAckCount(sql, table: "messages", room: room,
                    operation: operation) == 0)
            }
            #expect((await nextHost.host.stop(deadline: .now + .seconds(5))).completed)
            #expect(await nextHost.budget.snapshot().commandCount == 0)
            successor = nil
            old = nil

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            schemaInstalled = false
            try await proxied.shutdown()
            try await direct.shutdown()
            try await proxy.shutdown()
        } catch {
            await lockGate.open()
            _ = try? await locker?.value
            if let successor { _ = await successor.host.stop(deadline: .now + .seconds(5)) }
            if let old { _ = await old.host.stop(deadline: .now + .seconds(5)) }
            if schemaInstalled, let sql = direct.database(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await proxied.shutdown()
            try? await direct.shutdown()
            try? await proxy.shutdown()
            throw error
        }
    }
}

private struct HostSharedAckHosted: Sendable {
    let host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>
    let budget: V2RoomCommandBudget
    let batcher: V2SendMessageAdmissionBatcher
}

private func hostSharedAckHost(database: any Database, writeDatabase: any Database,
    fixture: PostgresV2RoomWriteStoreIntegrationTests, leases: PostgresV2RoomActivationStore,
    configuration: V2RoomRuntimeConfiguration) throws -> HostSharedAckHosted {
    let writes = try PostgresV2RoomWriteStore(database: writeDatabase,
        strangerMessagePolicy: .init(maximumMessagesPerWindow: 10, window: 86_400),
        contentReviewMode: .disabled,
        shardAdmissionCommandCreditPool: .init(database: database, batchSize: 4))
    let batcher = V2SendMessageAdmissionBatcher(store: writes,
        configuration: .init(maximumBatchSize: 2, maximumDelay: .seconds(5),
            maximumPendingRequests: 4), actorGrantedStore: writes)
    let resources = try V2RoomServerOwnerResources(database: database, writes: writes,
        sendBatcher: batcher,
        membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: database),
        invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: database),
        receiptShadowForwarder: HostSharedAckShadow(),
        capacityProfile: fixture.forwardImportTestProfile(),
        messageLimits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
        contentReviewMode: .disabled, queryBatchConfiguration: .init())
    let factory = try V2RoomServerActivationFactory(owners: ["room-a": resources],
        safetyActorUserID: senderID).runtimeFactory()
    let budget = V2RoomCommandBudget(configuration: configuration)
    let identity = V2ActorHostIdentity(hostID: try .init("shared-ack-host"), incarnationID: UUID())
    return .init(host: .init(identity: identity, leaseStore: leases,
        configuration: configuration, budget: budget,
        classify: { $0.canShareSendTurn ? .send : .barrier }, factory: factory),
        budget: budget, batcher: batcher)
}

private func hostSharedAckActivate(_ host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>,
    room: RoomID, owner: V2RoomDataOwner) async throws -> V2RoomActivationToken {
    guard case .ready(let token) = try await host.activate(roomID: room, owner: owner,
        deadline: .now + .seconds(5)) else { throw HostSharedAckFailure.activationUnavailable }
    return token
}

private func hostSharedAckSend(room: RoomID, operation: UUID, text: String) throws -> Data {
    try JSONEncoder().encode(V2RoomRequest.messaging(.send(.init(
        roomID: room, actorUserID: senderID, clientMessageID: .init(uuid: operation),
        text: text, media: [], mentions: [], entities: [], replyTo: nil))))
}

private func hostSharedAckSeedPeerRoom(_ room: RoomID, sql: any SQLDatabase) async throws {
    let id = try #require(room.uuidValue)
    let at = Date(timeIntervalSince1970: 1_750_000_000)
    try await sql.raw("""
        INSERT INTO im_v2.rooms (room_id,room_shard_id,capacity_profile_id,capacity_class)
        VALUES (\(bind: id),'room-a','standard','large')
        """).run()
    try await sql.raw("""
        INSERT INTO im_v2.room_owner_routes (room_id,room_shard_id,route_epoch,created_at,updated_at)
        VALUES (\(bind: id),'room-a',0,\(bind: at),\(bind: at))
        """).run()
    try await sql.raw("""
        INSERT INTO im_v2.group_rooms (room_id,owner_user_id,title,created_at)
        VALUES (\(bind: id),\(bind: senderUUID),'Second shared room',\(bind: at))
        """).run()
    try await sql.raw("""
        INSERT INTO im_v2.room_admission
            (room_id,eligible_member_count,command_window_limit,shard_lease_id,shard_lease_generation)
        VALUES (\(bind: id),3,10,\(bind: leaseUUID),1)
        """).run()
    for member in [senderUUID, memberTwoUUID, memberThreeUUID] {
        try await sql.raw("""
            INSERT INTO im_v2.room_memberships (room_id,user_id,joined_revision)
            VALUES (\(bind: id),\(bind: member),0)
            """).run()
    }
}

private func hostSharedAckCount(_ sql: any SQLDatabase, table: String,
    room: RoomID, operation: UUID) async throws -> Int64 {
    let roomUUID = try #require(room.uuidValue)
    return try #require(try await sql.raw("""
        SELECT COUNT(*)::bigint AS value FROM im_v2.\(unsafeRaw: table)
        WHERE room_id = \(bind: roomUUID) AND sender_user_id = \(bind: senderUUID)
          AND client_message_id = \(bind: operation)
        """).first(decoding: HostSharedAckCountRow.self)).value
}

private func hostSharedAckMessageID(_ sql: any SQLDatabase,
    room: RoomID, operation: UUID) async throws -> UUID {
    let roomUUID = try #require(room.uuidValue)
    return try #require(try await sql.raw("""
        SELECT message_id AS value FROM im_v2.message_send_completions
        WHERE room_id = \(bind: roomUUID) AND sender_user_id = \(bind: senderUUID)
          AND client_message_id = \(bind: operation)
        """).first(decoding: HostSharedAckUUIDRow.self)).value
}

private func hostSharedAckAdvisoryWait(sql: any SQLDatabase) async throws -> Bool {
    try await sql.raw("""
        SELECT EXISTS (SELECT 1 FROM pg_locks AS waiting
            WHERE waiting.locktype = 'advisory' AND NOT waiting.granted
              AND waiting.objid = 9240313
              AND cardinality(pg_blocking_pids(waiting.pid)) > 0) AS value
        """).first(decoding: HostSharedAckBoolRow.self)?.value == true
}

private func hostSharedAckWaitUntil(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try !(await condition()) {
        guard ContinuousClock.now < deadline else { throw HostSharedAckFailure.phaseTimeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func hostSharedAckExpect<T: Sendable>(_ expected: V2RoomCallFailure,
    _ task: Task<T, any Error>) async {
    do { _ = try await task.value; Issue.record("unexpected success; expected \(expected)") }
    catch { #expect(error as? V2RoomCallFailure == expected) }
}

private func hostSharedAckExpectRetired<T: Sendable>(_ task: Task<T, any Error>) async {
    do { _ = try await task.value; Issue.record("retired token unexpectedly accepted") }
    catch {
        guard let failure = error as? V2RoomCallFailure,
              case .notAccepted(let reason) = failure else {
            Issue.record("retired token returned an ambiguous or non-runtime failure: \(error)")
            return
        }
        #expect([.staleActivation, .retired, .leaseLost].contains(reason))
    }
}

private actor HostSharedAckGate {
    private var held = false
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        held = true
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilHeld() async throws {
        try await hostSharedAckWaitUntil { await self.held }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private struct HostSharedAckShadow: V2UserShardProjectionShadowing {
    func shadowIfForwarding(userID: UserID, sourceEventID: EventID,
        projectionKinds: Set<String>) async throws -> UInt64? { nil }
}

private struct HostSharedAckBoolRow: Decodable { let value: Bool }
private struct HostSharedAckCountRow: Decodable { let value: Int64 }
private struct HostSharedAckUUIDRow: Decodable { let value: UUID }
private enum HostSharedAckFailure: Error {
    case schemaAlreadyExists, activationUnavailable, replayNotIdempotent, phaseTimeout
}
