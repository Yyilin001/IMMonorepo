import FluentKit
import Foundation
import SQLKit

/// 媒体可见性授权判定的 PostgreSQL 实现。
///
/// 此路径只授权消息附件；头像由资料展示服务签发独立的展示租约与下载能力。
/// 共享状态、旧个人副本或媒体标识本身不构成授权；每次签发和兑换都重新检查。
enum V2PostgresMediaVisibilityAuthorization {
    /// 判断请求者是否有权访问指定媒体。
    ///
    /// - Parameters:
    ///   - mediaID: 目标媒体标识。
    ///   - requesterUserID: 请求者用户。
    ///   - deviceID: 请求者设备，需为未吊销且会话有效的设备。
    ///   - sql: 当前事务使用的数据库连接。
    /// - Returns: 满足可见性谓词时为 `true`；查询无结果时按不可见处理。
    /// - Throws: SQL 执行失败时抛出。
    static func isAuthorized(
        mediaID: UUID,
        requesterUserID: UUID,
        deviceID: UUID,
        on sql: any SQLDatabase
    ) async throws -> Bool {
        let predicate = predicate(
            mediaID: "\(bind: mediaID)",
            requesterUserID: requesterUserID,
            deviceID: deviceID
        )
        return try await sql.raw("""
            SELECT \(predicate) AS authorized
            """).first(decoding: MediaVisibilityAuthorizationRow.self)?.authorized ?? false
    }

    /// 只读校验与原子授权认领共用的 SQL 谓词。
    ///
    /// 媒体表达式由受信服务端代码拼接，所有受调用方控制的标识仍以绑定参数传入。
    ///
    /// 谓词要求：资源已登记且当前代次可用、设备有效且账号未停用；
    /// 消息引用路径要求消息未撤回、引用未撤销、请求者在消息接受修订与当前修订下都具备成员资格，
    /// 并且请求者对当前正文修订具有历史访问权限。
    ///
    /// - Parameters:
    ///   - mediaID: 已拼装的媒体标识表达式，通常为绑定参数。
    ///   - requesterUserID: 请求者用户。
    ///   - deviceID: 请求者设备。
    /// - Returns: 可直接嵌入查询的可见性谓词。
    static func predicate(
        mediaID: SQLQueryString,
        requesterUserID: UUID,
        deviceID: UUID
    ) -> SQLQueryString {
        """
            EXISTS (
                SELECT 1
                FROM im_v2.media_objects AS media
                WHERE media.media_id = \(mediaID)
                  AND media.state = 'available'
                  AND EXISTS (
                      SELECT 1
                      FROM im_v2.auth_devices AS authenticated_device
                      JOIN im_v2.public_user_profiles AS authenticated_profile
                        ON authenticated_profile.user_id = authenticated_device.user_id
                       AND authenticated_profile.state = 'active'
                      WHERE authenticated_device.user_id = \(bind: requesterUserID)
                        AND authenticated_device.device_id = \(bind: deviceID)
                        AND authenticated_device.revoked_at IS NULL AND authenticated_device.session_expires_at > clock_timestamp()
                        AND NOT EXISTS (
                            SELECT 1 FROM im_v2.account_disables AS disabled
                            WHERE disabled.user_id = authenticated_device.user_id
                        )
                  )
                  AND (
                      EXISTS (
                          SELECT 1
                          FROM im_v2.message_media_references AS reference
                          JOIN im_v2.messages AS message
                            ON message.message_id = reference.message_id
                          JOIN im_v2.rooms AS room
                            ON room.room_id = message.room_id
                          JOIN im_v2.resource_catalog AS resource
                            ON resource.media_id = media.media_id
                           AND resource.home_kind = 'room' AND resource.home_id = room.room_id
                           AND resource.usage_kind = 'message_attachment'
                          JOIN im_v2.resource_blob_placements AS placement
                            ON placement.media_id = resource.media_id AND placement.generation = resource.generation
                           AND placement.state = 'active'
                          WHERE reference.media_id = media.media_id
                            AND message.withdrawn_at IS NULL
                            AND reference.revoked_at IS NULL
                            AND (\(v2ForwardSourceVisibility(actorID: requesterUserID)))
                      )
                  )
            )
            """
    }
}

private struct MediaVisibilityAuthorizationRow: Decodable {
    let authorized: Bool
}
