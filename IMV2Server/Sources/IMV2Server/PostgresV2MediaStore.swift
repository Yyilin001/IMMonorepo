import Fluent
import Foundation
import IMV2Core
import SQLKit

/// PostgreSQL authority for media lifecycle. It stores no provider URL, object
/// key, filename, thumbnail, or access token.
public struct PostgresV2MediaStore: V2MediaStore {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID

    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database; self.makeUUID = makeUUID
    }

    public func requestUpload(_ command: V2RequestMediaUploadCommand, deviceID: DeviceID, expiresAt: Date, now: Date) async throws -> V2MediaUploadGrant {
        let actor = try mediaUUID(command.actorUserID); let device = try mediaUUID(deviceID); let operation = try mediaUUID(command.operationID); let media = try mediaUUID(command.mediaID)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard try await isActiveDevice(owner: actor, device: device, on: sql) else { throw V2MediaStoreError.uploadNotAuthorized }
            if let existing = try await sql.raw("SELECT media_id, content_type, byte_count, upload_session_id, expires_at, requesting_device_id FROM im_v2.media_upload_operations WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation) FOR UPDATE").first(decoding: MediaUploadOperationRow.self) {
                guard existing.mediaID == media, existing.contentType == command.contentType, existing.byteCount == command.byteCount, existing.requestingDeviceID == device else { throw V2MediaStoreError.idempotencyConflict }
                return try .init(mediaID: command.mediaID, uploadSessionID: .init(existing.uploadSessionID.uuidString), expiresAt: existing.expiresAt)
            }
            let session = makeUUID()
            try await sql.raw("INSERT INTO im_v2.media_objects (media_id, owner_user_id, content_type, byte_count, state, upload_session_id, expires_at, state_updated_at, created_at) VALUES (\(bind: media), \(bind: actor), \(bind: command.contentType), \(bind: command.byteCount), 'pending_upload', \(bind: session), \(bind: expiresAt), \(bind: now), \(bind: now))").run()
            try await sql.raw("INSERT INTO im_v2.media_upload_operations (actor_user_id, operation_id, media_id, content_type, byte_count, upload_session_id, expires_at, created_at, requesting_device_id) VALUES (\(bind: actor), \(bind: operation), \(bind: media), \(bind: command.contentType), \(bind: command.byteCount), \(bind: session), \(bind: expiresAt), \(bind: now), \(bind: device))").run()
            try await sql.raw("INSERT INTO im_v2.media_upload_grants (upload_session_id, media_id, user_id, device_id, content_type, byte_count, expires_at, created_at) VALUES (\(bind: session), \(bind: media), \(bind: actor), \(bind: device), \(bind: command.contentType), \(bind: command.byteCount), \(bind: expiresAt), \(bind: now))").run()
            return try .init(mediaID: command.mediaID, uploadSessionID: .init(session.uuidString), expiresAt: expiresAt)
        }
    }

    /// Authorization is deliberately evaluated again for every grant. A
    /// previous grant may remain usable through its short expiry, but a new
    /// grant is denied after withdrawal or current-membership removal.
    public func requestDownload(requesterUserID: UserID, deviceID: DeviceID, mediaID: MediaID, expiresAt: Date, now: Date) async throws -> V2MediaDownloadGrant {
        let requester = try mediaUUID(requesterUserID)
        let device = try mediaUUID(deviceID)
        let media = try mediaUUID(mediaID)
        let session = makeUUID()
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let authorized = try await sql.raw("""
                SELECT EXISTS (
                    SELECT 1
                    FROM im_v2.media_objects AS media
                    JOIN im_v2.message_media_references AS reference
                      ON reference.media_id = media.media_id
                    JOIN im_v2.messages AS message
                      ON message.message_id = reference.message_id
                    JOIN im_v2.rooms AS room
                      ON room.room_id = message.room_id
                    JOIN im_v2.room_memberships AS membership
                      ON membership.room_id = room.room_id
                     AND membership.user_id = \(bind: requester)
                     AND membership.joined_revision <= room.membership_revision
                     AND (membership.left_revision IS NULL OR membership.left_revision > room.membership_revision)
                    WHERE media.media_id = \(bind: media)
                      AND media.state = 'available'
                      AND message.withdrawn_at IS NULL
                      AND reference.revoked_at IS NULL
                      AND EXISTS (
                          SELECT 1
                          FROM im_v2.auth_devices AS device
                          WHERE device.user_id = \(bind: requester)
                            AND device.device_id = \(bind: device)
                            AND device.revoked_at IS NULL
                      )
                      AND EXISTS (
                          SELECT 1
                          FROM im_v2.user_sync_log AS delivery
                          WHERE delivery.user_id = \(bind: requester)
                            AND delivery.projection_kind = 'message'
                            AND delivery.payload->>'event_type' = 'message.accepted'
                            AND delivery.payload->>'message_id' = message.message_id::text
                            AND delivery.payload->'media_ids' @> jsonb_build_array(media.media_id::text)
                      )
                ) AS authorized
                """).first(decoding: MediaDownloadAuthorizationRow.self)?.authorized ?? false
            guard authorized else { throw V2MediaStoreError.downloadNotAuthorized }
            try await sql.raw("""
                INSERT INTO im_v2.media_download_grants
                    (download_session_id, media_id, user_id, device_id, expires_at, created_at)
                VALUES
                    (\(bind: session), \(bind: media), \(bind: requester), \(bind: device), \(bind: expiresAt), \(bind: now))
                """).run()
            return try .init(mediaID: mediaID, downloadSessionID: .init(session.uuidString), expiresAt: expiresAt)
        }
    }

    public func markUploadCompleted(ownerUserID: UserID, deviceID: DeviceID, mediaID: MediaID, now: Date) async throws {
        let media = try mediaUUID(mediaID)
        let owner = try mediaUUID(ownerUserID)
        let device = try mediaUUID(deviceID)
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let row = try await sql.raw("SELECT owner_user_id, state, expires_at, upload_session_id FROM im_v2.media_objects WHERE media_id = \(bind: media) FOR UPDATE").first(decoding: MediaStateRow.self)
            else { throw V2MediaStoreError.mediaUnavailable }
            guard row.ownerUserID == owner else { throw V2MediaStoreError.mediaUnavailable }
            guard try await isCompletedUploadGrant(session: row.uploadSessionID, owner: owner, device: device, now: now, on: sql) else { throw V2MediaStoreError.uploadNotAuthorized }
            guard row.expiresAt > now else { throw V2MediaStoreError.mediaExpired }
            guard row.state == "pending_upload" else { throw V2MediaStoreError.invalidStateTransition }
            try await sql.raw("UPDATE im_v2.media_objects SET state = 'scanning', state_updated_at = \(bind: now) WHERE media_id = \(bind: media)").run()
            try await sql.raw("INSERT INTO im_v2.media_scan_outbox (media_id, state, created_at) VALUES (\(bind: media), 'pending', \(bind: now)) ON CONFLICT (media_id) DO NOTHING").run()
        }
    }

    public func uploadStatus(ownerUserID: UserID, deviceID: DeviceID, mediaID: MediaID, now: Date) async throws -> V2MediaObjectState {
        let owner = try mediaUUID(ownerUserID)
        let device = try mediaUUID(deviceID)
        let media = try mediaUUID(mediaID)
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        guard let row = try await sql.raw("""
            SELECT media.state, media.expires_at
            FROM im_v2.media_objects AS media
            JOIN im_v2.media_upload_grants AS upload_grant ON upload_grant.media_id = media.media_id
            WHERE media.media_id = \(bind: media)
              AND media.owner_user_id = \(bind: owner)
              AND upload_grant.user_id = \(bind: owner)
              AND upload_grant.device_id = \(bind: device)
              AND EXISTS (
                  SELECT 1 FROM im_v2.auth_devices AS authenticated_device
                  WHERE authenticated_device.user_id = \(bind: owner)
                    AND authenticated_device.device_id = \(bind: device)
                    AND authenticated_device.revoked_at IS NULL
              )
            """).first(decoding: MediaUploadStatusRow.self) else {
            throw V2MediaStoreError.uploadNotAuthorized
        }
        guard row.expiresAt > now else { return .expired }
        guard let state = V2MediaObjectState(databaseState: row.state) else {
            throw V2MediaStoreError.mediaUnavailable
        }
        return state
    }

    public func recordScanResult(mediaID: MediaID, passed: Bool, now: Date) async throws {
        let media = try mediaUUID(mediaID)
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let row = try await sql.raw("SELECT owner_user_id, state, expires_at, upload_session_id FROM im_v2.media_objects WHERE media_id = \(bind: media) FOR UPDATE").first(decoding: MediaStateRow.self)
            else { throw V2MediaStoreError.mediaUnavailable }
            guard row.expiresAt > now else { throw V2MediaStoreError.mediaExpired }
            guard row.state == "scanning" else { throw V2MediaStoreError.invalidStateTransition }
            try await sql.raw("UPDATE im_v2.media_objects SET state = \(bind: passed ? "available" : "failed"), state_updated_at = \(bind: now) WHERE media_id = \(bind: media)").run()
            try await sql.raw("UPDATE im_v2.media_scan_outbox SET state = 'completed', completed_at = \(bind: now), claim_token = NULL, lease_expires_at = NULL WHERE media_id = \(bind: media) AND state <> 'completed'").run()
        }
    }

    public func assertAvailableForReference(ownerUserID: UserID, mediaIDs: [MediaID], now: Date) async throws {
        guard Set(mediaIDs).count == mediaIDs.count else { throw V2MediaStoreError.invalidReferenceSet }
        let owner = try mediaUUID(ownerUserID)
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        for mediaID in mediaIDs {
            let media = try mediaUUID(mediaID)
            guard try await sql.raw("SELECT media_id FROM im_v2.media_objects WHERE media_id = \(bind: media) AND owner_user_id = \(bind: owner) AND state = 'available' AND expires_at > \(bind: now)").first(decoding: MediaIDRow.self) != nil else { throw V2MediaStoreError.mediaUnavailable }
        }
    }

    private func transition(mediaID: MediaID, expected: String, next: String, owner: UserID?, now: Date) async throws {
        let media = try mediaUUID(mediaID); let ownerUUID = try owner.map(mediaUUID)
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let row = try await sql.raw("SELECT owner_user_id, state, expires_at, upload_session_id FROM im_v2.media_objects WHERE media_id = \(bind: media) FOR UPDATE").first(decoding: MediaStateRow.self)
            else { throw V2MediaStoreError.mediaUnavailable }
            guard ownerUUID == nil || row.ownerUserID == ownerUUID else { throw V2MediaStoreError.mediaUnavailable }
            guard row.expiresAt > now else { throw V2MediaStoreError.mediaExpired }
            guard row.state == expected else { throw V2MediaStoreError.invalidStateTransition }
            try await sql.raw("UPDATE im_v2.media_objects SET state = \(bind: next), state_updated_at = \(bind: now) WHERE media_id = \(bind: media)").run()
        }
    }

    private func isActiveDevice(owner: UUID, device: UUID, on sql: any SQLDatabase) async throws -> Bool {
        try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.auth_devices WHERE user_id = \(bind: owner) AND device_id = \(bind: device) AND revoked_at IS NULL) AS authorized").first(decoding: MediaUploadAuthorizationRow.self)?.authorized ?? false
    }

    private func isCompletedUploadGrant(session: UUID, owner: UUID, device: UUID, now: Date, on sql: any SQLDatabase) async throws -> Bool {
        try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.media_upload_grants WHERE upload_session_id = \(bind: session) AND user_id = \(bind: owner) AND device_id = \(bind: device) AND expires_at > \(bind: now) AND state = 'consumed') AS authorized").first(decoding: MediaUploadAuthorizationRow.self)?.authorized ?? false
    }
}

