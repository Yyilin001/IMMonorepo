import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// Message downloads use a fresh room turn for visibility. The owner database
/// stores only the scoped provider grant; it is not consulted for room facts.
public struct V2RoomRefMediaDownloadClient: V2MediaDownloadTargetResolving {
    private let local: V2MediaEdgeDownloadService
    private let rooms: any V2RoomShardRouting
    private let owners: [String: V2MessageMediaOwner]
    private let controlDatabase: any Database
    private let authorization: V2ActorRoomMediaAuthorizationPort
    private let callTimeout: Duration
    private let now: @Sendable () -> Date

    public init(local: V2MediaEdgeDownloadService, rooms: any V2RoomShardRouting,
                owners: [String: V2MessageMediaOwner], controlDatabase: any Database,
                authorization: V2ActorRoomMediaAuthorizationPort,
                callTimeout: Duration = .seconds(10),
                now: @escaping @Sendable () -> Date = Date.init) {
        precondition(callTimeout > .zero)
        self.local = local; self.rooms = rooms; self.owners = owners
        self.controlDatabase = controlDatabase; self.authorization = authorization
        self.callTimeout = callTimeout; self.now = now
    }

    public func downloadTarget(actorUserID: UserID, deviceID: DeviceID, mediaID: MediaID,
                               message: V2MediaMessageLocation?) async throws -> V2MediaProviderObjectTarget {
        guard let message else {
            return try await local.downloadTarget(actorUserID: actorUserID, deviceID: deviceID,
                                                  mediaID: mediaID)
        }
        let deadline = ContinuousClock.now + callTimeout
        try Task.checkCancellation()
        let route: V2RoomShardRoute
        do { route = try await rooms.route(for: message.roomID) }
        catch V2RoomShardRouteError.roomNotFound { throw V2MediaStoreError.downloadNotAuthorized }
        guard let owner = owners[route.shardID] else {
            throw V2MediaEdgeHTTPHandlerError.messageOwnerUnavailable
        }
        let context = try RoomRefMediaContext(actor: actorUserID, device: deviceID,
                                              media: mediaID, message: message, route: route)
        let guardrail = RoomRefMediaGuard(controlDatabase: controlDatabase, rooms: rooms,
                                         authorization: authorization, context: context,
                                         deadline: deadline)
        let snapshot = try await guardrail.capture()
        let instant = now()
        guard let expiry = v2PostgresFutureTimestamp(now: instant,
                    interval: V2MediaDownloadLimits.standard.grantLifetime) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let store = RoomRefMediaSessions(owner: owner.database, context: context,
                                         guardrail: guardrail, snapshot: snapshot)
        let grant = try await store.issue(now: instant, expiresAt: expiry)
        let sessions = try V2MediaProviderSessionService(store: store, provider: owner.provider, now: now)
        let target = try await sessions.exchangeDownload(actorUserID: actorUserID,
            deviceID: deviceID, downloadSessionID: grant.downloadSessionID)
        // Provider signing may await network or storage. A granted snapshot is
        // not a standing authorization after that wait.
        try await guardrail.recheck(snapshot)
        let returnedAt = now()
        guard v2PostgresTimestampCanEncode(returnedAt) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard target.expiresAt > returnedAt else { throw V2MediaProviderSessionError.expiredSession }
        return target
    }
}

private struct RoomRefMediaContext: Sendable {
    let actor: UUID; let device: UUID; let media: UUID
    let room: UUID; let message: UUID; let route: V2RoomShardRoute
    let actorID: UserID; let mediaID: MediaID; let roomID: RoomID; let messageID: MessageID

