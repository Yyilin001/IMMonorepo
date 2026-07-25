import Fluent
import FluentPostgresDriver
import Foundation
import IMV2Core
import IMV2ServerHTTP
@testable import IMV2Server
import SQLKit
import Testing
import Vapor
import VaporTesting

@Suite("V2 PostgreSQL room write", .serialized)
struct PostgresV2RoomWriteStoreIntegrationTests {
    @Test("one room-shard transaction creates message event plan and outbox")
    func atomicallyPersistsAcceptanceWriteSet() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else {
            return
        }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let schemaExists = try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self)
            guard schemaExists?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)

            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3)
            let store = PostgresV2RoomWriteStore(database: app.db(.psql))
            let service = V2SendMessageService(store: store, capacityProfile: try .init(id: "standard", limits: profile), limits: try .init(maxUTF8Bytes: 64), now: { Date(timeIntervalSince1970: 1_750_000_000) })
            let outcome = try await service.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "transactional"))
            guard case .accepted(let message) = outcome else {
                Issue.record("expected accepted message")
                return
            }
            try await sql.raw("""
                UPDATE im_v2.rooms SET membership_revision = 1 WHERE room_id = \(bind: roomUUID)
                """).run()
            try await sql.raw("""
                UPDATE im_v2.room_memberships
                SET left_revision = 1
                WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID) AND joined_revision = 0
                """).run()
            let replayAfterLeave = try await service.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "transactional"))

            let triggerRow = try #require(try await sql.raw("""
                SELECT source_event_id, plan_id FROM im_v2.room_outbox
                """).first(decoding: TriggerRow.self))
            let pushWindow = Date(timeIntervalSince1970: 1_750_000_001)
            let pushDispatchID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
            try await sql.raw("""
                INSERT INTO im_v2.push_campaigns (campaign_id, state, updated_at)
                VALUES ('sync-wake', 'enabled', \(bind: pushWindow))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.push_device_budgets
                    (device_id, campaign_id, window_started_at, max_work_units, max_new_key_operations)
                VALUES (\(bind: UUID(uuidString: deviceID.rawValue)!), 'sync-wake', \(bind: pushWindow), 1, 1)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.push_wake_outbox
                    (dispatch_id, source_event_id, target_user_id, target_device_id, campaign_id, budget_window_started_at, created_at)
                VALUES (\(bind: pushDispatchID), \(bind: triggerRow.sourceEventID), \(bind: senderUUID), \(bind: UUID(uuidString: deviceID.rawValue)!), 'sync-wake', \(bind: pushWindow), \(bind: pushWindow))
            """).run()
            let pushStore = PostgresV2PushWakeStore(database: app.db(.psql), makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000021")! })
            let pushLease = try #require(try await pushStore.claimAdmitted(now: pushWindow, leaseDuration: 30, limit: 1).first)
            try await pushStore.markSent(pushLease, now: pushWindow.addingTimeInterval(1))
            let planning = try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: testUserShardRouter),
                pageSize: 2,
                now: { Date(timeIntervalSince1970: 1_750_000_001) }
            ).plan(.init(sourceEventID: try .init(triggerRow.sourceEventID.uuidString), planID: try .init(triggerRow.planID.uuidString)))
            let deliveryWorker = V2FanoutDeliveryWorker(
                store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)),
                now: { Date(timeIntervalSince1970: 1_750_000_002) }
            )
            let firstDelivery = try await deliveryWorker.runOnce(limit: 1)
            let outboxBeforeFinalDelivery = try #require(try await sql.raw("""
                SELECT state FROM im_v2.room_outbox
                WHERE source_event_id = \(bind: triggerRow.sourceEventID)
                """).first(decoding: PushStateRow.self))
            let delivery = try await deliveryWorker.runOnce(limit: 8)
            let terminalOutbox = try #require(try await sql.raw("""
                SELECT state, terminal_at IS NOT NULL AS terminalized
                FROM im_v2.room_outbox
                WHERE source_event_id = \(bind: triggerRow.sourceEventID)
                """).first(decoding: TerminalOutboxStateRow.self))
            let deliveryRoutes = try await sql.raw("""
                SELECT DISTINCT target_shard_bucket, observed_router_epoch
                FROM im_v2.fanout_deliveries
                WHERE source_event_id = \(bind: triggerRow.sourceEventID)
                """).all(decoding: DeliveryRouteRow.self)
            let sync = V2SyncService(
                store: PostgresV2SyncStore(database: app.db(.psql)),
                now: { Date(timeIntervalSince1970: 1_750_000_003) }
            )
            let initialPull = try await sync.pull(userID: senderID, deviceID: deviceID, syncToken: nil, requestedMaxRecords: 2)
            guard case .ready(let initialGeneration, let records, let nextSyncToken, let receipt, let hasMore) = initialPull else {
                Issue.record("expected an initial sync batch")
                return
            }
            // The sender was removed from the room above, but the reset
            // baseline must retain the message actually delivered before that
            // change. It must not reconstruct visibility from current room
            // membership or mutable message tables.
            let projectionSnapshot = try await PostgresV2SnapshotProjectionMaterializer(database: app.db(.psql), pageItemLimit: 1).materialize(userID: senderID, now: Date(timeIntervalSince1970: 1_750_000_003))
            let projectionPages = try projectionSnapshot.pages.map { try V2SnapshotProjectionCodec.decodePage($0.payload) }
            let projectionMessages = projectionPages.flatMap(\.messages)
            await #expect(throws: V2SyncStoreError.invalidOrExpiredSyncReceipt) {
                try await sync.acknowledge(
                    userID: senderID,
                    deviceID: deviceID,
                    generation: initialGeneration,
                    highestContiguousSequence: try #require(records.last?.sequence),
                    receipt: try .init("forged-receipt")
                )
            }
            try await sync.acknowledge(userID: senderID, deviceID: deviceID, generation: initialGeneration, highestContiguousSequence: try #require(records.last?.sequence), receipt: receipt)
            let duplicatePull = try await sync.pull(userID: senderID, deviceID: deviceID, syncToken: nextSyncToken, requestedMaxRecords: 2)
            guard case .ready(_, let duplicateRecords, _, _, _) = duplicatePull else {
                Issue.record("expected a token-scoped duplicate batch")
                return
            }
            let resetGeneration = try await sync.stageReset(
                userID: senderID,
                deviceID: deviceID,
                snapshot: .init(snapshotID: snapshotID, baseSequence: 1, manifestDigest: "digest", nextSyncToken: try .init("opaque-next-token"), receipt: try .init("snapshot-receipt"), expiresAt: Date(timeIntervalSince1970: 1_750_000_100), schemaVersion: V2SnapshotProjectionCodec.schemaVersion, capabilityProfile: "base", pages: [.init(digest: "page-digest", payload: try V2SnapshotProjectionCodec.encode(messages: []))])
            )
            let resetPull = try await sync.pull(userID: senderID, deviceID: deviceID, syncToken: nil, requestedMaxRecords: 2)
            guard case .resetRequired(let returnedSnapshotID, let returnedGeneration, let returnedBase, _, _) = resetPull else {
                Issue.record("expected reset fence")
                return
            }
            let manifest = try await sync.fetchSnapshotManifest(userID: senderID, deviceID: deviceID, snapshotID: returnedSnapshotID, generation: returnedGeneration)
            let page = try await sync.fetchSnapshotPage(userID: senderID, deviceID: deviceID, snapshotID: returnedSnapshotID, generation: returnedGeneration, manifestDigest: manifest.manifestDigest, index: 0)
            try await sync.acknowledgeSnapshot(userID: senderID, deviceID: deviceID, snapshotID: returnedSnapshotID, generation: returnedGeneration, baseSequence: returnedBase, receipt: try .init("snapshot-receipt"))
            try await sync.acknowledgeSnapshot(userID: senderID, deviceID: deviceID, snapshotID: returnedSnapshotID, generation: returnedGeneration, baseSequence: returnedBase, receipt: try .init("snapshot-receipt"))
            let afterResetPull = try await sync.pull(userID: senderID, deviceID: deviceID, syncToken: manifest.nextSyncToken, requestedMaxRecords: 2)
            guard case .ready(let afterResetGeneration, let afterResetRecords, _, _, let afterResetHasMore) = afterResetPull else {
                Issue.record("expected ready cursor after snapshot acknowledgement")
                return
            }

            #expect(message.roomSequence == 1)
            #expect(replayAfterLeave == .idempotent(message))
            #expect(planning == .init(createdCompletionUnits: 2, createdDeliveries: 3, wasAlreadyPlanned: false))
            #expect(firstDelivery == .init(claimedCount: 1, committedCount: 1, staleCount: 0, releasedCount: 0))
            #expect(outboxBeforeFinalDelivery.state == "pending")
            #expect(delivery == .init(claimedCount: 2, committedCount: 2, staleCount: 0, releasedCount: 0))
            #expect(terminalOutbox.state == "terminal")
            #expect(terminalOutbox.terminalized)
            #expect(deliveryRoutes == [.init(bucket: "test-users", epoch: 9)])
            #expect(initialGeneration == 1)
            #expect(records.count == 1)
            #expect(projectionSnapshot.baseSequence == 1)
            #expect(projectionMessages.count == 1)
            #expect(projectionMessages.first?.messageID == message.messageID)
            #expect(projectionMessages.first?.text == "transactional")
            #expect(duplicateRecords.isEmpty)
            #expect(hasMore == false)
            #expect(resetGeneration == 2)
            #expect(returnedSnapshotID == snapshotID)
            #expect(returnedGeneration == 2)
            #expect(returnedBase == 1)
            #expect(manifest.pageDigests == ["page-digest"])
            #expect(manifest.nextSyncToken.rawValue == "opaque-next-token")
            #expect(try V2SnapshotProjectionCodec.decode(page.payload).isEmpty)
            #expect(afterResetGeneration == 2)
            #expect(afterResetRecords.isEmpty)
            #expect(afterResetHasMore == false)
            #expect(try await count("im_v2.messages", on: sql) == 1)
            #expect(try await count("im_v2.room_events", on: sql) == 1)
            #expect(try await count("im_v2.fanout_plans", on: sql) == 1)
            #expect(try await count("im_v2.room_outbox", on: sql) == 1)
            #expect(try await count("im_v2.fanout_completion_units", on: sql) == 2)
            #expect(try await count("im_v2.fanout_deliveries", on: sql) == 3)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 3)
            let syncedMessage = try #require(try await sql.raw("""
                SELECT payload->>'room_id' AS room_id, payload->>'message_id' AS message_id,
                       payload->>'sender_user_id' AS sender_user_id, payload->>'text' AS text,
                       payload->>'event_type' AS event_type
                FROM im_v2.user_sync_log
                WHERE projection_kind = 'message'
                LIMIT 1
                """).first(decoding: SyncedMessagePayloadRow.self))
            #expect(syncedMessage.roomID == roomUUID.uuidString)
            #expect(syncedMessage.messageID == message.messageID.rawValue)
            #expect(syncedMessage.senderUserID == senderUUID.uuidString)
            #expect(syncedMessage.text == "transactional")
            #expect(syncedMessage.eventType == "message.accepted")
            let capacity = try #require(try await sql.raw("SELECT command_window_used, fanout_window_used FROM im_v2.room_admission WHERE room_id = \(bind: roomUUID)").first(decoding: CapacityRow.self))
            #expect(capacity.commandWindowUsed == 1)
            #expect(capacity.fanoutWindowUsed == 3)
            let outstanding = try #require(try await sql.raw("SELECT outstanding_fanout_units, outstanding_plans FROM im_v2.room_admission WHERE room_id = \(bind: roomUUID)").first(decoding: OutstandingRow.self))
            #expect(outstanding.outstandingFanoutUnits == 0)
            #expect(outstanding.outstandingPlans == 0)
            let pushState = try #require(try await sql.raw("SELECT state FROM im_v2.push_wake_outbox WHERE dispatch_id = \(bind: pushDispatchID)").first(decoding: PushStateRow.self))
            let pushBudget = try #require(try await sql.raw("SELECT used_work_units, used_new_key_operations FROM im_v2.push_device_budgets WHERE device_id = \(bind: UUID(uuidString: deviceID.rawValue)!)").first(decoding: PushBudgetRow.self))
            #expect(pushLease.wake.deviceID == deviceID)
            #expect(pushState.state == "sent")
            #expect(pushBudget.usedWorkUnits == 1)
            #expect(pushBudget.usedNewKeyOperations == 0)

            let replacement = try await V2ShardAdmissionLeaseService(
                store: PostgresV2ShardAdmissionLeaseStore(database: app.db(.psql)),
                makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000019")! },
                now: { Date(timeIntervalSince1970: 1_750_000_200) }
            ).replaceExpired(
                key: try .init(roomShardID: "room-a", capacityProfileID: "standard"),
                capacityProfile: try .init(id: "standard", limits: profile),
                lifetime: 30
            )
            let cascadedFence = try #require(try await sql.raw("""
                SELECT shard_lease_id, shard_lease_generation
                FROM im_v2.room_admission WHERE room_id = \(bind: roomUUID)
                """).first(decoding: AdmissionFenceRow.self))
            #expect(replacement.generation == 2)
            #expect(cascadedFence.shardLeaseID.uuidString == replacement.id.rawValue)
            #expect(cascadedFence.shardLeaseGeneration == 2)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("Push wake retries reclaim expired leases without double-spending admission")
    func pushWakeRetryRecoveryPreservesAdmissionBudget() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let room = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
            let event = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
            let user = UUID(uuidString: "00000000-0000-0000-0000-000000000303")!
            let device = UUID(uuidString: "00000000-0000-0000-0000-000000000304")!
            let dispatch = UUID(uuidString: "00000000-0000-0000-0000-000000000305")!
            try await sql.raw("""
                INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id)
                VALUES (\(bind: room), 'room-a', 'standard')
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
                VALUES (\(bind: event), \(bind: room), 1, 'message.accepted', \(bind: user), '{}'::jsonb, 0, \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.push_campaigns (campaign_id, state, updated_at)
                VALUES ('wake', 'enabled', \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.push_device_budgets
                    (device_id, campaign_id, window_started_at, max_work_units, max_new_key_operations)
                VALUES (\(bind: device), 'wake', \(bind: now), 1, 1)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.push_wake_outbox
                    (dispatch_id, source_event_id, target_user_id, target_device_id, campaign_id, budget_window_started_at, created_at)
                VALUES (\(bind: dispatch), \(bind: event), \(bind: user), \(bind: device), 'wake', \(bind: now), \(bind: now))
                """).run()

            let store = PostgresV2PushWakeStore(
                database: app.db(.psql),
                makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000306")! }
            )
            let providerFailed = try #require(try await store.claimAdmitted(now: now, leaseDuration: 30, limit: 1).first)
            try await store.release(providerFailed)
            _ = try #require(try await store.claimAdmitted(now: now.addingTimeInterval(1), leaseDuration: 30, limit: 1).first)
            let reclaimed = try #require(try await store.claimAdmitted(now: now.addingTimeInterval(32), leaseDuration: 30, limit: 1).first)
            try await store.markSent(reclaimed, now: now.addingTimeInterval(33))

            let state = try #require(try await sql.raw("SELECT state, retry_count, admitted_at FROM im_v2.push_wake_outbox WHERE dispatch_id = \(bind: dispatch)").first(decoding: PushRecoveryStateRow.self))
            let budget = try #require(try await sql.raw("SELECT used_work_units, used_new_key_operations FROM im_v2.push_device_budgets WHERE device_id = \(bind: device)").first(decoding: PushBudgetRow.self))
            #expect(state.state == "sent")
            #expect(state.retryCount == 3)
            #expect(state.admittedAt == now)
            #expect(budget.usedWorkUnits == 1)
            #expect(budget.usedNewKeyOperations == 0)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("Push endpoint encryption is device-bound and late rejection cannot disable a fresh registration")
    func pushEndpointRegistrationUsesGenerationFence() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("""
                INSERT INTO im_v2.auth_devices (user_id, device_id, created_at)
                VALUES (\(bind: senderUUID), \(bind: UUID(uuidString: deviceID.rawValue)!), \(bind: now))
                """).run()
            let key = try V2PushEndpointEnvelopeKey(rawBytes: Data(repeating: 7, count: 32))
            let store = PostgresV2PushDeviceEndpointStore(
                database: app.db(.psql),
                envelopeKey: key
            )
            let firstToken = String(repeating: "a", count: 64)
            try await store.register(
                actorUserID: senderID,
                deviceID: deviceID,
                endpoint: try .init(provider: .apns, environment: .development, token: firstToken),
                now: now
            )
            let first = try #require(try await store.endpoint(for: deviceID))
            try await store.register(
                actorUserID: senderID,
                deviceID: deviceID,
                endpoint: try .init(provider: .apns, environment: .production, token: String(repeating: "b", count: 64)),
                now: now.addingTimeInterval(1)
            )
            try await store.disable(first, now: now.addingTimeInterval(2))
            let current = try #require(try await store.endpoint(for: deviceID))
            let encrypted = try #require(try await sql.raw("""
                SELECT encrypted_token FROM im_v2.push_device_endpoints
                WHERE device_id = \(bind: UUID(uuidString: deviceID.rawValue)!)
                """).first(decoding: EncryptedPushEndpointRow.self))

            #expect(current.generation != first.generation)
            #expect(current.environment == .production)
            #expect(current.token == String(repeating: "b", count: 64))
            #expect(encrypted.encryptedToken != current.token)

            try await store.disable(current, now: now.addingTimeInterval(3))
            #expect(try await store.endpoint(for: deviceID) == nil)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("fan-out planner commits page checkpoints and resumes after an interrupted enumeration")
    func fanoutPlannerResumesFromDurablePageCheckpoint() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10,
                maxCommandsPerWindow: 10,
                maxFanoutUnitsPerWindow: 100,
                maxOutstandingFanoutUnits: 100,
                maxOutstandingPlans: 10,
                maxEnumerationPageSize: 10,
                maxPlannerConcurrency: 1,
                maxDeliveryConcurrency: 1,
                retryAfterSeconds: 3
            ))
            let send = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: app.db(.psql)),
                capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64),
                now: { now }
            )
            guard case .accepted = try await send.send(.init(
                roomID: roomID,
                actorUserID: senderID,
                clientMessageID: clientMessageID,
                text: "checkpointed planning"
            )) else {
                Issue.record("expected accepted message")
                return
            }
            let trigger = try #require(try await sql.raw("SELECT source_event_id, plan_id FROM im_v2.room_outbox").first(decoding: TriggerRow.self))
            let plannerTrigger = try V2FanoutPlanTrigger(sourceEventID: .init(trigger.sourceEventID.uuidString), planID: .init(trigger.planID.uuidString))

            await #expect(throws: PlannerInterruption.afterFirstCheckpoint) {
                try await V2FanoutPlanner(
                    store: PostgresV2FanoutPlanStore(
                        database: app.db(.psql),
                        router: FailsOnSecondPageRouter(blockedUserID: try .init(memberTwoUUID.uuidString))
                    ),
                    pageSize: 1,
                    now: { now.addingTimeInterval(1) }
                ).plan(plannerTrigger)
            }

            let interrupted = try #require(try await sql.raw("""
                SELECT state, enumeration_checkpoint->>'after_user_id' AS after_user_id
                FROM im_v2.fanout_plans WHERE plan_id = \(bind: trigger.planID)
                """).first(decoding: PlanningCheckpointAssertionRow.self))
            let interruptedCompletionUnits = try await count("im_v2.fanout_completion_units", on: sql)
            let interruptedDeliveries = try await count("im_v2.fanout_deliveries", on: sql)
            let prematureDelivery = try await V2FanoutDeliveryWorker(
                store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)),
                now: { now.addingTimeInterval(2) }
            ).runOnce(limit: 8)

            let resumed = try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: testUserShardRouter),
                pageSize: 1,
                now: { now.addingTimeInterval(3) }
            ).plan(plannerTrigger)
            let delivery = try await V2FanoutDeliveryWorker(
                store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)),
                now: { now.addingTimeInterval(4) }
            ).runOnce(limit: 8)

            #expect(interrupted.state == "planning")
            #expect(interrupted.afterUserID == senderUUID.uuidString)
            #expect(interruptedCompletionUnits == 1)
            #expect(interruptedDeliveries == 1)
            #expect(prematureDelivery == .init(claimedCount: 0, committedCount: 0, staleCount: 0, releasedCount: 0))
            #expect(resumed == .init(createdCompletionUnits: 2, createdDeliveries: 2, wasAlreadyPlanned: false))
            #expect(delivery == .init(claimedCount: 3, committedCount: 3, staleCount: 0, releasedCount: 0))
            #expect(try await count("im_v2.fanout_completion_units", on: sql) == 3)
            #expect(try await count("im_v2.fanout_deliveries", on: sql) == 3)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 3)
            #expect(try await count("im_v2.fanout_plans WHERE state = 'terminal'", on: sql) == 1)
            #expect(try await count("im_v2.room_outbox WHERE state = 'terminal'", on: sql) == 1)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("direct rooms enforce recipient setting and stranger quota transactionally")
    func enforcesStrangerDirectMessagePolicy() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let schemaExists = try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self)
            guard schemaExists?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_100_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 100, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 100, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3))
            let leaseID = UUID(uuidString: "00000000-0000-0000-0000-000000000071")!
            try await sql.raw("INSERT INTO im_v2.shard_admission_pools (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit, fanout_window_limit, max_outstanding_fanout_units, max_outstanding_plans) VALUES ('rooms-primary', 'standard', \(bind: leaseID), 1, \(bind: now.addingTimeInterval(600)), 100, 100, 100, 100)").run()
            let directStore = PostgresV2DirectMessagingStore(database: app.db(.psql))
            let directService = try V2DirectMessagingService(store: directStore, capacityProfile: profile, roomShardID: "rooms-primary", now: { now })
            let recipient = try UserID(memberTwoUUID.uuidString)
            let opened = try await directService.open(actorUserID: senderID, operationID: try .init("00000000-0000-0000-0000-000000000072"), targetUserID: recipient)
            guard case .opened(let room) = opened else { Issue.record("expected direct room"); return }
            let replay = try await directService.open(actorUserID: senderID, operationID: try .init("00000000-0000-0000-0000-000000000072"), targetUserID: recipient)
            guard case .idempotent(let replayed) = replay else { Issue.record("expected idempotent room"); return }
            #expect(replayed.roomID == room.roomID)

            _ = try await directService.setStrangerMessagePermission(actorUserID: recipient, operationID: try .init("00000000-0000-0000-0000-000000000073"), permission: .deny)
            let writer = PostgresV2RoomWriteStore(database: app.db(.psql), strangerMessagePolicy: try .init(maximumMessagesPerWindow: 3, window: 86_400))
            let messages = V2SendMessageService(store: writer, capacityProfile: profile, limits: try .init(maxUTF8Bytes: 64), now: { now })
            await #expect(throws: V2RoomWriteStoreError.strangerMessagePermissionDenied) {
                _ = try await messages.send(.init(roomID: room.roomID, actorUserID: senderID, clientMessageID: try .init("00000000-0000-0000-0000-000000000074"), text: "blocked-by-setting"))
            }

            _ = try await directService.setStrangerMessagePermission(actorUserID: recipient, operationID: try .init("00000000-0000-0000-0000-000000000075"), permission: .allow)
            let attempts = await withTaskGroup(of: StrangerMessageAttempt.self, returning: [StrangerMessageAttempt].self) { group in
                for suffix in 76...79 {
                    group.addTask {
                        do {
                            let result = try await messages.send(.init(roomID: room.roomID, actorUserID: senderID, clientMessageID: try .init("00000000-0000-0000-0000-0000000000\(suffix)"), text: "stranger"))
                            if case .accepted = result { return .accepted }
                            return .unexpectedOutcome
                        } catch V2RoomWriteStoreError.strangerMessageLimitReached {
                            return .limited
                        } catch {
                            return .unexpectedFailure
                        }
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            #expect(attempts.filter { $0 == .accepted }.count == 3)
            #expect(attempts.filter { $0 == .limited }.count == 1)
            #expect(!attempts.contains(.unexpectedOutcome))
            #expect(!attempts.contains(.unexpectedFailure))
            let reply = try await messages.send(.init(roomID: room.roomID, actorUserID: recipient, clientMessageID: try .init("00000000-0000-0000-0000-000000000080"), text: "reply"))
            guard case .accepted = reply else { Issue.record("expected reply"); return }
            let afterReply = try await messages.send(.init(roomID: room.roomID, actorUserID: senderID, clientMessageID: try .init("00000000-0000-0000-0000-000000000081"), text: "unlimited-after-reply"))
            guard case .accepted = afterReply else { Issue.record("expected post-reply message"); return }
            let window = try #require(try await sql.raw("SELECT message_count FROM im_v2.stranger_message_windows WHERE sender_user_id = \(bind: senderUUID) AND recipient_user_id = \(bind: memberTwoUUID)").first(decoding: StrangerWindowAssertionRow.self))
            #expect(window.messageCount == 3)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("group creation fans out only room identity to its frozen initial audience")
    func groupCreationDeliversRoomProfileAndRetainsItInSnapshot() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_300_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10,
                maxCommandsPerWindow: 10,
                maxFanoutUnitsPerWindow: 100,
                maxOutstandingFanoutUnits: 100,
                maxOutstandingPlans: 10,
                maxEnumerationPageSize: 10,
                maxPlannerConcurrency: 1,
                maxDeliveryConcurrency: 1,
                retryAfterSeconds: 3
            ))
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until,
                     command_window_limit, fanout_window_limit, max_outstanding_fanout_units, max_outstanding_plans)
                VALUES ('rooms-primary', 'standard', \(bind: leaseUUID), 1, \(bind: now.addingTimeInterval(600)), 10, 100, 100, 10)
                """).run()
            let invitedUser = try UserID(memberTwoUUID.uuidString)
            let group = try await V2GroupMessagingService(
                store: PostgresV2GroupMessagingStore(database: app.db(.psql)),
                capacityProfile: profile,
                roomShardID: "rooms-primary",
                now: { now }
            ).create(
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000082"),
                title: "  V2 项目群  ",
                initialMemberUserIDs: [invitedUser]
            )
            guard case .created(let created) = group else { Issue.record("expected created group"); return }

            let trigger = try #require(try await sql.raw("SELECT source_event_id, plan_id FROM im_v2.room_outbox").first(decoding: TriggerRow.self))
            let planning = try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: testUserShardRouter),
                pageSize: 1,
                now: { now.addingTimeInterval(1) }
            ).plan(.init(sourceEventID: try .init(trigger.sourceEventID.uuidString), planID: try .init(trigger.planID.uuidString)))
            let delivery = try await V2FanoutDeliveryWorker(
                store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)),
                now: { now.addingTimeInterval(2) }
            ).runOnce(limit: 8)
            let sync = V2SyncService(store: PostgresV2SyncStore(database: app.db(.psql)), now: { now.addingTimeInterval(3) })
            let pull = try await sync.pull(userID: invitedUser, deviceID: deviceID, syncToken: nil, requestedMaxRecords: 10)
            guard case .ready(_, let records, _, _, _) = pull,
                  let roomRecord = records.first(where: { $0.projectionKind == "room" })
            else { Issue.record("expected delivered room profile"); return }
            let payload = try #require(try JSONSerialization.jsonObject(with: Data(roomRecord.payloadJSON.utf8)) as? [String: Any])
            let snapshot = try await PostgresV2SnapshotProjectionMaterializer(database: app.db(.psql), pageItemLimit: 1)
                .materialize(userID: invitedUser, now: now.addingTimeInterval(4))
            let profiles = try snapshot.pages.flatMap { try V2SnapshotProjectionCodec.decodePage($0.payload).roomProfiles }

            #expect(created.title == "V2 项目群")
            #expect(planning == .init(createdCompletionUnits: 2, createdDeliveries: 2, wasAlreadyPlanned: false))
            #expect(delivery == .init(claimedCount: 2, committedCount: 2, staleCount: 0, releasedCount: 0))
            #expect(roomRecord.sourceEventID.rawValue == trigger.sourceEventID.uuidString)
            #expect(payload["event_type"] as? String == "room.created")
            #expect(payload["room_id"] as? String == created.roomID.rawValue)
            #expect(payload["title"] as? String == "V2 项目群")
            #expect(payload["member_user_ids"] == nil)
            #expect(profiles == [try .init(sourceEventID: roomRecord.sourceEventID, roomID: created.roomID, title: "V2 项目群", ownerUserID: senderID, membershipRevision: 1, createdAt: now)])

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
        }
    }

    /// This is a scale-shape regression, not a throughput benchmark. It
    /// verifies that a 100k immutable membership audience remains paged and
    /// creates exactly one completion unit and one deduplicated delivery per
    /// recipient. Capacity release still requires the separate load-report
    /// gate in docs/09-capacity/standard-100k.md.
    @Test("100,000-member fan-out planning remains page-bounded and exact")
    func plansOneHundredThousandMemberAudienceExactly() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let schemaExists = try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self)
            guard schemaExists?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)

            let room = UUID(uuidString: "00000000-0000-0000-0000-000000001001")!
            let event = UUID(uuidString: "00000000-0000-0000-0000-000000001002")!
            let plan = UUID(uuidString: "00000000-0000-0000-0000-000000001003")!
            let now = Date(timeIntervalSince1970: 1_750_200_000)
            try await sql.raw("""
                INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id, created_at)
                VALUES (\(bind: room), 'capacity-shape', 'standard', \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision)
                SELECT \(bind: room),
                       ('00000000-0000-0000-0000-' || lpad(to_hex(member), 12, '0'))::uuid,
                       0
                FROM generate_series(1, 100000) AS member
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
                VALUES
                    (\(bind: event), \(bind: room), 1, 'message.accepted', NULL, '{}'::jsonb, 0, \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.fanout_plans
                    (plan_id, source_event_id, room_id, source_room_sequence, committed_membership_revision,
                     target_rule, enumeration_checkpoint, target_count, reserved_fanout_cost, state, created_at)
                VALUES
                    (\(bind: plan), \(bind: event), \(bind: room), 1, 0,
                     '{"kind":"membership_at_revision"}'::jsonb, '{}'::jsonb, 100000, 100000, 'planning', \(bind: now))
                """).run()

            let result = try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: testUserShardRouter),
                pageSize: 1_000,
                now: { now }
            ).plan(.init(sourceEventID: try .init(event.uuidString), planID: try .init(plan.uuidString)))

            let accounting = try #require(try await sql.raw("""
                SELECT
                    (SELECT COUNT(*) FROM im_v2.fanout_completion_units WHERE source_event_id = \(bind: event)) AS completion_units,
                    (SELECT COALESCE(SUM(target_count), 0)::bigint FROM im_v2.fanout_completion_units WHERE source_event_id = \(bind: event)) AS completion_targets,
                    (SELECT COUNT(*) FROM im_v2.fanout_deliveries WHERE source_event_id = \(bind: event)) AS deliveries,
                    (SELECT COUNT(DISTINCT target_user_id) FROM im_v2.fanout_deliveries WHERE source_event_id = \(bind: event)) AS distinct_deliveries,
                    (SELECT state FROM im_v2.fanout_plans WHERE plan_id = \(bind: plan)) AS plan_state
                """).first(decoding: FanoutScaleAccountingRow.self))
            #expect(result == .init(createdCompletionUnits: 100, createdDeliveries: 100_000, wasAlreadyPlanned: false))
            #expect(accounting.completionUnits == 100)
            #expect(accounting.completionTargets == 100_000)
            #expect(accounting.deliveries == 100_000)
            #expect(accounting.distinctDeliveries == 100_000)
            #expect(accounting.planState == "planned")

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await app.asyncShutdown()
            throw error
        }
    }

    /// This deliberately remains opt-in: it writes 100k durable user-sync
    /// records one transaction at a time, which is valuable end-to-end
    /// correctness evidence but too expensive for each normal unit run. It is
    /// not a throughput benchmark; capacity release still needs the dated
    /// topology/workload report in `standard-100k.md`.
    @Test("opt-in 100,000-member fan-out drain preserves every durable projection and releases admission")
    func drainsOneHundredThousandMemberAudienceExactly() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1",
              Environment.get("IMV2_RUN_100K_DELIVERY_SOAK") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let room = UUID(uuidString: "00000000-0000-0000-0000-000000001101")!
            let event = UUID(uuidString: "00000000-0000-0000-0000-000000001102")!
            let plan = UUID(uuidString: "00000000-0000-0000-0000-000000001103")!
            let lease = UUID(uuidString: "00000000-0000-0000-0000-000000001104")!
            let now = Date(timeIntervalSince1970: 1_750_300_000)
            try await sql.raw("""
                INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id, created_at)
                VALUES (\(bind: room), 'capacity-delivery', 'standard', \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until,
                     command_window_limit, command_window_used, fanout_window_limit, fanout_window_used,
                     max_outstanding_fanout_units, outstanding_fanout_units,
                     max_outstanding_plans, outstanding_plans)
                VALUES
                    ('capacity-delivery', 'standard', \(bind: lease), 1, \(bind: now.addingTimeInterval(86_400)),
                     1, 1, 100000, 100000, 100000, 100000, 1, 1)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_admission
                    (room_id, eligible_member_count, command_window_limit, command_window_used,
                     fanout_window_limit, fanout_window_used, max_outstanding_fanout_units,
                     outstanding_fanout_units, max_outstanding_plans, outstanding_plans,
                     shard_lease_id, shard_lease_generation)
                VALUES
                    (\(bind: room), 100000, 1, 1, 100000, 100000, 100000, 100000, 1, 1,
                     \(bind: lease), 1)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision)
                SELECT \(bind: room),
                       ('00000000-0000-0000-0000-' || lpad(to_hex(member), 12, '0'))::uuid,
                       0
                FROM generate_series(1, 100000) AS member
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
                VALUES
                    (\(bind: event), \(bind: room), 1, 'message.accepted', NULL, '{}'::jsonb, 0, \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.fanout_plans
                    (plan_id, source_event_id, room_id, source_room_sequence, committed_membership_revision,
                     target_rule, enumeration_checkpoint, target_count, reserved_fanout_cost, state, created_at)
                VALUES
                    (\(bind: plan), \(bind: event), \(bind: room), 1, 0,
                     '{"kind":"membership_at_revision"}'::jsonb, '{}'::jsonb, 100000, 100000, 'planning', \(bind: now))
                """).run()

            let trigger = try V2FanoutPlanTrigger(sourceEventID: .init(event.uuidString), planID: .init(plan.uuidString))
            #expect(try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: testUserShardRouter),
                pageSize: 1_000,
                now: { now }
            ).plan(trigger) == .init(createdCompletionUnits: 100, createdDeliveries: 100_000, wasAlreadyPlanned: false))

            let deliveryWorker = V2FanoutDeliveryWorker(
                store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)),
                bucket: "test-users",
                router: testUserShardRouter,
                now: { now.addingTimeInterval(1) }
            )
            var delivered = 0
            for _ in 0..<100 {
                let report = try await deliveryWorker.runOnce(limit: 1_000)
                #expect(report == .init(claimedCount: 1_000, committedCount: 1_000, staleCount: 0, staleRouteCount: 0, releasedCount: 0))
                delivered += report.committedCount
            }
            #expect(delivered == 100_000)
            #expect(try await deliveryWorker.runOnce(limit: 1_000) == .init(claimedCount: 0, committedCount: 0, staleCount: 0, staleRouteCount: 0, releasedCount: 0))

            let accounting = try #require(try await sql.raw("""
                SELECT
                    (SELECT COUNT(*) FROM im_v2.user_sync_log WHERE source_event_id = \(bind: event)) AS sync_records,
                    (SELECT COUNT(DISTINCT user_id) FROM im_v2.user_sync_log WHERE source_event_id = \(bind: event)) AS distinct_sync_recipients,
                    (SELECT COUNT(*) FROM im_v2.consumer_inbox WHERE source_event_id = \(bind: event)) AS inbox_records,
                    (SELECT COUNT(*) FROM im_v2.fanout_deliveries WHERE source_event_id = \(bind: event) AND state = 'terminal') AS terminal_deliveries,
                    (SELECT COUNT(*) FROM im_v2.fanout_completion_units WHERE source_event_id = \(bind: event) AND state = 'released') AS released_completion_units,
                    (SELECT state FROM im_v2.fanout_plans WHERE plan_id = \(bind: plan)) AS plan_state
                """).first(decoding: FanoutDeliveryScaleAccountingRow.self))
            let roomReservation = try #require(try await sql.raw("""
                SELECT outstanding_fanout_units, outstanding_plans
                FROM im_v2.room_admission WHERE room_id = \(bind: room)
                """).first(decoding: OutstandingRow.self))
            let shardReservation = try #require(try await sql.raw("""
                SELECT outstanding_fanout_units, outstanding_plans
                FROM im_v2.shard_admission_pools
                WHERE room_shard_id = 'capacity-delivery' AND capacity_profile_id = 'standard'
                """).first(decoding: OutstandingRow.self))
            #expect(accounting.syncRecords == 100_000)
            #expect(accounting.distinctSyncRecipients == 100_000)
            #expect(accounting.inboxRecords == 100_000)
            #expect(accounting.terminalDeliveries == 100_000)
            #expect(accounting.releasedCompletionUnits == 100)
            #expect(accounting.planState == "terminal")
            #expect(roomReservation.outstandingFanoutUnits == 0)
            #expect(roomReservation.outstandingPlans == 0)
            #expect(shardReservation.outstandingFanoutUnits == 0)
            #expect(shardReservation.outstandingPlans == 0)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await app.asyncShutdown()
            throw error
        }
    }

    /// The 100k correctness gate also needs a recovery shape. Every completion
    /// unit is interrupted before its first target checkpoint, after one
    /// checkpoint, before its final terminal/release update, and after that
    /// terminal update. Replacement workers must resume only pending target
    /// effects, while completion-unit release still happens exactly once.
    /// This is opt-in because it performs the same 100k durable writes as the
    /// full drain gate.
    @Test("opt-in 100,000-member delivery recovers every completion unit after simulated worker loss")
    func recoversOneHundredThousandMemberAudienceAfterEveryCompletionUnitInterruption() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1",
              Environment.get("IMV2_RUN_100K_CRASH_RECOVERY_SOAK") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let room = UUID(uuidString: "00000000-0000-0000-0000-000000001201")!
            let event = UUID(uuidString: "00000000-0000-0000-0000-000000001202")!
            let plan = UUID(uuidString: "00000000-0000-0000-0000-000000001203")!
            let lease = UUID(uuidString: "00000000-0000-0000-0000-000000001204")!
            let now = Date(timeIntervalSince1970: 1_750_400_000)
            try await sql.raw("""
                INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id, created_at)
                VALUES (\(bind: room), 'capacity-recovery', 'standard', \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until,
                     command_window_limit, command_window_used, fanout_window_limit, fanout_window_used,
                     max_outstanding_fanout_units, outstanding_fanout_units,
                     max_outstanding_plans, outstanding_plans)
                VALUES
                    ('capacity-recovery', 'standard', \(bind: lease), 1, \(bind: now.addingTimeInterval(86_400)),
                     1, 1, 100000, 100000, 100000, 100000, 1, 1)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_admission
                    (room_id, eligible_member_count, command_window_limit, command_window_used,
                     fanout_window_limit, fanout_window_used, max_outstanding_fanout_units,
                     outstanding_fanout_units, max_outstanding_plans, outstanding_plans,
                     shard_lease_id, shard_lease_generation)
                VALUES
                    (\(bind: room), 100000, 1, 1, 100000, 100000, 100000, 100000, 1, 1,
                     \(bind: lease), 1)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision)
                SELECT \(bind: room),
                       ('00000000-0000-0000-0000-' || lpad(to_hex(member), 12, '0'))::uuid,
                       0
                FROM generate_series(1, 100000) AS member
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
                VALUES
                    (\(bind: event), \(bind: room), 1, 'message.accepted', NULL, '{}'::jsonb, 0, \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.fanout_plans
                    (plan_id, source_event_id, room_id, source_room_sequence, committed_membership_revision,
                     target_rule, enumeration_checkpoint, target_count, reserved_fanout_cost, state, created_at)
                VALUES
                    (\(bind: plan), \(bind: event), \(bind: room), 1, 0,
                     '{"kind":"membership_at_revision"}'::jsonb, '{}'::jsonb, 100000, 100000, 'planning', \(bind: now))
                """).run()

            let recoveryRouter = CompletionUnitRecoveryTestRouter()
            let trigger = try V2FanoutPlanTrigger(sourceEventID: .init(event.uuidString), planID: .init(plan.uuidString))
            #expect(try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: recoveryRouter),
                pageSize: 1_000,
                now: { now }
            ).plan(trigger) == .init(createdCompletionUnits: 100, createdDeliveries: 100_000, wasAlreadyPlanned: false))

            let deliveryStore = PostgresV2FanoutDeliveryStore(database: app.db(.psql))
            var durableDeliveries = 0
            for unitIndex in 0..<100 {
                let claimTime = now.addingTimeInterval(Double(unitIndex * 100))
                // 1. A worker loses its whole claimed batch before advancing
                // the first durable target checkpoint.
                let beforeCheckpointLeases = try await deliveryStore.claimPending(
                    bucket: "recovery-\(unitIndex)",
                    now: claimTime,
                    leaseDuration: 30,
                    limit: 1_000
                )
                #expect(beforeCheckpointLeases.count == 1_000)

                // 2. Its replacement commits one target, then loses the rest
                // after that durable checkpoint. The uncommitted leases are
                // left for expiry instead of explicitly released.
                let afterCheckpointLeases = try await deliveryStore.claimPending(
                    bucket: "recovery-\(unitIndex)",
                    now: claimTime.addingTimeInterval(31),
                    leaseDuration: 30,
                    limit: 1_000
                )
                #expect(afterCheckpointLeases.count == 1_000)
                guard case .committed(_, let releasedFirstUnit, let closedFirstPlan) = try await deliveryStore.commit(afterCheckpointLeases[0], now: claimTime.addingTimeInterval(32)) else {
                    Issue.record("expected the first checkpoint to commit")
                    return
                }
                #expect(!releasedFirstUnit)
                #expect(!closedFirstPlan)

                // 3. A later replacement progresses every remaining target
                // except the last one, then loses that final leased target
                // immediately before the unit's terminal/release update.
                let beforeTerminalLeases = try await deliveryStore.claimPending(
                    bucket: "recovery-\(unitIndex)",
                    now: claimTime.addingTimeInterval(62),
                    leaseDuration: 30,
                    limit: 1_000
                )
                #expect(beforeTerminalLeases.count == 999)
                for lease in beforeTerminalLeases.dropLast() {
                    guard case .committed(_, false, false) = try await deliveryStore.commit(lease, now: claimTime.addingTimeInterval(63)) else {
                        Issue.record("expected a nonterminal checkpoint before the final target")
                        return
                    }
                }

                // 4. The final replacement commits the one expired target,
                // performing the terminal unit release. A subsequent worker
                // represents a crash after that terminal update and must find
                // no duplicate work to claim.
                let recoveryWorker = V2FanoutDeliveryWorker(
                    store: deliveryStore,
                    bucket: "recovery-\(unitIndex)",
                    router: recoveryRouter,
                    now: { claimTime.addingTimeInterval(93) }
                )
                let recovery = try await recoveryWorker.runOnce(limit: 1_000)
                #expect(recovery == .init(
                    claimedCount: 1,
                    committedCount: 1,
                    staleCount: 0,
                    staleRouteCount: 0,
                    releasedCount: 0
                ))
                #expect(try await recoveryWorker.runOnce(limit: 1_000) == .init(
                    claimedCount: 0,
                    committedCount: 0,
                    staleCount: 0,
                    staleRouteCount: 0,
                    releasedCount: 0
                ))
                durableDeliveries += 1 + beforeTerminalLeases.dropLast().count + recovery.committedCount
            }
            #expect(durableDeliveries == 100_000)
            let accounting = try #require(try await sql.raw("""
                SELECT
                    (SELECT COUNT(*) FROM im_v2.user_sync_log WHERE source_event_id = \(bind: event)) AS sync_records,
                    (SELECT COUNT(DISTINCT user_id) FROM im_v2.user_sync_log WHERE source_event_id = \(bind: event)) AS distinct_sync_recipients,
                    (SELECT COUNT(*) FROM im_v2.consumer_inbox WHERE source_event_id = \(bind: event)) AS inbox_records,
                    (SELECT COUNT(*) FROM im_v2.fanout_deliveries WHERE source_event_id = \(bind: event) AND state = 'terminal') AS terminal_deliveries,
                    (SELECT COUNT(*) FROM im_v2.fanout_completion_units WHERE source_event_id = \(bind: event) AND state = 'released') AS released_completion_units,
                    (SELECT state FROM im_v2.fanout_plans WHERE plan_id = \(bind: plan)) AS plan_state
                """).first(decoding: FanoutDeliveryScaleAccountingRow.self))
            let roomReservation = try #require(try await sql.raw("""
                SELECT outstanding_fanout_units, outstanding_plans
                FROM im_v2.room_admission WHERE room_id = \(bind: room)
                """).first(decoding: OutstandingRow.self))
            let shardReservation = try #require(try await sql.raw("""
                SELECT outstanding_fanout_units, outstanding_plans
                FROM im_v2.shard_admission_pools
                WHERE room_shard_id = 'capacity-recovery' AND capacity_profile_id = 'standard'
                """).first(decoding: OutstandingRow.self))
            #expect(accounting.syncRecords == 100_000)
            #expect(accounting.distinctSyncRecipients == 100_000)
            #expect(accounting.inboxRecords == 100_000)
            #expect(accounting.terminalDeliveries == 100_000)
            #expect(accounting.releasedCompletionUnits == 100)
            #expect(accounting.planState == "terminal")
            #expect(roomReservation.outstandingFanoutUnits == 0)
            #expect(roomReservation.outstandingPlans == 0)
            #expect(shardReservation.outstandingFanoutUnits == 0)
            #expect(shardReservation.outstandingPlans == 0)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("relationship and block mutations are durable, private, and synchronize both sides")
    func relationshipAndBlockLifecycle() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_200_000)
            let sender = senderID
            let recipient = try UserID(memberTwoUUID.uuidString)
            let service = V2SocialRelationshipService(store: PostgresV2SocialRelationshipStore(database: app.db(.psql)), now: { now })
            let requestOperation = try RelationshipOperationID("00000000-0000-0000-0000-000000000091")

            let requested = try await service.changeRelationship(actorUserID: sender, operationID: requestOperation, targetUserID: recipient, action: .request)
            let replay = try await service.changeRelationship(actorUserID: sender, operationID: requestOperation, targetUserID: recipient, action: .request)
            let accepted = try await service.changeRelationship(actorUserID: recipient, operationID: try .init("00000000-0000-0000-0000-000000000092"), targetUserID: sender, action: .accept)
            let blocked = try await service.changeUserBlock(actorUserID: recipient, operationID: try .init("00000000-0000-0000-0000-000000000093"), targetUserID: sender, action: .block)
            let blockedRequest = try await service.changeRelationship(actorUserID: sender, operationID: try .init("00000000-0000-0000-0000-000000000094"), targetUserID: recipient, action: .request)
            let unblocked = try await service.changeUserBlock(actorUserID: recipient, operationID: try .init("00000000-0000-0000-0000-000000000095"), targetUserID: sender, action: .unblock)
            let requestedAgain = try await service.changeRelationship(actorUserID: sender, operationID: try .init("00000000-0000-0000-0000-000000000096"), targetUserID: recipient, action: .request)

            guard case .changed(let first) = requested, case .idempotent(let replayed) = replay,
                  case .changed(let acceptedChange) = accepted, case .changed(let blockedChange) = blocked,
                  case .changed(let unblockedChange) = unblocked, case .changed(let second) = requestedAgain
            else { Issue.record("expected durable social lifecycle outcomes"); return }
            #expect(first.resultingState == .pending)
            #expect(replayed == first)
            #expect(acceptedChange.resultingState == .accepted)
            #expect(blockedChange.isBlocked)
            #expect(blockedRequest == .forbidden)
            #expect(!unblockedChange.isBlocked)
            #expect(second.resultingState == .pending)
            let relation = try #require(try await sql.raw("SELECT state, requested_by_user_id FROM im_v2.user_relationships WHERE lower_user_id = \(bind: senderUUID) AND higher_user_id = \(bind: memberTwoUUID)").first(decoding: RelationshipAssertionRow.self))
            #expect(relation.state == "pending")
            #expect(relation.requestedByUserID == senderUUID)
            #expect(try await count("im_v2.user_relationship_operations", on: sql) == 3)
            #expect(try await count("im_v2.user_block_operations", on: sql) == 2)
            #expect(try await count("im_v2.user_blocks", on: sql) == 0)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 10)
            let targetHasNoBlockProjection = try #require(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE user_id = \(bind: senderUUID) AND projection_kind = 'user_block'").first(decoding: CountRow.self)).value
            #expect(targetHasNoBlockProjection == 0)

            // Snapshot reset obtains mutable social state from authority, not
            // from a device's possibly truncated incremental log.  Exercise
            // every social projection owned by the requesting user.
            let ownBlock = try await service.changeUserBlock(actorUserID: sender, operationID: try .init("00000000-0000-0000-0000-000000000097"), targetUserID: try .init(memberThreeUUID.uuidString), action: .block)
            let capacityProfile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3))
            let direct = try V2DirectMessagingService(store: PostgresV2DirectMessagingStore(database: app.db(.psql)), capacityProfile: capacityProfile, roomShardID: "room-a", now: { now })
            let preference = try await direct.setStrangerMessagePermission(actorUserID: sender, operationID: try .init("00000000-0000-0000-0000-000000000098"), permission: .deny)
            guard case .changed(let ownBlockChange) = ownBlock,
                  case .updated(let permissionValue, _) = preference
            else { Issue.record("expected authoritative social state"); return }

            let snapshot = try await PostgresV2SocialSnapshotMaterializer(database: app.db(.psql), pageItemLimit: 1).materialize(userID: sender, now: now)
            let decoded = try snapshot.pages.map { try V2SnapshotProjectionCodec.decodePage($0.payload) }
            let snapshotRelationships = decoded.flatMap(\.relationships)
            let snapshotBlocks = decoded.flatMap(\.userBlocks)
            let snapshotPreference = decoded.compactMap(\.strangerMessagePreference).first

            #expect(ownBlockChange.isBlocked)
            #expect(permissionValue == .deny)
            #expect(snapshot.baseSequence == 6)
            #expect(snapshot.pages.count == 2)
            #expect(snapshot.pages.allSatisfy { $0.digest.count == 64 })
            #expect(snapshotRelationships == [try .init(targetUserID: recipient, state: .pending, requestedByUserID: sender, updatedAt: now)])
            #expect(snapshotBlocks == [.init(targetUserID: try .init(memberThreeUUID.uuidString), isBlocked: true, updatedAt: now)])
            #expect(snapshotPreference == .init(allowsStrangerMessages: false, updatedAt: now))

            // Only the server-owned materializer may turn a complete
            // projection baseline into a device reset fence. The authenticated
            // client is never allowed to supply pages or a watermark.
            let resetSync = V2SyncService(store: PostgresV2SyncStore(database: app.db(.psql)), now: { now })
            let stager = V2ServerSnapshotResetStager(
                materializer: PostgresV2SnapshotProjectionMaterializer(database: app.db(.psql), pageItemLimit: 1),
                sync: resetSync,
                capabilityLifetime: 60,
                now: { now }
            )
            let stagedGeneration = try await stager.stageReset(userID: sender, deviceID: deviceID, capabilityProfile: "base")
            let stagedPull = try await resetSync.pull(userID: sender, deviceID: deviceID, syncToken: nil, requestedMaxRecords: 10)
            guard case .resetRequired(_, let returnedGeneration, let returnedBase, _, _) = stagedPull else {
                Issue.record("expected server-built reset"); return
            }
            #expect(stagedGeneration == 2)
            #expect(returnedGeneration == 2)
            #expect(returnedBase == snapshot.baseSequence)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("membership add atomically freezes its audience and replays after authorization changes")
    func membershipWriteUsesFrozenAudienceAndDurableIdempotency() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else {
            return
        }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let schemaExists = try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self)
            guard schemaExists?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").run()

            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let target = try UserID("00000000-0000-0000-0000-000000000025")
            let operation = try MembershipOperationID("00000000-0000-0000-0000-000000000026")
            let service = V2RoomMembershipService(
                store: PostgresV2RoomMembershipStore(database: app.db(.psql)),
                capacityProfile: try .init(id: "standard", limits: profile),
                identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000027")! }),
                now: { now }
            )
            let request = V2AuthenticatedMembershipChange(roomID: roomID, actorUserID: senderID, operationID: operation, targetUserID: target, action: .add, expectedMembershipRevision: 0)
            let first = try await service.change(request)
            guard case .changed(let change) = first else {
                Issue.record("expected an accepted membership change")
                return
            }

            // The replay must not re-evaluate current authorization. A lost
            // response can occur after the actor has itself left the room.
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision = 1 WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").run()
            let replay = try await service.change(request)

            let planning = try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: testUserShardRouter),
                pageSize: 2,
                now: { now.addingTimeInterval(1) }
            ).plan(.init(sourceEventID: change.eventID, planID: change.fanoutPlanID))
            let delivery = try await V2FanoutDeliveryWorker(
                store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)),
                now: { now.addingTimeInterval(2) }
            ).runOnce(limit: 8)

            let persisted = try #require(try await sql.raw("SELECT membership_revision, room_sequence FROM im_v2.rooms WHERE room_id = \(bind: roomUUID)").first(decoding: MembershipRevisionRow.self))
            let targetCount = try #require(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.fanout_plan_targets WHERE source_event_id = \(bind: UUID(uuidString: change.eventID.rawValue)!)").first(decoding: CountRow.self)).value
            let targetMembership = try #require(try await sql.raw("SELECT role, joined_revision FROM im_v2.room_memberships WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: UUID(uuidString: target.rawValue)!)").first(decoding: MembershipTargetStateRow.self))
            let addedMemberSnapshot = try await PostgresV2SnapshotProjectionMaterializer(database: app.db(.psql), pageItemLimit: 10)
                .materialize(userID: target, now: now.addingTimeInterval(3))
            let addedMemberProfiles = try addedMemberSnapshot.pages.flatMap { try V2SnapshotProjectionCodec.decodePage($0.payload).roomProfiles }

            #expect(replay == .idempotent(change))
            #expect(persisted.membershipRevision == 1)
            #expect(persisted.roomSequence == 1)
            #expect(targetMembership.role == "member")
            #expect(targetMembership.joinedRevision == 1)
            #expect(targetCount == 4) // original 3 members plus the added user
            #expect(planning == .init(createdCompletionUnits: 2, createdDeliveries: 4, wasAlreadyPlanned: false))
            #expect(delivery == .init(claimedCount: 4, committedCount: 4, staleCount: 0, releasedCount: 0))
            #expect(try await count("im_v2.room_membership_operations", on: sql) == 1)
            #expect(try await count("im_v2.room_events", on: sql) == 1)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 4)
            #expect(addedMemberProfiles == [try .init(sourceEventID: change.eventID, roomID: roomID, title: "集成测试群", ownerUserID: senderID, membershipRevision: 1, createdAt: now)])

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("an admin can remove a non-owner through the durable membership path")
    func adminMayRemoveMember() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let schemaExists = try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self)
            guard schemaExists?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'admin' WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: memberThreeUUID)").run()

            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let target = try UserID(memberTwoUUID.uuidString)
            let operation = try MembershipOperationID("00000000-0000-0000-0000-000000000028")
            let service = V2RoomMembershipService(
                store: PostgresV2RoomMembershipStore(database: app.db(.psql)),
                capacityProfile: try .init(id: "standard", limits: profile),
                identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000029")! }),
                now: { now }
            )
            let request = V2AuthenticatedMembershipChange(roomID: roomID, actorUserID: senderID, operationID: operation, targetUserID: target, action: .remove, expectedMembershipRevision: 0)
            let first = try await service.change(request)
            guard case .changed(let change) = first else { Issue.record("expected admin removal"); return }
            let replay = try await service.change(request)
            let membership = try #require(try await sql.raw("SELECT left_revision FROM im_v2.room_memberships WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: UUID(uuidString: target.rawValue)!)").first(decoding: LeftRevisionRow.self))
            let auditMembershipEvent = try #require(try await sql.raw("SELECT event_type, payload->>'action' AS action FROM im_v2.room_events WHERE event_id = \(bind: UUID(uuidString: change.eventID.rawValue)!)").first(decoding: MembershipEventRow.self))

            #expect(replay == .idempotent(change))
            #expect(change.membershipRevision == 1)
            #expect(membership.leftRevision == 1)
            #expect(auditMembershipEvent.eventType == "membership_changed")
            #expect(auditMembershipEvent.action == "remove")
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("message withdrawal atomically writes a tombstone fanout plan and durable replay result")
    func withdrawalWritesTombstoneTransaction() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)
            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: app.db(.psql)), capacityProfile: try .init(id: "standard", limits: profile), limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let accepted) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "withdraw me")) else { Issue.record("expected accepted message"); return }
            let operation = try MessageWithdrawalOperationID("00000000-0000-0000-0000-000000000028")
            let withdrawal = V2MessageWithdrawalService(store: PostgresV2MessageWithdrawalStore(database: app.db(.psql)), capacityProfile: try .init(id: "standard", limits: profile), identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000029")! }), now: { now.addingTimeInterval(1) })
            let request = V2AuthenticatedMessageWithdrawal(roomID: roomID, actorUserID: senderID, operationID: operation, messageID: accepted.messageID, expectedMessageRevision: 1)
            let first = try await withdrawal.withdraw(request)
            guard case .withdrawn(let result) = first else { Issue.record("expected withdrawn result"); return }
            let replay = try await withdrawal.withdraw(request)
            let tombstone = try #require(try await sql.raw("SELECT content_revision, withdrawn_by_user_id FROM im_v2.messages WHERE message_id = \(bind: UUID(uuidString: accepted.messageID.rawValue)!)").first(decoding: WithdrawalMessageStateRow.self))
            let event = try #require(try await sql.raw("SELECT event_type, payload->>'message_id' AS message_id, payload->>'is_withdrawn' AS withdrawn FROM im_v2.room_events WHERE event_id = \(bind: UUID(uuidString: result.eventID.rawValue)!)").first(decoding: WithdrawalEventRow.self))
            #expect(replay == .idempotent(result))
            #expect(tombstone.contentRevision == 2)
            #expect(tombstone.withdrawnByUserID == senderUUID)
            #expect(event.eventType == "message.withdrawn")
            #expect(event.messageID == accepted.messageID.rawValue)
            #expect(event.withdrawn == "true")
            #expect(try await count("im_v2.message_withdrawal_operations", on: sql) == 1)
            #expect(try await count("im_v2.room_outbox", on: sql) == 2)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("message reaction atomically persists its set change, fanout plan, and replay result")
    func reactionWritesSetChangeAndDeliversIt() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)

            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: app.db(.psql)), capacityProfile: try .init(id: "standard", limits: profile), limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "react to me")) else { Issue.record("expected accepted message"); return }
            let acceptedTrigger = try #require(try await sql.raw("SELECT source_event_id, plan_id FROM im_v2.room_outbox ORDER BY created_at LIMIT 1").first(decoding: TriggerRow.self))
            let acceptedPlanning = try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: testUserShardRouter),
                pageSize: 2,
                now: { now.addingTimeInterval(0.5) }
            ).plan(.init(sourceEventID: try .init(acceptedTrigger.sourceEventID.uuidString), planID: try .init(acceptedTrigger.planID.uuidString)))
            let acceptedDelivery = try await V2FanoutDeliveryWorker(
                store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)),
                now: { now.addingTimeInterval(0.75) }
            ).runOnce(limit: 8)

            let reaction = V2MessageReactionService(
                store: PostgresV2MessageReactionStore(database: app.db(.psql)),
                capacityProfile: try .init(id: "standard", limits: profile),
                identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000031")! }),
                now: { now.addingTimeInterval(1) }
            )
            let request = V2AuthenticatedMessageReaction(
                roomID: roomID,
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000030"),
                messageID: message.messageID,
                reaction: "👍",
                action: .add
            )
            let first = try await reaction.change(request)
            guard case .changed(let change) = first else { Issue.record("expected reaction change"); return }
            let replay = try await reaction.change(request)

            let planning = try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: testUserShardRouter),
                pageSize: 2,
                now: { now.addingTimeInterval(2) }
            ).plan(.init(sourceEventID: change.eventID, planID: change.fanoutPlanID))
            let delivery = try await V2FanoutDeliveryWorker(
                store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)),
                now: { now.addingTimeInterval(3) }
            ).runOnce(limit: 8)

            let reactionState = try #require(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.message_reactions WHERE message_id = \(bind: UUID(uuidString: message.messageID.rawValue)!) AND actor_user_id = \(bind: senderUUID) AND reaction = '👍'").first(decoding: CountRow.self))
            let event = try #require(try await sql.raw("SELECT event_type, payload->>'message_id' AS message_id, payload->>'reaction' AS reaction, payload->>'action' AS action FROM im_v2.room_events WHERE event_id = \(bind: UUID(uuidString: change.eventID.rawValue)!)").first(decoding: ReactionEventRow.self))
            let delivered = try #require(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE source_event_id = \(bind: UUID(uuidString: change.eventID.rawValue)!)").first(decoding: CountRow.self))
            let snapshot = try await PostgresV2SnapshotProjectionMaterializer(database: app.db(.psql), pageItemLimit: 1).materialize(userID: senderID, now: now.addingTimeInterval(4))
            let snapshotMessages = try snapshot.pages.flatMap { try V2SnapshotProjectionCodec.decodePage($0.payload).messages }

            #expect(replay == .idempotent(change))
            #expect(change.roomSequence == 2)
            #expect(reactionState.value == 1)
            #expect(event.eventType == "message.reaction_changed")
            #expect(event.messageID == message.messageID.rawValue)
            #expect(event.reaction == "👍")
            #expect(event.action == "add")
            #expect(acceptedPlanning == .init(createdCompletionUnits: 2, createdDeliveries: 3, wasAlreadyPlanned: false))
            #expect(acceptedDelivery == .init(claimedCount: 3, committedCount: 3, staleCount: 0, releasedCount: 0))
            #expect(planning == .init(createdCompletionUnits: 2, createdDeliveries: 3, wasAlreadyPlanned: false))
            #expect(delivery == .init(claimedCount: 3, committedCount: 3, staleCount: 0, releasedCount: 0))
            #expect(delivered.value == 3)
            #expect(snapshotMessages == [try .init(sourceEventID: .init(acceptedTrigger.sourceEventID.uuidString), messageID: message.messageID, roomID: roomID, roomSequence: 1, senderUserID: senderID, text: "react to me", createdAt: now, reactions: [try .init(actorUserID: senderID, reaction: "👍")])])
            #expect(try await count("im_v2.message_reaction_operations", on: sql) == 1)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("message edit atomically updates content, fans out, and replays its canonical result")
    func editWritesRevisionFencedTransaction() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)
            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: app.db(.psql)), capacityProfile: try .init(id: "standard", limits: profile), limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "before")) else { Issue.record("expected accepted message"); return }
            let edit = V2MessageEditService(store: PostgresV2MessageEditStore(database: app.db(.psql)), capacityProfile: try .init(id: "standard", limits: profile), maximumTextUTF8Bytes: 64, identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000033")! }), now: { now.addingTimeInterval(1) })
            let request = V2AuthenticatedMessageEdit(roomID: roomID, actorUserID: senderID, operationID: try .init("00000000-0000-0000-0000-000000000032"), messageID: message.messageID, expectedMessageRevision: 1, text: "after")
            let first = try await edit.edit(request)
            guard case .edited(let result) = first else { Issue.record("expected edit result"); return }
            let replay = try await edit.edit(request)
            let planning = try await V2FanoutPlanner(store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: testUserShardRouter), pageSize: 2, now: { now.addingTimeInterval(2) }).plan(.init(sourceEventID: result.eventID, planID: result.fanoutPlanID))
            let delivery = try await V2FanoutDeliveryWorker(store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)), now: { now.addingTimeInterval(3) }).runOnce(limit: 8)
            let persisted = try #require(try await sql.raw("SELECT text_body, content_revision FROM im_v2.messages WHERE message_id = \(bind: UUID(uuidString: message.messageID.rawValue)!)").first(decoding: EditMessageStateRow.self))
            let event = try #require(try await sql.raw("SELECT event_type, payload->>'text' AS text, payload->>'message_revision' AS revision FROM im_v2.room_events WHERE event_id = \(bind: UUID(uuidString: result.eventID.rawValue)!)").first(decoding: EditEventRow.self))
            let delivered = try #require(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE source_event_id = \(bind: UUID(uuidString: result.eventID.rawValue)!)").first(decoding: CountRow.self))
            #expect(replay == .idempotent(result))
            #expect(result.messageRevision == 2)
            #expect(result.roomSequence == 2)
            #expect(persisted.text == "after")
            #expect(persisted.revision == 2)
            #expect(event.eventType == "message.edited")
            #expect(event.text == "after")
            #expect(event.revision == "2")
            #expect(planning == .init(createdCompletionUnits: 2, createdDeliveries: 3, wasAlreadyPlanned: false))
            #expect(delivery == .init(claimedCount: 3, committedCount: 3, staleCount: 0, releasedCount: 0))
            #expect(delivered.value == 3)
            #expect(try await count("im_v2.message_edit_operations", on: sql) == 1)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("a tombstone rejects an older edit without creating replacement delivery work")
    func withdrawalWinsOverOlderEdit() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)

            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let capacityProfile = try V2CapacityProfile(id: "standard", limits: profile)
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: app.db(.psql)), capacityProfile: capacityProfile, limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "before withdrawal")) else { Issue.record("expected accepted message"); return }

            let withdrawal = V2MessageWithdrawalService(
                store: PostgresV2MessageWithdrawalStore(database: app.db(.psql)),
                capacityProfile: capacityProfile,
                identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000036")! }),
                now: { now.addingTimeInterval(1) }
            )
            let withdrawalRequest = V2AuthenticatedMessageWithdrawal(
                roomID: roomID,
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000035"),
                messageID: message.messageID,
                expectedMessageRevision: 1
            )
            guard case .withdrawn = try await withdrawal.withdraw(withdrawalRequest) else { Issue.record("expected withdrawal"); return }

            let edit = V2MessageEditService(
                store: PostgresV2MessageEditStore(database: app.db(.psql)),
                capacityProfile: capacityProfile,
                maximumTextUTF8Bytes: 64,
                identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000038")! }),
                now: { now.addingTimeInterval(2) }
            )
            let olderEdit = try await edit.edit(.init(
                roomID: roomID,
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000037"),
                messageID: message.messageID,
                expectedMessageRevision: 1,
                text: "must not replace tombstone"
            ))
            let persisted = try #require(try await sql.raw("SELECT text_body, content_revision, withdrawn_at IS NOT NULL AS is_withdrawn FROM im_v2.messages WHERE message_id = \(bind: UUID(uuidString: message.messageID.rawValue)!)").first(decoding: TombstonedEditStateRow.self))

            #expect(olderEdit == .alreadyWithdrawn)
            #expect(persisted.text == "before withdrawal")
            #expect(persisted.revision == 2)
            #expect(persisted.isWithdrawn)
            #expect(try await count("im_v2.message_edit_operations", on: sql) == 0)
            #expect(try await count("im_v2.room_events", on: sql) == 2)
            #expect(try await count("im_v2.fanout_plans", on: sql) == 2)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("concurrent edit and withdrawal commit exactly one terminal message mutation")
    func concurrentEditAndWithdrawalDoNotCreateConflictingHistory() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)

            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let capacityProfile = try V2CapacityProfile(id: "standard", limits: profile)
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: app.db(.psql)), capacityProfile: capacityProfile, limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "original")) else { Issue.record("expected accepted message"); return }

            let edit = V2MessageEditService(
                store: PostgresV2MessageEditStore(database: app.db(.psql)),
                capacityProfile: capacityProfile,
                maximumTextUTF8Bytes: 64,
                identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000040")! }),
                now: { now.addingTimeInterval(1) }
            )
            let editRequest = V2AuthenticatedMessageEdit(
                roomID: roomID,
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000039"),
                messageID: message.messageID,
                expectedMessageRevision: 1,
                text: "edited"
            )
            let withdrawal = V2MessageWithdrawalService(
                store: PostgresV2MessageWithdrawalStore(database: app.db(.psql)),
                capacityProfile: capacityProfile,
                identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000042")! }),
                now: { now.addingTimeInterval(1) }
            )
            let withdrawalRequest = V2AuthenticatedMessageWithdrawal(
                roomID: roomID,
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000041"),
                messageID: message.messageID,
                expectedMessageRevision: 1
            )

            let outcomes = await withTaskGroup(of: MessageMutationRaceOutcome.self, returning: [MessageMutationRaceOutcome].self) { group in
                group.addTask {
                    do {
                        switch try await edit.edit(editRequest) {
                        case .edited: return .edited
                        case .alreadyWithdrawn: return .alreadyWithdrawn
                        case .revisionConflict: return .revisionConflict
                        default: return .unexpectedOutcome
                        }
                    } catch { return .unexpectedFailure }
                }
                group.addTask {
                    do {
                        switch try await withdrawal.withdraw(withdrawalRequest) {
                        case .withdrawn: return .withdrawn
                        case .alreadyWithdrawn: return .alreadyWithdrawn
                        case .revisionConflict: return .revisionConflict
                        default: return .unexpectedOutcome
                        }
                    } catch { return .unexpectedFailure }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            let state = try #require(try await sql.raw("SELECT text_body, content_revision, withdrawn_at IS NOT NULL AS is_withdrawn FROM im_v2.messages WHERE message_id = \(bind: UUID(uuidString: message.messageID.rawValue)!)").first(decoding: TombstonedEditStateRow.self))

            let editWins = outcomes.filter { $0 == .edited }.count == 1 && outcomes.filter { $0 == .revisionConflict }.count == 1
            let withdrawalWins = outcomes.filter { $0 == .withdrawn }.count == 1 && outcomes.filter { $0 == .alreadyWithdrawn }.count == 1
            #expect(editWins || withdrawalWins)
            #expect(!outcomes.contains(.unexpectedOutcome))
            #expect(!outcomes.contains(.unexpectedFailure))
            #expect(state.revision == 2)
            #expect(editWins ? state.text == "edited" && !state.isWithdrawn : state.text == "original" && state.isWithdrawn)
            #expect(try await count("im_v2.message_edit_operations", on: sql) + count("im_v2.message_withdrawal_operations", on: sql) == 1)
            #expect(try await count("im_v2.room_events", on: sql) == 2)
            #expect(try await count("im_v2.fanout_plans", on: sql) == 2)
            #expect(try await count("im_v2.room_outbox", on: sql) == 2)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("read receipt is monotonic user state and never creates delivery work")
    func readReceiptDoesNotBecomeASyncAcknowledgement() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)
            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: app.db(.psql)), capacityProfile: try .init(id: "standard", limits: profile), limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "read me")) else { Issue.record("expected accepted message"); return }
            let receipt = V2ReadReceiptService(store: PostgresV2ReadReceiptStore(database: app.db(.psql)), now: { now.addingTimeInterval(1) })
            let request = V2AuthenticatedReadReceipt(roomID: roomID, actorUserID: senderID, operationID: try .init("00000000-0000-0000-0000-000000000034"), readThroughRoomSequence: message.roomSequence)
            let first = try await receipt.record(request)
            guard case .recorded(let result) = first else { Issue.record("expected receipt"); return }
            let replay = try await receipt.record(request)
            let state = try #require(try await sql.raw("SELECT read_through_room_sequence FROM im_v2.room_read_receipts WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").first(decoding: ReceiptStateAssertionRow.self))
            #expect(replay == .idempotent(result))
            #expect(state.sequence == 1)
            #expect(try await count("im_v2.read_receipt_operations", on: sql) == 1)
            #expect(try await count("im_v2.room_events", on: sql) == 1)
            #expect(try await count("im_v2.fanout_plans", on: sql) == 1)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 0)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("available owner media is referenced atomically and unavailable media cannot create a message")
    func persistsAuthorizedMediaReferencesWithMessageAcceptance() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let uploadLimits = try V2MediaUploadLimits(maximumBytes: 1_000_000)
            let availableID = try MediaID("00000000-0000-0000-0000-000000000090")
            let unavailableID = try MediaID("00000000-0000-0000-0000-000000000091")
            let mentionedUser = try UserID(memberTwoUUID.uuidString)
            let mediaStore = PostgresV2MediaStore(database: app.db(.psql))
            try await sql.raw("""
                INSERT INTO im_v2.auth_devices (user_id, device_id, created_at)
                VALUES (\(bind: senderUUID), \(bind: UUID(uuidString: deviceID.rawValue)!), \(bind: now))
                """).run()
            _ = try await mediaStore.requestUpload(
                .init(actorUserID: senderID, operationID: try .init("00000000-0000-0000-0000-000000000093"), mediaID: availableID, contentType: "image/png", byteCount: 42, limits: uploadLimits),
                deviceID: deviceID,
                expiresAt: now.addingTimeInterval(600),
                now: now
            )
            try await sql.raw("UPDATE im_v2.media_upload_grants SET state = 'consumed', redeemed_at = \(bind: now) WHERE media_id = \(bind: UUID(uuidString: availableID.rawValue)!)").run()
            try await mediaStore.markUploadCompleted(ownerUserID: senderID, deviceID: deviceID, mediaID: availableID, now: now.addingTimeInterval(1))
            #expect(try await mediaStore.uploadStatus(ownerUserID: senderID, deviceID: deviceID, mediaID: availableID, now: now.addingTimeInterval(1)) == .scanning)
            let scanStore = PostgresV2MediaScanStore(database: app.db(.psql), makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000092")! })
            let scanLease = try #require(try await scanStore.claimPending(now: now.addingTimeInterval(2), leaseDuration: 10, limit: 1).first)
            #expect(scanLease.mediaID == availableID)
            try await scanStore.complete(scanLease, result: .passed, now: now.addingTimeInterval(2))
            let completedScan = try #require(try await sql.raw("SELECT state FROM im_v2.media_scan_outbox WHERE media_id = \(bind: UUID(uuidString: availableID.rawValue)!)").first(decoding: PushStateRow.self))
            #expect(completedScan.state == "completed")
            #expect(try await mediaStore.uploadStatus(ownerUserID: senderID, deviceID: deviceID, mediaID: availableID, now: now.addingTimeInterval(2)) == .available)
            _ = try await mediaStore.requestUpload(
                .init(actorUserID: senderID, operationID: try .init("00000000-0000-0000-0000-000000000094"), mediaID: unavailableID, contentType: "image/png", byteCount: 42, limits: uploadLimits),
                deviceID: deviceID,
                expiresAt: now.addingTimeInterval(600),
                now: now
            )

            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3))
            let service = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: app.db(.psql)),
                capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64),
                idFactory: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000095")! }),
                now: { now.addingTimeInterval(3) }
            )
            let accepted = try await service.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "", media: [.init(mediaID: availableID)], mentions: [.user(mentionedUser)]))
            guard case .accepted(let message) = accepted else { Issue.record("expected media message acceptance"); return }
            let persistedReference = try #require(try await sql.raw("SELECT message_id, media_id, ordinal FROM im_v2.message_media_references").first(decoding: MediaReferenceAssertionRow.self))
            let mention = try #require(try await sql.raw("SELECT mentioned_user_id FROM im_v2.message_mentions WHERE message_id = \(bind: UUID(uuidString: message.messageID.rawValue)!)").first(decoding: MentionAssertionRow.self))
            let event = try #require(try await sql.raw("SELECT payload @> jsonb_build_object('media_ids', jsonb_build_array(\(bind: availableID.rawValue)) ) AS contains FROM im_v2.room_events WHERE event_id = \(bind: UUID(uuidString: "00000000-0000-0000-0000-000000000095")!)").first(decoding: MediaEventContainsRow.self))
            #expect(persistedReference.messageID.uuidString == message.messageID.rawValue)
            #expect(persistedReference.mediaID.uuidString == availableID.rawValue)
            #expect(persistedReference.ordinal == 0)
            #expect(event.contains)
            #expect(mention.userID.uuidString == mentionedUser.rawValue)

            // Download authorization is based on a delivered message, rather
            // than on a caller knowing an opaque media ID. Seed the device at
            // the same identity boundary the media edge will authenticate.
            try await sql.raw("""
                INSERT INTO im_v2.auth_devices (user_id, device_id, created_at)
                VALUES (\(bind: senderUUID), \(bind: UUID(uuidString: deviceID.rawValue)!), \(bind: now))
                ON CONFLICT (user_id, device_id) DO NOTHING
                """).run()
            let acceptedTrigger = try #require(try await sql.raw("SELECT source_event_id, plan_id FROM im_v2.room_outbox WHERE source_event_id = \(bind: UUID(uuidString: "00000000-0000-0000-0000-000000000095")!)").first(decoding: TriggerRow.self))
            _ = try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: testUserShardRouter),
                pageSize: 2,
                now: { now.addingTimeInterval(4) }
            ).plan(.init(sourceEventID: try .init(acceptedTrigger.sourceEventID.uuidString), planID: try .init(acceptedTrigger.planID.uuidString)))
            _ = try await V2FanoutDeliveryWorker(
                store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)),
                now: { now.addingTimeInterval(5) }
            ).runOnce(limit: 8)
            let download = try await mediaStore.requestDownload(
                requesterUserID: senderID,
                deviceID: deviceID,
                mediaID: availableID,
                expiresAt: now.addingTimeInterval(60),
                now: now.addingTimeInterval(6)
            )
            #expect(download.mediaID == availableID)
            #expect(download.expiresAt == now.addingTimeInterval(60))
            let downloadSessions = PostgresV2MediaDownloadSessionStore(database: app.db(.psql))
            let claimedDownload = try await downloadSessions.claimDownload(
                requesterUserID: senderID,
                deviceID: deviceID,
                downloadSessionID: download.downloadSessionID,
                now: now.addingTimeInterval(6),
                leaseDuration: 10
            )
            try await downloadSessions.completeDownload(claimedDownload, now: now.addingTimeInterval(7))
            let consumedGrant = try #require(try await sql.raw("SELECT state FROM im_v2.media_download_grants WHERE download_session_id = \(bind: UUID(uuidString: download.downloadSessionID.rawValue)!)").first(decoding: PushStateRow.self))
            #expect(consumedGrant.state == "consumed")
            await #expect(throws: V2MediaDownloadSessionStoreError.sessionUnavailable) {
                _ = try await downloadSessions.claimDownload(requesterUserID: senderID, deviceID: deviceID, downloadSessionID: download.downloadSessionID, now: now.addingTimeInterval(8), leaseDuration: 10)
            }
            let unexchangedDownload = try await mediaStore.requestDownload(
                requesterUserID: senderID,
                deviceID: deviceID,
                mediaID: availableID,
                expiresAt: now.addingTimeInterval(60),
                now: now.addingTimeInterval(8)
            )

            await #expect(throws: V2MediaStoreError.mediaUnavailable) {
                _ = try await service.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: try .init("00000000-0000-0000-0000-000000000096"), text: "", media: [.init(mediaID: unavailableID)]))
            }

            // A newly-issued grant must fail after a withdrawal even though a
            // previously handed-off provider target may naturally expire.
            try await sql.raw("UPDATE im_v2.messages SET withdrawn_at = \(bind: now.addingTimeInterval(7)), withdrawn_by_user_id = \(bind: senderUUID) WHERE message_id = \(bind: UUID(uuidString: message.messageID.rawValue)!)").run()
            await #expect(throws: V2MediaStoreError.downloadNotAuthorized) {
                _ = try await mediaStore.requestDownload(requesterUserID: senderID, deviceID: deviceID, mediaID: availableID, expiresAt: now.addingTimeInterval(60), now: now.addingTimeInterval(9))
            }
            await #expect(throws: V2MediaDownloadSessionStoreError.sessionUnavailable) {
                _ = try await downloadSessions.claimDownload(requesterUserID: senderID, deviceID: deviceID, downloadSessionID: unexchangedDownload.downloadSessionID, now: now.addingTimeInterval(9), leaseDuration: 10)
            }
            try await sql.raw("UPDATE im_v2.messages SET withdrawn_at = NULL, withdrawn_by_user_id = NULL WHERE message_id = \(bind: UUID(uuidString: message.messageID.rawValue)!)").run()

            // Removal has the same effect for subsequent grants, while the
            // row above remains a bounded record of the already-issued grant.
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 1 WHERE room_id = \(bind: roomUUID)").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision = 1 WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID) AND joined_revision = 0").run()
            await #expect(throws: V2MediaStoreError.downloadNotAuthorized) {
                _ = try await mediaStore.requestDownload(requesterUserID: senderID, deviceID: deviceID, mediaID: availableID, expiresAt: now.addingTimeInterval(60), now: now.addingTimeInterval(10))
            }
            #expect(try await count("im_v2.media_download_grants", on: sql) == 2)

            // Retention changes metadata to a terminal state and emits a
            // provider-owned cleanup task; it does not destroy message or
            // audit history in the chat transaction.
            try await sql.raw("UPDATE im_v2.messages SET withdrawn_at = \(bind: now.addingTimeInterval(-31 * 86_400)), withdrawn_by_user_id = \(bind: senderUUID) WHERE message_id = \(bind: UUID(uuidString: message.messageID.rawValue)!)").run()
            let retention = try V2MediaRetentionWorker(
                store: PostgresV2MediaRetentionStore(database: app.db(.psql)),
                now: { now }
            )
            #expect(try await retention.runOnce(limit: 1) == 1)
            #expect(try await retention.runOnce(limit: 1) == 0)
            let retainedState = try #require(try await sql.raw("SELECT state FROM im_v2.media_objects WHERE media_id = \(bind: UUID(uuidString: availableID.rawValue)!)").first(decoding: PushStateRow.self))
            #expect(retainedState.state == "expired")
            #expect(try await count("im_v2.media_purge_outbox", on: sql) == 1)
            let purgeStore = PostgresV2MediaPurgeStore(database: app.db(.psql), makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000097")! })
            let purgeLease = try #require(try await purgeStore.claimPending(now: now, leaseDuration: 10, limit: 1).first)
            #expect(purgeLease.mediaID == availableID)
            #expect(purgeLease.reason == .withdrawnRetentionElapsed)
            try await purgeStore.markCompleted(purgeLease, now: now.addingTimeInterval(1))
            let completedPurge = try #require(try await sql.raw("SELECT state FROM im_v2.media_purge_outbox WHERE media_id = \(bind: UUID(uuidString: availableID.rawValue)!)").first(decoding: PushStateRow.self))
            #expect(completedPurge.state == "completed")
            #expect(try await count("im_v2.messages", on: sql) == 1)
            #expect(try await count("im_v2.message_media_references", on: sql) == 1)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("moderator redaction atomically tombstones, audits, fans out, and replays")
    func moderatorRedactionIsDurableAndExplicit() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3))
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: app.db(.psql)), capacityProfile: profile, limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "requires moderation")) else { Issue.record("expected accepted message"); return }
            let acceptedTrigger = try #require(try await sql.raw("SELECT source_event_id, plan_id FROM im_v2.room_outbox ORDER BY created_at LIMIT 1").first(decoding: TriggerRow.self))
            _ = try await V2FanoutPlanner(store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: testUserShardRouter), pageSize: 2, now: { now.addingTimeInterval(0.25) }).plan(.init(sourceEventID: try .init(acceptedTrigger.sourceEventID.uuidString), planID: try .init(acceptedTrigger.planID.uuidString)))
            _ = try await V2FanoutDeliveryWorker(store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)), now: { now.addingTimeInterval(0.5) }).runOnce(limit: 8)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID) AND joined_revision = 0").run()
            let command = try V2ModerationCommand(roomID: roomID, actorUserID: senderID, operationID: .init("00000000-0000-0000-0000-000000000097"), action: .redactMessage, messageID: message.messageID, reasonCode: .init("abuse_spam"))
            let store = PostgresV2ModerationStore(database: app.db(.psql))
            let first = try await store.apply(command: command, capacityProfile: profile, eventID: .init("00000000-0000-0000-0000-000000000098"), planID: .init("00000000-0000-0000-0000-000000000099"), now: now.addingTimeInterval(1))
            guard case .applied(let result) = first else { Issue.record("expected moderation result"); return }
            let replay = try await store.apply(command: command, capacityProfile: profile, eventID: .init("00000000-0000-0000-0000-000000000100"), planID: .init("00000000-0000-0000-0000-000000000101"), now: now.addingTimeInterval(2))
            let event = try #require(try await sql.raw("SELECT event_type, payload->>'message_id' AS message_id FROM im_v2.room_events WHERE event_id = \(bind: UUID(uuidString: result.eventID.rawValue)!)").first(decoding: ModerationEventAssertionRow.self))
            let audit = try #require(try await sql.raw("SELECT action, reason_code FROM im_v2.moderation_audit_entries WHERE actor_user_id = \(bind: senderUUID)").first(decoding: ModerationAuditAssertionRow.self))
            let state = try #require(try await sql.raw("SELECT withdrawn_at IS NOT NULL AS withdrawn, content_revision FROM im_v2.messages WHERE message_id = \(bind: UUID(uuidString: message.messageID.rawValue)!)").first(decoding: ModerationMessageAssertionRow.self))
            let planning = try await V2FanoutPlanner(store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: testUserShardRouter), pageSize: 2, now: { now.addingTimeInterval(3) }).plan(.init(sourceEventID: result.eventID, planID: result.fanoutPlanID))
            let delivery = try await V2FanoutDeliveryWorker(store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)), now: { now.addingTimeInterval(4) }).runOnce(limit: 8)
            let delivered = try #require(try await sql.raw("SELECT payload->>'event_type' AS event_type FROM im_v2.user_sync_log WHERE source_event_id = \(bind: UUID(uuidString: result.eventID.rawValue)!) LIMIT 1").first(decoding: ModerationDeliveredEventRow.self))
            let snapshot = try await PostgresV2SnapshotProjectionMaterializer(database: app.db(.psql)).materialize(userID: senderID, now: now.addingTimeInterval(5))
            let snapshotMessages = try snapshot.pages.flatMap { try V2SnapshotProjectionCodec.decodePage($0.payload).messages }
            #expect(replay == .idempotent(result))
            #expect(event.eventType == "message.redacted")
            #expect(event.messageID == message.messageID.rawValue)
            #expect(audit.action == "redact_message")
            #expect(audit.reasonCode == "abuse_spam")
            #expect(state.withdrawn)
            #expect(state.revision == 2)
            #expect(planning == .init(createdCompletionUnits: 2, createdDeliveries: 3, wasAlreadyPlanned: false))
            #expect(delivery == .init(claimedCount: 3, committedCount: 3, staleCount: 0, releasedCount: 0))
            #expect(delivered.eventType == "message.redacted")
            #expect(snapshotMessages == [try .init(sourceEventID: .init(acceptedTrigger.sourceEventID.uuidString), messageID: message.messageID, roomID: roomID, roomSequence: 1, messageRevision: 2, senderUserID: senderID, text: "requires moderation", createdAt: now, isWithdrawn: true)])
            #expect(try await count("im_v2.moderation_operations", on: sql) == 1)
            try await sql.raw("UPDATE im_v2.moderation_audit_entries SET retain_until = \(bind: now.addingTimeInterval(-1))").run()
            let retention = V2ModerationAuditRetentionWorker(
                store: PostgresV2ModerationAuditRetentionStore(database: app.db(.psql)),
                now: { now }
            )
            #expect(try await retention.runOnce(limit: 1) == 1)
            #expect(try await retention.runOnce(limit: 1) == 0)
            #expect(try await count("im_v2.moderation_audit_entries", on: sql) == 0)
            #expect(try await count("im_v2.moderation_operations", on: sql) == 1)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("frozen rooms and active member mutes reject new messages before any write")
    func moderationAdmissionStatesBlockMessages() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3))
            let messages = V2SendMessageService(store: PostgresV2RoomWriteStore(database: app.db(.psql)), capacityProfile: profile, limits: try .init(maxUTF8Bytes: 64), now: { now })

            try await sql.raw("UPDATE im_v2.rooms SET frozen_at = \(bind: now), frozen_by_user_id = \(bind: memberTwoUUID) WHERE room_id = \(bind: roomUUID)").run()
            await #expect(throws: V2RoomWriteStoreError.roomFrozen) {
                _ = try await messages.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "blocked-by-freeze"))
            }

            try await sql.raw("UPDATE im_v2.rooms SET frozen_at = NULL, frozen_by_user_id = NULL WHERE room_id = \(bind: roomUUID)").run()
            let muteOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000070")!
            try await sql.raw("INSERT INTO im_v2.room_member_mutes (room_id, user_id, mute_until, actor_user_id, operation_id, created_at) VALUES (\(bind: roomUUID), \(bind: senderUUID), \(bind: now.addingTimeInterval(300)), \(bind: memberTwoUUID), \(bind: muteOperationID), \(bind: now))").run()
            await #expect(throws: V2RoomWriteStoreError.actorMuted) {
                _ = try await messages.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: try .init("00000000-0000-0000-0000-000000000071"), text: "blocked-by-mute"))
            }
            #expect(try await count("im_v2.messages", on: sql) == 0)
            #expect(try await count("im_v2.room_events", on: sql) == 0)
            #expect(try await count("im_v2.room_outbox", on: sql) == 0)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("trusted safety service freezes and unfreezes a room with durable audit and fan-out")
    func trustedSafetyRoomControlIsDurableAndEnforced() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3))
            let safetyActor = try UserID("00000000-0000-0000-0000-000000000110")
            let safety = V2TrustedSafetyModerationService(
                store: PostgresV2ModerationStore(database: app.db(.psql)),
                safetyActorUserID: safetyActor,
                capacityProfile: profile,
                now: { now }
            )
            let freeze = try V2TrustedSafetyRoomControl(roomID: roomID, operationID: .init("00000000-0000-0000-0000-000000000112"), action: .freezeRoom, reasonCode: .init("safety_review"))
            let first = try await safety.apply(freeze)
            guard case .applied(let frozen) = first else { Issue.record("expected room freeze"); return }
            let replay = try await safety.apply(freeze)
            let state = try #require(try await sql.raw("SELECT frozen_at, frozen_by_user_id FROM im_v2.rooms WHERE room_id = \(bind: roomUUID)").first(decoding: FrozenRoomAssertionRow.self))
            let audit = try #require(try await sql.raw("SELECT action, reason_code FROM im_v2.moderation_audit_entries WHERE actor_user_id = \(bind: UUID(uuidString: safetyActor.rawValue)!)").first(decoding: ModerationAuditAssertionRow.self))
            let messages = V2SendMessageService(store: PostgresV2RoomWriteStore(database: app.db(.psql)), capacityProfile: profile, limits: try .init(maxUTF8Bytes: 64), now: { now })
            await #expect(throws: V2RoomWriteStoreError.roomFrozen) {
                _ = try await messages.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "frozen"))
            }
            let planning = try await V2FanoutPlanner(store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: testUserShardRouter), pageSize: 2, now: { now.addingTimeInterval(1) }).plan(.init(sourceEventID: frozen.eventID, planID: frozen.fanoutPlanID))
            let delivery = try await V2FanoutDeliveryWorker(store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)), now: { now.addingTimeInterval(2) }).runOnce(limit: 8)
            let projection = try #require(try await sql.raw("SELECT projection_kind, payload->>'event_type' AS event_type FROM im_v2.user_sync_log WHERE source_event_id = \(bind: UUID(uuidString: frozen.eventID.rawValue)!) LIMIT 1").first(decoding: FreezeProjectionRow.self))

            let unfreeze = try V2TrustedSafetyRoomControl(roomID: roomID, operationID: .init("00000000-0000-0000-0000-000000000113"), action: .unfreezeRoom, reasonCode: .init("safety_review"))
            let unfrozen = try await safety.apply(unfreeze)
            guard case .applied(let result) = unfrozen else { Issue.record("expected room unfreeze"); return }
            let finalState = try #require(try await sql.raw("SELECT frozen_at, frozen_by_user_id FROM im_v2.rooms WHERE room_id = \(bind: roomUUID)").first(decoding: FrozenRoomAssertionRow.self))

            #expect(replay == .idempotent(frozen))
            #expect(state.frozenAt == now)
            #expect(state.frozenByUserID == UUID(uuidString: safetyActor.rawValue))
            #expect(audit.action == "freeze_room")
            #expect(audit.reasonCode == "safety_review")
            #expect(planning == .init(createdCompletionUnits: 2, createdDeliveries: 3, wasAlreadyPlanned: false))
            #expect(delivery == .init(claimedCount: 3, committedCount: 3, staleCount: 0, releasedCount: 0))
            #expect(projection.projectionKind == "moderation")
            #expect(projection.eventType == "room.frozen")
            #expect(result.action == .unfreezeRoom)
            #expect(finalState.frozenAt == nil)
            #expect(finalState.frozenByUserID == nil)
            #expect(try await count("im_v2.moderation_operations", on: sql) == 2)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("moderator mute persists its audit event, fans out, replays, and blocks the target")
    func moderatorMuteIsDurableAndEnforced() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").run()
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3))
            let moderation = V2ModerationService(store: PostgresV2ModerationStore(database: app.db(.psql)), capacityProfile: profile, now: { now })
            let request = V2AuthenticatedModeration(roomID: roomID, actorUserID: senderID, operationID: try .init("00000000-0000-0000-0000-000000000074"), action: .muteMember, targetUserID: try .init(memberTwoUUID.uuidString), muteUntil: now.addingTimeInterval(300), reasonCode: try .init("abuse_spam"))
            let first = try await moderation.apply(request)
            guard case .applied(let result) = first else { Issue.record("expected mute application"); return }
            let replay = try await moderation.apply(request)
            let mute = try #require(try await sql.raw("SELECT mute_until, actor_user_id FROM im_v2.room_member_mutes WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: memberTwoUUID)").first(decoding: MuteAssertionRow.self))
            let audit = try #require(try await sql.raw("SELECT action, reason_code FROM im_v2.moderation_audit_entries WHERE actor_user_id = \(bind: senderUUID)").first(decoding: ModerationAuditAssertionRow.self))
            let event = try #require(try await sql.raw("SELECT event_type, payload->>'target_user_id' AS target_user_id FROM im_v2.room_events WHERE event_id = \(bind: UUID(uuidString: result.eventID.rawValue)!)").first(decoding: MuteEventAssertionRow.self))
            let messages = V2SendMessageService(store: PostgresV2RoomWriteStore(database: app.db(.psql)), capacityProfile: profile, limits: try .init(maxUTF8Bytes: 64), now: { now })
            await #expect(throws: V2RoomWriteStoreError.actorMuted) {
                _ = try await messages.send(.init(roomID: roomID, actorUserID: try .init(memberTwoUUID.uuidString), clientMessageID: try .init("00000000-0000-0000-0000-000000000075"), text: "must-not-send"))
            }
            let planning = try await V2FanoutPlanner(store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: testUserShardRouter), pageSize: 2, now: { now.addingTimeInterval(1) }).plan(.init(sourceEventID: result.eventID, planID: result.fanoutPlanID))
            let delivery = try await V2FanoutDeliveryWorker(store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)), now: { now.addingTimeInterval(2) }).runOnce(limit: 8)
            let snapshot = try await PostgresV2SnapshotProjectionMaterializer(database: app.db(.psql)).materialize(userID: senderID, now: now.addingTimeInterval(3))
            let snapshotMutes = try snapshot.pages.flatMap { try V2SnapshotProjectionCodec.decodePage($0.payload).moderationActions }
            #expect(replay == .idempotent(result))
            #expect(mute.actorUserID == senderUUID)
            #expect(mute.muteUntil == now.addingTimeInterval(300))
            #expect(audit.action == "mute_member")
            #expect(audit.reasonCode == "abuse_spam")
            #expect(event.eventType == "member.muted")
            #expect(event.targetUserID == memberTwoUUID.uuidString)
            #expect(planning == .init(createdCompletionUnits: 2, createdDeliveries: 3, wasAlreadyPlanned: false))
            #expect(delivery == .init(claimedCount: 3, committedCount: 3, staleCount: 0, releasedCount: 0))
            #expect(snapshotMutes == [try .init(sourceEventID: result.eventID, roomID: roomID, roomSequence: result.roomSequence, actorUserID: senderID, targetUserID: try .init(memberTwoUUID.uuidString), muteUntil: now.addingTimeInterval(300), createdAt: now)])
            #expect(try await count("im_v2.moderation_operations", on: sql) == 1)
            #expect(try await count("im_v2.messages", on: sql) == 0)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("audit member removal is atomic, replayable, and includes the departing member in its frozen audience")
    func moderatedMemberRemovalIsDurableAndDeliveredToTarget() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").run()
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3))
            let moderation = V2ModerationService(store: PostgresV2ModerationStore(database: app.db(.psql)), capacityProfile: profile, now: { now })
            let request = V2AuthenticatedModeration(roomID: roomID, actorUserID: senderID, operationID: try .init("00000000-0000-0000-0000-000000000076"), action: .removeMember, targetUserID: try .init(memberTwoUUID.uuidString), reasonCode: try .init("abuse_spam"))
            let first = try await moderation.apply(request)
            guard case .applied(let result) = first, let membershipRevision = result.membershipRevision else { Issue.record("expected audited removal"); return }
            let replay = try await moderation.apply(request)
            let membership = try #require(try await sql.raw("SELECT left_revision FROM im_v2.room_memberships WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: memberTwoUUID)").first(decoding: RemovedMembershipAssertionRow.self))
            let audit = try #require(try await sql.raw("SELECT action, reason_code FROM im_v2.moderation_audit_entries WHERE actor_user_id = \(bind: senderUUID)").first(decoding: ModerationAuditAssertionRow.self))
            let event = try #require(try await sql.raw("SELECT event_type, payload->>'action' AS action, payload->>'target_user_id' AS target_user_id FROM im_v2.room_events WHERE event_id = \(bind: UUID(uuidString: result.eventID.rawValue)!)").first(decoding: ModeratedRemovalEventAssertionRow.self))
            let planning = try await V2FanoutPlanner(store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: testUserShardRouter), pageSize: 2, now: { now.addingTimeInterval(1) }).plan(.init(sourceEventID: result.eventID, planID: result.fanoutPlanID))
            let delivery = try await V2FanoutDeliveryWorker(store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)), now: { now.addingTimeInterval(2) }).runOnce(limit: 8)
            let targetDelivery = try #require(try await sql.raw("SELECT COUNT(*)::int AS value FROM im_v2.user_sync_log WHERE source_event_id = \(bind: UUID(uuidString: result.eventID.rawValue)!) AND user_id = \(bind: memberTwoUUID)").first(decoding: CountRow.self))
            #expect(replay == .idempotent(result))
            #expect(membership.leftRevision == Int64(membershipRevision))
            #expect(audit.action == "remove_member")
            #expect(audit.reasonCode == "abuse_spam")
            #expect(event.eventType == "membership_changed")
            #expect(event.action == "remove")
            #expect(event.targetUserID == memberTwoUUID.uuidString)
            #expect(planning == .init(createdCompletionUnits: 2, createdDeliveries: 3, wasAlreadyPlanned: false))
            #expect(delivery == .init(claimedCount: 3, committedCount: 3, staleCount: 0, releasedCount: 0))
            #expect(targetDelivery.value == 1)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("durable-work metrics query aggregate backlog without exposing routes or identifiers")
    func readsDurableWorkBacklog() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let metrics = PostgresV2DurableWorkMetricsSource(database: app.db(.psql), deliveryBucket: "test-users")
            #expect(try await metrics.loadDurableWorkMetrics() == .init(isAvailable: true))

            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3)
            let send = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: app.db(.psql)),
                capacityProfile: try .init(id: "standard", limits: profile),
                limits: try .init(maxUTF8Bytes: 64),
                now: { now }
            )
            guard case .accepted = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "metrics")) else {
                Issue.record("expected accepted message")
                return
            }
            let relay = V2OutboxRelay(
                store: PostgresV2RoomOutboxStore(database: app.db(.psql)),
                publisher: V2LocalFanoutPlanPublisher(
                    planner: .init(
                        store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: testUserShardRouter),
                        pageSize: 2,
                        now: { now }
                    )
                ),
                now: { now }
            )
            #expect(try await relay.runOnce(limit: 1) == .init(claimedCount: 1, publishedCount: 1, releasedCount: 0))
            try await sql.raw("""
                UPDATE im_v2.fanout_deliveries
                SET target_shard_bucket = 'test-users-b'
                WHERE target_user_id = \(bind: senderUUID)
                """).run()

            let snapshot = await metrics.durableWorkMetricsSnapshot()
            #expect(snapshot.isAvailable)
            #expect(snapshot.readyRoomOutboxRows == 0)
            #expect(snapshot.leasedRoomOutboxRows == 0)
            #expect(snapshot.openFanoutPlans == 1)
            #expect(snapshot.readyFanoutDeliveries == 2)
            #expect(snapshot.leasedFanoutDeliveries == 0)
            #expect(snapshot.pendingSyncRecordsAcrossDevices == 0)
            #expect(snapshot.resetPendingDevices == 0)
            let allBuckets = PostgresV2DurableWorkMetricsSource(database: app.db(.psql))
            #expect((await allBuckets.durableWorkMetricsSnapshot()).readyFanoutDeliveries == 3)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("expired outbox and delivery leases recover across worker replacement")
    func fanoutWorkersRecoverAfterLeaseExpiry() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3)
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: app.db(.psql)), capacityProfile: try .init(id: "standard", limits: profile), limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "recover after worker replacement")) else { Issue.record("expected accepted message"); return }

            let abandonedOutbox = try await PostgresV2RoomOutboxStore(database: app.db(.psql)).claimPending(now: now.addingTimeInterval(1), leaseDuration: 30, limit: 8)
            #expect(abandonedOutbox.count == 1)
            let recoveredRelay = V2OutboxRelay(
                store: PostgresV2RoomOutboxStore(database: app.db(.psql)),
                publisher: V2LocalFanoutPlanPublisher(planner: .init(store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: testUserShardRouter), pageSize: 2, now: { now.addingTimeInterval(32) })),
                now: { now.addingTimeInterval(32) }
            )
            #expect(try await recoveredRelay.runOnce(limit: 8) == .init(claimedCount: 1, publishedCount: 1, releasedCount: 0))

            let abandonedDeliveries = try await PostgresV2FanoutDeliveryStore(database: app.db(.psql)).claimPending(bucket: nil, now: now.addingTimeInterval(33), leaseDuration: 30, limit: 8)
            #expect(abandonedDeliveries.count == 3)
            let recoveredDelivery = V2FanoutDeliveryWorker(store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)), now: { now.addingTimeInterval(64) })
            #expect(try await recoveredDelivery.runOnce(limit: 8) == .init(claimedCount: 3, committedCount: 3, staleCount: 0, releasedCount: 0))
            #expect(try await count("im_v2.user_sync_log", on: sql) == 3)
            #expect(try await count("im_v2.fanout_deliveries WHERE state = 'terminal'", on: sql) == 3)
            #expect(try await count("im_v2.fanout_plans WHERE state = 'terminal'", on: sql) == 1)
            #expect(try await count("im_v2.room_outbox WHERE state = 'terminal'", on: sql) == 1)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("durable work backs off, pauses, and requires explicit replay without terminal skipping")
    func durableWorkRetryPauseAndReplay() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql); try await seedRoom(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3)
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: app.db(.psql)), capacityProfile: try .init(id: "standard", limits: profile), limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "retry pause replay")) else { Issue.record("expected accepted message"); return }
            let trigger = try #require(try await sql.raw("SELECT source_event_id, plan_id FROM im_v2.room_outbox").first(decoding: TriggerRow.self))
            let sourceEventID = try EventID(trigger.sourceEventID.uuidString)
            let planID = try FanoutPlanID(trigger.planID.uuidString)
            let outbox = PostgresV2RoomOutboxStore(database: app.db(.psql))
            let delivery = PostgresV2FanoutDeliveryStore(database: app.db(.psql))
            let metrics = PostgresV2DurableWorkMetricsSource(database: app.db(.psql), deliveryBucket: "test-users")
            let operatorReplay = V2DurableWorkOperatorReplayService(
                store: PostgresV2DurableWorkReplayStore(database: app.db(.psql)),
                operatorPrincipal: "oncall-primary",
                now: { now.addingTimeInterval(12) }
            )

            let firstOutbox = try #require(try await outbox.claimPending(now: now, leaseDuration: 30, limit: 1).first)
            #expect(firstOutbox.attempt == 1)
            try await outbox.scheduleRetry(firstOutbox, disposition: .retry(at: now.addingTimeInterval(10)), now: now)
            #expect(try await outbox.claimPending(now: now.addingTimeInterval(9), leaseDuration: 30, limit: 1).isEmpty)
            let secondOutbox = try #require(try await outbox.claimPending(now: now.addingTimeInterval(10), leaseDuration: 30, limit: 1).first)
            #expect(secondOutbox.attempt == 2)
            try await outbox.scheduleRetry(secondOutbox, disposition: .pause, now: now.addingTimeInterval(10))
            let pausedOutbox = try #require(try await sql.raw("SELECT state, retry_count FROM im_v2.room_outbox WHERE source_event_id = \(bind: trigger.sourceEventID)").first(decoding: DurableRetryStateRow.self))
            #expect(pausedOutbox.state == "paused")
            #expect(pausedOutbox.retryCount == 2)
            #expect(try await outbox.claimPending(now: now.addingTimeInterval(11), leaseDuration: 30, limit: 1).isEmpty)
            #expect((await metrics.durableWorkMetricsSnapshot()).pausedRoomOutboxRows == 1)

            let outboxReplayCommand = try V2DurableWorkReplayCommand(
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000881")!,
                target: .init(kind: .roomOutbox, sourceEventID: sourceEventID),
                reason: .dependencyRecovered
            )
            #expect(try await operatorReplay.replay(outboxReplayCommand) == .init(operationID: outboxReplayCommand.operationID, outcome: .requeued, wasIdempotent: false))
            #expect(try await operatorReplay.replay(outboxReplayCommand) == .init(operationID: outboxReplayCommand.operationID, outcome: .requeued, wasIdempotent: true))
            let replayedOutbox = try #require(try await outbox.claimPending(now: now.addingTimeInterval(12), leaseDuration: 30, limit: 1).first)
            #expect(replayedOutbox.attempt == 1)
            _ = try await V2FanoutPlanner(store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: testUserShardRouter), pageSize: 2, now: { now.addingTimeInterval(12) }).plan(.init(sourceEventID: sourceEventID, planID: planID))
            try await outbox.markPublished(replayedOutbox)

            let firstDeliveries = try await delivery.claimPending(bucket: nil, now: now.addingTimeInterval(13), leaseDuration: 30, limit: 8)
            #expect(firstDeliveries.count == 3)
            #expect(firstDeliveries.allSatisfy { $0.attempt == 1 })
            for lease in firstDeliveries {
                try await delivery.scheduleRetry(lease, disposition: .retry(at: now.addingTimeInterval(20)), now: now.addingTimeInterval(13))
            }
            #expect(try await delivery.claimPending(bucket: nil, now: now.addingTimeInterval(19), leaseDuration: 30, limit: 8).isEmpty)
            let secondDeliveries = try await delivery.claimPending(bucket: nil, now: now.addingTimeInterval(20), leaseDuration: 30, limit: 8)
            #expect(secondDeliveries.count == 3)
            #expect(secondDeliveries.allSatisfy { $0.attempt == 2 })
            for lease in secondDeliveries {
                try await delivery.scheduleRetry(lease, disposition: .pause, now: now.addingTimeInterval(20))
            }
            #expect(try await count("im_v2.fanout_deliveries WHERE state = 'paused'", on: sql) == 3)
            #expect(try await delivery.claimPending(bucket: nil, now: now.addingTimeInterval(21), leaseDuration: 30, limit: 8).isEmpty)
            let pausedMetrics = await metrics.durableWorkMetricsSnapshot()
            #expect(pausedMetrics.pausedRoomOutboxRows == 0)
            #expect(pausedMetrics.pausedFanoutDeliveries == 3)

            let replayTarget = try #require(secondDeliveries.first)
            let deliveryReplayCommand = try V2DurableWorkReplayCommand(
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000882")!,
                target: .init(
                    kind: .fanoutDelivery,
                    sourceEventID: replayTarget.sourceEventID,
                    targetUserID: replayTarget.targetUserID,
                    projectionKind: replayTarget.projectionKind
                ),
                reason: .dataRepaired
            )
            #expect(try await operatorReplay.replay(deliveryReplayCommand) == .init(operationID: deliveryReplayCommand.operationID, outcome: .requeued, wasIdempotent: false))
            let replayedDelivery = try #require(try await delivery.claimPending(bucket: nil, now: now.addingTimeInterval(22), leaseDuration: 30, limit: 8).first)
            #expect(replayedDelivery.targetUserID == replayTarget.targetUserID)
            #expect(replayedDelivery.attempt == 1)
            #expect(try await count("im_v2.fanout_deliveries WHERE state = 'paused'", on: sql) == 2)
            #expect((await metrics.durableWorkMetricsSnapshot()).pausedFanoutDeliveries == 2)
            #expect(try await count("im_v2.fanout_deliveries WHERE state = 'terminal'", on: sql) == 0)
            #expect(try await count("im_v2.fanout_completion_units WHERE state = 'released'", on: sql) == 0)
            #expect(try await count("im_v2.room_outbox WHERE state = 'terminal'", on: sql) == 0)
            #expect(try await count("im_v2.durable_work_replay_audit WHERE outcome = 'requeued'", on: sql) == 2)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("trusted device registration and refresh rotation are durable, replayable, and revoke on reuse")
    func deviceCredentialRotationFencesReuse() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let tokenKey = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 0x11, count: 32))
            let replayKey = try V2CredentialReplayEnvelopeKey(rawBytes: Data(repeating: 0x22, count: 32))
            let issuer = try V2PostgresDeviceCredentialService(
                database: app.db(.psql),
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

            let gateway = V2PostgresGatewayAuthenticator(database: app.db(.psql), tokenKey: tokenKey, now: { now })
            #expect(try await gateway.authenticate(accessToken: initial.accessToken, deviceID: deviceID) == userID)

            let refresh = try V2DeviceCredentialRefresh(
                userID: userID,
                deviceID: deviceID,
                refreshCredential: initial.refreshCredential,
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000204")!
            )
            guard case .rotated(let successor) = try await issuer.refresh(refresh) else { Issue.record("expected refresh rotation"); return }
            #expect(successor.accessToken != initial.accessToken)
            #expect(successor.refreshCredential != initial.refreshCredential)
            #expect(try await issuer.refresh(refresh) == .idempotent(successor))
            #expect(try await gateway.authenticate(accessToken: successor.accessToken, deviceID: deviceID) == userID)

            let reuse = try V2DeviceCredentialRefresh(
                userID: userID,
                deviceID: deviceID,
                refreshCredential: initial.refreshCredential,
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000205")!
            )
            #expect(try await issuer.refresh(reuse) == .terminalRejection)
            await #expect(throws: V2GatewayAuthenticationError.unauthenticated) {
                try await gateway.authenticate(accessToken: successor.accessToken, deviceID: deviceID)
            }
            #expect(try await count("im_v2.auth_devices", on: sql) == 1)
            #expect(try await count("im_v2.device_refresh_sessions", on: sql) == 1)
            #expect(try await count("im_v2.device_credential_operations", on: sql) == 2)
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 1)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("account HTTP retries replay one durable credential result after response loss")
    func deviceCredentialHTTPRetriesReplayPersistedResult() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_100)
            let tokenKey = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 0x31, count: 32))
            let replayKey = try V2CredentialReplayEnvelopeKey(rawBytes: Data(repeating: 0x32, count: 32))
            let assertionIssuer = try V2HMACAccountAssertionIssuer(rawKey: Data(repeating: 0x33, count: 32), now: { now })
            let issuer = try V2PostgresDeviceCredentialService(
                database: app.db(.psql),
                tokenHMACKey: tokenKey,
                replayEnvelopeKey: replayKey,
                now: { now }
            )
            V2VaporDeviceCredentialRoutes(assertionVerifier: assertionIssuer, issuer: issuer).register(on: app)

            let userID = try UserID("00000000-0000-0000-0000-000000000211")
            let deviceID = try DeviceID("00000000-0000-0000-0000-000000000212")
            let registrationOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000213")!
            let registration = V2DeviceCredentialIssueHTTPRequest(
                accountAssertion: try assertionIssuer.issue(userID: userID, deviceID: deviceID),
                deviceID: deviceID.rawValue,
                operationID: registrationOperationID
            )

            // Model a client that lost the first successful response: the
            // second identical request is the only response it observes.
            var firstRegistration: V2DeviceCredentialIssueHTTPResponse?
            try await app.testing().test(.POST, "v2/device-credentials", beforeRequest: { request in
                try request.content.encode(registration)
            }) { response async in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: .cacheControl) == "no-store")
                expectContent(V2DeviceCredentialIssueHTTPResponse.self, response) { firstRegistration = $0 }
            }
            var replayedRegistration: V2DeviceCredentialIssueHTTPResponse?
            try await app.testing().test(.POST, "v2/device-credentials", beforeRequest: { request in
                try request.content.encode(registration)
            }) { response async in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: .cacheControl) == "no-store")
                expectContent(V2DeviceCredentialIssueHTTPResponse.self, response) { replayedRegistration = $0 }
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
                refreshCredential: initial.refreshCredential,
                operationID: refreshOperationID
            )
            var firstRefresh: V2DeviceCredentialIssueHTTPResponse?
            try await app.testing().test(.POST, "v2/device-credentials/refresh", beforeRequest: { request in
                try request.content.encode(refresh)
            }) { response async in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: .cacheControl) == "no-store")
                expectContent(V2DeviceCredentialIssueHTTPResponse.self, response) { firstRefresh = $0 }
            }
            var replayedRefresh: V2DeviceCredentialIssueHTTPResponse?
            try await app.testing().test(.POST, "v2/device-credentials/refresh", beforeRequest: { request in
                try request.content.encode(refresh)
            }) { response async in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: .cacheControl) == "no-store")
                expectContent(V2DeviceCredentialIssueHTTPResponse.self, response) { replayedRefresh = $0 }
            }
            let successor = try #require(firstRefresh)
            let replayedSuccessor = try #require(replayedRefresh)
            #expect(successor.accessToken != initial.accessToken)
            #expect(successor.refreshCredential != initial.refreshCredential)
            #expect(replayedSuccessor.accessToken == successor.accessToken)
            #expect(replayedSuccessor.accessTokenExpiresAtMilliseconds == successor.accessTokenExpiresAtMilliseconds)
            #expect(replayedSuccessor.refreshCredential == successor.refreshCredential)

            let gateway = V2PostgresGatewayAuthenticator(database: app.db(.psql), tokenKey: tokenKey, now: { now })
            #expect(try await gateway.authenticate(accessToken: successor.accessToken, deviceID: deviceID) == userID)
            #expect(try await count("im_v2.auth_devices", on: sql) == 1)
            #expect(try await count("im_v2.device_refresh_sessions", on: sql) == 1)
            #expect(try await count("im_v2.device_credential_operations", on: sql) == 2)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("a stale delivery route is fenced into the new bucket without creating a second durable target")
    func staleDeliveryRouteHandoffMovesTheClaimedRow() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let room = UUID(uuidString: "00000000-0000-0000-0000-000000000a01")!
            let event = UUID(uuidString: "00000000-0000-0000-0000-000000000a02")!
            let plan = UUID(uuidString: "00000000-0000-0000-0000-000000000a03")!
            let unit = UUID(uuidString: "00000000-0000-0000-0000-000000000a04")!
            let user = UUID(uuidString: "00000000-0000-0000-0000-000000000a05")!
            let userID = try UserID(user.uuidString)
            let router = V2PostgresUserShardRouter(database: app.db(.psql))
            let initialRoute = try V2UserShardRoute(bucket: "users-old", observedRouterEpoch: 4)
            try await router.bootstrap(defaultRoute: initialRoute, now: now)
            #expect(try await router.routes(for: [userID]) == [initialRoute])
            let migrationStore = PostgresV2UserShardMigrationStore(database: app.db(.psql))
            let migration = try await migrationStore.prepare(.init(
                migrationID: UUID(uuidString: "00000000-0000-0000-0000-000000000a09")!, userID: userID,
                sourceBucket: "users-old", targetBucket: "users-new", sourceRouterEpoch: 4
            ), now: now)
            _ = try await migrationStore.advance(migrationID: migration.migrationID, expectedPhase: .prepared, action: .beginCopy, fingerprints: nil, now: now)
            _ = try await migrationStore.advance(migrationID: migration.migrationID, expectedPhase: .copying, action: .copySucceeded, fingerprints: nil, now: now)
            _ = try await migrationStore.advance(migrationID: migration.migrationID, expectedPhase: .copied, action: .beginVerification, fingerprints: nil, now: now)
            _ = try await migrationStore.advance(migrationID: migration.migrationID, expectedPhase: .verifying, action: .verificationSucceeded, fingerprints: ("same", "same"), now: now)
            _ = try await migrationStore.advance(migrationID: migration.migrationID, expectedPhase: .forwarding, action: .forwardingVerificationSucceeded, fingerprints: ("same", "same"), now: now)
            let cutover = try V2UserShardRouteCutover(
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000a07")!,
                userID: userID,
                expectedRouterEpoch: 4,
                newWriteBucket: "users-new",
                readFallbackBucket: "users-old"
            )
            let control = V2PostgresUserShardRouteControl(database: app.db(.psql), operatorPrincipal: "router-test")
            await #expect(throws: V2UserShardRouteControlError.migrationNotVerified) {
                try await control.cutOver(.init(
                    operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000a10")!,
                    userID: try UserID("00000000-0000-0000-0000-000000000a11"),
                    expectedRouterEpoch: 4,
                    newWriteBucket: "users-unverified",
                    readFallbackBucket: "users-old"
                ), now: now)
            }
            let firstCutover = try await control.cutOver(cutover, now: now)
            let currentRoute = firstCutover.route
            let expectedCurrentRoute = try V2UserShardRoute(bucket: "users-new", observedRouterEpoch: 5, readFallbackBucket: "users-old")
            #expect(currentRoute == expectedCurrentRoute)
            #expect(firstCutover.wasIdempotent == false)
            #expect(try await control.cutOver(cutover, now: now.addingTimeInterval(1)) == .init(route: currentRoute, wasIdempotent: true))
            let retainedMigration = try await migrationStore.load(migrationID: migration.migrationID)
            #expect(retainedMigration?.phase == .retention)
            #expect(retainedMigration?.cutoverOperationID == cutover.operationID)
            #expect(retainedMigration?.retentionUntil == now.addingTimeInterval(86_400))
            await #expect(throws: V2UserShardRouteControlError.staleRouterEpoch) {
                try await control.cutOver(.init(
                    operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000a08")!,
                    userID: userID,
                    expectedRouterEpoch: 4,
                    newWriteBucket: "users-third",
                    readFallbackBucket: "users-new"
                ), now: now)
            }
            #expect(try await router.routes(for: [userID]) == [currentRoute])
            try await sql.raw("""
                INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id)
                VALUES (\(bind: room), 'route-test', 'standard');
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
                VALUES (\(bind: event), \(bind: room), 1, 'message.accepted', NULL, '{}'::jsonb, 0, \(bind: now));
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.fanout_plans
                    (plan_id, source_event_id, room_id, source_room_sequence, committed_membership_revision,
                     target_rule, enumeration_checkpoint, target_count, reserved_fanout_cost, state, created_at)
                VALUES (\(bind: plan), \(bind: event), \(bind: room), 1, 0,
                        '{"kind":"frozen_targets"}'::jsonb, '{}'::jsonb, 1, 1, 'planned', \(bind: now));
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.fanout_completion_units
                    (source_event_id, completion_unit_id, target_boundary, target_count, state)
                VALUES (\(bind: event), \(bind: unit), '{}'::jsonb, 1, 'pending');
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.fanout_deliveries
                    (source_event_id, target_user_id, projection_kind, completion_unit_id, target_shard_bucket, observed_router_epoch)
                VALUES (\(bind: event), \(bind: user), 'message', \(bind: unit), 'users-old', 4);
                """).run()

            let store = PostgresV2FanoutDeliveryStore(
                database: app.db(.psql),
                makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000a06")! }
            )
            let handoff = try await V2FanoutDeliveryWorker(
                store: store,
                bucket: "users-old",
                router: router,
                now: { now }
            ).runOnce(limit: 1)
            #expect(handoff == .init(claimedCount: 1, committedCount: 0, staleCount: 0, staleRouteCount: 1, releasedCount: 0))

            let row = try #require(try await sql.raw("""
                SELECT target_shard_bucket, observed_router_epoch, claim_token IS NULL AS unclaimed
                FROM im_v2.fanout_deliveries
                WHERE source_event_id = \(bind: event) AND target_user_id = \(bind: user) AND projection_kind = 'message'
                """).first(decoding: HandoffRouteRow.self))
            #expect(row.bucket == "users-new")
            #expect(row.epoch == 5)
            #expect(row.unclaimed)
            #expect(try await store.claimPending(bucket: "users-old", now: now, leaseDuration: 30, limit: 1).isEmpty)
            #expect(try await store.claimPending(bucket: "users-new", now: now, leaseDuration: 30, limit: 1).count == 1)
            #expect(try await count("im_v2.fanout_deliveries", on: sql) == 1)
            let rollback = try V2UserShardRouteRollback(
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000a12")!, userID: userID,
                expectedRouterEpoch: 5
            )
            let rollbackResult = try await control.rollBack(rollback, now: now.addingTimeInterval(2))
            let expectedRollbackRoute = try V2UserShardRoute(
                bucket: "users-old", observedRouterEpoch: 6, readFallbackBucket: "users-new"
            )
            #expect(rollbackResult.route == expectedRollbackRoute)
            #expect(!rollbackResult.wasIdempotent)
            #expect(try await control.rollBack(rollback, now: now.addingTimeInterval(3)).wasIdempotent)
            #expect(try await migrationStore.load(migrationID: migration.migrationID)?.phase == .rolledBack)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("user-shard migration phases are durable, fenced, and idempotently prepared")
    func userShardMigrationStoreFencesProgress() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let user = try UserID("00000000-0000-0000-0000-000000000b01")
            let request = try V2UserShardMigrationPreparation(
                migrationID: UUID(uuidString: "00000000-0000-0000-0000-000000000b02")!, userID: user,
                sourceBucket: "users-old", targetBucket: "users-new", sourceRouterEpoch: 12
            )
            let store = PostgresV2UserShardMigrationStore(database: app.db(.psql))
            let prepared = try await store.prepare(request, now: now)
            #expect(prepared.phase == .prepared)
            #expect(try await store.prepare(request, now: now.addingTimeInterval(1)) == prepared)
            await #expect(throws: V2UserShardMigrationStoreError.requestConflict) {
                try await store.prepare(.init(
                    migrationID: request.migrationID, userID: user, sourceBucket: "users-old",
                    targetBucket: "users-third", sourceRouterEpoch: 12
                ), now: now)
            }

            let copying = try await store.advance(
                migrationID: request.migrationID, expectedPhase: .prepared, action: .beginCopy,
                fingerprints: nil, now: now
            )
            #expect(copying.phase == .copying)
            await #expect(throws: V2UserShardMigrationStoreError.phaseConflict) {
                try await store.advance(
                    migrationID: request.migrationID, expectedPhase: .prepared, action: .beginCopy,
                    fingerprints: nil, now: now
                )
            }
            let copied = try await store.advance(
                migrationID: request.migrationID, expectedPhase: .copying, action: .copySucceeded,
                fingerprints: nil, now: now
            )
            let verifying = try await store.advance(
                migrationID: request.migrationID, expectedPhase: copied.phase, action: .beginVerification,
                fingerprints: nil, now: now
            )
            let forwarding = try await store.advance(
                migrationID: request.migrationID, expectedPhase: verifying.phase, action: .verificationSucceeded,
                fingerprints: ("sha256:equal", "sha256:equal"), now: now
            )
            #expect(forwarding.phase == .forwarding)
            let verified = try await store.advance(
                migrationID: request.migrationID, expectedPhase: forwarding.phase, action: .forwardingVerificationSucceeded,
                fingerprints: ("sha256:equal", "sha256:equal"), now: now
            )
            #expect(verified.phase == .verified)
            #expect(verified.sourceFingerprint == "sha256:equal")
            #expect(verified.targetFingerprint == "sha256:equal")
            #expect(verified.verifiedAt == now)
            #expect(verified.lastErrorCode == nil)
            #expect(try await store.load(migrationID: request.migrationID) == verified)

            let retentionMigrationID = UUID(uuidString: "00000000-0000-0000-0000-000000000b03")!
            let retentionUser = UUID(uuidString: "00000000-0000-0000-0000-000000000b04")!
            try await sql.raw("""
                INSERT INTO im_v2.user_shard_migrations
                    (migration_id, user_id, source_bucket, target_bucket, source_router_epoch, phase,
                     source_fingerprint, target_fingerprint, verified_at, retention_until, created_at, updated_at)
                VALUES
                    (\(bind: retentionMigrationID), \(bind: retentionUser), 'users-old', 'users-new', 12, 'retention',
                     'sha256:equal', 'sha256:equal', \(bind: now), \(bind: now.addingTimeInterval(-1)), \(bind: now), \(bind: now))
                """).run()
            let claimedRetention = try await store.claimExpiredRetention(now: now, leaseDuration: 30, limit: 1)
            #expect(claimedRetention.count == 1)
            #expect(claimedRetention.first?.record.migrationID == retentionMigrationID)
            #expect(try await store.completeRetention(try #require(claimedRetention.first), now: now))
            #expect(try await store.load(migrationID: retentionMigrationID)?.phase == .completed)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("cross-store user projection copy verifies every sync-owned record before source cleanup")
    func crossStoreUserProjectionTransferIsIdempotentAndVerified() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        let sourceSchema = "im_v2_source_transfer"
        let targetSchema = "im_v2_target_transfer"
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql, schema: sourceSchema)
            try await installSchema(on: sql, schema: targetSchema)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let user = UUID(uuidString: "00000000-0000-0000-0000-000000000c01")!
            let device = UUID(uuidString: "00000000-0000-0000-0000-000000000c02")!
            let eventOne = UUID(uuidString: "00000000-0000-0000-0000-000000000c03")!
            let eventTwo = UUID(uuidString: "00000000-0000-0000-0000-000000000c04")!
            let snapshot = UUID(uuidString: "00000000-0000-0000-0000-000000000c05")!
            try await seedTransferProjection(
                schema: sourceSchema, user: user, device: device, eventOne: eventOne,
                eventTwo: eventTwo, snapshot: snapshot, now: now, on: sql
            )

            let record = V2UserShardMigrationRecord(
                migrationID: UUID(uuidString: "00000000-0000-0000-0000-000000000c06")!, userID: try UserID(user.uuidString),
                sourceBucket: "users-source", targetBucket: "users-target", sourceRouterEpoch: 4,
                phase: .prepared, sourceFingerprint: nil, targetFingerprint: nil
            )
            let transfer = try PostgresV2UserShardProjectionTransfer(
                source: app.db(.psql), target: app.db(.psql),
                sourceBucket: "users-source", targetBucket: "users-target",
                sourceSchema: sourceSchema, targetSchema: targetSchema, pageSize: 1
            )
            try await transfer.copy(record)
            try await transfer.copy(record)
            let fingerprints = try await transfer.fingerprints(for: record)
            #expect(fingerprints.source == fingerprints.target)
            #expect(try await scopedCount(targetSchema, "user_sync_log", user: user, on: sql) == 2)
            #expect(try await scopedCount(targetSchema, "consumer_inbox", user: user, on: sql) == 1)
            #expect(try await scopedCount(targetSchema, "sync_snapshots", user: user, on: sql) == 1)
            #expect(try await scopedCount(targetSchema, "sync_tokens", user: user, on: sql) == 1)
            #expect(try await scopedCount(targetSchema, "sync_receipts", user: user, on: sql) == 1)

            let retained = V2UserShardMigrationRecord(
                migrationID: record.migrationID, userID: record.userID, sourceBucket: record.sourceBucket, targetBucket: record.targetBucket,
                sourceRouterEpoch: record.sourceRouterEpoch, phase: .retention,
                sourceFingerprint: fingerprints.source, targetFingerprint: fingerprints.target,
                retentionUntil: now
            )
            try await transfer.cleanSource(for: retained)
            #expect(try await scopedCount(sourceSchema, "user_sync_log", user: user, on: sql) == 0)
            #expect(try await scopedCount(targetSchema, "user_sync_log", user: user, on: sql) == 2)
            try await sql.raw("DROP SCHEMA \(unsafeRaw: sourceSchema) CASCADE").run()
            try await sql.raw("DROP SCHEMA \(unsafeRaw: targetSchema) CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS \(unsafeRaw: sourceSchema) CASCADE").run()
                try? await sql.raw("DROP SCHEMA IF EXISTS \(unsafeRaw: targetSchema) CASCADE").run()
            }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("cross-store fanout retries a target projection without duplicating its sync effect")
    func crossStoreFanoutProjectsToRoutedSchemaAndFencesControlCompletion() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              let secondaryDatabaseURL = Environment.get("IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            let secondaryID = DatabaseID(string: "secondary")
            app.databases.use(try .postgres(url: secondaryDatabaseURL, maxConnectionsPerEventLoop: 1), as: secondaryID)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard let secondarySQL = app.db(secondaryID) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            guard (try await secondarySQL.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            try await installSchema(on: secondarySQL)
            try await seedRoom(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try RoomCapacityProfile(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100,
                maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10,
                maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3
            )
            let message = try await V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: app.db(.psql)),
                capacityProfile: .init(id: "standard", limits: profile), limits: .init(maxUTF8Bytes: 64), now: { now }
            ).send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "remote"))
            guard case .accepted = message else {
                Issue.record("expected accepted message")
                return
            }
            let trigger = try #require(try await sql.raw("""
                SELECT source_event_id, plan_id FROM im_v2.room_outbox
                """).first(decoding: TriggerRow.self))
            let sourceRoute = try V2UserShardRoute(bucket: "users-source", observedRouterEpoch: 1)
            _ = try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(
                    database: app.db(.psql), router: V2SingleUserShardRouter(route: sourceRoute)
                ), pageSize: 10, now: { now.addingTimeInterval(1) }
            ).plan(.init(sourceEventID: try .init(trigger.sourceEventID.uuidString), planID: try .init(trigger.planID.uuidString)))

            let control = PostgresV2FanoutDeliveryStore(database: app.db(.psql))
            let migrations = PostgresV2UserShardMigrationStore(database: app.db(.psql))
            let migration = try await migrations.prepare(.init(
                migrationID: UUID(uuidString: "00000000-0000-0000-0000-000000000f01")!, userID: senderID,
                sourceBucket: "users-source", targetBucket: "users-remote", sourceRouterEpoch: 1
            ), now: now)
            _ = try await migrations.advance(migrationID: migration.migrationID, expectedPhase: .prepared, action: .beginCopy, fingerprints: nil, now: now)
            _ = try await migrations.advance(migrationID: migration.migrationID, expectedPhase: .copying, action: .copySucceeded, fingerprints: nil, now: now)
            _ = try await migrations.advance(migrationID: migration.migrationID, expectedPhase: .copied, action: .beginVerification, fingerprints: nil, now: now)
            _ = try await migrations.advance(migrationID: migration.migrationID, expectedPhase: .verifying, action: .verificationSucceeded, fingerprints: ("initial", "initial"), now: now)
            let registry = try V2StaticUserShardStorageRegistry(locations: [
                try .init(bucket: "users-source", database: app.db(.psql), schema: "im_v2"),
                try .init(bucket: "users-remote", database: app.db(secondaryID), schema: "im_v2"),
            ])
            // Model a process loss after the target transaction commits but
            // before the control-store completion transaction begins.
            let abandoned = try #require(try await control.claimPending(
                bucket: "users-source", now: now.addingTimeInterval(2), leaseDuration: 30, limit: 1
            ).first)
            let input = try #require(try await control.projectionInput(for: abandoned))
            let location = try registry.location(for: "users-source")
            _ = try await PostgresV2UserShardFanoutProjector(
                database: location.database, schema: location.schema
            ).project(input, now: now.addingTimeInterval(2))
            try await control.release(abandoned)

            let report = try await V2FanoutDeliveryWorker(
                store: V2CrossStoreFanoutDeliveryStore(
                    control: control, registry: registry,
                    migrations: migrations
                ),
                bucket: "users-source", now: { now.addingTimeInterval(3) }
            ).runOnce(limit: 10)
            #expect(report == .init(claimedCount: 3, committedCount: 3, staleCount: 0, releasedCount: 0))
            #expect(try await scopedCount("im_v2", "user_sync_log", user: senderUUID, on: secondarySQL) == 1)
            #expect(try await scopedCount("im_v2", "consumer_inbox", user: senderUUID, on: secondarySQL) == 1)
            #expect(try await scopedCount("im_v2", "user_sync_log", user: senderUUID, on: sql) == 1)
            #expect(try await count("im_v2.fanout_deliveries", on: sql) == 3)
            let transfer = try PostgresV2UserShardProjectionTransfer(
                source: app.db(.psql), target: app.db(secondaryID),
                sourceBucket: "users-source", targetBucket: "users-remote",
                sourceSchema: "im_v2", targetSchema: "im_v2"
            )
            let verified = try await V2DurableUserShardMigrationCoordinator(
                store: migrations, copier: transfer, verifier: transfer, now: { now.addingTimeInterval(4) }
            ).verifyForwarding(migrationID: migration.migrationID)
            #expect(verified.phase == .verified)
            let terminal = try #require(try await sql.raw("""
                SELECT state FROM im_v2.fanout_plans WHERE source_event_id = \(bind: trigger.sourceEventID)
                """).first(decoding: PushStateRow.self))
            #expect(terminal.state == "terminal")

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await secondarySQL.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            if let secondarySQL = app.db(DatabaseID(string: "secondary")) as? any SQLDatabase {
                try? await secondarySQL.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("cross-store target database outage schedules durable retry and recovers exactly once")
    func crossStoreTargetDatabaseOutageRetriesBeforeControlCompletion() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              let secondaryDatabaseURL = Environment.get("IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            let secondaryID = DatabaseID(string: "secondary")
            app.databases.use(try .postgres(url: secondaryDatabaseURL, maxConnectionsPerEventLoop: 1), as: secondaryID)
            // There is deliberately no PostgreSQL listener in the test
            // container at this endpoint. This is a real TCP connection
            // refusal against an independently-addressed target, not a mock
            // projector error.
            let unavailableID = DatabaseID(string: "secondary-unavailable")
            app.databases.use(
                try .postgres(
                    url: "postgres://im_v2_test:im_v2_test@127.0.0.1:1/im_v2_secondary_test",
                    maxConnectionsPerEventLoop: 1
                ),
                as: unavailableID
            )
            guard let sql = app.db(.psql) as? any SQLDatabase,
                  let secondarySQL = app.db(secondaryID) as? any SQLDatabase
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false,
                  (try await secondarySQL.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false
            else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await installSchema(on: secondarySQL)
            try await seedRoom(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_050)
            let profile = try RoomCapacityProfile(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100,
                maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10,
                maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3
            )
            let message = try await V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: app.db(.psql)),
                capacityProfile: .init(id: "standard", limits: profile), limits: .init(maxUTF8Bytes: 64), now: { now }
            ).send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "target-outage"))
            guard case .accepted = message else {
                Issue.record("expected accepted message")
                return
            }
            let trigger = try #require(try await sql.raw("SELECT source_event_id, plan_id FROM im_v2.room_outbox").first(decoding: TriggerRow.self))
            let remoteRoute = try V2UserShardRoute(bucket: "users-remote", observedRouterEpoch: 1)
            _ = try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: V2SingleUserShardRouter(route: remoteRoute)),
                pageSize: 10,
                now: { now.addingTimeInterval(1) }
            ).plan(.init(sourceEventID: try .init(trigger.sourceEventID.uuidString), planID: try .init(trigger.planID.uuidString)))

            let control = PostgresV2FanoutDeliveryStore(database: app.db(.psql))
            let migrations = PostgresV2UserShardMigrationStore(database: app.db(.psql))
            let retryPolicy = V2DurableRetryPolicy(initialDelay: 1, maximumDelay: 1, maximumAttempts: 2, jitterFraction: 0)
            let unavailableRegistry = try V2StaticUserShardStorageRegistry(locations: [
                try .init(bucket: "users-remote", database: app.db(unavailableID), schema: "im_v2"),
            ])
            let outage = try await V2FanoutDeliveryWorker(
                store: V2CrossStoreFanoutDeliveryStore(control: control, registry: unavailableRegistry, migrations: migrations),
                bucket: "users-remote", retryPolicy: retryPolicy, now: { now.addingTimeInterval(2) }
            ).runOnce(limit: 10)
            #expect(outage == .init(claimedCount: 3, committedCount: 0, staleCount: 0, releasedCount: 3))
            #expect(try await count("im_v2.user_sync_log", on: secondarySQL) == 0)
            let retryState = try #require(try await sql.raw("""
                SELECT state, retry_count FROM im_v2.fanout_deliveries
                WHERE source_event_id = \(bind: trigger.sourceEventID)
                ORDER BY target_user_id LIMIT 1
                """).first(decoding: DurableRetryStateRow.self))
            #expect(retryState.state == "pending")
            #expect(retryState.retryCount == 1)

            let recoveredRegistry = try V2StaticUserShardStorageRegistry(locations: [
                try .init(bucket: "users-remote", database: app.db(secondaryID), schema: "im_v2"),
            ])
            let recovered = try await V2FanoutDeliveryWorker(
                store: V2CrossStoreFanoutDeliveryStore(control: control, registry: recoveredRegistry, migrations: migrations),
                bucket: "users-remote", retryPolicy: retryPolicy, now: { now.addingTimeInterval(4) }
            ).runOnce(limit: 10)
            #expect(recovered == .init(claimedCount: 3, committedCount: 3, staleCount: 0, releasedCount: 0))
            #expect(try await count("im_v2.user_sync_log", on: secondarySQL) == 3)
            #expect(try await count("im_v2.consumer_inbox", on: secondarySQL) == 3)
            let terminal = try #require(try await sql.raw("""
                SELECT state FROM im_v2.fanout_plans WHERE source_event_id = \(bind: trigger.sourceEventID)
                """).first(decoding: PushStateRow.self))
            #expect(terminal.state == "terminal")

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await secondarySQL.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            if let secondarySQL = app.db(DatabaseID(string: "secondary")) as? any SQLDatabase { try? await secondarySQL.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("direct and social sync records shadow to a forwarding user shard with their source sequence")
    func forwardingShadowsDirectAndSocialUserSyncRecords() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              let secondaryDatabaseURL = Environment.get("IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            let secondaryID = DatabaseID(string: "secondary")
            app.databases.use(try .postgres(url: secondaryDatabaseURL, maxConnectionsPerEventLoop: 1), as: secondaryID)
            guard let sql = app.db(.psql) as? any SQLDatabase,
                  let secondarySQL = app.db(secondaryID) as? any SQLDatabase
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false,
                  (try await secondarySQL.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false
            else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await installSchema(on: secondarySQL)

            let now = Date(timeIntervalSince1970: 1_750_000_100)
            let migrations = PostgresV2UserShardMigrationStore(database: app.db(.psql))
            let migration = try await migrations.prepare(.init(
                migrationID: UUID(uuidString: "00000000-0000-0000-0000-000000000f11")!, userID: senderID,
                sourceBucket: "users-source", targetBucket: "users-target", sourceRouterEpoch: 1
            ), now: now)
            _ = try await migrations.advance(migrationID: migration.migrationID, expectedPhase: .prepared, action: .beginCopy, fingerprints: nil, now: now)
            _ = try await migrations.advance(migrationID: migration.migrationID, expectedPhase: .copying, action: .copySucceeded, fingerprints: nil, now: now)
            _ = try await migrations.advance(migrationID: migration.migrationID, expectedPhase: .copied, action: .beginVerification, fingerprints: nil, now: now)
            _ = try await migrations.advance(migrationID: migration.migrationID, expectedPhase: .verifying, action: .verificationSucceeded, fingerprints: ("initial", "initial"), now: now)
            let registry = try V2StaticUserShardStorageRegistry(locations: [
                try .init(bucket: "users-source", database: app.db(.psql), schema: "im_v2"),
                try .init(bucket: "users-target", database: app.db(secondaryID), schema: "im_v2"),
            ])
            let router = V2PostgresUserShardRouter(database: app.db(.psql))
            try await router.bootstrap(defaultRoute: .init(bucket: "users-source", observedRouterEpoch: 1), now: now)
            let shadow = V2PostgresUserShardProjectionShadowForwarder(
                control: app.db(.psql), router: router,
                migrations: migrations, registry: registry
            )
            let direct = PostgresV2DirectMessagingStore(database: app.db(.psql), shadowForwarder: shadow)
            let preferenceOperation = try StrangerMessagePreferenceOperationID("00000000-0000-0000-0000-000000000f12")
            _ = try await direct.setStrangerMessagePermission(
                command: .init(actorUserID: senderID, operationID: preferenceOperation, permission: .deny), now: now
            )
            // A response-loss retry sees the control-plane operation and must
            // reuse, rather than duplicate, the mirrored sync record.
            _ = try await direct.setStrangerMessagePermission(
                command: .init(actorUserID: senderID, operationID: preferenceOperation, permission: .deny), now: now.addingTimeInterval(1)
            )
            let social = PostgresV2SocialRelationshipStore(database: app.db(.psql), shadowForwarder: shadow)
            _ = try await social.changeRelationship(.init(
                actorUserID: senderID, operationID: try .init("00000000-0000-0000-0000-000000000f13"),
                targetUserID: try .init(memberTwoUUID.uuidString), action: .request
            ), now: now.addingTimeInterval(2))

            #expect(try await scopedCount("im_v2", "user_sync_log", user: senderUUID, on: sql) == 2)
            #expect(try await scopedCount("im_v2", "user_sync_log", user: senderUUID, on: secondarySQL) == 2)
            let targetRows = try await secondarySQL.raw("""
                SELECT user_sync_sequence, projection_kind
                FROM im_v2.user_sync_log WHERE user_id = \(bind: senderUUID)
                ORDER BY user_sync_sequence
                """).all(decoding: SyncKindRow.self)
            #expect(targetRows.map(\.sequence) == [1, 2])
            #expect(targetRows.map(\.kind) == ["stranger_message_permission", "relationship"])

            let transfer = try PostgresV2UserShardProjectionTransfer(
                source: app.db(.psql), target: app.db(secondaryID),
                sourceBucket: "users-source", targetBucket: "users-target"
            )
            let verified = try await V2DurableUserShardMigrationCoordinator(
                store: migrations, copier: transfer, verifier: transfer, now: { now.addingTimeInterval(3) }
            ).verifyForwarding(migrationID: migration.migrationID)
            #expect(verified.phase == .verified)
            _ = try await V2PostgresUserShardRouteControl(
                database: app.db(.psql), operatorPrincipal: "router-test"
            ).cutOver(.init(
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000f14")!, userID: senderID,
                expectedRouterEpoch: 1, newWriteBucket: "users-target", readFallbackBucket: "users-source"
            ), now: now.addingTimeInterval(4))
            // A target-owned fan-out effect consumes the next target sequence.
            // The following direct setting must allocate after it rather than
            // reuse the control store's now-stale source counter.
            _ = try await PostgresV2UserShardFanoutProjector(
                database: app.db(secondaryID), schema: "im_v2"
            ).project(.init(
                sourceEventID: try .init("00000000-0000-0000-0000-000000000f16"), targetUserID: senderID,
                projectionKind: "room_event", eventPayloadJSON: #"{"event_type":"message"}"#
            ), now: now.addingTimeInterval(4))
            _ = try await direct.setStrangerMessagePermission(
                command: .init(
                    actorUserID: senderID, operationID: try .init("00000000-0000-0000-0000-000000000f15"), permission: .allow
                ), now: now.addingTimeInterval(5)
            )
            #expect(try await scopedCount("im_v2", "user_sync_log", user: senderUUID, on: secondarySQL) == 4)
            let postCutover = try #require(try await secondarySQL.raw("""
                SELECT user_sync_sequence, projection_kind FROM im_v2.user_sync_log
                WHERE user_id = \(bind: senderUUID) ORDER BY user_sync_sequence DESC LIMIT 1
                """).first(decoding: SyncKindRow.self))
            #expect(postCutover.sequence == 4)
            #expect(postCutover.kind == "stranger_message_permission")
            #expect((try await router.routes(for: [senderID])).first?.bucket == "users-target")

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await secondarySQL.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            if let secondarySQL = app.db(DatabaseID(string: "secondary")) as? any SQLDatabase { try? await secondarySQL.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("password fallback failure limits persist across account-service instances")
    func persistsPasswordLoginFailureLimit() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else {
            return
        }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2PasswordLoginRateLimitError.unavailable
            }
            let schemaExists = try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self)
            guard schemaExists?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let policy = try V2PasswordLoginRateLimitPolicy(maximumFailures: 2, window: 60, lockout: 60)
            let firstInstance = V2PostgresPasswordLoginAttemptLimiter(database: app.db(.psql), policy: policy)
            let secondInstance = V2PostgresPasswordLoginAttemptLimiter(database: app.db(.psql), policy: policy)
            #expect(try await firstInstance.blockedRetryAfterSeconds(accountHandle: "limit-test") == nil)
            try await firstInstance.recordFailure(accountHandle: "limit-test")
            #expect(try await secondInstance.blockedRetryAfterSeconds(accountHandle: "limit-test") == nil)
            try await secondInstance.recordFailure(accountHandle: "limit-test")
            let retryAfter = try #require(try await firstInstance.blockedRetryAfterSeconds(accountHandle: "limit-test"))
            #expect((1 ... 60).contains(retryAfter))
            try await secondInstance.reset(accountHandle: "limit-test")
            #expect(try await firstInstance.blockedRetryAfterSeconds(accountHandle: "limit-test") == nil)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await app.asyncShutdown()
            throw error
        }
    }

    private func installSchema(on sql: any SQLDatabase, schema: String = "im_v2") async throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schemaDirectory = repositoryRoot.appending(path: "IMV2/sql", directoryHint: .isDirectory)
        let migrations = try FileManager.default.contentsOfDirectory(
            at: schemaDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.range(of: "^[0-9]{4}_.+\\.sql$", options: .regularExpression) != nil }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for schemaURL in migrations {
            let source = try String(contentsOf: schemaURL, encoding: .utf8)
                .replacingOccurrences(of: "im_v2", with: schema)
            let executableSQL = source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
                .joined(separator: "\n")
            for fragment in executableSQL.split(separator: ";") {
                let statement = fragment
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !statement.isEmpty else { continue }
                try await sql.raw("\(unsafeRaw: statement)").run()
            }
        }
    }

    private func seedTransferProjection(
        schema: String, user: UUID, device: UUID, eventOne: UUID, eventTwo: UUID,
        snapshot: UUID, now: Date, on sql: any SQLDatabase
    ) async throws {
        try await sql.raw("INSERT INTO \(unsafeRaw: schema).user_sync_sequences (user_id, next_sequence) VALUES (\(bind: user), 2)").run()
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).user_sync_log
                (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
            VALUES (\(bind: user), 1, \(bind: eventOne), 'message', '{"body":"one"}'::jsonb, \(bind: now)),
                   (\(bind: user), 2, \(bind: eventTwo), 'message', '{"body":"two"}'::jsonb, \(bind: now))
            """).run()
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).consumer_inbox
                (consumer_name, source_event_id, target_user_id, projection_kind, committed_at)
            VALUES ('v2-fanout-delivery', \(bind: eventOne), \(bind: user), 'message', \(bind: now))
            """).run()
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).device_sync_cursors
                (user_id, device_id, state, reset_generation, acknowledged_sequence)
            VALUES (\(bind: user), \(bind: device), 'ready', 2, 1)
            """).run()
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).sync_snapshots
                (snapshot_id, user_id, device_id, reset_generation, base_user_sync_sequence, manifest_digest,
                 schema_version, capability_profile, next_sync_token, sync_receipt, expires_at, state, created_at)
            VALUES (\(bind: snapshot), \(bind: user), \(bind: device), 2, 1, 'manifest', 10, 'base', 'token-snapshot', 'receipt-snapshot',
                    \(bind: now.addingTimeInterval(600)), 'acknowledged', \(bind: now))
            """).run()
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).sync_snapshot_pages (snapshot_id, page_index, page_digest, payload)
            VALUES (\(bind: snapshot), 0, 'page', '\\x0102'::bytea)
            """).run()
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).sync_tokens
                (token, user_id, device_id, reset_generation, watermark, expires_at, created_at)
            VALUES ('token-1', \(bind: user), \(bind: device), 2, 2, \(bind: now.addingTimeInterval(600)), \(bind: now))
            """).run()
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).sync_receipts
                (receipt, user_id, device_id, reset_generation, first_sequence, last_sequence, expires_at, created_at)
            VALUES ('receipt-1', \(bind: user), \(bind: device), 2, 1, 2, \(bind: now.addingTimeInterval(600)), \(bind: now))
            """).run()
    }

    private func scopedCount(_ schema: String, _ table: String, user: UUID, on sql: any SQLDatabase) async throws -> Int {
        let column = table == "consumer_inbox" ? "target_user_id" : "user_id"
        let count = try await sql.raw("SELECT COUNT(*)::bigint AS value FROM \(unsafeRaw: schema).\(unsafeRaw: table) WHERE \(unsafeRaw: column) = \(bind: user)")
            .first(decoding: CountRow.self)?.value ?? 0
        guard let value = Int(exactly: count) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return value
    }

    private func seedRoom(on sql: any SQLDatabase) async throws {
        try await sql.raw("""
            INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id)
            VALUES (\(bind: roomUUID), 'room-a', 'standard')
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.group_rooms (room_id, owner_user_id, title, created_at)
            VALUES (\(bind: roomUUID), \(bind: senderUUID), '集成测试群', \(bind: Date(timeIntervalSince1970: 1_750_000_000)))
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.shard_admission_pools
                (room_shard_id, capacity_profile_id, lease_id, generation, valid_until,
                 command_window_limit, fanout_window_limit, max_outstanding_fanout_units, max_outstanding_plans)
            VALUES ('room-a', 'standard', \(bind: leaseUUID), 1, \(bind: Date(timeIntervalSince1970: 1_750_000_100)), 10, 100, 100, 10)
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.room_admission
                (room_id, eligible_member_count, command_window_limit, fanout_window_limit,
                 max_outstanding_fanout_units, max_outstanding_plans, shard_lease_id, shard_lease_generation)
            VALUES (\(bind: roomUUID), 3, 10, 100, 100, 10, \(bind: leaseUUID), 1)
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision)
            VALUES (\(bind: roomUUID), \(bind: senderUUID), 0)
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision)
            VALUES (\(bind: roomUUID), \(bind: memberTwoUUID), 0),
                   (\(bind: roomUUID), \(bind: memberThreeUUID), 0)
            """).run()
    }

    private func count(_ table: String, on sql: any SQLDatabase) async throws -> Int64 {
        try #require(try await sql.raw("SELECT COUNT(*) AS value FROM \(unsafeRaw: table)").first(decoding: CountRow.self)).value
    }
}

