import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("RoomRef media grants recheck visibility and devices after provider wait",
          arguments: ["valid", "visibility-revoked", "device-revoked", "route-changed"])
    func roomRefMediaDownload(scenario: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { controlDB, ownerDB, controlSQL, ownerSQL, room in
            let now = Date(), user = UserID(uuid: memberTwoUUID)
            let device = DeviceID(uuid: UUID()), media = MediaID(uuid: UUID())
            let message = MessageID(uuid: UUID())
            try await ownerSQL.raw("""
                INSERT INTO im_v2.media_objects
                    (media_id, owner_user_id, content_type, byte_count, state,
                     upload_session_id, expires_at, state_updated_at, created_at)
                VALUES (\(bind: media.uuidValue!), \(bind: senderUUID), 'text/plain', 10,
                        'available', \(bind: UUID()), \(bind: now.addingTimeInterval(600)),
                        \(bind: now), \(bind: now))
                """).run()
            try await controlSQL.raw("""
                INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at)
                VALUES (\(bind: memberTwoUUID), \(bind: device.uuidValue!), \(bind: now), \(bind: now))
                """).run()
            try await controlSQL.raw("""
                INSERT INTO im_v2.room_owner_routes
                    (room_id, room_shard_id, route_epoch, created_at, updated_at)
                VALUES (\(bind: room.uuidValue!), 'room-b', 0, \(bind: now), \(bind: now))
                """).run()
            let visibility = MediaVisibilityProbe(snapshot: .init(roomID: room,
                messageID: message, mediaID: media, membershipRevision: 1,
                contentRevision: 1, mediaUpdatedAt: now, uploadSessionID: UUID()))
            let port = V2ActorRoomMediaAuthorizationPort { query, _ in
                await visibility.query(query)
            }
            let provider = MediaProviderProbe { _ in
                if scenario == "visibility-revoked" { await visibility.revoke() }
                if scenario == "device-revoked" {
                    try await controlSQL.raw("""
                        UPDATE im_v2.auth_devices SET revoked_at = clock_timestamp()
                        WHERE user_id = \(bind: memberTwoUUID) AND device_id = \(bind: device.uuidValue!)
                        """).run()
                }
                if scenario == "route-changed" {
                    try await controlSQL.raw("""
                        UPDATE im_v2.room_owner_routes SET route_epoch = 1,
                            updated_at = clock_timestamp() WHERE room_id = \(bind: room.uuidValue!)
                        """).run()
                }
            }
            let localProvider = MediaProviderProbe { _ in }
            let local = V2MediaEdgeDownloadService(media: .init(
                store: PostgresV2MediaStore(database: controlDB),
                limits: try .init(maximumBytes: 1_024)),
                providerSessions: try .init(
                    store: PostgresV2MediaDownloadSessionStore(database: controlDB),
                    provider: localProvider))
            let client = V2RoomRefMediaDownloadClient(local: local,
                rooms: V2PostgresRoomShardRouter(database: controlDB),
                owners: ["room-b": .init(database: ownerDB, provider: provider)],
                controlDatabase: controlDB, authorization: port)
            let location = V2MediaMessageLocation(roomID: room, messageID: message)
            if scenario == "valid" {
                let target = try await client.downloadTarget(actorUserID: user,
                    deviceID: device, mediaID: media, message: location)
                #expect(target.url.scheme == "https")
                #expect(try await count("im_v2.media_download_grants WHERE state = 'consumed'", on: ownerSQL) == 1)
            } else {
                await #expect(throws: V2MediaStoreError.downloadNotAuthorized) {
                    try await client.downloadTarget(actorUserID: user,
                        deviceID: device, mediaID: media, message: location)
                }
                #expect(try await count("im_v2.media_download_grants WHERE state = 'pending'", on: ownerSQL) == 1)
                #expect(try await count("im_v2.media_download_grants WHERE state = 'consumed'", on: ownerSQL) == 0)
            }
            #expect(await visibility.calls >= (scenario == "device-revoked" ? 3 : 4))
            #expect(await provider.calls == 1)
        }
    }
}

private actor MediaVisibilityProbe {
    let snapshot: V2ActorMessageMediaVisibilitySnapshotWire
    private var revoked = false
    private(set) var calls = 0
    init(snapshot: V2ActorMessageMediaVisibilitySnapshotWire) { self.snapshot = snapshot }
    func revoke() { revoked = true }
    func query(_ query: V2RoomMediaAuthorizationQuery) -> V2RoomMediaAuthorizationResult {
        calls += 1
        guard case .messageVisibility(let request) = query,
              request.roomID == snapshot.roomID,
              request.messageID == snapshot.messageID,
              request.mediaID == snapshot.mediaID,
              !revoked else { return .notVisible }
        return .visible(snapshot)
    }
}

private actor MediaProviderProbe: V2MediaObjectProvider {
    let onIssue: @Sendable (MediaID) async throws -> Void
    private(set) var calls = 0
    init(onIssue: @escaping @Sendable (MediaID) async throws -> Void) { self.onIssue = onIssue }
    func issueDownloadTarget(mediaID: MediaID, expiresAt: Date) async throws -> V2MediaProviderObjectTarget {
        calls += 1
        try await onIssue(mediaID)
        return .init(url: URL(string: "https://media.invalid/download")!,
                     expiresAt: expiresAt.addingTimeInterval(-1))
    }
}
