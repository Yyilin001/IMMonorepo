import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 提供方兑换边界的 PostgreSQL 栅栏实现。
///
/// 只有存储确认了已认证设备、当前成员关系、当前消息可见性与未撤回状态之后，
/// 提供方才会收到授权。
public struct PostgresV2MediaDownloadSessionStore: V2MediaDownloadSessionStore {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID

    /// 组合数据库与令牌生成方式。
    ///
    /// - Parameters:
    ///   - database: 存放下载授权与媒体可见性依据的数据库。
    ///   - makeUUID: 认领令牌生成方式，测试可注入确定性实现。
    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database
        self.makeUUID = makeUUID
    }

    /// 认领一个下载会话。
    ///
    /// 单条条件更新同时校验会话归属、设备绑定、有效期、租约资格与媒体可见性；
    /// 重试计数达到有符号 64 位上限后不再递增。
    ///
    /// - Parameters:
    ///   - requesterUserID: 请求下载的用户。
    ///   - deviceID: 发起下载的设备。
    ///   - downloadSessionID: 下载会话标识。
    ///   - now: 本次认领时刻。
    ///   - leaseDuration: 租约时长秒数，需大于零。
    /// - Returns: 已认领的下载会话。
    /// - Throws: 租约时长非正时抛出
    ///   ``V2MediaDownloadSessionStoreError/invalidRequest``；租约到期时刻不可编码或连接不支持 SQL 时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``；会话不满足条件时抛出
    ///   ``V2MediaDownloadSessionStoreError/sessionUnavailable``。
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

    /// 在提供方 I/O 完成后消费该次有效租约。
    ///
    /// 消费时会用同一可见性谓词再次校验，确保认领已经失效时不会返回可用地址。
    ///
    /// - Parameters:
    ///   - claim: 已认领的下载会话。
    ///   - now: 完成时刻。
    /// - Throws: 连接不支持 SQL、标识非法或时刻不可编码时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``；租约已失效或可见性变化时抛出
    ///   ``V2MediaDownloadSessionStoreError/sessionUnavailable``。
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

    /// 释放已认领但未消费的下载会话。
    ///
    /// - Parameter claim: 已认领的下载会话。
    /// - Throws: 连接不支持 SQL 或会话标识非法时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``。
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

/// 下载会话存储错误。
public enum V2MediaDownloadSessionStoreError: Error, Equatable, Sendable {
    /// 请求参数不满足约束。
    case invalidRequest
    /// 下载会话当前不可认领、消费或释放。
    case sessionUnavailable
}

private struct MediaDownloadGrantRow: Decodable {
    let mediaID: UUID
    let expiresAt: Date
    enum CodingKeys: String, CodingKey { case mediaID = "media_id"; case expiresAt = "expires_at" }
}

/// 把标识原始值解析为 UUID。
///
/// - Parameter value: 已校验的标识类型。
/// - Returns: 对应的 UUID。
/// - Throws: 原始值不是合法 UUID 时抛出
///   ``V2MediaDownloadSessionStoreError/sessionUnavailable``。
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
