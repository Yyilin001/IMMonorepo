import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import SQLKit

/// 房间日志是权威副本时，被 @ 成员的**通知**活动标识。
///
/// 该活动由规范 schema 预置为 `enabled`；真正能不能发出去由按设备、按窗口的预算决定，
/// 预算缺失时消费侧只会把唤醒标记为 `suppressed`，不会报错也不会阻塞消息接受。
let v2MentionPushWakeCampaignID = "mention_wake"

/// 一次提及通知入队的上限。
enum V2MentionPushWakeLimits {
    /// 单条消息最多通知的被 @ 成员数；与命令侧提及上限同量级。
    static let maximumMentionedUsers = 32
    /// 单个成员最多通知的设备数，按最近活跃排序取前若干台。
    static let maximumDevicesPerUser = 5
}

/// 为被 @ 的成员入队推送唤醒。
///
/// 这些唤醒是**通知**，不是投递：内容仍然只存在于房间事件日志里，成员靠房间游标恢复。
/// 因此这里刻意不创建任何逐用户投递行，也不参与消息是否已送达的判定。
///
/// 入队与消息接受在同一事务内完成：事件不存在时引用它的唤醒也不可能存在（外键保证）。
/// 预算或活动不可用时由消费侧抑制，不影响消息本身。
///
/// - Parameters:
///   - sourceEventID: 承载提及的房间事件标识，必须已在本事务内提交。
///   - mentionedUserIDs: 被 @ 的用户标识，已由调用方去重并排除发送者。
///   - now: 服务端统一授时时刻，同时用于推导预算窗口。
///   - sql: 消息接受事务使用的数据库句柄。
/// - Returns: 实际入队的唤醒条数；活动缺失或全部设备不可用时为 0。
/// - Throws: SQL 执行失败时抛出。
@discardableResult
func v2EnqueueMentionPushWakes(
    sourceEventID: UUID,
    mentionedUserIDs: [UUID],
    now: Date,
    sql: any SQLDatabase
) async throws -> Int {
    guard !mentionedUserIDs.isEmpty, v2PostgresTimestampCanEncode(now) else { return 0 }
    let targets = Array(mentionedUserIDs.prefix(V2MentionPushWakeLimits.maximumMentionedUsers))
    let rows = try await sql.raw("""
        WITH campaign AS (
            SELECT campaign_id FROM im_v2.push_campaigns
            WHERE campaign_id = \(bind: v2MentionPushWakeCampaignID) AND state = 'enabled'
        ),
        ranked_device AS (
            SELECT device.user_id, device.device_id,
                   ROW_NUMBER() OVER (
                       PARTITION BY device.user_id
                       ORDER BY device.last_active_at DESC, device.device_id
                   ) AS device_rank
            FROM im_v2.auth_devices AS device
            WHERE device.user_id = ANY(\(bind: targets)::uuid[])
              AND device.revoked_at IS NULL
              AND device.session_expires_at > \(bind: now)
              AND NOT EXISTS (
                  SELECT 1 FROM im_v2.account_disables AS disabled
                  WHERE disabled.user_id = device.user_id
              )
        )
        INSERT INTO im_v2.push_wake_outbox
            (dispatch_id, source_event_id, target_user_id, target_device_id, campaign_id,
             budget_window_started_at, requires_new_key_operation, created_at)
        SELECT gen_random_uuid(), \(bind: sourceEventID), device.user_id, device.device_id,
               campaign.campaign_id, date_trunc('hour', \(bind: now)), FALSE, \(bind: now)
        FROM ranked_device AS device
        JOIN campaign ON TRUE
        WHERE device.device_rank <= \(bind: V2MentionPushWakeLimits.maximumDevicesPerUser)
        ON CONFLICT (dispatch_id) DO NOTHING
        RETURNING dispatch_id
        """).all(decoding: MentionWakeRow.self)
    return rows.count
}

private struct MentionWakeRow: Decodable {
    let dispatchID: UUID
    enum CodingKeys: String, CodingKey { case dispatchID = "dispatch_id" }
}
