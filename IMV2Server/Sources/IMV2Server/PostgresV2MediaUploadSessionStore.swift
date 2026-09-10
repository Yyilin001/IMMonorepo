import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 上传目标兑换的 PostgreSQL 栅栏实现。
///
/// 上传会话既绑定用户与设备，也是一次性的：单条条件更新会同时校验归属、设备状态、
/// 媒体状态、有效期与租约资格，全部满足后才完成认领。
public struct PostgresV2MediaUploadSessionStore: V2MediaUploadSessionStore {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID

    /// 组合数据库与令牌生成方式。
    ///
    /// - Parameters:
    ///   - database: 存放上传授权与媒体对象的数据库。
    ///   - makeUUID: 认领令牌生成方式，测试可注入确定性实现。
    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database
        self.makeUUID = makeUUID
    }

    /// 认领一个上传会话以兑换提供方目标。
    ///
    /// 认领成功时会把授权置为已认领、写入租约并递增重试计数；重试计数达到
    /// 有符号 64 位上限后不再递增，避免溢出。
    ///
    /// - Parameters:
    ///   - ownerUserID: 会话归属用户。
    ///   - deviceID: 发起兑换的设备。
    ///   - uploadSessionID: 上传会话标识。
    ///   - now: 本次认领时刻。
    ///   - leaseDuration: 租约时长秒数，需大于零。
    /// - Returns: 已认领的上传会话。
    /// - Throws: 租约时长非正时抛出
    ///   ``V2MediaUploadSessionStoreError/invalidRequest``；租约到期时刻不可编码或连接不支持 SQL 时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``；会话不满足归属、设备、状态或时效条件时抛出
    ///   ``V2MediaUploadSessionStoreError/sessionUnavailable``。
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

    /// 将已认领的上传会话标记为已消费。
    ///
    /// 会话必须仍归属于同一认领令牌、未过期，且设备与媒体状态仍然有效。
    ///
    /// - Parameters:
    ///   - claim: 已认领的上传会话。
    ///   - now: 完成时刻。
    /// - Throws: 时刻不可编码或连接不支持 SQL 时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``；会话不满足条件时抛出
    ///   ``V2MediaUploadSessionStoreError/sessionUnavailable``。
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

    /// 释放已认领但未消费的上传会话，使其回到待认领状态。
    ///
    /// - Parameter claim: 已认领的上传会话。
    /// - Throws: 连接不支持 SQL 或会话标识非法时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``。
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

/// 上传会话存储错误。
public enum V2MediaUploadSessionStoreError: Error, Equatable, Sendable {
    /// 请求参数不满足约束。
    case invalidRequest
    /// 上传会话当前不可认领、消费或释放。
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

/// 把标识原始值解析为 UUID。
///
/// - Parameter value: 已校验的标识类型。
/// - Returns: 对应的 UUID。
/// - Throws: 原始值不是合法 UUID 时抛出
///   ``V2MediaUploadSessionStoreError/sessionUnavailable``。
private func uploadUUID<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let uuid = UUID(uuidString: value.rawValue) else { throw V2MediaUploadSessionStoreError.sessionUnavailable }
    return uuid
}
