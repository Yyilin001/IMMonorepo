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
    @Test("audit member removal is atomic, replayable, and personally delivered to the departing member")
    func moderatedMemberRemovalIsDurableAndDeliveredToTarget() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").run()
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3))
            let store = PostgresV2MemberAdministrationStore(database: resources.database(.psql), clock: { now })
            let (originalReceipt, membershipRevision, eventID) = try await withRoomActivation(
                database: resources.database(.psql), roomID: roomID
            ) { token in
                let baseline = try #require(try await sql.raw("SELECT membership_revision AS value FROM im_v2.rooms WHERE room_id = \(bind: roomUUID)").first(decoding: CountRow.self))
                let intent = try V2MemberAdministrationIntent(
                    roomID: roomID, actorUserID: senderID,
                    operationID: .init("00000000-0000-0000-0000-000000000076"),
                    targetUserID: .init(uuid: memberTwoUUID), action: .remove,
                    reasonCode: .init("abuse_spam"), expectedMembershipRevision: UInt64(baseline.value),
                    confirmedUntilMilliseconds: UInt64(now.timeIntervalSince1970 * 1000) + 120_000
                )
                guard case .admitted(let admission) = try await store.admit(intent, token: token) else {
                    throw V2ModerationStoreError.corruptPersistenceState
                }
                let command = try V2MemberAdministrationCommand(intent: intent, admission: admission)
                guard case .receipt(let receipt) = try await store.submit(command, token: token, capacityProfile: profile, eventID: .init(uuid: UUID())),
                      case .applied(.removed(let revision, _, let event)) = receipt.outcome else {
                    throw V2ModerationStoreError.corruptPersistenceState
                }
                guard case .receipt(let replay) = try await store.submit(command, token: token, capacityProfile: profile, eventID: .init(uuid: UUID())) else {
                    throw V2ModerationStoreError.corruptPersistenceState
                }
                #expect(replay == receipt)
                return (receipt, revision, event)
            }
            let membership = try #require(try await sql.raw("SELECT left_revision FROM im_v2.room_memberships WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: memberTwoUUID)").first(decoding: RemovedMembershipAssertionRow.self))
            let audit = try #require(try await sql.raw("SELECT action, reason_code FROM im_v2.moderation_audit_entries WHERE actor_user_id = \(bind: senderUUID)").first(decoding: ModerationAuditAssertionRow.self))
            let event = try #require(try await sql.raw("SELECT event_type, payload->>'action' AS action, payload->>'target_user_id' AS target_user_id FROM im_v2.room_events WHERE event_id = \(bind: UUID(uuidString: eventID.rawValue)!)").first(decoding: ModeratedRemovalEventAssertionRow.self))
            let delivery = try await V2UserStateEventWorker(
                outbox: PostgresV2UserStateEventOutbox(database: resources.database(.psql)),
                projector: PostgresV2UserStateEventProjector(database: resources.database(.psql)),
                now: { now.addingTimeInterval(2) }
            ).runOnce(limit: 8)
            let targetDelivery = try #require(try await sql.raw("SELECT COUNT(*)::int AS value FROM im_v2.user_sync_log WHERE source_event_id = \(bind: UUID(uuidString: eventID.rawValue)!) AND user_id = \(bind: memberTwoUUID)").first(decoding: CountRow.self))
            #expect(originalReceipt.identity.accountID == senderID)
            #expect(membership.leftRevision == Int64(membershipRevision))
            #expect(audit.action == "remove_member")
            #expect(audit.reasonCode == "abuse_spam")
            #expect(event.eventType == "membership_changed")
            #expect(event.action == "remove")
            #expect(event.targetUserID == memberTwoUUID.uuidString)
            #expect(delivery == 1)
            #expect(targetDelivery.value == 1)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown(); throw error
        }
    }

    @Test("durable-work metrics query aggregate backlog without exposing routes or identifiers")
    func readsDurableWorkBacklog() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let revocationNodeID = "metrics-revocation-gateway"
            let metrics = PostgresV2DurableWorkMetricsSource(
                database: resources.database(.psql),
                gatewayNodeID: revocationNodeID
            )
            let initialMetrics = try await metrics.loadDurableWorkMetrics()
            #expect(initialMetrics.isAvailable)
            #expect(initialMetrics.userSyncLogEstimatedRows == 0)
            #expect(initialMetrics.userSyncLogRelationBytes > 0)
            #expect(initialMetrics.userProjectionEffectsEstimatedRows == 0)
            #expect(initialMetrics.userProjectionEffectsRelationBytes > 0)
            let initialShardMetrics = await PostgresV2UserShardDurableWorkMetricsSource(
                database: resources.database(.psql), schema: "im_v2"
            ).durableWorkMetricsSnapshot()
            #expect(initialShardMetrics.isAvailable)
            #expect(initialShardMetrics.userSyncLogRelationBytes > 0)
            #expect(initialShardMetrics.userProjectionEffectsRelationBytes > 0)

            let firstRevokedUser = UUID(uuidString: "00000000-0000-0000-0000-000000000711")!
            let firstRevokedDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000712")!
            let secondRevokedUser = UUID(uuidString: "00000000-0000-0000-0000-000000000713")!
            let secondRevokedDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000714")!
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: firstRevokedUser), \(bind: firstRevokedDevice), \(bind: now), \(bind: now)), (\(bind: secondRevokedUser), \(bind: secondRevokedDevice), \(bind: now), \(bind: now))").run()
            try await sql.raw("INSERT INTO im_v2.device_revocation_events (user_id, device_id, created_at) VALUES (\(bind: firstRevokedUser), \(bind: firstRevokedDevice), \(bind: now)), (\(bind: secondRevokedUser), \(bind: secondRevokedDevice), \(bind: now))").run()
            let revocationBacklog = await metrics.durableWorkMetricsSnapshot()
            #expect(revocationBacklog.pendingDeviceRevocationEvents == 2)
            #expect(revocationBacklog.pendingRevokedDeviceProjectionCleanupEvents == 2)
            let revocationStore = V2PostgresDeviceRevocationEventStore(database: resources.database(.psql))
            let firstRevocation = try #require(try await revocationStore.events(afterCursorFor: revocationNodeID, limit: 1).first)
            try await revocationStore.markProcessed(eventID: firstRevocation.eventID, nodeID: revocationNodeID, now: now)
            let advancedRevocationBacklog = await metrics.durableWorkMetricsSnapshot()
            #expect(advancedRevocationBacklog.pendingDeviceRevocationEvents == 1)
            #expect(advancedRevocationBacklog.pendingRevokedDeviceProjectionCleanupEvents == 2)

            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3)
            let send = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: resources.database(.psql)),
                capacityProfile: try .init(id: "standard", limits: profile),
                limits: try .init(maxUTF8Bytes: 64),
                now: { now }
            )
            guard case .accepted = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "metrics")) else {
                Issue.record("expected accepted message")
                return
            }
            let readyProfileUpdateID = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
            let leasedProfileUpdateID = UUID(uuidString: "00000000-0000-0000-0000-000000000702")!
            let profileLeaseToken = UUID(uuidString: "00000000-0000-0000-0000-000000000703")!
            // Metrics are evaluated against PostgreSQL CURRENT_TIMESTAMP, so
            // the lease assertion must use the same wall-clock domain rather
            // than this test's fixed room-event clock.
            let metricsLeaseExpiry = Date().addingTimeInterval(60)
            try await sql.raw("""
                INSERT INTO im_v2.public_profile_update_outbox
                    (source_event_id, source_user_id, public_handle, display_name, revision, profile_updated_at,
                     state, claim_token, lease_expires_at, created_at)
                VALUES (\(bind: readyProfileUpdateID), \(bind: senderUUID), 'sender012', '发送者', 1, \(bind: now),
                        'pending', NULL, NULL, \(bind: now)),
                       (\(bind: leasedProfileUpdateID), \(bind: senderUUID), 'sender012', '发送者', 1, \(bind: now),
                        'claimed', \(bind: profileLeaseToken), \(bind: metricsLeaseExpiry), \(bind: now))
                """).run()

            let snapshot = await metrics.durableWorkMetricsSnapshot()
            #expect(snapshot.isAvailable)
            #expect(snapshot.readyUserStateEventRows == 0)
            #expect(snapshot.leasedUserStateEventRows == 0)
            #expect(snapshot.readyDirectProfileUpdates == 1)
            #expect(snapshot.leasedDirectProfileUpdates == 1)
            #expect(snapshot.readyContentReviews == 1)
            #expect(snapshot.leasedContentReviews == 0)
            #expect(snapshot.scheduledContentReviews == 0)
            #expect(snapshot.pausedContentReviews == 0)
            #expect(snapshot.userSyncLogRelationBytes > 0)
            #expect(snapshot.pendingSyncRecordsAcrossDevices == 0)
            #expect(snapshot.resetPendingDevices == 0)
            let allBuckets = PostgresV2DurableWorkMetricsSource(database: resources.database(.psql))
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown(); throw error
        }
    }

    @Test("room retention reaches an independent owner while the control room is protected")
    func roomRetentionIndependentOwner() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, controlSQL, ownerSQL, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let protectedRoom = UUID(), eligibleRoom = UUID()
            for (sql, room, canTrim) in [(controlSQL, protectedRoom, false), (ownerSQL, eligibleRoom, true)] {
                let user = UUID()
                try await insertSummaryFixtureRoom(on: sql, room: room, kind: "group", sequence: 4,
                    revision: 1, lastEventAt: now, createdAt: now)
                try await insertSummaryFixtureMembership(on: sql, room: room, user: user, joined: 1, left: nil)
                if canTrim {
                    try await insertSummaryFixtureReadReceipt(on: sql, room: room, user: user, readThrough: 3, at: now)
                }
                for sequence in 1 ... 4 {
                    try await insertSummaryFixtureRoomEvent(on: sql, room: room, sequence: Int64(sequence),
                        revision: 1, message: UUID(), createdAt: now)
                }
            }
            for database in [control, owner] {
                let driver = V2RoomLogRetentionTestDriver(database: database)
                _ = try await driver.trimRoomLogs(mode: .permanent, window: 3600, now: now, limit: 100)
            }
            for (sql, room, expected) in [(controlSQL, protectedRoom, 4), (ownerSQL, eligibleRoom, 2)] {
                let count = try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.room_events WHERE room_id = \(bind: room)")
                    .first(decoding: CountRow.self)
                #expect(try #require(count).value == Int64(expected))
            }
        }
    }

    @Test("room retention protects missing receipts and rotates past blocked rooms", arguments: [V2RoomLogRetentionMode.permanent, .window])
    func roomRetentionMissingReceiptsAndRotation(mode: V2RoomLogRetentionMode) async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            try await installSchema(on: sql)
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let rooms = (1 ... 3).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-00000000e%03d", $0))! }
            for (index, room) in rooms.enumerated() {
                try await insertSummaryFixtureRoom(on: sql, room: room, kind: index == 0 ? "direct" : "group",
                    sequence: 4, revision: 1, lastEventAt: base, createdAt: base)
                let user = UUID()
                try await insertSummaryFixtureMembership(on: sql, room: room, user: user, joined: 1, left: nil)
                // 新单聊两端都没有回执；旧群仅部分成员上报；最后一个群可裁剪。
                if index != 0 {
                    try await insertSummaryFixtureReadReceipt(on: sql, room: room, user: user, readThrough: 3, at: base)
                }
                if index < 2 {
                    try await insertSummaryFixtureMembership(on: sql, room: room, user: UUID(), joined: 1, left: nil)
                }
                for sequence in 1 ... 4 {
                    try await insertSummaryFixtureRoomEvent(on: sql, room: room, sequence: Int64(sequence),
                        revision: 1, message: UUID(), createdAt: base)
                }
            }
            let store = V2RoomLogRetentionTestDriver(database: resources.database(.psql))
            for expectedTrim in [0, 0, 1, 0] {
                let report = try await store.trimRoomLogs(mode: mode, window: 3600, now: base, limit: 1)
                #expect(report.scannedRooms == 1)
                #expect(report.trimmedRooms == expectedTrim)
                #expect(report.deletedEvents == (expectedTrim == 1 ? 2 : 0))
            }
            #expect(try await count("im_v2.room_events", on: sql) == 10)
            for room in rooms.prefix(2) {
                let floor = try await sql.raw("SELECT log_trimmed_through_room_sequence AS value FROM im_v2.rooms WHERE room_id = \(bind: room)").first(decoding: CountRow.self)
                #expect(floor?.value == 0)
            }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await resources.shutdown()
            throw error
        }
        try await resources.shutdown()
    }




    @Test("room log retention follows active readers and marks trimmed history")
    func roomLogRetentionFollowsActiveReaders() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            try await installSchema(on: sql)
            let room = UUID(uuidString: "00000000-0000-0000-0000-00000000e101")!
            let activeReader = UUID()
            let staleReader = UUID()
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let window: TimeInterval = 7 * 24 * 60 * 60

            try await insertSummaryFixtureRoom(on: sql, room: room, kind: "group", sequence: 10,
                                               revision: 1, lastEventAt: base, createdAt: base)
            for sequence in 1 ... 10 {
                try await sql.raw("""
                    INSERT INTO im_v2.room_events
                        (event_id, room_id, room_sequence, event_type, actor_user_id, payload,
                         committed_membership_revision, created_at)
                    VALUES (\(bind: UUID()), \(bind: room), \(bind: Int64(sequence)), 'message.accepted',
                            \(bind: UUID()), jsonb_build_object('event_type', 'message.accepted',
                                'message_id', \(bind: UUID().uuidString)), 1,
                            \(bind: base.addingTimeInterval(Double(sequence))))
                    """).run()
            }
            for (reader, readThrough, updatedAt) in [
                (activeReader, Int64(4), base.addingTimeInterval(60)),
                (staleReader, Int64(1), base.addingTimeInterval(-2 * window)),
            ] {
                try await insertSummaryFixtureMembership(on: sql, room: room, user: reader, joined: 1, left: nil)
                try await sql.raw("""
                    INSERT INTO im_v2.room_read_receipts (room_id, user_id, read_through_room_sequence, updated_at)
                    VALUES (\(bind: room), \(bind: reader), \(bind: readThrough), \(bind: updatedAt))
                    """).run()
            }

            let store = V2RoomLogRetentionTestDriver(database: resources.database(.psql))
            // 永久模式：计入全部历史读者，最慢的那个把下界钉在 1，什么都不删。
            let permanent = try await store.trimRoomLogs(mode: .permanent, window: window, now: base.addingTimeInterval(120), limit: 8)
            #expect(permanent.trimmedRooms == 0)
            #expect(permanent.deletedEvents == 0)
            #expect(try await count("im_v2.room_events", on: sql) == 10)

            // 窗口模式：窗口外的读者不再钉住下界，下界落到仍在窗口内的读者已读线 4。
            let windowed = try await store.trimRoomLogs(mode: .window, window: window, now: base.addingTimeInterval(120), limit: 8)
            #expect(windowed.trimmedRooms == 1)
            #expect(windowed.deletedEvents == 3)
            #expect(try await sql.raw("""
                SELECT log_trimmed_through_room_sequence AS value FROM im_v2.rooms WHERE room_id = \(bind: room)
                """).first(decoding: CountRow.self)?.value == 4)
            #expect(try await count("im_v2.room_events", on: sql) == 7)

            // 下界是单调的：再跑一轮不会回退，也不会重复删除。
            let again = try await store.trimRoomLogs(mode: .window, window: window, now: base.addingTimeInterval(120), limit: 8)
            #expect(again.trimmedRooms == 0)
            #expect(try await count("im_v2.room_events", on: sql) == 7)

            // 普通写入路径仍然不能删除房间事件：只有保留裁剪能够放行，而且必须低于下界。
            await #expect(throws: (any Error).self) {
                try await sql.raw("DELETE FROM im_v2.room_events WHERE room_id = \(bind: room)").run()
            }
            try await sql.raw("SET LOCAL im_v2.retention_trim = 'on'").run()
            await #expect(throws: (any Error).self) {
                try await sql.raw("DELETE FROM im_v2.room_events WHERE room_id = \(bind: room) AND room_sequence < 9").run()
            }

            // 读取方能看到"历史不完整"的下界：游标低于它的客户端必须被显式告知。
            let page = try await PostgresV2GroupEventLogStore(database: resources.database(.psql))
                .pull(roomID: RoomID(uuid: room), actorUserID: UserID(uuid: activeReader), afterRoomSequence: 0, pageSize: 20)
            #expect(page.logTrimmedThroughRoomSequence == 4)
            // 已读线本身仍然保留：裁剪删的是**严格早于**下界的历史。
            #expect(page.events.first?.roomSequence == 4)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("new device issuance enforces active and durable account budgets")
    func deviceRegistrationBudgetsBoundDurableIdentityGrowth() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2DeviceCredentialServiceError.unavailable
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let tokenKey = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 0x61, count: 32))
            let replayKey = try V2CredentialReplayEnvelopeKey(rawBytes: Data(repeating: 0x62, count: 32))
            let policy = try V2DeviceRegistrationPolicy(
                maximumActiveDevices: 2,
                maximumNewDevicesPerWindow: 2,
                window: 60
            )
            let issuer = try V2PostgresDeviceCredentialService(
                database: resources.database(.psql), tokenHMACKey: tokenKey,
                replayEnvelopeKey: replayKey, registrationPolicy: policy, now: { now }
            )
            let userID = try UserID("00000000-0000-0000-0000-000000000c01")
            let firstDevice = try DeviceID("00000000-0000-0000-0000-000000000c02")
            let secondDevice = try DeviceID("00000000-0000-0000-0000-000000000c03")
            let thirdDevice = try DeviceID("00000000-0000-0000-0000-000000000c04")
            let fourthDevice = try DeviceID("00000000-0000-0000-0000-000000000c05")
            let firstRequest = V2TrustedDeviceRegistration(
                userID: userID, deviceID: firstDevice,
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000c11")!
            )
            guard case .issued = try await issuer.register(firstRequest),
                  case .issued = try await issuer.register(.init(
                    userID: userID, deviceID: secondDevice,
                    operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000c12")!
                  ))
            else { Issue.record("expected first two device registrations"); return }
            guard case .idempotent = try await issuer.register(firstRequest) else {
                Issue.record("idempotent replay must remain outside the issuance budget"); return
            }
            #expect(try await count("im_v2.device_registration_rate_limits WHERE successful_registrations = 2", on: sql) == 1)

            #expect(try await issuer.register(.init(
                userID: userID, deviceID: thirdDevice,
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000c13")!
            )) == .activeDeviceLimitReached)

            let sessions = V2PostgresDeviceSessionService(database: resources.database(.psql), now: { now.addingTimeInterval(1) })
            let baseline = try await sessions.remoteRevocationBaseline(actorUserID: userID, currentDeviceID: firstDevice)
            let revoke = try V2RemoteDeviceRevocationCommand(operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000c14")!, baseline: baseline, selection: .device(secondDevice), firstSubmissionDeadlineMilliseconds: baseline.expiresAtMilliseconds)
            guard case .receipt(let receipt) = try await sessions.submitRemoteRevocation(revoke) else { Issue.record("expected remote revocation proof"); return }
            #expect(receipt.validates(revoke))
            #expect(receipt.outcome == .revoked)
            #expect(try await issuer.register(.init(
                userID: userID, deviceID: thirdDevice,
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000c15")!
            )) == .rateLimited(retryAfterSeconds: 60))

            let nextWindowIssuer = try V2PostgresDeviceCredentialService(
                database: resources.database(.psql), tokenHMACKey: tokenKey,
                replayEnvelopeKey: replayKey, registrationPolicy: policy,
                now: { now.addingTimeInterval(61) }
            )
            guard case .issued = try await nextWindowIssuer.register(.init(
                userID: userID, deviceID: thirdDevice,
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000c16")!
            )) else { Issue.record("expected the next registration window to reopen"); return }
            #expect(try await nextWindowIssuer.register(.init(
                userID: userID, deviceID: fourthDevice,
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000c17")!
            )) == .activeDeviceLimitReached)
            #expect(try await count("im_v2.auth_devices", on: sql) == 3)
            #expect(try await count("im_v2.auth_devices WHERE revoked_at IS NULL", on: sql) == 2)
            #expect(try await count("im_v2.device_registration_rate_limits WHERE successful_registrations = 1", on: sql) == 1)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("absolute device expiry bounds rotations, replay, authentication and Push eligibility")
    func deviceSessionAbsoluteExpiry() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            let deadline = start.addingTimeInterval(120)
            let key = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 0x61, count: 32))
            let replayKey = try V2CredentialReplayEnvelopeKey(rawBytes: Data(repeating: 0x62, count: 32))
            func issuer(at time: Date) throws -> V2PostgresDeviceCredentialService {
                try .init(database: resources.database(.psql), tokenHMACKey: key, replayEnvelopeKey: replayKey,
                    accessTokenLifetime: 600, refreshCredentialLifetime: 600, maximumSessionLifetime: 120,
                    registrationPolicy: .init(maximumActiveDevices: 1, maximumNewDevicesPerWindow: 10, window: 3_600),
                    now: { time })
            }
            for lifetime in [0.0, 0.5, -1, .infinity, .nan, 367 * 86_400] {
                #expect(throws: V2DeviceCredentialServiceError.invalidConfiguration) {
                    try V2PostgresDeviceCredentialService(database: resources.database(.psql), tokenHMACKey: key,
                        replayEnvelopeKey: replayKey, maximumSessionLifetime: lifetime)
                }
            }
            let user = try UserID(UUID().uuidString), device = try DeviceID(UUID().uuidString)
            let registration = V2TrustedDeviceRegistration(userID: user, deviceID: device, operationID: UUID())
            guard case .issued(let first) = try await issuer(at: start).register(registration) else { throw V2DeviceCredentialServiceError.unavailable }
            #expect(first.accessTokenExpiresAt == deadline)
            let refresh = try V2DeviceCredentialRefresh(userID: user, deviceID: device,
                refreshCredential: first.refreshCredential, revocationCredential: first.revocationCredential, operationID: UUID())
            guard case .rotated(let rotated) = try await issuer(at: deadline.addingTimeInterval(-1)).refresh(refresh) else { throw V2DeviceCredentialServiceError.unavailable }
            #expect(rotated.accessTokenExpiresAt == deadline)
            let replayMatches = try await issuer(at: deadline.addingTimeInterval(-1)).refresh(refresh) == .idempotent(rotated)
            #expect(replayMatches)
            let replayExpired = try await issuer(at: deadline).refresh(refresh) == .terminalRejection
            #expect(replayExpired)
            let rotationExpired = try await issuer(at: deadline).refresh(.init(userID: user, deviceID: device,
                refreshCredential: rotated.refreshCredential, revocationCredential: rotated.revocationCredential, operationID: UUID())) == .terminalRejection
            #expect(rotationExpired)
            let registrationExpired = try await issuer(at: deadline).register(registration) == .deviceUnavailable
            #expect(registrationExpired)
            let deviceUUID = try #require(UUID(uuidString: device.rawValue))
            let persisted = try #require(try await sql.raw("SELECT (device.session_expires_at = \(bind: deadline) AND session.expires_at <= device.session_expires_at AND token.expires_at <= device.session_expires_at) AS exists FROM im_v2.auth_devices device JOIN im_v2.device_refresh_sessions session USING(device_id) JOIN im_v2.device_access_tokens token ON token.token_hmac = \(bind: key.digest(rotated.accessToken)) WHERE device.device_id = \(bind: deviceUUID)").first(decoding: ExistsRow.self))
            #expect(persisted.exists)
            // The auth boundary independently caps even a legacy oversized
            // access row; it cannot rely solely on the issuing code.
            try await sql.raw("UPDATE im_v2.device_access_tokens SET expires_at = \(bind: deadline.addingTimeInterval(600)) WHERE device_id = \(bind: deviceUUID)").run()
            let before = V2PostgresGatewayAuthenticator(database: resources.database(.psql), tokenKey: key, now: { start })
            #expect(try await before.authenticateSession(accessToken: rotated.accessToken, deviceID: device).expiresAt == deadline)
            let expired = V2PostgresGatewayAuthenticator(database: resources.database(.psql), tokenKey: key, now: { deadline })
            await #expect(throws: V2GatewayAuthenticationError.unauthenticated) { try await expired.authenticateSession(accessToken: rotated.accessToken, deviceID: device) }
            let inventory = V2PostgresDeviceSessionService(database: resources.database(.psql), now: { deadline })
            #expect(try await inventory.sessions(for: user, cursor: nil, pageSize: 10).sessions.isEmpty)
            let newDevice = try DeviceID(UUID().uuidString)
            guard case .issued = try await issuer(at: deadline).register(.init(userID: user, deviceID: newDevice, operationID: UUID())) else { throw V2DeviceCredentialServiceError.unavailable }
            #expect(try await inventory.sessions(for: user, cursor: nil, pageSize: 10).sessions.map(\.deviceID) == [newDevice])

            let push = PostgresV2PushDeviceEndpointStore(database: resources.database(.psql), envelopeKey: try .init(rawBytes: Data(repeating: 0x63, count: 32)))
            let endpoint = try V2PushDeviceEndpointRegistration(provider: .apns, environment: .development, token: "expiry-test-token")
            try await push.register(actorUserID: user, deviceID: device, endpoint: endpoint, now: start)
            #expect(try await push.endpoint(for: device) != nil)
            let uploads = PostgresV2ResourceLifecycleStore(database: resources.database(.psql), authorize: { transaction in
                guard try await V2PostgresDeviceAvailabilityChecker(database: transaction).isAvailable(userID: user, deviceID: device)
                else { throw V2MediaStoreError.uploadNotAuthorized }
            })
            let uploadCommand = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()), usage: .userAvatar,
                contentType: "image/png", byteCount: 1, checksum: .init(value: String(repeating: "a", count: 64)))
            func createUpload(_ input: V2ResourceUploadRequest) async throws -> V2PersistedResourceUpload {
                try await uploads.create(homeKind: "account", homeID: user.uuidValue!, usageKind: "user_avatar", actor: user.uuidValue!,
                    device: deviceUUID, operation: input.operationID.uuidValue!, mediaID: input.mediaID.uuidValue!, contentType: input.contentType,
                    byteCount: input.byteCount, requestJSON: String(decoding: JSONEncoder().encode(input), as: UTF8.self),
                    allocate: { try .init(placementID: UUID(), binding: .init(id: "device-expiry", configurationRevision: 1), handle: Data(input.mediaID.rawValue.utf8)) },
                    expiresAt: start.addingTimeInterval(300), now: start)
            }
            let upload = try await createUpload(uploadCommand)
            let claim = try await uploads.claimFinalize(session: upload.sessionID, generation: 1, actor: user.uuidValue!, device: deviceUUID, now: start)
            let completedCommand = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()), usage: .userAvatar,
                contentType: "image/png", byteCount: 1, checksum: uploadCommand.checksum)
            let completedUpload = try await createUpload(completedCommand)
            let completedClaim = try await uploads.claimFinalize(session: completedUpload.sessionID, generation: 1, actor: user.uuidValue!, device: deviceUUID, now: start)
            let facts = try V2StoredObjectFacts(reference: claim.placement, byteCount: 1, sha256: Data(repeating: 0xaa, count: 32))
            try await uploads.publish(completedClaim, facts: .init(reference: completedClaim.placement, byteCount: 1, sha256: facts.sha256), actor: user.uuidValue!, device: deviceUUID, now: start)
            try await sql.raw("UPDATE im_v2.auth_devices SET session_expires_at = CURRENT_TIMESTAMP - interval '1 second' WHERE device_id = \(bind: deviceUUID)").run()
            #expect(try await push.endpoint(for: device) == nil)
            await #expect(throws: V2MediaStoreError.uploadNotAuthorized) { try await uploads.publish(claim, facts: facts, actor: user.uuidValue!, device: deviceUUID, now: start) }
            await #expect(throws: V2MediaStoreError.uploadNotAuthorized) { try await uploads.claimFinalize(session: upload.sessionID, generation: 1, actor: user.uuidValue!, device: deviceUUID, now: start) }
            await #expect(throws: V2MediaStoreError.uploadNotAuthorized) { try await createUpload(uploadCommand) }
            await #expect(throws: V2MediaStoreError.uploadNotAuthorized) { try await uploads.status(session: completedUpload.sessionID, actor: user.uuidValue!, device: deviceUUID) }
            await #expect(throws: V2MediaStoreError.uploadNotAuthorized) { try await uploads.cancel(session: upload.sessionID, generation: 1, actor: user.uuidValue!, device: deviceUUID, now: start) }
            await #expect(throws: V2PushDeviceEndpointError.deviceUnavailable) { try await push.intentEpoch(actorUserID: user, deviceID: device) }
            await #expect(throws: V2PushDeviceEndpointError.deviceUnavailable) { try await push.register(actorUserID: user, deviceID: device, endpoint: endpoint, now: Date()) }
            #expect(try await V2PostgresDeviceAvailabilityChecker(database: resources.database(.psql)).isAvailable(userID: user, deviceID: device) == false)
            try await sql.raw("ALTER TABLE im_v2.auth_devices DROP CONSTRAINT auth_devices_session_expiry_finite").run()
            await #expect(throws: V2SchemaReadinessError.self) { try await V2SchemaReadiness.verify(database: resources.database(.psql)) }
            try await assertSQLSchemaGate(false, on: sql)
            try await sql.raw("ALTER TABLE im_v2.auth_devices ADD CONSTRAINT auth_devices_session_expiry_finite CHECK (isfinite(session_expires_at))").run()
            try await sql.raw("ALTER TABLE im_v2.auth_devices DROP COLUMN session_expires_at").run()
            await #expect(throws: V2SchemaReadinessError.self) { try await V2SchemaReadiness.verify(database: resources.database(.psql)) }
            try await assertSQLSchemaGate(false, on: sql)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("trusted device registration and refresh rotation are durable, replayable, and revoke on reuse")
    func deviceCredentialRotationFencesReuse() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let tokenKey = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 0x11, count: 32))
            let replayKey = try V2CredentialReplayEnvelopeKey(rawBytes: Data(repeating: 0x22, count: 32))
            let issuer = try V2PostgresDeviceCredentialService(
                database: resources.database(.psql),
                tokenHMACKey: tokenKey,
                replayEnvelopeKey: replayKey,
                now: { now }
            )
            let userID = try UserID("00000000-0000-0000-0000-000000000201")
            let deviceID = try DeviceID("00000000-0000-0000-0000-000000000202")
            let registration = V2TrustedDeviceRegistration(
                userID: userID,
                deviceID: deviceID,
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000203")!
            )
            guard case .issued(let initial) = try await issuer.register(registration) else { Issue.record("expected initial device credentials"); return }
            #expect(try await issuer.register(registration) == .idempotent(initial))

            let gateway = V2PostgresGatewayAuthenticator(database: resources.database(.psql), tokenKey: tokenKey, now: { now })
            #expect(try await gateway.authenticateSession(accessToken: initial.accessToken, deviceID: deviceID).userID == userID)

            let refresh = try V2DeviceCredentialRefresh(
                userID: userID,
                deviceID: deviceID,
                refreshCredential: initial.refreshCredential, revocationCredential: initial.revocationCredential,
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000204")!
            )
            guard case .rotated(let successor) = try await issuer.refresh(refresh) else { Issue.record("expected refresh rotation"); return }
            #expect(successor.accessToken != initial.accessToken)
            #expect(successor.refreshCredential != initial.refreshCredential)
            #expect(try await issuer.refresh(refresh) == .idempotent(successor))
            #expect(try await gateway.authenticateSession(accessToken: successor.accessToken, deviceID: deviceID).userID == userID)

            let arbitraryMismatch = try V2DeviceCredentialRefresh(
                userID: userID,
                deviceID: deviceID,
                refreshCredential: "attacker-controlled-random-value", revocationCredential: initial.revocationCredential,
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000206")!
            )
            #expect(try await issuer.refresh(arbitraryMismatch) == .terminalRejection)
            #expect(try await gateway.authenticateSession(accessToken: successor.accessToken, deviceID: deviceID).userID == userID)
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 0)

            let reuse = try V2DeviceCredentialRefresh(
                userID: userID,
                deviceID: deviceID,
                refreshCredential: initial.refreshCredential, revocationCredential: initial.revocationCredential,
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000205")!
            )
            #expect(try await issuer.refresh(reuse) == .terminalRejection)
            await #expect(throws: V2GatewayAuthenticationError.unauthenticated) {
                try await gateway.authenticateSession(accessToken: successor.accessToken, deviceID: deviceID)
            }
            #expect(try await count("im_v2.auth_devices", on: sql) == 1)
            #expect(try await count("im_v2.device_refresh_sessions", on: sql) == 1)
            #expect(try await count("im_v2.device_credential_operations", on: sql) == 2)
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 1)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown(); throw error
        }
    }

    @Test("unknown device refresh is terminal without a foreign-key failure or cross-account mutation")
    func unknownDeviceCredentialRefreshIsTerminalNoOp() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)

            let issuer = try V2PostgresDeviceCredentialService(
                database: resources.database(.psql),
                tokenHMACKey: try .init(rawBytes: Data(repeating: 0x31, count: 32)),
                replayEnvelopeKey: try .init(rawBytes: Data(repeating: 0x32, count: 32)),
                now: { Date(timeIntervalSince1970: 1_750_000_000) }
            )
            let refresh = try V2DeviceCredentialRefresh(
                userID: try .init("00000000-0000-0000-0000-000000000211"),
                deviceID: try .init("00000000-0000-0000-0000-000000000212"),
                refreshCredential: "unknown-refresh-credential", revocationCredential: .generate(),
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000213")!
            )

            #expect(try await issuer.refresh(refresh) == .terminalRejection)
            #expect(try await count("im_v2.auth_devices", on: sql) == 0)
            #expect(try await count("im_v2.device_refresh_sessions", on: sql) == 0)
            #expect(try await count("im_v2.device_access_tokens", on: sql) == 0)
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 0)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("device sessions paginate metadata and revoke remote installations with bounded SQL")
    func deviceSessionManagementRevokesOnlyTheRequestedDevice() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2DeviceSessionServiceError.unavailable }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_100)
            let tokenKey = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 0x51, count: 32))
            let replayKey = try V2CredentialReplayEnvelopeKey(rawBytes: Data(repeating: 0x52, count: 32))
            let issuer = try V2PostgresDeviceCredentialService(database: resources.database(.psql), tokenHMACKey: tokenKey, replayEnvelopeKey: replayKey, now: { now })
            let userID = try UserID("00000000-0000-0000-0000-000000000a01")
            let currentDeviceID = try DeviceID("00000000-0000-0000-0000-000000000a02")
            let remoteDeviceID = try DeviceID("00000000-0000-0000-0000-000000000a03")
            let otherRemoteDeviceID = try DeviceID("00000000-0000-0000-0000-000000000a08")
            guard case .issued(let currentCredentials) = try await issuer.register(.init(userID: userID, deviceID: currentDeviceID, operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000a04")!, metadata: .init(displayName: "Current iPhone", platform: "iPhone"))),
                  case .issued(let remoteCredentials) = try await issuer.register(.init(userID: userID, deviceID: remoteDeviceID, operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000a05")!, metadata: .init(displayName: "Remote iPad", platform: "iPad"))),
                  case .issued(let otherRemoteCredentials) = try await issuer.register(.init(userID: userID, deviceID: otherRemoteDeviceID, operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000a09")!, metadata: .init(displayName: "Remote Mac", platform: "macOS")))
            else { Issue.record("expected device credentials"); return }
            let remoteUUID = try #require(UUID(uuidString: remoteDeviceID.rawValue))
            let otherRemoteUUID = try #require(UUID(uuidString: otherRemoteDeviceID.rawValue))
            let endpointGeneration = UUID(uuidString: "00000000-0000-0000-0000-000000000a06")!
            let otherEndpointGeneration = UUID(uuidString: "00000000-0000-0000-0000-000000000a0a")!
            try await sql.raw("INSERT INTO im_v2.push_device_endpoints (device_id, provider, environment, endpoint_generation, encrypted_token, updated_at) VALUES (\(bind: remoteUUID), 'apns', 'development', \(bind: endpointGeneration), 'sealed', \(bind: now)), (\(bind: otherRemoteUUID), 'apns', 'development', \(bind: otherEndpointGeneration), 'sealed-other', \(bind: now))").run()

            let service = V2PostgresDeviceSessionService(database: resources.database(.psql), now: { now.addingTimeInterval(1) })
            let firstPage = try await service.sessions(for: userID, cursor: nil, pageSize: 2)
            #expect(firstPage.sessions.map(\.deviceID) == [currentDeviceID, remoteDeviceID])
            #expect(firstPage.sessions.map(\.displayName) == ["Current iPhone", "Remote iPad"])
            guard let pageCursor = firstPage.nextCursor else { Issue.record("expected a second device page"); return }
            let secondPage = try await service.sessions(for: userID, cursor: pageCursor, pageSize: 2)
            #expect(secondPage.sessions.map(\.deviceID) == [otherRemoteDeviceID])
            #expect(secondPage.nextCursor == nil)
            let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000a07")!
            let baseline = try await service.remoteRevocationBaseline(actorUserID: userID, currentDeviceID: currentDeviceID)
            let single = try V2RemoteDeviceRevocationCommand(operationID: operationID, baseline: baseline, selection: .device(remoteDeviceID), firstSubmissionDeadlineMilliseconds: baseline.expiresAtMilliseconds)
            let singleResult = try await service.submitRemoteRevocation(single)
            guard case .receipt(let singleReceipt) = singleResult else { Issue.record("expected immutable remote proof"); return }
            #expect(singleReceipt.validates(single) && singleReceipt.outcome == .revoked)
            #expect(try await service.submitRemoteRevocation(single) == singleResult)
            let revokeOthersOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000a0b")!
            let all = try V2RemoteDeviceRevocationCommand(operationID: revokeOthersOperationID, baseline: baseline, selection: .allObservedOthers, firstSubmissionDeadlineMilliseconds: baseline.expiresAtMilliseconds)
            let allResult = try await service.submitRemoteRevocation(all)
            guard case .receipt(let allReceipt) = allResult else { Issue.record("expected frozen-set proof"); return }
            #expect(allReceipt.validates(all) && allReceipt.targetDeviceIDs == baseline.targetDeviceIDs)
            #expect(allReceipt.outcome == .revoked)
            #expect(try await service.submitRemoteRevocation(all) == allResult)
            #expect(try await service.recoverRemoteRevocation(.init(command: all, action: .query)) == allResult)

            let gateway = V2PostgresGatewayAuthenticator(database: resources.database(.psql), tokenKey: tokenKey, now: { now.addingTimeInterval(2) })
            #expect(try await gateway.authenticateSession(accessToken: currentCredentials.accessToken, deviceID: currentDeviceID).userID == userID)
            await #expect(throws: V2GatewayAuthenticationError.unauthenticated) {
                try await gateway.authenticateSession(accessToken: remoteCredentials.accessToken, deviceID: remoteDeviceID)
            }
            await #expect(throws: V2GatewayAuthenticationError.unauthenticated) {
                try await gateway.authenticateSession(accessToken: otherRemoteCredentials.accessToken, deviceID: otherRemoteDeviceID)
            }
            #expect(try await count("im_v2.auth_devices WHERE revoked_at IS NULL", on: sql) == 1)
            #expect(try await count("im_v2.device_session_operations", on: sql) == 0)
            #expect(try await count("im_v2.remote_device_revocation_receipts", on: sql) == 2)
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 2)
            #expect(try await count("im_v2.push_device_endpoints WHERE disabled_at IS NOT NULL", on: sql) == 2)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown(); throw error
        }
    }

    @Test("account disable fences credential issuance, revokes every device, and preserves one audit fact")
    func accountDisableRevokesCredentialsAndFencesFutureIssue() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2AccountDisableError.unavailable }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let tokenKey = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 0x41, count: 32))
            let replayKey = try V2CredentialReplayEnvelopeKey(rawBytes: Data(repeating: 0x42, count: 32))
            let issuer = try V2PostgresDeviceCredentialService(
                database: resources.database(.psql), tokenHMACKey: tokenKey, replayEnvelopeKey: replayKey, now: { now }
            )
            let userID = try UserID("00000000-0000-0000-0000-000000000991")
            let firstDeviceID = try DeviceID("00000000-0000-0000-0000-000000000992")
            let secondDeviceID = try DeviceID("00000000-0000-0000-0000-000000000993")
            let firstRegistration = V2TrustedDeviceRegistration(userID: userID, deviceID: firstDeviceID, operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000994")!)
            let secondRegistration = V2TrustedDeviceRegistration(userID: userID, deviceID: secondDeviceID, operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000995")!)
            guard case .issued(let firstCredentials) = try await issuer.register(firstRegistration),
                  case .issued(let secondCredentials) = try await issuer.register(secondRegistration)
            else { Issue.record("expected initial device credentials"); return }
            let userUUID = try #require(UUID(uuidString: userID.rawValue))
            let passwordHash = String(repeating: "x", count: 60)
            try await sql.raw("INSERT INTO im_v2.account_password_credentials (account_handle, user_id, password_hash, created_at) VALUES ('account991', \(bind: userUUID), \(bind: passwordHash), \(bind: now))").run()
            try await sql.raw("INSERT INTO im_v2.public_user_profiles (user_id, public_handle, display_name, revision, created_at, updated_at) VALUES (\(bind: userUUID), 'account991', '待停用账号', 1, \(bind: now), \(bind: now))").run()

            let disable = try V2PostgresAccountDisableService(database: resources.database(.psql), operatorPrincipal: "account-safety-primary", now: { now.addingTimeInterval(1) })
            let command = try V2AccountDisableCommand(
                userID: userID, operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000996")!, reason: .credentialCompromise
            )
            #expect(try await disable.disable(command) == .disabled(disabledAt: now.addingTimeInterval(1)))
            #expect(try await disable.disable(command) == .idempotent(disabledAt: now.addingTimeInterval(1)))
            let conflictingOperation = try V2AccountDisableCommand(
                userID: try UserID("00000000-0000-0000-0000-000000000999"), operationID: command.operationID, reason: .credentialCompromise
            )
            await #expect(throws: V2AccountDisableError.operationConflict) {
                _ = try await disable.disable(conflictingOperation)
            }
            let otherOperation = try V2AccountDisableCommand(userID: userID, operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000997")!, reason: .policyEnforcement)
            #expect(try await disable.disable(otherOperation) == .alreadyDisabled(disabledAt: now.addingTimeInterval(1)))

            let gateway = V2PostgresGatewayAuthenticator(database: resources.database(.psql), tokenKey: tokenKey, now: { now.addingTimeInterval(2) })
            await #expect(throws: V2GatewayAuthenticationError.unauthenticated) {
                try await gateway.authenticateSession(accessToken: firstCredentials.accessToken, deviceID: firstDeviceID)
            }
            await #expect(throws: V2GatewayAuthenticationError.unauthenticated) {
                try await gateway.authenticateSession(accessToken: secondCredentials.accessToken, deviceID: secondDeviceID)
            }
            #expect(try await issuer.register(firstRegistration) == .deviceUnavailable)
            let refresh = try V2DeviceCredentialRefresh(
                userID: userID, deviceID: firstDeviceID, refreshCredential: firstCredentials.refreshCredential, revocationCredential: firstCredentials.revocationCredential,
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000998")!
            )
            #expect(try await issuer.refresh(refresh) == .terminalRejection)
            #expect(try await V2PostgresPasswordAccountStore(database: resources.database(.psql)).passwordCredential(for: "account991") == nil)
            let disabledProfile = try #require(try await sql.raw("SELECT state, revision, visibility_revision, avatar_media_id IS NULL AS avatar_cleared FROM im_v2.public_user_profiles WHERE user_id = \(bind: userUUID)").first(decoding: DisabledProfileAssertionRow.self))
            #expect(disabledProfile.state == "suspended")
            #expect(disabledProfile.revision == 2)
            #expect(disabledProfile.visibilityRevision == 2)
            #expect(disabledProfile.avatarCleared)
            let profileInvalidation = try #require(try await sql.raw("SELECT profile_state, revision FROM im_v2.public_profile_update_outbox WHERE source_event_id = \(bind: command.operationID)").first(decoding: DisabledProfileOutboxAssertionRow.self))
            #expect(profileInvalidation.profileState == "suspended")
            #expect(profileInvalidation.revision == 2)
            let publicDirectory = V2PostgresPublicIdentityDirectory(
                database: resources.database(.psql),
                policy: try .init(maximumQueries: 2, window: 60),
                now: { now.addingTimeInterval(2) }
            )
            #expect(try await publicDirectory.resolve(handle: .init("account991"), actorUserID: try .init("00000000-0000-0000-0000-000000000990")) == nil)
            #expect(try await publicDirectory.resolve(handle: .init("account991"), actorUserID: try .init("00000000-0000-0000-0000-000000000990")) == nil)
            await #expect(throws: V2PublicIdentityDirectoryError.rateLimited(retryAfterSeconds: 60)) {
                _ = try await publicDirectory.resolve(
                    handle: .init("account991"),
                    actorUserID: try .init("00000000-0000-0000-0000-000000000990")
                )
            }
            #expect(try await count("im_v2.account_disables", on: sql) == 1)
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 2)
            #expect(try await count("im_v2.auth_devices WHERE revoked_at IS NULL", on: sql) == 0)
            #expect(try await count("im_v2.device_access_tokens WHERE revoked_at IS NULL", on: sql) == 0)
            #expect(try await count("im_v2.device_refresh_sessions WHERE revoked_at IS NULL", on: sql) == 0)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("PostgreSQL device-revocation cursor initializes new nodes and advances existing nodes")
    func deviceRevocationCursorReadsAndAcknowledgesEvents() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2GatewayAuthenticationError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let firstUser = UUID(uuidString: "00000000-0000-0000-0000-000000000981")!
            let firstDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000982")!
            let secondUser = UUID(uuidString: "00000000-0000-0000-0000-000000000983")!
            let secondDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000984")!
            let occurredAt = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: firstUser), \(bind: firstDevice), \(bind: occurredAt), \(bind: occurredAt)), (\(bind: secondUser), \(bind: secondDevice), \(bind: occurredAt), \(bind: occurredAt))").run()
            try await sql.raw("INSERT INTO im_v2.device_revocation_events (user_id, device_id, created_at) VALUES (\(bind: firstUser), \(bind: firstDevice), \(bind: occurredAt)), (\(bind: secondUser), \(bind: secondDevice), \(bind: occurredAt))").run()

            let store = V2PostgresDeviceRevocationEventStore(database: resources.database(.psql))
            let nodeID = "gateway-revocation-cursor-test"
            let firstPage = try await store.events(afterCursorFor: nodeID, limit: 8)
            #expect(firstPage.map(\.userID) == [try UserID(firstUser.uuidString), try UserID(secondUser.uuidString)])
            #expect(firstPage.map(\.deviceID) == [try DeviceID(firstDevice.uuidString), try DeviceID(secondDevice.uuidString)])

            try await store.markProcessed(eventID: firstPage[0].eventID, nodeID: nodeID, now: occurredAt)
            let secondPage = try await store.events(afterCursorFor: nodeID, limit: 8)
            #expect(secondPage.map(\.eventID) == [firstPage[1].eventID])
            try await store.markProcessed(eventID: secondPage[0].eventID, nodeID: nodeID, now: occurredAt)
            #expect(try await store.events(afterCursorFor: nodeID, limit: 8).isEmpty)

            let freshNodeID = "gateway-revocation-fresh-node"
            try await store.initializeCursorIfNeeded(nodeID: freshNodeID, now: occurredAt)
            #expect(try await store.events(afterCursorFor: freshNodeID, limit: 8).isEmpty)

            let laterUser = UUID(uuidString: "00000000-0000-0000-0000-000000000985")!
            let laterDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000986")!
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: laterUser), \(bind: laterDevice), \(bind: occurredAt), \(bind: occurredAt))").run()
            try await sql.raw("INSERT INTO im_v2.device_revocation_events (user_id, device_id, created_at) VALUES (\(bind: laterUser), \(bind: laterDevice), \(bind: occurredAt))").run()
            let laterPage = try await store.events(afterCursorFor: freshNodeID, limit: 8)
            #expect(laterPage.map(\.deviceID) == [try DeviceID(laterDevice.uuidString)])
            // Startup initialization must not advance an already-created
            // cursor, otherwise a duplicate node ID could skip live work.
            try await store.initializeCursorIfNeeded(nodeID: freshNodeID, now: occurredAt)
            #expect(try await store.events(afterCursorFor: freshNodeID, limit: 8).map(\.eventID) == laterPage.map(\.eventID))

            // The cluster-global projection consumer uses an independent
            // namespace and deliberately replays historical events.
            let cleanupStore = V2PostgresDeviceRevocationEventStore.projectionCleanup(
                database: resources.database(.psql)
            )
            try await cleanupStore.initializeCursorAtBeginningIfNeeded(
                nodeID: "cluster",
                now: occurredAt
            )
            #expect(
                try await cleanupStore.events(afterCursorFor: "cluster", limit: 8)
                    .map(\.deviceID) == [
                        try DeviceID(firstDevice.uuidString),
                        try DeviceID(secondDevice.uuidString),
                        try DeviceID(laterDevice.uuidString),
                    ]
            )

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("account HTTP retries replay one durable credential result after response loss")
    func deviceCredentialHTTPRetriesReplayPersistedResult() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        let app = try await Application(.testing)
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_100)
            let tokenKey = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 0x31, count: 32))
            let replayKey = try V2CredentialReplayEnvelopeKey(rawBytes: Data(repeating: 0x32, count: 32))
            let assertionIssuer = try V2HMACAccountAssertionIssuer(rawKey: Data(repeating: 0x33, count: 32), now: { now })
            let issuer = try V2PostgresDeviceCredentialService(
                database: resources.database(.psql),
                tokenHMACKey: tokenKey,
                replayEnvelopeKey: replayKey,
                now: { now }
            )
            V2VaporDeviceCredentialRoutes(assertionVerifier: assertionIssuer, issuer: issuer).register(on: app)

            let userID = try UserID("00000000-0000-0000-0000-000000000211")
            let accountUser = try #require(userID.uuidValue)
            try await sql.raw("""
                INSERT INTO im_v2.account_password_credentials(account_handle,user_id,password_hash,credential_revision,created_at)
                VALUES ('credential-replay-http', \(bind: accountUser), repeat('x',60), 1, \(bind: now))
                """).run()
            let deviceID = try DeviceID("00000000-0000-0000-0000-000000000212")
            let registrationOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000213")!
            let registration = V2DeviceCredentialIssueHTTPRequest(
                accountAssertion: try assertionIssuer.issue(userID: userID, deviceID: deviceID),
                deviceID: deviceID.rawValue,
                operationID: registrationOperationID,
                cancellation: try .init(deviceID: deviceID, operationID: registrationOperationID, proof: .generate(), issueBeforeMilliseconds: Int64(now.timeIntervalSince1970 * 1_000) + 600_000)
            )

            // Model a client that lost the first successful response: the
            // second identical request is the only response it observes.
            var firstRegistration: V2DeviceCredentialIssueHTTPResponse?
            try await app.testing { client in
                let response = try await client.send(.post, to: "v2/device-credentials", beforeSend: { request in
                    try request.content.encode(registration)
                })
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-store")
                firstRegistration = try await response.content.decode(V2DeviceCredentialIssueHTTPResponse.self)
            }
            var replayedRegistration: V2DeviceCredentialIssueHTTPResponse?
            try await app.testing { client in
                let response = try await client.send(.post, to: "v2/device-credentials", beforeSend: { request in
                    try request.content.encode(registration)
                })
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-store")
                replayedRegistration = try await response.content.decode(V2DeviceCredentialIssueHTTPResponse.self)
            }
            let initial = try #require(firstRegistration)
            let replayedInitial = try #require(replayedRegistration)
            #expect(replayedInitial.userID == initial.userID)
            #expect(replayedInitial.deviceID == initial.deviceID)
            #expect(replayedInitial.accessToken == initial.accessToken)
            #expect(replayedInitial.accessTokenExpiresAtMilliseconds == initial.accessTokenExpiresAtMilliseconds)
            #expect(replayedInitial.refreshCredential == initial.refreshCredential)

            let refreshOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000214")!
            let refresh = V2DeviceCredentialRefreshHTTPRequest(
                userID: initial.userID,
                deviceID: initial.deviceID,
                refreshCredential: initial.refreshCredential, revocationCredential: initial.revocationCredential,
                operationID: refreshOperationID
            )
            var firstRefresh: V2DeviceCredentialIssueHTTPResponse?
            try await app.testing { client in
                let response = try await client.send(.post, to: "v2/device-credentials/refresh", beforeSend: { request in
                    try request.content.encode(refresh)
                })
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-store")
                firstRefresh = try await response.content.decode(V2DeviceCredentialIssueHTTPResponse.self)
            }
            var replayedRefresh: V2DeviceCredentialIssueHTTPResponse?
            try await app.testing { client in
                let response = try await client.send(.post, to: "v2/device-credentials/refresh", beforeSend: { request in
                    try request.content.encode(refresh)
                })
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-store")
                replayedRefresh = try await response.content.decode(V2DeviceCredentialIssueHTTPResponse.self)
            }
            let successor = try #require(firstRefresh)
            let replayedSuccessor = try #require(replayedRefresh)
            #expect(successor.accessToken != initial.accessToken)
            #expect(successor.refreshCredential != initial.refreshCredential)
            #expect(replayedSuccessor.accessToken == successor.accessToken)
            #expect(replayedSuccessor.accessTokenExpiresAtMilliseconds == successor.accessTokenExpiresAtMilliseconds)
            #expect(replayedSuccessor.refreshCredential == successor.refreshCredential)

            let gateway = V2PostgresGatewayAuthenticator(database: resources.database(.psql), tokenKey: tokenKey, now: { now })
            #expect(try await gateway.authenticateSession(accessToken: successor.accessToken, deviceID: deviceID).userID == userID)
            #expect(try await count("im_v2.auth_devices", on: sql) == 1)
            #expect(try await count("im_v2.device_refresh_sessions", on: sql) == 1)
            #expect(try await count("im_v2.device_credential_operations", on: sql) == 2)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.shutdown(); try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.shutdown(); try? await resources.shutdown(); throw error
        }
    }


    @Test("one poison user backs off and pauses without blocking healthy projection work")
    func userProjectionPoisonIsolationAndReplay() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let poisonUser = UUID(uuidString: "00000000-0000-0000-0000-000000000c01")!
            let healthyUser = UUID(uuidString: "00000000-0000-0000-0000-000000000c02")!
            let poisonEvent = UUID(uuidString: "00000000-0000-0000-0000-000000000c03")!
            let healthyEvent = UUID(uuidString: "00000000-0000-0000-0000-000000000c04")!
            let target = UUID(uuidString: "00000000-0000-0000-0000-000000000c05")!
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence)
                VALUES (\(bind: poisonUser), 1), (\(bind: healthyUser), 1)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind,
                     payload, created_at)
                VALUES
                    (\(bind: poisonUser), 1, \(bind: poisonEvent), 'relationship',
                     '[]'::jsonb, \(bind: now.addingTimeInterval(-1))),
                    (\(bind: healthyUser), 1, \(bind: healthyEvent), 'relationship',
                     \(bind: "{\"target_user_id\":\"\(target.uuidString.lowercased())\",\"state\":\"accepted\",\"updated_at_ms\":1750000000000}")::jsonb,
                     \(bind: now))
                """).run()
            #expect(try await count("im_v2.user_projection_ready", on: sql) == 2)
            let worker = PostgresV2UserProjectionWorker(
                database: resources.database(.psql),
                batchSize: 10,
                retryPolicy: .init(
                    initialDelay: 1, maximumDelay: 1,
                    maximumAttempts: 2, jitterFraction: 0
                )
            )

            #expect(try await worker.runOnce(now: now) == .init(
                claimed: true, appliedRecordCount: 0, failedRecordCount: 1
            ))
            #expect(try await worker.runOnce(now: now) == .init(
                claimed: true, appliedRecordCount: 1
            ))
            #expect(try await count("im_v2.user_projection_ready", on: sql) == 1)
            #expect(try await worker.runOnce(now: now.addingTimeInterval(2)) == .init(
                claimed: true, appliedRecordCount: 0,
                failedRecordCount: 1, pausedUserCount: 1
            ))
            let paused = try #require(try await sql.raw("""
                SELECT state, failure_count, failed_sequence, last_failure_code
                FROM im_v2.user_projection_checkpoints
                WHERE user_id = \(bind: poisonUser)
                """).first(decoding: ProjectionPoisonCheckpointAssertionRow.self))
            #expect(paused.state == "paused")
            #expect(paused.failureCount == 2)
            #expect(paused.failedSequence == 1)
            #expect(paused.lastFailureCode == "invalid_payload")
            #expect(try await count("im_v2.user_projection_ready", on: sql) == 0)
            #expect(try await currentV3ProjectionItems(
                sql: sql, userID: .init(healthyUser.uuidString), kind: "relationship"
            ).count == 1)

            // Repair the exact malformed body first, then use the closed,
            // audited replay target. The worker resumes from the unchanged
            // checkpoint and applies the formerly poison record once.
            try await sql.raw("""
                UPDATE im_v2.user_sync_log
                SET payload = \(bind: "{\"target_user_id\":\"\(target.uuidString.lowercased())\",\"state\":\"accepted\",\"updated_at_ms\":1750000000000}")::jsonb
                WHERE user_id = \(bind: poisonUser) AND source_event_id = \(bind: poisonEvent)
                """).run()
            #expect(try await verifyDurableReplayClockRecovery(.init(
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000c06")!,
                target: .init(
                    kind: .userProjection,
                    sourceEventID: .init(poisonEvent.uuidString),
                    targetUserID: .init(poisonUser.uuidString)
                ),
                reason: .dataRepaired
            ), store: PostgresV2DurableWorkReplayStore(database: resources.database(.psql)), sql: sql, operatorPrincipal: "oncall-projection", now: now.addingTimeInterval(3)).outcome == .requeued)
            #expect(try await count("im_v2.user_projection_ready", on: sql) == 1)
            #expect(try await worker.runOnce(now: now.addingTimeInterval(3)) == .init(
                claimed: true, appliedRecordCount: 1
            ))
            #expect(try await count("im_v2.user_projection_ready", on: sql) == 0)
            #expect(try await currentV3ProjectionItems(
                sql: sql, userID: .init(poisonUser.uuidString), kind: "relationship"
            ).count == 1)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("sync-log compaction is device-independent and low cursors lazily share one snapshot")
    func userSyncLogCompactionAndLowCursorReset() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let old = now.addingTimeInterval(-10_000)
            let user = UUID(uuidString: "00000000-0000-0000-0000-000000000c11")!
            let lowDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000c12")!
            let currentDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000c13")!
            let newDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000c14")!
            let events = (1 ... 3).map {
                UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", 0xc20 + $0))!
            }
            try await sql.raw("""
                INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at)
                VALUES
                    (\(bind: user), \(bind: lowDevice), \(bind: old), \(bind: now)),
                    (\(bind: user), \(bind: currentDevice), \(bind: old), \(bind: now)),
                    (\(bind: user), \(bind: newDevice), \(bind: old), \(bind: now))
                """).run()
            try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: user), 3)").run()
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind,
                     payload, created_at)
                VALUES
                    (\(bind: user), 1, \(bind: events[0]), 'relationship',
                     '{"target_user_id":"00000000-0000-0000-0000-000000000c31","state":"accepted","updated_at_ms":1}'::jsonb,
                     \(bind: old)),
                    (\(bind: user), 2, \(bind: events[1]), 'relationship',
                     '{"target_user_id":"00000000-0000-0000-0000-000000000c32","state":"accepted","updated_at_ms":2}'::jsonb,
                     \(bind: old)),
                    (\(bind: user), 3, \(bind: events[2]), 'relationship',
                     '{"target_user_id":"00000000-0000-0000-0000-000000000c33","state":"accepted","updated_at_ms":3}'::jsonb,
                     \(bind: old))
                """).run()

            try await sql.raw("""
                INSERT INTO im_v2.device_sync_cursors
                    (user_id, device_id, state, reset_generation, acknowledged_sequence)
                VALUES (\(bind: user), \(bind: lowDevice), 'ready', 1, 0),
                       (\(bind: user), \(bind: currentDevice), 'ready', 1, 3)
                """).run()
            // The first sequence of an unexpired receipt is inclusive. It
            // must remain physically available until that receipt expires.
            try await sql.raw("""
                INSERT INTO im_v2.sync_receipts
                    (receipt, user_id, device_id, reset_generation,
                     first_sequence, last_sequence, expires_at, created_at)
                VALUES ('compaction-receipt', \(bind: user), \(bind: currentDevice), 1,
                        2, 3, \(bind: now.addingTimeInterval(0.5)), \(bind: old))
                """).run()
            let projector = PostgresV2UserProjectionWorker(database: resources.database(.psql), batchSize: 10)
            #expect(try await projector.runOnce(now: old).appliedRecordCount == 3)

            let compactor = PostgresV2UserSyncLogCompactionWorker(
                database: resources.database(.psql), minimumLogAge: 60
            )
            #expect(try await compactor.runOnce(now: now, userLimit: 1, rowLimit: 2) == .init(
                claimedUserCount: 1,
                deletedLogRowCount: 1
            ))
            let floor = try #require(try await sql.raw("""
                SELECT compacted_through_sequence AS value
                FROM im_v2.user_sync_retention WHERE user_id = \(bind: user)
                """).first(decoding: CountRow.self)).value
            #expect(floor == 1)
            let receiptProtectedSequences = try await sql.raw("""
                SELECT user_sync_sequence AS value FROM im_v2.user_sync_log
                WHERE user_id = \(bind: user) ORDER BY user_sync_sequence
                """).all(decoding: CountRow.self).map(\.value)
            #expect(receiptProtectedSequences == [2, 3])
            let fenced = try #require(try await sql.raw("""
                SELECT state, acknowledged_sequence, pending_snapshot_id
                FROM im_v2.device_sync_cursors
                WHERE user_id = \(bind: user) AND device_id = \(bind: lowDevice)
                """).first(decoding: HousekeepingCursorAssertionRow.self))
            #expect(fenced.state == "ready")
            #expect(fenced.pendingSnapshotID == nil)
            #expect(try await count("im_v2.sync_snapshot_artifacts", on: sql) == 0)

            #expect(try await compactor.runOnce(now: now.addingTimeInterval(1), userLimit: 1, rowLimit: 2) == .init(
                claimedUserCount: 1,
                deletedLogRowCount: 2
            ))
            #expect(try await count("im_v2.user_sync_log", on: sql) == 0)

            #expect(try await count("im_v2.user_projection_effects", on: sql) == 3)
            let stableEffect = try #require(try await sql.raw("""
                SELECT user_sync_sequence AS value
                FROM im_v2.user_projection_effects
                WHERE user_id = \(bind: user) AND source_event_id = \(bind: events[0])
                  AND projection_kind = 'relationship'
                """).first(decoding: CountRow.self))
            #expect(stableEffect.value == 1)

            // No maintenance pass scans or mutates historical devices. The
            // first real low-watermark pull stages one checkpoint artifact;
            // another device gets its own tokens and generation while reusing
            // the immutable payload build even if the checkpoint advances.
            let sync = PostgresV2SyncStore(
                database: resources.database(.psql), capabilityProfile: "base",
                capabilityLifetime: 600
            )
            guard case let .resetPreparing(lowSnapshot, lowGeneration, _) = try await sync.pull(
                userID: .init(user.uuidString), deviceID: .init(lowDevice.uuidString),
                syncToken: nil, maxRecords: 10, now: now.addingTimeInterval(2)
            ) else {
                Issue.record("expected retained-floor reset for existing low device")
                try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
                try await resources.shutdown()
                return
            }
            let catchupEvent = UUID(uuidString: "00000000-0000-0000-0000-000000000c24")!
            try await sql.raw("UPDATE im_v2.user_sync_sequences SET next_sequence = 4 WHERE user_id = \(bind: user)").run()
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind,
                     payload, created_at)
                VALUES (\(bind: user), 4, \(bind: catchupEvent), 'relationship',
                        '{"target_user_id":"00000000-0000-0000-0000-000000000c34","state":"accepted","updated_at_ms":4}'::jsonb,
                        \(bind: now.addingTimeInterval(2)))
                """).run()
            #expect(try await projector.runOnce(now: now.addingTimeInterval(2)).appliedRecordCount == 1)
            guard case let .resetPreparing(newSnapshot, newGeneration, _) = try await sync.pull(
                userID: .init(user.uuidString), deviceID: .init(newDevice.uuidString),
                syncToken: nil, maxRecords: 10, now: now.addingTimeInterval(3)
            ) else {
                Issue.record("expected retained-floor reset for new device")
                try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
                try await resources.shutdown()
                return
            }
            #expect(lowGeneration == 2)
            #expect(newGeneration == 2)
            #expect(lowSnapshot == newSnapshot)
            #expect(try await count("im_v2.sync_snapshot_artifacts", on: sql) == 1)
            #expect(try await count("im_v2.device_snapshot_resets", on: sql) == 2)

            // Manual reset watermarks come from the monotonic allocator, not
            // MAX(log), which is now empty after successful compaction.
            let resetRoute = try V2UserShardRoute(bucket: "control", observedRouterEpoch: 1)
            let resetService = try V2PostgresDeviceSnapshotResetService(
                registry: try V2StaticUserShardStorageRegistry(locations: [
                    try .init(bucket: "control", database: resources.database(.psql), schema: "im_v2")
                ]),
                deviceAvailability: V2PostgresDeviceAvailabilityChecker(
                    database: resources.database(.psql)
                ),
                routeFence: V2FixedUserShardRouteFence(route: resetRoute, database: resources.database(.psql)),
                capabilityProfile: "base",
                now: { now.addingTimeInterval(2) }
            )
            let manualResetDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000c15")!
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: user), \(bind: manualResetDevice), \(bind: old), \(bind: now))").run()
            let resetOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000c16")!
            let manualReset = try await resetService.stage(.init(
                operationID: resetOperationID,
                userID: .init(user.uuidString), deviceID: .init(manualResetDevice.uuidString)
            ))
            #expect(manualReset.state == .preparing)
            let resetBase = try #require(try await sql.raw("""
                SELECT base_user_sync_sequence AS value
                FROM im_v2.sync_snapshot_artifacts
                WHERE snapshot_id = \(bind: resetOperationID)
                """).first(decoding: CountRow.self))
            #expect(resetBase.value == 4)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("snapshot reset authorizes against control plane for an independent user shard")
    func snapshotResetUsesControlPlaneDeviceAuthority() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        let shardSchema = "im_v2_reset_shard"
        do {
            resources.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2),
                as: .psql, isDefault: true
            )
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists")
                .first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            try await installSchema(on: sql, schema: shardSchema)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let user = UUID(uuidString: "00000000-0000-0000-0000-000000000cf1")!
            let device = UUID(uuidString: "00000000-0000-0000-0000-000000000cf2")!
            let operation = UUID(uuidString: "00000000-0000-0000-0000-000000000cf3")!
            try await sql.raw("""
                INSERT INTO im_v2.auth_devices
                    (user_id, device_id, created_at, last_active_at)
                VALUES (\(bind: user), \(bind: device), \(bind: now), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: shardSchema).user_projection_checkpoints
                    (user_id, projected_sequence, updated_at)
                VALUES (\(bind: user), 0, \(bind: now))
                """).run()
            #expect(try await count("\(shardSchema).auth_devices", on: sql) == 0)

            let route = try V2UserShardRoute(
                bucket: "reset-shard",
                observedRouterEpoch: 1
            )
            let storage = try V2StaticUserShardStorageRegistry(locations: [
                try .init(
                    bucket: route.bucket,
                    database: resources.database(.psql),
                    schema: shardSchema
                ),
                try .init(
                    bucket: "control",
                    database: resources.database(.psql),
                    schema: "im_v2"
                ),
            ])
            let service = try V2PostgresDeviceSnapshotResetService(
                registry: storage,
                deviceAvailability: V2PostgresDeviceAvailabilityChecker(
                    database: resources.database(.psql)
                ),
                routeFence: V2FixedUserShardRouteFence(route: route, database: resources.database(.psql)),
                capabilityProfile: "base",
                now: { now }
            )
            #expect(try await service.stage(.init(
                operationID: operation,
                userID: .init(user.uuidString),
                deviceID: .init(device.uuidString)
            )) == .init(generation: 2, state: .preparing, wasIdempotent: false))
            #expect(try await count("\(shardSchema).sync_snapshot_artifacts", on: sql) == 1)

            try await sql.raw("""
                UPDATE im_v2.auth_devices SET revoked_at = \(bind: now)
                WHERE user_id = \(bind: user) AND device_id = \(bind: device)
                """).run()
            await #expect(throws: V2DeviceSnapshotResetError.deviceUnavailable) {
                try await service.stage(.init(
                    operationID: UUID(),
                    userID: .init(user.uuidString),
                    deviceID: .init(device.uuidString)
                ))
            }

            // Revocation removes capabilities from the configured current owner.
            try await V2RoutedRevokedDeviceProjectionCleaner(
                routeFence: StaticUserShardRouteFence(
                    route: route,
                    database: resources.database(.psql)
                ),
                registry: storage,
                coLocatedControlBuckets: ["control"]
            ).clean(
                userID: .init(user.uuidString),
                deviceID: .init(device.uuidString),
                revokedAt: now
            )
            #expect(try await count("\(shardSchema).device_sync_cursors", on: sql) == 0)
            #expect(try await count("im_v2.device_sync_cursors", on: sql) == 0)
            #expect(try await count(
                "\(shardSchema).revoked_device_projection_tombstones",
                on: sql
            ) == 1)
            #expect(try await count(
                "im_v2.revoked_device_projection_tombstones",
                on: sql
            ) == 0)
            #expect(try await sql.raw("""
                SELECT COUNT(DISTINCT revoked_at) AS value
                FROM (
                    SELECT revoked_at
                    FROM im_v2.revoked_device_projection_tombstones
                    WHERE user_id = \(bind: user) AND device_id = \(bind: device)
                    UNION ALL
                    SELECT revoked_at
                    FROM \(unsafeRaw: shardSchema).revoked_device_projection_tombstones
                    WHERE user_id = \(bind: user) AND device_id = \(bind: device)
                ) AS tombstones
                """).first(decoding: CountRow.self)?.value == 1)
            await #expect(throws: V2SyncStoreError.deviceRevoked) {
                try await PostgresV2SyncStore(
                    database: resources.database(.psql),
                    schema: shardSchema
                ).pull(
                    userID: .init(user.uuidString),
                    deviceID: .init(device.uuidString),
                    syncToken: nil,
                    maxRecords: 10,
                    now: now
                )
            }
            #expect(try await count("\(shardSchema).device_sync_cursors", on: sql) == 0)

            try await sql.raw("DROP SCHEMA \(unsafeRaw: shardSchema) CASCADE").run()
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS \(unsafeRaw: shardSchema) CASCADE").run()
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("snapshot V3 resumes page-by-page, publishes immediately, and GC preserves active baselines")
    func snapshotV3ArtifactResumptionAndVersionGC() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let user = UUID(uuidString: "00000000-0000-0000-0000-000000000d01")!
            let device = UUID(uuidString: "00000000-0000-0000-0000-000000000d02")!
            let targetOne = UUID(uuidString: "00000000-0000-0000-0000-000000000d03")!
            let targetTwo = UUID(uuidString: "00000000-0000-0000-0000-000000000d04")!
            let eventOne = UUID(uuidString: "00000000-0000-0000-0000-000000000d05")!
            let eventTwo = UUID(uuidString: "00000000-0000-0000-0000-000000000d06")!
            let eventThree = UUID(uuidString: "00000000-0000-0000-0000-000000000d07")!
            let protectedSnapshot = UUID(uuidString: "00000000-0000-0000-0000-000000000d08")!
            let snapshot = UUID(uuidString: "00000000-0000-0000-0000-000000000d09")!
            let nextSnapshot = UUID(uuidString: "00000000-0000-0000-0000-000000000d10")!
            let profile = "base"
            let protectedDigest = V2SnapshotV3Digest.initial(baseSequence: 1, capabilityProfile: profile)
            let initialDigest = V2SnapshotV3Digest.initial(baseSequence: 3, capabilityProfile: profile)

            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: user), \(bind: device), \(bind: now), \(bind: now))").run()
            try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: user), 3)").run()
            try await sql.raw("INSERT INTO im_v2.user_projection_checkpoints (user_id, projected_sequence, updated_at) VALUES (\(bind: user), 3, \(bind: now))").run()
            try await sql.raw("""
                INSERT INTO im_v2.user_projection_versions
                    (user_id, projection_kind, entity_key, valid_from_sequence,
                     valid_to_sequence, source_event_id, payload, created_at)
                VALUES
                    (\(bind: user), 'relationship', \(bind: targetOne.uuidString.lowercased()), 1, 2,
                     \(bind: eventOne), \(bind: "{\"target_user_id\":\"\(targetOne.uuidString.lowercased())\",\"state\":\"pending\",\"requested_by_user_id\":\"\(user.uuidString.lowercased())\",\"updated_at_ms\":1749999999000}")::jsonb, \(bind: now.addingTimeInterval(-1))),
                    (\(bind: user), 'relationship', \(bind: targetOne.uuidString.lowercased()), 2, NULL,
                     \(bind: eventTwo), \(bind: "{\"target_user_id\":\"\(targetOne.uuidString.lowercased())\",\"state\":\"accepted\",\"updated_at_ms\":1750000000000}")::jsonb, \(bind: now)),
                    (\(bind: user), 'relationship', \(bind: targetTwo.uuidString.lowercased()), 3, NULL,
                     \(bind: eventThree), \(bind: "{\"target_user_id\":\"\(targetTwo.uuidString.lowercased())\",\"state\":\"accepted\",\"updated_at_ms\":1750000000000}")::jsonb, \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.sync_snapshot_artifacts
                    (snapshot_id, user_id, base_user_sync_sequence, source_projected_sequence,
                     schema_version, capability_profile, state, rolling_digest,
                     expires_at, created_at)
                VALUES (\(bind: protectedSnapshot), \(bind: user), 1, 3, 30, \(bind: profile),
                        'building', \(bind: protectedDigest), \(bind: now.addingTimeInterval(600)),
                        \(bind: now.addingTimeInterval(-10)))
                """).run()

            let gc = PostgresV2ProjectionVersionGCWorker(database: resources.database(.psql))
            #expect(try await gc.runOnce(now: now, limit: 10) == 0)
            try await sql.raw("UPDATE im_v2.sync_snapshot_artifacts SET state = 'failed', failure_code = 'test' WHERE snapshot_id = \(bind: protectedSnapshot)").run()
            #expect(try await gc.runOnce(now: now, limit: 10) == 1)

            try await sql.raw("""
                INSERT INTO im_v2.sync_snapshot_artifacts
                    (snapshot_id, user_id, base_user_sync_sequence, source_projected_sequence,
                     schema_version, capability_profile, state, rolling_digest,
                     expires_at, created_at)
                VALUES (\(bind: snapshot), \(bind: user), 3, 3, 30, \(bind: profile),
                        'building', \(bind: initialDigest), \(bind: now.addingTimeInterval(600)), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.device_snapshot_resets
                    (user_id, device_id, reset_generation, snapshot_id, state,
                     next_sync_token, snapshot_receipt, expires_at, created_at)
                VALUES (\(bind: user), \(bind: device), 2, \(bind: snapshot), 'preparing',
                        'snapshot-v3-token', 'snapshot-v3-receipt',
                        \(bind: now.addingTimeInterval(600)), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.device_sync_cursors
                    (user_id, device_id, state, reset_generation, acknowledged_sequence,
                     pending_snapshot_id, pending_base_sequence, pending_snapshot_expires_at)
                VALUES (\(bind: user), \(bind: device), 'reset_preparing', 2, 0,
                        \(bind: snapshot), 3, \(bind: now.addingTimeInterval(600)))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.sync_receipts
                    (receipt, user_id, device_id, reset_generation, first_sequence,
                     last_sequence, expires_at, created_at)
                VALUES ('pre-reset-incremental-receipt', \(bind: user), \(bind: device), 1,
                        1, 3, \(bind: now.addingTimeInterval(600)), \(bind: now))
                """).run()
            let sync = V2SyncService(
                store: PostgresV2SyncStore(database: resources.database(.psql)), now: { now }
            )
            try await sync.acknowledge(
                userID: .init(user.uuidString), deviceID: .init(device.uuidString),
                generation: 1, highestContiguousSequence: 3,
                receipt: .init("pre-reset-incremental-receipt")
            )
            let resetPreparingAfterIncrementalACK = try #require(try await sql.raw("""
                SELECT state, acknowledged_sequence, pending_snapshot_id
                FROM im_v2.device_sync_cursors
                WHERE user_id = \(bind: user) AND device_id = \(bind: device)
                """).first(decoding: HousekeepingCursorAssertionRow.self))
            #expect(resetPreparingAfterIncrementalACK.state == "reset_preparing")
            #expect(resetPreparingAfterIncrementalACK.acknowledgedSequence == 3)
            #expect(resetPreparingAfterIncrementalACK.pendingSnapshotID == snapshot)

            let builder = PostgresV2SnapshotArtifactBuilder(
                database: resources.database(.psql), pageItemLimit: 1, maximumCandidateItems: 1
            )
            #expect(try await builder.runOnce(now: now) == .init(claimed: true, published: false, pageCount: 1, itemCount: 1))
            // A committed page releases the lease; the same artifact advances
            // immediately rather than sleeping for the 30-second lease TTL.
            #expect(try await builder.runOnce(now: now) == .init(claimed: true, published: false, pageCount: 2, itemCount: 2))
            #expect(try await builder.runOnce(now: now) == .init(claimed: true, published: true, pageCount: 2, itemCount: 2))

            let artifact = try #require(try await sql.raw("""
                SELECT state, root_digest, page_count, item_count, total_bytes
                FROM im_v2.sync_snapshot_artifacts WHERE snapshot_id = \(bind: snapshot)
                """).first(decoding: SnapshotV3ArtifactAssertionRow.self))
            #expect(artifact.state == "published")
            #expect(artifact.rootDigest?.count == 64)
            #expect(artifact.pageCount == 2)
            #expect(artifact.itemCount == 2)
            #expect(artifact.totalBytes > 0)

            let manifest = try await sync.fetchSnapshotManifest(
                userID: .init(user.uuidString), deviceID: .init(device.uuidString),
                snapshotID: .init(snapshot.uuidString), generation: 2
            )
            #expect(manifest.pageCount == 2)
            var rolling = initialDigest
            for index in 0 ..< manifest.pageCount {
                let page = try await sync.fetchSnapshotPage(
                    userID: .init(user.uuidString), deviceID: .init(device.uuidString),
                    snapshotID: .init(snapshot.uuidString), generation: 2,
                    rootDigest: manifest.rootDigest, index: index
                )
                #expect(try V2SnapshotProjectionV3Codec.decode(page.payload).items.count == 1)
                rolling = V2SnapshotV3Digest.next(
                    previous: rolling, pageIndex: page.index, pageDigest: page.digest,
                    firstKey: page.firstKey, lastKey: page.lastKey, itemCount: page.itemCount
                )
            }
            #expect(rolling == manifest.rootDigest)
            try await sync.acknowledgeSnapshot(
                userID: .init(user.uuidString), deviceID: .init(device.uuidString),
                snapshotID: .init(snapshot.uuidString), generation: 2,
                baseSequence: 3, receipt: .init("snapshot-v3-receipt")
            )
            let cursor = try #require(try await sql.raw("""
                SELECT state, acknowledged_sequence, pending_snapshot_id
                FROM im_v2.device_sync_cursors WHERE user_id = \(bind: user) AND device_id = \(bind: device)
                """).first(decoding: HousekeepingCursorAssertionRow.self))
            #expect(cursor.state == "ready")
            #expect(cursor.acknowledgedSequence == 3)
            #expect(cursor.pendingSnapshotID == nil)

            // The server commit can race a client crash before that client
            // activates its local shadow. Even if the next reset has already
            // been staged, replaying the exact previous ACK must be a no-op;
            // it must not overwrite the newer pending generation fence.
            try await sql.raw("""
                INSERT INTO im_v2.sync_snapshot_artifacts
                    (snapshot_id, user_id, base_user_sync_sequence, source_projected_sequence,
                     schema_version, capability_profile, state, rolling_digest,
                     expires_at, created_at)
                VALUES (
                    \(bind: nextSnapshot), \(bind: user), 3, 3, 30, \(bind: profile),
                    'building', \(bind: initialDigest), \(bind: now.addingTimeInterval(600)), \(bind: now)
                )
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.device_snapshot_resets
                    (user_id, device_id, reset_generation, snapshot_id, state,
                     next_sync_token, snapshot_receipt, expires_at, created_at)
                VALUES (
                    \(bind: user), \(bind: device), 3, \(bind: nextSnapshot), 'preparing',
                    'snapshot-v3-next-token', 'snapshot-v3-next-receipt',
                    \(bind: now.addingTimeInterval(600)), \(bind: now)
                )
                """).run()
            try await sql.raw("""
                UPDATE im_v2.device_sync_cursors
                SET state = 'reset_preparing', reset_generation = 3,
                    pending_snapshot_id = \(bind: nextSnapshot), pending_base_sequence = 3,
                    pending_snapshot_expires_at = \(bind: now.addingTimeInterval(600))
                WHERE user_id = \(bind: user) AND device_id = \(bind: device)
                """).run()
            try await sync.acknowledgeSnapshot(
                userID: .init(user.uuidString), deviceID: .init(device.uuidString),
                snapshotID: .init(snapshot.uuidString), generation: 2,
                baseSequence: 3, receipt: .init("snapshot-v3-receipt")
            )
            let stagedAfterReplay = try #require(try await sql.raw("""
                SELECT state, reset_generation, pending_snapshot_id
                FROM im_v2.device_sync_cursors
                WHERE user_id = \(bind: user) AND device_id = \(bind: device)
                """).first(decoding: SnapshotV3RecoveredCursorRow.self))
            #expect(stagedAfterReplay.state == "reset_preparing")
            #expect(stagedAfterReplay.resetGeneration == 3)
            #expect(stagedAfterReplay.pendingSnapshotID == nextSnapshot)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("snapshot V3 publishes an empty account and rolls back a failed build generation")
    func snapshotV3EmptyAccountAndFailedBuildRecovery() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1),
                as: .psql, isDefault: true
            )
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists")
                .first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let userUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000e01")!
            let deviceUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000e02")!
            let emptySnapshot = UUID(uuidString: "00000000-0000-0000-0000-000000000e03")!
            let failedSnapshot = UUID(uuidString: "00000000-0000-0000-0000-000000000e04")!
            let retrySnapshot = UUID(uuidString: "00000000-0000-0000-0000-000000000e05")!
            let sourceEvent = UUID(uuidString: "00000000-0000-0000-0000-000000000e06")!
            let userID = try UserID(userUUID.uuidString)
            let deviceID = try DeviceID(deviceUUID.uuidString)
            try await sql.raw("""
                INSERT INTO im_v2.auth_devices
                    (user_id, device_id, created_at, last_active_at)
                VALUES (\(bind: userUUID), \(bind: deviceUUID), \(bind: now), \(bind: now))
                """).run()

            let route = try V2UserShardRoute(bucket: "snapshot-v3-test", observedRouterEpoch: 1)
            let reset = try V2PostgresDeviceSnapshotResetService(
                registry: V2StaticUserShardStorageRegistry(locations: [
                    try .init(bucket: route.bucket, database: resources.database(.psql), schema: "im_v2")
                ]),
                deviceAvailability: V2PostgresDeviceAvailabilityChecker(
                    database: resources.database(.psql)
                ),
                routeFence: V2FixedUserShardRouteFence(route: route, database: resources.database(.psql)),
                capabilityProfile: "base",
                makeUUID: { UUID() }, now: { now }
            )
            #expect(try await reset.stage(.init(
                operationID: emptySnapshot, userID: userID, deviceID: deviceID
            )) == .init(generation: 2, state: .preparing, wasIdempotent: false))

            let builder = PostgresV2SnapshotArtifactBuilder(database: resources.database(.psql))
            #expect(try await builder.runOnce(now: now) == .init(
                claimed: true, published: true, pageCount: 0, itemCount: 0
            ))
            let sync = V2SyncService(store: PostgresV2SyncStore(database: resources.database(.psql)), now: { now })
            let emptyManifest = try await sync.fetchSnapshotManifest(
                userID: userID, deviceID: deviceID,
                snapshotID: .init(emptySnapshot.uuidString), generation: 2
            )
            #expect(emptyManifest.pageCount == 0)
            #expect(emptyManifest.totalItems == 0)
            #expect(emptyManifest.totalBytes == 0)
            try await sync.acknowledgeSnapshot(
                userID: userID, deviceID: deviceID,
                snapshotID: .init(emptySnapshot.uuidString), generation: 2,
                baseSequence: 0, receipt: emptyManifest.receipt
            )

            // Seed one projection that violates the V3 per-item contract.
            // Persistence can contain corrupt data; the builder must fail
            // closed without stranding the device on an unpublished generation.
            let oversizedJSONData = try JSONSerialization.data(withJSONObject: [
                "target_user_id": userUUID.uuidString.lowercased(),
                "state": "accepted",
                "padding": String(repeating: "x", count: V2SnapshotProjectionV3Codec.maximumItemBytes)
            ])
            guard let oversizedJSON = String(
                data: oversizedJSONData, encoding: .utf8
            ) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: userUUID), 1)").run()
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind,
                     payload, created_at)
                VALUES (\(bind: userUUID), 1, \(bind: sourceEvent), 'relationship',
                        '{}'::jsonb, \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.user_projection_versions
                    (user_id, projection_kind, entity_key, valid_from_sequence,
                     source_event_id, payload, created_at)
                VALUES (\(bind: userUUID), 'relationship', 'oversized', 1,
                        \(bind: sourceEvent), \(bind: oversizedJSON)::jsonb, \(bind: now))
                """).run()
            try await sql.raw("""
                UPDATE im_v2.user_projection_checkpoints
                SET projected_sequence = 1, updated_at = \(bind: now)
                WHERE user_id = \(bind: userUUID)
                """).run()

            #expect(try await reset.stage(.init(
                operationID: failedSnapshot, userID: userID, deviceID: deviceID
            )) == .init(generation: 3, state: .preparing, wasIdempotent: false))
            #expect(try await builder.runOnce(now: now) == .init(
                claimed: true, published: false, pageCount: 0, itemCount: 0
            ))
            let recovered = try #require(try await sql.raw("""
                SELECT state, reset_generation, pending_snapshot_id
                FROM im_v2.device_sync_cursors
                WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                """).first(decoding: SnapshotV3RecoveredCursorRow.self))
            #expect(recovered.state == "ready")
            #expect(recovered.resetGeneration == 2)
            #expect(recovered.pendingSnapshotID == nil)
            #expect(try await sql.raw("""
                SELECT 1 FROM im_v2.device_snapshot_resets
                WHERE snapshot_id = \(bind: failedSnapshot)
                """).first() == nil)
            #expect(try await sql.raw("""
                SELECT 1 FROM im_v2.sync_tokens
                WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                  AND reset_generation = 3
                """).first() == nil)

            let resumed = try await sync.pull(
                userID: userID, deviceID: deviceID,
                syncToken: emptyManifest.nextSyncToken, requestedMaxRecords: 10
            )
            guard case .ready(let generation, let records, _, _, _) = resumed else {
                Issue.record("expected the pre-reset generation to remain usable")
                return
            }
            #expect(generation == 2)
            #expect(records.map { $0.sequence } == [1])
            await #expect(throws: V2DeviceSnapshotResetError.unavailable) {
                try await reset.stage(.init(
                    operationID: failedSnapshot, userID: userID, deviceID: deviceID
                ))
            }
            #expect(try await reset.stage(.init(
                operationID: retrySnapshot, userID: userID, deviceID: deviceID
            )) == .init(generation: 3, state: .preparing, wasIdempotent: false))

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await resources.shutdown()
            throw error
        }
    }


    @Test("direct and social sync records shadow to a forwarding user shard with their source sequence")
    func currentOwnerReceivesDirectAndSocialUserSyncRecords() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              let secondaryDatabaseURL = Environment.get("IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            let secondaryID = DatabaseID(string: "secondary")
            resources.databases.use(try .postgres(url: secondaryDatabaseURL, maxConnectionsPerEventLoop: 1), as: secondaryID)
            guard let sql = resources.database(.psql) as? any SQLDatabase,
                  let secondarySQL = resources.database(secondaryID) as? any SQLDatabase
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false,
                  (try await secondarySQL.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false
            else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await installSchema(on: secondarySQL)

            let now = Date(timeIntervalSince1970: 1_750_000_100)
            let registry = try V2StaticUserShardStorageRegistry(locations: [
                try .init(bucket: "users-source", database: resources.database(.psql), schema: "im_v2"),
                try .init(bucket: "users-target", database: resources.database(secondaryID), schema: "im_v2"),
            ])
            let coordinationID = DatabaseID(string: "direct-sync-coordination")
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: coordinationID)
            let coordination = resources.database(coordinationID)
            let router = V2PostgresUserShardRouter(database: coordination)
            let eventFenceID = DatabaseID(string: "personal-event-fence")
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: eventFenceID)
            let eventProjector = try V2RoutedUserStateEventProjector(
                routeFence: V2PostgresUserShardRouter(database: resources.database(eventFenceID)), registry: registry)
            let eventOutbox = try PostgresV2UserStateEventOutbox(database: resources.database(.psql))
            try await configureDefaultUserShardRoute(
                .init(bucket: "users-target", observedRouterEpoch: 1),
                now: now,
                on: sql
            )
            let shadow = V2PostgresUserShardProjectionDelivery(
                registry: registry,
                routeFence: router,
                batchRouteFence: router,
                coLocatedControlBuckets: ["users-source"]
            )
            let direct = PostgresV2DirectMessagingStore(database: resources.database(.psql), identityReader: PostgresV2DirectRoomIdentityReader(database: coordination), projectionDelivery: shadow)
            let capacityProfile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3))
            let forwardingLeaseID = UUID(uuidString: "00000000-0000-0000-0000-000000000f17")!
            try await sql.raw("INSERT INTO im_v2.shard_admission_pools (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit) VALUES ('rooms-primary', 'standard', \(bind: forwardingLeaseID), 1, \(bind: now.addingTimeInterval(600)), 10)").run()
            try await sql.raw("INSERT INTO im_v2.public_user_profiles (user_id, public_handle, display_name, revision, created_at, updated_at) VALUES (\(bind: senderUUID), 'sender012', '发送者', 1, \(bind: now), \(bind: now)), (\(bind: memberTwoUUID), 'member015', '成员二', 1, \(bind: now), \(bind: now))").run()
            let directFixture = V2DirectRoomOperationTestFixture(store: direct, capacityProfile: capacityProfile,
                roomShardID: "rooms-primary", now: { now })
            let directRoom = try await directFixture.openedIdentity(actorUserID: senderID,
                operationID: .init("00000000-0000-0000-0000-000000000f18"), targetUserID: .init(memberTwoUUID.uuidString),
                firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            struct OpeningEligibility: Decodable { let value: Date }
            let openingTime = try #require(try await sql.raw("SELECT MAX(next_attempt_at) AS value FROM im_v2.user_state_event_outbox").first(decoding: OpeningEligibility.self)).value
            let openingLeases = try await eventOutbox.claim(now: openingTime, leaseDuration: 30, limit: 10)
            #expect(openingLeases.count == 1)
            let openingLease = try #require(openingLeases.first)
            #expect(try await eventProjector.project(openingLease.event) == 1)
            #expect(try await eventOutbox.acknowledge(openingLease, sequence: 1, now: openingTime))
            guard let directRoomUUID = UUID(uuidString: directRoom.roomID.rawValue) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            // Profile propagation intentionally targets only direct rooms
            // with message history. Seed that authority fact without running
            // the unrelated send-projection pipeline in this focused test.
            try await sql.raw("""
                INSERT INTO im_v2.messages
                    (message_id, room_id, room_sequence, timeline_sequence, sender_user_id,
                     client_message_id, text_body, created_at)
                VALUES
                    (\(bind: UUID(uuidString: "00000000-0000-0000-0000-000000000f20")!),
                     \(bind: directRoomUUID), 1, 1, \(bind: senderUUID),
                     \(bind: UUID(uuidString: "00000000-0000-0000-0000-000000000f21")!),
                     'history', \(bind: now))
                """).run()
            let preferences = PostgresV2AccountPreferenceOperationStore(database: resources.database(.psql),
                projectionDelivery: shadow, authorizationCoordinator: .init(controlDatabase: resources.database(.psql),
                    ownerDatabases: ["rooms-primary": resources.database(.psql)]))
            let preference = try await preferences.freezePreferenceFixture(owner: senderID,
                operation: .strangerMessagePreference(.init("00000000-0000-0000-0000-000000000f12")), value: .strangerMessage(.deny), now: now)
            let originalPreference = try await preferences.submit(preference, now: now)
            // The exact frozen command preserves its original proof and sync allocation.
            #expect(try await preferences.submit(preference, now: now.addingTimeInterval(1)) == originalPreference)
            let social = PostgresV2SocialRelationshipStore(database: resources.database(.psql), projectionDelivery: shadow)
            _ = try await social.executeSocialFixture(actorUserID: senderID, targetUserID: .init(memberTwoUUID.uuidString),
                operation: .relationship(.init("00000000-0000-0000-0000-000000000f13")), action: .relationship(.request), now: now.addingTimeInterval(2))

            // Account-owned profile changes use a separate outbox, but must
            // use the same current-owner delivery as the direct/social
            // control records. The changed profile belongs to member two; its
            // only direct recipient is the currently forwarding sender.
            let profileEventID = UUID(uuidString: "00000000-0000-0000-0000-000000000f19")!
            let directory = V2PostgresPublicIdentityDirectory(
                database: resources.database(.psql), policy: try .init(maximumQueries: 10, window: 60),
                makeUUID: { profileEventID }, now: { now.addingTimeInterval(3) }
            )
            _ = try await directory.updateDisplayName(
                for: try .init(memberTwoUUID.uuidString), displayName: "成员二新版"
            )
            let profileWorker = V2DirectRoomProfilePropagationWorker(
                database: resources.database(.psql), projectionDelivery: shadow, now: { now.addingTimeInterval(4) }
            )
            #expect(try await profileWorker.runOnce(limit: 1).projectedRecipientCount == 1)

            #expect(try await scopedCount("im_v2", "user_sync_log", user: senderUUID, on: sql) == 4)
            #expect(try await scopedCount("im_v2", "user_sync_log", user: senderUUID, on: secondarySQL) == 5)
            let targetRows = try await secondarySQL.raw("""
                SELECT user_sync_sequence, projection_kind
                FROM im_v2.user_sync_log WHERE user_id = \(bind: senderUUID)
                ORDER BY user_sync_sequence
                """).all(decoding: SyncKindRow.self)
            #expect(targetRows.map(\.sequence) == [1, 2, 3, 4, 5])
            #expect(targetRows.map(\.kind) == [
                "direct_room_profile", "stranger_message_permission", "relationship",
                "direct_room_profile", "profile_invalidation",
            ])
            let existingShadowSources = try await sql.raw("""
                SELECT source_event_id, projection_kind
                FROM im_v2.user_projection_effects
                WHERE user_id = \(bind: senderUUID)
                ORDER BY user_sync_sequence
                LIMIT 2
                """).all(decoding: ShadowIdentityRow.self)
            #expect(existingShadowSources.count == 2)
            let batchResults = try await shadow.deliverToCurrentShard(
                try existingShadowSources.map {
                    .init(
                        userID: senderID,
                        sourceEventID: try .init($0.sourceEventID.uuidString),
                        projectionKinds: [$0.projectionKind]
                    )
                }
            )
            #expect(batchResults.compactMap { $0 }.count == 2)
            // The batched retry uses the same immutable source identities and
            // must not allocate another target sequence.
            #expect(try await scopedCount(
                "im_v2", "user_sync_log", user: senderUUID, on: secondarySQL
            ) == 5)
            let forwardedProfile = try #require(try await secondarySQL.raw("""
                SELECT user_id, payload->>'room_id' AS room_id, payload->>'display_name' AS display_name,
                       (payload->>'revision')::bigint AS revision
                FROM im_v2.user_sync_log
                WHERE user_id = \(bind: senderUUID) AND source_event_id = \(bind: profileEventID)
                  AND projection_kind = 'direct_room_profile'
                """).first(decoding: ProfilePropagationProjectionRow.self))
            #expect(forwardedProfile.displayName == "成员二新版")
            #expect(forwardedProfile.revision == 2)
            #expect(UUID(uuidString: forwardedProfile.roomID)?.uuidString == forwardedProfile.roomID)

            // A target-owned personal effect consumes the next sequence.
            _ = try await PostgresV2UserProjectionStore(database: resources.database(secondaryID), schema: "im_v2")
                .projectAllocated(userID: senderID, sourceEventID: .init("00000000-0000-0000-0000-000000000f16"),
                    projectionKind: "stranger_permission", payloadJSON: "{}", createdAt: now.addingTimeInterval(4))
            _ = try await preferences.executePreferenceFixture(owner: senderID,
                operation: .strangerMessagePreference(.init("00000000-0000-0000-0000-000000000f15")),
                value: .strangerMessage(.allow), now: now.addingTimeInterval(5))
            #expect(try await scopedCount("im_v2", "user_sync_log", user: senderUUID, on: secondarySQL) == 7)
            let latestRecord = try #require(try await secondarySQL.raw("""
                SELECT user_sync_sequence, projection_kind FROM im_v2.user_sync_log
                WHERE user_id = \(bind: senderUUID) ORDER BY user_sync_sequence DESC LIMIT 1
                """).first(decoding: SyncKindRow.self))
            #expect(latestRecord.sequence == 7)
            #expect(latestRecord.kind == "stranger_message_permission")
            // Replaying the room event uses its persisted
            // receipt and cannot allocate another sequence on the current owner.
            #expect(try await eventProjector.project(openingLease.event) == 1)
            #expect(try await scopedCount("im_v2", "user_sync_log", user: senderUUID, on: secondarySQL) == 7)
            #expect((try await router.routes(for: [senderID])).first?.bucket == "users-target")

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await secondarySQL.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            if let secondarySQL = resources.database(DatabaseID(string: "secondary")) as? any SQLDatabase { try? await secondarySQL.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

}

private struct SnapshotV3ArtifactAssertionRow: Decodable {
    let state: String
    let rootDigest: String?
    let pageCount: Int?
    let itemCount: Int64
    let totalBytes: Int64
    enum CodingKeys: String, CodingKey {
        case state, rootDigest = "root_digest", pageCount = "page_count"
        case itemCount = "item_count", totalBytes = "total_bytes"
    }
}

private struct SnapshotV3RecoveredCursorRow: Decodable {
    let state: String
    let resetGeneration: Int64
    let pendingSnapshotID: UUID?
    enum CodingKeys: String, CodingKey {
        case state, resetGeneration = "reset_generation"
        case pendingSnapshotID = "pending_snapshot_id"
    }
}

private struct DisabledProfileAssertionRow: Decodable {
    let state: String
    let revision: Int64
    let visibilityRevision: Int64
    let avatarCleared: Bool
    enum CodingKeys: String, CodingKey {
        case state, revision
        case visibilityRevision = "visibility_revision"
        case avatarCleared = "avatar_cleared"
    }
}

private struct DisabledProfileOutboxAssertionRow: Decodable {
    let profileState: String
    let revision: Int64
    enum CodingKeys: String, CodingKey {
        case profileState = "profile_state"
        case revision
    }
}
private struct ProjectionPoisonCheckpointAssertionRow: Decodable {
    let state: String
    let failureCount: Int64
    let failedSequence: Int64?
    let lastFailureCode: String?
    enum CodingKeys: String, CodingKey {
        case state
        case failureCount = "failure_count"
        case failedSequence = "failed_sequence"
        case lastFailureCode = "last_failure_code"
    }
}
private struct SyncKindRow: Decodable {
    let sequence: Int64
    let kind: String
    enum CodingKeys: String, CodingKey { case sequence = "user_sync_sequence", kind = "projection_kind" }
}
private struct ShadowIdentityRow: Decodable {
    let sourceEventID: UUID
    let projectionKind: String
    enum CodingKeys: String, CodingKey {
        case sourceEventID = "source_event_id"
        case projectionKind = "projection_kind"
    }
}
private struct RemovedMembershipAssertionRow: Decodable { let leftRevision: Int64; enum CodingKeys: String, CodingKey { case leftRevision = "left_revision" } }
private struct ModeratedRemovalEventAssertionRow: Decodable { let eventType: String; let action: String; let targetUserID: String; enum CodingKeys: String, CodingKey { case eventType = "event_type", action, targetUserID = "target_user_id" } }
private struct StaticUserShardRouteFence: V2UserShardRouteFencing {
    let route: V2UserShardRoute
    let database: any Database

    func withCurrentRoute<Result: Sendable>(
        for _: UserID,
        _ operation: @escaping @Sendable (V2UserShardRoute, any Database) async throws -> Result
    ) async throws -> Result {
        try await operation(route, database)
    }
}
