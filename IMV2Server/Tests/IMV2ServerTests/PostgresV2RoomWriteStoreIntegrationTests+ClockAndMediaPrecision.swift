@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Crypto
import FluentKit
import FluentPostgresDriver
import Foundation
import HTTPTypes
#if os(macOS)
import Darwin
#endif
import IMV2Core
import IMV2ServerHTTP
import PostgresNIO
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Synchronization
import Testing
import Vapor
import VaporTesting

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("Push admission preserves the exact persisted budget window across timestamp conversion", arguments: 0..<6)
    func pushBudgetWindowTimestampPrecision(index: Int) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let instants: [Double] = [946_684_800 + 0.00000125, 946_684_800 - 0.00000125,
                0.1234567, 1_750_000_000.1234567, -210_866_803_200 + 10, 9_224_318_016_000 - 10]
            let window = Date(timeIntervalSince1970: instants[index])
            let otherWindow = window.addingTimeInterval(-1)
            let now = window.addingTimeInterval(1)
            let device = UUID(), dispatch = UUID(), missing = UUID()
            let sender = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database), capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64), now: { Date(timeIntervalSince1970: 1_750_000_000) })
            guard case .accepted = try await sender.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "push window precision")) else { throw CancellationError() }
            let event = try #require(try await sql.raw("SELECT event_id AS source_event_id, event_id AS plan_id FROM im_v2.room_events").first(decoding: TriggerRow.self)).sourceEventID
            try await sql.raw("INSERT INTO im_v2.push_campaigns (campaign_id, state, updated_at) VALUES ('wake', 'enabled', \(bind: window))").run()
            for time in [window, otherWindow] {
                try await sql.raw("INSERT INTO im_v2.push_device_budgets (device_id, campaign_id, window_started_at, max_work_units, used_work_units, max_new_key_operations, used_new_key_operations) VALUES (\(bind: device), 'wake', \(bind: time), 1, 0, 1, 0)").run()
            }
            for (id, target) in [(dispatch, device), (missing, UUID())] {
                try await sql.raw("INSERT INTO im_v2.push_wake_outbox (dispatch_id, source_event_id, target_user_id, target_device_id, campaign_id, budget_window_started_at, requires_new_key_operation, created_at) VALUES (\(bind: id), \(bind: event), \(bind: memberTwoUUID), \(bind: target), 'wake', \(bind: window), TRUE, \(bind: window))").run()
            }
            // The database itself confirms that the referenced window exists exactly.
            #expect(try await count("im_v2.push_wake_outbox w JOIN im_v2.push_device_budgets b ON b.device_id = w.target_device_id AND b.campaign_id = w.campaign_id AND b.window_started_at = w.budget_window_started_at", on: sql) == 1)
            let store = PostgresV2PushWakeStore(database: database)
            let first = try await store.claimAdmitted(now: now, leaseDuration: 1, limit: 2)
            #expect(first.count == 1)
            let old = try #require(first.first)
            #expect(old.wake.dispatchID == dispatch)
            let replacement = try #require(try await store.claimAdmitted(now: now.addingTimeInterval(1), leaseDuration: 1, limit: 2).first)
            #expect(replacement.wake.dispatchID == dispatch && replacement.claimToken != old.claimToken)
            try await store.markSent(old, now: now.addingTimeInterval(1))
            #expect(try await count("im_v2.push_wake_outbox WHERE state = 'claimed'", on: sql) == 1)
            try await store.release(replacement)
            let final = try #require(try await store.claimAdmitted(now: now.addingTimeInterval(2), leaseDuration: 1, limit: 2).first)
            try await store.markSent(final, now: now.addingTimeInterval(2))
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.push_device_budgets WHERE window_started_at = \(bind: window) AND used_work_units = 1 AND used_new_key_operations = 1").first(decoding: CountRow.self)?.value == 1)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.push_device_budgets WHERE window_started_at = \(bind: otherWindow) AND used_work_units = 0 AND used_new_key_operations = 0").first(decoding: CountRow.self)?.value == 1)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.push_wake_outbox WHERE dispatch_id = \(bind: dispatch) AND state = 'sent' AND retry_count = 3 AND admitted_at = \(bind: now) AND budget_window_started_at = \(bind: window) AND claim_token IS NULL AND lease_expires_at IS NULL").first(decoding: CountRow.self)?.value == 1)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.push_wake_outbox WHERE dispatch_id = \(bind: missing) AND state = 'suppressed' AND suppression_reason = 'device_budget_unavailable' AND admitted_at IS NULL AND retry_count = 0").first(decoding: CountRow.self)?.value == 1)
            #expect(try await store.claimAdmitted(now: now.addingTimeInterval(3), leaseDuration: 1, limit: 2).isEmpty)
        }
    }

    @Test("Push retry exhaustion preserves one admission charge and fences old sends", arguments: 0..<6)
    func pushWakeRetryCounterBoundary(index: Int) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let now = base.addingTimeInterval(30)
            let expired = index >= 3
            let retryCounters: [Int64] = [Int64(0), Int64.max - 1, Int64.max, 1, Int64.max - 1, Int64.max]
            let starting = retryCounters[index]
            let sender = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database), capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64), now: { base })
            guard case .accepted = try await sender.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "push retry boundary")) else { throw CancellationError() }
            let event = try #require(try await sql.raw("SELECT event_id AS source_event_id, event_id AS plan_id FROM im_v2.room_events").first(decoding: TriggerRow.self)).sourceEventID
            let primary = UUID(), healthy = UUID()
            try await sql.raw("INSERT INTO im_v2.push_campaigns (campaign_id, state, updated_at) VALUES ('wake', 'enabled', \(bind: base))").run()
            for (offset, dispatch) in [primary, healthy].enumerated() {
                let device = UUID()
                let counter = dispatch == primary ? starting : expired ? 1 : 0
                let used = counter > 0 ? 1 : 0
                let admittedAt: Date? = used == 1 ? base : nil
                try await sql.raw("INSERT INTO im_v2.push_device_budgets (device_id, campaign_id, window_started_at, max_work_units, used_work_units, max_new_key_operations, used_new_key_operations) VALUES (\(bind: device), 'wake', \(bind: base), 1, \(bind: used), 1, \(bind: used))").run()
                try await sql.raw("INSERT INTO im_v2.push_wake_outbox (dispatch_id, source_event_id, target_user_id, target_device_id, campaign_id, budget_window_started_at, requires_new_key_operation, created_at, retry_count, admitted_at) VALUES (\(bind: dispatch), \(bind: event), \(bind: offset == 0 ? memberTwoUUID : memberThreeUUID), \(bind: device), 'wake', \(bind: base), TRUE, \(bind: base), \(bind: counter), \(bind: admittedAt))").run()
            }
            if expired { try await sql.raw("UPDATE im_v2.push_wake_outbox SET state = 'claimed', claim_token = \(bind: UUID()), lease_expires_at = \(bind: now)").run() }
            let store = PostgresV2PushWakeStore(database: database)
            let leases = try await store.claimAdmitted(now: now, leaseDuration: 30, limit: 2)
            #expect(leases.count == 2)
            let old = try #require(leases.first { $0.wake.dispatchID == primary })
            let other = try #require(leases.first { $0.wake.dispatchID == healthy })
            #expect(try await count("im_v2.push_device_budgets WHERE used_work_units = 1 AND used_new_key_operations = 1", on: sql) == 2)
            try await store.markSent(other, now: now)
            try await store.release(old)
            let replacement = try #require(try await store.claimAdmitted(now: now, leaseDuration: 30, limit: 2).first)
            #expect(replacement.wake.dispatchID == primary && replacement.claimToken != old.claimToken)
            let expected = starting >= Int64.max - 1 ? Int64.max : starting + 2
            #expect(try await sql.raw("SELECT retry_count AS value FROM im_v2.push_wake_outbox WHERE dispatch_id = \(bind: primary)").first(decoding: CountRow.self)?.value == expected)
            let admitted = starting > 0 ? base : now
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.push_wake_outbox WHERE dispatch_id = \(bind: primary) AND admitted_at = \(bind: admitted)").first(decoding: CountRow.self)?.value == 1)
            let held = try #require(try await sql.raw("SELECT jsonb_agg(to_jsonb(w) ORDER BY dispatch_id)::text AS value FROM im_v2.push_wake_outbox w").first(decoding: StringValueRow.self)).value
            try await store.markSent(old, now: now)
            try await store.release(old)
            #expect(try await sql.raw("SELECT jsonb_agg(to_jsonb(w) ORDER BY dispatch_id)::text AS value FROM im_v2.push_wake_outbox w").first(decoding: StringValueRow.self)?.value == held)
            try await store.markSent(replacement, now: now.addingTimeInterval(1))
            #expect(try await count("im_v2.push_wake_outbox WHERE state = 'sent' AND claim_token IS NULL AND lease_expires_at IS NULL", on: sql) == 2)
            #expect(try await count("im_v2.push_device_budgets WHERE used_work_units = 1 AND used_new_key_operations = 1", on: sql) == 2)
            #expect(try await store.claimAdmitted(now: now.addingTimeInterval(60), leaseDuration: 30, limit: 2).isEmpty)
        }
    }

    @Test("Content review retry limits preserve decisions, pause policy and claim fencing", arguments: 0..<6, [false, true])
    func contentReviewRetryCounterBoundary(index: Int, pause: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let now = base.addingTimeInterval(30)
            let maximum = Int64(Int32.max)
            let retryCounters: [Int64] = [Int64(0), maximum - 1, maximum, 1, maximum - 1, maximum]
            let starting = retryCounters[index]
            let sender = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database), capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64), now: { base })
            var messages: [MessageID] = []
            for _ in 0..<2 {
                guard case .accepted(let message) = try await sender.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "review retry boundary")) else { throw CancellationError() }
                messages.append(message.messageID)
            }
            let primary = messages[0]
            try await sql.raw("UPDATE im_v2.content_review_jobs SET retry_count = CASE WHEN message_id = \(bind: primary.uuidValue!) THEN \(bind: starting) ELSE 0 END").run()
            if index >= 3 {
                try await sql.raw("UPDATE im_v2.content_review_jobs SET state = 'claimed', claim_token = \(bind: UUID()), lease_expires_at = \(bind: now)").run()
            }
            let store = PostgresV2ContentReviewStore(database: database)
            let old = try await store.claimPending(now: now, leaseDuration: 30, limit: 2)
            #expect(old.count == 2)
            #expect(try await store.claimPending(now: now.addingTimeInterval(29), leaseDuration: 30, limit: 2).isEmpty)
            let reclaimed = try await store.claimPending(now: now.addingTimeInterval(30), leaseDuration: 30, limit: 2)
            #expect(reclaimed.count == 2)
            let current = try #require(reclaimed.first { $0.input.messageID == primary })
            #expect(current.attempt == Int(min(starting + 2, maximum)))
            let held = try #require(try await sql.raw("SELECT jsonb_agg(to_jsonb(j) ORDER BY message_id)::text AS value FROM im_v2.content_review_jobs j").first(decoding: StringValueRow.self)).value
            for lease in old {
                #expect(try await store.resolve(lease, verdict: .clear, now: now.addingTimeInterval(31)) == false)
                try await store.scheduleRetry(lease, disposition: .pause, now: now.addingTimeInterval(31))
            }
            #expect(try await sql.raw("SELECT jsonb_agg(to_jsonb(j) ORDER BY message_id)::text AS value FROM im_v2.content_review_jobs j").first(decoding: StringValueRow.self)?.value == held)
            for lease in reclaimed {
                if pause && lease.input.messageID == primary {
                    let disposition = V2DurableRetryPolicy.standard.disposition(attempt: lease.attempt, claimToken: lease.claimToken, now: now.addingTimeInterval(31))
                    #expect((disposition == .pause) == (starting > 1))
                    try await store.scheduleRetry(lease, disposition: disposition, now: now.addingTimeInterval(31))
                } else {
                    #expect(try await store.resolve(lease, verdict: .clear, now: now.addingTimeInterval(31)))
                }
            }
            #expect(try await count("im_v2.content_review_decisions", on: sql) == (pause ? 1 : 2))
            #expect(try await count("im_v2.content_review_findings", on: sql) == 0)
            let expectedState = !pause ? "completed" : starting > 1 ? "paused" : "pending"
            #expect(try await sql.raw("SELECT state AS value FROM im_v2.content_review_jobs WHERE message_id = \(bind: primary.uuidValue!)").first(decoding: StringValueRow.self)?.value == expectedState)
            #expect(try await count("im_v2.content_review_jobs WHERE state = 'completed' AND decision = 'clear' AND claim_token IS NULL AND lease_expires_at IS NULL", on: sql) == (pause ? 1 : 2))
            #expect(try await store.claimPending(now: now.addingTimeInterval(31), leaseDuration: 30, limit: 2).isEmpty)
        }
    }

    @Test("Scan completion and retention agree at exact database deadlines in either order",
          arguments: 0..<12, [false, true])
    func mediaScanCompletionExpiryPrecision(index: Int, passed: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let epoch = Date(timeIntervalSince1970: 946_684_800)
            let created = epoch.addingTimeInterval(-10)
            let boundary = index % 6
            let retentionFirst = index >= 6
            let offsets: [Double] = [0.000001, -0.00000125, -0.000001, 0.00000125, 0.00000225, -0.00000225]
            let now = Date(timeInterval: offsets[boundary], since: epoch)
            let expiryMicroseconds: Int64 = boundary == 1 || boundary == 5 ? -1 : 1
            let live = [0, 2, 5].contains(boundary)
            let media = MediaID(uuid: UUID())
            try await sql.raw("INSERT INTO im_v2.media_objects (media_id, owner_user_id, content_type, byte_count, state, upload_session_id, expires_at, state_updated_at, created_at) VALUES (\(bind: media.uuidValue!), \(bind: senderUUID), 'image/png', 42, 'scanning', \(bind: UUID()), TIMESTAMPTZ '2000-01-01 00:00:00+00' + \(bind: expiryMicroseconds) * INTERVAL '1 microsecond', \(bind: created), \(bind: created))").run()
            try await sql.raw("INSERT INTO im_v2.media_scan_outbox (media_id, state, created_at) VALUES (\(bind: media.uuidValue!), 'pending', \(bind: created))").run()
            #expect(try await sql.raw("SELECT expires_at > \(bind: now) AS exists FROM im_v2.media_objects").first(decoding: ExistsRow.self)?.exists == live)
            let retention = PostgresV2MediaRetentionStore(database: database)
            if retentionFirst {
                #expect(try await retention.expireEligibleMedia(now: now, withdrawnRetention: 60, limit: 1) == (live ? 0 : 1))
            }
            struct Scanner: V2MediaScanProvider {
                let result: V2MediaScanResult
                func scan(mediaID: MediaID) async throws -> V2MediaScanResult { result }
            }
            let result: V2MediaScanResult = passed ? .passed : .failed
            let token = UUID()
            let store = PostgresV2MediaScanStore(database: database, makeUUID: { token })
            let report = try await V2MediaScanWorker(store: store, provider: Scanner(result: result), now: { now }).runOnce(limit: 1)
            #expect(report == .init(claimedCount: 1, completedCount: 1, releasedCount: 0, pausedCount: 0))
            let expectedState = live ? (passed ? "available" : "failed") : (retentionFirst ? "expired" : "scanning")
            let expectedUpdate = live || retentionFirst ? now : created
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.media_objects WHERE state = \(bind: expectedState) AND state_updated_at = \(bind: expectedUpdate)").first(decoding: CountRow.self)?.value == 1)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.media_scan_outbox WHERE state = 'completed' AND retry_count = 1 AND completed_at = \(bind: now) AND claim_token IS NULL AND lease_expires_at IS NULL AND next_attempt_at IS NULL AND paused_at IS NULL").first(decoding: CountRow.self)?.value == 1)
            if !retentionFirst {
                #expect(try await retention.expireEligibleMedia(now: now, withdrawnRetention: 60, limit: 1) == (live ? 0 : 1))
            }
            #expect(try await count("im_v2.media_purge_outbox", on: sql) == (live ? 0 : 1))
            #expect(try await sql.raw("SELECT state AS value FROM im_v2.media_objects").first(decoding: StringValueRow.self)?.value == (live ? (passed ? "available" : "failed") : "expired"))
            func snapshot() async throws -> [String] {
                var values: [String] = []
                for table in ["media_objects", "media_scan_outbox", "media_purge_outbox"] {
                    let row = try #require(try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self))
                    values.append(row.value)
                }
                return values
            }
            let committed = try await snapshot()
            let completedLease = V2MediaScanLease(mediaID: media, claimToken: token, attempt: 1)
            for date in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity), now.addingTimeInterval(60)] {
                try await store.complete(completedLease, result: passed ? .failed : .passed, now: date)
                #expect(try await snapshot() == committed)
            }
        }
    }

    @Test("Download retry counters allow the final claim and reject exhaustion without writes",
          arguments: [false, true], 0..<3)
    func mediaSessionRetryCounterBoundary(reclaim: Bool, index: Int) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000.1234567)
            let now = base.addingTimeInterval(30)
            let device = DeviceID(uuid: UUID()), media = MediaID(uuid: UUID())
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, session_expires_at) VALUES (\(bind: senderUUID), \(bind: device.uuidValue!), \(bind: base), \(bind: base), \(bind: Date().addingTimeInterval(3600)))").run()
            try await prepareDownloadableResource(mediaID: media, device: device, database: database)
            let grant = try await PostgresV2MediaStore(database: database).requestDownload(requesterUserID: senderID, deviceID: device, mediaID: media, expiresAt: base.addingTimeInterval(600), now: base)
            let downloads = PostgresV2MediaDownloadSessionStore(database: database)
            if reclaim { _ = try await downloads.claimDownload(requesterUserID: senderID, deviceID: device, downloadSessionID: grant.downloadSessionID, now: base, leaseDuration: 30) }
            let starting = [Int64(0), Int64.max - 1, Int64.max][index]
            try await sql.raw("UPDATE im_v2.media_download_grants SET retry_count = \(bind: starting)").run()
            let initial = try #require(try await sql.raw("SELECT to_jsonb(r)::text AS value FROM im_v2.media_download_grants r").first(decoding: StringValueRow.self)).value
            if starting == Int64.max {
                await #expect(throws: V2MediaDownloadSessionStoreError.sessionUnavailable) {
                    try await downloads.claimDownload(requesterUserID: senderID, deviceID: device, downloadSessionID: grant.downloadSessionID, now: now, leaseDuration: 30)
                }
                #expect(try await sql.raw("SELECT to_jsonb(r)::text AS value FROM im_v2.media_download_grants r").first(decoding: StringValueRow.self)?.value == initial)
                return
            }
            let claim = try await downloads.claimDownload(requesterUserID: senderID, deviceID: device, downloadSessionID: grant.downloadSessionID, now: now, leaseDuration: 30)
            #expect(claim.mediaID == media && claim.expiresAt == grant.expiresAt)
            try await downloads.completeDownload(claim, now: now.addingTimeInterval(1))
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.media_download_grants WHERE state = 'consumed' AND retry_count = \(bind: starting + 1) AND redeemed_at = \(bind: now.addingTimeInterval(1)) AND claim_token IS NULL AND lease_expires_at IS NULL").first(decoding: CountRow.self)?.value == 1)
        }
    }

    @Test("Media workers handle saturated retry counts without blocking healthy work",
          arguments: ["scan-pending", "scan-expired", "purge-pending", "purge-expired"], 0..<6)
    func mediaWorkerRetryCounterBoundary(path: String, index: Int) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000.1234567)
            let primary = MediaID(uuid: UUID()), healthy = MediaID(uuid: UUID())
            let scan = path.hasPrefix("scan")
            let fails = index >= 3
            let starting = [Int64(0), Int64.max - 1, Int64.max][index % 3]
            let expectedCount: Int64 = starting == 0 ? 1 : .max
            let table = scan ? "media_scan_outbox" : "media_purge_outbox"
            for (offset, media) in [primary, healthy].enumerated() {
                let created = now.addingTimeInterval(Double(offset - 2))
                try await sql.raw("INSERT INTO im_v2.media_objects (media_id, owner_user_id, content_type, byte_count, state, upload_session_id, expires_at, state_updated_at, created_at) VALUES (\(bind: media.uuidValue!), \(bind: senderUUID), 'image/png', 42, \(bind: scan ? "scanning" : "expired"), \(bind: UUID()), \(bind: now.addingTimeInterval(600)), \(bind: created), \(bind: created))").run()
                let counter = media == primary ? starting : 0
                if scan {
                    try await sql.raw("INSERT INTO im_v2.media_scan_outbox (media_id, state, retry_count, created_at) VALUES (\(bind: media.uuidValue!), 'pending', \(bind: counter), \(bind: created))").run()
                } else {
                    try await sql.raw("INSERT INTO im_v2.media_purge_outbox (media_id, reason, state, retry_count, created_at) VALUES (\(bind: media.uuidValue!), 'unreferenced_expired', 'pending', \(bind: counter), \(bind: created))").run()
                }
            }
            if path.hasSuffix("expired") {
                try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET state = 'claimed', claim_token = \(bind: UUID()), lease_expires_at = \(bind: now) WHERE media_id = \(bind: primary.uuidValue!)").run()
            }
            struct Provider: V2MediaScanProvider, V2MediaPurgeProvider {
                let failing: MediaID?
                func scan(mediaID: MediaID) async throws -> V2MediaScanResult {
                    if mediaID == failing { throw V2MediaStoreError.mediaUnavailable }
                    return .passed
                }
                func purge(mediaID: MediaID) async throws {
                    if mediaID == failing { throw V2MediaStoreError.mediaUnavailable }
                }
            }
            let provider = Provider(failing: fails ? primary : nil)
            func run() async throws -> (claimed: Int, completed: Int, released: Int, paused: Int) {
                if scan {
                    let report = try await V2MediaScanWorker(store: PostgresV2MediaScanStore(database: database), provider: provider, now: { now }).runOnce(limit: 2)
                    return (report.claimedCount, report.completedCount, report.releasedCount, report.pausedCount)
                }
                let report = try await V2MediaPurgeWorker(store: PostgresV2MediaPurgeStore(database: database), provider: provider, now: { now }).runOnce(limit: 2)
                return (report.claimedCount, report.completedCount, report.releasedCount, report.pausedCount)
            }
            let report = try await run()
            // 提供商故障是瞬时的：即使重试计数已经饱和（包括 Int64.max），
            // 工作也只释放重试，不进入需要人工干预的暂停状态。
            #expect(report.claimed == 2 && report.completed == (fails ? 1 : 2))
            #expect(report.paused == 0 && report.released == (fails ? 1 : 0))
            let primaryState = !fails ? "completed" : "pending"
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table) WHERE media_id = \(bind: primary.uuidValue!) AND state = \(bind: primaryState) AND retry_count = \(bind: expectedCount) AND claim_token IS NULL AND lease_expires_at IS NULL AND ((state = 'completed' AND completed_at = \(bind: now)) OR (state = 'paused' AND paused_at = \(bind: now)) OR (state = 'pending' AND next_attempt_at > \(bind: now)))").first(decoding: CountRow.self)?.value == 1)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table) WHERE media_id = \(bind: healthy.uuidValue!) AND state = 'completed' AND retry_count = 1 AND completed_at = \(bind: now) AND claim_token IS NULL AND lease_expires_at IS NULL").first(decoding: CountRow.self)?.value == 1)
            if scan {
                #expect(try await sql.raw("SELECT state AS value FROM im_v2.media_objects WHERE media_id = \(bind: primary.uuidValue!)").first(decoding: StringValueRow.self)?.value == (fails ? "scanning" : "available"))
                #expect(try await sql.raw("SELECT state AS value FROM im_v2.media_objects WHERE media_id = \(bind: healthy.uuidValue!)").first(decoding: StringValueRow.self)?.value == "available")
            }
            let committed = try #require(try await sql.raw("SELECT jsonb_agg(to_jsonb(r) ORDER BY media_id)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self)).value
            #expect(try await run().claimed == 0)
            #expect(try await sql.raw("SELECT jsonb_agg(to_jsonb(r) ORDER BY media_id)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self)?.value == committed)
        }
    }

    @Test("Media lifecycle expiry agrees with PostgreSQL at microsecond boundaries",
          arguments: ["rounded-positive", "same-negative", "before", "at", "after", "negative-before"], ["pending", "scan-pass", "scan-fail"])
    func mediaLifecycleExpiryPrecision(boundary: String, stage: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let epoch = Date(timeIntervalSince1970: 946_684_800)
            let baseline = epoch.addingTimeInterval(-10)
            let wall = Date()
            let device = DeviceID(uuid: UUID()), media = MediaID(uuid: UUID())
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, session_expires_at) VALUES (\(bind: senderUUID), \(bind: device.uuidValue!), \(bind: wall), \(bind: wall), \(bind: wall.addingTimeInterval(3600)))").run()
            let store = PostgresV2ResourceLifecycleStore(database: database, authorize: { _ in })
            let input = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: media, usage: .messageAttachment(roomID),
                contentType: "image/png", byteCount: 42, checksum: .init(value: String(repeating: "a", count: 64)))
            let upload = try await createResourceUpload(input, device: device, store: store, expiresAt: epoch.addingTimeInterval(1), now: baseline)
            let claim = try await store.claimFinalize(session: upload.sessionID, generation: 1, actor: senderUUID, device: device.uuidValue!, now: baseline)
            let facts = try V2StoredObjectFacts(reference: claim.placement, byteCount: 42, sha256: Data(repeating: 0xaa, count: 32))
            let scans = PostgresV2MediaScanStore(database: database)
            var scanLease: V2MediaScanLease?
            if stage != "pending" {
                try await store.publish(claim, facts: facts, actor: senderUUID, device: device.uuidValue!, now: baseline.addingTimeInterval(2))
                scanLease = try #require(try await scans.claimPending(now: baseline.addingTimeInterval(3), leaseDuration: 30, limit: 1).first)
            }
            let negative = boundary == "same-negative" || boundary == "negative-before"
            let expiryMicroseconds: Int64 = negative ? -1 : 1
            let offset: Double
            switch boundary {
            case "rounded-positive": offset = 0.000001
            case "same-negative": offset = -0.00000125
            case "before": offset = -0.000001
            case "at": offset = 0.00000125
            case "after": offset = 0.00000225
            default: offset = -0.00000225
            }
            let now = Date(timeInterval: offset, since: epoch)
            let live = ["rounded-positive", "before", "negative-before"].contains(boundary)
            // Inject the exact SQL deadline, avoiding a Date round trip.
            for table in ["media_objects", "resource_upload_sessions"] {
                try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET expires_at = TIMESTAMPTZ '2000-01-01 00:00:00+00' + \(bind: expiryMicroseconds) * INTERVAL '1 microsecond'").run()
                #expect(try await sql.raw("SELECT expires_at > \(bind: now) AS exists FROM im_v2.\(unsafeRaw: table)").first(decoding: ExistsRow.self)?.exists == live)
            }
            func snapshot() async throws -> [String] {
                var values: [String] = []
                for table in ["media_objects", "resource_upload_sessions", "resource_catalog", "resource_blob_placements", "media_scan_outbox"] {
                    values.append(try #require(try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self)).value)
                }
                return values
            }
            let initial = try await snapshot()
            if stage == "pending" {
                if !live {
                    await #expect(throws: V2ResourceProviderError.preconditionFailed) {
                        try await store.publish(claim, facts: facts, actor: senderUUID, device: device.uuidValue!, now: now)
                    }
                    #expect(try await snapshot() == initial)
                    return
                }
                try await store.publish(claim, facts: facts, actor: senderUUID, device: device.uuidValue!, now: now)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.media_objects m JOIN im_v2.media_scan_outbox scan USING (media_id) WHERE m.state = 'scanning' AND scan.state = 'pending' AND m.state_updated_at = scan.created_at AND m.state_updated_at = \(bind: now)").first(decoding: CountRow.self)?.value == 1)
            } else {
                // Expired objects drain the job without publishing its scan result.
                try await scans.complete(#require(scanLease), result: stage == "scan-pass" ? .passed : .failed, now: now)
                let expected = live ? (stage == "scan-pass" ? "available" : "failed") : "scanning"
                #expect(try await store.status(session: upload.sessionID, actor: senderUUID, device: device.uuidValue!).mediaState == expected)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.media_scan_outbox WHERE state = 'completed' AND completed_at = \(bind: now)").first(decoding: CountRow.self)?.value == 1)
                if !live {
                    #expect(try await sql.raw("SELECT state_updated_at AS value FROM im_v2.media_objects").first(decoding: RevocationClockDateRow.self)?.value == baseline.addingTimeInterval(2))
                }
            }
        }
    }

    @Test("Media responses retain the database deadline on first issue and upload replay", arguments: 0..<6)
    func mediaResponseTimestampPrecision(index: Int) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let seconds: [Double] = [946_684_800 + 0.00000125, 946_684_800 - 0.00000125,
                0.1234567, 1_750_000_000.1234567, -210_866_803_190, 9_224_318_015_990]
            let expiry = Date(timeIntervalSince1970: seconds[index])
            let now = expiry.addingTimeInterval(-1)
            let device = DeviceID(uuid: UUID()), mediaID = MediaID(uuid: UUID())
            let wall = Date()
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, session_expires_at) VALUES (\(bind: senderUUID), \(bind: device.uuidValue!), \(bind: wall), \(bind: wall), \(bind: wall.addingTimeInterval(3600)))").run()
            let store = PostgresV2ResourceLifecycleStore(database: database, authorize: { _ in })
            let input = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: mediaID, usage: .messageAttachment(roomID),
                contentType: "image/png", byteCount: 42, checksum: .init(value: String(repeating: "a", count: 64)))
            let upload = try await createResourceUpload(input, device: device, store: store, expiresAt: expiry, now: now)
            let saved = try #require(try await sql.raw("SELECT expires_at AS value FROM im_v2.resource_upload_sessions").first(decoding: RevocationClockDateRow.self)).value
            #expect(upload.expiresAt == saved)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.media_objects m JOIN im_v2.resource_upload_sessions s USING (media_id) JOIN im_v2.resource_catalog c USING (media_id) WHERE m.expires_at = s.expires_at AND s.expires_at = \(bind: expiry) AND m.created_at = s.created_at AND s.created_at = c.created_at AND s.created_at = \(bind: now)").first(decoding: CountRow.self)?.value == 1)
            let committed = try #require(try await sql.raw("SELECT to_jsonb(s)::text AS value FROM im_v2.resource_upload_sessions s").first(decoding: StringValueRow.self)).value
            for date in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity), wall] {
                let replay = try await createResourceUpload(input, device: device, store: store, expiresAt: date, now: date)
                #expect(replay.sessionID == upload.sessionID && replay.expiresAt == saved)
                #expect(try await sql.raw("SELECT to_jsonb(s)::text AS value FROM im_v2.resource_upload_sessions s").first(decoding: StringValueRow.self)?.value == committed)
            }
            let downloadMedia = MediaID(uuid: UUID())
            try await prepareDownloadableResource(mediaID: downloadMedia, device: device, database: database)
            let download = try await PostgresV2MediaStore(database: database).requestDownload(requesterUserID: senderID, deviceID: device, mediaID: downloadMedia, expiresAt: expiry, now: now)
            #expect(download.expiresAt == (try await sql.raw("SELECT expires_at AS value FROM im_v2.media_download_grants").first(decoding: RevocationClockDateRow.self)?.value))
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.media_download_grants WHERE expires_at = \(bind: expiry) AND created_at = \(bind: now)").first(decoding: CountRow.self)?.value == 1)
            #expect(try await count("im_v2.resource_upload_sessions", on: sql) == 2)
        }
    }

    @Test("Concurrent upload requests replay one operation and retain its deadline", arguments: ["same", "different-media", "different-size"])
    func mediaUploadConcurrentReplay(path: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 946_684_800 + 0.00000125)
            let expiry = now.addingTimeInterval(60)
            let wall = Date()
            let device = DeviceID(uuid: UUID()), mediaID = MediaID(uuid: UUID()), otherMedia = MediaID(uuid: UUID())
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, session_expires_at) VALUES (\(bind: senderUUID), \(bind: device.uuidValue!), \(bind: wall), \(bind: wall), \(bind: wall.addingTimeInterval(3600)))").run()
            let operation = MediaUploadOperationID(uuid: UUID())
            let command = try V2ResourceUploadRequest(operationID: operation, mediaID: mediaID, usage: .messageAttachment(roomID),
                contentType: "image/png", byteCount: 42, checksum: .init(value: String(repeating: "a", count: 64)))
            let conflict = try V2ResourceUploadRequest(operationID: operation, mediaID: path == "different-media" ? otherMedia : mediaID,
                usage: .messageAttachment(roomID), contentType: "image/png", byteCount: path == "different-size" ? 43 : 42, checksum: command.checksum)
            let store = PostgresV2ResourceLifecycleStore(database: database, authorize: { _ in })
            struct Receipt: Equatable, Sendable { let sessionID: UUID; let expiresAt: Date }
            func perform(_ request: V2ResourceUploadRequest, date: Date) async throws -> Receipt? {
                do {
                    let row = try await store.create(homeKind: "room", homeID: roomUUID, usageKind: "message_attachment", actor: senderUUID,
                        device: device.uuidValue!, operation: operation.uuidValue!, mediaID: request.mediaID.uuidValue!, contentType: request.contentType,
                        byteCount: request.byteCount, requestJSON: String(decoding: JSONEncoder().encode(request), as: UTF8.self),
                        allocate: { try .init(placementID: UUID(), binding: .init(id: "concurrent-upload", configurationRevision: 1), handle: Data(UUID().uuidString.utf8)) },
                        expiresAt: date.addingTimeInterval(60), now: date)
                    return Receipt(sessionID: row.sessionID, expiresAt: row.expiresAt)
                } catch V2MediaStoreError.idempotencyConflict { return nil }
            }
            let gate = PostgreSQLTransactionGate()
            let holder = Task {
                try await database.transaction { transaction in
                    let held = try #require(transaction as? any SQLDatabase)
                    // Hold inserts after the empty-ledger read without
                    // changing either request's normal business input.
                    try await held.raw("LOCK TABLE im_v2.media_objects IN SHARE MODE").run()
                    await gate.holdTransaction()
                }
            }
            await gate.waitUntilHeld()
            func waitForWriters(_ expected: Int64) async throws {
                for _ in 0..<500 {
                    let waiting = try await sql.raw("SELECT COUNT(*) AS value FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'").first(decoding: CountRow.self)?.value ?? 0
                    if waiting == expected { return }
                    try await Task.sleep(for: .milliseconds(10))
                }
                Issue.record("Expected overlapping uploads to wait on database locks")
                throw CancellationError()
            }
            let first = Task { try await perform(command, date: now) }
            var second: Task<Receipt?, Error>?
            do {
                try await waitForWriters(1)
                second = Task { try await perform(conflict, date: wall) }
                try await waitForWriters(2)
                await gate.releaseTransaction()
                try await holder.value
                let issued = try #require(try await first.value)
                #expect(try await #require(second).value == (path == "same" ? issued : nil))
                #expect(issued.expiresAt == (try await sql.raw("SELECT expires_at AS value FROM im_v2.resource_upload_sessions").first(decoding: RevocationClockDateRow.self)?.value))
                func snapshot() async throws -> [String] {
                    var values: [String] = []
                    for table in ["media_objects", "resource_upload_sessions", "resource_catalog"] {
                        #expect(try await count("im_v2." + table, on: sql) == 1)
                        let row = try #require(try await sql.raw("SELECT to_jsonb(r)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self))
                        values.append(row.value)
                        #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table) WHERE created_at = \(bind: now)").first(decoding: CountRow.self)?.value == 1)
                        if table != "resource_catalog" {
                            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table) WHERE expires_at = \(bind: expiry)").first(decoding: CountRow.self)?.value == 1)
                        }
                    }
                    return values
                }
                let committed = try await snapshot()
                for date in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity), wall] {
                    #expect(try await perform(command, date: date) == issued)
                    #expect(try await perform(conflict, date: date) == (path == "same" ? issued : nil))
                    #expect(try await snapshot() == committed)
                }
            } catch {
                first.cancel()
                second?.cancel()
                await gate.releaseTransaction()
                _ = await holder.result
                _ = await first.result
                if let second { _ = await second.result }
                throw error
            }
        }
    }

    @Test("Concurrent presentation operations serialize across targets and replay at the maximum revision",
          arguments: ["alias", "alias-max", "nickname", "nickname-max"], [false, true])
    func presentationOperationConcurrentReplay(path: String, sameResource: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let alias = path.hasPrefix("alias")
            let maximum = path.hasSuffix("-max")
            let starting: Int64 = maximum ? .max : 1
            let expected = try #require(V2ProfileRevision(rawValue: UInt64(starting)))
            let resulting = maximum ? UInt64(Int64.max) : 2
            let baseline = Date(timeIntervalSince1970: 1_750_000_000)
            let now = Date(timeIntervalSince1970: 946_684_800 + 0.00000125)
            let desired = maximum ? "original" : "changed"
            let otherRoom = UUID()
            let resources = alias ? [memberTwoUUID, memberThreeUUID] : [roomUUID, otherRoom]
            let table = alias ? "user_contact_aliases" : "room_member_nicknames"
            let operations = alias ? "contact_alias_operation_receipts" : "group_nickname_operation_receipts"
            if !alias {
                try await sql.raw("INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id, membership_revision) SELECT \(bind: otherRoom), room_shard_id, capacity_profile_id, 1 FROM im_v2.rooms WHERE room_id = \(bind: roomUUID)").run()
                try await sql.raw("INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision) VALUES (\(bind: otherRoom), \(bind: senderUUID), 1)").run()
                try await sql.raw("INSERT INTO im_v2.room_admission (room_id,eligible_member_count,command_window_limit,shard_lease_id,shard_lease_generation) SELECT \(bind: otherRoom),1,command_window_limit,shard_lease_id,shard_lease_generation FROM im_v2.room_admission WHERE room_id=\(bind: roomUUID)").run()
            }
            for resource in resources {
                if alias {
                    try await sql.raw("INSERT INTO im_v2.user_relationships (lower_user_id, higher_user_id, state, requested_by_user_id, updated_at) VALUES (LEAST(\(bind: senderUUID), \(bind: resource)), GREATEST(\(bind: senderUUID), \(bind: resource)), 'accepted', \(bind: senderUUID), \(bind: baseline))").run()
                    try await sql.raw("INSERT INTO im_v2.user_contact_aliases (owner_user_id, target_user_id, remark_name, revision, updated_at) VALUES (\(bind: senderUUID), \(bind: resource), 'original', \(bind: starting), \(bind: baseline))").run()
                } else {
                    try await sql.raw("INSERT INTO im_v2.room_member_nicknames (room_id, user_id, nickname, revision, updated_at) VALUES (\(bind: resource), \(bind: senderUUID), 'original', \(bind: starting), \(bind: baseline))").run()
                }
            }
            let operation = UUID()
            func perform(resource: UUID, date: Date) async throws -> UInt64? {
                let store = PostgresV2ProfilePresentationStore(database: database, nicknameCapacityProfile: try forwardImportTestProfile(), now: { date })
                do {
                    if alias {
                        let command = try V2ContactAliasUpdateCommand(ownerUserID: senderID, targetUserID: .init(uuid: resource), operationID: .init(uuid: operation), expectedRevision: expected, remarkName: "  " + desired + "  ",firstSubmissionDeadlineMilliseconds:UInt64(Int64.max))
                        let proof = try await store.updateContactAlias(command)
                        #expect(proof.validates(command))
                        if maximum {
                            #expect(proof.outcome == .rejected(.revisionConflict(current: expected)))
                            return expected.rawValue
                        }
                        guard case .committed(let value) = proof.outcome else { throw V2ProfilePresentationError.corruptPersistenceState }
                        return value.revision.rawValue
                    }
                    let command = try V2GroupNicknameUpdateCommand(actorUserID: senderID, roomID: .init(uuid: resource), operationID: .init(uuid: operation), expectedRevision: expected, nickname: "  " + desired + "  ",firstSubmissionDeadlineMilliseconds:UInt64(Int64.max))
                    let proof = try await store.updateOwnGroupNickname(command)
                    #expect(proof.validates(command))
                    if maximum {
                        #expect(proof.outcome == .rejected(.revisionConflict(current: expected)))
                        return expected.rawValue
                    }
                    guard case .committed(let value) = proof.outcome else { throw V2ProfilePresentationError.corruptPersistenceState }
                    return value.revision.rawValue
                } catch V2ProfilePresentationError.operationPayloadMismatch {
                    return nil
                }
            }
            let gate = PostgreSQLTransactionGate()
            let holder = Task {
                try await database.transaction { transaction in
                    let held = try #require(transaction as? any SQLDatabase)
                    // Both old paths can read the empty ledger before blocking
                    // on separate state rows. The operation lock must prevent this.
                    _ = try await held.raw("SELECT 1 FROM im_v2.\(unsafeRaw: table) FOR UPDATE").all()
                    await gate.holdTransaction()
                }
            }
            await gate.waitUntilHeld()
            func waitForWriters(_ expectedCount: Int64) async throws {
                for _ in 0..<500 {
                    let waiting = try await sql.raw("SELECT COUNT(*) AS value FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'").first(decoding: CountRow.self)?.value ?? 0
                    if waiting == expectedCount { return }
                    try await Task.sleep(for: .milliseconds(10))
                }
                Issue.record("Expected overlapping presentation operations to wait on database locks")
                throw CancellationError()
            }
            let first = Task { try await perform(resource: resources[0], date: now) }
            var second: Task<UInt64?, Error>?
            do {
                try await waitForWriters(1)
                second = Task { try await perform(resource: resources[sameResource ? 0 : 1], date: baseline) }
                try await waitForWriters(2)
                await gate.releaseTransaction()
                try await holder.value
                #expect(try await first.value == resulting)
                #expect(try await #require(second).value == (sameResource ? resulting : nil))
                #expect(try await count("im_v2." + operations, on: sql) == 1)
                let resourceColumn = alias ? "target_user_id" : "room_id"
                let nameColumn = alias ? "remark_name" : "nickname"
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table) state JOIN im_v2.\(unsafeRaw: operations) op USING (\(unsafeRaw: resourceColumn)) WHERE op.operation_id = \(bind: operation) AND state.updated_at = \(bind: maximum ? baseline : now) AND op.created_at = \(bind: now) AND state.revision = \(bind: Int64(resulting)) AND state.\(unsafeRaw: nameColumn) = \(bind: desired)").first(decoding: CountRow.self)?.value == 1)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table) WHERE \(unsafeRaw: resourceColumn) = \(bind: resources[1]) AND revision = \(bind: starting) AND updated_at = \(bind: baseline) AND \(unsafeRaw: nameColumn) = 'original'").first(decoding: CountRow.self)?.value == 1)
                func snapshot() async throws -> [String] {
                    var values: [String] = []
                    for name in ["user_contact_aliases", "contact_alias_operation_receipts", "room_member_nicknames", "group_nickname_operation_receipts"] {
                        let row = try #require(try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: name) r").first(decoding: StringValueRow.self))
                        values.append(row.value)
                    }
                    return values
                }
                let committed = try await snapshot()
                for date in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity), baseline] {
                    #expect(try await perform(resource: resources[0], date: date) == resulting)
                    #expect(try await perform(resource: resources[1], date: date) == nil)
                    #expect(try await snapshot() == committed)
                }
            } catch {
                first.cancel()
                second?.cancel()
                await gate.releaseTransaction()
                _ = await holder.result
                _ = await first.result
                if let second { _ = await second.result }
                throw error
            }
        }
    }

    @Test("Concurrent relationship and block retries retain one transition at the final policy revision",
          arguments: ["request", "accept", "reject", "remove", "block", "unblock"], [false, true])
    func socialOperationConcurrentReplay(path: String, mismatch: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let baseline = Date(timeIntervalSince1970: 1_750_000_000)
            let now = Date(timeIntervalSince1970: 946_684_800 + 0.00000125)
            let target = UserID(uuid: memberTwoUUID)
            let direct = PostgresV2DirectMessagingStore(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: database), projectionDelivery: SuccessfulProjectionDelivery())
            let room = try await V2DirectRoomOperationTestFixture(store: direct, capacityProfile: forwardImportTestProfile(), roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { baseline }).openedIdentity(actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: target, firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(baseline))
            try await sql.raw("UPDATE im_v2.direct_room_pairs SET direct_policy_revision = \(bind: Int64.max - 1) WHERE room_id = \(bind: room.roomID.uuidValue!)").run()
            if ["accept", "reject", "remove", "block"].contains(path) {
                let state = path == "accept" || path == "reject" ? "pending" : "accepted"
                try await sql.raw("INSERT INTO im_v2.user_relationships (lower_user_id, higher_user_id, state, requested_by_user_id, updated_at) VALUES (LEAST(\(bind: senderUUID), \(bind: memberTwoUUID)), GREATEST(\(bind: senderUUID), \(bind: memberTwoUUID)), \(bind: state), \(bind: memberTwoUUID), \(bind: baseline))").run()
            }
            if path == "unblock" {
                try await sql.raw("INSERT INTO im_v2.user_blocks (blocker_user_id, blocked_user_id, created_at) VALUES (\(bind: senderUUID), \(bind: memberTwoUUID), \(bind: baseline))").run()
            }
            let operation = UUID()
            let block = path == "block" || path == "unblock"
            let shadow = PreferenceReplayClockDelivery()
            let store = PostgresV2SocialRelationshipStore(database: database, projectionDelivery: shadow)
            let originalAction: V2SocialOperationAction = block
                ? .userBlock(path == "block" ? .block : .unblock)
                : .relationship(try #require(V2RelationshipAction(rawValue: path)))
            let changedAction: V2SocialOperationAction = block
                ? .userBlock(path == "block" ? .unblock : .block)
                : .relationship(path == "request" || path == "accept" ? .reject : .request)
            let frozen = try await store.freezeSocialFixture(actorUserID: senderID, targetUserID: target,
                operation: block ? .userBlock(.init(uuid: operation)) : .relationship(.init(uuid: operation)),
                action: originalAction, now: now)
            let conflictCommand = try V2SocialOperationCommand(identity: frozen.identity, action: changedAction,
                expectedRevision: frozen.expectedRevision,
                firstSubmissionDeadlineMilliseconds: frozen.firstSubmissionDeadlineMilliseconds)
            func perform(conflict: Bool, date: Date) async throws -> (kind: String, time: Date?) {
                switch try await store.submitSocialOperation(conflict ? conflictCommand : frozen, now: date) {
                case .receipt(let proof):
                    guard proof.validates(command: conflict ? conflictCommand : frozen), case .applied = proof.outcome else {
                        return ("rejected", nil)
                    }
                    return ("receipt", Date(timeIntervalSince1970: Double(proof.resolvedAtMilliseconds)/1000))
                case .fingerprintConflict: return ("conflict", nil)
                case .unresolved, .deferred: return ("unresolved", nil)
                }
            }
            let gate = PostgreSQLTransactionGate()
            let holder = Task {
                try await database.transaction { transaction in
                    let held = try #require(transaction as? any SQLDatabase)
                    let key = [senderUUID.uuidString.lowercased(), memberTwoUUID.uuidString.lowercased()].sorted().joined(separator: "|")
                    try await held.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
                    await gate.holdTransaction()
                }
            }
            await gate.waitUntilHeld()
            func waitForWriters(_ expected: Int64) async throws {
                for _ in 0..<500 {
                    let waiting = try await sql.raw("SELECT COUNT(*) AS value FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND query LIKE '%pg_advisory_xact_lock%'").first(decoding: CountRow.self)?.value ?? 0
                    if waiting == expected { return }
                    try await Task.sleep(for: .milliseconds(10))
                }
                Issue.record("Expected overlapping social operations to wait on database locks")
                throw CancellationError()
            }
            let first = Task { try await perform(conflict: false, date: now) }
            var second: Task<(kind: String, time: Date?), Error>?
            do {
                try await waitForWriters(1)
                second = Task { try await perform(conflict: mismatch, date: baseline) }
                try await waitForWriters(2)
                await gate.releaseTransaction()
                try await holder.value
                let result = try await first.value
                #expect(result.kind == "receipt")
                let persisted = try #require(result.time)
                let replay = try await #require(second).value
                #expect(replay.kind == (mismatch ? "conflict" : "receipt"))
                #expect(replay.time == (mismatch ? nil : persisted))
                let expectedState: String? = path == "request" ? "pending" : path == "accept" ? "accepted" : nil
                #expect(try await sql.raw("SELECT state AS value FROM im_v2.user_relationships WHERE lower_user_id = LEAST(\(bind: senderUUID), \(bind: memberTwoUUID)) AND higher_user_id = GREATEST(\(bind: senderUUID), \(bind: memberTwoUUID))").first(decoding: StringValueRow.self)?.value == expectedState)
                #expect(try await count("im_v2.user_blocks", on: sql) == (path == "block" ? 1 : 0))
                #expect(try await sql.raw("SELECT direct_policy_revision AS value FROM im_v2.direct_room_pairs WHERE room_id = \(bind: room.roomID.uuidValue!)").first(decoding: CountRow.self)?.value == Int64.max)
                #expect(try await count("im_v2.social_operation_receipts", on: sql) == 1)
                func snapshot() async throws -> [String] {
                    var values: [String] = []
                    for table in ["user_relationships", "social_operation_receipts", "social_relationship_revisions", "user_blocks", "social_block_revisions", "direct_room_pairs", "user_sync_sequences", "user_sync_log"] {
                        guard let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self) else { throw CancellationError() }
                        values.append(row.value)
                    }
                    return values
                }
                let committed = try await snapshot()
                for date in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity), baseline] {
                    let calls = shadow.calls.count
                    let repeated = try await perform(conflict: false, date: date)
                    #expect(repeated.kind == "receipt" && repeated.time == persisted)
                    #expect(try await perform(conflict: true, date: date).kind == "conflict")
                    #expect(shadow.calls.count == calls + 2)
                    #expect(try await snapshot() == committed)
                }
            } catch {
                first.cancel()
                second?.cancel()
                await gate.releaseTransaction()
                _ = await holder.result
                _ = await first.result
                if let second { _ = await second.result }
                throw error
            }
        }
    }

    @Test("Concurrent direct room opens serialize operation identity and reuse the original room timestamp",
          arguments: ["same-operation", "different-operation", "different-target"], [false, true])
    func directRoomOpenConcurrentReplay(path: String, existingPair: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 946_684_800 + 0.00000125)
            let shadow = PreferenceReplayClockDelivery()
            let store = PostgresV2DirectMessagingStore(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: database), projectionDelivery: shadow)
            let profile = try forwardImportTestProfile()
            let target = UserID(uuid: memberTwoUUID)
            let otherTarget = UserID(uuid: memberThreeUUID)
            let proposedRoom = RoomID(uuid: UUID())
            var expectedRoomID = proposedRoom
            if existingPair {
                let existing = try await V2DirectRoomOperationTestFixture(store: store, capacityProfile: profile, roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { now.addingTimeInterval(-10) }).openedIdentity(actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: target, firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now.addingTimeInterval(-10)))
                expectedRoomID = existing.roomID
            }
            let operation = UUID()
            let command = try V2DirectRoomOperationCommand(actorUserID: senderID, operationID: .init(uuid: operation), targetUserID: target, firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            let secondCommand = try V2DirectRoomOperationCommand(actorUserID: senderID,
                operationID: .init(uuid: path == "different-operation" ? UUID() : operation),
                targetUserID: path == "different-target" ? otherTarget : target, firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            let gate = PostgreSQLTransactionGate()
            let holder = Task {
                try await database.transaction { transaction in
                    let held = try #require(transaction as? any SQLDatabase)
                    // Hold both domain pair locks to force overlap after identity admission.
                    for peer in [memberTwoUUID, memberThreeUUID] {
                        let key = [senderUUID.uuidString.lowercased(), peer.uuidString.lowercased()].sorted().joined(separator: "|")
                        try await held.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
                    }
                    await gate.holdTransaction()
                }
            }
            await gate.waitUntilHeld()
            func waitForWriters(_ expected: Int64) async throws {
                for _ in 0..<500 {
                    let waiting = try await sql.raw("SELECT COUNT(*) AS value FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND query LIKE '%pg_advisory_xact_lock%'").first(decoding: CountRow.self)?.value ?? 0
                    if waiting == expected { return }
                    try await Task.sleep(for: .milliseconds(10))
                }
                Issue.record("Expected overlapping direct-room creators to wait on database locks")
                throw CancellationError()
            }
            let first = Task {
                try await store.submitDirectRoomOperation(command, roomID: proposedRoom, roomShardID: "room-a", capacityProfile: profile, now: now)
            }
            var second: Task<V2DirectRoomOperationResult, Error>?
            do {
                try await waitForWriters(1)
                second = Task {
                    try await store.submitDirectRoomOperation(secondCommand, roomID: .init(uuid: UUID()), roomShardID: "room-a",
                        capacityProfile: profile, now: now.addingTimeInterval(1))
                }
                try await waitForWriters(2)
                await gate.releaseTransaction()
                try await holder.value
                guard case .receipt(let opened) = try await first.value,
                      case .opened(let openedRoomID, let createdAtMilliseconds) = opened.outcome else { throw CancellationError() }
                #expect(opened.validates(command: command) && openedRoomID == expectedRoomID)
                let secondResult = try await #require(second).value
                switch path {
                case "different-operation":
                    guard case .receipt(let proof) = secondResult else { throw CancellationError() }
                    #expect(proof.validates(command: secondCommand) && proof.outcome == opened.outcome)
                case "different-target": #expect(secondResult == .fingerprintConflict)
                default: #expect(secondResult == .receipt(opened))
                }
                let operationCount: Int64 = (existingPair ? 1 : 0) + (path == "different-operation" ? 2 : 1)
                #expect(try await count("im_v2.direct_room_owner_receipts", on: sql) == operationCount)
                #expect(try await count("im_v2.direct_room_pairs", on: sql) == 1)
                #expect(try await count("im_v2.rooms WHERE room_kind = 'direct'", on: sql) == 1)
                let storedTime = try #require(try await sql.raw("SELECT created_at AS value FROM im_v2.direct_room_pairs WHERE room_id = \(bind: openedRoomID.uuidValue!)").first(decoding: RevocationClockDateRow.self)).value
                #expect(try v2GatewayMilliseconds(storedTime) == Int64(createdAtMilliseconds))
                #expect(try await sql.raw("SELECT next_sequence AS value FROM im_v2.user_sync_sequences WHERE user_id = \(bind: senderUUID)").first(decoding: CountRow.self)?.value == nil)
                #expect(try await count("im_v2.user_sync_log WHERE projection_kind = 'direct_room_profile'", on: sql) == 0)
                #expect(try await count("im_v2.user_state_event_outbox WHERE projection_kind = 'direct_room_profile'", on: sql) == 1)
                #expect(try await sql.raw("""
                    SELECT COUNT(*) AS value FROM im_v2.user_state_event_outbox event
                    JOIN im_v2.rooms room ON room.room_id = (event.payload->>'room_id')::uuid
                    WHERE event.projection_kind = 'direct_room_profile'
                      AND (event.payload->>'room_created_at_ms')::bigint = floor(extract(epoch FROM room.created_at) * 1000)::bigint
                    """).first(decoding: CountRow.self)?.value == 1)
                func snapshot() async throws -> [String] {
                    var values: [String] = []
                    for table in ["rooms", "direct_room_pairs", "direct_room_owner_receipts", "room_memberships", "room_admission", "user_direct_send_policy_versions", "user_sync_sequences", "user_sync_log", "user_state_event_outbox"] {
                        guard let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self) else { throw CancellationError() }
                        values.append(row.value)
                    }
                    return values
                }
                let committed = try await snapshot()
                let conflict = try V2DirectRoomOperationCommand(actorUserID: senderID, operationID: .init(uuid: operation), targetUserID: otherTarget, firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
                for date in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity), now] {
                    let calls = shadow.calls
                    #expect(try await store.submitDirectRoomOperation(command, roomID: .init(uuid: UUID()), roomShardID: "room-a", capacityProfile: profile, now: date) == .receipt(opened))
                    #expect(try await store.submitDirectRoomOperation(conflict, roomID: .init(uuid: UUID()), roomShardID: "room-a", capacityProfile: profile, now: date) == .fingerprintConflict)
                    #expect(shadow.calls == calls)
                    #expect(try await snapshot() == committed)
                }
            } catch {
                first.cancel()
                second?.cancel()
                await gate.releaseTransaction()
                _ = await holder.result
                _ = await first.result
                if let second { _ = await second.result }
                throw error
            }
        }
    }
    @Test("Concurrent direct preference retries retain one policy transition and committed timestamp",
          arguments: ["stranger", "stranger-final-revision", "user-add"], [false, true])
    func directPreferenceConcurrentReplay(path: String, mismatch: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 946_684_800 + 0.00000125)
            let later = Date(timeIntervalSince1970: 1_750_000_000)
            let stranger = path != "user-add"
            let finalRevision = path == "stranger-final-revision"
            let table = stranger ? "user_stranger_message_preferences" : "user_add_preferences"
            let column = stranger ? "allows_stranger_messages" : "allows_being_added"
            let operations = "account_preference_receipts"
            try await sql.raw("INSERT INTO im_v2.\(unsafeRaw: table) (user_id, \(unsafeRaw: column), updated_at) VALUES (\(bind: senderUUID), TRUE, \(bind: later))").run()
            if stranger {
                try await sql.raw("INSERT INTO im_v2.user_direct_send_policy_versions (user_id, revision, updated_at) VALUES (\(bind: senderUUID), \(bind: finalRevision ? Int64.max - 1 : 1), \(bind: later)) ON CONFLICT (user_id) DO UPDATE SET revision = EXCLUDED.revision, updated_at = EXCLUDED.updated_at").run()
            }
            let operation = UUID()
            let shadow = PreferenceReplayClockDelivery()
            let store = PostgresV2AccountPreferenceOperationStore(database: database, projectionDelivery: shadow,
                authorizationCoordinator: V2DirectAuthorizationCoordinator(controlDatabase: database, ownerDatabases: ["room-a": database]))
            let frozen = try await store.freezePreferenceFixture(owner: senderID,
                operation: stranger ? .strangerMessagePreference(.init(uuid: operation)) : .userAddPreference(.init(uuid: operation)),
                value: stranger ? .strangerMessage(.deny) : .userAdd(.deny), now: now)
            let conflicting = try V2AccountPreferenceCommand(identity: frozen.identity,
                value: stranger ? .strangerMessage(.allow) : .userAdd(.allow), expectedRevision: frozen.expectedRevision,
                firstSubmissionDeadlineMilliseconds: frozen.firstSubmissionDeadlineMilliseconds)
            func perform(conflict: Bool, date: Date) async throws -> PreferenceClockComparison {
                switch try await store.submit(conflict ? conflicting : frozen, now: date) {
                case .receipt(let proof):
                    guard proof.validates(command: conflict ? conflicting : frozen), case .applied = proof.outcome else { throw CancellationError() }
                    return .applied(Date(timeIntervalSince1970: Double(proof.resolvedAtMilliseconds)/1000))
                case .fingerprintConflict: return .idempotencyConflict
                case .deferred, .unresolved: throw CancellationError()
                }
            }
            let gate = PostgreSQLTransactionGate()
            let holder = Task {
                try await database.transaction { transaction in
                    let held = try #require(transaction as? any SQLDatabase)
                    try await held.raw("SELECT user_id FROM im_v2.\(unsafeRaw: table) WHERE user_id = \(bind: senderUUID) FOR UPDATE").run()
                    await gate.holdTransaction()
                }
            }
            await gate.waitUntilHeld()
            func waitForWriters(_ expected: Int64) async throws {
                for _ in 0..<500 {
                    let waiting = try await sql.raw("SELECT COUNT(*) AS value FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND (query LIKE \(bind: "%im_v2." + table + "%") OR query LIKE '%pg_advisory_xact_lock%')").first(decoding: CountRow.self)?.value ?? 0
                    if waiting == expected { return }
                    try await Task.sleep(for: .milliseconds(10))
                }
                Issue.record("Expected overlapping direct preference writers to wait on database locks")
                throw CancellationError()
            }
            let first = Task { try await perform(conflict: false, date: now) }
            var second: Task<PreferenceClockComparison, Error>?
            do {
                try await waitForWriters(1)
                second = Task { try await perform(conflict: mismatch, date: later) }
                try await waitForWriters(2)
                await gate.releaseTransaction()
                try await holder.value
                guard case .applied(let persisted) = try await first.value else { throw CancellationError() }
                #expect(try await #require(second).value == (mismatch ? .idempotencyConflict : .applied(persisted)))
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table) WHERE user_id = \(bind: senderUUID) AND NOT \(unsafeRaw: column) AND floor(extract(epoch FROM updated_at)*1000)::bigint = \(bind: try v2GatewayMilliseconds(persisted))").first(decoding: CountRow.self)?.value == 1)

                if stranger {
                    #expect(try await sql.raw("SELECT revision AS value FROM im_v2.user_direct_send_policy_versions WHERE user_id = \(bind: senderUUID)").first(decoding: CountRow.self)?.value == (finalRevision ? Int64.max : 2))
                }
                func snapshot() async throws -> [String] {
                    var values: [String] = []
                    for name in [table, operations, "user_direct_send_policy_versions", "user_sync_sequences", "user_sync_log"] {
                        guard let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: name) r").first(decoding: StringValueRow.self) else { throw CancellationError() }
                        values.append(row.value)
                    }
                    return values
                }
                let committed = try await snapshot()
                for date in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity), later] {
                    let calls = shadow.calls
                    #expect(try await perform(conflict: false, date: date) == .applied(persisted))
                    #expect(try await perform(conflict: true, date: date) == .idempotencyConflict)
                    #expect(shadow.calls.count == calls.count + 1)
                    #expect(try await snapshot() == committed)
                }
                #expect(try await count("im_v2." + operations, on: sql) == 1)
                #expect(try await sql.raw("SELECT next_sequence AS value FROM im_v2.user_sync_sequences WHERE user_id = \(bind: senderUUID)").first(decoding: CountRow.self)?.value == 1)
            } catch {
                first.cancel()
                second?.cancel()
                await gate.releaseTransaction()
                _ = await holder.result
                _ = await first.result
                if let second { _ = await second.result }
                throw error
            }
        }
    }

    @Test("Direct policy revision exhaustion rolls back first replies and policy changes",
          arguments: ["room-log", "stranger", "relationship", "block"])
    func directPolicyRevisionBoundary(path: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let isSend = path == "room-log"
            let direct = PostgresV2DirectMessagingStore(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: database), projectionDelivery: SuccessfulProjectionDelivery())
            let social = PostgresV2SocialRelationshipStore(database: database, projectionDelivery: SuccessfulProjectionDelivery())
            var rooms: [RoomID] = []
            for peer in [memberTwoUUID] {
                let room = try await V2DirectRoomOperationTestFixture(store: direct, capacityProfile: profile, roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { now }).openedIdentity(actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: peer), firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
                rooms.append(room.roomID)
            }
            if path == "block" {
                try await sql.raw("INSERT INTO im_v2.user_relationships (lower_user_id, higher_user_id, state, requested_by_user_id, updated_at) VALUES (LEAST(\(bind: senderUUID), \(bind: memberTwoUUID)), GREATEST(\(bind: senderUUID), \(bind: memberTwoUUID)), 'accepted', \(bind: senderUUID), \(bind: now))").run()
            }
            func store() throws -> PostgresV2RoomWriteStore {
                PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled)
            }
            let writer = try store()
            let replayWriter = try store()
            func request(_ room: RoomID) throws -> V2RoomWriteRequest {
                .init(command: try .init(roomID: room, senderUserID: senderID, clientMessageID: .init(uuid: UUID()),
                    text: "direct revision boundary", limits: .init(maxUTF8Bytes: 64)), capacityProfile: profile,
                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())), now: now)
            }
            let inputs = try rooms.map { try request($0) }
            let operation = UUID()
            let preferences = PostgresV2AccountPreferenceOperationStore(database: database,
                projectionDelivery: SuccessfulProjectionDelivery(), authorizationCoordinator:
                    V2DirectAuthorizationCoordinator(controlDatabase: database, ownerDatabases: ["room-a": database]))
            let frozenPreference: V2AccountPreferenceCommand? = path == "stranger"
                ? try await preferences.freezePreferenceFixture(owner: senderID,
                    operation: .strangerMessagePreference(.init(uuid: operation)), value: .strangerMessage(.deny), now: now) : nil
            let frozenSocial: V2SocialOperationCommand?
            if path == "relationship" || path == "block" {
                frozenSocial = try await social.freezeSocialFixture(actorUserID: senderID, targetUserID: .init(uuid: memberTwoUUID),
                    operation: path == "relationship" ? .relationship(.init(uuid: operation)) : .userBlock(.init(uuid: operation)),
                    action: path == "relationship" ? .relationship(.request) : .userBlock(.block), now: now)
            } else { frozenSocial = nil }
            var receipts: [V2MessageAcceptanceReceipt] = []
            func perform(replay: Bool) async throws {
                switch path {
                case "stranger":
                    guard case .receipt(let proof) = try await preferences.submit(try #require(frozenPreference), now: now),
                          case .applied = proof.outcome else { throw CancellationError() }
                    #expect(proof.validates(command: try #require(frozenPreference)))
                case "relationship", "block":
                    guard case .receipt(let proof) = try await social.submitSocialOperation(try #require(frozenSocial), now: now),
                          case .applied = proof.outcome else { throw CancellationError() }
                    #expect(proof.validates(command: try #require(frozenSocial)))
                default:
                    var outcomes: [V2SendMessageOutcome] = []
                    let active = replay ? replayWriter : writer
                    for input in inputs {
                        outcomes.append(try await active.accept(command: input.command, capacityProfile: profile,
                            identifiers: input.identifiers, now: input.now))
                    }
                    for (index, outcome) in outcomes.enumerated() {
                        switch outcome {
                        case .accepted(let message): #expect(!replay); receipts.append(message.receipt)
                        case .idempotent(let receipt): #expect(replay); #expect(receipts[index] == receipt)
                        default: Issue.record("Expected a committed message")
                        }
                    }
                }
            }
            let room = try #require(rooms[0].uuidValue)
            let table = path == "stranger" ? "user_direct_send_policy_versions" : "direct_room_pairs"
            let key = path == "stranger" ? "user_id" : "room_id"
            let rowID = path == "stranger" ? senderUUID : room
            let column = path == "stranger" ? "revision" : "direct_policy_revision"
            try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET \(unsafeRaw: column) = \(bind: Int64.max) WHERE \(unsafeRaw: key) = \(bind: rowID)").run()
            func revision() async throws -> Int64? {
                try await sql.raw("SELECT \(unsafeRaw: column) AS value FROM im_v2.\(unsafeRaw: table) WHERE \(unsafeRaw: key) = \(bind: rowID)").first(decoding: CountRow.self)?.value
            }
            func snapshot() async throws -> [String] {
                var result = [try await crossStoreClockState(on: sql)]
                for name in ["rooms", "room_memberships", "direct_room_pairs", "room_admission", "shard_admission_pools",
                    "messages", "message_send_completions", "message_projection_states", "message_content_versions", "room_events",
                    "stranger_message_windows",
                    "user_direct_send_policy_versions", "user_stranger_message_preferences", "account_preference_receipts",
                    "user_relationships", "social_operation_receipts", "user_blocks"] {
                    guard let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: name) r").first(decoding: StringValueRow.self) else { throw CancellationError() }
                    result.append(row.value)
                }
                return result
            }
            let before = try await snapshot()
            for _ in 0..<2 {
                do { try await perform(replay: false); Issue.record("Expected revision exhaustion") }
                catch {
                    switch path {
                    case "stranger": #expect(error as? V2DirectMessagingStoreError == .corruptPersistenceState)
                    case "relationship", "block": #expect(error as? V2SocialRelationshipStoreError == .corruptPersistenceState)
                    default: #expect(error as? V2RoomWriteStoreError == .corruptPersistenceState)
                    }
                }
                #expect(try await snapshot() == before)
            }
            try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET \(unsafeRaw: column) = \(bind: Int64.max - 1) WHERE \(unsafeRaw: key) = \(bind: rowID)").run()
            try await perform(replay: false)
            #expect(try await revision() == Int64.max)
            let committed = try await snapshot()
            for _ in 0..<2 { try await perform(replay: true); #expect(try await snapshot() == committed) }
            if isSend {
                // Once the first-reply marker is true, ordinary later messages
                // need no policy revision. The maximum revision stays usable.
                for room in rooms {
                    let input = try request(room)
                    guard case .accepted = try await replayWriter.accept(command: input.command, capacityProfile: profile,
                        identifiers: input.identifiers, now: input.now) else { throw CancellationError() }
                }
                #expect(try await revision() == Int64.max)
                #expect(try await count("im_v2.messages", on: sql) == Int64(rooms.count * 2))
            }
        }
    }

    @Test("Room and timeline cursor exhaustion preserves rollback and committed replay",
          arguments: ["room-log", "group", "hybrid", "hybrid-batch", "denial"], [false, true])
    func roomWriteCursorBoundary(path: String, timeline: Bool) async throws {
        let hybrid = path.hasPrefix("hybrid")
        let direct = path != "group" && !hybrid
        let batch = path == "hybrid-batch"
        try await withForwardOwnerDatabases(mode: hybrid ? .large : .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            var rooms: [RoomID] = []
            if direct {
                for peer in [memberTwoUUID] {
                    let opened = try await V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: database), projectionDelivery: SuccessfulProjectionDelivery()), capacityProfile: profile, roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { now }).openedIdentity(actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: peer), firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
                    rooms.append(opened.roomID)
                }
            } else { rooms = batch ? [roomID, roomID] : [roomID] }
            let cache = V2DirectRoomLogFastAppendCache()
            func store(warm: Bool) throws -> PostgresV2RoomWriteStore {
                PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled,
                    directRoomLogFastAppendCache: warm ? cache : .init())
            }
            let warm = try store(warm: true)
            let replay = try store(warm: false)
            func request(_ room: RoomID) throws -> V2RoomWriteRequest {
                .init(command: try .init(roomID: room, senderUserID: senderID, clientMessageID: .init(uuid: UUID()),
                    text: "room cursor boundary", limits: .init(maxUTF8Bytes: 64)), capacityProfile: profile,
                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())), now: now)
            }
            func scalar(_ input: V2RoomWriteRequest, on writer: PostgresV2RoomWriteStore) async throws -> V2SendMessageOutcome {
                try await writer.accept(command: input.command, capacityProfile: profile, identifiers: input.identifiers, now: input.now)
            }
            var baseline: [(V2RoomWriteRequest, V2MessageAcceptanceReceipt)] = []
            for room in Set(rooms) {
                let input = try request(room)
                guard case .accepted(let message) = try await scalar(input, on: warm) else { throw CancellationError() }
                baseline.append((input, message.receipt))
            }
            if path == "denial" {
                _ = try await PostgresV2AccountPreferenceOperationStore(database: database,
                    projectionDelivery: SuccessfulProjectionDelivery(), authorizationCoordinator:
                        V2DirectAuthorizationCoordinator(controlDatabase: database, ownerDatabases: ["room-a": database]))
                    .executePreferenceFixture(owner: .init(uuid: memberTwoUUID), operation: .strangerMessagePreference(.init(uuid: UUID())),
                        value: .strangerMessage(.deny), now: now)
            }
            let writer = try store(warm: false)
            let inputs = try rooms.map { try request($0) }
            func perform() async throws -> [V2SendMessageOutcome] {
                if batch { return try await writer.acceptAtomically(requests: inputs) }
                return [try await scalar(inputs[0], on: writer)]
            }
            func snapshot() async throws -> [String] {
                var result = [try await crossStoreClockState(on: sql)]
                for table in ["rooms", "room_memberships", "direct_room_pairs", "room_admission", "messages",
                    "message_send_completions", "message_projection_states", "message_content_versions", "message_media_references",
                    "message_mentions", "room_events", "room_timeline_activities", "direct_message_denials",
                    "stranger_message_windows"] {
                    guard let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self) else { throw CancellationError() }
                    result.append(row.value)
                }
                return result
            }
            let column = timeline ? "timeline_sequence" : "room_sequence"
            let room = try #require(rooms[0].uuidValue)
            let needed: Int64 = path == "hybrid-batch" ? 2 : 1
            try await sql.raw("UPDATE im_v2.rooms SET \(unsafeRaw: column) = \(bind: Int64.max - needed + 1) WHERE room_id = \(bind: room)").run()
            let before = try await snapshot()
            for (input, receipt) in baseline { #expect(try await scalar(input, on: replay) == .idempotent(receipt)) }
            #expect(try await snapshot() == before)
            if path == "denial" && !timeline {
                // A private denial consumes only a timeline position. A full
                // message cursor must not suppress this normal business result.
                guard case .denied(let denial) = try await scalar(inputs[0], on: writer) else { throw CancellationError() }
                let committed = try await snapshot()
                #expect(try await scalar(inputs[0], on: replay) == .denied(denial))
                #expect(try await snapshot() == committed)
                #expect(try await sql.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id = \(bind: room)").first(decoding: CountRow.self)?.value == Int64.max)
                return
            }
            for _ in 0..<2 {
                do { _ = try await perform(); Issue.record("Expected cursor exhaustion to reject the whole write") }
                catch {
                    if path == "hybrid-batch" { #expect(error is V2RoomWriteStoreError || error is V2AtomicRoomWriteBatchError) }
                    else { #expect(error as? V2RoomWriteStoreError == .corruptPersistenceState) }
                }
                #expect(try await snapshot() == before)
            }
            try await sql.raw("UPDATE im_v2.rooms SET \(unsafeRaw: column) = \(bind: Int64.max - needed) WHERE room_id = \(bind: room)").run()
            let outcomes = try await perform()
            #expect(outcomes.count == inputs.count)
            #expect(try await sql.raw("SELECT \(unsafeRaw: column) AS value FROM im_v2.rooms WHERE room_id = \(bind: room)").first(decoding: CountRow.self)?.value == Int64.max)
            let committed = try await snapshot()
            for _ in 0..<2 {
                for (input, outcome) in zip(inputs, outcomes) {
                    switch outcome {
                    case .accepted(let message): #expect(try await scalar(input, on: replay) == .idempotent(message.receipt))
                    case .denied(let denial): #expect(path == "denial"); #expect(try await scalar(input, on: replay) == .denied(denial))
                    default: Issue.record("Expected a committed result at the final valid cursor")
                    }
                }
                #expect(try await snapshot() == committed)
            }
        }
    }

    @Test("User sequence exhaustion preserves committed direct messages and recoverable personal events",
          arguments: ["scalar-sender", "scalar-peer", "denial-activity", "denial-capability"])
    func directWriteProjectionSequenceBoundary(path: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, target, sql, targetSQL, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let denied = path.hasPrefix("denial")
            let direct = PostgresV2DirectMessagingStore(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: database), projectionDelivery: SuccessfulProjectionDelivery())
            var rooms: [RoomID] = []
            for peer in [memberTwoUUID] {
                let room = try await V2DirectRoomOperationTestFixture(store: direct, capacityProfile: profile, roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { now }).openedIdentity(actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: peer), firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
                rooms.append(room.roomID)
            }
            if denied {
                _ = try await PostgresV2AccountPreferenceOperationStore(database: database, projectionDelivery: SuccessfulProjectionDelivery(), authorizationCoordinator: .init(controlDatabase: database, ownerDatabases: [:])).executePreferenceFixture(owner: .init(uuid: memberTwoUUID), operation: .strangerMessagePreference(.init(uuid: UUID())), value: .strangerMessage(.deny), now: now)
            }
            func store() throws -> PostgresV2RoomWriteStore {
                PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400),
                    contentReviewMode: .disabled)
            }
            let writer = try store()
            let replayWriter = try store()
            let requests = try rooms.map { room in
                V2RoomWriteRequest(command: try .init(roomID: room, senderUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "direct sequence boundary", limits: .init(maxUTF8Bytes: 64)),
                    capacityProfile: profile,
                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())), now: now)
            }
            func scalar(_ request: V2RoomWriteRequest, on active: PostgresV2RoomWriteStore) async throws -> V2SendMessageOutcome {
                try await active.accept(command: request.command, capacityProfile: profile,
                    identifiers: request.identifiers, now: request.now)
            }
            func perform() async throws -> [V2SendMessageOutcome] {
                return [try await scalar(requests[0], on: writer)]
            }
            func snapshot() async throws -> [String] {
                var result = [try await crossStoreClockState(on: sql)]
                for table in ["rooms", "room_memberships", "direct_room_pairs", "room_admission", "shard_admission_pools",
                    "messages", "message_send_completions", "message_projection_states", "message_content_versions",
                    "message_media_references", "message_mentions", "room_events", "room_timeline_activities",
                    "direct_message_denials", "stranger_message_windows", "user_state_event_outbox",
                    ] {
                    guard let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self) else { throw CancellationError() }
                    result.append(row.value)
                }
                return result
            }
            let recipient = path.hasSuffix("peer") ? memberTwoUUID : senderUUID
            let needed: Int64 = denied ? 2 : 1
            let outbox = try PostgresV2UserStateEventOutbox(database: database)
            let projector = try PostgresV2UserStateEventProjector(database: target)
            let worker = V2UserStateEventWorker(outbox: outbox, projector: projector, now: { now })
            _ = try await worker.runOnce(limit: 100)
            for connection in [sql, targetSQL] {
                try await connection.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: recipient), \(bind: Int64.max)) ON CONFLICT (user_id) DO UPDATE SET next_sequence = EXCLUDED.next_sequence").run()
            }
            let outcomes = try await perform()
            #expect(outcomes.count == requests.count)
            // The room commit is independent of the exhausted user target.
            _ = try await worker.runOnce(limit: 100)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_state_event_outbox WHERE user_id = \(bind: recipient) AND state = 'paused'").first(decoding: CountRow.self)?.value == needed)
            #expect(try await targetSQL.raw("SELECT next_sequence AS value FROM im_v2.user_sync_sequences WHERE user_id = \(bind: recipient)").first(decoding: CountRow.self)?.value == Int64.max)
            #expect(try await targetSQL.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE user_id = \(bind: recipient) AND user_sync_sequence = \(bind: Int64.max)").first(decoding: CountRow.self)?.value == 0)
            #expect(try await worker.runOnce(limit: 100) == 0)
            // Restore test capacity and replay the preserved source events.
            try await targetSQL.raw("UPDATE im_v2.user_sync_sequences SET next_sequence = \(bind: Int64.max - needed) WHERE user_id = \(bind: recipient)").run()
            try await sql.raw("UPDATE im_v2.user_state_event_outbox SET state = 'pending', next_attempt_at = \(bind: now) WHERE user_id = \(bind: recipient) AND state = 'paused'").run()
            #expect(try await worker.runOnce(limit: 100) == Int(needed))
            #expect(try await targetSQL.raw("SELECT next_sequence AS value FROM im_v2.user_sync_sequences WHERE user_id = \(bind: recipient)").first(decoding: CountRow.self)?.value == Int64.max)
            #expect(try await targetSQL.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE user_id = \(bind: recipient) AND user_sync_sequence > \(bind: Int64.max - needed)").first(decoding: CountRow.self)?.value == needed)
            #expect(try await sql.raw("SELECT next_sequence AS value FROM im_v2.user_sync_sequences WHERE user_id = \(bind: recipient)").first(decoding: CountRow.self)?.value == Int64.max)
            #expect(try await count("im_v2.messages", on: sql) == (denied ? 0 : Int64(requests.count)))
            #expect(try await count("im_v2.direct_message_denials", on: sql) == (denied ? 1 : 0))
            let committed = try await snapshot()
            // A restarted worker replays durable operations through the scalar
            // path without precharged process credits. Replay must not need
            // another sequence allocation or alter the committed state.
            for _ in 0..<2 {
                for (request, outcome) in zip(requests, outcomes) {
                    switch outcome {
                    case .accepted(let message): #expect(try await scalar(request, on: replayWriter) == .idempotent(message.receipt))
                    case .denied(let denial): #expect(denied); #expect(try await scalar(request, on: replayWriter) == .denied(denial))
                    default: Issue.record("Expected a committed accepted or denied operation")
                    }
                }
                #expect(try await snapshot() == committed)
            }
        }
    }

    @Test("First direct sends preserve profile and capability timestamp precision",
          arguments: [0, 1, 2, 3, 4, 5, 6])
    func directAuxiliaryProjectionTimestampPrecision(clock: Int) async throws {
        let dates: [Double] = [946_684_800 - 0.00000075, 946_684_800 + 0.00000125, 1_750_000_000 + 0.12375,
            1_750_000_000 + 0.99999975, -0.00075, 946_684_800 - 211_813_488_000, 946_684_800 + 9_223_371_331_200 - 10]
        let seconds = dates[clock]
        try await withForwardOwnerDatabases(mode: .standard) { database, target, sql, targetSQL, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let sourceTime = Date(timeIntervalSince1970: seconds)
            // Keep stranger quota cutoffs representable while testing extreme source profile dates.
            let now = seconds < -1_000_000_000 ? base : sourceTime
            try await sql.raw("UPDATE im_v2.public_user_profiles SET updated_at = \(bind: sourceTime)").run()
            let profile = try forwardImportTestProfile()
            let expiry = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 1)
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until = \(bind: expiry)").run()
            var rooms: [RoomID] = []
            var openingIDs: [UUID] = []
            for peer in [memberTwoUUID, memberThreeUUID] {
                let operation = UUID()
                let room = try await V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: database), projectionDelivery: SuccessfulProjectionDelivery()), capacityProfile: profile, roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { base }).openedIdentity(actorUserID: senderID, operationID: .init(uuid: operation), targetUserID: .init(uuid: peer), firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(base))
                rooms.append(room.roomID); openingIDs.append(operation)
            }
            let writer = PostgresV2RoomWriteStore(database: database,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled)
            let requests = try rooms.map { room in
                V2RoomWriteRequest(command: try .init(roomID: room, senderUserID: senderID, clientMessageID: .init(uuid: UUID()),
                    text: "Direct auxiliary precision", limits: .init(maxUTF8Bytes: 64)), capacityProfile: profile,
                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())), now: now)
            }
            var outcomes: [V2SendMessageOutcome] = []
            for request in requests {
                outcomes.append(try await writer.accept(
                    command: request.command, capacityProfile: profile,
                    identifiers: request.identifiers, now: now
                ))
            }
            #expect(outcomes.count == 2)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 0)
            let outbox = try PostgresV2UserStateEventOutbox(database: database)
            let projector = try PostgresV2UserStateEventProjector(database: target)
            // The owner includes lock/identity-read elapsed time in creation.
            // Claim at the actual persisted eligibility boundary of every event.
            let deliveryTime = try #require(try await sql.raw("SELECT MAX(next_attempt_at) AS value FROM im_v2.user_state_event_outbox").first(decoding: RevocationClockDateRow.self)).value
            let leases = try await deliverUserStateEvents(outbox, projector: projector, now: deliveryTime, leaseDuration: 1, limit: 100)
            #expect(leases.count == 6)
            for lease in leases where lease.event.kind == .directRoomProfile {
                let object = try #require(JSONSerialization.jsonObject(with: Data(lease.event.payloadJSON.utf8)) as? [String: Any])
                let rawRoom = try #require(object["room_id"] as? String)
                let projectedRoomID = try #require(UUID(uuidString: rawRoom))
                let committed = try #require(try await sql.raw("SELECT floor(extract(epoch FROM created_at)*1000)::bigint AS value FROM im_v2.rooms WHERE room_id = \(bind: projectedRoomID)").first(decoding: CountRow.self))
                #expect((object["room_created_at_ms"] as? NSNumber)?.int64Value == committed.value)
            }
            for (index, outcome) in outcomes.enumerated() {
                guard case .accepted(let message) = outcome else { throw CancellationError() }
                let source = try #require(message.sourceEventID).uuidValue!
                let stored = try await sql.raw("SELECT created_at AS value FROM im_v2.messages WHERE message_id = \(bind: message.messageID.uuidValue!)").first(decoding: RevocationClockDateRow.self)
                let storedTime = try #require(stored).value
                let expectedProfile = try await sql.raw("SELECT updated_at AS value FROM im_v2.public_user_profiles WHERE user_id = \(bind: senderUUID)").first(decoding: RevocationClockDateRow.self)
                let profileMS = try v2GatewayMilliseconds(#require(expectedProfile).value)
                let opening = try await targetSQL.raw("SELECT (payload->>'updated_at_ms')::bigint AS value FROM im_v2.user_sync_log WHERE source_event_id = \(bind: openingIDs[index]) AND projection_kind = 'direct_room_profile'").first(decoding: CountRow.self)
                #expect(opening?.value == profileMS)
                let projections = try await targetSQL.raw("""
                    SELECT COUNT(*) AS value FROM im_v2.user_sync_log l
                    WHERE l.source_event_id = \(bind: source) AND l.created_at = \(bind: now) AND (
                        (l.projection_kind = 'direct_sending_capability' AND l.user_id = \(bind: senderUUID)
                         AND (l.payload->>'updated_at_ms')::bigint = \(bind: try v2GatewayMilliseconds(storedTime)))
                        OR (l.projection_kind = 'direct_room_profile' AND l.user_id = \(bind: index == 0 ? memberTwoUUID : memberThreeUUID)
                            AND (l.payload->>'updated_at_ms')::bigint = \(bind: profileMS))
                    )
                    """).first(decoding: CountRow.self)
                #expect(projections?.value == 2)
                let before = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.user_state_event_outbox r").first(decoding: StringValueRow.self)
                let request = requests[index]
                #expect(try await writer.accept(command: request.command, capacityProfile: profile, identifiers: request.identifiers, now: base) == .idempotent(message.receipt))
                let after = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.user_state_event_outbox r").first(decoding: StringValueRow.self)
                #expect(before?.value == after?.value)
            }
            #expect(try await count("im_v2.messages", on: sql) == 2)
            #expect(try await count("im_v2.user_sync_log WHERE projection_kind = 'direct_room_profile'", on: targetSQL) == 4)
            #expect(try await count("im_v2.user_sync_log WHERE projection_kind = 'direct_sending_capability'", on: targetSQL) == 2)
        }
    }

    @Test("Group creation proof and owner facts share the committed millisecond time",
          arguments: [V2GroupCapacityClass.standard, .large])
    func groupCreationResponseTimestampPrecision(mode: V2GroupCapacityClass) async throws {
        try await withForwardOwnerDatabases(mode: mode) { database, _, sql, _, _ in
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100_000, maxCommandsPerWindow: 10, retryAfterSeconds: 3))
            let audience: [UserID]
            if mode == .large {
                audience = (0..<5_000).map { _ in UserID(uuid: UUID()) }
                try await sql.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,revision,created_at,updated_at) SELECT u, 'p' || left(replace(u::text,'-',''),20), 'Precision member', 1, \(bind: Date(timeIntervalSince1970: 1_750_000_000)), \(bind: Date(timeIntervalSince1970: 1_750_000_000)) FROM unnest(\(bind: audience.map { $0.uuidValue! })::uuid[]) u").run()
            } else { audience = [.init(uuid: memberTwoUUID)] }
            let dates: [Double] = [946_684_800 - 0.00000075, 946_684_800 + 0.00000075,
                946_684_800 + 0.00000125, 1_750_000_000 + 0.99999975]
            for seconds in dates {
                let now = Date(timeIntervalSince1970: seconds)
                try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until = \(bind: now.addingTimeInterval(600))").run()
                let members = try V2GroupCreationAudience.canonical(audience, actorUserID: senderID)
                let intent = try V2GroupCreationIntent(identity: .init(accountID: senderID, scope: .account(senderID),
                    operation: .groupRoom(.init(uuid: UUID()))), title: "Precision group", capacityClass: mode,
                    initialMemberCount: members.count, audienceDigest: V2GroupCreationAudience.digest(members),
                    firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
                let fixture = try V2GroupCreationOperationTestFixture(control: database, owner: database,
                    shardID: "room-a", capacityProfile: profile, now: { now })
                let created = try await fixture.create(intent: intent, canonicalMembers: members, now: now)
                let room = created.roomID.uuidValue!
                struct Committed: Decodable { let createdAt: Date; enum CodingKeys: String, CodingKey { case createdAt = "created_at" } }
                let committed = try #require(try await sql.raw("SELECT created_at FROM im_v2.rooms WHERE room_id = \(bind: room)").first(decoding: Committed.self))
                let milliseconds = try v2GatewayMilliseconds(committed.createdAt)
                #expect(created.receipt.resolvedAtMilliseconds == UInt64(milliseconds))
                let exact = try await sql.raw("""
                    SELECT COUNT(*) AS value FROM im_v2.rooms r JOIN im_v2.group_rooms g USING (room_id)
                    JOIN im_v2.room_events e USING (room_id)
                    JOIN im_v2.user_state_event_outbox b ON b.source_event_id = e.event_id
                    WHERE r.room_id = \(bind: room) AND g.created_at = r.created_at
                        AND e.created_at = r.created_at AND b.created_at = r.created_at
                        AND r.created_at = \(bind: now)
                        AND (e.payload->>'created_at_ms')::bigint = \(bind: milliseconds)
                    """).first(decoding: CountRow.self)
                #expect(exact?.value == Int64(members.count + 1))
                #expect(try await fixture.store.recover(.init(intent: intent, action: .query), now: now.addingTimeInterval(700))
                    == .receipt(created.receipt))
                #expect(try await count("im_v2.group_creation_pages", on: sql) == 0)
                #expect(try await count("im_v2.group_room_creation_intent_members", on: sql) == 0)
            }
            #expect(try await count("im_v2.group_creation_owner_receipts", on: sql) == Int64(dates.count))
        }
    }

    @Test("Direct receipt responses and visible projections preserve committed time with monotonic cursors",
          arguments: [false, true], [false, true])
    func directReceiptResponseTimestampPrecision(batch: Bool, hidden: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, userDatabase, sql, userSQL, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let room = try await V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: database), projectionDelivery: SuccessfulProjectionDelivery()), capacityProfile: profile, roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { base }).openedIdentity(actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID), firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(base))
            struct Fence: V2UserShardRouteFencing {
                let database: any Database
                func withCurrentRoute<Result: Sendable>(for userID: UserID,
                    _ operation: @escaping @Sendable (V2UserShardRoute, any Database) async throws -> Result) async throws -> Result {
                    try await database.transaction { transaction in
                        try await operation(.init(bucket: "user", observedRouterEpoch: 1), transaction)
                    }
                }
            }
            let projector = try V2RoutedUserStateEventProjector(routeFence: Fence(database: database),
                registry: V2StaticUserShardStorageRegistry(locations: [.init(bucket: "user", database: userDatabase, schema: "im_v2")]))
            let store = PostgresV2ReadReceiptStore(database: database)
            if hidden {
                let preferences = PostgresV2AccountPreferenceOperationStore(database: database,
                    projectionDelivery: SuccessfulProjectionDelivery(), authorizationCoordinator:
                        V2DirectAuthorizationCoordinator(controlDatabase: database, ownerDatabases: ["room-a": database]))
                guard case .receipt(let proof) = try await preferences.executePreferenceFixture(owner: .init(uuid: memberTwoUUID),
                    operation: .readReceiptPreference(.init(uuid: UUID())),
                    value: .readReceipt(allowsDirectReadReceipts: false, allowsGroupReadReceipts: true), now: base),
                    case .applied = proof.outcome else { throw CancellationError() }
            }
            let sender = V2SendMessageService(store: PostgresV2RoomWriteStore(database: database), capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64), now: { base })
            func record(_ command: V2RecordReadReceiptCommand, at now: Date) async throws -> V2ReadReceiptOutcome {
                if !batch { return try await store.record(command: command, now: now) }
                let results = try await store.recordBatch([.init(command: command, now: now)])
                guard results.count == 1, case .success(let outcome) = results[0] else { throw CancellationError() }
                return outcome
            }
            func snapshot() async throws -> [String] {
                var values: [String] = []
                for table in ["rooms", "room_read_receipts", "read_receipt_operations", "user_sync_sequences", "user_sync_log",
                    "room_events", "room_admission", "shard_admission_pools", "user_state_event_outbox"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self)
                    values.append(try #require(row).value)
                }
                values.append(try await crossStoreClockState(on: userSQL))
                return values
            }
            let dates: [Double] = [946_684_800 - 0.00000075, 946_684_800 + 0.00000075, 946_684_800 + 0.00000125,
                1_750_000_000 + 0.99999975, 946_684_800 - 211_813_488_000, 946_684_800 + 9_223_371_331_200 - 10]
            for (index, seconds) in dates.enumerated() {
                guard case .accepted(let message) = try await sender.send(.init(roomID: room.roomID,
                    actorUserID: index % 2 == 0 ? .init(uuid: memberTwoUUID) : senderID,
                    clientMessageID: .init(uuid: UUID()), text: "Receipt precision fixture")) else { throw CancellationError() }
                let now = Date(timeIntervalSince1970: seconds)
                for advancing in [true, false] {
                    let operationTime = advancing ? now : now.addingTimeInterval(0.125)
                    let command = try V2RecordReadReceiptCommand(roomID: room.roomID, actorUserID: senderID,
                        operationID: .init(uuid: UUID()), readThroughRoomSequence: advancing ? message.roomSequence : 1)
                    guard case .recorded(let first) = try await record(command, at: operationTime) else { throw CancellationError() }
                    let operation = command.operationID.uuidValue!
                    let row = try await sql.raw("SELECT recorded_at AS value FROM im_v2.read_receipt_operations WHERE operation_id = \(bind: operation)").first(decoding: RevocationClockDateRow.self)
                    let stored = try #require(row).value
                    let exactOperation = try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.read_receipt_operations WHERE operation_id = \(bind: operation) AND recorded_at = \(bind: operationTime)").first(decoding: CountRow.self)
                    #expect(exactOperation?.value == 1)
                    #expect(first.recordedAt == stored && first.readThroughRoomSequence == message.roomSequence)
                    #expect(try v2GatewayMilliseconds(first.recordedAt) == v2GatewayMilliseconds(stored))
                    let state = try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.room_read_receipts WHERE room_id = \(bind: room.roomID.uuidValue!) AND user_id = \(bind: senderUUID) AND read_through_room_sequence = \(bind: Int64(message.roomSequence)) AND updated_at = \(bind: now)").first(decoding: CountRow.self)
                    #expect(state?.value == 1)
                    struct Candidate: Decodable {
                        let userID: UUID
                        let kind: String
                        let payload: String
                        let createdAt: V2PersistenceTimestamp
                    }
                    let candidates = try await sql.raw("SELECT user_id AS \"userID\", projection_kind AS kind, payload::text AS payload, created_at AS \"createdAt\" FROM im_v2.user_state_event_outbox WHERE source_event_id = \(bind: operation)").all(decoding: Candidate.self)
                    #expect(candidates.count == (advancing ? 2 : 0))
                    for candidate in candidates {
                        let personal = try V2UserStateEvent(sourceEventID: .init(uuid: operation), userID: .init(uuid: candidate.userID), kind: try #require(V2UserStateEventKind(rawValue: candidate.kind)), payload: Data(candidate.payload.utf8), createdAt: candidate.createdAt)
                        let sequence = try await projector.project(personal)
                        #expect(try await projector.project(personal) == sequence)
                        #expect(try await userSQL.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE source_event_id = \(bind: operation) AND user_id = \(bind: candidate.userID) AND created_at = \(bind: candidate.createdAt)").first(decoding: CountRow.self)?.value == 1)
                    }
                    #expect(try await userSQL.raw("""
                        SELECT COUNT(*) AS value FROM im_v2.user_sync_log
                        WHERE source_event_id = \(bind: operation) AND projection_kind = 'direct_read_receipt'
                            AND user_id = \(bind: memberTwoUUID)
                            AND (payload->>'is_visible')::boolean = \(bind: !hidden)
                            AND (payload->>'read_through_room_sequence')::bigint = \(bind: hidden ? Int64(0) : Int64(message.roomSequence))
                            AND (payload->>'recorded_at_ms')::bigint = \(bind: try v2GatewayMilliseconds(stored))
                        """).first(decoding: CountRow.self)?.value == (advancing ? 1 : 0))
                    let before = try await snapshot()
                    #expect(try await record(command, at: base) == .idempotent(first))
                    #expect(try await snapshot() == before)
                }
            }
            #expect(try await count("im_v2.read_receipt_operations", on: sql) == 12)
            #expect(try await count("im_v2.user_sync_log WHERE projection_kind = 'direct_read_receipt'", on: sql) == 0)
            #expect(try await count("im_v2.user_sync_log WHERE projection_kind = 'direct_read_receipt'", on: userSQL) == 6)
            #expect(try await count("im_v2.user_sync_log WHERE projection_kind = 'direct_read_receipt' AND (payload->>'is_visible')::boolean", on: userSQL) == (hidden ? 0 : 6))
        }
    }

    @Test("Membership owner preserves original proof and committed event time",
          arguments: [V2GroupCapacityClass.standard, .large])
    func membershipResponseTimestampPrecision(mode: V2GroupCapacityClass) async throws {
        try await withForwardOwnerDatabases(mode: mode) { database, _, sql, _, _ in
            let profile = try forwardImportTestProfile(), target = UserID(uuid: memberTwoUUID)
            try await sql.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE room_id=\(bind: roomUUID) AND user_id=\(bind: senderUUID)").run()
            let expiry = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 1)
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until=\(bind: expiry)").run()
            let identity = try await V2PostgresMembershipIdentitySnapshotValidator(database: database).snapshot(actorUserID: senderID, targetUserID: target)
            guard case .acquired(let lease) = try await PostgresV2RoomActivationStore(database: database).acquire(
                roomID: roomID, owner: .init(shardID: "room-a", epoch: 0),
                host: .init(hostID: .init("membership-precision"), incarnationID: UUID()), duration: .init(30_000)) else { throw CancellationError() }
            func snapshot() async throws -> [String] {
                var values: [String] = []
                for name in ["group_rooms", "rooms", "room_memberships", "membership_operation_receipts",
                    "room_events", "user_state_event_outbox", "room_admission", "shard_admission_pools"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: name) r").first(decoding: StringValueRow.self)
                    values.append(try #require(row).value)
                }
                return values
            }
            let dates: [Double] = [946_684_800 - 0.00000075, 946_684_800 + 0.00000075, 946_684_800 + 0.00000125,
                1_750_000_000 + 0.99999975, 1_750_000_010, 946_684_800 + 9_223_371_331_200 - 180]
            for (index, seconds) in dates.enumerated() {
                let now = Date(timeIntervalSince1970: seconds)
                let intent = try V2MembershipIntent(roomID: roomID, actorUserID: senderID,
                    operationID: .init(uuid: UUID()), targetUserID: target, action: index % 2 == 0 ? .remove : .add,
                    expectedMembershipRevision: UInt64(index), confirmedUntilMilliseconds: UInt64(v2GatewayMilliseconds(now)) + 120_000)
                let store = PostgresV2MembershipOperationStore(database: database, clock: { now })
                guard case .admitted(let admission) = try await store.admit(intent, identitySnapshot: identity, token: lease.token) else { throw CancellationError() }
                let command = try V2MembershipOperationCommand(intent: intent, admission: admission)
                let result = try await store.submit(command, token: lease.token, capacityProfile: profile, eventID: .init(uuid: UUID()), identitySnapshot: identity)
                guard case .receipt(let proof) = result, case .changed(let first) = proof.outcome else { throw CancellationError() }
                #expect(proof.validates(command: command))
                #expect(first.membershipRevision == UInt64(index + 1) && first.roomSequence == UInt64(index + 1))
                let event = first.eventID.uuidValue!
                let row = try await sql.raw("SELECT created_at AS value FROM im_v2.room_events WHERE event_id=\(bind: event)").first(decoding: RevocationClockDateRow.self)
                let stored = try #require(row).value
                #expect(try Int64(proof.resolvedAtMilliseconds) == v2GatewayMilliseconds(stored))
                let exact = try await sql.raw("""
                    SELECT COUNT(*) AS value FROM im_v2.room_events e
                    JOIN im_v2.user_state_event_outbox p ON p.source_event_id=e.event_id
                    WHERE e.event_id=\(bind: event) AND e.created_at=\(bind: now) AND p.created_at=e.created_at
                      AND e.committed_membership_revision=\(bind: Int64(first.membershipRevision))
                      AND e.room_sequence=\(bind: Int64(first.roomSequence))
                      AND (e.payload->>'server_created_at_ms')::bigint=\(bind: Int64(proof.resolvedAtMilliseconds))
                    """).first(decoding: CountRow.self)
                #expect(exact?.value == 1)
                let before = try await snapshot()
                let replay = PostgresV2MembershipOperationStore(database: database, clock: { Date(timeIntervalSince1970: .nan) })
                #expect(try await replay.submit(command, token: lease.token, capacityProfile: profile, eventID: .init(uuid: UUID()), identitySnapshot: identity) == result)
                #expect(try await snapshot() == before)
            }
            #expect(try await count("im_v2.membership_operation_receipts", on: sql) == Int64(dates.count))
            #expect(try await count("im_v2.room_membership_operations", on: sql) == 0)
            #expect(try await count("im_v2.room_memberships WHERE left_revision IS NULL", on: sql) == 3)
        }
    }

    @Test("Moderation owner proofs and trusted safety audits retain committed timestamp precision",
          arguments: [V2GroupCapacityClass.standard, .large],
          ["redact", "redact-owner", "mute", "remove", "control", "control-owner"])
    func moderationResponseTimestampPrecision(mode: V2GroupCapacityClass, path: String) async throws {
        try await withForwardOwnerDatabases(mode: mode) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 20, retryAfterSeconds: 3))
            let expiry = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 1)
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until=\(bind: expiry),command_window_limit=20").run()
            try await sql.raw("UPDATE im_v2.room_admission SET command_window_limit=20").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE room_id=\(bind: roomUUID) AND user_id=\(bind: senderUUID)").run()
            let store = PostgresV2ModerationStore(database: database)
            let sender = V2SendMessageService(store: PostgresV2RoomWriteStore(database: database), capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64), now: { base })
            let route = try V2RoomShardRoute(shardID: "room-a", epoch: 0)
            let kind = String(path.split(separator: "-")[0]), owner = path.hasSuffix("-owner")
            if kind == "mute" || kind == "remove" {
                try await verifyMemberClockFixture(database: database, sql: sql, profile: profile, kind: kind)
                return
            }
            func snapshot() async throws -> [String] {
                var values: [String] = []
                for name in ["rooms", "room_memberships", "messages", "message_media_references", "message_projection_states",
                    "message_moderation_receipts", "moderation_operations", "moderation_audit_entries", "room_events",
                    "user_state_event_outbox", "room_admission", "shard_admission_pools"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: name) r").first(decoding: StringValueRow.self)
                    values.append(try #require(row).value)
                }
                return values
            }
            // Trusted safety retains its native signed-date domain; user admission requires positive milliseconds.
            let lower: Double = kind == "control" ? 946_684_800 - 211_813_488_000 : 1_750_000_010
            let dates: [Double] = [946_684_800 - 0.00000075, 946_684_800 + 0.00000075, 946_684_800 + 0.00000125,
                1_750_000_000 + 0.99999975, lower, 946_684_800 + 9_223_371_331_200 - 180 * 86_400 - 180]
            for (index, seconds) in dates.enumerated() {
                let now = Date(timeIntervalSince1970: seconds), operation = ModerationOperationID(uuid: UUID())
                if kind == "redact" {
                    guard case .accepted(let message) = try await sender.send(.init(roomID: roomID, actorUserID: senderID,
                        clientMessageID: .init(uuid: UUID()), text: "Moderation precision fixture")) else { throw CancellationError() }
                    let command = try await freezeMessageModerationFixture(database: database, roomID: roomID,
                        actorUserID: senderID, operationID: operation, messageID: message.messageID, reasonCode: .init("abuse_spam"),
                        now: now, ownerRoute: owner ? route : nil)
                    let result = try await submitMessageModerationFixture(database: database, command: command, profile: profile,
                        eventID: .init(uuid: UUID()), now: now, ownerRoute: owner ? route : nil)
                    guard case .receipt(let proof) = result,
                          case .redacted(let id, let revision, let sequence, let event) = proof.outcome else { throw CancellationError() }
                    #expect(proof.validates(intent: command.intent) && id == message.messageID && revision == 2)
                    let exact = try await sql.raw("""
                        SELECT COUNT(*) AS value FROM im_v2.room_events e
                        JOIN im_v2.moderation_audit_entries a ON a.actor_user_id=\(bind: senderUUID) AND a.operation_id=\(bind: operation.uuidValue!)
                        WHERE e.event_id=\(bind: event.uuidValue!) AND e.created_at=\(bind: now) AND a.occurred_at=e.created_at
                          AND a.retain_until=\(bind: now.addingTimeInterval(180 * 86_400))
                          AND e.room_sequence=\(bind: Int64(sequence))
                          AND (e.payload->>'server_created_at_ms')::bigint=\(bind: Int64(proof.resolvedAtMilliseconds))
                        """).first(decoding: CountRow.self)
                    #expect(exact?.value == 1)
                    let before = try await snapshot()
                    #expect(try await submitMessageModerationFixture(database: database, command: command, profile: profile,
                        eventID: .init(uuid: UUID()), now: .init(timeIntervalSince1970: .nan), ownerRoute: owner ? route : nil) == result)
                    #expect(try await snapshot() == before)
                } else {
                    let command = try V2ModerationCommand(roomID: roomID, actorUserID: senderID, operationID: operation,
                        action: index % 2 == 0 ? .freezeRoom : .unfreezeRoom, reasonCode: .init("abuse_spam"))
                    func invoke(at clock: Date) async throws -> V2ModerationOutcome {
                        if owner { return try await store.applyTrustedSafetyOwnerValidated(command: command, ownerRoute: route,
                            capacityProfile: profile, eventID: .init(uuid: UUID()), now: clock) }
                        return try await store.applyTrustedSafety(command: command, capacityProfile: profile, eventID: .init(uuid: UUID()), now: clock)
                    }
                    guard case .applied(let first) = try await invoke(at: now) else { throw CancellationError() }
                    #expect(first.action == command.action && first.operationID == operation)
                    let exact = try await sql.raw("""
                        SELECT COUNT(*) AS value FROM im_v2.moderation_operations o
                        JOIN im_v2.room_events e ON e.event_id=o.event_id
                        JOIN im_v2.moderation_audit_entries a ON a.actor_user_id=o.actor_user_id AND a.operation_id=o.operation_id
                        WHERE o.operation_id=\(bind: operation.uuidValue!) AND o.created_at=\(bind: now) AND e.created_at=o.created_at
                          AND a.occurred_at=o.created_at AND a.retain_until=\(bind: now.addingTimeInterval(180 * 86_400))
                          AND e.room_sequence=o.room_sequence
                          AND (e.payload->>'server_created_at_ms')::bigint=\(bind: try v2GatewayMilliseconds(first.createdAt))
                        """).first(decoding: CountRow.self)
                    #expect(exact?.value == 1)
                    let before = try await snapshot()
                    #expect(try await invoke(at: base) == .idempotent(first))
                    #expect(try await snapshot() == before)
                }
            }
            #expect(try await count("im_v2.moderation_operations", on: sql) == (kind == "control" ? Int64(dates.count) : 0))
            #expect(try await count("im_v2.message_moderation_receipts", on: sql) == (kind == "redact" ? Int64(dates.count) : 0))
            #expect(try await count("im_v2.moderation_audit_entries", on: sql) == Int64(dates.count))
        }
    }

    @Test("Atomic room-log appends retain independent timeline and event sequences after an edit",
          arguments: ["direct-hot", "hybrid"])
    func roomLogAppendAfterMutation(path: String) async throws {
        let hybrid = path == "hybrid"
        try await withForwardOwnerDatabases(mode: hybrid ? .large : .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            var rooms: [RoomID] = []
            if hybrid { rooms = [roomID, roomID] }
            else {
                for target in [memberTwoUUID, memberThreeUUID] {
                    let room = try await V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: database), projectionDelivery: SuccessfulProjectionDelivery()), capacityProfile: profile, roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { base }).openedIdentity(actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: target), firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(base))
                    rooms.append(room.roomID)
                }
            }
            let fastCache = V2DirectRoomLogFastAppendCache()
            func writer(cache: V2DirectRoomLogFastAppendCache) throws -> PostgresV2RoomWriteStore {
                PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled,
                    directRoomLogFastAppendCache: cache)
            }
            let warm = try writer(cache: fastCache)
            func request(_ index: Int) throws -> V2RoomWriteRequest {
                .init(command: try .init(roomID: rooms[index], senderUserID: hybrid && index == 1 ? .init(uuid: memberTwoUUID) : senderID,
                    clientMessageID: .init(uuid: UUID()), text: "Room log after mutation", limits: .init(maxUTF8Bytes: 64)),
                    capacityProfile: profile, identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())), now: base)
            }
            var accepted: [V2AcceptedMessage] = []
            for index in 0..<2 {
                let input = try request(index)
                guard case .accepted(let message) = try await warm.accept(command: input.command, capacityProfile: profile, identifiers: input.identifiers, now: base) else { throw CancellationError() }
                accepted.append(message)
            }
            for message in hybrid ? [accepted[0]] : accepted {
                let command = try V2MessageEditOperationCommand(command: .init(roomID: message.roomID,
                    actorUserID: message.senderUserID, operationID: .init(uuid: UUID()),
                    messageID: message.messageID, expectedMessageRevision: 1,
                    text: "Edited before next append", maximumUTF8Bytes: 64),
                    firstSubmissionDeadlineMilliseconds: UInt64(base.timeIntervalSince1970 * 1_000) + 600_000)
                let result = try await withRoomActivation(database: database, roomID: message.roomID) { token in
                    try await PostgresV2MessageMutationOperationStore(database: database, contentReviewMode: .disabled,
                        identities: V2PostgresMembershipIdentitySnapshotValidator(database: database), clock: { base })
                        .edit(command, token: token, capacityProfile: profile, eventID: .init(uuid: UUID()),
                              now: base, maximumUTF8Bytes: 64)
                }
                guard case .receipt(let proof) = result,
                      try proof.validates(identity: command.identity, fingerprint: command.fingerprint),
                      case .committed(let edited) = proof.outcome,
                      edited.messageID == message.messageID, edited.messageRevision == 2 else { throw CancellationError() }
            }
            let eventCount = try await count("im_v2.room_events", on: sql)
            let beforeFast = await fastCache.snapshot()
            let active = warm
            let requests = try [request(0), request(1)]
            let outcomes = try await active.acceptAtomically(requests: requests)
            #expect(outcomes.count == 2)
            if path == "direct-hot" {
                let afterFast = await fastCache.snapshot()
                #expect(afterFast.committedAppends - beforeFast.committedAppends == 2)
                #expect(afterFast.fallbackAppends == beforeFast.fallbackAppends)
            }
            for (index, outcome) in outcomes.enumerated() {
                guard case .accepted(let message) = outcome else { throw CancellationError() }
                #expect(message.roomSequence == UInt64(hybrid ? index + 4 : 3))
                #expect(message.timelineSequence == UInt64(hybrid ? index + 3 : 2))
                let stored = try await sql.raw("""
                    SELECT COUNT(*) AS value FROM im_v2.messages m
                    JOIN im_v2.message_send_completions c ON c.message_id = m.message_id
                    JOIN im_v2.room_events e ON e.event_id = c.event_id
                    WHERE m.message_id = \(bind: message.messageID.uuidValue!)
                        AND m.accepted_event_storage = 'room_event' AND m.accepted_event_id IS NULL
                        AND m.accepted_membership_revision IS NULL
                        AND e.room_sequence = m.room_sequence AND e.committed_membership_revision = c.accepted_membership_revision
                        AND (e.payload->>'room_sequence')::bigint = m.room_sequence
                        AND (e.payload->>'timeline_sequence')::bigint = m.timeline_sequence
                        AND e.payload->>'text' = m.text_body AND e.payload->>'message_id' = \(bind: message.messageID.rawValue)
                    """).first(decoding: CountRow.self)
                #expect(stored?.value == 1)
                let original = requests[index]
                guard case .idempotent(let replay) = try await active.accept(command: original.command, capacityProfile: profile, identifiers: original.identifiers, now: base) else { throw CancellationError() }
                #expect(replay == message.receipt)
                let page = try await PostgresV2GroupEventLogStore(database: database).pull(roomID: message.roomID,
                    actorUserID: original.command.senderUserID, afterRoomSequence: message.roomSequence - 1, pageSize: 20)
                #expect(page.events.first?.sourceEventID == message.sourceEventID)
            }
            #expect(try await count("im_v2.room_events", on: sql) == eventCount + 2)
            #expect(try await count("im_v2.messages", on: sql) == 4)
            #expect(try await count("im_v2.message_send_completions", on: sql) == 4)
        }
    }

}

private struct TriggerRow: Decodable {
    let sourceEventID: UUID
    let planID: UUID
    enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id", planID = "plan_id" }
}

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("Scan publication and retry require an unexpired claim at SQL precision",
          arguments: ["rounded-positive", "same-negative", "before", "at", "after", "negative-before"],
          ["pass", "fail", "retry", "pause"])
    func scanLeaseExpiryFence(boundary: String, action: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let epoch = Date(timeIntervalSince1970: 946_684_800)
            let baseline = epoch.addingTimeInterval(-10)
            let device = DeviceID(uuid: UUID()), media = MediaID(uuid: UUID())
            let uploads = PostgresV2ResourceLifecycleStore(database: database, authorize: { _ in })
            let input = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: media, usage: .messageAttachment(roomID),
                contentType: "image/png", byteCount: 42, checksum: .init(value: String(repeating: "a", count: 64)))
            let upload = try await createResourceUpload(input, device: device, store: uploads, expiresAt: epoch.addingTimeInterval(600), now: baseline)
            let finalized = try await uploads.claimFinalize(session: upload.sessionID, generation: 1, actor: senderUUID, device: device.uuidValue!, now: baseline)
            try await uploads.publish(finalized, facts: .init(reference: finalized.placement, byteCount: 42, sha256: Data(repeating: 0xaa, count: 32)),
                actor: senderUUID, device: device.uuidValue!, now: baseline)
            let scans = PostgresV2MediaScanStore(database: database)
            let lease = try #require(try await scans.claimPending(now: baseline, leaseDuration: 30, limit: 1).first)
            let negative = boundary == "same-negative" || boundary == "negative-before"
            let expiry: Int64 = negative ? -1 : 1
            let offset: Double = switch boundary {
            case "rounded-positive": 0.000001
            case "same-negative": -0.00000125
            case "before": -0.000001
            case "at": 0.00000125
            case "after": 0.00000225
            default: -0.00000225
            }
            let now = Date(timeInterval: offset, since: epoch)
            let live = ["rounded-positive", "before", "negative-before"].contains(boundary)
            try await sql.raw("UPDATE im_v2.media_scan_outbox SET lease_expires_at = TIMESTAMPTZ '2000-01-01 00:00:00+00' + \(bind: expiry) * INTERVAL '1 microsecond'").run()
            #expect(try await sql.raw("SELECT lease_expires_at > \(bind: now) AS exists FROM im_v2.media_scan_outbox").first(decoding: ExistsRow.self)?.exists == live)
            func snapshot() async throws -> String {
                try #require(try await sql.raw("""
                    SELECT jsonb_build_object('media', (SELECT to_jsonb(m) FROM im_v2.media_objects m),
                        'scan', (SELECT to_jsonb(s) FROM im_v2.media_scan_outbox s))::text AS value
                    """).first(decoding: StringValueRow.self)).value
            }
            func apply(_ claim: V2MediaScanLease, at time: Date) async throws {
                switch action {
                case "pass": try await scans.complete(claim, result: .passed, now: time)
                case "fail": try await scans.complete(claim, result: .failed, now: time)
                case "retry": try await scans.scheduleRetry(claim, disposition: .retry(at: epoch.addingTimeInterval(60)), now: time)
                default: try await scans.scheduleRetry(claim, disposition: .pause, now: time)
                }
            }
            let initial = try await snapshot()
            try await apply(lease, at: now)
            if live {
                let expectedState = action == "pass" ? "available" : (action == "fail" ? "failed" : "scanning")
                let expectedJob = action == "retry" ? "pending" : (action == "pause" ? "paused" : "completed")
                #expect(try await uploads.status(session: upload.sessionID, actor: senderUUID, device: device.uuidValue!).mediaState == expectedState)
                #expect(try await sql.raw("SELECT state AS value FROM im_v2.media_scan_outbox").first(decoding: StringValueRow.self)?.value == expectedJob)
            } else {
                #expect(try await snapshot() == initial)
                let replacement = try #require(try await scans.claimPending(now: epoch.addingTimeInterval(1), leaseDuration: 30, limit: 1).first)
                #expect(replacement.claimToken != lease.claimToken)
                let reclaimed = try await snapshot()
                // Even a formerly valid timestamp cannot authorize the replaced token.
                try await apply(lease, at: baseline)
                #expect(try await snapshot() == reclaimed)
                try await scans.complete(replacement, result: .passed, now: epoch.addingTimeInterval(2))
                #expect(try await uploads.status(session: upload.sessionID, actor: senderUUID, device: device.uuidValue!).mediaState == "available")
            }
        }
    }
}

private enum PreferenceClockComparison:Equatable { case applied(Date),idempotent(Date),idempotencyConflict }
