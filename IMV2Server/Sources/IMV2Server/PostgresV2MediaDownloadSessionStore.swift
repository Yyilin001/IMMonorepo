import Fluent
import Foundation
import IMV2Core
import SQLKit

/// PostgreSQL fencing for the provider-exchange boundary. The provider never
/// receives a grant until this store has confirmed the authenticated device,
/// current membership, current message visibility, and non-withdrawn state.
public struct PostgresV2MediaDownloadSessionStore: V2MediaDownloadSessionStore {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID

    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database
        self.makeUUID = makeUUID
    }

    public func claimDownload(
        requesterUserID: UserID,
        deviceID: DeviceID,
        downloadSessionID: MediaDownloadSessionID,
        now: Date,
        leaseDuration: TimeInterval
    ) async throws -> V2ClaimedMediaDownload {
        guard leaseDuration > 0 else { throw V2MediaDownloadSessionStoreError.invalidRequest }
        guard let leaseExpiresAt = v2PostgresFutureTimestamp(now: now, interval: leaseDuration) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let requester = try mediaDownloadUUID(requesterUserID)
        let device = try mediaDownloadUUID(deviceID)
        let session = try mediaDownloadUUID(downloadSessionID)
        let token = makeUUID()
        guard let sql = database as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let authorization = V2PostgresMediaVisibilityAuthorization.predicate(
            mediaID: "download_grant.media_id",
            requesterUserID: requester,
            deviceID: device
        )
        guard let grant = try await sql.raw("""
            UPDATE im_v2.media_download_grants AS download_grant
            SET state = 'claimed',
                claim_token = \(bind: token),
                lease_expires_at = \(bind: leaseExpiresAt),
                retry_count = download_grant.retry_count + 1
            WHERE download_grant.download_session_id = \(bind: session)
              AND download_grant.message_room_id IS NULL
              AND download_grant.user_id = \(bind: requester)
              AND download_grant.device_id = \(bind: device)
              AND download_grant.expires_at > \(bind: now)
              AND download_grant.retry_count < 9223372036854775807
              AND (
                  download_grant.state = 'pending'
                  OR (download_grant.state = 'claimed'
                      AND download_grant.lease_expires_at <= \(bind: now))
              )
              AND \(authorization)
            RETURNING download_grant.media_id, download_grant.expires_at
            """).first(decoding: MediaDownloadGrantRow.self)
        else { throw V2MediaDownloadSessionStoreError.sessionUnavailable }
        return try .init(
            mediaID: .init(grant.mediaID.uuidString),
            downloadSessionID: downloadSessionID,
            expiresAt: grant.expiresAt,
            claimToken: token
        )
    }

    public func completeDownload(_ claim: V2ClaimedMediaDownload, now: Date) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let session = try mediaDownloadUUID(claim.downloadSessionID)
        let media = try mediaDownloadUUID(claim.mediaID)
        guard let identity = try await sql.raw("""
            SELECT user_id, device_id FROM im_v2.media_download_grants
            WHERE download_session_id = \(bind: session)
              AND message_room_id IS NULL AND media_id = \(bind: media)
              AND state = 'claimed' AND claim_token = \(bind: claim.claimToken)
            """).first(decoding: MediaDownloadGrantIdentityRow.self)
        else { throw V2MediaDownloadSessionStoreError.sessionUnavailable }
        guard v2PostgresTimestampCanEncode(now) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let authorization = V2PostgresMediaVisibilityAuthorization.predicate(
            mediaID: "download_grant.media_id", requesterUserID: identity.userID, deviceID: identity.deviceID
        )
        // Provider I/O has finished. Re-evaluate the same authorization while
        // consuming this exact live lease; a lost claim must not return a URL.
        guard try await sql.raw("""
            UPDATE im_v2.media_download_grants AS download_grant
            SET state = 'consumed', redeemed_at = \(bind: now), claim_token = NULL, lease_expires_at = NULL
            WHERE download_grant.download_session_id = \(bind: session)
              AND download_grant.message_room_id IS NULL
              AND download_grant.media_id = \(bind: media)
              AND download_grant.user_id = \(bind: identity.userID)
              AND download_grant.device_id = \(bind: identity.deviceID)
              AND download_grant.state = 'claimed'
              AND download_grant.claim_token = \(bind: claim.claimToken)
              AND download_grant.lease_expires_at > \(bind: now)
              AND download_grant.expires_at > \(bind: now)
              AND \(authorization)
            RETURNING download_grant.download_session_id
            """).first() != nil
        else { throw V2MediaDownloadSessionStoreError.sessionUnavailable }
    }

    public func releaseDownload(_ claim: V2ClaimedMediaDownload) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            UPDATE im_v2.media_download_grants
            SET state = 'pending', claim_token = NULL, lease_expires_at = NULL
            WHERE download_session_id = \(bind: try mediaDownloadUUID(claim.downloadSessionID))
              AND state = 'claimed'
              AND claim_token = \(bind: claim.claimToken)
            """).run()
    }

}

public enum V2MediaDownloadSessionStoreError: Error, Equatable, Sendable {
    case invalidRequest
    case sessionUnavailable
}

private struct MediaDownloadGrantRow: Decodable {
    let mediaID: UUID
    let expiresAt: Date
    enum CodingKeys: String, CodingKey { case mediaID = "media_id"; case expiresAt = "expires_at" }
}

private func mediaDownloadUUID<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let uuid = UUID(uuidString: value.rawValue) else {
        throw V2MediaDownloadSessionStoreError.sessionUnavailable
    }
    return uuid
}

private struct MediaDownloadGrantIdentityRow: Decodable {
    let userID: UUID
    let deviceID: UUID
    enum CodingKeys: String, CodingKey { case userID = "user_id", deviceID = "device_id" }
}
