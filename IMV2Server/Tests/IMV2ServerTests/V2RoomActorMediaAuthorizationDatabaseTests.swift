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
            let mediaID = MediaID(uuid: UUID()), device = DeviceID(uuid: UUID())
            let uploads = PostgresV2ResourceLifecycleStore(database: database, authorize: { _ in })
            let input = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()),
                mediaID: mediaID, usage: .messageAttachment(roomID), contentType: "text/plain",
                byteCount: 5, checksum: .init(value: String(repeating: "a", count: 64)))
            let upload = try await createResourceUpload(input, device: device, store: uploads,
                expiresAt: now.addingTimeInterval(600), now: now)
            let sessionID = upload.sessionID
            let claim = try await uploads.claimFinalize(session: sessionID, generation: 1,
                actor: senderUUID, device: device.uuidValue!, now: now)
            try await uploads.publish(claim, facts: .init(reference: claim.placement,
                byteCount: 5, sha256: Data(repeating: 0xaa, count: 32)),
                actor: senderUUID, device: device.uuidValue!, now: now)
            let scans = PostgresV2MediaScanStore(database: database)
            let scan = try #require(try await scans.claimPending(now: now, leaseDuration: 30, limit: 1).first)
            try await scans.complete(scan, result: .passed, now: now)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let send = V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(
                database: database, controlDatabase: database,
                store: PostgresV2RoomWriteStore(database: database), shardID: "room-a", epoch: 0),
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