    init(actor: UserID, device: DeviceID, media: MediaID,
         message: V2MediaMessageLocation, route: V2RoomShardRoute) throws {
        guard let actorUUID = actor.uuidValue, let deviceUUID = device.uuidValue,
              let mediaUUID = media.uuidValue, let roomUUID = message.roomID.uuidValue,
              let messageUUID = message.messageID.uuidValue else {
            throw V2MediaStoreError.downloadNotAuthorized
        }
        self.actor = actorUUID; self.device = deviceUUID; self.media = mediaUUID
        self.room = roomUUID; self.message = messageUUID; self.route = route
        self.actorID = actor; self.mediaID = media; self.roomID = message.roomID
        self.messageID = message.messageID
    }
}

private struct RoomRefMediaGuard: Sendable {
    let controlDatabase: any Database
    let rooms: any V2RoomShardRouting
    let authorization: V2ActorRoomMediaAuthorizationPort
    let context: RoomRefMediaContext
    let deadline: ContinuousClock.Instant

    func capture() async throws -> V2ActorMessageMediaVisibilitySnapshotWire {
        try await checkDevice()
        let request = V2ActorMessageMediaVisibilityWire(roomID: context.roomID,
            messageID: context.messageID, mediaID: context.mediaID, actorUserID: context.actorID)
        guard let snapshot = try await authorization.capture(request, deadline: deadline) else {
            throw V2MediaStoreError.downloadNotAuthorized
        }
        try await checkRoute()
        try await checkDevice()
        return snapshot
    }

    func recheck(_ snapshot: V2ActorMessageMediaVisibilitySnapshotWire) async throws {
        try await checkDevice()
        guard try await authorization.recheck(snapshot, actorUserID: context.actorID,
                                              deadline: deadline) else {
            throw V2MediaStoreError.downloadNotAuthorized
        }
        try await checkRoute()
        try await checkDevice()
    }

    private func checkRoute() async throws {
        let current: V2RoomShardRoute
        do { current = try await rooms.route(for: context.roomID) }
        catch V2RoomShardRouteError.roomNotFound { throw V2MediaStoreError.downloadNotAuthorized }
        guard current == context.route else { throw V2MediaStoreError.downloadNotAuthorized }
    }

    private func checkDevice() async throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
        }
        guard let sql = controlDatabase as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard try await sql.raw("""
            SELECT 1 FROM im_v2.auth_devices AS device
            JOIN im_v2.public_user_profiles AS profile ON profile.user_id = device.user_id AND profile.state = 'active'
            WHERE device.user_id = \(bind: context.actor) AND device.device_id = \(bind: context.device)
              AND device.revoked_at IS NULL AND device.session_expires_at > clock_timestamp()
              AND NOT EXISTS (SELECT 1 FROM im_v2.account_disables WHERE user_id = device.user_id)
            """).first() != nil else { throw V2MediaStoreError.downloadNotAuthorized }
    }
}

/// Only the scoped grant lifecycle touches owner SQL. RoomRef and control
/// checks finish before every owner transaction, so no SQL lock spans a room turn.
private struct RoomRefMediaSessions: V2MediaDownloadSessionStore {
    let owner: any Database
    let context: RoomRefMediaContext
    let guardrail: RoomRefMediaGuard
    let snapshot: V2ActorMessageMediaVisibilitySnapshotWire

    func issue(now: Date, expiresAt: Date) async throws -> V2MediaDownloadGrant {
        guard v2PostgresTimestampPrecedes(now, expiresAt) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        try await guardrail.recheck(snapshot)
        guard let sql = owner as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let id = UUID()
        try await sql.raw("""
            INSERT INTO im_v2.media_download_grants
                (download_session_id, media_id, user_id, device_id, expires_at, created_at,
                 message_room_id, message_id, owner_shard_id, owner_epoch)
            VALUES (\(bind: id), \(bind: context.media), \(bind: context.actor), \(bind: context.device),
                    \(bind: expiresAt), \(bind: now), \(bind: context.room), \(bind: context.message),
                    \(bind: context.route.shardID), \(bind: context.route.epoch))
            """).run()
        return .init(mediaID: context.mediaID, downloadSessionID: .init(uuid: id), expiresAt: expiresAt)
    }

