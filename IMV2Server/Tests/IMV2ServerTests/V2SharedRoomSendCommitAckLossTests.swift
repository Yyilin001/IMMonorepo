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
import Synchronization
import Testing

@Suite("Independent room transaction successful COMMIT ACK loss", .serialized, .timeLimit(.minutes(3)))
struct V2SharedRoomSendCommitAckLossTests {
    @Test("a lost commit acknowledgement affects one room and both rooms recover exactly once",
          .enabled(if: ProcessInfo.processInfo.environment[
            "IMV2_SHARED_SEND_ACK_LOSS_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func independentRoomsWithLostAck() async throws {
        let directURL = try #require(ProcessInfo.processInfo.environment[
            "IMV2_SHARED_SEND_ACK_LOSS_DATABASE_URL"])
        let components = try #require(URLComponents(string: directURL))
        let proxy = try await V2PostgresCommitAckLossProxy.start(
            backendHost: try #require(components.host), backendPort: components.port ?? 5432, initiallyArmed: false)
        let direct = makeV2DatabaseTestResources()
        let proxied = makeV2DatabaseTestResources()
        var schemaInstalled = false
        let ownerExecutor = Mutex<V2DurableSendOperationOwnerBatcher?>(nil)
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

            try await withRoomActivation(database: database, roomID: roomID) { firstToken in
            try await withRoomActivation(database: database, roomID: secondRoom) { secondToken in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try fixture.forwardImportTestProfile()
            let first = try preparedSend(token: firstToken, text: "first", profile: profile, now: now)
            let second = try preparedSend(token: secondToken, text: "second", profile: profile, now: now)

            let policies = v2FixtureRoomPolicyAuthorizations(database: database)
            let writer = PostgresV2RoomWriteStore(database: proxied.database(.psql),
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400),
                contentReviewMode: .disabled).usingPolicyAuthorizations(policies)
            let operations = PostgresV2MessageSendOperationStore(database: proxied.database(.psql),
                writes: writer, clock: { now }, initializationDatabase: database)
                .observingOwnerTransactions { _, scalar, _ in if scalar { proxy.arm() } }
            let deadline = ContinuousClock.now + .seconds(30)
            let firstCommand = try V2MessageSendOperationCommand(command: first.request.command,
                firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            let secondCommand = try V2MessageSendOperationCommand(command: second.request.command,
                firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            let prepared = try await policies.prepareOwnerBatches(store: operations, requests: [
                .init(commands: [firstCommand], token: firstToken, deadline: deadline),
                .init(commands: [secondCommand], token: secondToken, deadline: deadline)
            ], now: { now })
            let firstHandle = try prepared[0].get()
            let secondHandle = try prepared[1].get()
            let identifiers = Mutex(try [first, second].flatMap { send in
                [try #require(send.request.identifiers.messageID.uuidValue),
                 try #require(send.request.identifiers.eventID.uuidValue)]
            })
            let dispatcher = V2DurableSendOperationOwnerBatcher(fixtureStore: operations, connectionCapacity: 1, capacityProfile: profile,
                identifiers: .init(makeUUID: { identifiers.withLock { $0.removeFirst() } }),
                now: { now }, configuration: .init(maximumPendingRequests: 4),
                maximumRetainedBytes: 16_384)
            ownerExecutor.withLock { $0 = dispatcher }
            do {
            await #expect(throws: V2RoomTransactionOutcomeUnknown.self) { try await dispatcher.execute(firstHandle) }
            #expect(proxy.observedSuccessfulCommit)
            // The same dispatcher can execute another room after returning the failed connection.
            let secondResults = try await dispatcher.execute(secondHandle)
            guard case .sendOperation(.receipt(let receipt))? = secondResults.first,
                  case .accepted = receipt.outcome else { throw V2SharedAckLossTestError.replayNotIdempotent }

            for send in [first, second] {
                let operationID = try #require(send.request.command.clientMessageID.uuidValue)
                let room = try #require(send.token.roomID.uuidValue)
                #expect(try await rowCount("messages", room: room, operation: operationID,
                    sql: sql) == 1)
                #expect(try await rowCount("message_send_completions", room: room,
                    operation: operationID, sql: sql) == 1)
                #expect(try await acceptedEventCount(for: send, sql: sql) == 1)
            }
            // The complex-message owner path persists one canonical event for each committed message.
            #expect(try await fixture.count("im_v2.room_events", on: sql) == 2)

            // Recover the exact durable result using the original identities on a fresh connection.
            let replayStore = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database), clock: { now })
            for (send, command) in zip([first, second], [firstCommand, secondCommand]) {
                let recovery = try await replayStore.recover(.init(identity: command.identity,
                    fingerprint: command.fingerprint, domainFingerprint: command.command.fingerprint), token: send.token)
                guard case .receipt(let recovered) = recovery,
                      case .accepted(let message) = recovered.outcome else {
                    throw V2SharedAckLossTestError.replayNotIdempotent
                }
                #expect(message.messageID == send.request.identifiers.messageID)
            }
            #expect(try await fixture.count("im_v2.messages", on: sql) == 2)
            #expect(try await fixture.count("im_v2.message_send_completions", on: sql) == 2)
            #expect(try await fixture.count("im_v2.room_events", on: sql) == 2)
            await dispatcher.shutdown()
            ownerExecutor.withLock { $0 = nil }
            } catch {
                await dispatcher.shutdown()
                ownerExecutor.withLock { $0 = nil }
                throw error
            }
            }
            }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            schemaInstalled = false
            try await proxied.shutdown()
            try await direct.shutdown()
            try await proxy.shutdown()
        } catch {
            await ownerExecutor.withLock { $0 }?.shutdown()
            if schemaInstalled, let sql = direct.database(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await proxied.shutdown()
            try? await direct.shutdown()
            try? await proxy.shutdown()
            throw error
        }
    }

    private func preparedSend(token: V2RoomActivationToken, text: String,
                              profile: V2CapacityProfile, now: Date) throws -> V2PreparedActorSend {
        let command = try V2SendMessageCommand(roomID: token.roomID, senderUserID: senderID,
            clientMessageID: .init(uuid: UUID()), text: text,
            mentions: [.user(.init(uuid: memberTwoUUID))],
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

    private func acceptedEventCount(for send: V2PreparedActorSend,
                                   sql: any SQLDatabase) async throws -> Int64 {
        let room = try #require(send.token.roomID.uuidValue)
        let event = try #require(send.request.identifiers.eventID.uuidValue)
        return try #require(try await sql.raw("""
            SELECT COUNT(*)::bigint AS value FROM im_v2.room_events
            WHERE room_id = \(bind: room) AND event_id = \(bind: event)
              AND room_sequence = 1
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
    case replayNotIdempotent
}
