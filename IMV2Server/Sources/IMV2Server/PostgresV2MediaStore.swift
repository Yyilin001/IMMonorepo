import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 消息附件下载授权的 PostgreSQL 实现。
///
/// 它不保存提供方地址、对象键、文件名、缩略图或访问令牌。
public struct PostgresV2MediaStore: V2MediaStore {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID

    /// 组合数据库与会话标识生成方式。
    ///
    /// - Parameters:
    ///   - database: 存放资源目录、消息引用与下载授权的数据库。
    ///   - makeUUID: 会话标识生成方式。
    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database; self.makeUUID = makeUUID
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

private struct MediaGrantExpiryRow: Decodable { let expiresAt: Date; enum CodingKeys: String, CodingKey { case expiresAt = "expires_at" } }
private func mediaUUID<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag { guard let uuid = UUID(uuidString: value.rawValue) else { throw V2MediaStoreError.mediaUnavailable }; return uuid }