private let roomUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
private let senderUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
private let clientUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
private let leaseUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000014")!
private let memberTwoUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000015")!
private let memberThreeUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000016")!
private let roomID = try! RoomID(roomUUID.uuidString)
private let senderID = try! UserID(senderUUID.uuidString)
private let clientMessageID = try! ClientMessageID(clientUUID.uuidString)
private let deviceID = try! DeviceID("00000000-0000-0000-0000-000000000017")
private let snapshotID = try! SnapshotID("00000000-0000-0000-0000-000000000018")
private let testUserShardRouter = V2SingleUserShardRouter(route: try! .init(bucket: "test-users", observedRouterEpoch: 9))

/// The recovery soak uses one deterministic logical bucket per 1,000-member
/// completion unit. This is test-only routing: it lets the test abandon and
/// reclaim one unit without a globally ordered worker also claiming the next
/// unit in the same batch.
private struct CompletionUnitRecoveryTestRouter: V2UserShardRouter {
    func routes(for users: [UserID]) async throws -> [V2UserShardRoute] {
        try users.map { user in
            guard let value = UUID(uuidString: user.rawValue)?.uuidString
                .split(separator: "-").last
                .flatMap({ Int($0, radix: 16) }),
                (1...100_000).contains(value)
            else { throw V2UserShardRouterError.invalidRoute }
            return try .init(bucket: "recovery-\((value - 1) / 1_000)", observedRouterEpoch: 1)
        }
    }
}

