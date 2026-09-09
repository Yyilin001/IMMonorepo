import Fluent
import Foundation
import IMV2Core
import SQLKit

public struct V2MessageMediaOwner: Sendable {
    let database: any Database
    let provider: any V2MediaObjectProvider
    public init(database: any Database, provider: any V2MediaObjectProvider) {
        self.database = database; self.provider = provider
    }
}

/// A message locator chooses the persisted room owner. Personal delivery is
/// checked on the routed user store; device authority stays on control.
public struct V2RoutedMediaDownloadService: V2MediaDownloadTargetResolving {
    private let legacy: V2MediaEdgeDownloadService
    private let rooms: any V2RoomShardRouting
    private let owners: [String: V2MessageMediaOwner]
    private let authorization: MessageMediaAuthorization
    private let now: @Sendable () -> Date

    public init(legacy: V2MediaEdgeDownloadService, rooms: any V2RoomShardRouting,
                owners: [String: V2MessageMediaOwner], userRoutes: any V2UserShardRouteFencing,
                userStores: any V2UserShardStorageResolving, coLocatedControlBuckets: Set<String> = [],
                now: @escaping @Sendable () -> Date = Date.init) {
        self.legacy = legacy; self.rooms = rooms; self.owners = owners; self.now = now
        authorization = .init(userRoutes: userRoutes, userStores: userStores, coLocatedControlBuckets: coLocatedControlBuckets)
    }

    public func downloadTarget(actorUserID: UserID, deviceID: DeviceID, mediaID: MediaID, message: V2MediaMessageLocation?) async throws -> V2MediaProviderObjectTarget {
        guard let message else { return try await legacy.downloadTarget(actorUserID: actorUserID, deviceID: deviceID, mediaID: mediaID) }
        try Task.checkCancellation()
        let route: V2RoomShardRoute
        do { route = try await rooms.route(for: message.roomID) }
        catch V2RoomShardRouteError.roomNotFound { throw V2MediaStoreError.downloadNotAuthorized }
        guard let owner = owners[route.shardID] else { throw V2MediaEdgeHTTPHandlerError.messageOwnerUnavailable }
        let context = try MessageMediaContext(actor: actorUserID, device: deviceID, media: mediaID, message: message, route: route)
        let store = MessageMediaSessions(owner: owner.database, context: context, authorization: authorization)
        let instant = now()
        guard let expiry = v2PostgresFutureTimestamp(now: instant, interval: V2MediaDownloadLimits.standard.grantLifetime) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let grant = try await store.issue(now: instant, expiresAt: expiry)
        let sessions = try V2MediaProviderSessionService(store: store, provider: owner.provider, now: now)
        let target = try await sessions.exchangeDownload(actorUserID: actorUserID, deviceID: deviceID, downloadSessionID: grant.downloadSessionID)
        let returnedAt = now()
        guard v2PostgresTimestampCanEncode(returnedAt) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        guard target.expiresAt > returnedAt else { throw V2MediaProviderSessionError.expiredSession }
        return target
    }
}

private struct MessageMediaContext: Sendable {
    let actor: UUID; let device: UUID; let media: UUID; let room: UUID; let message: UUID; let route: V2RoomShardRoute
    init(actor: UserID, device: DeviceID, media: MediaID, message: V2MediaMessageLocation, route: V2RoomShardRoute) throws {
        guard let actor = actor.uuidValue, let device = device.uuidValue, let media = media.uuidValue,
              let room = message.roomID.uuidValue, let message = message.messageID.uuidValue
        else { throw V2MediaStoreError.downloadNotAuthorized }
        self.actor = actor; self.device = device; self.media = media; self.room = room; self.message = message; self.route = route
    }
}

private struct MessageMediaSnapshot: Decodable, Equatable, Sendable {
    let membershipRevision: Int64
    let contentRevision: Int64
    let mediaUpdatedAt: Date
    let uploadSessionID: UUID
    let authority: String
    enum CodingKeys: String, CodingKey {
        case membershipRevision = "membership_revision", contentRevision = "content_revision"
        case mediaUpdatedAt = "state_updated_at", uploadSessionID = "upload_session_id", authority
    }
}

private struct MessageMediaAuthorization: Sendable {
    let userRoutes: any V2UserShardRouteFencing
    let userStores: any V2UserShardStorageResolving
    let coLocatedControlBuckets: Set<String>

