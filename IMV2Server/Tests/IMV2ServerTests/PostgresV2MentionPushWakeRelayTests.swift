@testable import IMV2ServerInfrastructure
import IMV2Core
import IMV2ServerContracts
import Foundation
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("mention notifications cross physical databases, survive trimming, and honor owner mute",
          arguments: [false, true])
    func crossStoreMentionPushRelay(muted: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, controlSQL, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let event = UUID(), device = UUID(), revokedDevice = UUID()
            let roomUUID = try #require(room.uuidValue)
            try await controlSQL.raw("""
                INSERT INTO im_v2.auth_devices (user_id,device_id,created_at,last_active_at,revoked_at)
                VALUES (\(bind: memberTwoUUID),\(bind: device),\(bind: now),\(bind: now),NULL),
                       (\(bind: memberTwoUUID),\(bind: revokedDevice),\(bind: now),\(bind: now),\(bind: now))
                """).run()
            try await controlSQL.raw("""
                INSERT INTO im_v2.push_campaigns (campaign_id,state,updated_at)
                VALUES ('mention_wake','enabled',\(bind: now));
                """).run()
            try await controlSQL.raw("""
                INSERT INTO im_v2.push_device_budgets
                    (device_id,campaign_id,window_started_at,max_work_units,max_new_key_operations)
                VALUES (\(bind: device),'mention_wake',date_trunc('hour',\(bind: now)),1,0)
                """).run()
            try await ownerSQL.raw("""
                INSERT INTO im_v2.room_events
                    (event_id,room_id,room_sequence,event_type,actor_user_id,payload,committed_membership_revision,created_at)
                VALUES (\(bind: event),\(bind: roomUUID),1,'message.accepted',\(bind: senderUUID),'{}',0,\(bind: now))
                """).run()
            #expect(try await v2EnqueueMentionPushWakes(sourceEventID: event, roomID: roomUUID,
                mentionedUserIDs: [memberTwoUUID], now: now, sql: ownerSQL) == 1)
            // 未转交通知也不能钉住房间日志；控制域的唤醒依靠独立 room_id 事实。
            try await owner.transaction { transaction in
                let sql = try #require(transaction as? any SQLDatabase)
                try await sql.raw("UPDATE im_v2.rooms SET log_trimmed_through_room_sequence=2 WHERE room_id=\(bind: roomUUID)").run()
                try await sql.raw("SET LOCAL im_v2.retention_trim='on'").run()
                try await sql.raw("DELETE FROM im_v2.room_events WHERE event_id = \(bind: event)").run()
            }
            let relay = PostgresV2MentionPushWakeRelay(owner: owner, control: control)
            #expect(try await relay.runOnce(now: now, limit: 1) == 1)
            #expect(try await count("im_v2.mention_push_wake_intents", on: ownerSQL) == 0)
            #expect(try await count("im_v2.push_wake_outbox", on: ownerSQL) == 0)
            #expect(try await count("im_v2.push_wake_outbox", on: controlSQL) == 1)
            #expect(try await count("im_v2.room_events", on: controlSQL) == 0)
            // 模拟目标提交、源删除之前崩溃：重放不重新解析刚注册的新设备。
            try await controlSQL.raw("""
                INSERT INTO im_v2.auth_devices (user_id,device_id,created_at,last_active_at)
                VALUES (\(bind: memberTwoUUID),\(bind: UUID()),\(bind: now),\(bind: now))
                """).run()
            try await v2EnqueueMentionPushWakes(sourceEventID: event, roomID: roomUUID,
                mentionedUserIDs: [memberTwoUUID], now: now, sql: ownerSQL)
            #expect(try await relay.runOnce(now: now, limit: 1) == 1)
            #expect(try await count("im_v2.push_wake_outbox", on: controlSQL) == 1)
            if muted {
                try await ownerSQL.raw("""
                    INSERT INTO im_v2.user_room_preferences (user_id,room_id,mute_until,updated_at,revision)
                    VALUES (\(bind: memberTwoUUID),\(bind: roomUUID),\(bind: now.addingTimeInterval(3600)),\(bind: now),1)
                    """).run()
            }
            let store = PostgresV2PushWakeStore(database: control, conversationMuted: { roomID, userID, time in
                try await ownerSQL.raw("""
                    SELECT EXISTS (SELECT 1 FROM im_v2.user_room_preferences
                        WHERE room_id=\(bind: roomID) AND user_id=\(bind: userID)
                          AND mute_until>\(bind: time)) AS value
                    """).first(decoding: MentionRelayBooleanRow.self)?.value == true
            })
            let leases = try await store.claimAdmitted(now: now, leaseDuration: 30, limit: 1)
            #expect(leases.count == (muted ? 0 : 1))
            let used = try #require(try await controlSQL.raw("""
                SELECT used_work_units AS value FROM im_v2.push_device_budgets WHERE device_id=\(bind: device)
                """).first(decoding: CountRow.self)).value
            #expect(used == (muted ? 0 : 1))
            // 已生成的控制通知也不持有 owner 事件外键。
            #expect(try await count("im_v2.push_wake_outbox", on: controlSQL) == 1)
        }
    }

    @Test("expired mention intents are closed without device enumeration or receipt renewal")
    func expiredMentionPushIntent() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, controlSQL, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await v2EnqueueMentionPushWakes(sourceEventID: UUID(), roomID: try #require(room.uuidValue),
                mentionedUserIDs: [memberTwoUUID], now: now.addingTimeInterval(-86_400), sql: ownerSQL)
            #expect(try await PostgresV2MentionPushWakeRelay(owner: owner, control: control)
                .runOnce(now: now, limit: 1) == 1)
            #expect(try await count("im_v2.mention_push_wake_intents", on: ownerSQL) == 0)
            #expect(try await count("im_v2.mention_push_wake_receipts", on: controlSQL) == 0)
            #expect(try await count("im_v2.push_wake_outbox", on: controlSQL) == 0)
            let pending = UUID(), expiredClaim = UUID(), activeClaim = UUID(), fresh = UUID()
            try await controlSQL.raw("""
                INSERT INTO im_v2.push_campaigns (campaign_id,state,updated_at)
                VALUES ('mention_wake','enabled',\(bind: now))
                """).run()
            for dispatch in [pending, expiredClaim, activeClaim, fresh] {
                let created = dispatch == fresh ? now : now.addingTimeInterval(-90_000)
                try await controlSQL.raw("""
                    INSERT INTO im_v2.push_wake_outbox
                        (dispatch_id,source_event_id,source_room_id,target_user_id,target_device_id,
                         campaign_id,budget_window_started_at,created_at)
                    VALUES (\(bind: dispatch),\(bind: UUID()),\(bind: room.uuidValue!),
                            \(bind: memberTwoUUID),\(bind: UUID()),'mention_wake',\(bind: created),\(bind: created))
                    """).run()
            }
            for (dispatch, expiry) in [(expiredClaim, now), (activeClaim, now.addingTimeInterval(60))] {
                try await controlSQL.raw("""
                    UPDATE im_v2.push_wake_outbox SET state='claimed',claim_token=\(bind: UUID()),
                        lease_expires_at=\(bind: expiry) WHERE dispatch_id=\(bind: dispatch)
                    """).run()
            }
            for recorded in [now.addingTimeInterval(-8 * 86_400), now] {
                try await controlSQL.raw("""
                    INSERT INTO im_v2.mention_push_wake_receipts (source_event_id,target_user_id,recorded_at)
                    VALUES (\(bind: UUID()),\(bind: memberTwoUUID),\(bind: recorded))
                    """).run()
            }
            let report = try await PostgresV2ControlPlaneHousekeepingStore(database: control)
                .purgeTerminal(now: now, retention: 7 * 86_400,
                    idempotencyRetention: V2IdempotencyPolicy.minimumServerRetention, limit: 120)
            #expect(report.expiredPushWakeRows == 2)
            #expect(try await count("im_v2.push_wake_outbox WHERE state='suppressed'", on: controlSQL) == 2)
            #expect(try await controlSQL.raw("""
                SELECT state='claimed' AND claim_token IS NOT NULL AND lease_expires_at>\(bind: now) AS value
                FROM im_v2.push_wake_outbox WHERE dispatch_id=\(bind: activeClaim)
                """).first(decoding: MentionRelayBooleanRow.self)?.value == true)
            #expect(try await count("im_v2.push_wake_outbox WHERE state='pending'", on: controlSQL) == 1)
            #expect(try await count("im_v2.mention_push_wake_receipts", on: controlSQL) == 1)
            // 已过期通知不再查询远端 owner；它可能已经不可用。
            let expiredWithoutOwner = UUID()
            try await controlSQL.raw("""
                INSERT INTO im_v2.push_wake_outbox
                    (dispatch_id,source_event_id,source_room_id,target_user_id,target_device_id,
                     campaign_id,budget_window_started_at,created_at)
                VALUES (\(bind: expiredWithoutOwner),\(bind: UUID()),\(bind: room.uuidValue!),
                        \(bind: memberTwoUUID),\(bind: UUID()),'mention_wake',
                        \(bind: now),\(bind: now.addingTimeInterval(-100_000)))
                """).run()
            let store = PostgresV2PushWakeStore(database: control, conversationMuted: { _, _, _ in
                throw V2RoomWriteStoreError.corruptPersistenceState
            })
            #expect(try await store.claimAdmitted(now: now, leaseDuration: 30, limit: 1).isEmpty)
            #expect(try await count("im_v2.push_wake_outbox WHERE dispatch_id='\(expiredWithoutOwner.uuidString)' AND state='suppressed'", on: controlSQL) == 1)
        }
    }
}
private struct MentionRelayBooleanRow: Decodable { let value: Bool }
