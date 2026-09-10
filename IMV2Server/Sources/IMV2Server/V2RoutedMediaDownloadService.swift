import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 单个房间归属所需的媒体数据库与提供方组合。
public struct V2MessageMediaOwner: Sendable {
    /// 归属侧数据库。
    let database: any Database
    /// 归属侧媒体提供方。
    let provider: any V2MediaObjectProvider

    /// 组合数据库与提供方。
    ///
    /// - Parameters:
    ///   - database: 归属侧数据库。
    ///   - provider: 归属侧媒体提供方。
    public init(database: any Database, provider: any V2MediaObjectProvider) {
        self.database = database; self.provider = provider
    }
}

/// 按消息定位房间归属的媒体下载服务。
///
/// 消息定位符用于选择已持久化的房间归属；个人投递路径在路由后的用户存储上校验，
/// 设备权威仍留在控制面。
public struct V2RoutedMediaDownloadService: V2MediaDownloadTargetResolving {
    private let legacy: V2MediaEdgeDownloadService
    private let rooms: any V2RoomShardRouting
    private let owners: [String: V2MessageMediaOwner]
    private let authorization: MessageMediaAuthorization
    private let now: @Sendable () -> Date

    /// 组合兼容路径、路由来源与各归属端点。
    ///
    /// - Parameters:
    ///   - legacy: 无消息定位符时使用的兼容下载服务。
    ///   - rooms: 房间归属路由来源。
    ///   - owners: 逻辑分片标识到归属端点的映射。
    ///   - userRoutes: 用户归属栅栏。
    ///   - userStores: 用户归属存储解析器。
    ///   - coLocatedControlBuckets: 与控制库同库部署、需复用栅栏连接的归属桶。
    ///   - now: 可注入的当前时刻读取函数。
    public init(legacy: V2MediaEdgeDownloadService, rooms: any V2RoomShardRouting,
                owners: [String: V2MessageMediaOwner], userRoutes: any V2UserShardRouteFencing,
                userStores: any V2UserShardStorageResolving, coLocatedControlBuckets: Set<String> = [],
                now: @escaping @Sendable () -> Date = Date.init) {
        self.legacy = legacy; self.rooms = rooms; self.owners = owners; self.now = now
        authorization = .init(userRoutes: userRoutes, userStores: userStores, coLocatedControlBuckets: coLocatedControlBuckets)
    }

    /// 解析媒体下载目标。
    ///
    /// 未给出消息定位符时直接走兼容路径；给出时先解析房间归属，若房间不存在则按未授权处理，
    /// 归属未配置则返回消息归属不可用。授权通过后签发下载会话并兑换提供方目标，
    /// 返回前再次确认目标未过期。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起下载的用户。
    ///   - deviceID: 发起下载的设备。
    ///   - mediaID: 目标媒体标识。
    ///   - message: 媒体所属消息位置。
    /// - Returns: 提供方对象目标。
    /// - Throws: 房间不存在或授权不通过时抛出
    ///   ``V2MediaStoreError/downloadNotAuthorized``；归属未配置时抛出
    ///   ``V2MediaEdgeHTTPHandlerError/messageOwnerUnavailable``；
    ///   时刻不可编码时抛出 ``V2RoomWriteStoreError/corruptPersistenceState``；
    ///   目标已过期时抛出 ``V2MediaProviderSessionError/expiredSession``。
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

/// 单次消息媒体访问的标识上下文。
private struct MessageMediaContext: Sendable {
    let actor: UUID; let device: UUID; let media: UUID; let room: UUID; let message: UUID; let route: V2RoomShardRoute
    /// 解析并保存标识上下文。
    ///
    /// - Parameters:
    ///   - actor: 发起访问的用户。
    ///   - device: 发起访问的设备。
    ///   - media: 目标媒体标识。
    ///   - message: 媒体所属消息位置。
    ///   - route: 已解析的房间归属。
    /// - Throws: 任一标识无法解析为 UUID 时抛出
    ///   ``V2MediaStoreError/downloadNotAuthorized``。
    init(actor: UserID, device: DeviceID, media: MediaID, message: V2MediaMessageLocation, route: V2RoomShardRoute) throws {
        guard let actor = actor.uuidValue, let device = device.uuidValue, let media = media.uuidValue,
              let room = message.roomID.uuidValue, let message = message.messageID.uuidValue
        else { throw V2MediaStoreError.downloadNotAuthorized }
        self.actor = actor; self.device = device; self.media = media; self.room = room; self.message = message; self.route = route
    }
}

/// 消息媒体访问的授权快照。
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

/// 消息媒体访问的跨存储授权逻辑。
private struct MessageMediaAuthorization: Sendable {
    let userRoutes: any V2UserShardRouteFencing
    let userStores: any V2UserShardStorageResolving
    let coLocatedControlBuckets: Set<String>