    func claimDownload(requesterUserID: UserID, deviceID: DeviceID,
                       downloadSessionID: MediaDownloadSessionID, now: Date,
                       leaseDuration: TimeInterval) async throws -> V2ClaimedMediaDownload {
        guard requesterUserID.uuidValue == context.actor, deviceID.uuidValue == context.device,
              let session = downloadSessionID.uuidValue, leaseDuration.isFinite,
              leaseDuration > 0 else { throw V2MediaDownloadSessionStoreError.sessionUnavailable }
        guard let leaseExpiresAt = v2PostgresFutureTimestamp(now: now, interval: leaseDuration) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        try await guardrail.recheck(snapshot)
        guard let sql = owner as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let token = UUID()
        guard let row = try await sql.raw("""
            UPDATE im_v2.media_download_grants SET state = 'claimed', claim_token = \(bind: token),
                lease_expires_at = \(bind: leaseExpiresAt), retry_count = retry_count + 1
            WHERE download_session_id = \(bind: session) AND media_id = \(bind: context.media)
              AND user_id = \(bind: context.actor) AND device_id = \(bind: context.device)
              AND message_room_id = \(bind: context.room) AND message_id = \(bind: context.message)
              AND owner_shard_id = \(bind: context.route.shardID) AND owner_epoch = \(bind: context.route.epoch)
              AND expires_at > \(bind: now) AND retry_count < 9223372036854775807
              AND (state = 'pending' OR (state = 'claimed' AND lease_expires_at <= \(bind: now)))
            RETURNING expires_at
            """).first(decoding: RoomRefGrantExpiry.self) else {
            throw V2MediaDownloadSessionStoreError.sessionUnavailable
        }
        return .init(mediaID: context.mediaID, downloadSessionID: downloadSessionID,
                     expiresAt: row.expiresAt, claimToken: token)
    }

    func completeDownload(_ claim: V2ClaimedMediaDownload, now: Date) async throws {
        guard claim.mediaID.uuidValue == context.media, let session = claim.downloadSessionID.uuidValue else {
            throw V2MediaDownloadSessionStoreError.sessionUnavailable
        }
        guard v2PostgresTimestampCanEncode(now) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await guardrail.recheck(snapshot)
        guard let sql = owner as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        guard try await sql.raw("""
            UPDATE im_v2.media_download_grants SET state = 'consumed', redeemed_at = \(bind: now),
                claim_token = NULL, lease_expires_at = NULL
            WHERE download_session_id = \(bind: session) AND claim_token = \(bind: claim.claimToken)
              AND media_id = \(bind: context.media) AND user_id = \(bind: context.actor)
              AND device_id = \(bind: context.device) AND message_room_id = \(bind: context.room)
              AND message_id = \(bind: context.message) AND owner_shard_id = \(bind: context.route.shardID)
              AND owner_epoch = \(bind: context.route.epoch) AND state = 'claimed'
              AND lease_expires_at > \(bind: now) AND expires_at > \(bind: now)
            RETURNING download_session_id
            """).first() != nil else { throw V2MediaDownloadSessionStoreError.sessionUnavailable }
    }

    func releaseDownload(_ claim: V2ClaimedMediaDownload) async throws {
        guard claim.mediaID.uuidValue == context.media, let session = claim.downloadSessionID.uuidValue,
              let sql = owner as? any SQLDatabase else {
            throw V2MediaDownloadSessionStoreError.sessionUnavailable
        }
        try await sql.raw("""
            UPDATE im_v2.media_download_grants SET state = 'pending', claim_token = NULL,
                lease_expires_at = NULL
            WHERE download_session_id = \(bind: session) AND state = 'claimed'
              AND claim_token = \(bind: claim.claimToken)
            """).run()
    }
}

private struct RoomRefGrantExpiry: Decodable {
    let expiresAt: Date
    enum CodingKeys: String, CodingKey { case expiresAt = "expires_at" }
}
