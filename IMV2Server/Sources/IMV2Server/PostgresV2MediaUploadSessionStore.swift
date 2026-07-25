import Fluent
import Foundation
import IMV2Core
import SQLKit

/// PostgreSQL fencing for upload target exchange. A session is both
/// user/device-bound and one-time: target generation never happens while the
/// transaction holding the claim is open.
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
        let owner = try uploadUUID(ownerUserID)
        let device = try uploadUUID(deviceID)
        let session = try uploadUUID(uploadSessionID)
        let token = makeUUID()
        let leaseExpiresAt = now.addingTimeInterval(leaseDuration)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard let grant = try await sql.raw("""
                SELECT upload_grant.media_id, upload_grant.content_type, upload_grant.byte_count, upload_grant.expires_at
                FROM im_v2.media_upload_grants AS upload_grant
                JOIN im_v2.media_objects AS media ON media.media_id = upload_grant.media_id
                WHERE grant.upload_session_id = \(bind: session)
                  AND upload_grant.user_id = \(bind: owner)
                  AND upload_grant.device_id = \(bind: device)
                  AND grant.expires_at > \(bind: now)
                  AND media.state = 'pending_upload'
                  AND media.expires_at > \(bind: now)
                  AND EXISTS (
                      SELECT 1 FROM im_v2.auth_devices AS authenticated_device
                      WHERE authenticated_device.user_id = \(bind: owner)
                        AND authenticated_device.device_id = \(bind: device)
                        AND authenticated_device.revoked_at IS NULL
                  )
                  AND (grant.state = 'pending' OR (grant.state = 'claimed' AND grant.lease_expires_at <= \(bind: now)))
                FOR UPDATE OF grant, media
                """).first(decoding: MediaUploadGrantRow.self) else {
                throw V2MediaUploadSessionStoreError.sessionUnavailable
            }
            try await sql.raw("""
                UPDATE im_v2.media_upload_grants
                SET state = 'claimed', claim_token = \(bind: token), lease_expires_at = \(bind: leaseExpiresAt), retry_count = retry_count + 1
                WHERE upload_session_id = \(bind: session)
                """).run()
            return try .init(
                mediaID: .init(grant.mediaID.uuidString),
                uploadSessionID: uploadSessionID,
                contentType: grant.contentType,
                byteCount: grant.byteCount,
                expiresAt: grant.expiresAt,
                claimToken: token
            )
        }
    }

    public func completeUploadTarget(_ claim: V2ClaimedMediaUpload, now: Date) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            UPDATE im_v2.media_upload_grants
            SET state = 'consumed', redeemed_at = \(bind: now), claim_token = NULL, lease_expires_at = NULL
            WHERE upload_session_id = \(bind: try uploadUUID(claim.uploadSessionID))
              AND state = 'claimed'
              AND claim_token = \(bind: claim.claimToken)
            """).run()
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