    /// 在用户切栅栏内执行归属事务操作。
    ///
    /// 唯一的跨存储事务栅栏是既有的有界用户切栅栏，且此处不进行任何提供方 I/O。
    /// 房间事实先于用户证明读取，随后在本地锁下比对，避免退群重入或编辑竞态把
    /// 互不兼容的授权拼接在一起。
    ///
    /// - Parameters:
    ///   - owner: 房间归属数据库。
    ///   - context: 访问标识上下文。
    ///   - operation: 在归属事务内执行的操作。
    /// - Returns: 操作结果。
    /// - Throws: 设备无效、授权不通过或快照在加锁后发生变化时抛出
    ///   ``V2MediaStoreError/downloadNotAuthorized``；
    ///   连接不支持 SQL 时抛出 ``V2RoomWriteStoreError/corruptPersistenceState``。
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

    /// 校验设备仍为有效会话且账号未停用。
    ///
    /// - Parameters:
    ///   - context: 访问标识上下文。
    ///   - sql: 控制面数据库连接。
    /// - Throws: 设备无效、资料未生效或账号已停用时抛出
    ///   ``V2MediaStoreError/downloadNotAuthorized``。
    private func checkDevice(_ context: MessageMediaContext, sql: any SQLDatabase) async throws {
        guard try await sql.raw("""
            SELECT 1 FROM im_v2.auth_devices AS device
            JOIN im_v2.public_user_profiles AS profile ON profile.user_id = device.user_id AND profile.state = 'active'
            WHERE device.user_id = \(bind: context.actor) AND device.device_id = \(bind: context.device) AND device.revoked_at IS NULL AND device.session_expires_at > clock_timestamp()
              AND NOT EXISTS (SELECT 1 FROM im_v2.account_disables WHERE user_id = device.user_id)
            """).first() != nil else { throw V2MediaStoreError.downloadNotAuthorized }
    }

    /// 读取消息媒体授权快照。
    ///
    /// 锁定读取时会对房间行加共享锁，并在消息与媒体行上追加共享锁，
    /// 使加锁前后的快照可以在同一事务内精确比对。
    ///
    /// - Parameters:
    ///   - context: 访问标识上下文。
    ///   - sql: 归属数据库连接。
    ///   - locking: 是否加共享锁。
    /// - Returns: 授权快照。
    /// - Throws: 消息不可见、归属不符、媒体不可用或引用已撤销时抛出
    ///   ``V2MediaStoreError/downloadNotAuthorized``。
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

/// 与媒体归属一同存放的范围化授权。
///
/// 授权只包含身份与作用域，绝不包含提供方地址。签发、认领与最终消费三个阶段都会重复
/// 控制面设备校验，包括在等待提供方签名返回之后。
private struct MessageMediaSessions: V2MediaDownloadSessionStore {
    let owner: any Database
    let context: MessageMediaContext
    let authorization: MessageMediaAuthorization

    /// 签发下载会话。
    ///
    /// - Parameters:
    ///   - now: 签发时刻。
    ///   - expiresAt: 会话到期时刻，需晚于签发时刻。
    /// - Returns: 下载授权。
    /// - Throws: 到期时刻不晚于当前时刻时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``；其余错误来自授权流程。
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

    /// 认领下载会话。
    ///
    /// 条件更新要求会话标识、媒体、用户、设备、消息位置与房间归属全部匹配，
    /// 且会话未过期；重试计数达到有符号 64 位上限后不再递增。
    ///
    /// - Parameters:
    ///   - requesterUserID: 请求下载的用户。
    ///   - deviceID: 发起下载的设备。
    ///   - downloadSessionID: 下载会话标识。
    ///   - now: 本次认领时刻。
    ///   - leaseDuration: 租约时长秒数。
    /// - Returns: 已认领的下载会话。
    /// - Throws: 参数与上下文不符、租约时长非法或会话不可认领时抛出
    ///   ``V2MediaDownloadSessionStoreError/sessionUnavailable``；
    ///   租约到期时刻不可编码时抛出 ``V2RoomWriteStoreError/corruptPersistenceState``。
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

    /// 消费已认领的下载会话。
    ///
    /// - Parameters:
    ///   - claim: 已认领的下载会话。
    ///   - now: 完成时刻。
    /// - Throws: 时刻不可编码时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``；租约已失效时抛出
    ///   ``V2MediaDownloadSessionStoreError/sessionUnavailable``。
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

    /// 释放已认领但未消费的下载会话。
    ///
    /// - Parameter claim: 已认领的下载会话。
    /// - Throws: 参数与上下文不符或连接不支持 SQL 时抛出
    ///   ``V2MediaDownloadSessionStoreError/sessionUnavailable``。
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