public enum V2MediaStoreError: Error, Equatable, Sendable { case idempotencyConflict, mediaUnavailable, mediaExpired, invalidStateTransition, invalidReferenceSet, downloadNotAuthorized, uploadNotAuthorized }

private struct MediaUploadOperationRow: Decodable { let mediaID: UUID; let contentType: String; let byteCount: Int64; let uploadSessionID: UUID; let expiresAt: Date; let requestingDeviceID: UUID; enum CodingKeys: String, CodingKey { case mediaID = "media_id"; case contentType = "content_type"; case byteCount = "byte_count"; case uploadSessionID = "upload_session_id"; case expiresAt = "expires_at"; case requestingDeviceID = "requesting_device_id" } }
private struct MediaStateRow: Decodable { let ownerUserID: UUID; let state: String; let expiresAt: Date; let uploadSessionID: UUID; enum CodingKeys: String, CodingKey { case ownerUserID = "owner_user_id"; case state; case expiresAt = "expires_at"; case uploadSessionID = "upload_session_id" } }
private struct MediaIDRow: Decodable { let mediaID: UUID; enum CodingKeys: String, CodingKey { case mediaID = "media_id" } }
private struct MediaDownloadAuthorizationRow: Decodable { let authorized: Bool }
private struct MediaUploadAuthorizationRow: Decodable { let authorized: Bool }
private struct MediaUploadStatusRow: Decodable { let state: String; let expiresAt: Date; enum CodingKeys: String, CodingKey { case state; case expiresAt = "expires_at" } }
private func mediaUUID<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag { guard let uuid = UUID(uuidString: value.rawValue) else { throw V2MediaStoreError.mediaUnavailable }; return uuid }

private extension V2MediaObjectState {
    init?(databaseState: String) {
        switch databaseState {
        case "pending_upload": self = .pendingUpload
        case "scanning": self = .scanning
        case "available": self = .available
        case "failed": self = .failed
        case "expired": self = .expired
        default: return nil
        }
    }
}
