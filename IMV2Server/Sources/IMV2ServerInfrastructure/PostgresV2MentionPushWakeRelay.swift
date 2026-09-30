import FluentKit
import Foundation
import IMV2ServerApplication
import IMV2ServerContracts
import SQLKit

/// 将房间所有者的通知意图转交控制域。两次提交之间崩溃时，控制回执保证不重复解析设备。
/// 源认领事务先提交再访问控制库，因此同库单连接部署也不会嵌套占用连接。
public struct PostgresV2MentionPushWakeRelay: Sendable {
    private let owner: any Database
    private let control: any Database
    private let enabled: Bool

    public init(owner: any Database, control: any Database, enabled: Bool = true) {
        self.owner = owner
        self.control = control
        self.enabled = enabled
    }

    @discardableResult
    public func runOnce(now: Date, limit: Int) async throws -> Int {
        guard limit > 0, v2PostgresTimestampCanEncode(now),
              let expiry = v2PostgresFutureTimestamp(now: now, interval: 30),
              let ownerSQL = owner as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let token = UUID()
        let intents = try await owner.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return try await sql.raw("""
                WITH candidates AS (
                    SELECT source_event_id, target_user_id
                    FROM im_v2.mention_push_wake_intents
                    WHERE lease_expires_at IS NULL OR lease_expires_at <= \(bind: now)
                    ORDER BY created_at, source_event_id, target_user_id
                    LIMIT \(bind: limit) FOR UPDATE SKIP LOCKED
                )
                UPDATE im_v2.mention_push_wake_intents AS intent
                SET claim_token = \(bind: token), lease_expires_at = \(bind: expiry)
                FROM candidates
                WHERE intent.source_event_id = candidates.source_event_id
                  AND intent.target_user_id = candidates.target_user_id
                RETURNING intent.source_event_id, intent.room_id, intent.target_user_id, intent.created_at
                """).all(decoding: MentionRelayRow.self)
        }
        for intent in intents {
            try Task.checkCancellation()
            do {
                if enabled && intent.createdAt > now.addingTimeInterval(-V2MentionPushWakeLimits.lifetime) {
                    try await transfer(intent, now: now)
                }
                try await ownerSQL.raw("""
                    DELETE FROM im_v2.mention_push_wake_intents
                    WHERE source_event_id = \(bind: intent.sourceEventID)
                      AND target_user_id = \(bind: intent.targetUserID)
                      AND claim_token = \(bind: token)
                    """).run()
            } catch {
                try? await ownerSQL.raw("""
                    UPDATE im_v2.mention_push_wake_intents SET claim_token = NULL, lease_expires_at = NULL
                    WHERE source_event_id = \(bind: intent.sourceEventID)
                      AND target_user_id = \(bind: intent.targetUserID) AND claim_token = \(bind: token)
                    """).run()
                throw error
            }
        }
        return intents.count
    }

    private func transfer(_ intent: MentionRelayRow, now: Date) async throws {
        try await control.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            // 回执与设备唤醒原子提交。即使源端删除失败，重放也不增加设备数或续期通知。
            let inserted = try await sql.raw("""
                INSERT INTO im_v2.mention_push_wake_receipts (source_event_id, target_user_id, recorded_at)
                VALUES (\(bind: intent.sourceEventID), \(bind: intent.targetUserID), \(bind: now))
                ON CONFLICT (source_event_id, target_user_id) DO NOTHING
                RETURNING source_event_id
                """).first(decoding: MentionRelayReceiptRow.self)
            guard inserted != nil else { return }
            try await sql.raw("""
                WITH campaign AS (
                    SELECT campaign_id FROM im_v2.push_campaigns
                    WHERE campaign_id = \(bind: v2MentionPushWakeCampaignID) AND state = 'enabled'
                ), devices AS (
                    SELECT device_id FROM im_v2.auth_devices
                    WHERE user_id = \(bind: intent.targetUserID) AND revoked_at IS NULL
                      AND session_expires_at > \(bind: now)
                      AND NOT EXISTS (SELECT 1 FROM im_v2.account_disables
                          WHERE user_id = \(bind: intent.targetUserID))
                    ORDER BY last_active_at DESC, device_id
                    LIMIT \(bind: V2MentionPushWakeLimits.maximumDevicesPerUser)
                )
                INSERT INTO im_v2.push_wake_outbox
                    (dispatch_id, source_event_id, source_room_id, target_user_id, target_device_id,
                     campaign_id, budget_window_started_at, requires_new_key_operation, created_at)
                SELECT gen_random_uuid(), \(bind: intent.sourceEventID), \(bind: intent.roomID),
                       \(bind: intent.targetUserID), devices.device_id, campaign.campaign_id,
                       date_trunc('hour', \(bind: intent.createdAt)), FALSE, \(bind: intent.createdAt)
                FROM devices JOIN campaign ON TRUE
                """).run()
        }
    }
}

private struct MentionRelayRow: Decodable, Sendable {
    let sourceEventID: UUID
    let roomID: UUID
    let targetUserID: UUID
    let createdAt: Date
    enum CodingKeys: String, CodingKey {
        case sourceEventID = "source_event_id", roomID = "room_id"
        case targetUserID = "target_user_id", createdAt = "created_at"
    }
}
private struct MentionRelayReceiptRow: Decodable {
    let sourceEventID: UUID
    enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id" }
}
