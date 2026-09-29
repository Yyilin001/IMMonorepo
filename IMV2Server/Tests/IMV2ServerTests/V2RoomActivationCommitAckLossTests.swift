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

@Suite("Room activation successful COMMIT ACK loss", .serialized, .timeLimit(.minutes(2)))
struct V2RoomActivationCommitAckLossTests {
    @Test("a committed room send with a withheld COMMIT ACK is unknown and replays once",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_ACK_LOSS_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func committedSendWithLostAck() async throws {
        let directURL = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_ACK_LOSS_DATABASE_URL"])
        let components = try #require(URLComponents(string: directURL))
        let host = try #require(components.host)
        let port = components.port ?? 5432
        let proxy = try await V2PostgresCommitAckLossProxy.start(backendHost: host, backendPort: port)
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
            let proxyURL = try #require(proxyComponents.url?.absoluteString)
            proxied.databases.use(try .postgres(url: proxyURL, maxConnectionsPerEventLoop: 1),
                as: .psql, isDefault: true)
            let database = direct.database(.psql)
            let sql = try #require(database as? any SQLDatabase)
            guard try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists")
                .first(decoding: ExistsRow.self)?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            let fixture = PostgresV2RoomWriteStoreIntegrationTests()
            schemaInstalled = true
            try await fixture.installSchema(on: sql)
            try await fixture.seedRoom(on: sql)

            let leases = PostgresV2RoomActivationStore(database: database)
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let hostIdentity = V2ActorHostIdentity(hostID: try .init("ack-loss-host"),
                incarnationID: UUID())
            guard case .acquired(let lease) = try await leases.acquire(roomID: roomID,
                owner: owner, host: hostIdentity, duration: .init(30_000)) else {
                throw V2CommitAckLossTestError.activationUnavailable
            }
            let scope = try V2RoomActivationWriteScope(tokens: [lease.token])
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let operationID = UUID(), messageID = UUID(), eventID = UUID()
            let command = try V2SendMessageCommand(roomID: roomID, senderUserID: senderID,
                clientMessageID: .init(uuid: operationID), text: "committed with lost ACK",
                limits: .init(maxUTF8Bytes: 64))
            let profile = try fixture.forwardImportTestProfile()
            let identifiers = V2AcceptanceIdentifiers(messageID: .init(uuid: messageID),
                eventID: .init(uuid: eventID))
            let throughProxy = PostgresV2RoomWriteStore(database: proxied.database(.psql))
                .usingActivationScope(scope)

            // The proxy forwards the full successful transaction to PostgreSQL,
            // observes its COMMIT CommandComplete, then discards that ACK before
            // the production borrowed-connection primitive can receive it.
            await #expect(throws: V2RoomTransactionOutcomeUnknown.self) {
                _ = try await V2RoomSQLDeadline.withDeadline(.now + .seconds(5)) {
                    try await throughProxy.accept(command: command, capacityProfile: profile,
                        identifiers: identifiers, now: now)
                }
            }
            #expect(proxy.observedSuccessfulCommit)
            #expect(try await sql.raw("""
                SELECT COUNT(*)::bigint AS value FROM im_v2.message_send_completions
                WHERE room_id = \(bind: roomUUID) AND sender_user_id = \(bind: senderUUID)
                  AND client_message_id = \(bind: operationID)
                """).first(decoding: CountRow.self)?.value == 1)
            #expect(try await sql.raw("""
                SELECT COUNT(*)::bigint AS value FROM im_v2.messages
                WHERE room_id = \(bind: roomUUID) AND sender_user_id = \(bind: senderUUID)
                  AND client_message_id = \(bind: operationID)
                """).first(decoding: CountRow.self)?.value == 1)

            // A fresh independent client replays the same durable operation ID.
            // New executor-minted IDs cannot create a second message or event.
            let replay = try await PostgresV2RoomWriteStore(database: database)
                .usingActivationScope(scope).accept(command: command, capacityProfile: profile,
                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())),
                    now: now.addingTimeInterval(1))
            guard case .idempotent(let recovered) = replay else {
                throw V2CommitAckLossTestError.replayNotIdempotent
            }
            #expect(recovered.messageID == .init(uuid: messageID))
            #expect(try await fixture.count("im_v2.message_send_completions", on: sql) == 1)
            #expect(try await fixture.count("im_v2.messages", on: sql) == 1)
            #expect(try await fixture.count("im_v2.room_events", on: sql) == 1)
            #expect(try await leases.release(token: lease.token))

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
}

private enum V2CommitAckLossTestError: Error {
    case activationUnavailable
    case replayNotIdempotent
}