    /// The only cross-store transaction fence is the existing bounded user
    /// cutover fence. No provider I/O runs here. Room facts are read before the
    /// user proof and compared under local locks afterwards, preventing a
    /// leave/rejoin or edit race from combining incompatible authorizations.
    func withOwner<Result: Sendable>(owner: any Database, context: MessageMediaContext,
        operation: @escaping @Sendable (any SQLDatabase) async throws -> Result) async throws -> Result {
        try Task.checkCancellation()
        return try await userRoutes.withCurrentRoute(for: .init(uuid: context.actor)) { route, control in
            guard let controlSQL = control as? any SQLDatabase, let ownerSQL = owner as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await checkDevice(context, sql: controlSQL)
            let before = try await snapshot(context, sql: ownerSQL, locking: false)
            if before.authority == "personal" {
                let location = try userStores.location(for: route.bucket)
                let userDB = coLocatedControlBuckets.contains(route.bucket) ? control : location.database
                guard let userSQL = userDB as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
                let prefix = location.schema
                guard try await userSQL.raw("""
                    SELECT 1 FROM \(unsafeRaw: prefix).user_projection_versions AS delivery
                    LEFT JOIN \(unsafeRaw: prefix).message_projection_state_values AS state ON state.state_id = delivery.message_state_id
                    WHERE delivery.user_id = \(bind: context.actor) AND delivery.projection_kind = 'message'
                      AND delivery.entity_key IN (\(bind: context.message.uuidString.lowercased()), \(bind: context.message.uuidString))
                      AND delivery.scope_room_id = \(bind: context.room) AND delivery.valid_to_sequence IS NULL
                      AND COALESCE(state.payload, delivery.payload)->>'event_type' = 'message.accepted'
                      AND lower(COALESCE(state.payload, delivery.payload)->>'room_id') = \(bind: context.room.uuidString.lowercased())
                      AND lower(COALESCE(state.payload, delivery.payload)->>'message_id') = \(bind: context.message.uuidString.lowercased())
                      AND COALESCE(COALESCE(state.payload, delivery.payload)->>'message_revision', '1') = \(bind: String(before.contentRevision))
                      AND COALESCE((COALESCE(state.payload, delivery.payload)->>'is_withdrawn')::boolean, FALSE) = FALSE
                      AND (COALESCE(state.payload, delivery.payload)->'media_ids' @> jsonb_build_array(\(bind: context.media.uuidString.lowercased())::text)
                        OR COALESCE(state.payload, delivery.payload)->'media_ids' @> jsonb_build_array(\(bind: context.media.uuidString)::text))
                    """).first() != nil else { throw V2MediaStoreError.downloadNotAuthorized }
            } else if before.authority != "room_log" { throw V2MediaStoreError.downloadNotAuthorized }
            try await checkDevice(context, sql: controlSQL)
            try Task.checkCancellation()
            return try await owner.transaction { transaction in
                guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
                let after = try await snapshot(context, sql: sql, locking: true)
                guard after == before else { throw V2MediaStoreError.downloadNotAuthorized }
                return try await operation(sql)
            }
        }
    }

    private func checkDevice(_ context: MessageMediaContext, sql: any SQLDatabase) async throws {
        guard try await sql.raw("""
            SELECT 1 FROM im_v2.auth_devices AS device
            JOIN im_v2.public_user_profiles AS profile ON profile.user_id = device.user_id AND profile.state = 'active'
            WHERE device.user_id = \(bind: context.actor) AND device.device_id = \(bind: context.device) AND device.revoked_at IS NULL AND device.session_expires_at > clock_timestamp()
              AND NOT EXISTS (SELECT 1 FROM im_v2.account_disables WHERE user_id = device.user_id)
            """).first() != nil else { throw V2MediaStoreError.downloadNotAuthorized }
    }

    private func snapshot(_ context: MessageMediaContext, sql: any SQLDatabase, locking: Bool) async throws -> MessageMediaSnapshot {
        if locking {
            _ = try await sql.raw("SELECT room_id FROM im_v2.rooms WHERE room_id = \(bind: context.room) FOR SHARE").first()
        }
        var query: SQLQueryString = """
            SELECT room.membership_revision, message.content_revision, media.state_updated_at, media.upload_session_id,
                   COALESCE(completion.delivery_authority, 'personal') AS authority
            FROM im_v2.messages AS message
            JOIN im_v2.rooms AS room ON room.room_id = message.room_id
            JOIN im_v2.message_media_references AS reference ON reference.message_id = message.message_id
            JOIN im_v2.media_objects AS media ON media.media_id = reference.media_id
            LEFT JOIN im_v2.message_send_completions AS completion
              ON completion.room_id = message.room_id AND completion.sender_user_id = message.sender_user_id
             AND completion.client_message_id = message.client_message_id AND completion.message_id = message.message_id
            WHERE message.message_id = \(bind: context.message) AND message.room_id = \(bind: context.room)
              AND room.room_shard_id = \(bind: context.route.shardID) AND room.owner_epoch = \(bind: context.route.epoch)
              AND media.media_id = \(bind: context.media) AND media.state = 'available'
              AND reference.revoked_at IS NULL AND message.withdrawn_at IS NULL
              AND \(v2ForwardSourceVisibility(actorID: context.actor))
            """
        if locking { query += " FOR SHARE OF message, media" }
        guard let row = try await sql.raw(query).first(decoding: MessageMediaSnapshot.self) else { throw V2MediaStoreError.downloadNotAuthorized }
        return row
    }
}

