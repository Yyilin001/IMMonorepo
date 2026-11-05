@testable import IMV2ServerInfrastructure
import IMV2Core
import IMV2ServerContracts
import Foundation
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("generic wake expiry preserves active claims and skips remote authority")
    func expiredGenericPushWake() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, controlSQL, _, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
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
