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

@Suite("Two-room send transaction successful COMMIT ACK loss", .serialized, .timeLimit(.minutes(3)))
struct V2SharedRoomSendCommitAckLossTests {
    @Test("one committed batch becomes unknown for both turns and replays exactly once",
          .enabled(if: ProcessInfo.processInfo.environment[
            "IMV2_SHARED_SEND_ACK_LOSS_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func committedTwoRoomBatchWithLostAck() async throws {
        let directURL = try #require(ProcessInfo.processInfo.environment[
            "IMV2_SHARED_SEND_ACK_LOSS_DATABASE_URL"])
        let components = try #require(URLComponents(string: directURL))
        let proxy = try await V2PostgresCommitAckLossProxy.start(
            backendHost: try #require(components.host), backendPort: components.port ?? 5432)
        let direct = makeV2DatabaseTestResources()
        let proxied = makeV2DatabaseTestResources()
        var schemaInstalled = false
        do {
            direct.databases.use(try .postgres(url: directURL, maxConnectionsPerEventLoop: 3),
                as: .psql, isDefault: true)
            var proxyComponents = components
            proxyComponents.host = "127.0.0.1"
            proxyComponents.port = proxy.port
            proxyComponents.queryItems = (proxyComponents.queryItems ?? []).filter {
                !["tlsmode", "sslmode", "tls", "ssl"].contains($0.name.lowercased())
            } + [URLQueryItem(name: "sslmode", value: "disable")]
            proxied.databases.use(try .postgres(
                url: try #require(proxyComponents.url?.absoluteString),
                maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            let database = direct.database(.psql)
            let sql = try #require(database as? any SQLDatabase)
            guard try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists")
                .first(decoding: ExistsRow.self)?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            let fixture = PostgresV2RoomWriteStoreIntegrationTests()
            schemaInstalled = true
            try await fixture.installSchema(on: sql)
            try await fixture.seedRoom(capacityClass: .large, on: sql)
            let secondRoom = RoomID(uuid: UUID())
            try await seedPeerRoom(secondRoom, on: sql)

            let leases = PostgresV2RoomActivationStore(database: database)
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let host = V2ActorHostIdentity(hostID: try .init("shared-ack-loss-host"),
                incarnationID: UUID())
            let firstToken = try await acquire(roomID, leases: leases, owner: owner, host: host)
            let secondToken = try await acquire(secondRoom, leases: leases, owner: owner, host: host)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try fixture.forwardImportTestProfile()
            let first = try preparedSend(token: firstToken, text: "first", profile: profile, now: now)
            let second = try preparedSend(token: secondToken, text: "second", profile: profile, now: now)

            // Credit reservations use the direct connection. The only COMMIT
            // passing through the one-shot proxy is the shared message write.
            let writer = try PostgresV2RoomWriteStore(database: proxied.database(.psql),
                strangerMessagePolicy: .init(maximumMessagesPerWindow: 10, window: 86_400),
                contentReviewMode: .disabled,
                shardAdmissionCommandCreditPool: .init(database: database, batchSize: 4))
            let batcher = V2SendMessageAdmissionBatcher(store: writer,
                configuration: .init(maximumBatchSize: 2, maximumDelay: .seconds(2),
                    maximumPendingRequests: 4), actorGrantedStore: writer)
            let adapter = V2ActorGrantedSendBatchAdapter(batcher: batcher)
            let deadline = ContinuousClock.now + .seconds(30)
            let firstTask = Task {
                try await adapter.execute([first], batchDeadline: deadline,
                    callDeadline: deadline)
            }
            // Phase barrier: the first granted turn is pending, so the second
            // fills this exact batch instead of racing two scalar transactions.
            let enqueueDeadline = ContinuousClock.now + .seconds(1)
            while await batcher.snapshot().pendingRequests != 1 {
                try #require(ContinuousClock.now < enqueueDeadline)
                await Task.yield()
            }
            let secondTask = Task {
                try await adapter.execute([second], batchDeadline: deadline,
                    callDeadline: deadline)
            }
            await #expect(throws: V2RoomCallFailure.outcomeUnknown) { try await firstTask.value }
            await #expect(throws: V2RoomCallFailure.outcomeUnknown) { try await secondTask.value }
            #expect(proxy.observedSuccessfulCommit)
            let snapshot = await batcher.snapshot()
            #expect(snapshot.atomicBatchAttempts == 1)
            #expect(snapshot.atomicBatchCommitted == 0)
            #expect(snapshot.atomicBatchFallbacks == 0)
            #expect(snapshot.singletonDispatches == 0)
            #expect(snapshot.completedBatches == 1)
            #expect(snapshot.pendingRequests == 0)

            for send in [first, second] {
                let operationID = try #require(send.request.command.clientMessageID.uuidValue)
                let room = try #require(send.token.roomID.uuidValue)
                #expect(try await rowCount("messages", room: room, operation: operationID,
                    sql: sql) == 1)
                #expect(try await rowCount("message_send_completions", room: room,
                    operation: operationID, sql: sql) == 1)
                #expect(try await compactEventCount(for: send, sql: sql) == 1)
            }
            // Large-group plain sends use the message row as their immutable
            // accepted event, rather than inserting a separate room_events row.
            #expect(try await fixture.count("im_v2.room_events", on: sql) == 0)

            // Quarantine precedes any successor SQL, even though PostgreSQL
            // really committed both writes. A separate client can recover the
            // exact durable result with the original operation identities.
            for token in [firstToken, secondToken] {
                let late = try preparedSend(token: token, text: "late", profile: profile, now: now)
                await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
                    try await adapter.execute([late], batchDeadline: deadline,
                        callDeadline: deadline)
                }
            }
            #expect(await batcher.snapshot().completedBatches == 1)
            #expect(try await fixture.count("im_v2.messages", on: sql) == 2)
            let replayStore = try PostgresV2RoomWriteStore(database: database,
                strangerMessagePolicy: .init(maximumMessagesPerWindow: 10, window: 86_400),
                contentReviewMode: .disabled).usingActivationScope(
                    .init(tokens: [firstToken, secondToken]))
            for send in [first, second] {
                let replay = try await replayStore.accept(command: send.request.command,
                    capacityProfile: profile,
                    identifiers: .init(messageID: .init(uuid: UUID()),
                        eventID: .init(uuid: UUID())), now: now.addingTimeInterval(1))
                guard case .idempotent(let recovered) = replay else {
                    throw V2SharedAckLossTestError.replayNotIdempotent
                }
                #expect(recovered.messageID == send.request.identifiers.messageID)
            }
            #expect(try await fixture.count("im_v2.messages", on: sql) == 2)
            #expect(try await fixture.count("im_v2.message_send_completions", on: sql) == 2)
            #expect(try await fixture.count("im_v2.room_events", on: sql) == 0)
            await adapter.retire(firstToken)
            await adapter.retire(secondToken)
            #expect(try await leases.release(token: firstToken))
            #expect(try await leases.release(token: secondToken))

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            schemaInstalled = false
            try await proxied.shutdown()
            try await direct.shutdown()
            try await proxy.shutdown()
        } catch {
            if schemaInstalled, let sql = direct.database(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await proxied.shutdown()
            try? await direct.shutdown()
            try? await proxy.shutdown()
            throw error
        }
    }

    private func acquire(_ room: RoomID, leases: PostgresV2RoomActivationStore,
                         owner: V2RoomDataOwner, host: V2ActorHostIdentity) async throws
        -> V2RoomActivationToken {
        guard case .acquired(let lease) = try await leases.acquire(roomID: room,
            owner: owner, host: host, duration: .init(30_000)) else {
            throw V2SharedAckLossTestError.activationUnavailable
        }
        return lease.token
    }

    private func preparedSend(token: V2RoomActivationToken, text: String,
                              profile: V2CapacityProfile, now: Date) throws -> V2PreparedActorSend {
        let command = try V2SendMessageCommand(roomID: token.roomID, senderUserID: senderID,
            clientMessageID: .init(uuid: UUID()), text: text,
            limits: .init(maxUTF8Bytes: 64))
        let request = V2RoomWriteRequest(command: command, capacityProfile: profile,
            identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())),
            now: now)
        return V2PreparedActorSend(token: token, request: request)
    }

    private func rowCount(_ table: String, room: UUID, operation: UUID,
                          sql: any SQLDatabase) async throws -> Int64 {
        try #require(try await sql.raw("""
            SELECT COUNT(*)::bigint AS value FROM im_v2.\(unsafeRaw: table)
            WHERE room_id = \(bind: room) AND sender_user_id = \(bind: senderUUID)
              AND client_message_id = \(bind: operation)
            """).first(decoding: CountRow.self)).value
    }

    private func compactEventCount(for send: V2PreparedActorSend,
                                   sql: any SQLDatabase) async throws -> Int64 {
        let room = try #require(send.token.roomID.uuidValue)
        let operation = try #require(send.request.command.clientMessageID.uuidValue)
        let event = try #require(send.request.identifiers.eventID.uuidValue)
        return try #require(try await sql.raw("""
            SELECT COUNT(*)::bigint AS value FROM im_v2.messages
            WHERE room_id = \(bind: room) AND sender_user_id = \(bind: senderUUID)
              AND client_message_id = \(bind: operation)
              AND accepted_event_storage = 'message_row'
              AND accepted_event_id = \(bind: event)
              AND room_sequence = 1 AND timeline_sequence = 1
            """).first(decoding: CountRow.self)).value
    }

    private func seedPeerRoom(_ room: RoomID, on sql: any SQLDatabase) async throws {
        let id = try #require(room.uuidValue)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        try await sql.raw("INSERT INTO im_v2.rooms (room_id,room_shard_id,capacity_profile_id,capacity_class) VALUES (\(bind: id),'room-a','standard','large')").run()
        try await sql.raw("INSERT INTO im_v2.room_owner_routes (room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES (\(bind: id),'room-a',0,\(bind: now),\(bind: now))").run()
        try await sql.raw("INSERT INTO im_v2.group_rooms (room_id,owner_user_id,title,created_at) VALUES (\(bind: id),\(bind: senderUUID),'Second batch room',\(bind: now))").run()
        try await sql.raw("INSERT INTO im_v2.room_admission (room_id,eligible_member_count,command_window_limit,shard_lease_id,shard_lease_generation) VALUES (\(bind: id),3,10,\(bind: leaseUUID),1)").run()
        for member in [senderUUID, memberTwoUUID, memberThreeUUID] {
            try await sql.raw("INSERT INTO im_v2.room_memberships (room_id,user_id,joined_revision) VALUES (\(bind: id),\(bind: member),0)").run()
        }
    }
}

private enum V2SharedAckLossTestError: Error {
    case activationUnavailable
    case replayNotIdempotent
}
