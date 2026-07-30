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
        let requester = try mediaDownloadUUID(requesterUserID)
        let device = try mediaDownloadUUID(deviceID)
        let session = try mediaDownloadUUID(downloadSessionID)
        let token = makeUUID()
        let leaseExpiresAt = now.addingTimeInterval(leaseDuration)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard let grant = try await sql.raw("""
                SELECT media_id, expires_at
                FROM im_v2.media_download_grants
                WHERE download_session_id = \(bind: session)
                  AND user_id = \(bind: requester)
                  AND device_id = \(bind: device)
                  AND expires_at > \(bind: now)
                  AND (state = 'pending' OR (state = 'claimed' AND lease_expires_at <= \(bind: now)))
                FOR UPDATE
                """).first(decoding: MediaDownloadGrantRow.self) else {
                throw V2MediaDownloadSessionStoreError.sessionUnavailable
            }
            guard try await isCurrentlyAuthorized(mediaID: grant.mediaID, requester: requester, device: device, on: sql) else {
                throw V2MediaDownloadSessionStoreError.sessionUnavailable
            }
            try await sql.raw("""
                UPDATE im_v2.media_download_grants
                SET state = 'claimed', claim_token = \(bind: token), lease_expires_at = \(bind: leaseExpiresAt), retry_count = retry_count + 1
                WHERE download_session_id = \(bind: session)
                """).run()
            return try .init(
                mediaID: .init(grant.mediaID.uuidString),
                downloadSessionID: downloadSessionID,
                expiresAt: grant.expiresAt,
                claimToken: token
            )
        }
    }

    public func completeDownload(_ claim: V2ClaimedMediaDownload, now: Date) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            UPDATE im_v2.media_download_grants
            SET state = 'consumed', redeemed_at = \(bind: now), claim_token = NULL, lease_expires_at = NULL
            WHERE download_session_id = \(bind: try mediaDownloadUUID(claim.downloadSessionID))
              AND state = 'claimed'
              AND claim_token = \(bind: claim.claimToken)
            """).run()
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

    private func isCurrentlyAuthorized(mediaID: UUID, requester: UUID, device: UUID, on sql: any SQLDatabase) async throws -> Bool {
        try await V2PostgresMediaVisibilityAuthorization.isAuthorized(
            mediaID: mediaID,
            requesterUserID: requester,
            deviceID: device,
            on: sql
        )
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