private enum PlannerInterruption: Error { case afterFirstCheckpoint }

/// Deterministically fails on the second UUID-sorted seeded member. The first
/// page therefore commits before this throws, which models a planner process
/// disappearing between independently durable enumeration transactions.
private struct FailsOnSecondPageRouter: V2UserShardRouter {
    let blockedUserID: UserID

    func routes(for users: [UserID]) async throws -> [V2UserShardRoute] {
        if users.contains(blockedUserID) { throw PlannerInterruption.afterFirstCheckpoint }
        return Array(repeating: try .init(bucket: "test-users", observedRouterEpoch: 9), count: users.count)
    }
}

private struct ExistsRow: Decodable { let exists: Bool }
private struct CountRow: Decodable { let value: Int64 }
private struct DurableRetryStateRow: Decodable {
    let state: String
    let retryCount: Int64
    enum CodingKeys: String, CodingKey { case state; case retryCount = "retry_count" }
}
private struct FanoutScaleAccountingRow: Decodable {
    let completionUnits: Int64
    let completionTargets: Int64
    let deliveries: Int64
    let distinctDeliveries: Int64
    let planState: String
    enum CodingKeys: String, CodingKey {
        case completionUnits = "completion_units"
        case completionTargets = "completion_targets"
        case deliveries
        case distinctDeliveries = "distinct_deliveries"
        case planState = "plan_state"
    }
}
private struct FanoutDeliveryScaleAccountingRow: Decodable {
    let syncRecords: Int64
    let distinctSyncRecipients: Int64
    let inboxRecords: Int64
    let terminalDeliveries: Int64
    let releasedCompletionUnits: Int64
    let planState: String
    enum CodingKeys: String, CodingKey {
        case syncRecords = "sync_records"
        case distinctSyncRecipients = "distinct_sync_recipients"
        case inboxRecords = "inbox_records"
        case terminalDeliveries = "terminal_deliveries"
        case releasedCompletionUnits = "released_completion_units"
        case planState = "plan_state"
    }
}
private struct CapacityRow: Decodable {
    let commandWindowUsed: Int
    let fanoutWindowUsed: Int
    enum CodingKeys: String, CodingKey { case commandWindowUsed = "command_window_used", fanoutWindowUsed = "fanout_window_used" }
}
private struct TriggerRow: Decodable {
    let sourceEventID: UUID
    let planID: UUID
    enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id", planID = "plan_id" }
}
private struct PlanningCheckpointAssertionRow: Decodable {
    let state: String
    let afterUserID: String?
    enum CodingKeys: String, CodingKey {
        case state
        case afterUserID = "after_user_id"
    }
}
private struct DeliveryRouteRow: Decodable, Equatable {
    let bucket: String
    let epoch: Int64
    enum CodingKeys: String, CodingKey { case bucket = "target_shard_bucket", epoch = "observed_router_epoch" }
}
private struct HandoffRouteRow: Decodable {
    let bucket: String
    let epoch: Int64
    let unclaimed: Bool
    enum CodingKeys: String, CodingKey {
        case bucket = "target_shard_bucket"
        case epoch = "observed_router_epoch"
        case unclaimed
    }
}
private struct OutstandingRow: Decodable {
    let outstandingFanoutUnits: Int
    let outstandingPlans: Int
    enum CodingKeys: String, CodingKey { case outstandingFanoutUnits = "outstanding_fanout_units", outstandingPlans = "outstanding_plans" }
}
private struct AdmissionFenceRow: Decodable {
    let shardLeaseID: UUID
    let shardLeaseGeneration: Int64
    enum CodingKeys: String, CodingKey { case shardLeaseID = "shard_lease_id", shardLeaseGeneration = "shard_lease_generation" }
}
private struct StrangerWindowAssertionRow: Decodable {
    let messageCount: Int
    enum CodingKeys: String, CodingKey { case messageCount = "message_count" }
}
private enum StrangerMessageAttempt: Equatable, Sendable {
    case accepted
    case limited
    case unexpectedOutcome
    case unexpectedFailure
}
private enum MessageMutationRaceOutcome: Equatable, Sendable {
    case edited
    case withdrawn
    case revisionConflict
    case alreadyWithdrawn
    case unexpectedOutcome
    case unexpectedFailure
}
private struct RelationshipAssertionRow: Decodable {
    let state: String; let requestedByUserID: UUID
    enum CodingKeys: String, CodingKey { case state; case requestedByUserID = "requested_by_user_id" }
}
private struct MembershipRevisionRow: Decodable {
    let membershipRevision: Int64
    let roomSequence: Int64
    enum CodingKeys: String, CodingKey { case membershipRevision = "membership_revision", roomSequence = "room_sequence" }
}
private struct MembershipTargetStateRow: Decodable {
    let role: String
    let joinedRevision: Int64
    enum CodingKeys: String, CodingKey { case role, joinedRevision = "joined_revision" }
}
private struct LeftRevisionRow: Decodable {
    let leftRevision: Int64?
    enum CodingKeys: String, CodingKey { case leftRevision = "left_revision" }
}
private struct MembershipEventRow: Decodable {
    let eventType: String
    let action: String
    enum CodingKeys: String, CodingKey { case eventType = "event_type", action }
}
private struct WithdrawalMessageStateRow: Decodable {
    let contentRevision: Int64
    let withdrawnByUserID: UUID
    enum CodingKeys: String, CodingKey { case contentRevision = "content_revision", withdrawnByUserID = "withdrawn_by_user_id" }
}
private struct WithdrawalEventRow: Decodable {
    let eventType: String
    let messageID: String
    let withdrawn: String
    enum CodingKeys: String, CodingKey { case eventType = "event_type", messageID = "message_id", withdrawn }
}
private struct ReactionEventRow: Decodable {
    let eventType: String
    let messageID: String
    let reaction: String
    let action: String
    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case messageID = "message_id"
        case reaction, action
    }
}
private struct EditMessageStateRow: Decodable {
    let text: String; let revision: Int64
    enum CodingKeys: String, CodingKey { case text = "text_body", revision = "content_revision" }
}
private struct TombstonedEditStateRow: Decodable {
    let text: String; let revision: Int64; let isWithdrawn: Bool
    enum CodingKeys: String, CodingKey { case text = "text_body", revision = "content_revision", isWithdrawn = "is_withdrawn" }
}
private struct EditEventRow: Decodable {
    let eventType: String; let text: String; let revision: String
    enum CodingKeys: String, CodingKey { case eventType = "event_type", text, revision }
}
private struct ReceiptStateAssertionRow: Decodable {
    let sequence: Int64
    enum CodingKeys: String, CodingKey { case sequence = "read_through_room_sequence" }
}
private struct PushStateRow: Decodable { let state: String }
private struct SyncKindRow: Decodable {
    let sequence: Int64
    let kind: String
    enum CodingKeys: String, CodingKey { case sequence = "user_sync_sequence", kind = "projection_kind" }
}
private struct EncryptedPushEndpointRow: Decodable {
    let encryptedToken: String
    enum CodingKeys: String, CodingKey { case encryptedToken = "encrypted_token" }
}
private struct PushRecoveryStateRow: Decodable {
    let state: String
    let retryCount: Int64
    let admittedAt: Date?
    enum CodingKeys: String, CodingKey {
        case state
        case retryCount = "retry_count"
        case admittedAt = "admitted_at"
    }
}
private struct TerminalOutboxStateRow: Decodable {
    let state: String
    let terminalized: Bool
}
private struct PushBudgetRow: Decodable {
    let usedWorkUnits: Int
    let usedNewKeyOperations: Int
    enum CodingKeys: String, CodingKey { case usedWorkUnits = "used_work_units", usedNewKeyOperations = "used_new_key_operations" }
}
private struct SyncedMessagePayloadRow: Decodable {
    let roomID: String
    let messageID: String
    let senderUserID: String
    let text: String
    let eventType: String
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case messageID = "message_id"
        case senderUserID = "sender_user_id"
        case text
        case eventType = "event_type"
    }
}
private struct MediaReferenceAssertionRow: Decodable {
    let messageID: UUID
    let mediaID: UUID
    let ordinal: Int
    enum CodingKeys: String, CodingKey { case messageID = "message_id", mediaID = "media_id", ordinal }
}
private struct MediaEventContainsRow: Decodable { let contains: Bool }
private struct MentionAssertionRow: Decodable { let userID: UUID; enum CodingKeys: String, CodingKey { case userID = "mentioned_user_id" } }
private struct ModerationEventAssertionRow: Decodable { let eventType: String; let messageID: String; enum CodingKeys: String, CodingKey { case eventType = "event_type", messageID = "message_id" } }
private struct ModerationAuditAssertionRow: Decodable { let action: String; let reasonCode: String; enum CodingKeys: String, CodingKey { case action; case reasonCode = "reason_code" } }
private struct ModerationMessageAssertionRow: Decodable { let withdrawn: Bool; let revision: Int64; enum CodingKeys: String, CodingKey { case withdrawn; case revision = "content_revision" } }
private struct MuteAssertionRow: Decodable { let muteUntil: Date; let actorUserID: UUID; enum CodingKeys: String, CodingKey { case muteUntil = "mute_until", actorUserID = "actor_user_id" } }
private struct MuteEventAssertionRow: Decodable { let eventType: String; let targetUserID: String; enum CodingKeys: String, CodingKey { case eventType = "event_type", targetUserID = "target_user_id" } }
private struct RemovedMembershipAssertionRow: Decodable { let leftRevision: Int64; enum CodingKeys: String, CodingKey { case leftRevision = "left_revision" } }
private struct ModeratedRemovalEventAssertionRow: Decodable { let eventType: String; let action: String; let targetUserID: String; enum CodingKeys: String, CodingKey { case eventType = "event_type", action, targetUserID = "target_user_id" } }
private struct FrozenRoomAssertionRow: Decodable { let frozenAt: Date?; let frozenByUserID: UUID?; enum CodingKeys: String, CodingKey { case frozenAt = "frozen_at", frozenByUserID = "frozen_by_user_id" } }
private struct FreezeProjectionRow: Decodable { let projectionKind: String; let eventType: String; enum CodingKeys: String, CodingKey { case projectionKind = "projection_kind", eventType = "event_type" } }
private struct ModerationDeliveredEventRow: Decodable { let eventType: String; enum CodingKeys: String, CodingKey { case eventType = "event_type" } }
private enum TestConfigurationError: Error { case schemaAlreadyExists }
