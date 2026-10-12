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

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("D5 media visibility snapshot is rechecked and fenced to the read turn",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_D5_MEDIA_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func v2RoomActorMediaVisibilityFence() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_D5_MEDIA_DATABASE_URL"])
        let resources = makeV2DatabaseTestResources()
        resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
        let database = resources.database(.psql)
        let sql = try #require(database as? any SQLDatabase)
        do {
            guard try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS value")
                .first(decoding: D5MediaBool.self)?.value == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let mediaID = MediaID(uuid: UUID()), sessionID = UUID()
            try await sql.raw("""
                INSERT INTO im_v2.media_objects
                    (media_id, owner_user_id, content_type, byte_count, state,
                     upload_session_id, expires_at, state_updated_at, created_at)
                VALUES (\(bind: mediaID.uuidValue!), \(bind: senderUUID), 'text/plain', 5,
                    'available', \(bind: sessionID), \(bind: now.addingTimeInterval(600)),
                    \(bind: now), \(bind: now))
                """).run()
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: database),
                capacityProfile: profile, limits: try .init(maxUTF8Bytes: 128), now: { now })
            let room = RoomID(uuid: roomUUID)
            guard case .accepted(let message) = try await send.send(.init(roomID: room,
                actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "media",
                media: [.init(mediaID: mediaID)])) else {
                throw V2ForwardInboxError.corruptPersistenceState
            }
            try await withRoomActivationLifetime(database: database, roomID: room) { token, lifetime in
                let query = V2RoomMediaAuthorizationQuery.messageVisibility(.init(roomID: room,
                    messageID: message.messageID, mediaID: mediaID,
                    actorUserID: UserID(uuid: memberTwoUUID)))
                let executor = try V2RoomMediaAuthorizationDomainExecutor(database: database,
                    token: token, lifetime: lifetime)
                guard case .visible(let snapshot) = try await executor.execute(query) else {
                    throw V2MediaStoreError.downloadNotAuthorized
                }
                #expect(snapshot.mediaID == mediaID && snapshot.uploadSessionID == sessionID)
                #expect(snapshot.membershipRevision == 0 && snapshot.contentRevision == 1)
                try await sql.raw("""
                    UPDATE im_v2.message_media_references SET revoked_at = CURRENT_TIMESTAMP
                    WHERE message_id = \(bind: message.messageID.uuidValue!)
                      AND media_id = \(bind: mediaID.uuidValue!)
                    """).run()
                #expect(try await executor.execute(query) == .notVisible)
                try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=owner_epoch+1 WHERE room_id=\(bind:room.uuidValue!)").run()
                await #expect(throws: V2RoomActorStateError.ownerChanged) {
                    _ = try await executor.execute(query)
                }
            }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            try? await resources.shutdown()
            throw error
        }
    }
}

private struct D5MediaBool: Decodable { let value: Bool }
