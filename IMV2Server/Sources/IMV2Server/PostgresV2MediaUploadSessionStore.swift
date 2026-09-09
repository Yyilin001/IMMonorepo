import Fluent
import Foundation
import IMV2Core
import SQLKit

/// PostgreSQL fencing for upload target exchange. A session is both
/// user/device-bound and one-time: one conditional update validates ownership,
/// device state, media state, expiry, and lease eligibility before claiming it.
public struct PostgresV2MediaUploadSessionStore: V2MediaUploadSessionStore {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID

    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database
        self.makeUUID = makeUUID
    }

    public func claimUpload(
        ownerUserID: UserID,
        deviceID: DeviceID,
        uploadSessionID: MediaUploadSessionID,
        now: Date,
        leaseDuration: TimeInterval
    ) async throws -> V2ClaimedMediaUpload {
        guard leaseDuration > 0 else { throw V2MediaUploadSessionStoreError.invalidRequest }
        guard let leaseExpiresAt = v2PostgresFutureTimestamp(now: now, interval: leaseDuration) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let owner = try uploadUUID(ownerUserID)
        let device = try uploadUUID(deviceID)
        let session = try uploadUUID(uploadSessionID)
        let token = makeUUID()
        guard let sql = database as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard let grant = try await sql.raw("""
            UPDATE im_v2.media_upload_grants AS upload_grant
            SET state = 'claimed',
                claim_token = \(bind: token),
                lease_expires_at = \(bind: leaseExpiresAt),
                retry_count = upload_grant.retry_count + 1
            FROM im_v2.media_objects AS media
            WHERE upload_grant.upload_session_id = \(bind: session)
              AND upload_grant.media_id = media.media_id
              AND upload_grant.user_id = \(bind: owner)
              AND upload_grant.device_id = \(bind: device)
              AND upload_grant.expires_at > \(bind: now)
              AND upload_grant.retry_count < 9223372036854775807
              AND media.state = 'pending_upload'
              AND media.expires_at > \(bind: now)
              AND EXISTS (
                  SELECT 1 FROM im_v2.auth_devices AS authenticated_device
                  WHERE authenticated_device.user_id = \(bind: owner)
                    AND authenticated_device.device_id = \(bind: device)
                    AND authenticated_device.revoked_at IS NULL AND authenticated_device.session_expires_at > clock_timestamp()
              )
              AND (
                  upload_grant.state = 'pending'
                  OR (upload_grant.state = 'claimed' AND upload_grant.lease_expires_at <= \(bind: now))
              )
            RETURNING upload_grant.media_id, upload_grant.content_type,
                      upload_grant.byte_count, upload_grant.expires_at
            """).first(decoding: MediaUploadGrantRow.self)
        else { throw V2MediaUploadSessionStoreError.sessionUnavailable }
        return try .init(
            mediaID: .init(grant.mediaID.uuidString),
            uploadSessionID: uploadSessionID,
            contentType: grant.contentType,
            byteCount: grant.byteCount,
            expiresAt: grant.expiresAt,
            claimToken: token
        )
    }

    public func completeUploadTarget(_ claim: V2ClaimedMediaUpload, now: Date) async throws {
        guard v2PostgresTimestampCanEncode(now),
              let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        guard try await sql.raw("""
            UPDATE im_v2.media_upload_grants AS upload_grant
            SET state = 'consumed', redeemed_at = \(bind: now), claim_token = NULL, lease_expires_at = NULL
            WHERE upload_session_id = \(bind: try uploadUUID(claim.uploadSessionID))
              AND state = 'claimed'
              AND claim_token = \(bind: claim.claimToken)
              AND expires_at > \(bind: now)
              AND lease_expires_at > \(bind: now)
              AND EXISTS (
                  SELECT 1 FROM im_v2.auth_devices AS device
                  WHERE device.user_id = upload_grant.user_id AND device.device_id = upload_grant.device_id
                    AND device.revoked_at IS NULL AND device.session_expires_at > clock_timestamp()
              )
              AND EXISTS (
                  SELECT 1 FROM im_v2.media_objects AS media
                  WHERE media.media_id = upload_grant.media_id AND media.state = 'pending_upload'
                    AND media.expires_at > \(bind: now)
              )
            RETURNING upload_session_id
            """).first() != nil else { throw V2MediaUploadSessionStoreError.sessionUnavailable }
    }

    public func releaseUploadTarget(_ claim: V2ClaimedMediaUpload) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            UPDATE im_v2.media_upload_grants
            SET state = 'pending', claim_token = NULL, lease_expires_at = NULL
            WHERE upload_session_id = \(bind: try uploadUUID(claim.uploadSessionID))
              AND state = 'claimed'
              AND claim_token = \(bind: claim.claimToken)
            """).run()
    }
}

public enum V2MediaUploadSessionStoreError: Error, Equatable, Sendable {
    case invalidRequest
    case sessionUnavailable
}

private struct MediaUploadGrantRow: Decodable {
    let mediaID: UUID
    let contentType: String
    let byteCount: Int64
    let expiresAt: Date
    enum CodingKeys: String, CodingKey {
        case mediaID = "media_id"
        case contentType = "content_type"
        case byteCount = "byte_count"
        case expiresAt = "expires_at"
    }
}

private func uploadUUID<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let uuid = UUID(uuidString: value.rawValue) else { throw V2MediaUploadSessionStoreError.sessionUnavailable }
    return uuid
}
