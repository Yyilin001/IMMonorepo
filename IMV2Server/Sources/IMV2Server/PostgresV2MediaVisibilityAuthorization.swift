import FluentKit
import Foundation
import SQLKit

/// 媒体可见性授权判定的 PostgreSQL 实现。
///
/// 消息附件由规范消息引用与房间访问权限授权，头像由可见资料授权。
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
    /// 谓词要求：媒对象处于可用状态、设备有效且账号未停用；随后满足其一——
    /// 消息引用路径要求消息未撤回、引用未撤销、请求者在消息接受修订与当前修订下都具备成员资格，
    /// 并且请求者对当前正文修订具有历史访问权限；
    /// 或头像路径要求资料有效、双方无拉黑，并且请求者与资料所有者存在好友、同房间等关联。
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
                          WHERE reference.media_id = media.media_id
                            AND message.withdrawn_at IS NULL
                            AND reference.revoked_at IS NULL
                            AND (\(v2ForwardSourceVisibility(actorID: requesterUserID)))
                      )
                      OR EXISTS (
                          SELECT 1
                          FROM im_v2.public_user_profiles AS profile
                          WHERE profile.avatar_media_id = media.media_id
                            AND profile.state = 'active'
                            AND NOT EXISTS (
                                SELECT 1
                                FROM im_v2.user_blocks AS block
                                WHERE (block.blocker_user_id = \(bind: requesterUserID)
                                       AND block.blocked_user_id = profile.user_id)
                                   OR (block.blocker_user_id = profile.user_id
                                       AND block.blocked_user_id = \(bind: requesterUserID))
                            )
                            AND (
                                profile.user_id = \(bind: requesterUserID)
                                OR EXISTS (
                                    SELECT 1
                                    FROM im_v2.user_relationships AS relationship
                                    WHERE relationship.state IN ('pending', 'accepted')
                                      AND ((relationship.lower_user_id = \(bind: requesterUserID)
                                            AND relationship.higher_user_id = profile.user_id)
                                        OR (relationship.higher_user_id = \(bind: requesterUserID)
                                            AND relationship.lower_user_id = profile.user_id))
                                )
                                OR EXISTS (
                                    SELECT 1
                                    FROM im_v2.rooms AS room
                                    JOIN im_v2.room_memberships AS requester_membership
                                      ON requester_membership.room_id = room.room_id
                                     AND requester_membership.user_id = \(bind: requesterUserID)
                                     AND requester_membership.joined_revision <= room.membership_revision
                                     AND (requester_membership.left_revision IS NULL OR requester_membership.left_revision > room.membership_revision)
                                    JOIN im_v2.room_memberships AS profile_membership
                                      ON profile_membership.room_id = room.room_id
                                     AND profile_membership.user_id = profile.user_id
                                     AND profile_membership.joined_revision <= room.membership_revision
                                     AND (profile_membership.left_revision IS NULL OR profile_membership.left_revision > room.membership_revision)
                                )
                            )
                      )
                  )
            )
            """
    }
}

private struct MediaVisibilityAuthorizationRow: Decodable {
    let authorized: Bool
}
