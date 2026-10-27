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
    @Test("resource directory uses current room authority and stable attachment ordering",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_DIRECTORY_DISPOSABLE"] == "1"))
    func resourceDirectoryPostgresAuthorityAndPagination() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_DIRECTORY_DATABASE_URL"])
        let resources = makeV2DatabaseTestResources()
        resources.databases.use(try .postgres(url: address, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
        let database = resources.database(.psql), sql = try #require(database as? any SQLDatabase)
        do {
            guard try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS value").first(decoding: DirectorySchemaExists.self)?.value == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            let firstMedia = MediaID(uuid: UUID()), secondMedia = MediaID(uuid: UUID()), thirdMedia = MediaID(uuid: UUID())
            try await prepareDownloadableResource(mediaID: firstMedia, device: deviceID, database: database)
            try await prepareDownloadableResource(mediaID: secondMedia, device: deviceID, database: database, dimensions: .init(width: 300, height: 160))
                let port = V2ActorRoomMediaAuthorizationPort(query: { query, _ in
                    try await withRoomActivationLifetime(database: database, roomID: roomID) { token, lifetime in
                        let executor = try V2RoomMediaAuthorizationDomainExecutor(database: database, token: token, lifetime: lifetime)
                        return try await executor.execute(query)
                    }
                })
                let service = try V2RoomResourceDirectoryService(authorization: port, signingKey: Data(repeating: 9, count: 32))
                let actor = UserID(uuid: memberTwoUUID)
                let first = try await service.list(roomID: roomID, actorUserID: actor, query: .init(category: .image, limit: 1))
                #expect(first.items.map(\.descriptor.key.mediaID) == [secondMedia])
                let acceptedPayload = try #require(try await sql.raw("""
                    SELECT payload::text AS value FROM im_v2.room_events
                    WHERE room_id=\(bind: roomUUID) AND event_type='message.accepted'
                    ORDER BY room_sequence DESC LIMIT 1
                    """).first(decoding: DirectoryAcceptedPayload.self))
                let accepted = try V2MessageProjectionState(payloadJSON: acceptedPayload.value)
                let synchronizedDescriptor = try #require(accepted.mediaPresentations.first?.resourceDescriptor)
                #expect(synchronizedDescriptor == first.items.first?.descriptor)
                #expect(synchronizedDescriptor.pixelWidth == 300 && synchronizedDescriptor.pixelHeight == 160)
                #expect(try V2MessageProjectionState(payloadJSON: accepted.encodedPayloadJSON()) == accepted)
                let cursor = try #require(first.nextCursor)
                // A later message is outside this scan's fixed upper bound.
                try await prepareDownloadableResource(mediaID: thirdMedia, device: deviceID, database: database)
                let second = try await service.list(roomID: roomID, actorUserID: actor, query: .init(category: .image, limit: 1, cursor: cursor))
                #expect(second.items.map(\.descriptor.key.mediaID) == [firstMedia])
                #expect(second.snapshotUpperRoomSequence == first.snapshotUpperRoomSequence)
                #expect(second.nextCursor == nil)
                #expect(second.items.first?.descriptor.checksum?.value == String(repeating: "a", count: 64))
                #expect(try await service.list(roomID: roomID, actorUserID: actor, query: .init(category: .file)).items.isEmpty)
                let all = try await service.list(roomID: roomID, actorUserID: actor, query: .init())
                #expect(all.items.count == 3)
                // SQL lifecycle fixtures exercise both real descriptor producers;
                // the probe suites separately validate actual original bytes.
                for category in [V2ResourceCategory.audio, .video] {
                    let timed = MediaID(uuid: UUID())
                    let video = category == .video
                    try await prepareDownloadableResource(mediaID: timed, device: deviceID, database: database,
                        dimensions: video ? .init(width: 64, height: 48) : nil,
                        contentType: video ? "video/mp4" : "audio/wav", durationMilliseconds: 2000)
                    let page = try await service.list(roomID: roomID, actorUserID: actor, query: .init(category: category))
                    let descriptor = try #require(page.items.first?.descriptor)
                    #expect(descriptor.key.mediaID == timed && descriptor.durationMilliseconds == 2000)
                    #expect(descriptor.pixelWidth == (video ? 64 : nil) && descriptor.pixelHeight == (video ? 48 : nil))
                    let payload = try #require(try await sql.raw("""
                        SELECT payload::text AS value FROM im_v2.room_events
                        WHERE room_id=\(bind: roomUUID) AND event_type='message.accepted'
                        ORDER BY room_sequence DESC LIMIT 1
                        """).first(decoding: DirectoryAcceptedPayload.self))
                    #expect(try V2MessageProjectionState(payloadJSON: payload.value).mediaPresentations.first?.resourceDescriptor == descriptor)
                }
                // The position trigger derives indexed facts from the message.
                let mismatch = UUID()
                await #expect(throws: (any Error).self) {
                    try await sql.raw("UPDATE im_v2.message_media_references SET room_id=\(bind: mismatch) WHERE media_id=\(bind: firstMedia.uuidValue!)").run()
                }
                try await sql.raw("UPDATE im_v2.message_media_references SET revoked_at=clock_timestamp() WHERE media_id=\(bind: firstMedia.uuidValue!)").run()
                #expect(try await service.list(roomID: roomID, actorUserID: actor, query: .init(category: .image, cursor: cursor)).items.isEmpty)
                // A valid old cursor is a position, never an authority grant.
                try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=1 WHERE room_id=\(bind: roomUUID) AND user_id=\(bind: memberTwoUUID) AND left_revision IS NULL").run()
                try await sql.raw("UPDATE im_v2.rooms SET membership_revision=1 WHERE room_id=\(bind: roomUUID)").run()
                await #expect(throws: V2ResourceDirectoryError.notVisible) {
                    try await service.list(roomID: roomID, actorUserID: actor, query: .init(category: .image, cursor: cursor))
                }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            // This suite is explicitly enabled only against its disposable DB.
            try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            try? await resources.shutdown()
            throw error
        }
    }
}
private struct DirectorySchemaExists: Decodable { let value: Bool }

private struct DirectoryAcceptedPayload: Decodable { let value: String }
