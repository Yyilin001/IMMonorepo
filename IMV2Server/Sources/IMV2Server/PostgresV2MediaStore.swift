import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 媒体生命周期的 PostgreSQL 权威实现。
///
/// 它不保存提供方地址、对象键、文件名、缩略图或访问令牌。
public struct PostgresV2MediaStore: V2MediaStore {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID

    /// 组合数据库与会话标识生成方式。
    ///
    /// - Parameters:
    ///   - database: 存放媒体对象与上传下载授权的数据库。
    ///   - makeUUID: 会话标识生成方式。
    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database; self.makeUUID = makeUUID
    }

    /// 在同一事务内创建上传意图、媒体对象与上传授权。
    ///
    /// 先校验设备仍为有效会话，再按发起者与操作标识加锁保证幂等：
    /// 同一操作若已存在，必须与本次的媒体、内容类型、字节数和请求设备完全一致，
    /// 否则判定幂等冲突，不匹配的重试不会创建第二个媒体对象。
    ///
    /// - Parameters:
    ///   - command: 上传请求命令。
    ///   - deviceID: 发起上传的设备。
    ///   - expiresAt: 上传授权到期时刻。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 上传授权。
    /// - Throws: 设备已失效时抛出 ``V2MediaStoreError/uploadNotAuthorized``；
    ///   同一操作载荷不一致时抛出 ``V2MediaStoreError/idempotencyConflict``；
    ///   到期时刻不晚于当前时刻、连接不支持 SQL 或返回字段异常时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``。
    public func requestUpload(_ command: V2RequestMediaUploadCommand, deviceID: DeviceID, expiresAt: Date, now: Date) async throws -> V2MediaUploadGrant {
        let actor = try mediaUUID(command.actorUserID); let device = try mediaUUID(deviceID); let operation = try mediaUUID(command.operationID); let media = try mediaUUID(command.mediaID)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard try await isActiveDevice(owner: actor, device: device, on: sql) else { throw V2MediaStoreError.uploadNotAuthorized }
            let operationLockKey = "v2-media-upload-operation:" + actor.uuidString.lowercased() + ":" + operation.uuidString.lowercased()
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: operationLockKey), 0))").run()
            if let existing = try await sql.raw("SELECT media_id, content_type, byte_count, upload_session_id, expires_at, requesting_device_id FROM im_v2.media_upload_operations WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation) FOR UPDATE").first(decoding: MediaUploadOperationRow.self) {
                guard existing.mediaID == media, existing.contentType == command.contentType, existing.byteCount == command.byteCount, existing.requestingDeviceID == device else { throw V2MediaStoreError.idempotencyConflict }
                return try .init(mediaID: command.mediaID, uploadSessionID: .init(existing.uploadSessionID.uuidString), expiresAt: existing.expiresAt)
            }
            guard v2PostgresTimestampPrecedes(now, expiresAt) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let session = makeUUID()
            try await sql.raw("INSERT INTO im_v2.media_objects (media_id, owner_user_id, content_type, byte_count, state, upload_session_id, expires_at, state_updated_at, created_at) VALUES (\(bind: media), \(bind: actor), \(bind: command.contentType), \(bind: command.byteCount), 'pending_upload', \(bind: session), \(bind: expiresAt), \(bind: now), \(bind: now))").run()
            try await sql.raw("INSERT INTO im_v2.media_upload_operations (actor_user_id, operation_id, media_id, content_type, byte_count, upload_session_id, expires_at, created_at, requesting_device_id) VALUES (\(bind: actor), \(bind: operation), \(bind: media), \(bind: command.contentType), \(bind: command.byteCount), \(bind: session), \(bind: expiresAt), \(bind: now), \(bind: device))").run()
            guard let persisted = try await sql.raw("INSERT INTO im_v2.media_upload_grants (upload_session_id, media_id, user_id, device_id, content_type, byte_count, expires_at, created_at) VALUES (\(bind: session), \(bind: media), \(bind: actor), \(bind: device), \(bind: command.contentType), \(bind: command.byteCount), \(bind: expiresAt), \(bind: now)) RETURNING expires_at").first(decoding: MediaGrantExpiryRow.self) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return try .init(mediaID: command.mediaID, uploadSessionID: .init(session.uuidString), expiresAt: persisted.expiresAt)
        }
    }

    /// 创建下载授权。
    ///
    /// 每次签发都会重新评估授权：既有授权在其短时有效期内仍可使用，
    /// 但消息撤回或成员关系移除之后签发的授权会被拒绝。
    ///
    /// - Parameters:
    ///   - requesterUserID: 请求下载的用户。
    ///   - deviceID: 发起下载的设备。
    ///   - mediaID: 目标媒体标识。
    ///   - expiresAt: 下载授权到期时刻。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 下载授权。
    /// - Throws: 可见性判定不通过时抛出 ``V2MediaStoreError/downloadNotAuthorized``；
    ///   到期时刻不晚于当前时刻或持久化异常时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``。
    public func requestDownload(requesterUserID: UserID, deviceID: DeviceID, mediaID: MediaID, expiresAt: Date, now: Date) async throws -> V2MediaDownloadGrant {
        let requester = try mediaUUID(requesterUserID)
        let device = try mediaUUID(deviceID)
        let media = try mediaUUID(mediaID)
        let session = makeUUID()
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let authorized = try await V2PostgresMediaVisibilityAuthorization.isAuthorized(
                mediaID: media,
                requesterUserID: requester,
                deviceID: device,
                on: sql
            )
            guard authorized else { throw V2MediaStoreError.downloadNotAuthorized }
            guard v2PostgresTimestampPrecedes(now, expiresAt) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard let persisted = try await sql.raw("""
                INSERT INTO im_v2.media_download_grants
                    (download_session_id, media_id, user_id, device_id, expires_at, created_at)
                VALUES
                    (\(bind: session), \(bind: media), \(bind: requester), \(bind: device), \(bind: expiresAt), \(bind: now))
                RETURNING expires_at
                """).first(decoding: MediaGrantExpiryRow.self) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return try .init(mediaID: mediaID, downloadSessionID: .init(session.uuidString), expiresAt: persisted.expiresAt)
        }
    }

    /// 标记上传完成并把媒体推进到待扫描状态。
    ///
    /// - Parameters:
    ///   - ownerUserID: 媒体归属用户。
    ///   - deviceID: 发起上传的设备。
    ///   - mediaID: 目标媒体标识。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 媒体不可用或已过期时抛出
    ///   ``V2MediaStoreError/mediaUnavailable`` 或 ``V2MediaStoreError/mediaExpired``；
    ///   当前状态不允许该跃迁时抛出 ``V2MediaStoreError/invalidStateTransition``；
    ///   持久化异常时抛出 ``V2RoomWriteStoreError/corruptPersistenceState``。
    public func markUploadCompleted(ownerUserID: UserID, deviceID: DeviceID, mediaID: MediaID, now: Date) async throws {
        let media = try mediaUUID(mediaID)
        let owner = try mediaUUID(ownerUserID)
        let device = try mediaUUID(deviceID)
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let row = try await sql.raw("SELECT owner_user_id, state, expires_at, upload_session_id FROM im_v2.media_objects WHERE media_id = \(bind: media) FOR UPDATE").first(decoding: MediaStateRow.self)
            else { throw V2MediaStoreError.mediaUnavailable }
            guard row.ownerUserID == owner else { throw V2MediaStoreError.mediaUnavailable }
            guard try await isActiveDevice(owner: owner, device: device, on: sql) else { throw V2MediaStoreError.uploadNotAuthorized }
            let currentTime = try V2PostgresTimestamp(date: now)
            guard try await isCompletedUploadGrant(session: row.uploadSessionID, owner: owner, device: device, now: now, on: sql) else { throw V2MediaStoreError.uploadNotAuthorized }
            guard row.expiresAt.microseconds > currentTime.microseconds else { throw V2MediaStoreError.mediaExpired }
            guard row.state == "pending_upload" else { throw V2MediaStoreError.invalidStateTransition }
            try await sql.raw("UPDATE im_v2.media_objects SET state = 'scanning', state_updated_at = \(bind: now) WHERE media_id = \(bind: media)").run()
            try await sql.raw("INSERT INTO im_v2.media_scan_outbox (media_id, state, created_at) VALUES (\(bind: media), 'pending', \(bind: now)) ON CONFLICT (media_id) DO NOTHING").run()
        }
    }

    /// 读取媒体对象当前状态。
    ///
    /// - Parameters:
    ///   - ownerUserID: 媒体归属用户。
    ///   - deviceID: 发起查询的设备。
    ///   - mediaID: 目标媒体标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 媒体对象状态。
    /// - Throws: 媒体不存在或不属于该用户时抛出
    ///   ``V2MediaStoreError/mediaUnavailable``；持久化异常时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``。
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
                    AND authenticated_device.revoked_at IS NULL AND authenticated_device.session_expires_at > clock_timestamp()
              )
            """).first(decoding: MediaUploadStatusRow.self) else {
            throw V2MediaStoreError.uploadNotAuthorized
        }
        let currentTime = try V2PostgresTimestamp(date: now)
        guard row.expiresAt.microseconds > currentTime.microseconds else { return .expired }
        guard let state = V2MediaObjectState(databaseState: row.state) else {
            throw V2MediaStoreError.mediaUnavailable
        }
        return state
    }

    /// 记录扫描结果。
    ///
    /// - Parameters:
    ///   - mediaID: 目标媒体标识。
    ///   - passed: 扫描是否通过。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 状态不允许记录该结果时抛出
    ///   ``V2MediaStoreError/invalidStateTransition``；其余失败抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``。
    public func recordScanResult(mediaID: MediaID, passed: Bool, now: Date) async throws {
        let currentTime = try V2PostgresTimestamp(date: now)
        let media = try mediaUUID(mediaID)
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let row = try await sql.raw("SELECT owner_user_id, state, expires_at, upload_session_id FROM im_v2.media_objects WHERE media_id = \(bind: media) FOR UPDATE").first(decoding: MediaStateRow.self)
            else { throw V2MediaStoreError.mediaUnavailable }
            guard row.expiresAt.microseconds > currentTime.microseconds else { throw V2MediaStoreError.mediaExpired }
            guard row.state == "scanning" else { throw V2MediaStoreError.invalidStateTransition }
            try await sql.raw("UPDATE im_v2.media_objects SET state = \(bind: passed ? "available" : "failed"), state_updated_at = \(bind: now) WHERE media_id = \(bind: media)").run()
            try await sql.raw("UPDATE im_v2.media_scan_outbox SET state = 'completed', completed_at = \(bind: now), claim_token = NULL, lease_expires_at = NULL, next_attempt_at = NULL, paused_at = NULL WHERE media_id = \(bind: media) AND state <> 'completed'").run()
        }
    }

    /// 断言指定媒体可用于被消息引用。
    ///
    /// - Parameters:
    ///   - ownerUserID: 媒体归属用户。
    ///   - mediaIDs: 待引用的媒体标识列表。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 列表为空、存在重复或归属不符时抛出
    ///   ``V2MediaStoreError/invalidReferenceSet``；媒体不可用或未被扫描通过时抛出
    ///   ``V2MediaStoreError/mediaUnavailable``。
    public func assertAvailableForReference(ownerUserID: UserID, mediaIDs: [MediaID], now: Date) async throws {
        guard Set(mediaIDs).count == mediaIDs.count else { throw V2MediaStoreError.invalidReferenceSet }
        let owner = try mediaUUID(ownerUserID)
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        guard mediaIDs.isEmpty || v2PostgresTimestampCanEncode(now) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        for mediaID in mediaIDs {
            let media = try mediaUUID(mediaID)
            guard try await sql.raw("SELECT media_id FROM im_v2.media_objects WHERE media_id = \(bind: media) AND owner_user_id = \(bind: owner) AND state = 'available' AND expires_at > \(bind: now)").first(decoding: MediaIDRow.self) != nil else { throw V2MediaStoreError.mediaUnavailable }
        }
    }

    private func transition(mediaID: MediaID, expected: String, next: String, owner: UserID?, now: Date) async throws {
        let currentTime = try V2PostgresTimestamp(date: now)
        let media = try mediaUUID(mediaID); let ownerUUID = try owner.map(mediaUUID)
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let row = try await sql.raw("SELECT owner_user_id, state, expires_at, upload_session_id FROM im_v2.media_objects WHERE media_id = \(bind: media) FOR UPDATE").first(decoding: MediaStateRow.self)
            else { throw V2MediaStoreError.mediaUnavailable }
            guard ownerUUID == nil || row.ownerUserID == ownerUUID else { throw V2MediaStoreError.mediaUnavailable }
            guard row.expiresAt.microseconds > currentTime.microseconds else { throw V2MediaStoreError.mediaExpired }
            guard row.state == expected else { throw V2MediaStoreError.invalidStateTransition }
            try await sql.raw("UPDATE im_v2.media_objects SET state = \(bind: next), state_updated_at = \(bind: now) WHERE media_id = \(bind: media)").run()
        }
    }

    private func isActiveDevice(owner: UUID, device: UUID, on sql: any SQLDatabase) async throws -> Bool {
        try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.auth_devices WHERE user_id = \(bind: owner) AND device_id = \(bind: device) AND revoked_at IS NULL AND session_expires_at > clock_timestamp()) AS authorized").first(decoding: MediaUploadAuthorizationRow.self)?.authorized ?? false
    }

    private func isCompletedUploadGrant(session: UUID, owner: UUID, device: UUID, now: Date, on sql: any SQLDatabase) async throws -> Bool {
        try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.media_upload_grants WHERE upload_session_id = \(bind: session) AND user_id = \(bind: owner) AND device_id = \(bind: device) AND expires_at > \(bind: now) AND state = 'consumed') AS authorized").first(decoding: MediaUploadAuthorizationRow.self)?.authorized ?? false
    }
}

/// 媒体存储错误。
public enum V2MediaStoreError: Error, Equatable, Sendable {
    /// 同一幂等操作标识已被不同载荷占用。
    case idempotencyConflict
    /// 媒体不存在、不可用或不属于调用方。
    case mediaUnavailable
    /// 媒体或其授权已过期。
    case mediaExpired
    /// 当前状态不允许请求的状态跃迁。
    case invalidStateTransition
    /// 待引用媒体集合为空、重复或归属不符。
    case invalidReferenceSet
    /// 请求者不具备下载该媒体的可见性。
    case downloadNotAuthorized
    /// 设备不具备上传资格。
    case uploadNotAuthorized
}

private struct MediaUploadOperationRow: Decodable { let mediaID: UUID; let contentType: String; let byteCount: Int64; let uploadSessionID: UUID; let expiresAt: Date; let requestingDeviceID: UUID; enum CodingKeys: String, CodingKey { case mediaID = "media_id"; case contentType = "content_type"; case byteCount = "byte_count"; case uploadSessionID = "upload_session_id"; case expiresAt = "expires_at"; case requestingDeviceID = "requesting_device_id" } }
private struct MediaStateRow: Decodable { let ownerUserID: UUID; let state: String; let expiresAt: V2PostgresTimestamp; let uploadSessionID: UUID; enum CodingKeys: String, CodingKey { case ownerUserID = "owner_user_id"; case state; case expiresAt = "expires_at"; case uploadSessionID = "upload_session_id" } }
private struct MediaIDRow: Decodable { let mediaID: UUID; enum CodingKeys: String, CodingKey { case mediaID = "media_id" } }
private struct MediaGrantExpiryRow: Decodable { let expiresAt: Date; enum CodingKeys: String, CodingKey { case expiresAt = "expires_at" } }
private struct MediaUploadAuthorizationRow: Decodable { let authorized: Bool }
private struct MediaUploadStatusRow: Decodable { let state: String; let expiresAt: V2PostgresTimestamp; enum CodingKeys: String, CodingKey { case state; case expiresAt = "expires_at" } }
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
