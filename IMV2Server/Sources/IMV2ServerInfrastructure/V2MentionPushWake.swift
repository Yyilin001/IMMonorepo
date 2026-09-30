import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import SQLKit

let v2MentionPushWakeCampaignID = "mention_wake"

enum V2MentionPushWakeLimits {
    static let maximumMentionedUsers = 32
    static let maximumDevicesPerUser = 5
    // 通知只改善前台延迟。超过此期限仍可从房间日志恢复，不重放旧通知。
    static let lifetime: TimeInterval = 24 * 60 * 60
}

/// 与房间消息一起记录通知意图；设备和推送预算只属于控制域。
/// 意图保留独立的房间事实，不引用可被裁剪的 room_events。
@discardableResult
func v2EnqueueMentionPushWakes(
    sourceEventID: UUID,
    roomID: UUID,
    mentionedUserIDs: [UUID],
    now: Date,
    sql: any SQLDatabase
) async throws -> Int {
    guard !mentionedUserIDs.isEmpty, v2PostgresTimestampCanEncode(now) else { return 0 }
    let targets = Array(Set(mentionedUserIDs)).sorted { $0.uuidString < $1.uuidString }
        .prefix(V2MentionPushWakeLimits.maximumMentionedUsers)
    let rows = try await sql.raw("""
        INSERT INTO im_v2.mention_push_wake_intents
            (source_event_id, room_id, target_user_id, created_at)
        SELECT \(bind: sourceEventID), \(bind: roomID), target, \(bind: now)
        FROM unnest(\(bind: Array(targets))::uuid[]) AS target
        ON CONFLICT (source_event_id, target_user_id) DO NOTHING
        RETURNING source_event_id
        """).all(decoding: MentionIntentIdentityRow.self)
    return rows.count
}

private struct MentionIntentIdentityRow: Decodable {
    let sourceEventID: UUID
    enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id" }
}