/// Scoped grants live with the media owner. They contain identity and scope,
/// never provider URLs. The control-plane device check is repeated for grant,
/// claim and final consumption, including after provider signing has awaited.
private struct MessageMediaSessions: V2MediaDownloadSessionStore {
    let owner: any Database
    let context: MessageMediaContext
    let authorization: MessageMediaAuthorization

    func issue(now: Date, expiresAt: Date) async throws -> V2MediaDownloadGrant {
        guard v2PostgresTimestampPrecedes(now, expiresAt) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let id = UUID()
        return try await authorization.withOwner(owner: owner, context: context) { sql in
            try await sql.raw("""
                INSERT INTO im_v2.media_download_grants
                    (download_session_id, media_id, user_id, device_id, expires_at, created_at,
                     message_room_id, message_id, owner_shard_id, owner_epoch)
                VALUES (\(bind: id), \(bind: context.media), \(bind: context.actor), \(bind: context.device), \(bind: expiresAt), \(bind: now),
                        \(bind: context.room), \(bind: context.message), \(bind: context.route.shardID), \(bind: context.route.epoch))
                """).run()
            return .init(mediaID: .init(uuid: context.media), downloadSessionID: .init(uuid: id), expiresAt: expiresAt)
        }
    }

    func claimDownload(requesterUserID: UserID, deviceID: DeviceID, downloadSessionID: MediaDownloadSessionID, now: Date, leaseDuration: TimeInterval) async throws -> V2ClaimedMediaDownload {
        guard requesterUserID.uuidValue == context.actor, deviceID.uuidValue == context.device, let session = downloadSessionID.uuidValue,
              leaseDuration.isFinite, leaseDuration > 0 else { throw V2MediaDownloadSessionStoreError.sessionUnavailable }
        guard let leaseExpiresAt = v2PostgresFutureTimestamp(now: now, interval: leaseDuration) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let token = UUID()
        return try await authorization.withOwner(owner: owner, context: context) { sql in
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
                """).first(decoding: MessageMediaGrantExpiry.self) else { throw V2MediaDownloadSessionStoreError.sessionUnavailable }
            return .init(mediaID: .init(uuid: context.media), downloadSessionID: downloadSessionID, expiresAt: row.expiresAt, claimToken: token)
        }
    }

    func completeDownload(_ claim: V2ClaimedMediaDownload, now: Date) async throws {
        guard claim.mediaID.uuidValue == context.media, let session = claim.downloadSessionID.uuidValue else { throw V2MediaDownloadSessionStoreError.sessionUnavailable }
        guard v2PostgresTimestampCanEncode(now) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await authorization.withOwner(owner: owner, context: context) { sql in
            guard try await sql.raw("""
                UPDATE im_v2.media_download_grants SET state = 'consumed', redeemed_at = \(bind: now), claim_token = NULL, lease_expires_at = NULL
                WHERE download_session_id = \(bind: session) AND claim_token = \(bind: claim.claimToken) AND state = 'claimed'
                  AND lease_expires_at > \(bind: now) AND expires_at > \(bind: now)
                RETURNING download_session_id
                """).first() != nil else { throw V2MediaDownloadSessionStoreError.sessionUnavailable }
        }
    }

    func releaseDownload(_ claim: V2ClaimedMediaDownload) async throws {
        guard claim.mediaID.uuidValue == context.media, let session = claim.downloadSessionID.uuidValue,
              let sql = owner as? any SQLDatabase else { throw V2MediaDownloadSessionStoreError.sessionUnavailable }
        try await sql.raw("""
            UPDATE im_v2.media_download_grants SET state = 'pending', claim_token = NULL, lease_expires_at = NULL
            WHERE download_session_id = \(bind: session) AND state = 'claimed' AND claim_token = \(bind: claim.claimToken)
            """).run()
    }
}
private struct MessageMediaGrantExpiry: Decodable {
    let expiresAt: Date
    enum CodingKeys: String, CodingKey { case expiresAt = "expires_at" }
}
