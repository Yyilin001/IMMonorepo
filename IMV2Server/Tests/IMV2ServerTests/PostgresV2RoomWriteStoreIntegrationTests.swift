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
    @Test("CI-required cross-store PostgreSQL endpoints are explicitly provisioned")
    func requiresCrossStorePostgresWhenConfigured() {
        guard Environment.get("IMV2_REQUIRE_CROSS_STORE_POSTGRES_TESTS") == "1" else { return }
        #expect(Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1")
        #expect(Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL")?.isEmpty == false)
        #expect(Environment.get("IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL")?.isEmpty == false)
        #expect(
            Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL") !=
            Environment.get("IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL")
        )
    }

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
            let nonFanoutSyncIdentityIndexExists = try #require(try await sql.raw("""
                SELECT to_regclass('im_v2.user_sync_log_nonfanout_identity_idx') IS NOT NULL AS exists
                """).first(decoding: ExistsRow.self))
            #expect(nonFanoutSyncIdentityIndexExists.exists)
            // The message table's room-sequence uniqueness indexes already
            // cover the only room-only existence probe.  A second
            // `(room_id, sender_user_id)` btree would add write amplification
            // to every accepted message without a selective read consumer.
            let redundantMessageRoomSenderIndexIsAbsent = try #require(
                try await sql.raw("""
                    SELECT to_regclass('im_v2.messages_room_sender_idx') IS NULL AS exists
                    """).first(decoding: ExistsRow.self)
            )
            #expect(redundantMessageRoomSenderIndexIsAbsent.exists)
            // A message accepted at a room sequence is represented by exactly
            // one `message.accepted` room event in the same transaction. The
            // room-event uniqueness constraint owns that invariant, while the
            // message table retains only its timeline-order index for reads.
            let redundantMessageRoomSequenceConstraintIsAbsent = try #require(
                try await sql.raw("""
                    SELECT NOT EXISTS (
                        SELECT 1
                        FROM pg_constraint
                        WHERE conname = 'messages_room_id_room_sequence_key'
                          AND conrelid = 'im_v2.messages'::regclass
                    ) AS exists
                    """).first(decoding: ExistsRow.self)
            )
            #expect(redundantMessageRoomSequenceConstraintIsAbsent.exists)
            let projectionReadyOrderIndexExists = try #require(try await sql.raw("""
                SELECT to_regclass(
                    'im_v2.user_projection_checkpoints_ready_order_idx'
                ) IS NOT NULL AS exists
                """).first(decoding: ExistsRow.self))
            #expect(projectionReadyOrderIndexExists.exists)
            let fullSyncIdentityConstraintIsAbsent = try #require(try await sql.raw("""
                SELECT NOT EXISTS (
                    SELECT 1 FROM pg_constraint
                    WHERE conname = 'user_sync_log_user_id_source_event_id_projection_kind_key'
                      AND conrelid = 'im_v2.user_sync_log'::regclass
                ) AS exists
                """).first(decoding: ExistsRow.self))
            #expect(fullSyncIdentityConstraintIsAbsent.exists)
            // Non-fan-out writers do not acquire `consumer_inbox`, so they
            // retain source-event semantic uniqueness.
            let nonFanoutUserID = UUID(uuidString: "00000000-0000-0000-0000-000000000e01")!
            let nonFanoutSourceEventID = UUID(uuidString: "00000000-0000-0000-0000-000000000e02")!
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                VALUES
                    (\(bind: nonFanoutUserID), 1, \(bind: nonFanoutSourceEventID), 'relationship', '{}'::jsonb, now())
                """).run()
            await #expect(throws: (any Error).self) {
                try await sql.raw("""
                    INSERT INTO im_v2.user_sync_log
                        (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                    VALUES
                        (\(bind: nonFanoutUserID), 2, \(bind: nonFanoutSourceEventID), 'relationship', '{}'::jsonb, now())
                    """).run()
            }
            try await sql.raw("""
                DELETE FROM im_v2.user_sync_log
                WHERE user_id = \(bind: nonFanoutUserID)
                  AND source_event_id = \(bind: nonFanoutSourceEventID)
                  AND projection_kind = 'relationship'
                """).run()
            // Staged group creation owns temporary audiences outside the room
            // bootstrap transaction. Verify its PostgreSQL admission and
            // lifecycle boundaries directly: actor quota, cancellation's
            // cascading member cleanup, and bounded expiry reclamation.
            let audienceStore = PostgresV2GroupAudienceImportStore(database: app.db(.psql))
            let audienceActor = try UserID("00000000-0000-0000-0000-000000000e10")
            let audienceOperationA = try GroupRoomOperationID("00000000-0000-0000-0000-000000000e11")
            let audienceOperationB = try GroupRoomOperationID("00000000-0000-0000-0000-000000000e12")
            let audienceMembers = [
                try UserID("00000000-0000-0000-0000-000000000e13"),
                try UserID("00000000-0000-0000-0000-000000000e14")
            ]
            let audienceNow = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, revision, created_at, updated_at)
                VALUES
                    (\(bind: UUID(uuidString: audienceActor.rawValue)!), 'audience_actor', '临时群创建者', 1, \(bind: audienceNow), \(bind: audienceNow)),
                    (\(bind: UUID(uuidString: audienceMembers[0].rawValue)!), 'audience_member_1', '临时群成员一', 1, \(bind: audienceNow), \(bind: audienceNow)),
                    (\(bind: UUID(uuidString: audienceMembers[1].rawValue)!), 'audience_member_2', '临时群成员二', 1, \(bind: audienceNow), \(bind: audienceNow))
                """).run()
            let audiencePolicy = V2GroupAudienceImportPolicy(
                maximumActiveDraftsPerActor: 1,
                maximumStagedMembersPerActor: 2,
                stagingLifetime: 10,
                completedRetention: 10
            )
            let staged = try await audienceStore.begin(
                actorUserID: audienceActor, operationID: audienceOperationA,
                title: "临时群", policy: audiencePolicy, now: audienceNow
            )
            #expect(staged.stagedMemberCount == 0)
            await #expect(throws: V2GroupAudienceImportError.activeDraftLimitReached) {
                try await audienceStore.begin(
                    actorUserID: audienceActor, operationID: audienceOperationB,
                    title: "第二个临时群", policy: audiencePolicy, now: audienceNow
                )
            }
            let appended = try await audienceStore.append(
                actorUserID: audienceActor, operationID: audienceOperationA,
                memberUserIDs: audienceMembers, maximumMembers: 2,
                policy: audiencePolicy, now: audienceNow
            )
            #expect(appended.stagedMemberCount == 2)
            try await audienceStore.cancel(actorUserID: audienceActor, operationID: audienceOperationA, now: audienceNow)
            let remainingAudienceMembers = try await sql.raw("""
                SELECT COUNT(*)::bigint AS value
                FROM im_v2.group_room_creation_draft_members
                WHERE actor_user_id = \(bind: UUID(uuidString: audienceActor.rawValue)!)
                """).first(decoding: CountRow.self)
            #expect(remainingAudienceMembers?.value == 0)
            _ = try await audienceStore.begin(
                actorUserID: audienceActor, operationID: audienceOperationB,
                title: "第二个临时群", policy: audiencePolicy, now: audienceNow
            )
            #expect(try await audienceStore.purgeExpired(now: audienceNow.addingTimeInterval(11), limit: 10) == 1)
            try await seedRoom(on: sql)

            let profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3)
            let store = PostgresV2RoomWriteStore(database: app.db(.psql))
            let service = V2SendMessageService(store: store, capacityProfile: try .init(id: "standard", limits: profile), limits: try .init(maxUTF8Bytes: 64), now: { Date(timeIntervalSince1970: 1_750_000_000) })
            let outcome = try await service.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "transactional"))
            guard case .accepted(let message) = outcome else {
                Issue.record("expected accepted message")
                return
            }
            // Standard fan-out keeps per-user sync as the reliable path, but
            // an active detail view may immediately pull this authorized room
            // event as a transient preview. This must be available before the
            // fan-out plan drains and must not depend on a Hybrid-only mode.
            let groupLog = V2GroupEventLogService(store: PostgresV2GroupEventLogStore(database: app.db(.psql)))
            let standardPreview = try await groupLog.pull(
                roomID: roomID,
                actorUserID: senderID,
                afterRoomSequence: 0,
                pageSize: 10
            )
            let standardSubscription = try await groupLog.subscribe(roomID: roomID, actorUserID: senderID)
            #expect(standardPreview.events.map(\.roomSequence) == [message.roomSequence])
            #expect(standardPreview.events.first?.projectionKind == "message")
            #expect(standardSubscription.highWatermark == message.roomSequence)
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
                store: PostgresV2FanoutPlanStore(database: app.db(.psql)),
                pageSize: 2,
                now: { Date(timeIntervalSince1970: 1_750_000_001) }
            ).plan(.init(sourceEventID: try .init(triggerRow.sourceEventID.uuidString), planID: try .init(triggerRow.planID.uuidString)))
            // First commit with the compatibility writer, then continue with
            // the reference writer. The second recipient must compact the
            // already-created shared row without changing its wire payload.
            let firstDelivery = try await V2FanoutDeliveryWorker(
                store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)),
                now: { Date(timeIntervalSince1970: 1_750_000_002) }
            ).runOnce(limit: 1)
            let outboxBeforeFinalDelivery = try #require(try await sql.raw("""
                SELECT state FROM im_v2.room_outbox
                WHERE source_event_id = \(bind: triggerRow.sourceEventID)
                """).first(decoding: PushStateRow.self))
            let referenceDeliveryStore = PostgresV2FanoutDeliveryStore(
                database: app.db(.psql),
                payloadWriteMode: .reference
            )
            let deliveryWorker = V2FanoutDeliveryWorker(
                store: referenceDeliveryStore,
                now: { Date(timeIntervalSince1970: 1_750_000_002) }
            )
            let delivery = try await deliveryWorker.runOnce(limit: 8)
            let completionRelease = try await V2FanoutCompletionReleaseWorker(
                store: referenceDeliveryStore,
                now: { Date(timeIntervalSince1970: 1_750_000_002) }
            ).runOnce(limit: 8)
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
            try await drainV3Projection(database: app.db(.psql))
            let projectionMessages = try await currentV3ProjectionItems(
                sql: sql, userID: senderID, kind: "message"
            )
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
            #expect(message.roomSequence == 1)
            #expect(replayAfterLeave == .idempotent(message))
            #expect(planning == .init(createdCompletionUnits: 2, createdDeliveries: 3, wasAlreadyPlanned: false))
            #expect(firstDelivery == .init(claimedCount: 1, committedCount: 1, staleCount: 0, releasedCount: 0))
            #expect(outboxBeforeFinalDelivery.state == "pending")
            #expect(delivery == .init(claimedCount: 2, committedCount: 2, staleCount: 0, releasedCount: 0))
            #expect(completionRelease == .init(releasedCount: 2, closedPlanCount: 1))
            #expect(terminalOutbox.state == "terminal")
            #expect(terminalOutbox.terminalized)
            #expect(deliveryRoutes == [.init(bucket: "test-users", epoch: 9)])
            #expect(initialGeneration == 1)
            #expect(records.count == 1)
            #expect(projectionMessages.count == 1)
            #expect(projectionMessages.first?.entityKey == message.messageID.rawValue)
            #expect(projectionMessages.first?.string("text") == "transactional")
            #expect(duplicateRecords.isEmpty)
            #expect(hasMore == false)
            #expect(try await count("im_v2.messages", on: sql) == 1)
            #expect(try await count("im_v2.room_events", on: sql) == 1)
            #expect(try await count(
                "im_v2.message_projection_states WHERE payload_storage = 'room_event' AND payload IS NULL",
                on: sql
            ) == 1)
            #expect(try await count(
                "im_v2.message_projection_state_values AS state JOIN im_v2.room_events AS event ON event.event_id = state.state_event_id WHERE state.payload = event.payload",
                on: sql
            ) == 1)
            #expect(try await count("im_v2.fanout_plans", on: sql) == 1)
            #expect(try await count("im_v2.room_outbox", on: sql) == 1)
            #expect(try await count("im_v2.fanout_completion_units", on: sql) == 2)
            #expect(try await count("im_v2.fanout_deliveries", on: sql) == 3)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 3)
            let syncedRecord = try #require(records.first)
            #expect(syncedRecord.sourceEventID.rawValue == triggerRow.sourceEventID.uuidString)
            #expect(syncedRecord.projectionKind == "message")
            let syncedMessage = try #require(try await sql.raw("""
                SELECT effective.payload->>'room_id' AS room_id,
                       effective.payload->>'message_id' AS message_id,
                       effective.payload->>'sender_user_id' AS sender_user_id,
                       effective.payload->>'text' AS text,
                       effective.payload->>'event_type' AS event_type
                FROM im_v2.user_sync_log AS log
                JOIN im_v2.fanout_sync_payloads AS shared
                  ON shared.source_event_id = log.source_event_id
                 AND shared.projection_kind = log.projection_kind
                LEFT JOIN im_v2.message_projection_state_values AS state
                  ON state.state_id = shared.message_state_id
                CROSS JOIN LATERAL (
                    SELECT COALESCE(shared.payload, state.payload) AS payload
                ) AS effective
                WHERE log.projection_kind = 'message'
                LIMIT 1
                """).first(decoding: SyncedMessagePayloadRow.self))
            #expect(syncedMessage.roomID == roomUUID.uuidString)
            #expect(syncedMessage.messageID == message.messageID.rawValue)
            #expect(syncedMessage.senderUserID == senderUUID.uuidString)
            #expect(syncedMessage.text == "transactional")
            #expect(syncedMessage.eventType == "message.accepted")
            let payloadEnvelope = try #require(try await sql.raw("""
                SELECT log.payload IS NULL AS has_null_log_payload,
                       log.payload_storage AS payload_storage,
                       effective.payload ? 'source_event_id' AS has_source_event_id,
                       effective.payload ? 'projection_kind' AS has_projection_kind
                FROM im_v2.user_sync_log AS log
                JOIN im_v2.fanout_sync_payloads AS shared
                  ON shared.source_event_id = log.source_event_id
                 AND shared.projection_kind = log.projection_kind
                LEFT JOIN im_v2.message_projection_state_values AS state
                  ON state.state_id = shared.message_state_id
                CROSS JOIN LATERAL (
                    SELECT COALESCE(shared.payload, state.payload) AS payload
                ) AS effective
                WHERE log.projection_kind = 'message'
                LIMIT 1
                """).first(decoding: SyncPayloadEnvelopeRow.self))
            #expect(payloadEnvelope.hasNullLogPayload)
            #expect(payloadEnvelope.payloadStorage == "fanout_shared")
            #expect(!payloadEnvelope.hasSourceEventID)
            #expect(!payloadEnvelope.hasProjectionKind)
            // Existing expand-migration rows start inline. Rehydrate this
            // accepted row to that shape, then prove bounded compaction keeps
            // the logical payload identical and makes the source event
            // immutable at the database boundary.
            try await sql.raw("""
                UPDATE im_v2.message_projection_states AS state
                SET payload = event.payload,
                    payload_storage = 'inline'
                FROM im_v2.room_events AS event
                WHERE event.event_id = state.state_event_id
                """).run()
            let bodyCompaction = PostgresV2MessageProjectionStateBodyCompactionWorker(
                database: app.db(.psql)
            )
            #expect(try await bodyCompaction.runOnce(limit: 10) == .init(compactedCount: 1))
            #expect(try await bodyCompaction.runOnce(limit: 10) == .init(compactedCount: 0))
            #expect(try await count(
                "im_v2.message_projection_states WHERE payload_storage = 'room_event' AND payload IS NULL",
                on: sql
            ) == 1)
            let logicalStateAfterCompaction = try #require(
                try await PostgresV2MessageProjectionStateRepository().load(
                    messageID: UUID(uuidString: message.messageID.rawValue)!,
                    revision: 1,
                    sql: sql
                )
            )
            #expect(logicalStateAfterCompaction.payloadJSON.contains("transactional"))
            await #expect(throws: (any Error).self) {
                try await sql.raw("""
                    UPDATE im_v2.room_events
                    SET payload = payload || '{"text":"tampered"}'::jsonb
                    WHERE event_id = \(bind: triggerRow.sourceEventID)
                    """).run()
            }
            #expect(try await count(
                "im_v2.fanout_sync_payloads WHERE projection_kind = 'message' AND payload IS NULL AND message_state_id IS NOT NULL",
                on: sql
            ) == 1)
            #expect(try await count(
                "im_v2.fanout_sync_payloads AS shared JOIN im_v2.message_projection_state_values AS state ON state.state_id = shared.message_state_id JOIN im_v2.room_events AS event ON event.event_id = shared.source_event_id WHERE shared.projection_kind = 'message' AND COALESCE(shared.payload, state.payload) = event.payload",
                on: sql
            ) == 1)
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

            // No policy rows means this pre-policy group still uses its role
            // default. An explicit empty policy has the same materialized
            // row shape, so its durable operation is the deny-all marker.
            #expect(try await v2ResolvedGroupPermissions(roomID: roomUUID, role: .member, sql: sql) == nil)
            try await sql.raw("""
                INSERT INTO im_v2.group_permission_operations
                    (actor_user_id, operation_id, room_id, expected_revision, resulting_revision,
                     role, permissions, room_sequence, event_id, plan_id, created_at)
                VALUES
                    (\(bind: senderUUID), '00000000-0000-0000-0000-00000000001a', \(bind: roomUUID), 1, 2,
                     'member', '[]'::jsonb, 2, '00000000-0000-0000-0000-00000000001b',
                     '00000000-0000-0000-0000-00000000001c', \(bind: Date(timeIntervalSince1970: 1_750_000_000)))
                """).run()
            #expect(try await v2ResolvedGroupPermissions(roomID: roomUUID, role: .member, sql: sql) == [])

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

    @Test("sync-log statement triggers deduplicate users and preserve immutable effects")
    func syncLogStatementTriggersAreSetBased() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1),
                as: .psql, isDefault: true
            )
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw(
                "SELECT to_regnamespace('im_v2') IS NOT NULL AS exists"
            ).first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let firstUser = UUID(uuidString: "00000000-0000-0000-0000-000000000d01")!
            let secondUser = UUID(uuidString: "00000000-0000-0000-0000-000000000d02")!
            let events = (1 ... 9).map {
                UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", 0xd10 + $0))!
            }
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let later = now.addingTimeInterval(10)
            let backdated = now.addingTimeInterval(-10)
            try await sql.raw(
                "CREATE TABLE im_v2.test_checkpoint_updates (user_id uuid NOT NULL)"
            ).run()
            try await sql.raw(
                "CREATE TABLE im_v2.test_ready_updates (user_id uuid NOT NULL)"
            ).run()
            try await sql.raw("""
                CREATE FUNCTION im_v2.record_test_checkpoint_update() RETURNS trigger
                    LANGUAGE plpgsql AS $$
                BEGIN
                    INSERT INTO im_v2.test_checkpoint_updates (user_id) VALUES (NEW.user_id);
                    RETURN NEW;
                END;
                $$
                """).run()
            try await sql.raw("""
                CREATE FUNCTION im_v2.record_test_ready_update() RETURNS trigger
                    LANGUAGE plpgsql AS $$
                BEGIN
                    INSERT INTO im_v2.test_ready_updates (user_id) VALUES (NEW.user_id);
                    RETURN NEW;
                END;
                $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER record_test_checkpoint_update
                    AFTER UPDATE ON im_v2.user_projection_checkpoints
                    FOR EACH ROW EXECUTE FUNCTION im_v2.record_test_checkpoint_update()
                """).run()
            try await sql.raw("""
                CREATE TRIGGER record_test_ready_update
                    AFTER UPDATE ON im_v2.user_projection_ready
                    FOR EACH ROW EXECUTE FUNCTION im_v2.record_test_ready_update()
                """).run()

            // Four rows and two users produce exactly two checkpoint/retention
            // inserts and no redundant conflict UPDATE.
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id,
                     projection_kind, payload, payload_storage, created_at)
                VALUES
                    (\(bind: firstUser), 1, \(bind: events[0]), 'relationship',
                     '{"state":"pending"}'::jsonb, 'inline', \(bind: now)),
                    (\(bind: firstUser), 2, \(bind: events[1]), 'relationship',
                     '{"state":"accepted"}'::jsonb, 'inline', \(bind: now)),
                    (\(bind: secondUser), 1, \(bind: events[2]), 'relationship',
                     '{"state":"pending"}'::jsonb, 'inline', \(bind: now)),
                    (\(bind: secondUser), 2, \(bind: events[3]), 'relationship',
                     '{"state":"accepted"}'::jsonb, 'inline', \(bind: now))
                """).run()
            #expect(try await count("im_v2.user_projection_checkpoints", on: sql) == 2)
            #expect(try await count("im_v2.user_sync_retention", on: sql) == 2)
            #expect(try await count("im_v2.user_projection_effects", on: sql) == 4)
            #expect(try await count("im_v2.test_checkpoint_updates", on: sql) == 0)
            #expect(try await count("im_v2.test_ready_updates", on: sql) == 0)

            // Existing per-user control rows must not even enter an INSERT
            // conflict path. In PostgreSQL that path can wait behind an
            // unrelated UPDATE of the same checkpoint before DO NOTHING.
            try await sql.raw("""
                CREATE FUNCTION im_v2.reject_existing_projection_control_insert()
                RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    RAISE EXCEPTION 'existing projection control row must be read, not inserted';
                END;
                $$
                """).run()
            for table in [
                "user_projection_checkpoints",
                "user_projection_ready",
                "user_sync_retention",
            ] {
                try await sql.raw("""
                    CREATE TRIGGER reject_existing_projection_control_insert
                    BEFORE INSERT ON im_v2.\(unsafeRaw: table)
                    FOR EACH ROW
                    EXECUTE FUNCTION im_v2.reject_existing_projection_control_insert()
                    """).run()
            }

            // Newer work must neither insert nor rewrite an unchanged
            // checkpoint/retention/wake tuple.
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id,
                     projection_kind, payload, payload_storage, created_at)
                VALUES
                    (\(bind: firstUser), 3, \(bind: events[4]), 'relationship',
                     '{"state":"accepted"}'::jsonb, 'inline', \(bind: later)),
                    (\(bind: firstUser), 4, \(bind: events[5]), 'relationship',
                     '{"state":"accepted"}'::jsonb, 'inline', \(bind: later)),
                    (\(bind: secondUser), 3, \(bind: events[6]), 'relationship',
                     '{"state":"accepted"}'::jsonb, 'inline', \(bind: later)),
                    (\(bind: secondUser), 4, \(bind: events[7]), 'relationship',
                     '{"state":"accepted"}'::jsonb, 'inline', \(bind: later))
                """).run()
            #expect(try await count("im_v2.test_checkpoint_updates", on: sql) == 0)
            #expect(try await count("im_v2.test_ready_updates", on: sql) == 0)

            // Backdated restoration work is already represented by the
            // durable wake row. It must not rewrite either row or contend
            // with a projector that currently owns them.
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id,
                     projection_kind, payload, payload_storage, created_at)
                VALUES
                    (\(bind: firstUser), 5, \(bind: events[8]), 'relationship',
                     '{"state":"accepted"}'::jsonb, 'inline', \(bind: backdated))
                """).run()
            #expect(try await count("im_v2.test_checkpoint_updates", on: sql) == 0)
            #expect(try await count("im_v2.test_ready_updates", on: sql) == 0)
            let backdatedCheckpoint = try #require(try await sql.raw("""
                SELECT COUNT(*) AS value
                FROM im_v2.user_projection_checkpoints
                WHERE user_id = \(bind: firstUser) AND updated_at = \(bind: now)
                """).first(decoding: CountRow.self))
            #expect(backdatedCheckpoint.value == 1)

            // Compaction may remove a sync-log row while its stable projection
            // effect remains. Reusing that immutable identity with a different
            // body must still abort the complete statement.
            try await sql.raw("""
                DELETE FROM im_v2.user_sync_log
                WHERE user_id = \(bind: firstUser) AND user_sync_sequence = 1
                """).run()
            await #expect(throws: (any Error).self) {
                try await sql.raw("""
                    INSERT INTO im_v2.user_sync_log
                        (user_id, user_sync_sequence, source_event_id,
                         projection_kind, payload, payload_storage, created_at)
                    VALUES
                        (\(bind: firstUser), 6, \(bind: events[0]), 'relationship',
                         '{"state":"conflicting"}'::jsonb, 'inline', \(bind: later))
                    """).run()
            }
            let conflictingRow = try #require(try await sql.raw("""
                SELECT COUNT(*) AS value FROM im_v2.user_sync_log
                WHERE user_id = \(bind: firstUser) AND user_sync_sequence = 6
                """).first(decoding: CountRow.self))
            #expect(conflictingRow.value == 0)

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

    @Test("two replicas drain all eight fresh-direct user lanes without gaps or duplicate payloads")
    func freshDirectUserMicrobatchIsReplicaSafe() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 8),
                as: .psql, isDefault: true
            )
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw(
                "SELECT to_regnamespace('im_v2') IS NOT NULL AS exists"
            ).first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let roomID = UUID(uuidString: "00000000-0000-0000-0001-000000000001")!
            let users = (0 ..< 8).map {
                UUID(uuidString: String(
                    format: "00000000-0000-0000-0002-%012x", $0 + 1
                ))!
            }
            let eventCount = 24
            try await sql.raw("""
                INSERT INTO im_v2.rooms
                    (room_id, room_kind, room_shard_id, room_sequence,
                     membership_revision, capacity_profile_id, created_at,
                     delivery_mode)
                VALUES (\(bind: roomID), 'direct', 'rooms-primary',
                        \(bind: eventCount), 2, 'test', \(bind: now),
                        'standard_fanout')
                """).run()

            for index in 0 ..< eventCount {
                let eventID = UUID(uuidString: String(
                    format: "00000000-0000-0000-0003-%012x", index + 1
                ))!
                let planID = UUID(uuidString: String(
                    format: "00000000-0000-0000-0004-%012x", index + 1
                ))!
                let completionID = UUID(uuidString: String(
                    format: "00000000-0000-0000-0005-%012x", index + 1
                ))!
                let messageID = UUID(uuidString: String(
                    format: "00000000-0000-0000-0006-%012x", index + 1
                ))!
                let firstUser = users[index % users.count]
                let secondUser = users[(index + 3) % users.count]
                let payload = """
                    {"event_type":"message.accepted","message_id":"\(messageID.uuidString.lowercased())","room_id":"\(roomID.uuidString.lowercased())","message_revision":1}
                    """
                try await sql.raw("""
                    WITH inserted_event AS (
                        INSERT INTO im_v2.room_events
                            (event_id, room_id, room_sequence, event_type,
                             actor_user_id, payload,
                             committed_membership_revision, created_at)
                        VALUES (\(bind: eventID), \(bind: roomID), \(bind: index + 1),
                                'message.accepted', \(bind: firstUser),
                                \(bind: payload)::jsonb, 2, \(bind: now))
                        RETURNING event_id
                    ), inserted_plan AS (
                        INSERT INTO im_v2.fanout_plans
                            (plan_id, source_event_id, room_id,
                             source_room_sequence, committed_membership_revision,
                             target_rule, enumeration_checkpoint, target_count,
                             reserved_fanout_cost, state, created_at,
                             enumerated_target_count)
                        SELECT \(bind: planID), event_id, \(bind: roomID),
                               \(bind: index + 1), 2,
                               '{"planning_strategy":"direct_preplanned"}'::jsonb,
                               '{"complete":true}'::jsonb, 2, 2, 'planned',
                               \(bind: now), 2
                        FROM inserted_event
                        RETURNING source_event_id
                    ), inserted_unit AS (
                        INSERT INTO im_v2.fanout_completion_units
                            (source_event_id, completion_unit_id, target_boundary,
                             target_count, state)
                        SELECT source_event_id, \(bind: completionID),
                               '{"audience_kind":"direct_preplanned"}'::jsonb,
                               2, 'pending'
                        FROM inserted_plan
                        RETURNING source_event_id, completion_unit_id
                    )
                    INSERT INTO im_v2.fanout_deliveries
                        (source_event_id, target_user_id, projection_kind,
                         completion_unit_id, target_shard_bucket,
                         observed_router_epoch, fresh_direct_eligible)
                    SELECT source_event_id, target_user_id, 'message',
                           completion_unit_id, 'test-users', 9, TRUE
                    FROM inserted_unit
                    CROSS JOIN unnest(ARRAY[\(bind: firstUser), \(bind: secondUser)]::uuid[])
                        AS target(target_user_id)
                    """).run()
                // Mirror the acceptance contract: the immutable shared body
                // commits before a fresh-direct delivery can become visible.
                try await sql.raw("""
                    INSERT INTO im_v2.fanout_sync_payloads
                        (source_event_id, projection_kind, payload, created_at)
                    VALUES (\(bind: eventID), 'message', \(bind: payload)::jsonb,
                            \(bind: now))
                    """).run()
            }

            let firstEventID = UUID(
                uuidString: "00000000-0000-0000-0003-000000000001"
            )!
            await #expect(throws: (any Error).self) {
                try await sql.raw("""
                    UPDATE im_v2.fanout_deliveries
                    SET fresh_direct_eligible = FALSE
                    WHERE source_event_id = \(bind: firstEventID)
                    """).run()
            }
            await #expect(throws: (any Error).self) {
                try await sql.raw("""
                    UPDATE im_v2.fanout_plans
                    SET target_rule = '{}'::jsonb
                    WHERE source_event_id = \(bind: firstEventID)
                    """).run()
            }

            // A direct audience is one atomic completion unit. Two otherwise
            // valid units with one recipient each must not pass the
            // statement-level exact-two check.
            let malformedEventID = UUID(
                uuidString: "00000000-0000-0000-0003-000000000099"
            )!
            let malformedPlanID = UUID(
                uuidString: "00000000-0000-0000-0004-000000000099"
            )!
            let malformedFirstUnitID = UUID(
                uuidString: "00000000-0000-0000-0005-000000000099"
            )!
            let malformedSecondUnitID = UUID(
                uuidString: "00000000-0000-0000-0005-000000000100"
            )!
            await #expect(throws: (any Error).self) {
                try await sql.raw("""
                    WITH inserted_event AS (
                        INSERT INTO im_v2.room_events
                            (event_id, room_id, room_sequence, event_type,
                             actor_user_id, payload,
                             committed_membership_revision, created_at)
                        VALUES (
                            \(bind: malformedEventID), \(bind: roomID),
                            \(bind: eventCount + 1), 'message.accepted',
                            \(bind: users[0]),
                            '{"event_type":"message.accepted"}'::jsonb,
                            2, \(bind: now)
                        )
                        RETURNING event_id
                    ), inserted_plan AS (
                        INSERT INTO im_v2.fanout_plans
                            (plan_id, source_event_id, room_id,
                             source_room_sequence, committed_membership_revision,
                             target_rule, enumeration_checkpoint, target_count,
                             reserved_fanout_cost, state, created_at,
                             enumerated_target_count)
                        SELECT \(bind: malformedPlanID), event_id, \(bind: roomID),
                               \(bind: eventCount + 1), 2,
                               '{"planning_strategy":"direct_preplanned"}'::jsonb,
                               '{"complete":true}'::jsonb, 2, 2, 'planned',
                               \(bind: now), 2
                        FROM inserted_event
                        RETURNING source_event_id
                    ), inserted_units AS (
                        INSERT INTO im_v2.fanout_completion_units
                            (source_event_id, completion_unit_id,
                             target_boundary, target_count, state)
                        SELECT source_event_id, unit_id,
                               '{"audience_kind":"direct_preplanned"}'::jsonb,
                               2, 'pending'
                        FROM inserted_plan
                        CROSS JOIN unnest(ARRAY[
                            \(bind: malformedFirstUnitID),
                            \(bind: malformedSecondUnitID)
                        ]::uuid[]) AS unit(unit_id)
                        RETURNING source_event_id, completion_unit_id
                    )
                    INSERT INTO im_v2.fanout_deliveries
                        (source_event_id, target_user_id, projection_kind,
                         completion_unit_id, target_shard_bucket,
                         observed_router_epoch, fresh_direct_eligible)
                    SELECT source_event_id, target_user_id, 'message',
                           completion_unit_id, 'test-users', 9, TRUE
                    FROM inserted_units
                    JOIN (VALUES
                        (\(bind: malformedFirstUnitID), \(bind: users[0])),
                        (\(bind: malformedSecondUnitID), \(bind: users[1]))
                    ) AS target(completion_unit_id, target_user_id)
                    USING (completion_unit_id)
                    """).run()
            }
            #expect(try await count(
                "im_v2.room_events WHERE event_id = '\(malformedEventID.uuidString)'",
                on: sql
            ) == 0)

            // Even a valid alternate unit cannot be spliced into an existing
            // fresh-direct identity after its creation statement commits.
            let alternateUnitID = UUID(
                uuidString: "00000000-0000-0000-0005-000000000101"
            )!
            try await sql.raw("""
                INSERT INTO im_v2.fanout_completion_units
                    (source_event_id, completion_unit_id, target_boundary,
                     target_count, state)
                VALUES (
                    \(bind: firstEventID), \(bind: alternateUnitID),
                    '{"audience_kind":"direct_preplanned"}'::jsonb,
                    2, 'pending'
                )
                """).run()
            await #expect(throws: (any Error).self) {
                try await sql.raw("""
                    UPDATE im_v2.fanout_deliveries
                    SET completion_unit_id = \(bind: alternateUnitID)
                    WHERE source_event_id = \(bind: firstEventID)
                      AND target_user_id = \(bind: users[0])
                    """).run()
            }
            try await sql.raw("""
                DELETE FROM im_v2.fanout_completion_units
                WHERE source_event_id = \(bind: firstEventID)
                  AND completion_unit_id = \(bind: alternateUnitID)
                """).run()

            // A BEFORE trigger proves the delivery statement does not merely
            // rely on `ON CONFLICT DO NOTHING`: it must issue no payload INSERT
            // at all once acceptance has published the immutable shared row.
            try await sql.raw("""
                CREATE FUNCTION im_v2.reject_fresh_direct_payload_insert()
                RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    RAISE EXCEPTION 'fresh-direct delivery must not insert shared payloads';
                END;
                $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER reject_fresh_direct_payload_insert
                BEFORE INSERT ON im_v2.fanout_sync_payloads
                FOR EACH ROW
                EXECUTE FUNCTION im_v2.reject_fresh_direct_payload_insert()
                """).run()

            let firstReplica = PostgresV2FanoutDeliveryStore(database: app.db(.psql))
            let secondReplica = PostgresV2FanoutDeliveryStore(database: app.db(.psql))
            // Normal Sync holds the route-cutover barrier in shared mode.
            // Hold it for every candidate user: delivery lane ownership must
            // use an independent key, then coexist on the shared route key.
            // Reusing the route key as an exclusive lane lock makes this
            // deterministic microbatch return no work.
            let routeReadGate = PostgreSQLTransactionGate()
            let routeReader = Task {
                try await app.db(.psql).transaction { transaction in
                    guard let transactionSQL = transaction as? any SQLDatabase else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    for user in users.sorted(by: { $0.uuidString < $1.uuidString }) {
                        try await transactionSQL.raw("""
                            SELECT pg_advisory_xact_lock_shared(
                                hashtextextended(\(bind: user.uuidString), 0)
                            )
                            """).run()
                    }
                    await routeReadGate.holdTransaction()
                }
            }
            await routeReadGate.waitUntilHeld()
            let firstMicrobatch: [V2FreshDirectFanoutDeliveryCommit]
            do {
                firstMicrobatch = try await firstReplica.commitFreshDirectPreplanned(
                    bucket: "test-users", partition: nil,
                    now: now.addingTimeInterval(1), limit: 4
                )
            } catch {
                await routeReadGate.releaseTransaction()
                _ = try? await routeReader.value
                throw error
            }
            await routeReadGate.releaseTransaction()
            try await routeReader.value
            #expect(firstMicrobatch.count == 4)
            #expect(Set(firstMicrobatch.map(\.targetUserID)).count == 4)

            // The independent lane key must not weaken cutover fencing. An
            // exclusive route migration lock still blocks the delivery until
            // the migration transaction releases its barrier.
            let routeCutoverGate = PostgreSQLTransactionGate()
            let routeCutover = Task {
                try await app.db(.psql).transaction { transaction in
                    guard let transactionSQL = transaction as? any SQLDatabase else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    for user in users.sorted(by: { $0.uuidString < $1.uuidString }) {
                        try await transactionSQL.raw("""
                            SELECT pg_advisory_xact_lock(
                                hashtextextended(\(bind: user.uuidString), 0)
                            )
                            """).run()
                    }
                    await routeCutoverGate.holdTransaction()
                }
            }
            await routeCutoverGate.waitUntilHeld()
            let cutoverFencedCommit = Task {
                try await secondReplica.commitFreshDirectPreplanned(
                    bucket: "test-users", partition: nil,
                    now: now.addingTimeInterval(1), limit: 4
                )
            }
            do {
                try await waitForAdvisoryWaiters(1, on: sql)
            } catch {
                cutoverFencedCommit.cancel()
                await routeCutoverGate.releaseTransaction()
                _ = try? await routeCutover.value
                _ = try? await cutoverFencedCommit.value
                throw error
            }
            await routeCutoverGate.releaseTransaction()
            try await routeCutover.value
            let secondMicrobatch = try await cutoverFencedCommit.value
            #expect(secondMicrobatch.count == 4)
            #expect(Set(secondMicrobatch.map(\.targetUserID)).count == 4)

            var passCount = 0
            while true {
                passCount += 1
                guard passCount <= 100 else {
                    Issue.record("fresh-direct replica drain did not converge")
                    break
                }
                let committed = try await withThrowingTaskGroup(
                    of: Int.self, returning: Int.self
                ) { group in
                    for replica in 0 ..< 2 {
                        for lane in 0 ..< 8 {
                            group.addTask {
                                let store = replica == 0 ? firstReplica : secondReplica
                                return try await store.commitFreshDirectPreplanned(
                                    bucket: "test-users",
                                    partition: .init(index: lane, count: 8),
                                    now: now.addingTimeInterval(1),
                                    limit: 4
                                ).count
                            }
                        }
                    }
                    var total = 0
                    for try await count in group { total += count }
                    return total
                }
                if committed == 0 { break }
            }

            #expect(try await count(
                "im_v2.fanout_deliveries WHERE state = 'terminal' AND retry_count = 0",
                on: sql
            ) == Int64(eventCount * 2))
            #expect(try await count("im_v2.user_sync_log", on: sql) == Int64(eventCount * 2))
            #expect(try await count("im_v2.consumer_inbox", on: sql) == Int64(eventCount * 2))
            #expect(try await count("im_v2.fanout_sync_payloads", on: sql) == Int64(eventCount))
            #expect(try await count(
                "im_v2.fanout_completion_units WHERE state = 'terminal' AND committed_target_count = 2",
                on: sql
            ) == Int64(eventCount))
            let brokenSequences = try #require(try await sql.raw("""
                SELECT COUNT(*) AS value
                FROM (
                    SELECT user_id
                    FROM im_v2.user_sync_log
                    GROUP BY user_id
                    HAVING min(user_sync_sequence) <> 1
                        OR max(user_sync_sequence) <> count(*)
                        OR count(DISTINCT user_sync_sequence) <> count(*)
                ) AS broken
                """).first(decoding: CountRow.self))
            #expect(brokenSequences.value == 0)

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

    @Test("accepted-message projection batches consecutive shared-state references")
    func acceptedMessageProjectionBatchPreservesNarrowReferences() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1),
                as: .psql,
                isDefault: true
            )
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw(
                "SELECT to_regnamespace('im_v2') IS NOT NULL AS exists"
            ).first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let user = UUID(uuidString: "00000000-0000-0000-0000-000000000c71")!
            let sender = UUID(uuidString: "00000000-0000-0000-0000-000000000c72")!
            let room = UUID(uuidString: "00000000-0000-0000-0000-000000000c73")!
            let messages = [
                UUID(uuidString: "00000000-0000-0000-0000-000000000C74")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000C75")!,
            ]
            let events = [
                UUID(uuidString: "00000000-0000-0000-0000-000000000c76")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000c77")!,
            ]
            let states = try messages.map {
                try v2MessageProjectionStateID(messageID: $0, messageRevision: 1)
            }
            let createdAt = Date(timeIntervalSince1970: 1_750_000_000)
            func payload(message: UUID, sequence: Int, text: String) throws -> String {
                let object: [String: Any] = [
                    "event_type": "message.accepted",
                    "message_id": message.uuidString,
                    "room_id": room.uuidString,
                    "room_sequence": sequence,
                    "timeline_sequence": sequence,
                    "sender_user_id": sender.uuidString,
                    "text": text,
                    "media_ids": [],
                    "media_presentations": [],
                    "mention_user_ids": [],
                    "mentions_everyone": false,
                    "entities": [],
                    "reply_to_message_id": NSNull(),
                    "forwarded_from_message_id": NSNull(),
                    "forwarded_from_user_id": NSNull(),
                    "message_revision": 1,
                    "server_created_at_ms": 1_750_000_000_000 + sequence,
                ]
                return String(
                    decoding: try JSONSerialization.data(withJSONObject: object),
                    as: UTF8.self
                )
            }
            let payloads = try [
                payload(message: messages[0], sequence: 1, text: "one"),
                payload(message: messages[1], sequence: 2, text: "two"),
            ]

            for index in messages.indices {
                try await sql.raw("""
                    INSERT INTO im_v2.message_projection_states
                        (state_id, message_id, room_id, message_revision, variant_key,
                         origin_event_id, state_event_id, is_withdrawn,
                         payload_schema_version, payload, created_at)
                    VALUES
                        (\(bind: states[index]), \(bind: messages[index]), \(bind: room), 1, 0,
                         \(bind: events[index]), \(bind: events[index]), FALSE,
                         1, \(bind: payloads[index])::jsonb, \(bind: createdAt))
                    """).run()
                try await sql.raw("""
                    INSERT INTO im_v2.fanout_sync_payloads
                        (source_event_id, projection_kind, payload, created_at, message_state_id)
                    VALUES
                        (\(bind: events[index]), 'message', NULL, \(bind: createdAt),
                         \(bind: states[index]))
                    """).run()
            }
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence)
                VALUES (\(bind: user), 2)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind,
                     payload, payload_storage, created_at)
                VALUES
                    (\(bind: user), 1, \(bind: events[0]), 'message', NULL,
                     'fanout_shared', \(bind: createdAt)),
                    (\(bind: user), 2, \(bind: events[1]), 'message', NULL,
                     'fanout_shared', \(bind: createdAt))
                """).run()

            let worker = PostgresV2UserProjectionWorker(
                database: app.db(.psql), batchSize: 10,
                messageWriteMode: .shared, acceptedMessageBatchEnabled: true
            )
            #expect(try await worker.runOnce(now: createdAt) == .init(
                claimed: true, appliedRecordCount: 2
            ))
            #expect(try await worker.runOnce(now: createdAt).claimed == false)
            #expect(try await count("im_v2.user_projection_ready", on: sql) == 0)
            let projected = try await currentV3ProjectionItems(
                sql: sql, userID: .init(user.uuidString), kind: "message"
            )
            #expect(projected.map(\.entityKey) == messages.map(\.uuidString).sorted())
            #expect(Set(projected.compactMap { $0.string("text") }) == ["one", "two"])
            #expect(try await count(
                "im_v2.user_projection_versions WHERE projection_kind = 'message' AND payload IS NULL AND message_state_id IS NOT NULL",
                on: sql
            ) == 2)

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

    @Test("projection completion cannot lose a concurrent durable ready enqueue")
    func projectionCompletionFencesConcurrentReadyEnqueue() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4),
                as: .psql,
                isDefault: true
            )
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw(
                "SELECT to_regnamespace('im_v2') IS NOT NULL AS exists"
            ).first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let user = UUID(uuidString: "00000000-0000-0000-0000-000000000d61")!
            let firstEvent = UUID(uuidString: "00000000-0000-0000-0000-000000000d62")!
            let secondEvent = UUID(uuidString: "00000000-0000-0000-0000-000000000d63")!
            let invalidatedUser = UUID(uuidString: "00000000-0000-0000-0000-000000000d64")!
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let payload = """
            {"user_id":"\(invalidatedUser.uuidString)"}
            """
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence)
                VALUES (\(bind: user), 1)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind,
                     payload, payload_storage, created_at)
                VALUES
                    (\(bind: user), 1, \(bind: firstEvent), 'profile_invalidation',
                     \(bind: payload)::jsonb, 'inline', \(bind: now))
                """).run()

            // The v7 enqueue trigger runs first. This test-only trigger then
            // holds the same INSERT transaction open so the projector can
            // exercise the exact delete-versus-commit race that previously
            // lost the durable ready row.
            let blockerLock: Int64 = 7_316_204_982
            try await sql.raw("""
                CREATE FUNCTION im_v2.zz_test_block_after_projection_enqueue()
                RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    PERFORM pg_advisory_xact_lock(7316204982);
                    RETURN NULL;
                END;
                $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER zz_test_block_after_projection_enqueue
                AFTER INSERT ON im_v2.user_sync_log
                REFERENCING NEW TABLE AS inserted_user_sync_rows
                FOR EACH STATEMENT
                EXECUTE FUNCTION im_v2.zz_test_block_after_projection_enqueue()
                """).run()

            let gate = PostgreSQLTransactionGate()
            let blocker = Task {
                try await app.db(.psql).transaction { transaction in
                    guard let transactionSQL = transaction as? any SQLDatabase else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    try await transactionSQL.raw(
                        "SELECT pg_advisory_xact_lock(\(bind: blockerLock))"
                    ).run()
                    await gate.holdTransaction()
                }
            }
            await gate.waitUntilHeld()

            var enqueuer: Task<Void, Error>?
            var projector: Task<V2UserProjectionWorkerReport, Error>?
            do {
                enqueuer = Task {
                    try await app.db(.psql).transaction { transaction in
                        guard let transactionSQL = transaction as? any SQLDatabase else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                        try await transactionSQL.raw("""
                            UPDATE im_v2.user_sync_sequences
                            SET next_sequence = 2
                            WHERE user_id = \(bind: user)
                            """).run()
                        try await transactionSQL.raw("""
                            INSERT INTO im_v2.user_sync_log
                                (user_id, user_sync_sequence, source_event_id,
                                 projection_kind, payload, payload_storage, created_at)
                            VALUES
                                (\(bind: user), 2, \(bind: secondEvent),
                                 'profile_invalidation', \(bind: payload)::jsonb,
                                 'inline', \(bind: now.addingTimeInterval(1)))
                            """).run()
                    }
                }
                try await waitForPostgreSQLLockWaiters(
                    1, lockType: "advisory", on: sql
                )
                let worker = PostgresV2UserProjectionWorker(
                    database: app.db(.psql), batchSize: 1,
                    messageWriteMode: .shared
                )
                projector = Task {
                    try await worker.runOnce(now: now.addingTimeInterval(2))
                }
                try await waitForPostgreSQLLockWaiters(
                    1, lockType: "transactionid", on: sql
                )
            } catch {
                enqueuer?.cancel()
                projector?.cancel()
                await gate.releaseTransaction()
                _ = try? await blocker.value
                _ = try? await enqueuer?.value
                _ = try? await projector?.value
                throw error
            }

            await gate.releaseTransaction()
            try await blocker.value
            try await enqueuer?.value
            let projectionReport = try #require(try await projector?.value)
            #expect(projectionReport == .init(claimed: true, appliedRecordCount: 1))
            #expect(try await count("im_v2.user_projection_ready", on: sql) == 1)
            let lag = try #require(try await sql.raw("""
                SELECT sequence.next_sequence - checkpoint.projected_sequence AS value
                FROM im_v2.user_sync_sequences AS sequence
                JOIN im_v2.user_projection_checkpoints AS checkpoint USING (user_id)
                WHERE sequence.user_id = \(bind: user)
                """).first(decoding: CountRow.self)).value
            #expect(lag == 1)

            let finalWorker = PostgresV2UserProjectionWorker(
                database: app.db(.psql), batchSize: 1,
                messageWriteMode: .shared
            )
            #expect(try await finalWorker.runOnce(
                now: now.addingTimeInterval(3)
            ) == .init(claimed: true, appliedRecordCount: 1))
            #expect(try await count("im_v2.user_projection_ready", on: sql) == 0)

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

    @Test("accepted-message fast path rolls back before an invalid shared state")
    func acceptedMessageProjectionBatchRollsBackAtExactInvalidSequence() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2),
                as: .psql,
                isDefault: true
            )
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw(
                "SELECT to_regnamespace('im_v2') IS NOT NULL AS exists"
            ).first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let user = UUID(uuidString: "00000000-0000-0000-0000-000000000d71")!
            let sender = UUID(uuidString: "00000000-0000-0000-0000-000000000d72")!
            let room = UUID(uuidString: "00000000-0000-0000-0000-000000000d73")!
            let messages = [
                UUID(uuidString: "00000000-0000-0000-0000-000000000d74")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000d75")!,
            ]
            let events = [
                UUID(uuidString: "00000000-0000-0000-0000-000000000d76")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000d77")!,
            ]
            let invalidOrigin = UUID(
                uuidString: "00000000-0000-0000-0000-000000000d78"
            )!
            let states = try messages.map {
                try v2MessageProjectionStateID(messageID: $0, messageRevision: 1)
            }
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            for index in messages.indices {
                let payload = """
                {"event_type":"message.accepted","message_id":"\(messages[index].uuidString)","room_id":"\(room.uuidString)","room_sequence":\(index + 1),"timeline_sequence":\(index + 1),"sender_user_id":"\(sender.uuidString)","text":"message-\(index)","media_ids":[],"media_presentations":[],"mention_user_ids":[],"mentions_everyone":false,"entities":[],"reply_to_message_id":null,"forwarded_from_message_id":null,"forwarded_from_user_id":null,"message_revision":1,"server_created_at_ms":1750000000000}
                """
                let origin = index == 0 ? events[index] : invalidOrigin
                try await sql.raw("""
                    INSERT INTO im_v2.message_projection_states
                        (state_id, message_id, room_id, message_revision, variant_key,
                         origin_event_id, state_event_id, is_withdrawn,
                         payload_schema_version, payload, created_at)
                    VALUES
                        (\(bind: states[index]), \(bind: messages[index]), \(bind: room), 1, 0,
                         \(bind: origin), \(bind: events[index]), FALSE, 1,
                         \(bind: payload)::jsonb, \(bind: now))
                    """).run()
                try await sql.raw("""
                    INSERT INTO im_v2.fanout_sync_payloads
                        (source_event_id, projection_kind, payload, created_at, message_state_id)
                    VALUES (\(bind: events[index]), 'message', NULL, \(bind: now),
                            \(bind: states[index]))
                    """).run()
            }
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence)
                VALUES (\(bind: user), 2)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind,
                     payload, payload_storage, created_at)
                VALUES
                    (\(bind: user), 1, \(bind: events[0]), 'message', NULL,
                     'fanout_shared', \(bind: now)),
                    (\(bind: user), 2, \(bind: events[1]), 'message', NULL,
                     'fanout_shared', \(bind: now))
                """).run()

            let worker = PostgresV2UserProjectionWorker(
                database: app.db(.psql), batchSize: 10,
                retryPolicy: .init(
                    initialDelay: 1, maximumDelay: 1,
                    maximumAttempts: 2, jitterFraction: 0
                ),
                messageWriteMode: .shared,
                acceptedMessageBatchEnabled: true
            )
            #expect(try await worker.runOnce(now: now) == .init(
                claimed: true, appliedRecordCount: 0, failedRecordCount: 1
            ))
            #expect(try await count("im_v2.user_projection_versions", on: sql) == 0)
            let projectedSequence = try #require(try await sql.raw("""
                SELECT projected_sequence AS value
                FROM im_v2.user_projection_checkpoints WHERE user_id = \(bind: user)
                """).first(decoding: CountRow.self)).value
            #expect(projectedSequence == 0)
            let failedSequence = try #require(try await sql.raw("""
                SELECT failed_sequence AS value
                FROM im_v2.user_projection_checkpoints WHERE user_id = \(bind: user)
                """).first(decoding: CountRow.self)).value
            #expect(failedSequence == 2)

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

    @Test("concurrent projectors claim distinct users without duplicate versions")
    func concurrentUserProjectionClaimsRemainExclusive() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4),
                as: .psql,
                isDefault: true
            )
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw(
                "SELECT to_regnamespace('im_v2') IS NOT NULL AS exists"
            ).first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let users = [
                UUID(uuidString: "00000000-0000-0000-0000-000000000d81")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000d82")!,
            ]
            let events = [
                UUID(uuidString: "00000000-0000-0000-0000-000000000d83")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000d84")!,
            ]
            let targets = [
                UUID(uuidString: "00000000-0000-0000-0000-000000000d85")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000d86")!,
            ]
            for index in users.indices {
                try await sql.raw("""
                    INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence)
                    VALUES (\(bind: users[index]), 1)
                    """).run()
                let payload = """
                {"target_user_id":"\(targets[index].uuidString)","state":"accepted","updated_at_ms":1750000000000}
                """
                try await sql.raw("""
                    INSERT INTO im_v2.user_sync_log
                        (user_id, user_sync_sequence, source_event_id, projection_kind,
                         payload, payload_storage, created_at)
                    VALUES (\(bind: users[index]), 1, \(bind: events[index]),
                            'relationship', \(bind: payload)::jsonb, 'inline', \(bind: now))
                    """).run()
            }

            let worker = PostgresV2UserProjectionWorker(
                database: app.db(.psql), batchSize: 10
            )
            async let first = worker.runOnce(now: now)
            async let second = worker.runOnce(now: now)
            let (firstReport, secondReport) = try await (first, second)
            #expect(firstReport.appliedRecordCount + secondReport.appliedRecordCount == 2)
            #expect(firstReport.claimed)
            #expect(secondReport.claimed)
            #expect(try await count("im_v2.user_projection_versions", on: sql) == 2)
            #expect(try await worker.runOnce(now: now).claimed == false)

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

    @Test("terminal fan-out completion survives a crash window and releases capacity exactly once")
    func terminalFanoutCompletionRecoversAfterWorkerReplacement() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2),
                as: .psql,
                isDefault: true
            )
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let room = UUID(uuidString: "00000000-0000-0000-0000-0000000003a1")!
            let user = UUID(uuidString: "00000000-0000-0000-0000-0000000003a2")!
            let event = UUID(uuidString: "00000000-0000-0000-0000-0000000003a3")!
            let plan = UUID(uuidString: "00000000-0000-0000-0000-0000000003a4")!
            let lease = UUID(uuidString: "00000000-0000-0000-0000-0000000003a5")!
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("""
                INSERT INTO im_v2.rooms
                    (room_id, room_shard_id, capacity_profile_id, created_at)
                VALUES (\(bind: room), 'release-recovery', 'standard', \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until,
                     command_window_limit, command_window_used,
                     fanout_window_limit, fanout_window_used,
                     max_outstanding_fanout_units, outstanding_fanout_units,
                     max_outstanding_plans, outstanding_plans)
                VALUES ('release-recovery', 'standard', \(bind: lease), 1,
                        \(bind: now.addingTimeInterval(600)),
                        10, 1, 10, 1, 10, 1, 10, 1)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_admission
                    (room_id, eligible_member_count, command_window_limit, command_window_used,
                     fanout_window_limit, fanout_window_used,
                     max_outstanding_fanout_units, outstanding_fanout_units,
                     max_outstanding_plans, outstanding_plans,
                     shard_lease_id, shard_lease_generation)
                VALUES (\(bind: room), 1, 10, 1, 10, 1, 10, 1, 10, 1,
                        \(bind: lease), 1)
                """).run()
            try await sql.raw("INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision) VALUES (\(bind: room), \(bind: user), 0)").run()
            try await sql.raw("""
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, payload,
                     committed_membership_revision, created_at)
                VALUES (\(bind: event), \(bind: room), 1, 'message.accepted',
                        '{}'::jsonb, 0, \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.fanout_plans
                    (plan_id, source_event_id, room_id, source_room_sequence,
                     committed_membership_revision, target_rule,
                     enumeration_checkpoint, target_count, reserved_fanout_cost,
                     state, created_at)
                VALUES (\(bind: plan), \(bind: event), \(bind: room), 1, 0,
                        '{"kind":"membership_at_revision"}'::jsonb,
                        '{}'::jsonb, 1, 1, 'planning', \(bind: now))
                """).run()

            let trigger = try V2FanoutPlanTrigger(
                sourceEventID: .init(event.uuidString),
                planID: .init(plan.uuidString)
            )
            #expect(try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(database: app.db(.psql)),
                pageSize: 1,
                now: { now }
            ).plan(trigger) == .init(
                createdCompletionUnits: 1,
                createdDeliveries: 1,
                wasAlreadyPlanned: false
            ))

            let deliveryStore = PostgresV2FanoutDeliveryStore(database: app.db(.psql))
            let deliveryLease = try #require(try await deliveryStore.claimPending(
                bucket: nil,
                now: now.addingTimeInterval(1),
                leaseDuration: 30,
                limit: 1
            ).first)
            guard case .committed(_, false, false) = try await deliveryStore.commit(
                deliveryLease, now: now.addingTimeInterval(2)
            ) else {
                Issue.record("phase A must not release admission capacity")
                return
            }

            let terminalUnit = try #require(try await sql.raw("SELECT state FROM im_v2.fanout_completion_units WHERE source_event_id = \(bind: event)").first(decoding: PushStateRow.self))
            let reservedBeforeRecovery = try #require(try await sql.raw("SELECT outstanding_fanout_units, outstanding_plans FROM im_v2.room_admission WHERE room_id = \(bind: room)").first(decoding: OutstandingRow.self))
            let planBeforeRecovery = try #require(try await sql.raw("SELECT state FROM im_v2.fanout_plans WHERE plan_id = \(bind: plan)").first(decoding: PushStateRow.self))
            let metricsBeforeRecovery = try await PostgresV2DurableWorkMetricsSource(
                database: app.db(.psql)
            ).loadDurableWorkMetrics()
            #expect(terminalUnit.state == "terminal")
            #expect(reservedBeforeRecovery.outstandingFanoutUnits == 1)
            #expect(reservedBeforeRecovery.outstandingPlans == 1)
            #expect(planBeforeRecovery.state == "planned")
            #expect(metricsBeforeRecovery.terminalFanoutCompletionUnits == 1)

            // A newly constructed worker models a process restart after phase
            // A committed but before any in-process wake reached phase B.
            let replacement = V2FanoutCompletionReleaseWorker(
                store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)),
                now: { now.addingTimeInterval(3) }
            )
            #expect(try await replacement.runOnce(limit: 8) == .init(
                releasedCount: 1, closedPlanCount: 1
            ))
            #expect(try await replacement.runOnce(limit: 8) == .init(
                releasedCount: 0, closedPlanCount: 0
            ))

            let releasedUnit = try #require(try await sql.raw("SELECT state FROM im_v2.fanout_completion_units WHERE source_event_id = \(bind: event)").first(decoding: PushStateRow.self))
            let reservedAfterRecovery = try #require(try await sql.raw("SELECT outstanding_fanout_units, outstanding_plans FROM im_v2.room_admission WHERE room_id = \(bind: room)").first(decoding: OutstandingRow.self))
            let planAfterRecovery = try #require(try await sql.raw("SELECT state FROM im_v2.fanout_plans WHERE plan_id = \(bind: plan)").first(decoding: PushStateRow.self))
            #expect(releasedUnit.state == "released")
            #expect(reservedAfterRecovery.outstandingFanoutUnits == 0)
            #expect(reservedAfterRecovery.outstandingPlans == 0)
            #expect(planAfterRecovery.state == "terminal")
            #expect(try await PostgresV2DurableWorkMetricsSource(
                database: app.db(.psql)
            ).loadDurableWorkMetrics().terminalFanoutCompletionUnits == 0)

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

    @Test("relationship profile reads require a current pending or accepted pair")
    func relationshipProfileReadsAreBoundedByAuthoritativeRelationshipState() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
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
            let actor = try UserID("00000000-0000-0000-0000-0000000009a1")
            let target = try UserID("00000000-0000-0000-0000-0000000009a2")
            let actorUUID = UUID(uuidString: actor.rawValue)!
            let targetUUID = UUID(uuidString: target.rawValue)!
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, revision, visibility_revision, created_at, updated_at)
                VALUES
                    (\(bind: actorUUID), 'contact_actor', '联系人发起者', 1, 1, \(bind: now), \(bind: now)),
                    (\(bind: targetUUID), 'contact_target', '联系人目标', 1, 1, \(bind: now), \(bind: now))
                """).run()
            let key = V2ProfileViewLookupKey(userID: target, context: .relationship)
            let store = PostgresV2ProfileViewStore(database: app.db(.psql))

            #expect(try await store.read(.init(actorUserID: actor, keys: [key])) == [.unavailable(key: key)])

            try await sql.raw("""
                INSERT INTO im_v2.user_relationships
                    (lower_user_id, higher_user_id, state, requested_by_user_id, updated_at)
                VALUES (\(bind: actorUUID), \(bind: targetUUID), 'pending', \(bind: actorUUID), \(bind: now))
                """).run()
            let pendingResult = try await store.read(.init(actorUserID: actor, keys: [key]))
            guard case .profile(_, let profile) = try #require(pendingResult.first) else {
                Issue.record("expected relationship-authorized profile")
                return
            }
            #expect(profile.publicIdentity?.handle.description == "@contact_target")

            try await sql.raw("INSERT INTO im_v2.user_blocks (blocker_user_id, blocked_user_id, created_at) VALUES (\(bind: targetUUID), \(bind: actorUUID), \(bind: now))").run()
            #expect(try await store.read(.init(actorUserID: actor, keys: [key])) == [.unavailable(key: key)])
            try await sql.raw("DELETE FROM im_v2.user_blocks WHERE blocker_user_id = \(bind: targetUUID) AND blocked_user_id = \(bind: actorUUID)").run()

            try await sql.raw("INSERT INTO im_v2.user_blocks (blocker_user_id, blocked_user_id, created_at) VALUES (\(bind: actorUUID), \(bind: targetUUID), \(bind: now))").run()
            #expect(try await store.read(.init(actorUserID: actor, keys: [key])) == [.unavailable(key: key)])
            try await sql.raw("DELETE FROM im_v2.user_blocks WHERE blocker_user_id = \(bind: actorUUID) AND blocked_user_id = \(bind: targetUUID)").run()

            try await sql.raw("DELETE FROM im_v2.user_relationships WHERE lower_user_id = \(bind: actorUUID) AND higher_user_id = \(bind: targetUUID)").run()
            #expect(try await store.read(.init(actorUserID: actor, keys: [key])) == [.unavailable(key: key)])
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

    @Test("direct and group profile reads collapse bilateral blocks to unavailable")
    func contextualProfileReadsEnforceBilateralBlocks() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
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
            let actor = try UserID("00000000-0000-0000-0000-0000000009b1")
            let target = try UserID("00000000-0000-0000-0000-0000000009b2")
            let actorUUID = UUID(uuidString: actor.rawValue)!
            let targetUUID = UUID(uuidString: target.rawValue)!
            let directRoom = UUID(uuidString: "00000000-0000-0000-0000-0000000009b3")!
            let groupRoom = try RoomID("00000000-0000-0000-0000-0000000009b4")
            let groupRoomUUID = UUID(uuidString: groupRoom.rawValue)!
            let actorDevice = UUID(uuidString: "00000000-0000-0000-0000-0000000009b5")!
            let avatarMedia = UUID(uuidString: "00000000-0000-0000-0000-0000000009b6")!
            let uploadSession = UUID(uuidString: "00000000-0000-0000-0000-0000000009b7")!
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, revision, visibility_revision, created_at, updated_at)
                VALUES
                    (\(bind: actorUUID), 'context_actor', '上下文发起者', 1, 1, \(bind: now), \(bind: now)),
                    (\(bind: targetUUID), 'context_target', '上下文目标', 1, 1, \(bind: now), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at)
                VALUES (\(bind: actorUUID), \(bind: actorDevice), \(bind: now), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.media_objects
                    (media_id, owner_user_id, content_type, byte_count, state, upload_session_id,
                     expires_at, state_updated_at, created_at)
                VALUES (\(bind: avatarMedia), \(bind: targetUUID), 'image/png', 1, 'available',
                        \(bind: uploadSession), \(bind: now.addingTimeInterval(3600)), \(bind: now), \(bind: now))
                """).run()
            try await sql.raw("UPDATE im_v2.public_user_profiles SET avatar_media_id = \(bind: avatarMedia) WHERE user_id = \(bind: targetUUID)").run()
            try await sql.raw("""
                INSERT INTO im_v2.rooms (room_id, room_kind, room_shard_id, capacity_profile_id)
                VALUES
                    (\(bind: directRoom), 'direct', 'profile-direct', 'standard'),
                    (\(bind: groupRoomUUID), 'group', 'profile-group', 'standard')
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.direct_room_pairs (lower_user_id, higher_user_id, room_id, created_at)
                VALUES (\(bind: actorUUID), \(bind: targetUUID), \(bind: directRoom), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision)
                VALUES
                    (\(bind: directRoom), \(bind: actorUUID), 0),
                    (\(bind: directRoom), \(bind: targetUUID), 0),
                    (\(bind: groupRoomUUID), \(bind: actorUUID), 0),
                    (\(bind: groupRoomUUID), \(bind: targetUUID), 0)
                """).run()

            let directKey = V2ProfileViewLookupKey(userID: target, context: .directConversation)
            let groupKey = V2ProfileViewLookupKey(userID: target, context: .room(groupRoom))
            let request = try V2ProfileViewReadRequest(actorUserID: actor, keys: [directKey, groupKey])
            let store = PostgresV2ProfileViewStore(database: app.db(.psql))
            let authorized = try await store.read(request)
            #expect(authorized.count == 2)
            #expect(authorized.allSatisfy { if case .profile = $0 { true } else { false } })
            #expect(try await V2PostgresMediaVisibilityAuthorization.isAuthorized(
                mediaID: avatarMedia, requesterUserID: actorUUID, deviceID: actorDevice, on: sql
            ))

            try await sql.raw("INSERT INTO im_v2.user_blocks (blocker_user_id, blocked_user_id, created_at) VALUES (\(bind: targetUUID), \(bind: actorUUID), \(bind: now))").run()
            #expect(try await store.read(request) == [.unavailable(key: directKey), .unavailable(key: groupKey)])
            #expect(try await V2PostgresMediaVisibilityAuthorization.isAuthorized(
                mediaID: avatarMedia, requesterUserID: actorUUID, deviceID: actorDevice, on: sql
            ) == false)
            try await sql.raw("DELETE FROM im_v2.user_blocks WHERE blocker_user_id = \(bind: targetUUID) AND blocked_user_id = \(bind: actorUUID)").run()
            #expect(try await V2PostgresMediaVisibilityAuthorization.isAuthorized(
                mediaID: avatarMedia, requesterUserID: actorUUID, deviceID: actorDevice, on: sql
            ))
            try await sql.raw("INSERT INTO im_v2.user_blocks (blocker_user_id, blocked_user_id, created_at) VALUES (\(bind: actorUUID), \(bind: targetUUID), \(bind: now))").run()
            #expect(try await V2PostgresMediaVisibilityAuthorization.isAuthorized(
                mediaID: avatarMedia, requesterUserID: actorUUID, deviceID: actorDevice, on: sql
            ) == false)

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

    @Test("muted conversation suppresses a generic Push wake before budget admission")
    func mutedConversationSuppressesPushWake() async throws {
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
            let room = UUID(uuidString: "00000000-0000-0000-0000-000000000311")!
            let event = UUID(uuidString: "00000000-0000-0000-0000-000000000312")!
            let user = UUID(uuidString: "00000000-0000-0000-0000-000000000313")!
            let device = UUID(uuidString: "00000000-0000-0000-0000-000000000314")!
            let dispatch = UUID(uuidString: "00000000-0000-0000-0000-000000000315")!
            try await sql.raw("""
                INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id)
                VALUES (\(bind: room), 'room-muted', 'standard')
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
                VALUES (\(bind: event), \(bind: room), 1, 'message.accepted', \(bind: user), '{}'::jsonb, 0, \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.user_room_preferences (user_id, room_id, pinned_at, archived_at, mute_until, updated_at)
                VALUES (\(bind: user), \(bind: room), NULL, NULL, \(bind: now.addingTimeInterval(3600)), \(bind: now))
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

            let store = PostgresV2PushWakeStore(database: app.db(.psql))
            #expect(try await store.claimAdmitted(now: now, leaseDuration: 30, limit: 1).isEmpty)
            let state = try #require(try await sql.raw("SELECT state, suppression_reason FROM im_v2.push_wake_outbox WHERE dispatch_id = \(bind: dispatch)").first(decoding: PushSuppressionStateRow.self))
            let budget = try #require(try await sql.raw("SELECT used_work_units, used_new_key_operations FROM im_v2.push_device_budgets WHERE device_id = \(bind: device)").first(decoding: PushBudgetRow.self))
            #expect(state.state == "suppressed")
            #expect(state.suppressionReason == "conversation_muted")
            #expect(budget.usedWorkUnits == 0)
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
                INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at)
                VALUES (\(bind: senderUUID), \(bind: UUID(uuidString: deviceID.rawValue)!), \(bind: now), \(bind: now))
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
            let plannerRouter = V2PostgresUserShardRouter(database: app.db(.psql))
            try await sql.raw("""
                INSERT INTO im_v2.user_shard_route_overrides
                    (user_id, write_bucket, read_fallback_bucket, router_epoch, updated_at)
                VALUES (\(bind: memberThreeUUID), 'test-users-override', NULL, 10, \(bind: now))
                """).run()
            // Fail the second page inside the set-based INSERT. This verifies
            // the first page remains durable while the failed page leaves no
            // completion unit, delivery or checkpoint behind.
            try await sql.raw("""
                CREATE FUNCTION im_v2.fail_second_set_based_planner_page()
                RETURNS trigger
                LANGUAGE plpgsql
                AS $$
                BEGIN
                    IF NEW.target_user_id = \(literal: memberTwoUUID.uuidString)::uuid THEN
                        RAISE EXCEPTION 'test fanout planner interruption';
                    END IF;
                    RETURN NEW;
                END;
                $$;
                """).run()
            try await sql.raw("""
                CREATE TRIGGER fanout_deliveries_fail_second_set_based_page
                BEFORE INSERT ON im_v2.fanout_deliveries
                FOR EACH ROW EXECUTE FUNCTION im_v2.fail_second_set_based_planner_page()
                """).run()

            await #expect(throws: (any Error).self) {
                try await V2FanoutPlanner(
                    store: PostgresV2FanoutPlanStore(
                        database: app.db(.psql)
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
            try await sql.raw("DROP TRIGGER fanout_deliveries_fail_second_set_based_page ON im_v2.fanout_deliveries").run()
            try await sql.raw("DROP FUNCTION im_v2.fail_second_set_based_planner_page()").run()

            let resumed = try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(database: app.db(.psql)),
                pageSize: 1,
                now: { now.addingTimeInterval(3) }
            ).plan(plannerTrigger)
            let overriddenRoute = try #require(try await sql.raw("""
                SELECT target_shard_bucket, observed_router_epoch
                FROM im_v2.fanout_deliveries
                WHERE source_event_id = \(bind: trigger.sourceEventID)
                  AND target_user_id = \(bind: memberThreeUUID)
                """).first(decoding: FanoutRouteAssertionRow.self))
            let delivery = try await V2FanoutDeliveryWorker(
                store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)),
                router: plannerRouter,
                now: { now.addingTimeInterval(4) }
            ).runOnce(limit: 8)
            let release = try await V2FanoutCompletionReleaseWorker(
                store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)),
                now: { now.addingTimeInterval(4) }
            ).runOnce(limit: 8)

            #expect(interrupted.state == "planning")
            #expect(interrupted.afterUserID == senderUUID.uuidString)
            #expect(interruptedCompletionUnits == 1)
            #expect(interruptedDeliveries == 1)
            #expect(prematureDelivery == .init(claimedCount: 0, committedCount: 0, staleCount: 0, releasedCount: 0))
            #expect(resumed == .init(createdCompletionUnits: 2, createdDeliveries: 2, wasAlreadyPlanned: false))
            #expect(overriddenRoute.bucket == "test-users-override")
            #expect(overriddenRoute.epoch == 10)
            #expect(delivery == .init(claimedCount: 3, committedCount: 3, staleCount: 0, releasedCount: 0))
            #expect(release == .init(releasedCount: 3, closedPlanCount: 1))
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

    @Test("relay and delivery persist multiple source events as fenced database batches")
    func relayUsesSetBasedPlanAndOutboxBatches() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4),
                as: .psql,
                isDefault: true
            )
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
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
                maxEnumerationPageSize: 2,
                maxPlannerConcurrency: 1,
                maxDeliveryConcurrency: 1,
                retryAfterSeconds: 3
            ))
            let service = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: app.db(.psql)),
                capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64),
                now: { now }
            )
            for (operation, text) in [
                ("00000000-0000-0000-0000-0000000000b1", "batch one"),
                ("00000000-0000-0000-0000-0000000000b2", "batch two"),
            ] {
                guard case .accepted = try await service.send(.init(
                    roomID: roomID,
                    actorUserID: senderID,
                    clientMessageID: try .init(operation),
                    text: text
                )) else {
                    Issue.record("expected accepted message")
                    return
                }
            }

            let planner = V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(database: app.db(.psql)),
                pageSize: 2,
                now: { now.addingTimeInterval(1) }
            )
            let triggers = try await sql.raw("""
                SELECT source_event_id, plan_id
                FROM im_v2.room_outbox
                ORDER BY created_at, source_event_id
                """).all(decoding: TriggerRow.self).map {
                    try V2FanoutPlanTrigger(
                        sourceEventID: .init($0.sourceEventID.uuidString),
                        planID: .init($0.planID.uuidString)
                    )
                }
            #expect(try await planner.planBatch(triggers) == [
                .init(createdCompletionUnits: 2, createdDeliveries: 3, wasAlreadyPlanned: false),
                .init(createdCompletionUnits: 2, createdDeliveries: 3, wasAlreadyPlanned: false),
            ])
            let relay = V2OutboxRelay(
                store: PostgresV2RoomOutboxStore(database: app.db(.psql)),
                publisher: V2LocalFanoutPlanPublisher(planner: planner),
                now: { now.addingTimeInterval(1) }
            )
            #expect(try await relay.runOnce(limit: 8) == .init(
                claimedCount: 2,
                publishedCount: 2,
                releasedCount: 0
            ))
            #expect(try await relay.runOnce(limit: 8) == .init(
                claimedCount: 0,
                publishedCount: 0,
                releasedCount: 0
            ))
            #expect(try await count("im_v2.fanout_plans WHERE state = 'planned' AND enumerated_target_count = target_count", on: sql) == 2)
            #expect(try await count("im_v2.room_outbox WHERE state = 'published' AND claim_token IS NULL", on: sql) == 2)
            #expect(try await count("im_v2.fanout_completion_units", on: sql) == 4)
            #expect(try await count("im_v2.fanout_deliveries", on: sql) == 6)

            // A completed inbox effect is immutable. Besides avoiding a
            // second heap version and index rewrite per target, inserting its
            // sequence in the original row means migration/compaction can
            // never observe a half-recorded result inside this transaction.
            // Make that physical write-shape a regression invariant instead
            // of relying on PostgreSQL statistics from a benchmark.
            try await sql.raw("""
                CREATE FUNCTION im_v2.reject_consumer_inbox_update()
                RETURNS trigger
                LANGUAGE plpgsql
                AS $$
                BEGIN
                    RAISE EXCEPTION 'consumer inbox results must be insert-only';
                END;
                $$;
                """).run()
            try await sql.raw("""
                CREATE TRIGGER consumer_inbox_result_must_be_insert_only
                BEFORE UPDATE ON im_v2.consumer_inbox
                FOR EACH ROW EXECUTE FUNCTION im_v2.reject_consumer_inbox_update()
                """).run()
            let delivery = try await V2FanoutDeliveryWorker(
                store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)),
                now: { now.addingTimeInterval(2) }
            ).runOnce(limit: 8)
            #expect(delivery == .init(
                claimedCount: 6,
                committedCount: 6,
                staleCount: 0,
                releasedCount: 0
            ))
            #expect(try await count(
                "im_v2.consumer_inbox WHERE user_sync_sequence IS NOT NULL",
                on: sql
            ) == 6)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 6)

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
            try await sql.raw("INSERT INTO im_v2.public_user_profiles (user_id, public_handle, display_name, revision, created_at, updated_at) VALUES (\(bind: senderUUID), 'sender012', '发送者', 1, \(bind: now), \(bind: now)), (\(bind: memberTwoUUID), 'member015', '成员二', 1, \(bind: now), \(bind: now)), (\(bind: memberThreeUUID), 'member016', '成员三', 1, \(bind: now), \(bind: now))").run()
            let directStore = PostgresV2DirectMessagingStore(database: app.db(.psql))
            let directService = try V2DirectMessagingService(store: directStore, capacityProfile: profile, roomShardID: "rooms-primary", now: { now })
            let recipient = try UserID(memberTwoUUID.uuidString)
            let opened = try await directService.open(actorUserID: senderID, operationID: try .init("00000000-0000-0000-0000-000000000072"), targetUserID: recipient)
            guard case .opened(let room) = opened else { Issue.record("expected direct room"); return }
            let replay = try await directService.open(actorUserID: senderID, operationID: try .init("00000000-0000-0000-0000-000000000072"), targetUserID: recipient)
            guard case .idempotent(let replayed) = replay else { Issue.record("expected idempotent room"); return }
            #expect(replayed.roomID == room.roomID)
            let directProfiles = try await sql.raw("""
                SELECT user_id, payload->>'room_id' AS room_id, payload->>'target_user_id' AS target_user_id,
                       payload->>'public_handle' AS public_handle, payload->>'display_name' AS display_name,
                       (payload->>'revision')::bigint AS revision
                FROM im_v2.user_sync_log
                WHERE projection_kind = 'direct_room_profile'
                ORDER BY user_id
                """).all(decoding: DirectProfileSyncAssertionRow.self)
            #expect(directProfiles == [
                .init(userID: senderUUID, roomID: room.roomID.rawValue.uppercased(), targetUserID: memberTwoUUID, publicHandle: "member015", displayName: "成员二", revision: 1),
            ])
            let openedPairState = try #require(try await sql.raw("""
                SELECT lower_profile_visible_to_higher, higher_profile_visible_to_lower,
                       lower_can_send, higher_can_send
                FROM im_v2.direct_room_pairs
                WHERE room_id = \(bind: UUID(uuidString: room.roomID.rawValue)!)
                """).first(decoding: DirectPairProjectionStateAssertionRow.self))
            #expect(openedPairState == .init(
                lowerProfileVisibleToHigher: false,
                higherProfileVisibleToLower: true,
                lowerCanSend: nil,
                higherCanSend: nil
            ))
            try await drainV3Projection(database: app.db(.psql))
            let snapshotDirectProfiles = try await currentV3ProjectionItems(sql: sql, userID: senderID, kind: "direct_room_profile")
            #expect(snapshotDirectProfiles.count == 1)
            #expect(snapshotDirectProfiles.first?.entityKey == room.roomID.rawValue)
            #expect(snapshotDirectProfiles.first?.string("target_user_id") == recipient.rawValue)
            // Account-owned add permissions are present in delivered history,
            // but a reset must rebuild them from their authoritative table.
            // This also proves the materializer accepts the non-message record.
            _ = try await directService.setUserAddPermission(
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000082"),
                permission: .deny
            )
            try await drainV3Projection(database: app.db(.psql))
            let userAddPreferences = try await currentV3ProjectionItems(sql: sql, userID: senderID, kind: "user_add_permission")
            #expect(userAddPreferences.count == 1)
            #expect(userAddPreferences.first?.bool("allows_being_added") == false)

            _ = try await directService.setStrangerMessagePermission(actorUserID: recipient, operationID: try .init("00000000-0000-0000-0000-000000000073"), permission: .deny)
            let otherRecipient = try UserID(memberThreeUUID.uuidString)
            let otherOpened = try await directService.open(actorUserID: senderID, operationID: try .init("00000000-0000-0000-0000-000000000083"), targetUserID: otherRecipient)
            guard case .opened(let otherRoom) = otherOpened else { Issue.record("expected second direct room"); return }
            let readReceipts = V2ReadReceiptService(
                store: PostgresV2ReadReceiptStore(database: app.db(.psql)),
                now: { now }
            )
            let preferenceOperationID = try ReadReceiptPreferenceOperationID("00000000-0000-0000-0000-000000000084")
            let disabledReceipts = try await readReceipts.setPreferences(
                actorUserID: senderID,
                operationID: preferenceOperationID,
                allowsDirectReadReceipts: false,
                allowsGroupReadReceipts: true
            )
            guard case .updated(let receiptPreferences) = disabledReceipts else {
                Issue.record("expected read-receipt preferences to update")
                return
            }
            let replayedPreferences = try await readReceipts.setPreferences(
                actorUserID: senderID,
                operationID: preferenceOperationID,
                allowsDirectReadReceipts: false,
                allowsGroupReadReceipts: true
            )
            #expect(replayedPreferences == .idempotent(receiptPreferences))
            let beforePropagation = try #require(try await sql.raw("SELECT COUNT(*)::int AS value, COUNT(DISTINCT source_event_id)::int AS distinct_sources FROM im_v2.user_sync_log WHERE projection_kind = 'direct_read_receipt'").first(decoding: ReceiptTombstoneCountAssertionRow.self))
            #expect(beforePropagation.value == 0)
            let receiptPropagation = V2ReadReceiptPreferencePropagationWorker(
                database: app.db(.psql),
                shadowForwarder: SuccessfulProjectionShadowForwarder(),
                now: { now }
            )
            #expect(try await receiptPropagation.runOnce(limit: 1) == .init(
                claimedOperationCount: 1,
                projectedRoomCount: 1,
                completedOperationCount: 0
            ))
            #expect(try await receiptPropagation.runOnce(limit: 1) == .init(
                claimedOperationCount: 1,
                projectedRoomCount: 1,
                completedOperationCount: 1
            ))
            let receiptTombstones = try #require(try await sql.raw("SELECT COUNT(*)::int AS value, COUNT(DISTINCT source_event_id)::int AS distinct_sources FROM im_v2.user_sync_log WHERE projection_kind = 'direct_read_receipt'").first(decoding: ReceiptTombstoneCountAssertionRow.self))
            #expect(receiptTombstones.value == 4)
            #expect(receiptTombstones.distinctSources == 2)
            _ = try await readReceipts.setPreferences(
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000085"),
                allowsDirectReadReceipts: true,
                allowsGroupReadReceipts: true
            )
            let retryPreferenceOperationID = try ReadReceiptPreferenceOperationID("00000000-0000-0000-0000-000000000086")
            _ = try await readReceipts.setPreferences(
                actorUserID: senderID,
                operationID: retryPreferenceOperationID,
                allowsDirectReadReceipts: false,
                allowsGroupReadReceipts: true
            )
            let interruptedPropagation = V2ReadReceiptPreferencePropagationWorker(
                database: app.db(.psql),
                shadowForwarder: ProfilePropagationFailingShadowForwarder(),
                retryPolicy: .init(maximumAttempts: 1),
                now: { now }
            )
            #expect(try await interruptedPropagation.runOnce(limit: 1) == .init(
                claimedOperationCount: 1,
                projectedRoomCount: 0,
                completedOperationCount: 0,
                pausedOperationCount: 1
            ))
            let pausedPropagation = try #require(try await sql.raw("SELECT state, retry_count FROM im_v2.read_receipt_preference_propagation_outbox WHERE actor_user_id = \(bind: senderUUID) AND operation_id = \(bind: UUID(uuidString: retryPreferenceOperationID.rawValue)!)").first(decoding: DurableRetryStateRow.self))
            #expect(pausedPropagation.state == "paused")
            #expect(pausedPropagation.retryCount == 1)
            let replayResult = try await PostgresV2DurableWorkReplayStore(database: app.db(.psql)).replay(
                .init(
                    operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000087")!,
                    target: try .init(
                        kind: .readReceiptPreferencePropagation,
                        sourceEventID: .init(retryPreferenceOperationID.rawValue),
                        targetUserID: senderID
                    ),
                    reason: .dependencyRecovered
                ),
                operatorPrincipal: "integration-test",
                now: now
            )
            #expect(replayResult.outcome == .requeued)
            let messageShadowRecorder = RecordingProjectionShadowForwarder()
            try await V2PostgresUserShardRouter(database: app.db(.psql)).bootstrap(
                defaultRoute: try .init(bucket: "test-users", observedRouterEpoch: 9)
            )
            let writer = PostgresV2RoomWriteStore(
                database: app.db(.psql),
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 3, window: 86_400),
                shadowForwarder: messageShadowRecorder,
                contentReviewMode: .enabled,
                directFanoutMode: .preplanned,
                payloadWriteMode: .reference
            )
            let messages = V2SendMessageService(store: writer, capacityProfile: profile, limits: try .init(maxUTF8Bytes: 64), now: { now })
            let deniedOutcome = try await messages.send(.init(roomID: room.roomID, actorUserID: senderID, clientMessageID: try .init("00000000-0000-0000-0000-000000000074"), text: "blocked-by-setting"))
            guard case .denied(let denial) = deniedOutcome else {
                Issue.record("expected a durable private denial")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            #expect(denial.reason == .generic)
            let crossRoomReplay = try await messages.send(.init(
                roomID: otherRoom.roomID,
                actorUserID: senderID,
                clientMessageID: try .init("00000000-0000-0000-0000-000000000074"),
                text: "must-not-rebind-denial"
            ))
            #expect(crossRoomReplay == .idempotencyConflict)
            let denialActivity = try #require(try await sql.raw("SELECT activity_type FROM im_v2.room_timeline_activities WHERE source_event_id = \(bind: UUID(uuidString: denial.sourceEventID.rawValue)!)").first(decoding: TimelineActivityTypeAssertionRow.self))
            #expect(denialActivity.activityType == "direct_message_restricted")
            let deniedRecipientProfiles = try #require(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE user_id = \(bind: memberTwoUUID) AND projection_kind = 'direct_room_profile'").first(decoding: CountRow.self))
            #expect(deniedRecipientProfiles.value == 0)
            let deniedPairState = try #require(try await sql.raw("""
                SELECT lower_profile_visible_to_higher, higher_profile_visible_to_lower,
                       lower_can_send, higher_can_send
                FROM im_v2.direct_room_pairs
                WHERE room_id = \(bind: UUID(uuidString: room.roomID.rawValue)!)
                """).first(decoding: DirectPairProjectionStateAssertionRow.self))
            #expect(deniedPairState.lowerCanSend == false)

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
            let acceptedRecipientProfiles = try #require(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE user_id = \(bind: memberTwoUUID) AND projection_kind = 'direct_room_profile' AND payload->>'room_id' = \(bind: room.roomID.rawValue)").first(decoding: CountRow.self))
            #expect(acceptedRecipientProfiles.value == 1)
            let acceptedPairState = try #require(try await sql.raw("""
                SELECT lower_profile_visible_to_higher, higher_profile_visible_to_lower,
                       lower_can_send, higher_can_send
                FROM im_v2.direct_room_pairs
                WHERE room_id = \(bind: UUID(uuidString: room.roomID.rawValue)!)
                """).first(decoding: DirectPairProjectionStateAssertionRow.self))
            #expect(acceptedPairState.lowerProfileVisibleToHigher)
            #expect(acceptedPairState.higherProfileVisibleToLower)
            #expect(acceptedPairState.lowerCanSend == true)
            #expect(acceptedPairState.higherCanSend == nil)
            let reply = try await messages.send(.init(roomID: room.roomID, actorUserID: recipient, clientMessageID: try .init("00000000-0000-0000-0000-000000000080"), text: "reply"))
            guard case .accepted = reply else { Issue.record("expected reply"); return }
            let repliedPairState = try #require(try await sql.raw("""
                SELECT lower_profile_visible_to_higher, higher_profile_visible_to_lower,
                       lower_can_send, higher_can_send
                FROM im_v2.direct_room_pairs
                WHERE room_id = \(bind: UUID(uuidString: room.roomID.rawValue)!)
                """).first(decoding: DirectPairProjectionStateAssertionRow.self))
            #expect(repliedPairState.lowerCanSend == true)
            #expect(repliedPairState.higherCanSend == true)
            let shadowsBeforeEstablishedMessage = await messageShadowRecorder.requestCount()
            let afterReply = try await messages.send(.init(roomID: room.roomID, actorUserID: senderID, clientMessageID: try .init("00000000-0000-0000-0000-000000000081"), text: "unlimited-after-reply"))
            guard case .accepted = afterReply else { Issue.record("expected post-reply message"); return }
            #expect(await messageShadowRecorder.requestCount() == shadowsBeforeEstablishedMessage)
            let afterReplyReplay = try await messages.send(.init(roomID: room.roomID, actorUserID: senderID, clientMessageID: try .init("00000000-0000-0000-0000-000000000081"), text: "unlimited-after-reply"))
            guard case .idempotent = afterReplyReplay else { Issue.record("expected idempotent post-reply message"); return }
            // A replay deliberately retains the lookup-based shadow path so a
            // crash between source commit and forwarding can recover it.
            #expect(await messageShadowRecorder.requestCount() == shadowsBeforeEstablishedMessage + 2)
            let window = try #require(try await sql.raw("SELECT message_count FROM im_v2.stranger_message_windows WHERE sender_user_id = \(bind: senderUUID) AND recipient_user_id = \(bind: memberTwoUUID)").first(decoding: StrangerWindowAssertionRow.self))
            #expect(window.messageCount == 3)
            let racedClientID = try ClientMessageID("00000000-0000-0000-0000-000000000089")
            async let firstRoomRace = messages.send(.init(
                roomID: room.roomID,
                actorUserID: senderID,
                clientMessageID: racedClientID,
                text: "one-operation-namespace"
            ))
            async let secondRoomRace = messages.send(.init(
                roomID: otherRoom.roomID,
                actorUserID: senderID,
                clientMessageID: racedClientID,
                text: "one-operation-namespace"
            ))
            let racedOutcomes = try await [firstRoomRace, secondRoomRace]
            #expect(racedOutcomes.filter {
                if case .accepted = $0 { return true }
                return false
            }.count == 1)
            #expect(racedOutcomes.filter { $0 == .idempotencyConflict }.count == 1)
            let racedClientUUID = UUID(uuidString: racedClientID.rawValue)!
            let racedPersistence = try #require(try await sql.raw("""
                SELECT
                    (SELECT COUNT(*) FROM im_v2.messages
                     WHERE sender_user_id = \(bind: senderUUID)
                       AND client_message_id = \(bind: racedClientUUID)) AS accepted_count,
                    (SELECT COUNT(*) FROM im_v2.direct_message_denials
                     WHERE sender_user_id = \(bind: senderUUID)
                       AND client_message_id = \(bind: racedClientUUID)) AS denied_count
                """).first(decoding: MessageOperationCardinalityAssertionRow.self))
            #expect(racedPersistence == .init(acceptedCount: 1, deniedCount: 0))
            let acceptedEventCount = try await count(
                "im_v2.room_events WHERE event_type = 'message.accepted'",
                on: sql
            )
            #expect(acceptedEventCount > 0)
            #expect(try await count(
                "im_v2.fanout_plans WHERE target_rule->>'planning_strategy' = 'direct_preplanned' AND state = 'planned' AND enumerated_target_count = 2",
                on: sql
            ) == acceptedEventCount)
            #expect(try await count(
                "im_v2.room_outbox AS outbox JOIN im_v2.room_events AS event ON event.event_id = outbox.source_event_id WHERE event.event_type = 'message.accepted'",
                on: sql
            ) == 0)
            #expect(try await count(
                "im_v2.fanout_completion_units AS unit JOIN im_v2.room_events AS event ON event.event_id = unit.source_event_id WHERE event.event_type = 'message.accepted' AND unit.target_count = 2",
                on: sql
            ) == acceptedEventCount)
            #expect(try await count(
                "im_v2.fanout_deliveries AS delivery JOIN im_v2.room_events AS event ON event.event_id = delivery.source_event_id WHERE event.event_type = 'message.accepted'",
                on: sql
            ) == acceptedEventCount * 2)
            #expect(try await count(
                "im_v2.fanout_deliveries AS delivery JOIN im_v2.room_events AS event ON event.event_id = delivery.source_event_id WHERE event.event_type = 'message.accepted' AND delivery.fresh_direct_eligible",
                on: sql
            ) == acceptedEventCount * 2)
            #expect(try await count(
                "im_v2.fanout_sync_payloads AS shared JOIN im_v2.room_events AS event ON event.event_id = shared.source_event_id WHERE event.event_type = 'message.accepted' AND shared.payload IS NULL AND shared.message_state_id IS NOT NULL",
                on: sql
            ) == acceptedEventCount)

            let directDeliveryControl = PostgresV2FanoutDeliveryStore(
                database: app.db(.psql), payloadWriteMode: .reference
            )
            let directDeliveryRegistry = try V2StaticUserShardStorageRegistry(
                locations: [try .init(
                    bucket: "test-users", database: app.db(.psql), schema: "im_v2"
                )]
            )
            let directDeliveryWorker = V2FanoutDeliveryWorker(
                store: V2CrossStoreFanoutDeliveryStore(
                    control: directDeliveryControl,
                    registry: directDeliveryRegistry,
                    migrations: PostgresV2UserShardMigrationStore(database: app.db(.psql)),
                    coLocatedControlBucket: "test-users",
                    payloadWriteMode: .reference
                ),
                bucket: "test-users",
                now: { now.addingTimeInterval(1) }
            )
            while try await directDeliveryWorker.runOnce(limit: 128).claimedCount > 0 {}
            #expect(try await count(
                "im_v2.fanout_deliveries AS delivery JOIN im_v2.room_events AS event ON event.event_id = delivery.source_event_id WHERE event.event_type = 'message.accepted' AND delivery.state = 'terminal' AND delivery.retry_count = 0 AND delivery.claim_token IS NULL AND delivery.lease_expires_at IS NULL",
                on: sql
            ) == acceptedEventCount * 2)
            #expect(try await count(
                "im_v2.fanout_sync_payloads AS shared JOIN im_v2.room_events AS event ON event.event_id = shared.source_event_id WHERE event.event_type = 'message.accepted' AND shared.payload IS NULL AND shared.message_state_id IS NOT NULL",
                on: sql
            ) == acceptedEventCount)
            #expect(try await count(
                "im_v2.fanout_sync_payloads AS shared JOIN im_v2.message_projection_state_values AS state ON state.state_id = shared.message_state_id JOIN im_v2.room_events AS event ON event.event_id = shared.source_event_id WHERE event.event_type = 'message.accepted' AND COALESCE(shared.payload, state.payload) = event.payload",
                on: sql
            ) == acceptedEventCount)
            // Simulate one body-mode row left by an older process. The
            // bounded online backfill must link and compact only an exact
            // accepted-message match.
            try await sql.raw("""
                WITH legacy AS (
                    SELECT shared.source_event_id,
                           jsonb_set(state.payload, '{text}', to_jsonb('tampered'::text)) AS payload
                    FROM im_v2.fanout_sync_payloads AS shared
                    JOIN im_v2.message_projection_state_values AS state
                      ON state.state_id = shared.message_state_id
                    JOIN im_v2.room_events AS event
                      ON event.event_id = shared.source_event_id
                     AND event.event_type = 'message.accepted'
                    ORDER BY shared.source_event_id
                    LIMIT 1
                )
                UPDATE im_v2.fanout_sync_payloads AS shared
                SET payload = legacy.payload, message_state_id = NULL
                FROM legacy
                WHERE shared.source_event_id = legacy.source_event_id
                  AND shared.projection_kind = 'message'
                """).run()
            #expect(try await PostgresV2FanoutPayloadReferenceBackfillWorker(
                database: app.db(.psql)
            ).runOnce(limit: 128) == .init(linkedRowCount: 0, compactedRowCount: 0))
            #expect(try await count(
                "im_v2.fanout_sync_payloads AS shared JOIN im_v2.room_events AS event ON event.event_id = shared.source_event_id WHERE event.event_type = 'message.accepted' AND shared.payload IS NOT NULL AND shared.message_state_id IS NULL",
                on: sql
            ) == 1)
            try await sql.raw("""
                UPDATE im_v2.fanout_sync_payloads AS shared
                SET payload = state.payload
                FROM im_v2.message_projection_state_values AS state
                WHERE state.state_event_id = shared.source_event_id
                  AND state.variant_key = 0
                  AND shared.projection_kind = 'message'
                  AND shared.message_state_id IS NULL
                """).run()
            #expect(try await PostgresV2FanoutPayloadReferenceBackfillWorker(
                database: app.db(.psql)
            ).runOnce(limit: 1) == .init(linkedRowCount: 1, compactedRowCount: 1))
            #expect(try await count(
                "im_v2.fanout_sync_payloads AS shared JOIN im_v2.room_events AS event ON event.event_id = shared.source_event_id WHERE event.event_type = 'message.accepted' AND shared.payload IS NULL AND shared.message_state_id IS NOT NULL",
                on: sql
            ) == acceptedEventCount)
            let directRelease = try await drainFanoutCompletionReleases(
                database: app.db(.psql),
                now: { now.addingTimeInterval(2) }
            )
            #expect(directRelease.releasedCount == Int(acceptedEventCount))
            #expect(try await count(
                "im_v2.fanout_plans WHERE target_rule->>'planning_strategy' = 'direct_preplanned' AND state = 'terminal'",
                on: sql
            ) == acceptedEventCount)

            // Route configuration is operational state, not authorization.
            // If it is briefly unavailable, acceptance must use the old
            // durable planner lane with no partial direct deliveries.
            try await sql.raw("DELETE FROM im_v2.user_shard_router_configuration").run()
            let fallbackOutcome = try await messages.send(.init(
                roomID: room.roomID,
                actorUserID: senderID,
                clientMessageID: try .init("00000000-0000-0000-0000-000000000091"),
                text: "route-fallback"
            ))
            guard case .accepted(let fallbackMessage) = fallbackOutcome else {
                Issue.record("expected planner fallback acceptance")
                return
            }
            let fallbackTrigger = try #require(try await sql.raw("""
                SELECT outbox.source_event_id, outbox.plan_id
                FROM im_v2.room_outbox AS outbox
                JOIN im_v2.room_events AS event
                  ON event.event_id = outbox.source_event_id
                WHERE event.payload->>'message_id' = \(bind: fallbackMessage.messageID.rawValue)
                """).first(decoding: TriggerRow.self))
            #expect(try #require(try await sql.raw("""
                SELECT COUNT(*)::bigint AS value
                FROM im_v2.fanout_completion_units
                WHERE source_event_id = \(bind: fallbackTrigger.sourceEventID)
                """).first(decoding: CountRow.self)).value == 0)
            #expect(try #require(try await sql.raw("""
                SELECT COUNT(*)::bigint AS value
                FROM im_v2.fanout_deliveries
                WHERE source_event_id = \(bind: fallbackTrigger.sourceEventID)
                """).first(decoding: CountRow.self)).value == 0)
            try await configureDefaultUserShardRoute(
                .init(bucket: "test-users", observedRouterEpoch: 9),
                now: now.addingTimeInterval(3),
                on: sql
            )
            let fallbackPlanning = try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(database: app.db(.psql)),
                pageSize: 10,
                now: { now.addingTimeInterval(4) }
            ).plan(.init(
                sourceEventID: try .init(fallbackTrigger.sourceEventID.uuidString),
                planID: try .init(fallbackTrigger.planID.uuidString)
            ))
            #expect(fallbackPlanning.createdDeliveries == 2)
            #expect(fallbackPlanning.createdCompletionUnits == 1)
            let fallbackDeliveryWorker = V2FanoutDeliveryWorker(
                store: PostgresV2FanoutDeliveryStore(
                    database: app.db(.psql),
                    payloadWriteMode: .reference
                ),
                now: { now.addingTimeInterval(5) }
            )
            #expect(try await count(
                "im_v2.fanout_deliveries WHERE source_event_id = '\(fallbackTrigger.sourceEventID.uuidString)' AND NOT fresh_direct_eligible",
                on: sql
            ) == 2)
            while try await fallbackDeliveryWorker.runOnce(limit: 16).claimedCount > 0 {}
            let fallbackRelease = try await drainFanoutCompletionReleases(
                database: app.db(.psql),
                now: { now.addingTimeInterval(6) }
            )
            #expect(fallbackRelease.releasedCount == 1)

            // A corrupt direct audience must fail closed. The authoritative
            // pair still names two users, but the revision-fenced membership
            // set below contains one. Verify that the surrounding transaction
            // leaves no accepted message or partial fan-out artifacts.
            try await sql.raw("""
                UPDATE im_v2.rooms
                SET membership_revision = 1
                WHERE room_id = \(bind: UUID(uuidString: room.roomID.rawValue)!)
                """).run()
            try await sql.raw("""
                UPDATE im_v2.room_memberships
                SET left_revision = 1
                WHERE room_id = \(bind: UUID(uuidString: room.roomID.rawValue)!)
                  AND user_id = \(bind: memberTwoUUID)
                """).run()
            let beforeCorruptWrite = try await directWriteArtifactCounts(sql: sql)
            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                try await messages.send(.init(
                    roomID: room.roomID,
                    actorUserID: senderID,
                    clientMessageID: try .init("00000000-0000-0000-0000-000000000092"),
                    text: "must-rollback"
                ))
            }
            #expect(try await directWriteArtifactCounts(sql: sql) == beforeCorruptWrite)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("independent direct-room creation shares the shard fence and rejects an existing pair under another profile")
    func directRoomCreationUsesSharedShardFence() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4),
                as: .psql,
                isDefault: true
            )
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_150_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10,
                maxCommandsPerWindow: 100,
                maxFanoutUnitsPerWindow: 100,
                maxOutstandingFanoutUnits: 100,
                maxOutstandingPlans: 100,
                maxEnumerationPageSize: 10,
                maxPlannerConcurrency: 1,
                maxDeliveryConcurrency: 1,
                retryAfterSeconds: 3
            ))
            let leaseID = UUID(uuidString: "00000000-0000-0000-0000-000000000151")!
            try await sql.raw("INSERT INTO im_v2.shard_admission_pools (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit, fanout_window_limit, max_outstanding_fanout_units, max_outstanding_plans) VALUES ('rooms-concurrent-direct', 'standard', \(bind: leaseID), 1, \(bind: now.addingTimeInterval(600)), 100, 100, 100, 100)").run()

            let users = (0..<4).map {
                UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", 0x160 + $0))!
            }
            for (index, userID) in users.enumerated() {
                try await sql.raw("INSERT INTO im_v2.public_user_profiles (user_id, public_handle, display_name, revision, created_at, updated_at) VALUES (\(bind: userID), \(bind: "direct_probe_\(index)"), \(bind: "并发用户\(index)"), 1, \(bind: now), \(bind: now))").run()
            }

            // The trigger sleeps after `open` has acquired the shard fence.
            // A sequence is deliberately used as a non-transactional probe:
            // both inserts can reach the trigger during the same sleep only
            // when their shard row locks are compatible.
            try await sql.raw("CREATE SEQUENCE im_v2.direct_room_shared_lock_probe").run()
            try await sql.raw("""
                CREATE FUNCTION im_v2.pause_direct_room_insert()
                RETURNS trigger
                LANGUAGE plpgsql
                AS $$
                BEGIN
                    PERFORM nextval('im_v2.direct_room_shared_lock_probe');
                    PERFORM pg_sleep(0.75);
                    RETURN NEW;
                END;
                $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER pause_direct_room_insert
                BEFORE INSERT ON im_v2.rooms
                FOR EACH ROW
                WHEN (NEW.room_kind = 'direct')
                EXECUTE FUNCTION im_v2.pause_direct_room_insert()
                """).run()

            let service = try V2DirectMessagingService(
                store: PostgresV2DirectMessagingStore(database: app.db(.psql)),
                capacityProfile: profile,
                roomShardID: "rooms-concurrent-direct",
                now: { now }
            )
            let firstOperation = try DirectRoomOperationID("00000000-0000-0000-0000-000000000170")
            let secondOperation = try DirectRoomOperationID("00000000-0000-0000-0000-000000000171")
            let first = Task {
                try await service.open(
                    actorUserID: try .init(users[0].uuidString),
                    operationID: firstOperation,
                    targetUserID: try .init(users[1].uuidString)
                )
            }

            let firstDeadline = Date().addingTimeInterval(2)
            while Date() < firstDeadline {
                let probe = try await sql.raw("SELECT last_value, is_called FROM im_v2.direct_room_shared_lock_probe").first(decoding: DirectRoomLockProbeRow.self)
                if probe?.isCalled == true { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let second = Task {
                try await service.open(
                    actorUserID: try .init(users[2].uuidString),
                    operationID: secondOperation,
                    targetUserID: try .init(users[3].uuidString)
                )
            }

            var bothReachedInsert = false
            let sharedLockDeadline = Date().addingTimeInterval(0.5)
            while Date() < sharedLockDeadline {
                let probe = try await sql.raw("SELECT last_value, is_called FROM im_v2.direct_room_shared_lock_probe").first(decoding: DirectRoomLockProbeRow.self)
                if probe?.isCalled == true, probe?.lastValue ?? 0 >= 2 {
                    bothReachedInsert = true
                    break
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(bothReachedInsert)

            guard case .opened(let firstRoom) = try await first.value,
                  case .opened = try await second.value
            else {
                Issue.record("expected both independent direct rooms to open")
                return
            }

            let otherProfile = try V2CapacityProfile(id: "next-profile", limits: profile.limits)
            let otherProfileService = try V2DirectMessagingService(
                store: PostgresV2DirectMessagingStore(database: app.db(.psql)),
                capacityProfile: otherProfile,
                roomShardID: "rooms-concurrent-direct",
                now: { now }
            )
            let mismatched = try await otherProfileService.open(
                actorUserID: try .init(users[0].uuidString),
                operationID: try .init("00000000-0000-0000-0000-000000000172"),
                targetUserID: try .init(users[1].uuidString)
            )
            #expect(mismatched == .unavailable)

            // A response-loss retry of the original immutable operation must
            // still return its canonical result after a deployment change.
            let replay = try await otherProfileService.open(
                actorUserID: try .init(users[0].uuidString),
                operationID: firstOperation,
                targetUserID: try .init(users[1].uuidString)
            )
            guard case .idempotent(let replayedRoom) = replay else {
                Issue.record("expected original operation replay")
                return
            }
            #expect(replayedRoom.roomID == firstRoom.roomID)

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
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, revision, created_at, updated_at)
                VALUES
                    (\(bind: senderUUID), 'groupowner82', '群主', 1, \(bind: now), \(bind: now)),
                    (\(bind: memberTwoUUID), 'groupmember82', '群成员', 1, \(bind: now), \(bind: now))
                """).run()
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
                store: PostgresV2FanoutPlanStore(database: app.db(.psql)),
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
            try await drainV3Projection(database: app.db(.psql))
            let profiles = try await currentV3ProjectionItems(sql: sql, userID: invitedUser, kind: "room")

            #expect(created.title == "V2 项目群")
            #expect(planning == .init(createdCompletionUnits: 2, createdDeliveries: 2, wasAlreadyPlanned: false))
            #expect(delivery == .init(claimedCount: 2, committedCount: 2, staleCount: 0, releasedCount: 0))
            #expect(roomRecord.sourceEventID.rawValue == trigger.sourceEventID.uuidString)
            #expect(payload["event_type"] as? String == "room.created")
            #expect(payload["room_id"] as? String == created.roomID.rawValue)
            #expect(payload["title"] as? String == "V2 项目群")
            #expect(payload["member_user_ids"] == nil)
            #expect(profiles.count == 1)
            #expect(profiles.first?.entityKey == created.roomID.rawValue)
            #expect(profiles.first?.string("title") == "V2 项目群")

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
                store: PostgresV2FanoutPlanStore(database: app.db(.psql)),
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

    /// This deliberately remains opt-in: four workers contend through leases
    /// while each bounded group of durable user-sync projections commits in
    /// one transaction. It is valuable end-to-end concurrency evidence but
    /// too expensive for each normal unit run. It is not a throughput
    /// benchmark; capacity release still needs the dated topology/workload
    /// report in `standard-100k.md`.
    @Test("opt-in 100,000-member fan-out drain preserves every durable projection and releases admission")
    func drainsOneHundredThousandMemberAudienceExactly() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1",
              Environment.get("IMV2_RUN_100K_DELIVERY_SOAK") == "1"
        else { return }

        let commitBatchSize: Int
        if let value = Environment.get("IMV2_FANOUT_COMMIT_BATCH_SIZE") {
            guard let parsed = Int(value), parsed > 0, parsed <= 1_000 else {
                throw TestConfigurationError.invalidFanoutCommitBatchSize(value)
            }
            commitBatchSize = parsed
        } else {
            commitBatchSize = 128
        }
        let deliveryClaimBatchSize: Int
        if let value = Environment.get("IMV2_FANOUT_DELIVERY_CLAIM_BATCH_SIZE") {
            guard let parsed = Int(value), parsed > 0, parsed <= 4_096 else {
                throw TestConfigurationError.invalidFanoutDeliveryClaimBatchSize(value)
            }
            deliveryClaimBatchSize = parsed
        } else {
            deliveryClaimBatchSize = 1_000
        }
        let plannerPageSize: Int
        if let value = Environment.get("IMV2_FANOUT_PLANNER_PAGE_SIZE") {
            guard let parsed = Int(value), parsed > 0, parsed <= 5_000 else {
                throw TestConfigurationError.invalidFanoutPlannerPageSize(value)
            }
            plannerPageSize = parsed
        } else {
            plannerPageSize = 1_000
        }
        let expectedCompletionUnitCount = (100_000 + plannerPageSize - 1) / plannerPageSize
        let injectFirstProjectionBatchFailure = Environment.get("IMV2_INJECT_100K_DELIVERY_BATCH_FAILURE") == "1"

        let workloadStartedAt = Date()
        let app = try await Application.make(.testing)
        do {
            // Four independently scheduled workers contend through PostgreSQL
            // leases. The pool cap is deliberately equal to the worker count:
            // the regression verifies concurrency without creating an
            // unbounded connection shape.
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            let synchronousCommit = try #require(try await sql.raw("SELECT current_setting('synchronous_commit') AS value").first(decoding: StringValueRow.self)).value
            let schemaStartedAt = Date()
            try await installSchema(on: sql)
            let schemaElapsedMilliseconds = v2LocalElapsedMilliseconds(since: schemaStartedAt)

            let seedStartedAt = Date()
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
            let seedElapsedMilliseconds = v2LocalElapsedMilliseconds(since: seedStartedAt)

            let trigger = try V2FanoutPlanTrigger(sourceEventID: .init(event.uuidString), planID: .init(plan.uuidString))
            // Exercise the production set-based planner path: member routing
            // comes from the same PostgreSQL control-plane relation instead
            // of the test-only in-memory single-bucket router.
            let plannerRouter = V2PostgresUserShardRouter(database: app.db(.psql))
            let planningStartedAt = Date()
            #expect(try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(database: app.db(.psql)),
                pageSize: plannerPageSize,
                now: { now }
            ).plan(trigger) == .init(
                createdCompletionUnits: expectedCompletionUnitCount,
                createdDeliveries: 100_000,
                wasAlreadyPlanned: false
            ))
            let planningElapsedMilliseconds = v2LocalElapsedMilliseconds(since: planningStartedAt)

            if injectFirstProjectionBatchFailure {
                // `nextval` is intentionally non-transactional. The first
                // inbox insert raises after advancing the sequence, so the
                // whole 128-target projection transaction rolls back once
                // while its later retry is allowed to succeed.
                try await sql.raw("""
                    CREATE SEQUENCE im_v2.test_first_projection_batch_failure
                    """).run()
                try await sql.raw("""
                    CREATE FUNCTION im_v2.fail_first_projection_batch() RETURNS trigger
                    LANGUAGE plpgsql AS $$
                    BEGIN
                        IF nextval('im_v2.test_first_projection_batch_failure') = 1 THEN
                            RAISE EXCEPTION 'injected fanout projection batch failure';
                        END IF;
                        RETURN NEW;
                    END;
                    $$;
                    """).run()
                try await sql.raw("""
                    CREATE TRIGGER fail_first_projection_batch
                    BEFORE INSERT ON im_v2.consumer_inbox
                    FOR EACH ROW EXECUTE FUNCTION im_v2.fail_first_projection_batch()
                    """).run()
            }

            let deliveryStore = PostgresV2FanoutDeliveryStore(database: app.db(.psql))
            let workerCount = 4
            let drainTracker = V2LocalFanoutDrainTracker(expectedCommitCount: 100_000)
            let retryPolicy = V2DurableRetryPolicy(
                initialDelay: 0.01,
                maximumDelay: 0.1,
                maximumAttempts: 10,
                jitterFraction: 0
            )
            let deliveryStartedAt = Date()
            let workerTimings = try await withThrowingTaskGroup(
                of: V2LocalFanoutDeliverySoakWorkerTiming.self,
                returning: [V2LocalFanoutDeliverySoakWorkerTiming].self
            ) { group in
                for _ in 0..<workerCount {
                    group.addTask {
                        let deliveryWorker = V2FanoutDeliveryWorker(
                            store: deliveryStore,
                            bucket: "test-users",
                            router: plannerRouter,
                            retryPolicy: retryPolicy,
                            commitBatchSize: commitBatchSize,
                            now: Date.init
                        )
                        let workerStartedAt = Date()
                        var claimedBatches = 0
                        var emptyBatches = 0
                        var aggregate = V2FanoutDeliveryReport(
                            claimedCount: 0, committedCount: 0, staleCount: 0,
                            staleRouteCount: 0, releasedCount: 0, pausedCount: 0
                        )
                        for _ in 0..<1_000 {
                            if await drainTracker.isComplete { break }
                            let report = try await deliveryWorker.runOnce(limit: deliveryClaimBatchSize)
                            if report.claimedCount > 0 { claimedBatches += 1 } else { emptyBatches += 1 }
                            aggregate = .init(
                                claimedCount: aggregate.claimedCount + report.claimedCount,
                                committedCount: aggregate.committedCount + report.committedCount,
                                staleCount: aggregate.staleCount + report.staleCount,
                                staleRouteCount: aggregate.staleRouteCount + report.staleRouteCount,
                                releasedCount: aggregate.releasedCount + report.releasedCount,
                                pausedCount: aggregate.pausedCount + report.pausedCount
                            )
                            if await drainTracker.record(committedCount: report.committedCount) { break }
                            if report.claimedCount == 0 {
                                try await Task.sleep(for: .milliseconds(10))
                            }
                        }
                        return .init(
                            report: aggregate,
                            elapsedMilliseconds: v2LocalElapsedMilliseconds(since: workerStartedAt),
                            claimedBatches: claimedBatches,
                            emptyBatches: emptyBatches
                        )
                    }
                }
                var values: [V2LocalFanoutDeliverySoakWorkerTiming] = []
                for try await timing in group { values.append(timing) }
                return values
            }
            let deliveryElapsedMilliseconds = v2LocalElapsedMilliseconds(since: deliveryStartedAt)
            let reports = workerTimings.map(\.report)
            let delivered = reports.reduce(0) { $0 + $1.committedCount }
            let stale = reports.reduce(0) { $0 + $1.staleCount }
            let staleRoutes = reports.reduce(0) { $0 + $1.staleRouteCount }
            let released = reports.reduce(0) { $0 + $1.releasedCount }
            let paused = reports.reduce(0) { $0 + $1.pausedCount }
            let drained = await drainTracker.isComplete
            #expect(drained)
            #expect(delivered == 100_000)
            #expect(stale == 0)
            #expect(staleRoutes == 0)
            #expect(released == (injectFirstProjectionBatchFailure ? commitBatchSize : 0))
            #expect(paused == 0)
            let finalDeliveryWorker = V2FanoutDeliveryWorker(
                store: deliveryStore,
                bucket: "test-users",
                router: plannerRouter,
                retryPolicy: retryPolicy,
                commitBatchSize: commitBatchSize,
                now: Date.init
            )
            #expect(try await finalDeliveryWorker.runOnce(limit: deliveryClaimBatchSize) == .init(claimedCount: 0, committedCount: 0, staleCount: 0, staleRouteCount: 0, releasedCount: 0))
            let completionRelease = try await drainFanoutCompletionReleases(
                database: app.db(.psql)
            )
            #expect(completionRelease.releasedCount == expectedCompletionUnitCount)
            #expect(completionRelease.closedPlanCount == 1)

            let verificationStartedAt = Date()
            let accounting = try #require(try await sql.raw("""
                SELECT
                    (SELECT COUNT(*) FROM im_v2.user_sync_log WHERE source_event_id = \(bind: event)) AS sync_records,
                    (SELECT COUNT(DISTINCT user_id) FROM im_v2.user_sync_log WHERE source_event_id = \(bind: event)) AS distinct_sync_recipients,
                    (SELECT COUNT(*) FROM im_v2.consumer_inbox WHERE source_event_id = \(bind: event)) AS inbox_records,
                    (SELECT COUNT(*) FROM im_v2.fanout_deliveries WHERE source_event_id = \(bind: event) AND state = 'terminal') AS terminal_deliveries,
                    (SELECT COUNT(*) FROM im_v2.fanout_completion_units WHERE source_event_id = \(bind: event) AND state = 'released') AS released_completion_units,
                    (SELECT state FROM im_v2.fanout_plans WHERE plan_id = \(bind: plan)) AS plan_state
                """).first(decoding: FanoutDeliveryScaleAccountingRow.self))
            let retryAccounting = try #require(try await sql.raw("""
                SELECT
                    COUNT(*) FILTER (WHERE retry_count = 2) AS retried_deliveries,
                    COALESCE(MAX(retry_count), 0) AS maximum_retry_count
                FROM im_v2.fanout_deliveries
                WHERE source_event_id = \(bind: event)
                """).first(decoding: FanoutDeliveryRetryAccountingRow.self))
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
            #expect(accounting.releasedCompletionUnits == Int64(expectedCompletionUnitCount))
            #expect(accounting.planState == "terminal")
            #expect(retryAccounting.retriedDeliveries == (injectFirstProjectionBatchFailure ? Int64(commitBatchSize) : 0))
            #expect(retryAccounting.maximumRetryCount == (injectFirstProjectionBatchFailure ? 2 : 1))
            #expect(roomReservation.outstandingFanoutUnits == 0)
            #expect(roomReservation.outstandingPlans == 0)
            #expect(shardReservation.outstandingFanoutUnits == 0)
            #expect(shardReservation.outstandingPlans == 0)
            let verificationElapsedMilliseconds = v2LocalElapsedMilliseconds(since: verificationStartedAt)
            print(V2LocalFanoutDeliverySoakTiming(
                commitBatchSize: commitBatchSize,
                deliveryClaimBatchSize: deliveryClaimBatchSize,
                plannerPageSize: plannerPageSize,
                synchronousCommit: synchronousCommit,
                injectedFirstProjectionBatchFailure: injectFirstProjectionBatchFailure,
                totalElapsedMilliseconds: v2LocalElapsedMilliseconds(since: workloadStartedAt),
                schemaElapsedMilliseconds: schemaElapsedMilliseconds,
                seedElapsedMilliseconds: seedElapsedMilliseconds,
                planningElapsedMilliseconds: planningElapsedMilliseconds,
                deliveryElapsedMilliseconds: deliveryElapsedMilliseconds,
                verificationElapsedMilliseconds: verificationElapsedMilliseconds,
                workerTimings: workerTimings
            ).machineReadableLine)

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

    /// Exercises the normal group-message path under a bounded burst: source
    /// acceptance serializes room sequence/admission, while relay/planning and
    /// delivery independently claim durable work. It is opt-in because the
    /// 16,000 receiver projections are deliberately larger than a unit test.
    /// The opt-in member/message knobs let the isolated capacity profile
    /// exercise the fixed standard-group ceiling (5,000 members) without
    /// maintaining a separate, lower-fidelity workload implementation.
    @Test("opt-in concurrent group-message burst preserves sequence, fan-out, and admission")
    func drainsConcurrentGroupMessageWorkload() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1",
              Environment.get("IMV2_RUN_CONCURRENT_ROOM_WORKLOAD") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let workload = try V2ConcurrentRoomWorkloadConfiguration()
            let messageCount = workload.messageCount
            let memberCount = workload.memberCount
            let plannerPageSize = workload.plannerPageSize
            let deliveryClaimBatchSize = workload.deliveryClaimBatchSize
            let eventPayloadBytes = workload.eventPayloadBytes
            let room = UUID(uuidString: "00000000-0000-0000-0000-000000001301")!
            let senderUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            let lease = UUID(uuidString: "00000000-0000-0000-0000-000000001302")!
            // This workload calls the real acceptance service with wall-clock
            // time, so its fenced admission lease must use that same domain.
            let now = Date()
            // Message admission now requires an active public profile for the
            // actor. Keep the capacity fixture on the same production
            // eligibility path instead of relying on membership alone.
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, revision, created_at, updated_at)
                VALUES (\(bind: senderUUID), 'capacity_sender', 'Capacity Sender', 1, \(bind: now), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id, created_at)
                VALUES (\(bind: room), 'capacity-concurrent-room', 'standard', \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until,
                     command_window_limit, fanout_window_limit,
                     max_outstanding_fanout_units, max_outstanding_plans)
                VALUES
                    ('capacity-concurrent-room', 'standard', \(bind: lease), 1, \(bind: now.addingTimeInterval(86_400)),
                     \(bind: messageCount), \(bind: messageCount * memberCount),
                     \(bind: messageCount * memberCount), \(bind: messageCount))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_admission
                    (room_id, eligible_member_count, command_window_limit, fanout_window_limit,
                     max_outstanding_fanout_units, max_outstanding_plans,
                     shard_lease_id, shard_lease_generation)
                VALUES
                    (\(bind: room), \(bind: memberCount), \(bind: messageCount), \(bind: messageCount * memberCount),
                     \(bind: messageCount * memberCount), \(bind: messageCount), \(bind: lease), 1)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision)
                SELECT \(bind: room),
                       ('00000000-0000-0000-0000-' || lpad(to_hex(member), 12, '0'))::uuid,
                       0
                FROM generate_series(1, \(bind: memberCount)) AS member
                """).run()
            // Match the running gateway: planning and delivery route through
            // the co-located PostgreSQL router, which enables the planner's
            // atomic set-based page path. The previous in-memory test router
            // exercised a deliberately slower cross-store fallback instead.
            let userShardRouter = V2PostgresUserShardRouter(database: app.db(.psql))

            let capacityProfile = try V2CapacityProfile(
                id: "standard",
                limits: .init(
                    maxEligibleMembers: memberCount,
                    maxCommandsPerWindow: messageCount,
                    maxFanoutUnitsPerWindow: messageCount * memberCount,
                    maxOutstandingFanoutUnits: messageCount * memberCount,
                    maxOutstandingPlans: messageCount,
                    maxEnumerationPageSize: plannerPageSize,
                    maxPlannerConcurrency: 4,
                    maxDeliveryConcurrency: 4,
                    retryAfterSeconds: 1
                )
            )
            let sender = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: app.db(.psql)),
                capacityProfile: capacityProfile,
                limits: try .init(maxUTF8Bytes: max(64, eventPayloadBytes)),
                now: Date.init
            )
            let roomID = try RoomID(room.uuidString)
            let senderID = try UserID(senderUUID.uuidString)
            let requests = try (0..<messageCount).map { index in
                V2AuthenticatedSendMessage(
                    roomID: roomID,
                    actorUserID: senderID,
                    clientMessageID: try .init(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", 0xD0000 + index))!.uuidString),
                    text: v2ConcurrentRoomMessageText(index: index, payloadBytes: eventPayloadBytes)
                )
            }
            // This is intentionally opt-in: resetting pg_stat_statements is
            // appropriate only for the disposable, isolated capacity
            // database. Capture a baseline after schema setup and seeding so
            // the report describes acceptance, planning and delivery rather
            // than migration or fixture cost.
            let postgresProfile = try await V2LocalPostgresDeliveryProfile.startIfEnabled(on: sql)
            let workloadStartedAt = Date()
            let acceptanceResults = try await withThrowingTaskGroup(
                of: ConcurrentRoomWriteAcceptanceResult.self,
                returning: [ConcurrentRoomWriteAcceptanceResult].self
            ) { group in
                for request in requests {
                    group.addTask {
                        let startedAt = Date()
                        let outcome = try await sender.send(request)
                        return .init(outcome: outcome, elapsedSeconds: Date().timeIntervalSince(startedAt))
                    }
                }
                var values: [ConcurrentRoomWriteAcceptanceResult] = []
                for try await outcome in group { values.append(outcome) }
                return values
            }
            #expect(acceptanceResults.count == messageCount)
            #expect(acceptanceResults.allSatisfy {
                if case .accepted = $0.outcome { return true }
                return false
            })

            let retryPolicy = V2DurableRetryPolicy(
                initialDelay: 0.01,
                maximumDelay: 0.1,
                maximumAttempts: 10,
                jitterFraction: 0
            )
            let relay = V2OutboxRelay(
                store: PostgresV2RoomOutboxStore(database: app.db(.psql)),
                publisher: V2LocalFanoutPlanPublisher(
                    planner: .init(
                        store: PostgresV2FanoutPlanStore(database: app.db(.psql)),
                        // Keep this capacity regression on the production
                        // standard-profile boundary (1,000 by default), not
                        // a single 5,000-member planner page. The latter
                        // hides completion-unit and plan-state behavior that
                        // the running gateway actually uses.
                        pageSize: plannerPageSize,
                        now: Date.init
                    )
                ),
                retryPolicy: retryPolicy,
                now: Date.init
            )
            let deliveryStore: any V2FanoutDeliveryStore
            if workload.forceGenericProjectionSequenceReservation {
                // Capacity A/B control for the ordinary distinct-recipient
                // fast path. The generic CTE remains the correctness fallback
                // for a batch that contains more than one source event for a
                // single user.
                deliveryStore = PostgresV2FanoutDeliveryStore(
                    database: app.db(.psql),
                    batchSequenceReservationStrategy: .forceGeneric
                )
            } else {
                // Exercise the actual gateway composition: a co-located
                // bucket still traverses the topology/migration boundary,
                // then delegates its projection to the control store's one
                // database transaction. This keeps the capacity profile from
                // bypassing claim-payload and migration-fence costs.
                let control = PostgresV2FanoutDeliveryStore(database: app.db(.psql))
                let registry = try V2StaticUserShardStorageRegistry(locations: [
                    try .init(bucket: "test-users", database: app.db(.psql), schema: "im_v2")
                ])
                deliveryStore = V2CrossStoreFanoutDeliveryStore(
                    control: control, registry: registry,
                    migrations: PostgresV2UserShardMigrationStore(database: app.db(.psql)),
                    coLocatedControlBucket: "test-users"
                )
            }
            let drainTracker = V2LocalFanoutDrainTracker(expectedCommitCount: messageCount * memberCount)
            // Production owns planning and delivery in independent scheduled
            // tasks. Start both at once so this regression measures the same
            // overlap instead of serializing every plan before the first
            // receiver projection can begin.
            async let relayReports: [V2OutboxRelayReport] = withThrowingTaskGroup(
                of: V2OutboxRelayReport.self,
                returning: [V2OutboxRelayReport].self
            ) { group in
                for _ in 0..<4 {
                    group.addTask {
                        var aggregate = V2OutboxRelayReport(claimedCount: 0, publishedCount: 0, releasedCount: 0, pausedCount: 0)
                        for _ in 0..<12 {
                            let report = try await relay.runOnce(limit: 1)
                            aggregate = .init(
                                claimedCount: aggregate.claimedCount + report.claimedCount,
                                publishedCount: aggregate.publishedCount + report.publishedCount,
                                releasedCount: aggregate.releasedCount + report.releasedCount,
                                pausedCount: aggregate.pausedCount + report.pausedCount
                            )
                            if report.claimedCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
                        }
                        return aggregate
                    }
                }
                var values: [V2OutboxRelayReport] = []
                for try await report in group { values.append(report) }
                return values
            }
            async let deliveryReports: [V2FanoutDeliveryReport] = withThrowingTaskGroup(
                of: V2FanoutDeliveryReport.self,
                returning: [V2FanoutDeliveryReport].self
            ) { group in
                for _ in 0..<workload.deliveryWorkerCount {
                    group.addTask {
                        let worker = V2FanoutDeliveryWorker(
                            store: deliveryStore,
                            bucket: "test-users",
                            router: userShardRouter,
                            retryPolicy: retryPolicy,
                            now: Date.init
                        )
                        var aggregate = V2FanoutDeliveryReport(
                            claimedCount: 0, committedCount: 0, staleCount: 0,
                            staleRouteCount: 0, releasedCount: 0, pausedCount: 0
                        )
                        // Claim passes can begin before planning has produced
                        // work. The shared durable-commit tracker, rather
                        // than a fixed empty-poll count, keeps each worker
                        // alive until the concurrent planner has drained.
                        for _ in 0..<1_000 {
                            if await drainTracker.isComplete { break }
                            let report = try await worker.runOnce(limit: deliveryClaimBatchSize)
                            aggregate = .init(
                                claimedCount: aggregate.claimedCount + report.claimedCount,
                                committedCount: aggregate.committedCount + report.committedCount,
                                staleCount: aggregate.staleCount + report.staleCount,
                                staleRouteCount: aggregate.staleRouteCount + report.staleRouteCount,
                                releasedCount: aggregate.releasedCount + report.releasedCount,
                                pausedCount: aggregate.pausedCount + report.pausedCount
                            )
                            if await drainTracker.record(committedCount: report.committedCount) { break }
                            if report.claimedCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
                        }
                        return aggregate
                    }
                }
                var values: [V2FanoutDeliveryReport] = []
                for try await report in group { values.append(report) }
                return values
            }
            let (relayResults, deliveryResults) = try await (relayReports, deliveryReports)
            let completionRelease = try await drainFanoutCompletionReleases(
                database: app.db(.psql)
            )
            #expect(relayResults.reduce(0) { $0 + $1.publishedCount } == messageCount)
            #expect(relayResults.reduce(0) { $0 + $1.pausedCount } == 0)
            #expect(await drainTracker.isComplete)
            #expect(deliveryResults.reduce(0) { $0 + $1.committedCount } == messageCount * memberCount)
            #expect(deliveryResults.reduce(0) { $0 + $1.staleCount } == 0)
            #expect(deliveryResults.reduce(0) { $0 + $1.staleRouteCount } == 0)
            #expect(deliveryResults.reduce(0) { $0 + $1.pausedCount } == 0)
            #expect(completionRelease.closedPlanCount == messageCount)
            // Measure only the acceptance → relay/planning → durable delivery
            // pipeline. The assertions below intentionally include optional
            // full-payload scans, which are correctness verification and must
            // not inflate the published delivery-wall metric.
            let workloadElapsedSeconds = Date().timeIntervalSince(workloadStartedAt)

            #expect(try await count("im_v2.messages", on: sql) == Int64(messageCount))
            #expect(try await count("im_v2.room_events", on: sql) == Int64(messageCount))
            #expect(try await count("im_v2.room_outbox", on: sql) == Int64(messageCount))
            #expect(try await count("im_v2.fanout_plans", on: sql) == Int64(messageCount))
            #expect(try await count("im_v2.user_sync_log", on: sql) == Int64(messageCount * memberCount))
            #expect(try await count("im_v2.consumer_inbox", on: sql) == Int64(messageCount * memberCount))
            if eventPayloadBytes > 0 {
                // Keep the payload-size profile honest: every recipient must
                // still have the complete client-readable message payload,
                // not merely an event reference or a partially copied body.
                let fullPayloadRecordCount = try #require(try await sql.raw("""
                    SELECT COUNT(*) FILTER (
                        WHERE octet_length(shared.payload ->> 'text') = \(bind: eventPayloadBytes)
                    ) AS value
                    FROM im_v2.user_sync_log AS log
                    JOIN im_v2.fanout_sync_payloads AS shared
                      ON shared.source_event_id = log.source_event_id
                     AND shared.projection_kind = log.projection_kind
                    WHERE log.projection_kind = 'message'
                    """).first(decoding: CountRow.self)).value
                #expect(fullPayloadRecordCount == Int64(messageCount * memberCount))
            }
            let maxSequence = try #require(try await sql.raw("SELECT MAX(room_sequence)::bigint AS value FROM im_v2.room_events").first(decoding: CountRow.self))
            let roomReservation = try #require(try await sql.raw("SELECT outstanding_fanout_units, outstanding_plans FROM im_v2.room_admission WHERE room_id = \(bind: room)").first(decoding: OutstandingRow.self))
            let shardReservation = try #require(try await sql.raw("SELECT outstanding_fanout_units, outstanding_plans FROM im_v2.shard_admission_pools WHERE room_shard_id = 'capacity-concurrent-room' AND capacity_profile_id = 'standard'").first(decoding: OutstandingRow.self))
            #expect(maxSequence.value == Int64(messageCount))
            #expect(roomReservation.outstandingFanoutUnits == 0)
            #expect(roomReservation.outstandingPlans == 0)
            #expect(shardReservation.outstandingFanoutUnits == 0)
            #expect(shardReservation.outstandingPlans == 0)

            let acceptanceLatency = V2LocalLatencySummary(
                samples: acceptanceResults.map(\.elapsedSeconds)
            )
            // `terminal_at - created_at` is the durable end-to-end fan-out
            // latency for each source event: acceptance, relay/planning and
            // every recipient projection have completed. It avoids treating
            // the aggregate drain wall time as if every message experienced
            // the same delay.
            let terminalLatencyRows = try await sql.raw("""
                SELECT EXTRACT(EPOCH FROM plan.terminal_at - event.created_at) AS elapsed_seconds
                FROM im_v2.fanout_plans AS plan
                JOIN im_v2.room_events AS event ON event.event_id = plan.source_event_id
                WHERE plan.room_id = \(bind: room)
                  AND plan.state = 'terminal' AND plan.terminal_at IS NOT NULL
                ORDER BY plan.source_room_sequence
                """).all(decoding: FanoutTerminalLatencyRow.self)
            #expect(terminalLatencyRows.count == messageCount)
            let terminalLatency = V2LocalLatencySummary(
                samples: terminalLatencyRows.map(\.elapsedSeconds)
            )
            let regressionLimits = try V2LocalCapacityRegressionLimits()
            #expect(acceptanceLatency.p99Milliseconds <= regressionLimits.maximumAcceptanceP99Milliseconds)
            #expect(Int((workloadElapsedSeconds * 1_000).rounded()) <= regressionLimits.maximumPipelineWallMilliseconds)
            let postgresProfileReport = try await postgresProfile?.finish(on: sql)
            print(
                "V2_LOCAL_CONCURRENT_ROOM_WORKLOAD " +
                    "acceptance_p50_ms=\(acceptanceLatency.p50Milliseconds) " +
                    "acceptance_p95_ms=\(acceptanceLatency.p95Milliseconds) " +
                    "acceptance_p99_ms=\(acceptanceLatency.p99Milliseconds) " +
                    "terminal_p50_ms=\(terminalLatency.p50Milliseconds) " +
                    "terminal_p95_ms=\(terminalLatency.p95Milliseconds) " +
                    "terminal_p99_ms=\(terminalLatency.p99Milliseconds) " +
                    "pipeline_wall_ms=\(Int((workloadElapsedSeconds * 1_000).rounded())) " +
                    "acceptance_p99_limit_ms=\(regressionLimits.maximumAcceptanceP99Milliseconds) " +
                    "pipeline_wall_limit_ms=\(regressionLimits.maximumPipelineWallMilliseconds) " +
                    "accepted_messages=\(messageCount) members=\(memberCount) " +
                    "planner_page_size=\(plannerPageSize) " +
                    "delivery_claim_batch_size=\(deliveryClaimBatchSize) " +
                    "delivery_worker_count=\(workload.deliveryWorkerCount) " +
                    "event_payload_bytes=\(eventPayloadBytes) " +
                    "force_generic_projection_sequence_reservation=\(workload.forceGenericProjectionSequenceReservation) " +
                    "receiver_projections=\(messageCount * memberCount)"
            )
            if let postgresProfileReport {
                for line in postgresProfileReport.machineReadableLines() {
                    print(line)
                }
            }

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
                INSERT INTO im_v2.user_shard_route_overrides
                    (user_id, write_bucket, read_fallback_bucket, router_epoch, updated_at)
                SELECT ('00000000-0000-0000-0000-' || lpad(to_hex(member), 12, '0'))::uuid,
                       'recovery-' || ((member - 1) / 1000)::text,
                       NULL,
                       1,
                       \(bind: now)
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
                store: PostgresV2FanoutPlanStore(database: app.db(.psql)),
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
                    router: V2PostgresUserShardRouter(database: app.db(.psql)),
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
            let completionRelease = try await drainFanoutCompletionReleases(
                database: app.db(.psql)
            )
            #expect(completionRelease.releasedCount == 100)
            #expect(completionRelease.closedPlanCount == 1)
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
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, revision, created_at, updated_at)
                VALUES
                    (\(bind: senderUUID), 'sender012', '发送者', 1, \(bind: now), \(bind: now)),
                    (\(bind: memberTwoUUID), 'member015', '成员二', 1, \(bind: now), \(bind: now)),
                    (\(bind: memberThreeUUID), 'member016', '成员三', 1, \(bind: now), \(bind: now))
                """).run()
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

            try await drainV3Projection(database: app.db(.psql))
            let snapshotRelationships = try await currentV3ProjectionItems(sql: sql, userID: sender, kind: "relationship")
            let snapshotBlocks = try await currentV3ProjectionItems(sql: sql, userID: sender, kind: "user_block")
            let snapshotPreference = try await currentV3ProjectionItems(sql: sql, userID: sender, kind: "stranger_message_permission")

            #expect(ownBlockChange.isBlocked)
            #expect(permissionValue == .deny)
            #expect(snapshotRelationships.count == 1)
            #expect(snapshotRelationships.first?.entityKey == recipient.rawValue)
            #expect(snapshotRelationships.first?.string("state") == "pending")
            #expect(snapshotBlocks.count == 1)
            #expect(snapshotBlocks.first?.entityKey == memberThreeUUID.uuidString.lowercased())
            #expect(snapshotBlocks.first?.bool("is_blocked") == true)
            #expect(snapshotPreference.first?.bool("allows_stranger_messages") == false)
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
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, revision, created_at, updated_at)
                VALUES (\(bind: UUID(uuidString: target.rawValue)!), 'member025', '新成员', 1, \(bind: now), \(bind: now))
                """).run()
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
                store: PostgresV2FanoutPlanStore(database: app.db(.psql)),
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
            try await drainV3Projection(database: app.db(.psql))
            let addedMemberProfiles = try await currentV3ProjectionItems(sql: sql, userID: target, kind: "room")

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
            #expect(addedMemberProfiles.count == 1)
            #expect(addedMemberProfiles.first?.entityKey == roomID.rawValue)
            #expect(addedMemberProfiles.first?.string("title") == "集成测试群")

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
                store: PostgresV2FanoutPlanStore(database: app.db(.psql)),
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
                store: PostgresV2FanoutPlanStore(database: app.db(.psql)),
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
            try await drainV3Projection(database: app.db(.psql))
            let snapshotMessages = try await currentV3ProjectionItems(sql: sql, userID: senderID, kind: "message")
            let snapshotReactions = try await currentV3ProjectionItems(
                sql: sql, userID: senderID, kind: "message_reaction"
            )

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
            #expect(snapshotMessages.count == 1)
            #expect(snapshotReactions.count == 1)
            #expect(snapshotReactions.first?.string("actor_user_id") == senderID.rawValue)
            #expect(snapshotReactions.first?.string("reaction") == "👍")
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
            let planning = try await V2FanoutPlanner(store: PostgresV2FanoutPlanStore(database: app.db(.psql)), pageSize: 2, now: { now.addingTimeInterval(2) }).plan(.init(sourceEventID: result.eventID, planID: result.fanoutPlanID))
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

    @Test("editing a claimed message resets review work to the new content revision")
    func editReplacesTheClaimedContentReviewJob() async throws {
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
            let limits = try RoomCapacityProfile(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100,
                maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10,
                maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3
            )
            let profile = try V2CapacityProfile(id: "standard", limits: limits)
            let send = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: app.db(.psql)),
                capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64),
                now: { now }
            )
            guard case .accepted(let message) = try await send.send(.init(
                roomID: roomID,
                actorUserID: senderID,
                clientMessageID: clientMessageID,
                text: "before review reset"
            )) else {
                Issue.record("expected accepted message")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }

            let oldToken = UUID(uuidString: "00000000-0000-0000-0000-000000000d21")!
            let reviewStore = PostgresV2ContentReviewStore(database: app.db(.psql), makeUUID: { oldToken })
            let oldLease = try #require(try await reviewStore.claimPending(now: now.addingTimeInterval(1), leaseDuration: 30, limit: 1).first)
            #expect(oldLease.input.messageID == message.messageID)
            #expect(oldLease.input.contentRevision == 1)
            #expect(oldLease.input.text == "before review reset")

            let edit = V2MessageEditService(
                store: PostgresV2MessageEditStore(database: app.db(.psql)),
                capacityProfile: profile,
                maximumTextUTF8Bytes: 64,
                identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000d22")! }),
                now: { now.addingTimeInterval(2) }
            )
            guard case .edited(let editResult) = try await edit.edit(.init(
                roomID: roomID,
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000d23"),
                messageID: message.messageID,
                expectedMessageRevision: 1,
                text: "after review reset"
            )) else {
                Issue.record("expected edit")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            #expect(editResult.messageRevision == 2)

            let messageUUID = try #require(UUID(uuidString: message.messageID.rawValue))
            let resetJob = try #require(try await sql.raw("""
                SELECT state, expected_content_revision, decision,
                       claim_token IS NULL AS claim_released,
                       lease_expires_at IS NULL AS lease_released,
                       completed_at IS NULL AS is_uncompleted
                FROM im_v2.content_review_jobs
                WHERE message_id = \(bind: messageUUID)
                """).first(decoding: ContentReviewResetAssertionRow.self))
            #expect(resetJob.state == "pending")
            #expect(resetJob.revision == 2)
            #expect(resetJob.decision == nil)
            #expect(resetJob.claimReleased)
            #expect(resetJob.leaseReleased)
            #expect(resetJob.isUncompleted)

            // The pre-edit worker loses authority, but its late check must
            // not mark the replacement job superseded or release it.
            #expect(try await reviewStore.validateAndRenew(oldLease, now: now.addingTimeInterval(3), leaseDuration: 10) == .lostLease)
            let preserved = try #require(try await sql.raw("""
                SELECT state, expected_content_revision, decision,
                       claim_token IS NULL AS claim_released,
                       lease_expires_at IS NULL AS lease_released,
                       completed_at IS NULL AS is_uncompleted
                FROM im_v2.content_review_jobs
                WHERE message_id = \(bind: messageUUID)
                """).first(decoding: ContentReviewResetAssertionRow.self))
            #expect(preserved == resetJob)

            let replacementStore = PostgresV2ContentReviewStore(
                database: app.db(.psql),
                makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000d24")! }
            )
            let replacementLease = try #require(try await replacementStore.claimPending(now: now.addingTimeInterval(3), leaseDuration: 30, limit: 1).first)
            #expect(replacementLease.input.messageID == message.messageID)
            #expect(replacementLease.input.contentRevision == 2)
            #expect(replacementLease.input.text == "after review reset")

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
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
            // Two timestamps inside the same millisecond exercise the cursor
            // precision boundary that previously truncated through Date-ms.
            try await sql.raw("""
                INSERT INTO im_v2.room_read_receipts
                    (room_id, user_id, read_through_room_sequence, updated_at)
                VALUES
                    (\(bind: roomUUID), \(bind: memberTwoUUID), 1,
                     TIMESTAMPTZ '2025-06-15 15:06:41.123100+00'),
                    (\(bind: roomUUID), \(bind: memberThreeUUID), 1,
                     TIMESTAMPTZ '2025-06-15 15:06:41.123900+00')
                """).run()
            let readerStore = PostgresV2ReadReceiptStore(database: app.db(.psql))
            await #expect(throws: V2ReadReceiptStoreError.messageNotFound) {
                _ = try await readerStore.readers(
                    roomID: roomID,
                    messageID: try .init("00000000-0000-0000-0000-000000000099"),
                    actorUserID: senderID,
                    cursor: nil,
                    pageSize: 1
                )
            }
            let firstReaders = try await readerStore.readers(
                roomID: roomID, messageID: message.messageID,
                actorUserID: senderID, cursor: nil, pageSize: 1
            )
            #expect(firstReaders.messageID == message.messageID)
            #expect(firstReaders.readers.map(\.userID) == [try .init(memberThreeUUID.uuidString)])
            let readerCursor = try #require(firstReaders.nextCursor)
            let secondReaders = try await readerStore.readers(
                roomID: roomID, messageID: message.messageID,
                actorUserID: senderID, cursor: readerCursor, pageSize: 1
            )
            #expect(secondReaders.readers.map(\.userID) == [try .init(memberTwoUUID.uuidString)])
            #expect(secondReaders.nextCursor == nil)
            let directory = PostgresV2RoomMembershipDirectoryStore(database: app.db(.psql))
            let firstMemberPage = try await directory.list(.init(
                roomID: roomID,
                actorUserID: senderID,
                cursor: nil,
                pageSize: 1
            ))
            let rosterCursor = try #require(firstMemberPage.nextCursor)
            #expect(UUID(uuidString: rosterCursor) == nil)
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 1 WHERE room_id = \(bind: roomUUID)").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision = 1 WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: memberThreeUUID)").run()
            let continuedReaders = try await readerStore.readers(
                roomID: roomID,
                messageID: message.messageID,
                actorUserID: senderID,
                cursor: readerCursor,
                pageSize: 1
            )
            #expect(continuedReaders.readers.map(\.userID) == [try .init(memberTwoUUID.uuidString)])
            #expect(continuedReaders.nextCursor == nil)
            let currentReaders = try await readerStore.readers(
                roomID: roomID,
                messageID: message.messageID,
                actorUserID: senderID,
                cursor: nil,
                pageSize: 10
            )
            #expect(currentReaders.readers.map(\.userID) == [try .init(memberTwoUUID.uuidString)])

            let lateMemberUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000017")!
            let lateMemberID = try UserID(lateMemberUUID.uuidString)
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, revision, created_at, updated_at)
                VALUES
                    (\(bind: lateMemberUUID), 'member017', '后加入成员', 1, \(bind: now), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision)
                VALUES (\(bind: roomUUID), \(bind: lateMemberUUID), 1)
                """).run()
            await #expect(throws: V2ReadReceiptStoreError.actorNotMember) {
                _ = try await readerStore.readers(
                    roomID: roomID,
                    messageID: message.messageID,
                    actorUserID: lateMemberID,
                    cursor: nil,
                    pageSize: 10
                )
            }

            try await sql.raw("UPDATE im_v2.public_user_profiles SET state = 'hidden' WHERE user_id = \(bind: memberTwoUUID)").run()
            let visibleReaders = try await readerStore.readers(
                roomID: roomID,
                messageID: message.messageID,
                actorUserID: senderID,
                cursor: nil,
                pageSize: 10
            )
            #expect(visibleReaders.readers.isEmpty)
            let hiddenMemberID = try UserID(memberTwoUUID.uuidString)
            let visibleMembers = try await directory.list(.init(
                roomID: roomID,
                actorUserID: senderID,
                cursor: nil,
                pageSize: 10
            ))
            #expect(!visibleMembers.entries.contains { $0.userID == hiddenMemberID })
            #expect(visibleMembers.entries.allSatisfy { $0.publicIdentity.userID == $0.userID })
            await #expect(throws: V2RoomMembershipDirectoryError.revisionConflict(currentRevision: 1)) {
                _ = try await directory.list(.init(
                    roomID: roomID,
                    actorUserID: senderID,
                    cursor: rosterCursor,
                    pageSize: 1
                ))
            }
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
                INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at)
                VALUES (\(bind: senderUUID), \(bind: UUID(uuidString: deviceID.rawValue)!), \(bind: now), \(bind: now))
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
                INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at)
                VALUES (\(bind: senderUUID), \(bind: UUID(uuidString: deviceID.rawValue)!), \(bind: now), \(bind: now))
                ON CONFLICT (user_id, device_id) DO NOTHING
                """).run()
            let acceptedTrigger = try #require(try await sql.raw("SELECT source_event_id, plan_id FROM im_v2.room_outbox WHERE source_event_id = \(bind: UUID(uuidString: "00000000-0000-0000-0000-000000000095")!)").first(decoding: TriggerRow.self))
            _ = try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(database: app.db(.psql)),
                pageSize: 2,
                now: { now.addingTimeInterval(4) }
            ).plan(.init(sourceEventID: try .init(acceptedTrigger.sourceEventID.uuidString), planID: try .init(acceptedTrigger.planID.uuidString)))
            _ = try await V2FanoutDeliveryWorker(
                store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)),
                now: { now.addingTimeInterval(5) }
            ).runOnce(limit: 8)
            try await drainV3Projection(database: app.db(.psql))
            let compaction = try await PostgresV2MessageProjectionBackfillWorker(
                database: app.db(.psql),
                compactInlinePayloads: true
            ).runOnce(now: now.addingTimeInterval(5), limit: 8)
            #expect(compaction.compactedRowCount == 3)
            let compactedDeliveryCount = try #require(try await sql.raw("""
                SELECT COUNT(*) AS value
                FROM im_v2.user_projection_versions
                WHERE projection_kind = 'message'
                  AND entity_key = \(bind: message.messageID.rawValue)
                  AND message_state_id IS NOT NULL
                  AND payload IS NULL
                """).first(decoding: CountRow.self))
            #expect(compactedDeliveryCount.value == 3)

            // Media authorization must follow the requester's narrow live
            // reference after inline JSON compaction; the shared state alone
            // must never become a capability.
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
            let messageUUID = try #require(UUID(uuidString: message.messageID.rawValue))
            let mediaUUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
            try await sql.raw("""
                INSERT INTO im_v2.media_objects
                    (media_id, owner_user_id, content_type, byte_count, state, upload_session_id, expires_at, state_updated_at, created_at)
                VALUES
                    (\(bind: mediaUUID), \(bind: senderUUID), 'image/png', 1, 'available',
                     \(bind: UUID(uuidString: "00000000-0000-0000-0000-0000000000a2")!),
                     \(bind: now.addingTimeInterval(3_600)), \(bind: now), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.message_media_references (message_id, media_id, ordinal, referenced_at)
                VALUES (\(bind: messageUUID), \(bind: mediaUUID), 0, \(bind: now))
                """).run()
            let acceptedTrigger = try #require(try await sql.raw("SELECT source_event_id, plan_id FROM im_v2.room_outbox ORDER BY created_at LIMIT 1").first(decoding: TriggerRow.self))
            _ = try await V2FanoutPlanner(store: PostgresV2FanoutPlanStore(database: app.db(.psql)), pageSize: 2, now: { now.addingTimeInterval(0.25) }).plan(.init(sourceEventID: try .init(acceptedTrigger.sourceEventID.uuidString), planID: try .init(acceptedTrigger.planID.uuidString)))
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
            let mediaReference = try #require(try await sql.raw("""
                SELECT revoked_at IS NOT NULL AS exists
                FROM im_v2.message_media_references
                WHERE message_id = \(bind: messageUUID) AND media_id = \(bind: mediaUUID)
                """).first(decoding: ExistsRow.self))
            let planning = try await V2FanoutPlanner(store: PostgresV2FanoutPlanStore(database: app.db(.psql)), pageSize: 2, now: { now.addingTimeInterval(3) }).plan(.init(sourceEventID: result.eventID, planID: result.fanoutPlanID))
            let delivery = try await V2FanoutDeliveryWorker(store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)), now: { now.addingTimeInterval(4) }).runOnce(limit: 8)
            let delivered = try #require(try await sql.raw("""
                SELECT (CASE WHEN log.payload_storage = 'inline' THEN log.payload ELSE shared.payload END)->>'event_type' AS event_type
                FROM im_v2.user_sync_log AS log
                LEFT JOIN im_v2.fanout_sync_payloads AS shared
                  ON shared.source_event_id = log.source_event_id
                 AND shared.projection_kind = log.projection_kind
                WHERE log.source_event_id = \(bind: UUID(uuidString: result.eventID.rawValue)!)
                LIMIT 1
                """).first(decoding: ModerationDeliveredEventRow.self))
            try await drainV3Projection(database: app.db(.psql))
            let snapshotMessages = try await currentV3ProjectionItems(sql: sql, userID: senderID, kind: "message")
            #expect(replay == .idempotent(result))
            #expect(event.eventType == "message.redacted")
            #expect(event.messageID == message.messageID.rawValue)
            #expect(audit.action == "redact_message")
            #expect(audit.reasonCode == "abuse_spam")
            #expect(state.withdrawn)
            #expect(state.revision == 2)
            #expect(mediaReference.exists)
            #expect(planning == .init(createdCompletionUnits: 2, createdDeliveries: 3, wasAlreadyPlanned: false))
            #expect(delivery == .init(claimedCount: 3, committedCount: 3, staleCount: 0, releasedCount: 0))
            #expect(delivered.eventType == "message.redacted")
            #expect(snapshotMessages.count == 1)
            #expect(snapshotMessages.first?.bool("is_withdrawn") == true)
            #expect(snapshotMessages.first?.string("text") == "[removed]")
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
            let planning = try await V2FanoutPlanner(store: PostgresV2FanoutPlanStore(database: app.db(.psql)), pageSize: 2, now: { now.addingTimeInterval(1) }).plan(.init(sourceEventID: frozen.eventID, planID: frozen.fanoutPlanID))
            let delivery = try await V2FanoutDeliveryWorker(store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)), now: { now.addingTimeInterval(2) }).runOnce(limit: 8)
            let projection = try #require(try await sql.raw("""
                SELECT log.projection_kind,
                       (CASE WHEN log.payload_storage = 'inline' THEN log.payload ELSE shared.payload END)->>'event_type' AS event_type
                FROM im_v2.user_sync_log AS log
                LEFT JOIN im_v2.fanout_sync_payloads AS shared
                  ON shared.source_event_id = log.source_event_id
                 AND shared.projection_kind = log.projection_kind
                WHERE log.source_event_id = \(bind: UUID(uuidString: frozen.eventID.rawValue)!)
                LIMIT 1
                """).first(decoding: FreezeProjectionRow.self))

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
            let planning = try await V2FanoutPlanner(store: PostgresV2FanoutPlanStore(database: app.db(.psql)), pageSize: 2, now: { now.addingTimeInterval(1) }).plan(.init(sourceEventID: result.eventID, planID: result.fanoutPlanID))
            let delivery = try await V2FanoutDeliveryWorker(store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)), now: { now.addingTimeInterval(2) }).runOnce(limit: 8)
            try await drainV3Projection(database: app.db(.psql))
            let snapshotMutes = try await currentV3ProjectionItems(sql: sql, userID: senderID, kind: "moderation")
            #expect(replay == .idempotent(result))
            #expect(mute.actorUserID == senderUUID)
            #expect(mute.muteUntil == now.addingTimeInterval(300))
            #expect(audit.action == "mute_member")
            #expect(audit.reasonCode == "abuse_spam")
            #expect(event.eventType == "member.muted")
            #expect(event.targetUserID == memberTwoUUID.uuidString)
            #expect(planning == .init(createdCompletionUnits: 2, createdDeliveries: 3, wasAlreadyPlanned: false))
            #expect(delivery == .init(claimedCount: 3, committedCount: 3, staleCount: 0, releasedCount: 0))
            #expect(snapshotMutes.count == 1)
            #expect(snapshotMutes.first?.string("target_user_id") == memberTwoUUID.uuidString.lowercased())
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
            let planning = try await V2FanoutPlanner(store: PostgresV2FanoutPlanStore(database: app.db(.psql)), pageSize: 2, now: { now.addingTimeInterval(1) }).plan(.init(sourceEventID: result.eventID, planID: result.fanoutPlanID))
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
            let revocationNodeID = "metrics-revocation-gateway"
            let metrics = PostgresV2DurableWorkMetricsSource(
                database: app.db(.psql),
                deliveryBucket: "test-users",
                gatewayNodeID: revocationNodeID
            )
            let initialMetrics = try await metrics.loadDurableWorkMetrics()
            #expect(initialMetrics.isAvailable)
            #expect(initialMetrics.userSyncLogEstimatedRows == 0)
            #expect(initialMetrics.userSyncLogRelationBytes > 0)
            #expect(initialMetrics.userProjectionEffectsEstimatedRows == 0)
            #expect(initialMetrics.userProjectionEffectsRelationBytes > 0)
            let initialShardMetrics = await PostgresV2UserShardDurableWorkMetricsSource(
                database: app.db(.psql), schema: "im_v2"
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
            let revocationStore = V2PostgresDeviceRevocationEventStore(database: app.db(.psql))
            let firstRevocation = try #require(try await revocationStore.events(afterCursorFor: revocationNodeID, limit: 1).first)
            try await revocationStore.markProcessed(eventID: firstRevocation.eventID, nodeID: revocationNodeID, now: now)
            let advancedRevocationBacklog = await metrics.durableWorkMetricsSnapshot()
            #expect(advancedRevocationBacklog.pendingDeviceRevocationEvents == 1)
            #expect(advancedRevocationBacklog.pendingRevokedDeviceProjectionCleanupEvents == 2)

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
                        store: PostgresV2FanoutPlanStore(database: app.db(.psql)),
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
            #expect(snapshot.readyRoomOutboxRows == 0)
            #expect(snapshot.leasedRoomOutboxRows == 0)
            #expect(snapshot.readyDirectProfileUpdates == 1)
            #expect(snapshot.leasedDirectProfileUpdates == 1)
            #expect(snapshot.openFanoutPlans == 1)
            #expect(snapshot.readyFanoutDeliveries == 2)
            #expect(snapshot.leasedFanoutDeliveries == 0)
            #expect(snapshot.readyContentReviews == 1)
            #expect(snapshot.leasedContentReviews == 0)
            #expect(snapshot.scheduledContentReviews == 0)
            #expect(snapshot.pausedContentReviews == 0)
            #expect(snapshot.userSyncLogRelationBytes > 0)
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
                publisher: V2LocalFanoutPlanPublisher(planner: .init(store: PostgresV2FanoutPlanStore(database: app.db(.psql)), pageSize: 2, now: { now.addingTimeInterval(32) })),
                now: { now.addingTimeInterval(32) }
            )
            #expect(try await recoveredRelay.runOnce(limit: 8) == .init(claimedCount: 1, publishedCount: 1, releasedCount: 0))

            let abandonedDeliveries = try await PostgresV2FanoutDeliveryStore(database: app.db(.psql)).claimPending(bucket: nil, now: now.addingTimeInterval(33), leaseDuration: 30, limit: 8)
            #expect(abandonedDeliveries.count == 3)
            let recoveredDelivery = V2FanoutDeliveryWorker(store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)), now: { now.addingTimeInterval(64) })
            #expect(try await recoveredDelivery.runOnce(limit: 8) == .init(claimedCount: 3, committedCount: 3, staleCount: 0, releasedCount: 0))
            #expect(try await V2FanoutCompletionReleaseWorker(
                store: PostgresV2FanoutDeliveryStore(database: app.db(.psql)),
                now: { now.addingTimeInterval(64) }
            ).runOnce(limit: 8) == .init(releasedCount: 2, closedPlanCount: 1))
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
            _ = try await V2FanoutPlanner(store: PostgresV2FanoutPlanStore(database: app.db(.psql)), pageSize: 2, now: { now.addingTimeInterval(12) }).plan(.init(sourceEventID: sourceEventID, planID: planID))
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

    @Test("new device issuance enforces active and durable account budgets")
    func deviceRegistrationBudgetsBoundDurableIdentityGrowth() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else {
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
                database: app.db(.psql), tokenHMACKey: tokenKey,
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

            let sessions = V2PostgresDeviceSessionService(database: app.db(.psql), now: { now.addingTimeInterval(1) })
            #expect(try await sessions.revokeDevice(
                actorUserID: userID,
                currentDeviceID: firstDevice,
                targetDeviceID: secondDevice,
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000c14")!
            ) == .applied)
            #expect(try await issuer.register(.init(
                userID: userID, deviceID: thirdDevice,
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000c15")!
            )) == .rateLimited(retryAfterSeconds: 60))

            let nextWindowIssuer = try V2PostgresDeviceCredentialService(
                database: app.db(.psql), tokenHMACKey: tokenKey,
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
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await app.asyncShutdown()
            throw error
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
            #expect(try await gateway.authenticateSession(accessToken: initial.accessToken, deviceID: deviceID).userID == userID)

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
            #expect(try await gateway.authenticateSession(accessToken: successor.accessToken, deviceID: deviceID).userID == userID)

            let reuse = try V2DeviceCredentialRefresh(
                userID: userID,
                deviceID: deviceID,
                refreshCredential: initial.refreshCredential,
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
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("unknown device refresh is terminal without a foreign-key failure or cross-account mutation")
    func unknownDeviceCredentialRefreshIsTerminalNoOp() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)

            let issuer = try V2PostgresDeviceCredentialService(
                database: app.db(.psql),
                tokenHMACKey: try .init(rawBytes: Data(repeating: 0x31, count: 32)),
                replayEnvelopeKey: try .init(rawBytes: Data(repeating: 0x32, count: 32)),
                now: { Date(timeIntervalSince1970: 1_750_000_000) }
            )
            let refresh = try V2DeviceCredentialRefresh(
                userID: try .init("00000000-0000-0000-0000-000000000211"),
                deviceID: try .init("00000000-0000-0000-0000-000000000212"),
                refreshCredential: "unknown-refresh-credential",
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000213")!
            )

            #expect(try await issuer.refresh(refresh) == .terminalRejection)
            #expect(try await count("im_v2.auth_devices", on: sql) == 0)
            #expect(try await count("im_v2.device_refresh_sessions", on: sql) == 0)
            #expect(try await count("im_v2.device_access_tokens", on: sql) == 0)
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 0)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("device sessions paginate metadata and revoke remote installations with bounded SQL")
    func deviceSessionManagementRevokesOnlyTheRequestedDevice() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2DeviceSessionServiceError.unavailable }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_100)
            let tokenKey = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 0x51, count: 32))
            let replayKey = try V2CredentialReplayEnvelopeKey(rawBytes: Data(repeating: 0x52, count: 32))
            let issuer = try V2PostgresDeviceCredentialService(database: app.db(.psql), tokenHMACKey: tokenKey, replayEnvelopeKey: replayKey, now: { now })
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

            let service = V2PostgresDeviceSessionService(database: app.db(.psql), now: { now.addingTimeInterval(1) })
            let firstPage = try await service.sessions(for: userID, cursor: nil, pageSize: 2)
            #expect(firstPage.sessions.map(\.deviceID) == [currentDeviceID, remoteDeviceID])
            #expect(firstPage.sessions.map(\.displayName) == ["Current iPhone", "Remote iPad"])
            guard let pageCursor = firstPage.nextCursor else { Issue.record("expected a second device page"); return }
            let secondPage = try await service.sessions(for: userID, cursor: pageCursor, pageSize: 2)
            #expect(secondPage.sessions.map(\.deviceID) == [otherRemoteDeviceID])
            #expect(secondPage.nextCursor == nil)
            let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000a07")!
            #expect(try await service.revokeDevice(actorUserID: userID, currentDeviceID: currentDeviceID, targetDeviceID: remoteDeviceID, operationID: operationID) == .applied)
            #expect(try await service.revokeDevice(actorUserID: userID, currentDeviceID: currentDeviceID, targetDeviceID: remoteDeviceID, operationID: operationID) == .idempotent)
            let revokeOthersOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000a0b")!
            #expect(try await service.revokeOtherDevices(actorUserID: userID, currentDeviceID: currentDeviceID, operationID: revokeOthersOperationID) == .applied)
            #expect(try await service.revokeOtherDevices(actorUserID: userID, currentDeviceID: currentDeviceID, operationID: revokeOthersOperationID) == .idempotent)

            let gateway = V2PostgresGatewayAuthenticator(database: app.db(.psql), tokenKey: tokenKey, now: { now.addingTimeInterval(2) })
            #expect(try await gateway.authenticateSession(accessToken: currentCredentials.accessToken, deviceID: currentDeviceID).userID == userID)
            await #expect(throws: V2GatewayAuthenticationError.unauthenticated) {
                try await gateway.authenticateSession(accessToken: remoteCredentials.accessToken, deviceID: remoteDeviceID)
            }
            await #expect(throws: V2GatewayAuthenticationError.unauthenticated) {
                try await gateway.authenticateSession(accessToken: otherRemoteCredentials.accessToken, deviceID: otherRemoteDeviceID)
            }
            #expect(try await count("im_v2.auth_devices WHERE revoked_at IS NULL", on: sql) == 1)
            #expect(try await count("im_v2.device_session_operations", on: sql) == 2)
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 2)
            #expect(try await count("im_v2.push_device_endpoints WHERE disabled_at IS NOT NULL", on: sql) == 2)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run(); try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown(); throw error
        }
    }

    @Test("account disable fences credential issuance, revokes every device, and preserves one audit fact")
    func accountDisableRevokesCredentialsAndFencesFutureIssue() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2AccountDisableError.unavailable }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let tokenKey = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 0x41, count: 32))
            let replayKey = try V2CredentialReplayEnvelopeKey(rawBytes: Data(repeating: 0x42, count: 32))
            let issuer = try V2PostgresDeviceCredentialService(
                database: app.db(.psql), tokenHMACKey: tokenKey, replayEnvelopeKey: replayKey, now: { now }
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

            let disable = try V2PostgresAccountDisableService(database: app.db(.psql), operatorPrincipal: "account-safety-primary", now: { now.addingTimeInterval(1) })
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

            let gateway = V2PostgresGatewayAuthenticator(database: app.db(.psql), tokenKey: tokenKey, now: { now.addingTimeInterval(2) })
            await #expect(throws: V2GatewayAuthenticationError.unauthenticated) {
                try await gateway.authenticateSession(accessToken: firstCredentials.accessToken, deviceID: firstDeviceID)
            }
            await #expect(throws: V2GatewayAuthenticationError.unauthenticated) {
                try await gateway.authenticateSession(accessToken: secondCredentials.accessToken, deviceID: secondDeviceID)
            }
            #expect(try await issuer.register(firstRegistration) == .deviceUnavailable)
            let refresh = try V2DeviceCredentialRefresh(
                userID: userID, deviceID: firstDeviceID, refreshCredential: firstCredentials.refreshCredential,
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000998")!
            )
            #expect(try await issuer.refresh(refresh) == .terminalRejection)
            #expect(try await V2PostgresPasswordAccountStore(database: app.db(.psql)).passwordCredential(for: "account991") == nil)
            let disabledProfile = try #require(try await sql.raw("SELECT state, revision, visibility_revision, avatar_media_id IS NULL AS avatar_cleared FROM im_v2.public_user_profiles WHERE user_id = \(bind: userUUID)").first(decoding: DisabledProfileAssertionRow.self))
            #expect(disabledProfile.state == "suspended")
            #expect(disabledProfile.revision == 2)
            #expect(disabledProfile.visibilityRevision == 2)
            #expect(disabledProfile.avatarCleared)
            let profileInvalidation = try #require(try await sql.raw("SELECT profile_state, revision FROM im_v2.public_profile_update_outbox WHERE source_event_id = \(bind: command.operationID)").first(decoding: DisabledProfileOutboxAssertionRow.self))
            #expect(profileInvalidation.profileState == "suspended")
            #expect(profileInvalidation.revision == 2)
            let publicDirectory = V2PostgresPublicIdentityDirectory(
                database: app.db(.psql),
                policy: try .init(maximumQueries: 2, window: 60),
                now: { now.addingTimeInterval(2) }
            )
            #expect(try await publicDirectory.resolve(handle: .init("account991"), actorUserID: try .init("00000000-0000-0000-0000-000000000990")) == nil)
            #expect(try await count("im_v2.account_disables", on: sql) == 1)
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 2)
            #expect(try await count("im_v2.auth_devices WHERE revoked_at IS NULL", on: sql) == 0)
            #expect(try await count("im_v2.device_access_tokens WHERE revoked_at IS NULL", on: sql) == 0)
            #expect(try await count("im_v2.device_refresh_sessions WHERE revoked_at IS NULL", on: sql) == 0)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("PostgreSQL device-revocation cursor initializes new nodes and advances existing nodes")
    func deviceRevocationCursorReadsAndAcknowledgesEvents() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2GatewayAuthenticationError.corruptPersistenceState }
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

            let store = V2PostgresDeviceRevocationEventStore(database: app.db(.psql))
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
                database: app.db(.psql)
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
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
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
            #expect(try await gateway.authenticateSession(accessToken: successor.accessToken, deviceID: deviceID).userID == userID)
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
            try await configureDefaultUserShardRoute(initialRoute, now: now, on: sql)
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
            let control = V2PostgresUserShardRouteControl(
                database: app.db(.psql), operatorPrincipal: "router-test",
                finalizer: RouteFinalizerNoop()
            )
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
            let caseVariantCutover = try V2UserShardRouteCutover(
                operationID: cutover.operationID,
                userID: try UserID(user.uuidString.lowercased()),
                expectedRouterEpoch: cutover.expectedRouterEpoch,
                newWriteBucket: cutover.newWriteBucket,
                readFallbackBucket: cutover.readFallbackBucket
            )
            #expect(try await control.cutOver(caseVariantCutover, now: now.addingTimeInterval(1)) == .init(route: currentRoute, wasIdempotent: true))
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
            let caseVariantRollback = try V2UserShardRouteRollback(
                operationID: rollback.operationID,
                userID: try UserID(user.uuidString.lowercased()),
                expectedRouterEpoch: rollback.expectedRouterEpoch
            )
            #expect(try await control.rollBack(caseVariantRollback, now: now.addingTimeInterval(3)).wasIdempotent)
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

    @Test("one poison user backs off and pauses without blocking healthy projection work")
    func userProjectionPoisonIsolationAndReplay() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
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
                     payload, payload_storage, created_at)
                VALUES
                    (\(bind: poisonUser), 1, \(bind: poisonEvent), 'relationship',
                     NULL, 'fanout_shared', \(bind: now.addingTimeInterval(-1))),
                    (\(bind: healthyUser), 1, \(bind: healthyEvent), 'relationship',
                     \(bind: "{\"target_user_id\":\"\(target.uuidString.lowercased())\",\"state\":\"accepted\",\"updated_at_ms\":1750000000000}")::jsonb,
                     'inline', \(bind: now))
                """).run()
            #expect(try await count("im_v2.user_projection_ready", on: sql) == 2)
            let worker = PostgresV2UserProjectionWorker(
                database: app.db(.psql),
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
            #expect(paused.lastFailureCode == "missing_payload")
            #expect(try await count("im_v2.user_projection_ready", on: sql) == 0)
            #expect(try await currentV3ProjectionItems(
                sql: sql, userID: .init(healthyUser.uuidString), kind: "relationship"
            ).count == 1)

            // Repair the exact missing body first, then use the closed,
            // audited replay target. The worker resumes from the unchanged
            // checkpoint and applies the formerly poison record once.
            try await sql.raw("""
                INSERT INTO im_v2.fanout_sync_payloads
                    (source_event_id, projection_kind, payload, created_at)
                VALUES (\(bind: poisonEvent), 'relationship',
                        \(bind: "{\"target_user_id\":\"\(target.uuidString.lowercased())\",\"state\":\"accepted\",\"updated_at_ms\":1750000000000}")::jsonb,
                        \(bind: now))
                """).run()
            let replay = V2DurableWorkOperatorReplayService(
                store: PostgresV2DurableWorkReplayStore(database: app.db(.psql)),
                operatorPrincipal: "integration.operator",
                now: { now.addingTimeInterval(3) }
            )
            #expect(try await replay.replay(.init(
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000c06")!,
                target: .init(
                    kind: .userProjection,
                    sourceEventID: .init(poisonEvent.uuidString),
                    targetUserID: .init(poisonUser.uuidString)
                ),
                reason: .dataRepaired
            )).outcome == .requeued)
            #expect(try await count("im_v2.user_projection_ready", on: sql) == 1)
            #expect(try await worker.runOnce(now: now.addingTimeInterval(3)) == .init(
                claimed: true, appliedRecordCount: 1
            ))
            #expect(try await count("im_v2.user_projection_ready", on: sql) == 0)
            #expect(try await currentV3ProjectionItems(
                sql: sql, userID: .init(poisonUser.uuidString), kind: "relationship"
            ).count == 1)

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

    @Test("sync-log compaction is device-independent and low cursors lazily share one snapshot")
    func userSyncLogCompactionAndLowCursorReset() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
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
                     payload, payload_storage, created_at)
                VALUES
                    (\(bind: user), 1, \(bind: events[0]), 'relationship',
                     '{"target_user_id":"00000000-0000-0000-0000-000000000c31","state":"accepted","updated_at_ms":1}'::jsonb,
                     'inline', \(bind: old)),
                    (\(bind: user), 2, \(bind: events[1]), 'relationship',
                     '{"target_user_id":"00000000-0000-0000-0000-000000000c32","state":"accepted","updated_at_ms":2}'::jsonb,
                     'inline', \(bind: old)),
                    (\(bind: user), 3, \(bind: events[2]), 'relationship',
                     '{"target_user_id":"00000000-0000-0000-0000-000000000c33","state":"accepted","updated_at_ms":3}'::jsonb,
                     'inline', \(bind: old))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.consumer_inbox
                    (consumer_name, source_event_id, target_user_id,
                     projection_kind, committed_at, user_sync_sequence)
                VALUES ('v2-fanout-delivery', \(bind: events[0]), \(bind: user),
                        'relationship', \(bind: old), 1)
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
            let projector = PostgresV2UserProjectionWorker(database: app.db(.psql), batchSize: 10)
            #expect(try await projector.runOnce(now: old).appliedRecordCount == 3)

            let compactor = PostgresV2UserSyncLogCompactionWorker(
                database: app.db(.psql), minimumLogAge: 60
            )
            #expect(try await compactor.runOnce(now: now, userLimit: 1, rowLimit: 2) == .init(
                claimedUserCount: 1,
                deletedLogRowCount: 1, deletedSharedPayloadCount: 0
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
                deletedLogRowCount: 2, deletedSharedPayloadCount: 0
            ))
            #expect(try await count("im_v2.user_sync_log", on: sql) == 0)
            #expect(try await count("im_v2.consumer_inbox", on: sql) == 1)
            let inboxSequence = try #require(try await sql.raw("""
                SELECT user_sync_sequence AS value FROM im_v2.consumer_inbox
                WHERE consumer_name = 'v2-fanout-delivery'
                  AND source_event_id = \(bind: events[0])
                  AND target_user_id = \(bind: user)
                  AND projection_kind = 'relationship'
                """).first(decoding: CountRow.self))
            #expect(inboxSequence.value == 1)
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
                database: app.db(.psql), capabilityProfile: "base",
                capabilityLifetime: 600
            )
            guard case let .resetPreparing(lowSnapshot, lowGeneration, _) = try await sync.pull(
                userID: .init(user.uuidString), deviceID: .init(lowDevice.uuidString),
                syncToken: nil, maxRecords: 10, now: now.addingTimeInterval(2)
            ) else {
                Issue.record("expected retained-floor reset for existing low device")
                try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
                try await app.asyncShutdown()
                return
            }
            let catchupEvent = UUID(uuidString: "00000000-0000-0000-0000-000000000c24")!
            try await sql.raw("UPDATE im_v2.user_sync_sequences SET next_sequence = 4 WHERE user_id = \(bind: user)").run()
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind,
                     payload, payload_storage, created_at)
                VALUES (\(bind: user), 4, \(bind: catchupEvent), 'relationship',
                        '{"target_user_id":"00000000-0000-0000-0000-000000000c34","state":"accepted","updated_at_ms":4}'::jsonb,
                        'inline', \(bind: now.addingTimeInterval(2)))
                """).run()
            #expect(try await projector.runOnce(now: now.addingTimeInterval(2)).appliedRecordCount == 1)
            guard case let .resetPreparing(newSnapshot, newGeneration, _) = try await sync.pull(
                userID: .init(user.uuidString), deviceID: .init(newDevice.uuidString),
                syncToken: nil, maxRecords: 10, now: now.addingTimeInterval(3)
            ) else {
                Issue.record("expected retained-floor reset for new device")
                try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
                try await app.asyncShutdown()
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
                    try .init(bucket: "control", database: app.db(.psql), schema: "im_v2")
                ]),
                deviceAvailability: V2PostgresDeviceAvailabilityChecker(
                    database: app.db(.psql)
                ),
                routeFence: V2FixedUserShardRouteFence(route: resetRoute, database: app.db(.psql)),
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
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("snapshot reset authorizes against control plane for an independent user shard")
    func snapshotResetUsesControlPlaneDeviceAuthority() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let app = try await Application.make(.testing)
        let shardSchema = "im_v2_reset_shard"
        do {
            app.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2),
                as: .psql, isDefault: true
            )
            guard let sql = app.db(.psql) as? any SQLDatabase else {
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
                observedRouterEpoch: 1,
                readFallbackBucket: "control"
            )
            let storage = try V2StaticUserShardStorageRegistry(locations: [
                try .init(
                    bucket: route.bucket,
                    database: app.db(.psql),
                    schema: shardSchema
                ),
                try .init(
                    bucket: "control",
                    database: app.db(.psql),
                    schema: "im_v2"
                ),
            ])
            let service = try V2PostgresDeviceSnapshotResetService(
                registry: storage,
                deviceAvailability: V2PostgresDeviceAvailabilityChecker(
                    database: app.db(.psql)
                ),
                routeFence: V2FixedUserShardRouteFence(route: route, database: app.db(.psql)),
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

            // A retained migration source can still contain capabilities at
            // revocation time. Route-fenced cleanup removes both owners; a
            // later exclusive final-copy therefore cannot resurrect them.
            try await sql.raw("""
                INSERT INTO im_v2.device_sync_cursors
                    (user_id, device_id, state, reset_generation)
                VALUES (\(bind: user), \(bind: device), 'ready', 1)
                """).run()
            try await V2RoutedRevokedDeviceProjectionCleaner(
                routeFence: StaticUserShardRouteFence(
                    route: route,
                    database: app.db(.psql)
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
            ) == 1)
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
                    database: app.db(.psql),
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
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS \(unsafeRaw: shardSchema) CASCADE").run()
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("snapshot V3 resumes page-by-page, publishes immediately, and GC preserves active baselines")
    func snapshotV3ArtifactResumptionAndVersionGC() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
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

            let gc = PostgresV2ProjectionVersionGCWorker(database: app.db(.psql))
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
                store: PostgresV2SyncStore(database: app.db(.psql)), now: { now }
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
                database: app.db(.psql), pageItemLimit: 1, maximumCandidateItems: 1
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
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("snapshot V3 publishes an empty account and rolls back a failed build generation")
    func snapshotV3EmptyAccountAndFailedBuildRecovery() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1),
                as: .psql, isDefault: true
            )
            guard let sql = app.db(.psql) as? any SQLDatabase else {
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
                    try .init(bucket: route.bucket, database: app.db(.psql), schema: "im_v2")
                ]),
                deviceAvailability: V2PostgresDeviceAvailabilityChecker(
                    database: app.db(.psql)
                ),
                routeFence: V2FixedUserShardRouteFence(route: route, database: app.db(.psql)),
                capabilityProfile: "base",
                makeUUID: { UUID() }, now: { now }
            )
            #expect(try await reset.stage(.init(
                operationID: emptySnapshot, userID: userID, deviceID: deviceID
            )) == .init(generation: 2, state: .preparing, wasIdempotent: false))

            let builder = PostgresV2SnapshotArtifactBuilder(database: app.db(.psql))
            #expect(try await builder.runOnce(now: now) == .init(
                claimed: true, published: true, pageCount: 0, itemCount: 0
            ))
            let sync = V2SyncService(store: PostgresV2SyncStore(database: app.db(.psql)), now: { now })
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
                     payload, payload_storage, created_at)
                VALUES (\(bind: userUUID), 1, \(bind: sourceEvent), 'relationship',
                        '{}'::jsonb, 'inline', \(bind: now))
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
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
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
            // Model residue committed by an interrupted earlier copy. The
            // retry must replace the complete target slice, including rows
            // whose keys do not conflict with the current source.
            let staleEffect = UUID(uuidString: "00000000-0000-0000-0000-000000000c07")!
            let staleShared = UUID(uuidString: "00000000-0000-0000-0000-000000000c08")!
            try await sql.raw("INSERT INTO \(unsafeRaw: targetSchema).user_sync_sequences (user_id, next_sequence) VALUES (\(bind: user), 999)").run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: targetSchema).fanout_sync_payloads
                    (source_event_id, projection_kind, payload, created_at)
                VALUES (\(bind: staleShared), 'message', '{"body":"stale"}'::jsonb, \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: targetSchema).user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind,
                     payload, payload_storage, created_at)
                VALUES
                    (\(bind: user), 998, \(bind: staleEffect), 'relationship',
                     '{"target_user_id":"00000000-0000-0000-0000-000000000c09","state":"accepted","updated_at_ms":1}'::jsonb,
                     'inline', \(bind: now)),
                    (\(bind: user), 999, \(bind: staleShared), 'message',
                     NULL, 'fanout_shared', \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: targetSchema).consumer_inbox
                    (consumer_name, source_event_id, target_user_id,
                     projection_kind, committed_at, user_sync_sequence)
                VALUES ('v2-fanout-delivery', \(bind: staleShared), \(bind: user),
                        'message', \(bind: now), 999)
                """).run()
            try await sql.raw("""
                UPDATE \(unsafeRaw: targetSchema).user_sync_retention
                SET compacted_through_sequence = 997
                WHERE user_id = \(bind: user)
                """).run()

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
            let beforeCopy = try await transfer.fingerprints(for: record)
            #expect(beforeCopy.source != beforeCopy.target)
            try await transfer.copy(record)
            try await transfer.copy(record)
            // Sync state remains mutable during forwarding. A final cutover
            // copy must update existing target rows, not merely ignore their
            // primary-key conflicts.
            try await sql.raw("""
                UPDATE \(unsafeRaw: sourceSchema).device_sync_cursors
                SET acknowledged_sequence = 2
                WHERE user_id = \(bind: user) AND device_id = \(bind: device)
                """).run()
            try await transfer.copy(record)
            let fingerprints = try await transfer.fingerprints(for: record)
            #expect(fingerprints.source == fingerprints.target)
            let copiedCursor = try #require(try await sql.raw("""
                SELECT acknowledged_sequence
                FROM \(unsafeRaw: targetSchema).device_sync_cursors
                WHERE user_id = \(bind: user) AND device_id = \(bind: device)
                """).first(decoding: TransferCursorAssertionRow.self))
            #expect(copiedCursor.acknowledgedSequence == 2)
            #expect(try await scopedCount(targetSchema, "user_sync_log", user: user, on: sql) == 2)
            #expect(try await count("\(targetSchema).fanout_sync_payloads", on: sql) == 1)
            #expect(try await scopedCount(targetSchema, "consumer_inbox", user: user, on: sql) == 1)
            #expect(try await scopedCount(targetSchema, "user_projection_versions", user: user, on: sql) == 2)
            #expect(try await scopedCount(targetSchema, "sync_snapshot_artifacts", user: user, on: sql) == 1)
            #expect(try await scopedCount(targetSchema, "device_snapshot_resets", user: user, on: sql) == 1)
            #expect(try await scopedCount(targetSchema, "sync_tokens", user: user, on: sql) == 1)
            #expect(try await scopedCount(targetSchema, "sync_receipts", user: user, on: sql) == 1)
            #expect(try await scopedCount(
                targetSchema,
                "revoked_device_projection_tombstones",
                user: user,
                on: sql
            ) == 1)
            #expect(try await scopedCount(targetSchema, "user_projection_effects", user: user, on: sql) == 0)
            #expect(try await sql.raw("SELECT 1 FROM \(unsafeRaw: targetSchema).user_sync_log WHERE source_event_id IN (\(bind: staleEffect), \(bind: staleShared))").first() == nil)
            #expect(try await sql.raw("SELECT 1 FROM \(unsafeRaw: targetSchema).consumer_inbox WHERE source_event_id = \(bind: staleShared)").first() == nil)
            #expect(try await sql.raw("SELECT 1 FROM \(unsafeRaw: targetSchema).fanout_sync_payloads WHERE source_event_id = \(bind: staleShared)").first() == nil)

            let retained = V2UserShardMigrationRecord(
                migrationID: record.migrationID, userID: record.userID, sourceBucket: record.sourceBucket, targetBucket: record.targetBucket,
                sourceRouterEpoch: record.sourceRouterEpoch, phase: .retention,
                sourceFingerprint: fingerprints.source, targetFingerprint: fingerprints.target,
                retentionUntil: now
            )
            try await transfer.cleanSource(for: retained)
            #expect(try await scopedCount(sourceSchema, "user_sync_log", user: user, on: sql) == 0)
            #expect(try await scopedCount(
                sourceSchema,
                "revoked_device_projection_tombstones",
                user: user,
                on: sql
            ) == 0)
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
            try await configureDefaultUserShardRoute(
                .init(bucket: "users-source", observedRouterEpoch: 1),
                now: now,
                on: sql
            )
            let profile = try RoomCapacityProfile(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100,
                maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10,
                maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3
            )
            let message = try await V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: app.db(.psql)),
                capacityProfile: .init(id: "standard", limits: profile), limits: .init(maxUTF8Bytes: 64), now: { now }
            ).send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "remote"))
            guard case .accepted(let acceptedMessage) = message else {
                Issue.record("expected accepted message")
                return
            }
            let trigger = try #require(try await sql.raw("""
                SELECT source_event_id, plan_id FROM im_v2.room_outbox
                """).first(decoding: TriggerRow.self))
            _ = try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(
                    database: app.db(.psql)
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
            let crossStore = V2CrossStoreFanoutDeliveryStore(
                control: control, registry: registry, migrations: migrations,
                payloadWriteMode: .reference
            )
            #expect(crossStore.maximumConcurrentClaimsPerBucket == 1)
            let coLocatedCrossStore = V2CrossStoreFanoutDeliveryStore(
                control: control, registry: registry, migrations: migrations,
                coLocatedControlBucket: "users-source",
                payloadWriteMode: .reference
            )
            #expect(coLocatedCrossStore.maximumConcurrentClaimsPerBucket == 8)
            let payloadLease = try #require(try await crossStore.claimPending(
                bucket: "users-source", now: now.addingTimeInterval(2), leaseDuration: 30, limit: 1
            ).first)
            #expect(payloadLease.eventPayloadJSON != nil)
            try await crossStore.release(payloadLease)
            let coLocatedLease = try #require(try await coLocatedCrossStore.claimPending(
                bucket: "users-source", now: now.addingTimeInterval(2), leaseDuration: 30, limit: 1
            ).first)
            #expect(coLocatedLease.eventPayloadJSON == nil)
            try await coLocatedCrossStore.release(coLocatedLease)
            // Model a process loss after the target transaction commits but
            // before the control-store completion transaction begins.
            let abandoned = try #require(try await control.claimPending(
                bucket: "users-source", now: now.addingTimeInterval(2), leaseDuration: 30, limit: 1
            ).first)
            let input = try #require(try await control.projectionInput(for: abandoned))
            let location = try registry.location(for: "users-source")
            _ = try await PostgresV2UserShardFanoutProjector(
                database: location.database, schema: location.schema,
                payloadWriteMode: .reference
            ).project(input, now: now.addingTimeInterval(2))
            try await control.release(abandoned)

            let report = try await V2FanoutDeliveryWorker(
                store: crossStore,
                bucket: "users-source", now: { now.addingTimeInterval(3) }
            ).runOnce(limit: 10)
            let release = try await V2FanoutCompletionReleaseWorker(
                store: control,
                now: { now.addingTimeInterval(3) }
            ).runOnce(limit: 10)
            #expect(report == .init(claimedCount: 3, committedCount: 3, staleCount: 0, releasedCount: 0))
            #expect(release == .init(releasedCount: 1, closedPlanCount: 1))
            #expect(try await scopedCount("im_v2", "user_sync_log", user: senderUUID, on: secondarySQL) == 1)
            #expect(try await scopedCount("im_v2", "consumer_inbox", user: senderUUID, on: secondarySQL) == 1)
            #expect(try await scopedCount("im_v2", "user_sync_log", user: senderUUID, on: sql) == 1)
            #expect(try await count("im_v2.fanout_deliveries", on: sql) == 3)
            #expect(try await count("im_v2.message_projection_states", on: sql) == 1)
            #expect(try await count("im_v2.message_projection_states", on: secondarySQL) == 1)
            for physicalStore in [sql, secondarySQL] {
                let linkedState = try #require(try await physicalStore.raw("""
                    SELECT COUNT(*) AS value
                    FROM im_v2.fanout_sync_payloads AS payload
                    JOIN im_v2.message_projection_state_values AS state
                      ON state.state_id = payload.message_state_id
                    WHERE state.message_id = \(bind: UUID(uuidString: acceptedMessage.messageID.rawValue)!)
                      AND payload.payload IS NULL
                    """).first(decoding: CountRow.self))
                #expect(linkedState.value == 1)
            }
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
            try await configureDefaultUserShardRoute(remoteRoute, now: now, on: sql)
            _ = try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(database: app.db(.psql)),
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
            let release = try await V2FanoutCompletionReleaseWorker(
                store: control,
                now: { now.addingTimeInterval(4) }
            ).runOnce(limit: 10)
            #expect(recovered == .init(claimedCount: 3, committedCount: 3, staleCount: 0, releasedCount: 0))
            #expect(release == .init(releasedCount: 1, closedPlanCount: 1))
            #expect(try await count("im_v2.user_sync_log", on: secondarySQL) == 3)
            #expect(try await count("im_v2.consumer_inbox", on: secondarySQL) == 3)
            let remotePayloadEnvelope = try #require(try await secondarySQL.raw("""
                SELECT log.payload IS NULL AS has_null_log_payload,
                       log.payload_storage AS payload_storage,
                       shared.payload ? 'source_event_id' AS has_source_event_id,
                       shared.payload ? 'projection_kind' AS has_projection_kind
                FROM im_v2.user_sync_log AS log
                JOIN im_v2.fanout_sync_payloads AS shared
                  ON shared.source_event_id = log.source_event_id
                 AND shared.projection_kind = log.projection_kind
                WHERE log.source_event_id = \(bind: trigger.sourceEventID)
                LIMIT 1
                """).first(decoding: SyncPayloadEnvelopeRow.self))
            #expect(remotePayloadEnvelope.hasNullLogPayload)
            #expect(remotePayloadEnvelope.payloadStorage == "fanout_shared")
            #expect(!remotePayloadEnvelope.hasSourceEventID)
            #expect(!remotePayloadEnvelope.hasProjectionKind)
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

    /// The cross-store store normally receives 128 claimed targets at once.
    /// Keep this opt-in profile focused on the target-store half so it can
    /// compare the old per-target transaction protocol with the new bounded
    /// inbox/sequence/log transaction without conflating control completion
    /// locks or router traffic.
    @Test("opt-in cross-store target projection batch preserves retry identity")
    func profilesCrossStoreTargetProjectionBatch() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1",
              Environment.get("IMV2_RUN_CROSS_STORE_BATCH_PROFILE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            let sourceEventID = try EventID("00000000-0000-0000-0000-00000000e001")
            let inputs = try (0..<1_000).map { index in
                V2FanoutProjectionInput(
                    sourceEventID: sourceEventID,
                    targetUserID: try .init(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", 0xE1000 + index))!.uuidString),
                    projectionKind: "message",
                    eventPayloadJSON: index.isMultiple(of: 2)
                        ? "{\"profile\":\"cross_store_batch\",\"payload_lane\":\"even\"}"
                        : "{\"profile\":\"cross_store_batch\",\"payload_lane\":\"odd\"}"
                )
            }
            let projector = try PostgresV2UserShardFanoutProjector(database: app.db(.psql), schema: "im_v2")
            let now = Date(timeIntervalSince1970: 1_750_000_200)

            try await installSchema(on: sql)
            let sequentialStartedAt = Date()
            for input in inputs {
                _ = try await projector.project(input, now: now)
            }
            let sequentialMilliseconds = v2LocalElapsedMilliseconds(since: sequentialStartedAt)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 1_000)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()

            try await installSchema(on: sql)
            // Fail after the target transaction has begun. A target batch is
            // useful only if it retains the old one-target transaction's
            // all-or-nothing inbox/sequence/log boundary.
            try await sql.raw("CREATE SEQUENCE im_v2.test_cross_store_batch_failure").run()
            try await sql.raw("""
                CREATE FUNCTION im_v2.fail_first_cross_store_batch_insert() RETURNS trigger
                LANGUAGE plpgsql AS $$
                BEGIN
                    IF nextval('im_v2.test_cross_store_batch_failure') = 1 THEN
                        RAISE EXCEPTION 'injected cross-store batch failure';
                    END IF;
                    RETURN NEW;
                END;
                $$;
                """).run()
            try await sql.raw("""
                CREATE TRIGGER fail_first_cross_store_batch_insert
                BEFORE INSERT ON im_v2.consumer_inbox
                FOR EACH ROW EXECUTE FUNCTION im_v2.fail_first_cross_store_batch_insert()
                """).run()
            await #expect(throws: (any Error).self) {
                _ = try await projector.projectBatch(inputs, now: now)
            }
            #expect(try await count("im_v2.user_sync_log", on: sql) == 0)
            #expect(try await count("im_v2.consumer_inbox", on: sql) == 0)
            try await sql.raw("DROP TRIGGER fail_first_cross_store_batch_insert ON im_v2.consumer_inbox").run()
            try await sql.raw("DROP FUNCTION im_v2.fail_first_cross_store_batch_insert()").run()
            let batchStartedAt = Date()
            let firstBatch = try await projector.projectBatch(inputs, now: now)
            let batchMilliseconds = v2LocalElapsedMilliseconds(since: batchStartedAt)
            let retryBatch = try await projector.projectBatch(inputs, now: now.addingTimeInterval(1))
            #expect(firstBatch == Array(repeating: 1, count: inputs.count))
            #expect(retryBatch == firstBatch)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 1_000)
            #expect(try await count("im_v2.consumer_inbox", on: sql) == 1_000)
            let payloadLaneCounts = try await sql.raw("""
                SELECT payload ->> 'payload_lane' AS payload_lane,
                       COUNT(*)::bigint AS entry_count
                FROM im_v2.user_sync_log
                GROUP BY payload ->> 'payload_lane'
                ORDER BY payload_lane
                """).all(decoding: PayloadLaneCountRow.self)
            #expect(payloadLaneCounts == [
                .init(payloadLane: "even", entryCount: 500),
                .init(payloadLane: "odd", entryCount: 500),
            ])
            print(
                "V2_LOCAL_CROSS_STORE_TARGET_BATCH " +
                    "targets=\(inputs.count) " +
                    "sequential_target_projection_ms=\(sequentialMilliseconds) " +
                    "batched_target_projection_ms=\(batchMilliseconds) " +
                    "retry_sequence_identity=true"
            )
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
        }
    }

    /// Measures the actual cross-store delivery protocol at the fixed
    /// standard-group ceiling: planner writes control records, one remote
    /// bucket worker performs its batch read/project/complete loop, and both
    /// stores must reach their durable terminal facts. It is opt-in because
    /// it performs 5,000 target-store writes and is a local diagnostic, not a
    /// production throughput promise.
    @Test("opt-in cross-store 5,000-member delivery reaches terminal state")
    func profilesCrossStoreFiveThousandMemberDelivery() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              let secondaryDatabaseURL = Environment.get("IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1",
              Environment.get("IMV2_RUN_CROSS_STORE_5K_PROFILE") == "1"
        else { return }
        let deliveryConcurrency: Int
        if let raw = Environment.get("IMV2_CROSS_STORE_5K_DELIVERY_CONCURRENCY") {
            guard let value = Int(raw), (1...4).contains(value) else {
                throw TestConfigurationError.invalidCrossStoreDeliveryConcurrency(raw)
            }
            deliveryConcurrency = value
        } else {
            deliveryConcurrency = 1
        }
        let commitBatchSize: Int
        if let raw = Environment.get("IMV2_CROSS_STORE_5K_COMMIT_BATCH_SIZE") {
            guard let value = Int(raw), [32, 64, 128, 256].contains(value) else {
                throw TestConfigurationError.invalidCrossStoreCommitBatchSize(raw)
            }
            commitBatchSize = value
        } else {
            commitBatchSize = 256
        }
        let commitConcurrency: Int
        if let raw = Environment.get("IMV2_CROSS_STORE_5K_BATCH_COMMIT_CONCURRENCY") {
            guard let value = Int(raw), (1...2).contains(value) else {
                throw TestConfigurationError.invalidCrossStoreBatchCommitConcurrency(raw)
            }
            commitConcurrency = value
        } else {
            commitConcurrency = 2
        }
        let eventPayloadBytes: Int
        if let raw = Environment.get("IMV2_CROSS_STORE_5K_EVENT_PAYLOAD_BYTES") {
            guard let value = Int(raw), (0...16_384).contains(value) else {
                throw TestConfigurationError.invalidCrossStoreEventPayloadBytes(raw)
            }
            eventPayloadBytes = value
        } else {
            eventPayloadBytes = 0
        }
        let eventPayloadJSON = eventPayloadBytes == 0
            ? "{}"
            : "{\"body\":\"\(String(repeating: "x", count: eventPayloadBytes))\"}"

        let app = try await Application.make(.testing)
        do {
            app.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: max(deliveryConcurrency, commitConcurrency)),
                as: .psql, isDefault: true
            )
            let secondaryID = DatabaseID(string: "secondary")
            app.databases.use(
                try .postgres(url: secondaryDatabaseURL, maxConnectionsPerEventLoop: max(deliveryConcurrency, commitConcurrency)),
                as: secondaryID
            )
            guard let controlSQL = app.db(.psql) as? any SQLDatabase,
                  let targetSQL = app.db(secondaryID) as? any SQLDatabase
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await controlSQL.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false,
                  (try await targetSQL.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false
            else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: controlSQL)
            try await installSchema(on: targetSQL)

            let memberCount = 5_000
            let plannerPageSize = 1_000
            let expectedCompletionUnits = memberCount / plannerPageSize
            let room = UUID(uuidString: "00000000-0000-0000-0000-00000000f501")!
            let event = UUID(uuidString: "00000000-0000-0000-0000-00000000f502")!
            let plan = UUID(uuidString: "00000000-0000-0000-0000-00000000f503")!
            let admissionLease = UUID(uuidString: "00000000-0000-0000-0000-00000000f504")!
            let now = Date(timeIntervalSince1970: 1_750_000_300)
            try await controlSQL.raw("""
                INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id, created_at)
                VALUES (\(bind: room), 'cross-store-capacity', 'standard', \(bind: now))
                """).run()
            try await controlSQL.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until,
                     command_window_limit, command_window_used, fanout_window_limit, fanout_window_used,
                     max_outstanding_fanout_units, outstanding_fanout_units,
                     max_outstanding_plans, outstanding_plans)
                VALUES
                    ('cross-store-capacity', 'standard', \(bind: admissionLease), 1, \(bind: now.addingTimeInterval(86_400)),
                     1, 1, \(bind: memberCount), \(bind: memberCount), \(bind: memberCount), \(bind: memberCount), 1, 1)
                """).run()
            try await controlSQL.raw("""
                INSERT INTO im_v2.room_admission
                    (room_id, eligible_member_count, command_window_limit, command_window_used,
                     fanout_window_limit, fanout_window_used, max_outstanding_fanout_units,
                     outstanding_fanout_units, max_outstanding_plans, outstanding_plans,
                     shard_lease_id, shard_lease_generation)
                VALUES
                    (\(bind: room), \(bind: memberCount), 1, 1, \(bind: memberCount), \(bind: memberCount),
                     \(bind: memberCount), \(bind: memberCount), 1, 1, \(bind: admissionLease), 1)
                """).run()
            try await controlSQL.raw("""
                INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision)
                SELECT \(bind: room),
                       ('00000000-0000-0000-0000-' || lpad(to_hex(member), 12, '0'))::uuid,
                       0
                FROM generate_series(1, \(bind: memberCount)) AS member
                """).run()
            try await controlSQL.raw("""
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
                VALUES (\(bind: event), \(bind: room), 1, 'message.accepted', NULL, \(bind: eventPayloadJSON)::jsonb, 0, \(bind: now))
                """).run()
            try await controlSQL.raw("""
                INSERT INTO im_v2.fanout_plans
                    (plan_id, source_event_id, room_id, source_room_sequence, committed_membership_revision,
                     target_rule, enumeration_checkpoint, target_count, reserved_fanout_cost, state, created_at)
                VALUES
                    (\(bind: plan), \(bind: event), \(bind: room), 1, 0,
                     '{"kind":"membership_at_revision"}'::jsonb, '{}'::jsonb,
                     \(bind: memberCount), \(bind: memberCount), 'planning', \(bind: now))
                """).run()

            let remoteRoute = try V2UserShardRoute(bucket: "users-remote", observedRouterEpoch: 1)
            try await configureDefaultUserShardRoute(remoteRoute, now: now, on: controlSQL)
            let trigger = try V2FanoutPlanTrigger(sourceEventID: .init(event.uuidString), planID: .init(plan.uuidString))
            let planningStartedAt = Date()
            #expect(try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(
                    database: app.db(.psql)
                ),
                pageSize: plannerPageSize, now: { now }
            ).plan(trigger) == .init(
                createdCompletionUnits: expectedCompletionUnits,
                createdDeliveries: memberCount,
                wasAlreadyPlanned: false
            ))
            let planningMilliseconds = v2LocalElapsedMilliseconds(since: planningStartedAt)
            // Reset only the isolated control and target databases after
            // planning so the two reports attribute the cross-store delivery
            // protocol itself, rather than schema setup or audience planning.
            let controlProfile = try await V2LocalPostgresDeliveryProfile.startIfEnabled(on: controlSQL)
            let targetProfile = try await V2LocalPostgresDeliveryProfile.startIfEnabled(on: targetSQL)
            let timingRecorder = V2LocalCrossStoreFanoutTimingRecorder()

            let deliveryStore = V2CrossStoreFanoutDeliveryStore(
                control: PostgresV2FanoutDeliveryStore(database: app.db(.psql)),
                registry: try V2StaticUserShardStorageRegistry(locations: [
                    try .init(bucket: "users-remote", database: app.db(secondaryID), schema: "im_v2"),
                ]),
                migrations: PostgresV2UserShardMigrationStore(database: app.db(.psql)),
                timingRecorder: timingRecorder
            )
            let worker = V2FanoutDeliveryWorker(
                store: deliveryStore, bucket: "users-remote",
                router: V2SingleUserShardRouter(route: remoteRoute),
                retryPolicy: .init(initialDelay: 0.01, maximumDelay: 0.1, maximumAttempts: 10, jitterFraction: 0),
                commitBatchSize: commitBatchSize,
                maximumConcurrentCommitBatches: commitConcurrency,
                now: Date.init
            )
            // Only `runDeliveryOnce` is exercised below. The relay is still
            // a real durable composition so this profile uses the same
            // pipeline concurrency gate as the running server.
            let pipeline = V2FanoutPipeline(
                relay: .init(
                    store: PostgresV2RoomOutboxStore(database: app.db(.psql)),
                    publisher: V2LocalFanoutPlanPublisher(planner: .init(
                        store: PostgresV2FanoutPlanStore(
                            database: app.db(.psql)
                        ),
                        pageSize: plannerPageSize,
                        now: Date.init
                    )),
                    retryPolicy: .init(initialDelay: 0.01, maximumDelay: 0.1, maximumAttempts: 10, jitterFraction: 0),
                    now: Date.init
                ),
                deliveryWorker: worker,
                telemetry: V2DiscardingTelemetrySink()
            )
            let deliveryStartedAt = Date()
            var aggregate = V2FanoutDeliveryReport(
                claimedCount: 0, committedCount: 0, staleCount: 0,
                staleRouteCount: 0, releasedCount: 0, pausedCount: 0
            )
            var claimPasses = 0
            for _ in 0..<8 {
                let report = try await pipeline.runDeliveryOnce(
                    claimLimit: 2_000, concurrency: deliveryConcurrency
                )
                if report.claimedCount == 0 { break }
                claimPasses += 1
                aggregate = .init(
                    claimedCount: aggregate.claimedCount + report.claimedCount,
                    committedCount: aggregate.committedCount + report.committedCount,
                    staleCount: aggregate.staleCount + report.staleCount,
                    staleRouteCount: aggregate.staleRouteCount + report.staleRouteCount,
                    releasedCount: aggregate.releasedCount + report.releasedCount,
                    pausedCount: aggregate.pausedCount + report.pausedCount
                )
            }
            let deliveryMilliseconds = v2LocalElapsedMilliseconds(since: deliveryStartedAt)
            let completionRelease = try await drainFanoutCompletionReleases(
                database: app.db(.psql)
            )
            let controlProfileReport = try await controlProfile?.finish(on: controlSQL)
            let targetProfileReport = try await targetProfile?.finish(on: targetSQL)
            let crossStoreTiming = await timingRecorder.summary()

            #expect(aggregate == .init(
                claimedCount: memberCount, committedCount: memberCount, staleCount: 0,
                staleRouteCount: 0, releasedCount: 0, pausedCount: 0
            ))
            #expect(completionRelease.releasedCount == expectedCompletionUnits)
            #expect(completionRelease.closedPlanCount == 1)
            #expect(try await count("im_v2.user_sync_log", on: targetSQL) == Int64(memberCount))
            #expect(try await count("im_v2.consumer_inbox", on: targetSQL) == Int64(memberCount))
            #expect(try await count("im_v2.fanout_deliveries WHERE state = 'terminal'", on: controlSQL) == Int64(memberCount))
            if eventPayloadBytes > 0 {
                let expectedBody = String(repeating: "x", count: eventPayloadBytes)
                let persistedPayloads = try await targetSQL.raw("""
                    SELECT COUNT(*)::bigint AS value
                    FROM im_v2.user_sync_log AS log
                    JOIN im_v2.fanout_sync_payloads AS shared
                      ON shared.source_event_id = log.source_event_id
                     AND shared.projection_kind = log.projection_kind
                    WHERE shared.payload ->> 'body' = \(bind: expectedBody)
                    """).first(decoding: CountRow.self)?.value
                #expect(persistedPayloads == Int64(memberCount))
            }
            let terminal = try #require(try await controlSQL.raw("""
                SELECT state FROM im_v2.fanout_plans WHERE plan_id = \(bind: plan)
                """).first(decoding: PushStateRow.self))
            #expect(terminal.state == "terminal")
            let roomReservation = try #require(try await controlSQL.raw("""
                SELECT outstanding_fanout_units, outstanding_plans
                FROM im_v2.room_admission WHERE room_id = \(bind: room)
                """).first(decoding: OutstandingRow.self))
            #expect(roomReservation.outstandingFanoutUnits == 0)
            #expect(roomReservation.outstandingPlans == 0)
            print(
                "V2_LOCAL_CROSS_STORE_5K_DELIVERY " +
                    "members=\(memberCount) planner_page_size=\(plannerPageSize) " +
                    "commit_batch_size=\(commitBatchSize) commit_concurrency=\(commitConcurrency) delivery_claim_batch_size=2000 delivery_concurrency=\(deliveryConcurrency) " +
                    "event_payload_bytes=\(eventPayloadBytes) " +
                    "planning_ms=\(planningMilliseconds) delivery_ms=\(deliveryMilliseconds) " +
                    "claim_passes=\(claimPasses) \(crossStoreTiming.machineReadableFields) terminal=true"
            )
            if let controlProfileReport {
                for line in controlProfileReport.machineReadableLines(scope: "CROSS_STORE_CONTROL") {
                    print(line)
                }
            }
            if let targetProfileReport {
                for line in targetProfileReport.machineReadableLines(scope: "CROSS_STORE_TARGET") {
                    print(line)
                }
            }

            try await controlSQL.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await targetSQL.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let controlSQL = app.db(.psql) as? any SQLDatabase {
                try? await controlSQL.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            if let targetSQL = app.db(DatabaseID(string: "secondary")) as? any SQLDatabase {
                try? await targetSQL.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
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
            try await configureDefaultUserShardRoute(
                .init(bucket: "users-source", observedRouterEpoch: 1),
                now: now,
                on: sql
            )
            let shadow = V2PostgresUserShardProjectionShadowForwarder(
                registry: registry,
                routeFence: router,
                coLocatedControlBuckets: ["users-source"]
            )
            let direct = PostgresV2DirectMessagingStore(database: app.db(.psql), shadowForwarder: shadow)
            let capacityProfile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3))
            let forwardingLeaseID = UUID(uuidString: "00000000-0000-0000-0000-000000000f17")!
            try await sql.raw("INSERT INTO im_v2.shard_admission_pools (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit, fanout_window_limit, max_outstanding_fanout_units, max_outstanding_plans) VALUES ('rooms-primary', 'standard', \(bind: forwardingLeaseID), 1, \(bind: now.addingTimeInterval(600)), 10, 100, 100, 10)").run()
            try await sql.raw("INSERT INTO im_v2.public_user_profiles (user_id, public_handle, display_name, revision, created_at, updated_at) VALUES (\(bind: senderUUID), 'sender012', '发送者', 1, \(bind: now), \(bind: now)), (\(bind: memberTwoUUID), 'member015', '成员二', 1, \(bind: now), \(bind: now))").run()
            let directService = try V2DirectMessagingService(store: direct, capacityProfile: capacityProfile, roomShardID: "rooms-primary", now: { now })
            guard case .opened(let directRoom) = try await directService.open(actorUserID: senderID, operationID: try .init("00000000-0000-0000-0000-000000000f18"), targetUserID: try .init(memberTwoUUID.uuidString)) else {
                Issue.record("expected direct room")
                return
            }
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

            // Account-owned profile changes use a separate outbox, but must
            // use the same migration-safe shadow write as the direct/social
            // control records. The changed profile belongs to member two; its
            // only direct recipient is the currently forwarding sender.
            let profileEventID = UUID(uuidString: "00000000-0000-0000-0000-000000000f19")!
            let directory = V2PostgresPublicIdentityDirectory(
                database: app.db(.psql), policy: try .init(maximumQueries: 10, window: 60),
                makeUUID: { profileEventID }, now: { now.addingTimeInterval(3) }
            )
            _ = try await directory.updateDisplayName(
                for: try .init(memberTwoUUID.uuidString), displayName: "成员二新版"
            )
            let profileWorker = V2DirectRoomProfilePropagationWorker(
                database: app.db(.psql), shadowForwarder: shadow, now: { now.addingTimeInterval(4) }
            )
            #expect(try await profileWorker.runOnce(limit: 1).projectedRecipientCount == 1)

            #expect(try await scopedCount("im_v2", "user_sync_log", user: senderUUID, on: sql) == 5)
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

            let transfer = try PostgresV2UserShardProjectionTransfer(
                source: app.db(.psql), target: app.db(secondaryID),
                sourceBucket: "users-source", targetBucket: "users-target"
            )
            let verified = try await V2DurableUserShardMigrationCoordinator(
                store: migrations, copier: transfer, verifier: transfer, now: { now.addingTimeInterval(3) }
            ).verifyForwarding(migrationID: migration.migrationID)
            #expect(verified.phase == .verified)
            _ = try await V2PostgresUserShardRouteControl(
                database: app.db(.psql), operatorPrincipal: "router-test",
                finalizer: V2UserShardProjectionMigrationExecutor(
                    store: migrations, registry: registry,
                    coLocatedControlBuckets: ["users-source"]
                )
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
            #expect(try await scopedCount("im_v2", "user_sync_log", user: senderUUID, on: secondarySQL) == 7)
            let postCutover = try #require(try await secondarySQL.raw("""
                SELECT user_sync_sequence, projection_kind FROM im_v2.user_sync_log
                WHERE user_id = \(bind: senderUUID) ORDER BY user_sync_sequence DESC LIMIT 1
                """).first(decoding: SyncKindRow.self))
            #expect(postCutover.sequence == 7)
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
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
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
            let userID = try UserID("00000000-0000-0000-0000-000000000901")
            let deviceID = try DeviceID("00000000-0000-0000-0000-000000000902")
            #expect(try await firstInstance.blockedRetryAfterSeconds(accountHandle: "limit-test") == nil)
            try await firstInstance.recordRejectedAttempt(accountHandle: "limit-test", userID: userID, deviceID: deviceID)
            #expect(try await secondInstance.blockedRetryAfterSeconds(accountHandle: "limit-test") == nil)
            try await secondInstance.recordRejectedAttempt(accountHandle: "limit-test", userID: userID, deviceID: deviceID)
            let retryAfter = try #require(try await firstInstance.blockedRetryAfterSeconds(accountHandle: "limit-test"))
            #expect((1 ... 60).contains(retryAfter))
            try await secondInstance.recordSuccessfulAttempt(accountHandle: "limit-test", userID: userID, deviceID: deviceID)
            #expect(try await firstInstance.blockedRetryAfterSeconds(accountHandle: "limit-test") == nil)
            try await firstInstance.recordRejectedAttempt(accountHandle: "unknown-audit", userID: nil, deviceID: deviceID)

            let audits = try await sql.raw("""
                SELECT outcome, user_id, device_id, occurred_at
                FROM im_v2.account_password_authentication_audit
                ORDER BY occurred_at, event_id
                """).all(decoding: PasswordAuthenticationAuditRow.self)
            #expect(audits.map(\.outcome) == ["assertion_rejected", "assertion_rejected", "assertion_succeeded", "assertion_rejected"])
            #expect(audits.dropLast().allSatisfy { $0.userID == UUID(uuidString: userID.rawValue) && $0.deviceID == UUID(uuidString: deviceID.rawValue) })
            #expect(audits.last?.userID == nil)
            #expect(audits.last?.deviceID == UUID(uuidString: deviceID.rawValue))

            // Hold the canonical handle lock, queue a rejection first, then a
            // success. Without the same advisory lock on the success path,
            // DELETE observes an empty table and the later rejected attempt
            // leaves a stale failure window after a successful login.
            let raceHandle = "success-rejection-race"
            let gate = PostgreSQLTransactionGate()
            let blocker = Task {
                try await app.db(.psql).transaction { transaction in
                    guard let transactionSQL = transaction as? any SQLDatabase else {
                        throw V2PasswordLoginRateLimitError.unavailable
                    }
                    let lockKey = "v2-password-login-rate:" + raceHandle
                    try await transactionSQL.raw(
                        "SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))"
                    ).run()
                    await gate.holdTransaction()
                }
            }
            await gate.waitUntilHeld()
            var rejected: Task<Void, Error>?
            var succeeded: Task<Void, Error>?
            do {
                rejected = Task {
                    try await firstInstance.recordRejectedAttempt(
                        accountHandle: raceHandle,
                        userID: userID,
                        deviceID: deviceID
                    )
                }
                try await waitForAdvisoryWaiters(1, on: sql)
                succeeded = Task {
                    try await secondInstance.recordSuccessfulAttempt(
                        accountHandle: raceHandle,
                        userID: userID,
                        deviceID: deviceID
                    )
                }
                try await waitForAdvisoryWaiters(2, on: sql)
            } catch {
                rejected?.cancel()
                succeeded?.cancel()
                await gate.releaseTransaction()
                _ = try? await blocker.value
                _ = try? await rejected?.value
                _ = try? await succeeded?.value
                throw error
            }
            await gate.releaseTransaction()
            try await blocker.value
            try await rejected?.value
            try await succeeded?.value
            #expect(try await firstInstance.blockedRetryAfterSeconds(accountHandle: raceHandle) == nil)
            #expect(try await sql.raw("SELECT 1 FROM im_v2.account_password_login_rate_limits WHERE account_handle = \(bind: raceHandle)").first() == nil)

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

    @Test("password registration writes a privacy-minimized audit fact atomically")
    func recordsPasswordRegistrationAudit() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2PasswordAccountStoreError.unavailable
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let deviceID = try DeviceID("00000000-0000-0000-0000-000000000903")
            let userID = try await V2PostgresPasswordAccountStore(
                database: app.db(.psql),
                now: { Date(timeIntervalSince1970: 1_750_001_001) }
            ).register(
                accountHandle: "audit-registration",
                passwordHash: String(repeating: "x", count: 60),
                publicHandle: "audit_registration",
                displayName: "审计注册",
                deviceID: deviceID
            )

            let audit = try #require(try await sql.raw("""
                SELECT outcome, user_id, device_id, occurred_at
                FROM im_v2.account_password_authentication_audit
                """).first(decoding: PasswordAuthenticationAuditRow.self))
            #expect(audit.outcome == "registration_succeeded")
            #expect(audit.userID == UUID(uuidString: userID.rawValue))
            #expect(audit.deviceID == UUID(uuidString: deviceID.rawValue))
            #expect(audit.occurredAt == Date(timeIntervalSince1970: 1_750_001_001))

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

    @Test("schema readiness fails before serving without password failure state")
    func schemaReadinessRequiresPasswordLoginRateLimitTable() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2SchemaReadinessError.unsupportedDatabase
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            // The canonical schema must satisfy the complete startup contract
            // before this test removes one required table. This catches a
            // schema migration whose renamed functions or triggers were not
            // reflected in the binary readiness gate.
            try await V2SchemaReadiness.verify(database: app.db(.psql))
            try await sql.raw("DROP TABLE im_v2.account_password_login_rate_limits").run()

            await #expect(throws: V2SchemaReadinessError.unavailableTable("im_v2.account_password_login_rate_limits")) {
                try await V2SchemaReadiness.verify(database: app.db(.psql))
            }

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

    @Test("schema readiness accepts the legacy direct event cursor contract during an online migration")
    func schemaReadinessAcceptsLegacyDirectEventCursorContract() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2SchemaReadinessError.unsupportedDatabase
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            // Model the pre-consolidation side of the online migration: the
            // old reader cursor exists, while the new sequence invariant has
            // not yet been installed. Startup must accept this state so the
            // reader can be deployed before the concurrent index drop.
            try await sql.raw("ALTER TABLE im_v2.messages DROP CONSTRAINT messages_message_row_sequences_match").run()
            try await sql.raw("CREATE INDEX messages_direct_event_cursor_idx ON im_v2.messages (room_id, room_sequence) WHERE accepted_event_storage = 'message_row'").run()
            try await V2SchemaReadiness.verify(database: app.db(.psql))

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

    @Test("edge client request budget is shared across replicas and stores no clear-text address")
    func enforcesPseudonymousEdgeClientRateLimit() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2AccountEdgeClientRateLimitError.unavailable
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let key = try V2AccountEdgeClientRateLimitKey(base64Encoded: Data(repeating: 8, count: 32).base64EncodedString())
            let policy = try V2AccountEdgeClientRateLimitPolicy(maximumRequests: 2, window: 60)
            let address = try V2AccountEdgeClientAddress("198.51.100.8")
            let firstReplica = V2PostgresAccountEdgeClientRateLimiter(
                database: app.db(.psql), policy: policy, key: key,
                now: { Date(timeIntervalSince1970: 1_750_002_000) }
            )

            #expect(try await firstReplica.consume(address: address) == .allowed)
            #expect(try await firstReplica.consume(address: address) == .allowed)
            #expect(try await firstReplica.consume(address: address) == .rateLimited(retryAfterSeconds: 60))
            #expect(try await firstReplica.consume(address: try V2AccountEdgeClientAddress("203.0.113.9")) == .allowed)

            let secondReplica = V2PostgresAccountEdgeClientRateLimiter(
                database: app.db(.psql), policy: policy, key: key,
                now: { Date(timeIntervalSince1970: 1_750_002_061) }
            )
            #expect(try await secondReplica.consume(address: address) == .allowed)
            #expect(try await secondReplica.consume(address: try V2AccountEdgeClientAddress("2001:db8::8")) == .allowed)

            let persistedKeys = try await sql.raw("SELECT client_key FROM im_v2.account_edge_client_rate_limits ORDER BY client_key").all(decoding: EdgeClientRateLimitKeyRow.self)
            #expect(persistedKeys.count == 3)
            #expect(persistedKeys.allSatisfy { $0.clientKey != "198.51.100.8" && $0.clientKey != "2001:db8::8" })
            #expect(persistedKeys.allSatisfy { $0.clientKey.count == 64 })
            #expect(try await secondReplica.purgeExpired(limit: 100) == 1)
            #expect(try await count("im_v2.account_edge_client_rate_limits", on: sql) == 2)

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

    @Test("display-name updates fan out to direct peers in bounded, idempotent pages")
    func propagatesDisplayNameToExistingDirectPeers() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2DirectRoomProfilePropagationError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_001_000)
            let sourceUUID = UUID(uuidString: "00000000-0000-0000-0000-00000000a001")!
            let firstPeerUUID = UUID(uuidString: "00000000-0000-0000-0000-00000000a002")!
            let secondPeerUUID = UUID(uuidString: "00000000-0000-0000-0000-00000000a003")!
            let sourceUserID = try UserID(sourceUUID.uuidString)
            let capacityProfile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100,
                maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10,
                maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3
            ))
            let leaseID = UUID(uuidString: "00000000-0000-0000-0000-00000000a010")!
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until,
                     command_window_limit, fanout_window_limit, max_outstanding_fanout_units, max_outstanding_plans)
                VALUES ('rooms-primary', 'standard', \(bind: leaseID), 1, \(bind: now.addingTimeInterval(600)),
                        10, 100, 100, 10)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, revision, created_at, updated_at)
                VALUES (\(bind: sourceUUID), 'source_a001', '旧名称', 1, \(bind: now), \(bind: now)),
                       (\(bind: firstPeerUUID), 'peer_a002', '同伴一', 1, \(bind: now), \(bind: now)),
                       (\(bind: secondPeerUUID), 'peer_a003', '同伴二', 1, \(bind: now), \(bind: now))
                """).run()

            let directService = try V2DirectMessagingService(
                store: PostgresV2DirectMessagingStore(database: app.db(.psql)),
                capacityProfile: capacityProfile, roomShardID: "rooms-primary", now: { now }
            )
            var directRoomIDs: [RoomID] = []
            for peer in [firstPeerUUID, secondPeerUUID] {
                guard case .opened(let room) = try await directService.open(
                    actorUserID: sourceUserID, operationID: try .init(UUID().uuidString),
                    targetUserID: try .init(peer.uuidString)
                ) else {
                    Issue.record("expected direct room")
                    return
                }
                directRoomIDs.append(room.roomID)
            }
            // A direct peer becomes visible only once the first eligible
            // message commits. Seed that state here so this test exercises
            // display-name propagation for real conversations, rather than
            // leaking an unopened stranger-initiated room.
            let directMessages = V2SendMessageService(
                store: PostgresV2RoomWriteStore(
                    database: app.db(.psql),
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 3, window: 86_400)
                ),
                capacityProfile: capacityProfile,
                limits: try .init(maxUTF8Bytes: 64),
                now: { now }
            )
            for roomID in directRoomIDs {
                guard case .accepted = try await directMessages.send(.init(
                    roomID: roomID,
                    actorUserID: sourceUserID,
                    clientMessageID: try .init(UUID().uuidString),
                    text: "已建立会话"
                )) else {
                    Issue.record("expected accepted first direct message")
                    return
                }
            }

            let profileEventID = UUID(uuidString: "00000000-0000-0000-0000-00000000a020")!
            let directory = V2PostgresPublicIdentityDirectory(
                database: app.db(.psql), policy: try .init(maximumQueries: 10, window: 60),
                makeUUID: { profileEventID }, now: { now.addingTimeInterval(1) }
            )
            let updated = try await directory.updateDisplayName(for: sourceUserID, displayName: "新名称")
            #expect(updated.displayName == "新名称")

            let router = V2PostgresUserShardRouter(database: app.db(.psql))
            try await configureDefaultUserShardRoute(
                .init(bucket: "users-primary", observedRouterEpoch: 1),
                now: now,
                on: sql
            )
            let registry = try V2StaticUserShardStorageRegistry(locations: [
                try .init(bucket: "users-primary", database: app.db(.psql), schema: "im_v2"),
            ])
            let shadow = V2PostgresUserShardProjectionShadowForwarder(
                registry: registry,
                routeFence: router,
                coLocatedControlBuckets: ["users-primary"]
            )
            // Simulate a process loss after the control-plane sync record was
            // committed but before it reached the current user shard. The
            // expired lease must retry that exact source event rather than
            // append a second control record or skip the first recipient.
            let interruptedWorker = V2DirectRoomProfilePropagationWorker(
                database: app.db(.psql), shadowForwarder: ProfilePropagationFailingShadowForwarder(),
                now: { now.addingTimeInterval(2) }
            )
            await #expect(throws: ProfilePropagationShadowFailure.interrupted) {
                try await interruptedWorker.runOnce(limit: 1)
            }
            let interruptedControlCount = try #require(try await sql.raw("""
                SELECT COUNT(*)::bigint AS value FROM im_v2.user_sync_log
                WHERE source_event_id = \(bind: profileEventID) AND projection_kind = 'direct_room_profile'
                """).first(decoding: CountRow.self))
            #expect(interruptedControlCount.value == 1)
            let interruptedInvalidationCount = try #require(try await sql.raw("""
                SELECT COUNT(*)::bigint AS value FROM im_v2.user_sync_log
                WHERE source_event_id = \(bind: profileEventID) AND projection_kind = 'profile_invalidation'
                """).first(decoding: CountRow.self))
            #expect(interruptedInvalidationCount.value == 1)
            let interruptedOutbox = try #require(try await sql.raw("""
                SELECT state, enumeration_checkpoint IS NOT NULL AS checkpointed
                FROM im_v2.public_profile_update_outbox WHERE source_event_id = \(bind: profileEventID)
                """).first(decoding: ProfilePropagationOutboxRow.self))
            #expect(interruptedOutbox.state == "claimed")
            #expect(!interruptedOutbox.checkpointed)
            try await sql.raw("""
                UPDATE im_v2.public_profile_update_outbox
                SET lease_expires_at = CURRENT_TIMESTAMP - INTERVAL '1 second'
                WHERE source_event_id = \(bind: profileEventID)
                """).run()
            let recoveryNow = Date()
            let worker = V2DirectRoomProfilePropagationWorker(
                database: app.db(.psql), shadowForwarder: shadow, now: { recoveryNow }
            )
            let firstPage = try await worker.runOnce(limit: 1)
            #expect(firstPage.projectedRecipientCount == 1)
            #expect(firstPage.completedUpdateCount == 0)
            let pending = try #require(try await sql.raw("""
                SELECT state, enumeration_checkpoint IS NOT NULL AS checkpointed
                FROM im_v2.public_profile_update_outbox WHERE source_event_id = \(bind: profileEventID)
                """).first(decoding: ProfilePropagationOutboxRow.self))
            #expect(pending.state == "pending")
            #expect(pending.checkpointed)

            let secondPage = try await worker.runOnce(limit: 1)
            #expect(secondPage.projectedRecipientCount == 1)
            #expect(secondPage.completedUpdateCount == 1)
            let completed = try #require(try await sql.raw("""
                SELECT state, completed_at IS NOT NULL AS completed
                FROM im_v2.public_profile_update_outbox WHERE source_event_id = \(bind: profileEventID)
                """).first(decoding: ProfilePropagationCompletedRow.self))
            #expect(completed.state == "completed")
            #expect(completed.completed)
            let projections = try await sql.raw("""
                SELECT user_id, payload->>'room_id' AS room_id, payload->>'display_name' AS display_name,
                       (payload->>'revision')::bigint AS revision
                FROM im_v2.user_sync_log
                WHERE source_event_id = \(bind: profileEventID) AND projection_kind = 'direct_room_profile'
                ORDER BY user_id
                """).all(decoding: ProfilePropagationProjectionRow.self)
            #expect(projections.map(\.userID) == [firstPeerUUID, secondPeerUUID])
            #expect(projections.allSatisfy { $0.displayName == "新名称" && $0.revision == 2 })
            #expect(projections.allSatisfy { UUID(uuidString: $0.roomID)?.uuidString == $0.roomID })
            let invalidations = try await sql.raw("""
                SELECT user_id, payload->>'user_id' AS user_id_payload,
                       (payload->>'minimum_profile_revision')::bigint AS minimum_profile_revision
                FROM im_v2.user_sync_log
                WHERE source_event_id = \(bind: profileEventID) AND projection_kind = 'profile_invalidation'
                ORDER BY user_id
                """).all(decoding: ProfileInvalidationAssertionRow.self)
            #expect(invalidations.map(\.recipientUserID) == [firstPeerUUID, secondPeerUUID])
            #expect(invalidations.allSatisfy {
                $0.invalidatedUserID == sourceUUID && $0.minimumProfileRevision == 2
            })

            // A completed source event is never reprojected on a later poll.
            let replay = try await worker.runOnce(limit: 8)
            #expect(replay.projectedRecipientCount == 0)
            #expect(try await scopedCount("im_v2", "user_sync_log", user: firstPeerUUID, on: sql) == 3)
            #expect(try await scopedCount("im_v2", "user_sync_log", user: secondPeerUUID, on: sql) == 3)

            let disableOperationID = UUID(uuidString: "00000000-0000-0000-0000-00000000a021")!
            let disableService = try V2PostgresAccountDisableService(
                database: app.db(.psql),
                operatorPrincipal: "account-safety-primary",
                now: { now.addingTimeInterval(10) }
            )
            #expect(try await disableService.disable(.init(
                userID: sourceUserID,
                operationID: disableOperationID,
                reason: .policyEnforcement
            )) == .disabled(disabledAt: now.addingTimeInterval(10)))
            let suspensionReport = try await worker.runOnce(limit: 8)
            let suspensionProfiles = try await sql.raw("SELECT user_id FROM im_v2.user_sync_log WHERE source_event_id = \(bind: disableOperationID) AND projection_kind = 'direct_room_profile'").all(decoding: ProjectionRecipientAssertionRow.self)
            let suspensionInvalidations = try await sql.raw("SELECT user_id, payload->>'profile_state' AS profile_state, (payload->>'minimum_profile_revision')::bigint AS minimum_profile_revision FROM im_v2.user_sync_log WHERE source_event_id = \(bind: disableOperationID) AND projection_kind = 'profile_invalidation' ORDER BY user_id").all(decoding: ProfileSuspensionInvalidationAssertionRow.self)
            #expect(suspensionReport == .init(claimedUpdateCount: 1, projectedRecipientCount: 2, completedUpdateCount: 1))
            #expect(suspensionProfiles.isEmpty)
            #expect(suspensionInvalidations.map(\.recipientUserID) == [firstPeerUUID, secondPeerUUID])
            #expect(suspensionInvalidations.allSatisfy { $0.profileState == "suspended" && $0.minimumProfileRevision == 3 })

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

    @Test("mention authorization preserves bilateral block checks without scanning a whole room")
    func mentionAuthorizationRejectsBlockedUserTargets() async throws {
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
            try await sql.raw("""
                INSERT INTO im_v2.user_blocks (blocker_user_id, blocked_user_id, created_at)
                VALUES (\(bind: memberTwoUUID), \(bind: senderUUID), \(bind: now))
                """).run()
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3))
            let service = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: app.db(.psql)),
                capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64),
                now: { now }
            )

            await #expect(throws: V2MentionValidationError.notAuthorized) {
                try await service.send(.init(
                    roomID: roomID,
                    actorUserID: senderID,
                    clientMessageID: clientMessageID,
                    text: "@受限成员",
                    mentions: [.user(try .init(memberTwoUUID.uuidString))]
                ))
            }
            #expect(try await count("im_v2.messages", on: sql) == 0)
            #expect(try await count("im_v2.room_events", on: sql) == 0)
            #expect(try await count("im_v2.fanout_plans", on: sql) == 0)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("direct room-log messages persist once and recover only through revision-fenced room cursors")
    func persistsDirectRoomLogWithoutPerUserFanoutArtifacts() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
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

            let now = Date(timeIntervalSince1970: 1_750_200_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 100,
                maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100,
                maxOutstandingPlans: 100, maxEnumerationPageSize: 10,
                maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1,
                retryAfterSeconds: 3
            ))
            let lease = UUID(uuidString: "00000000-0000-0000-0000-00000000c001")!
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until,
                     command_window_limit, fanout_window_limit, max_outstanding_fanout_units, max_outstanding_plans)
                VALUES ('rooms-primary', 'standard', \(bind: lease), 1, \(bind: now.addingTimeInterval(600)),
                        100, 100, 100, 100)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, revision, created_at, updated_at)
                VALUES
                    (\(bind: senderUUID), 'sender012', '发送者', 1, \(bind: now), \(bind: now)),
                    (\(bind: memberTwoUUID), 'member015', '成员二', 1, \(bind: now), \(bind: now)),
                    (\(bind: memberThreeUUID), 'member016', '成员三', 1, \(bind: now), \(bind: now))
                """).run()
            let direct = try V2DirectMessagingService(
                store: PostgresV2DirectMessagingStore(database: app.db(.psql)),
                capacityProfile: profile,
                roomShardID: "rooms-primary",
                now: { now }
            )
            let recipient = try UserID(memberTwoUUID.uuidString)
            guard case .opened(let room) = try await direct.open(
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-00000000c002"),
                targetUserID: recipient
            ) else {
                Issue.record("expected direct room")
                return
            }
            guard case .opened(let secondRoom) = try await direct.open(
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-00000000c005"),
                targetUserID: try .init(memberThreeUUID.uuidString)
            ) else {
                Issue.record("expected second direct room")
                return
            }
            let shardCredits = V2ShardAdmissionCommandCreditPool(
                database: app.db(.psql), batchSize: 2
            )
            let writer = PostgresV2RoomWriteStore(
                database: app.db(.psql),
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400),
                shadowForwarder: SuccessfulProjectionShadowForwarder(),
                contentReviewMode: .disabled,
                directFanoutMode: .roomLog,
                directRoomLogAdmissionMode: .shardOnly,
                shardAdmissionCommandCreditPool: shardCredits
            )
            let messages = V2SendMessageService(
                store: writer, capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64), now: { now }
            )
            // Neither sender has a direct-policy cache entry yet and both
            // sends must consume a stranger quota, advance the reply marker,
            // and publish the recipient profile/capability. This proves the
            // cold path remains one all-or-nothing transaction rather than
            // trusting an optimistic cache write.
            let coldEligibility = await writer.atomicBatchEligibility(requests: [
                .init(
                    command: try .init(
                        roomID: room.roomID, senderUserID: senderID,
                        clientMessageID: try .init("00000000-0000-0000-0000-00000000c030"),
                        text: "第一条冷批量消息", limits: try .init(maxUTF8Bytes: 64)
                    ),
                    capacityProfile: profile,
                    identifiers: try .init(
                        messageID: .init("00000000-0000-0000-0000-00000000c031"),
                        eventID: .init("00000000-0000-0000-0000-00000000c032"),
                        planID: .init("00000000-0000-0000-0000-00000000c033")
                    ),
                    now: now
                ),
                .init(
                    command: try .init(
                        roomID: secondRoom.roomID, senderUserID: senderID,
                        clientMessageID: try .init("00000000-0000-0000-0000-00000000c034"),
                        text: "第二条冷批量消息", limits: try .init(maxUTF8Bytes: 64)
                    ),
                    capacityProfile: profile,
                    identifiers: try .init(
                        messageID: .init("00000000-0000-0000-0000-00000000c035"),
                        eventID: .init("00000000-0000-0000-0000-00000000c036"),
                        planID: .init("00000000-0000-0000-0000-00000000c037")
                    ),
                    now: now
                ),
            ])
            #expect(coldEligibility == [true, true])
            let coldBatched = try await writer.acceptAtomically(requests: [
                .init(
                    command: try .init(
                        roomID: room.roomID, senderUserID: senderID,
                        clientMessageID: try .init("00000000-0000-0000-0000-00000000c030"),
                        text: "第一条冷批量消息", limits: try .init(maxUTF8Bytes: 64)
                    ),
                    capacityProfile: profile,
                    identifiers: try .init(
                        messageID: .init("00000000-0000-0000-0000-00000000c031"),
                        eventID: .init("00000000-0000-0000-0000-00000000c032"),
                        planID: .init("00000000-0000-0000-0000-00000000c033")
                    ),
                    now: now
                ),
                .init(
                    command: try .init(
                        roomID: secondRoom.roomID, senderUserID: senderID,
                        clientMessageID: try .init("00000000-0000-0000-0000-00000000c034"),
                        text: "第二条冷批量消息", limits: try .init(maxUTF8Bytes: 64)
                    ),
                    capacityProfile: profile,
                    identifiers: try .init(
                        messageID: .init("00000000-0000-0000-0000-00000000c035"),
                        eventID: .init("00000000-0000-0000-0000-00000000c036"),
                        planID: .init("00000000-0000-0000-0000-00000000c037")
                    ),
                    now: now
                ),
            ])
            #expect(coldBatched.allSatisfy {
                if case .accepted(let message) = $0 { return message.usesRoomEventLog }
                return false
            })
            #expect(try await count("im_v2.stranger_message_windows", on: sql) == 2)
            let coldProjectionRows = try await sql.raw("""
                SELECT user_id, user_sync_sequence, source_event_id, projection_kind
                FROM im_v2.user_sync_log
                WHERE source_event_id IN
                    ('00000000-0000-0000-0000-00000000c032'::uuid,
                     '00000000-0000-0000-0000-00000000c036'::uuid)
                ORDER BY user_id, user_sync_sequence
                """).all(decoding: DirectBatchProjectionSyncAssertionRow.self)
            #expect(coldProjectionRows.count == 4)
            #expect(coldProjectionRows.filter {
                $0.userID == senderUUID
                    && $0.projectionKind == "direct_sending_capability"
            }.count == 2)
            #expect(coldProjectionRows.filter {
                $0.projectionKind == "direct_room_profile"
            }.count == 2)
            let senderCapabilitySequences = coldProjectionRows
                .filter { $0.userID == senderUUID }
                .map(\.userSyncSequence)
            #expect(senderCapabilitySequences.count == 2)
            if senderCapabilitySequences.count == 2 {
                #expect(senderCapabilitySequences[1] == senderCapabilitySequences[0] + 1)
            }
            let coldPairStates = try await sql.raw("""
                SELECT lower_profile_visible_to_higher,
                       higher_profile_visible_to_lower,
                       lower_can_send, higher_can_send
                FROM im_v2.direct_room_pairs
                WHERE room_id IN
                    (\(bind: UUID(uuidString: room.roomID.rawValue)! ),
                     \(bind: UUID(uuidString: secondRoom.roomID.rawValue)! ))
                """).all(decoding: DirectPairProjectionStateAssertionRow.self)
            #expect(coldPairStates.count == 2)
            #expect(coldPairStates.allSatisfy {
                $0.lowerProfileVisibleToHigher || $0.higherProfileVisibleToLower
            })
            #expect(coldPairStates.allSatisfy {
                $0.lowerCanSend == true || $0.higherCanSend == true
            })
            let coldCreditSnapshot = await shardCredits.snapshot()
            #expect(coldCreditSnapshot.databaseCreditsReserved == 2)
            #expect(coldCreditSnapshot.committedCredits == 2)
            let clientID = try ClientMessageID("00000000-0000-0000-0000-00000000c003")
            guard case .accepted(let accepted) = try await messages.send(.init(
                roomID: room.roomID, actorUserID: senderID, clientMessageID: clientID,
                text: "只写一次的私聊"
            )) else {
                Issue.record("expected room-log acceptance")
                return
            }
            #expect(accepted.usesRoomEventLog)
            let replay = try await messages.send(.init(
                roomID: room.roomID, actorUserID: senderID, clientMessageID: clientID,
                text: "只写一次的私聊"
            ))
            guard case .idempotent(let replayed) = replay else {
                Issue.record("expected idempotent replay")
                return
            }
            #expect(replayed == accepted)

            // A later policy mutation must still be fenced by the durable
            // user policy revision inside the write transaction; a stale
            // cache entry must never authorize this send.
            guard case .accepted = try await messages.send(.init(
                roomID: room.roomID, actorUserID: senderID,
                clientMessageID: try .init("00000000-0000-0000-0000-00000000c004"),
                text: "缓存回填后的第二条消息"
            )) else {
                Issue.record("expected second room-log acceptance")
                return
            }

            // Friend relationships make the two established conversations
            // eligible without changing their room-event history.  The test
            // removes them immediately after the append so the stale-policy
            // assertion below retains its original stranger semantics.
            try await sql.raw("""
                INSERT INTO im_v2.user_relationships
                    (lower_user_id, higher_user_id, state, requested_by_user_id, updated_at)
                VALUES
                    (\(bind: senderUUID), \(bind: memberTwoUUID), 'accepted', \(bind: senderUUID), \(bind: now)),
                    (\(bind: senderUUID), \(bind: memberThreeUUID), 'accepted', \(bind: senderUUID), \(bind: now))
                """).run()
            try await sql.raw("""
                UPDATE im_v2.direct_room_pairs
                SET direct_policy_revision = direct_policy_revision + 1
                WHERE room_id IN (\(bind: UUID(uuidString: room.roomID.rawValue)! ),
                                  \(bind: UUID(uuidString: secondRoom.roomID.rawValue)! ))
                """).run()
            // The direct-policy revisions above intentionally invalidate the
            // old cache entries. Warm both independently first, then the
            // atomic pair below proves that the set preflight only activates
            // after it can verify fresh durable revision fences.
            guard case .accepted = try await messages.send(.init(
                roomID: room.roomID, actorUserID: senderID,
                clientMessageID: try .init("00000000-0000-0000-0000-00000000c021"),
                text: "关系变更后的缓存回填"
            )), case .accepted = try await messages.send(.init(
                roomID: secondRoom.roomID, actorUserID: senderID,
                clientMessageID: try .init("00000000-0000-0000-0000-00000000c022"),
                text: "第二个会话的缓存回填"
            )) else {
                Issue.record("expected post-revision cache warm acceptance")
                return
            }
            let batched = try await writer.acceptAtomically(requests: [
                .init(
                    command: try .init(
                        roomID: room.roomID,
                        senderUserID: senderID,
                        clientMessageID: try .init("00000000-0000-0000-0000-00000000c007"),
                        text: "第一条批量消息",
                        limits: try .init(maxUTF8Bytes: 64)
                    ),
                    capacityProfile: profile,
                    identifiers: try .init(
                        messageID: .init("00000000-0000-0000-0000-00000000c008"),
                        eventID: .init("00000000-0000-0000-0000-00000000c009"),
                        planID: .init("00000000-0000-0000-0000-00000000c010")
                    ),
                    now: now
                ),
                .init(
                    command: try .init(
                        roomID: secondRoom.roomID,
                        senderUserID: senderID,
                        clientMessageID: try .init("00000000-0000-0000-0000-00000000c011"),
                        text: "第二条批量消息",
                        limits: try .init(maxUTF8Bytes: 64)
                    ),
                    capacityProfile: profile,
                    identifiers: try .init(
                        messageID: .init("00000000-0000-0000-0000-00000000c012"),
                        eventID: .init("00000000-0000-0000-0000-00000000c013"),
                        planID: .init("00000000-0000-0000-0000-00000000c014")
                    ),
                    now: now
                ),
            ])
            #expect(batched.allSatisfy {
                if case .accepted(let message) = $0 { return message.usesRoomEventLog }
                return false
            })
            try await sql.raw("""
                DELETE FROM im_v2.user_relationships
                WHERE lower_user_id = \(bind: senderUUID)
                  AND higher_user_id IN (\(bind: memberTwoUUID), \(bind: memberThreeUUID))
                """).run()

            // Rich messages retain the existing CTE: the plain-message fast
            // path must never silently skip a required moderation record.
            let reviewingMessages = V2SendMessageService(
                store: PostgresV2RoomWriteStore(
                    database: app.db(.psql),
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400),
                    shadowForwarder: SuccessfulProjectionShadowForwarder(),
                    contentReviewMode: .enabled,
                    directFanoutMode: .roomLog,
                    directRoomLogAdmissionMode: .shardOnly,
                    shardAdmissionCommandCreditPool: shardCredits
                ),
                capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64),
                now: { now }
            )
            guard case .accepted = try await reviewingMessages.send(.init(
                roomID: room.roomID, actorUserID: senderID,
                clientMessageID: try .init("00000000-0000-0000-0000-00000000c00a"),
                text: "审核路径仍保留完整持久化"
            )) else {
                Issue.record("expected reviewed room-log acceptance")
                return
            }
            #expect(try await count("im_v2.content_review_jobs", on: sql) == 1)

            _ = try await direct.setStrangerMessagePermission(
                actorUserID: recipient,
                operationID: try .init("00000000-0000-0000-0000-00000000c005"),
                permission: .deny
            )
            let stalePolicyAttempt = try await messages.send(.init(
                roomID: room.roomID, actorUserID: senderID,
                clientMessageID: try .init("00000000-0000-0000-0000-00000000c006"),
                text: "策略变更后必须被拒绝"
            ))
            guard case .denied(let stalePolicyDenial) = stalePolicyAttempt else {
                Issue.record("stale direct-send cache bypassed a policy change")
                return
            }
            #expect(stalePolicyDenial.reason == .generic)

            let roomLog = V2GroupEventLogService(store: PostgresV2GroupEventLogStore(database: app.db(.psql)))
            let senderPage = try await roomLog.pull(roomID: room.roomID, actorUserID: senderID, afterRoomSequence: accepted.roomSequence - 1, pageSize: 10)
            let recipientPage = try await roomLog.pull(roomID: room.roomID, actorUserID: recipient, afterRoomSequence: accepted.roomSequence - 1, pageSize: 10)
            #expect(senderPage.events.map(\.roomSequence) == [
                accepted.roomSequence,
                accepted.roomSequence + 1,
                accepted.roomSequence + 2,
                accepted.roomSequence + 3,
                accepted.roomSequence + 4
            ])
            #expect(recipientPage.events == senderPage.events)
            #expect(String(data: try #require(senderPage.events.first?.payload), encoding: .utf8)?.contains("只写一次的私聊") == true)
            let acceptedEventID = try #require(UUID(uuidString: senderPage.events.first?.sourceEventID.rawValue ?? ""))
            let directMessageEvent = try #require(try await sql.raw("""
                SELECT accepted_event_id, accepted_event_storage,
                       accepted_membership_revision
                FROM im_v2.messages
                WHERE message_id = \(bind: UUID(uuidString: accepted.messageID.rawValue)!)
                """).first(decoding: DirectMessageRowEventRow.self))
            #expect(directMessageEvent.acceptedEventID == acceptedEventID)
            #expect(directMessageEvent.acceptedEventStorage == "message_row")
            #expect(accepted.sourceEventID?.rawValue == acceptedEventID.uuidString)
            // Direct-room creation commits its initial membership revision
            // before the first accepted message. The row-source event must
            // retain that exact historical fence rather than assuming zero.
            #expect(directMessageEvent.acceptedMembershipRevision == 1)
            #expect(accepted.acceptedMembershipRevision == 1)
            #expect(try await count(
                "im_v2.room_events WHERE event_id = '\(acceptedEventID.uuidString)'",
                on: sql
            ) == 0)

            // The accepted event must continue to expose its original body
            // after a later message revision changes the mutable row.
            await #expect(throws: (any Error).self) {
                try await sql.raw("""
                    UPDATE im_v2.messages
                    SET text_body = '没有 revision 的非法修改'
                    WHERE message_id = \(bind: UUID(uuidString: accepted.messageID.rawValue)!)
                    """).run()
            }
            try await sql.raw("""
                UPDATE im_v2.messages
                SET text_body = '已编辑的当前内容', rich_entities = '[]'::jsonb,
                    content_revision = 2
                WHERE message_id = \(bind: UUID(uuidString: accepted.messageID.rawValue)!)
                """).run()
            let recoveredAfterRevision = try await roomLog.pull(
                roomID: room.roomID, actorUserID: senderID,
                afterRoomSequence: accepted.roomSequence - 1, pageSize: 10
            )
            let originalPayload = String(
                data: try #require(recoveredAfterRevision.events.first?.payload),
                encoding: .utf8
            )
            #expect(originalPayload?.contains("只写一次的私聊") == true)
            #expect(originalPayload?.contains("已编辑的当前内容") == false)
            #expect(try await count("im_v2.message_content_versions", on: sql) == 1)
            await #expect(throws: V2GroupEventLogError.actorNotMember) {
                try await roomLog.pull(roomID: room.roomID, actorUserID: try .init(memberThreeUUID.uuidString), afterRoomSequence: 0, pageSize: 10)
            }

            #expect(try await count("im_v2.messages", on: sql) == 9)
            // Eight ordinary direct messages are materialized from the
            // message row itself. The reviewed message intentionally retains
            // the complete room-event write graph.
            #expect(try await count("im_v2.room_events WHERE event_type = 'message.accepted'", on: sql) == 1)
            #expect(try await count("im_v2.message_projection_states", on: sql) == 0)
            #expect(try await count("im_v2.fanout_sync_payloads", on: sql) == 0)
            #expect(try await count("im_v2.fanout_plans", on: sql) == 0)
            #expect(try await count("im_v2.fanout_completion_units", on: sql) == 0)
            #expect(try await count("im_v2.fanout_deliveries", on: sql) == 0)
            #expect(try await count("im_v2.room_outbox", on: sql) == 0)
            #expect(try await count("im_v2.user_sync_log WHERE projection_kind = 'message'", on: sql) == 0)
            // Shard-only admission deliberately leaves the room-local
            // command window unchanged. The durable shard credit is the
            // command-capacity authority for these direct room-log sends.
            let roomAdmission = try #require(try await sql.raw("""
                SELECT command_window_used, fanout_window_used
                FROM im_v2.room_admission
                WHERE room_id = \(bind: UUID(uuidString: room.roomID.rawValue)!)
                """).first(decoding: CapacityRow.self))
            #expect(roomAdmission.commandWindowUsed == 0)
            #expect(roomAdmission.fanoutWindowUsed == 0)
            let creditedAdmission = try #require(try await sql.raw("""
                SELECT command_window_used, fanout_window_used
                FROM im_v2.shard_admission_pools
                WHERE room_shard_id = 'rooms-primary' AND capacity_profile_id = 'standard'
                """).first(decoding: CapacityRow.self))
            // Nine accepted commands reserve five database credit batches;
            // the cold and warm room-log appends still preserve the
            // same conservatively durable command capacity.
            #expect(creditedAdmission.commandWindowUsed == 10)
            let creditSnapshot = await shardCredits.snapshot()
            #expect(creditSnapshot.batchReservations == 5)
            #expect(creditSnapshot.databaseCreditsReserved == 10)
            #expect(creditSnapshot.committedCredits == 9)

            let roomUUID = try #require(UUID(uuidString: room.roomID.rawValue))
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 1 WHERE room_id = \(bind: roomUUID)").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision = 1 WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: memberTwoUUID)").run()
            await #expect(throws: V2GroupEventLogError.actorNotMember) {
                try await roomLog.pull(roomID: room.roomID, actorUserID: recipient, afterRoomSequence: 0, pageSize: 10)
            }

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

    @Test("direct room-log command credits are durable, bounded, and cannot oversell a shard window")
    func directRoomLogCommandCreditsPreserveShardCapacity() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1),
                as: .psql, isDefault: true
            )
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists")
                .first(decoding: ExistsRow.self))?.exists == false
            else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_201_000)
            let leaseID = UUID(uuidString: "00000000-0000-0000-0000-00000000c101")!
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until,
                     command_window_limit, fanout_window_limit,
                     max_outstanding_fanout_units, max_outstanding_plans)
                VALUES ('rooms-credit-test', 'credit-test', \(bind: leaseID), 1,
                        \(bind: now.addingTimeInterval(600)), 2, 10, 10, 10)
                """).run()
            let state = try ShardAdmissionState(
                lease: .init(
                    id: try .init(leaseID.uuidString), generation: 1,
                    validUntil: now.addingTimeInterval(600),
                    commandWindow: try .init(limit: 2),
                    fanoutWindow: try .init(limit: 10),
                    maxOutstandingFanoutUnits: 10, maxOutstandingPlans: 10
                ),
                outstandingFanoutUnits: 0, outstandingPlans: 0
            )
            let credits = V2ShardAdmissionCommandCreditPool(
                database: app.db(.psql), batchSize: 2
            )

            for expectedEffectiveUsed in 0 ... 1 {
                let acquisition = try await credits.acquire(
                    roomShardID: "rooms-credit-test", capacityProfileID: "credit-test",
                    shardState: state, now: now
                )
                guard case .granted(let token, let effective) = acquisition,
                      let effectiveLease = effective.lease
                else {
                    Issue.record("expected a durable command credit")
                    return
                }
                #expect(effectiveLease.commandWindow.used == expectedEffectiveUsed)
                await credits.commit(token)
            }
            let exhausted = try await credits.acquire(
                roomShardID: "rooms-credit-test", capacityProfileID: "credit-test",
                shardState: state, now: now
            )
            guard case .rateLimited = exhausted else {
                Issue.record("the credit pool oversold the command window")
                return
            }
            let persisted = try #require(try await sql.raw("""
                SELECT command_window_used, fanout_window_used
                FROM im_v2.shard_admission_pools
                WHERE room_shard_id = 'rooms-credit-test'
                  AND capacity_profile_id = 'credit-test'
                """).first(decoding: CapacityRow.self))
            #expect(persisted.commandWindowUsed == 2)
            #expect(await credits.snapshot() == .init(
                activeCredits: 0, inFlightCredits: 0,
                batchReservations: 1, databaseCreditsReserved: 2,
                committedCredits: 2, returnedCredits: 0,
                expiredCreditsDiscarded: 0, capacityRejections: 1
            ))

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

    @Test("a 100k hybrid group persists ordinary messages as room-log events and fans out only explicit mentions")
    func acceptsOneHundredThousandMemberHybridRoomWithoutGlobalFanout() async throws {
        guard Environment.get("IMV2_RUN_HYBRID_100K_CAPACITY") == "1",
              let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let startedAt = Date()
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            let schemaElapsed = v2LocalElapsedMilliseconds(since: startedAt)

            let room = UUID(uuidString: "00000000-0000-0000-0000-00000000b001")!
            let sender = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            let mentioned = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            let lease = UUID(uuidString: "00000000-0000-0000-0000-00000000b002")!
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("""
                INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id, delivery_mode)
                VALUES (\(bind: room), 'hybrid-100k', 'hybrid-100k', 'large_group_hybrid')
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.group_rooms (room_id, owner_user_id, title, created_at)
                VALUES (\(bind: room), \(bind: sender), '十万混合群', \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until,
                     command_window_limit, fanout_window_limit, max_outstanding_fanout_units, max_outstanding_plans)
                VALUES ('hybrid-100k', 'hybrid-100k', \(bind: lease), 1, \(bind: now.addingTimeInterval(600)),
                        1_000, 1_000, 1_000, 1_000)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_admission
                    (room_id, eligible_member_count, command_window_limit, fanout_window_limit,
                     max_outstanding_fanout_units, max_outstanding_plans, shard_lease_id, shard_lease_generation)
                VALUES (\(bind: room), 100000, 1_000, 1_000, 1_000, 1_000, \(bind: lease), 1)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision)
                SELECT \(bind: room),
                       ('00000000-0000-0000-0000-' || lpad(to_hex(member_number), 12, '0'))::uuid,
                       CASE WHEN member_number = 1 THEN 'owner' ELSE 'member' END,
                       0
                FROM generate_series(1, 100000) AS member_number
                """).run()
            let seedElapsed = v2LocalElapsedMilliseconds(since: startedAt) - schemaElapsed

            let profile = try RoomCapacityProfile(maxEligibleMembers: 100000, maxCommandsPerWindow: 1_000, maxFanoutUnitsPerWindow: 1_000, maxOutstandingFanoutUnits: 1_000, maxOutstandingPlans: 1_000, maxEnumerationPageSize: 1_000, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 1)
            let service = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: app.db(.psql)),
                capacityProfile: try .init(id: "hybrid-100k", limits: profile),
                limits: try .init(maxUTF8Bytes: 64), now: { now }
            )
            let ordinaryStart = Date()
            guard case .accepted(let ordinary) = try await service.send(.init(roomID: try .init(room.uuidString), actorUserID: try .init(sender.uuidString), clientMessageID: try .init("00000000-0000-0000-0000-00000000b003"), text: "普通大群消息")) else {
                Issue.record("expected hybrid ordinary message acceptance")
                return
            }
            let ordinaryElapsed = v2LocalElapsedMilliseconds(since: ordinaryStart)

            let groupLog = V2GroupEventLogService(store: PostgresV2GroupEventLogStore(database: app.db(.psql)))
            let pullStart = Date()
            let ordinaryPage = try await groupLog.pull(roomID: try .init(room.uuidString), actorUserID: try .init(sender.uuidString), afterRoomSequence: 0, pageSize: 10)
            let pullElapsed = v2LocalElapsedMilliseconds(since: pullStart)

            let mentionStart = Date()
            guard case .accepted(let mentionedMessage) = try await service.send(.init(
                roomID: try .init(room.uuidString), actorUserID: try .init(sender.uuidString),
                clientMessageID: try .init("00000000-0000-0000-0000-00000000b004"), text: "@指定成员",
                mentions: [.user(try .init(mentioned.uuidString))]
            )) else {
                Issue.record("expected hybrid mention message acceptance")
                return
            }
            let mentionElapsed = v2LocalElapsedMilliseconds(since: mentionStart)

            let plans = try await sql.raw("""
                SELECT source_room_sequence, state, target_count, reserved_fanout_cost
                FROM im_v2.fanout_plans WHERE room_id = \(bind: room)
                ORDER BY source_room_sequence
                """).all(decoding: HybridPlanAssertionRow.self)
            let outboxCount = try await count("im_v2.room_outbox", on: sql)
            let targetCount = try await count("im_v2.fanout_plan_targets", on: sql)
            let verificationElapsed = v2LocalElapsedMilliseconds(since: startedAt) - schemaElapsed - seedElapsed - ordinaryElapsed - pullElapsed - mentionElapsed

            #expect(ordinary.roomSequence == 1)
            #expect(ordinaryPage.events.count == 1)
            #expect(ordinaryPage.events.first?.roomSequence == ordinary.roomSequence)
            #expect(ordinaryPage.events.first?.projectionKind == "message")
            #expect(mentionedMessage.roomSequence == 2)
            #expect(plans == [
                .init(roomSequence: 1, state: "terminal", targetCount: 0, reservedFanoutCost: 0),
                .init(roomSequence: 2, state: "planning", targetCount: 1, reservedFanoutCost: 1),
            ])
            #expect(outboxCount == 1)
            #expect(targetCount == 1)
            print("V2_LOCAL_HYBRID_100K_TIMING total_wall_ms=\(v2LocalElapsedMilliseconds(since: startedAt)) schema_ms=\(schemaElapsed) seed_ms=\(seedElapsed) ordinary_accept_ms=\(ordinaryElapsed) first_pull_ms=\(pullElapsed) mention_accept_ms=\(mentionElapsed) verification_ms=\(max(0, verificationElapsed)) ordinary_fanout_targets=0 mention_fanout_targets=1")

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("finalizing audience recovery claims each stale draft once before replay")
    func claimsStaleFinalizingAudienceRecoveryWork() async throws {
        guard Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1",
              let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL")
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            let recoveryIndex = try #require(try await sql.raw("""
                SELECT COUNT(*) AS value
                FROM pg_indexes
                WHERE schemaname = 'im_v2'
                  AND tablename = 'group_room_creation_drafts'
                  AND indexname = 'group_room_creation_drafts_finalizing_recovery_idx'
                """).first(decoding: CountRow.self))
            #expect(recoveryIndex.value == 1)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let stale = now.addingTimeInterval(-31)
            let actor = UUID(uuidString: "00000000-0000-0000-0000-00000000c101")!
            let first = UUID(uuidString: "00000000-0000-0000-0000-00000000c102")!
            let second = UUID(uuidString: "00000000-0000-0000-0000-00000000c103")!
            try await sql.raw("""
                INSERT INTO im_v2.group_room_creation_drafts
                    (actor_user_id, operation_id, title, state, created_at, updated_at, expires_at)
                VALUES
                    (\(bind: actor), \(bind: first), '恢复一', 'finalizing', \(bind: stale), \(bind: stale), \(bind: now.addingTimeInterval(86_400))),
                    (\(bind: actor), \(bind: second), '恢复二', 'finalizing', \(bind: stale), \(bind: stale), \(bind: now.addingTimeInterval(86_400)))
                """).run()
            let store = PostgresV2GroupAudienceImportStore(database: app.db(.psql))

            let firstClaim = try await store.recoverableFinalizing(now: now, staleAfter: 30, limit: 1)
            let secondClaim = try await store.recoverableFinalizing(now: now, staleAfter: 30, limit: 2)
            let repeatedClaim = try await store.recoverableFinalizing(now: now, staleAfter: 30, limit: 2)

            #expect(firstClaim.count == 1)
            #expect(secondClaim.count == 1)
            #expect(Set((firstClaim + secondClaim).map(\.operationID)) == Set([try GroupRoomOperationID(first.uuidString), try GroupRoomOperationID(second.uuidString)]))
            #expect(repeatedClaim.isEmpty)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("disabled content review creates no job for message acceptance or editing")
    func disabledContentReviewSkipsDurableJobs() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
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
            try await seedRoom(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100,
                maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10,
                maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3
            ))
            let sender = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: app.db(.psql), contentReviewMode: .disabled),
                capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64),
                now: { now }
            )
            guard case .accepted(let accepted) = try await sender.send(.init(
                roomID: roomID,
                actorUserID: senderID,
                clientMessageID: clientMessageID,
                text: "review lane disabled"
            )) else {
                Issue.record("expected accepted message")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            #expect(try await count("im_v2.content_review_jobs", on: sql) == 0)

            let editor = V2MessageEditService(
                store: PostgresV2MessageEditStore(database: app.db(.psql), contentReviewMode: .disabled),
                capacityProfile: profile,
                maximumTextUTF8Bytes: 64,
                identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000da1")! }),
                now: { now.addingTimeInterval(1) }
            )
            guard case .edited = try await editor.edit(.init(
                roomID: roomID,
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000da2"),
                messageID: accepted.messageID,
                expectedMessageRevision: 1,
                text: "still not reviewed"
            )) else {
                Issue.record("expected edited message")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            #expect(try await count("im_v2.content_review_jobs", on: sql) == 0)

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

    @Test("content review jobs commit with messages, fence expired leases, and persist review decisions")
    func contentReviewJobsAreTransactionalLeaseFencedAndDurablyResolved() async throws {
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
                maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100,
                maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10,
                maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3
            ))
            let sender = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: app.db(.psql)),
                capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64),
                now: { now }
            )
            guard case .accepted(let accepted) = try await sender.send(.init(
                roomID: roomID,
                actorUserID: senderID,
                clientMessageID: clientMessageID,
                text: "needs review"
            )) else {
                Issue.record("expected accepted message")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let messageUUID = try #require(UUID(uuidString: accepted.messageID.rawValue))
            let initial = try #require(try await sql.raw("""
                SELECT state, expected_content_revision, decision
                FROM im_v2.content_review_jobs WHERE message_id = \(bind: messageUUID)
                """).first(decoding: ContentReviewJobAssertionRow.self))
            #expect(initial.state == "pending")
            #expect(initial.revision == 1)
            #expect(initial.decision == nil)

            let oldToken = UUID(uuidString: "00000000-0000-0000-0000-000000000d01")!
            let newToken = UUID(uuidString: "00000000-0000-0000-0000-000000000d02")!
            let oldStore = PostgresV2ContentReviewStore(database: app.db(.psql), makeUUID: { oldToken })
            let oldLease = try #require(try await oldStore.claimPending(now: now, leaseDuration: 10, limit: 1).first)
            #expect(oldLease.input.messageID == accepted.messageID)
            #expect(try await oldStore.validateAndRenew(oldLease, now: now.addingTimeInterval(1), leaseDuration: 9) == .current)

            let renewedStore = PostgresV2ContentReviewStore(database: app.db(.psql), makeUUID: { newToken })
            let renewedLease = try #require(try await renewedStore.claimPending(now: now.addingTimeInterval(11), leaseDuration: 10, limit: 1).first)
            #expect(renewedLease.claimToken == newToken)
            #expect(renewedLease.claimToken != oldLease.claimToken)

            // An old worker may resume after its lease expires, but it must
            // never release or resolve the newer owner's claim.
            try await oldStore.scheduleRetry(oldLease, disposition: .retry(at: now.addingTimeInterval(20)), now: now.addingTimeInterval(12))
            #expect(try await oldStore.resolve(oldLease, verdict: .clear, now: now.addingTimeInterval(12)) == false)
            let fenced = try #require(try await sql.raw("""
                SELECT state, claim_token = \(bind: newToken) AS has_new_token, decision
                FROM im_v2.content_review_jobs WHERE message_id = \(bind: messageUUID)
                """).first(decoding: ContentReviewLeaseFenceAssertionRow.self))
            #expect(fenced.state == "claimed")
            #expect(fenced.hasNewToken)
            #expect(fenced.decision == nil)

            #expect(try await renewedStore.resolve(
                renewedLease,
                verdict: .reviewRequired(try .init(category: "manual_review", severity: 2, confidence: 0.75)),
                now: now.addingTimeInterval(12)
            ))
            let completed = try #require(try await sql.raw("""
                SELECT state, decision, claim_token IS NULL AS released
                FROM im_v2.content_review_jobs WHERE message_id = \(bind: messageUUID)
                """).first(decoding: ContentReviewCompletionAssertionRow.self))
            #expect(completed.state == "completed")
            #expect(completed.decision == "review_required")
            #expect(completed.released == true)
            #expect(try await count("im_v2.content_review_decisions", on: sql) == 1)
            #expect(try await count("im_v2.content_review_findings", on: sql) == 1)
            #expect(try await count("im_v2.content_review_cases", on: sql) == 1)

            // A late worker must never close or redact a newer edit. The
            // edit path rewrites the expected revision in its own transaction;
            // this assertion exercises the review store's final fence.
            guard case .accepted(let editedLater) = try await sender.send(.init(
                roomID: roomID,
                actorUserID: senderID,
                clientMessageID: try .init("00000000-0000-0000-0000-000000000d03"),
                text: "will be edited before review"
            )) else {
                Issue.record("expected second accepted message")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let editedLaterUUID = try #require(UUID(uuidString: editedLater.messageID.rawValue))
            let staleStore = PostgresV2ContentReviewStore(
                database: app.db(.psql),
                makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000d04")! }
            )
            let staleLease = try #require(try await staleStore.claimPending(now: now.addingTimeInterval(20), leaseDuration: 10, limit: 1).first)
            #expect(staleLease.input.messageID == editedLater.messageID)
            try await sql.raw("UPDATE im_v2.messages SET content_revision = 2 WHERE message_id = \(bind: editedLaterUUID)").run()
            #expect(try await staleStore.validateAndRenew(staleLease, now: now.addingTimeInterval(21), leaseDuration: 10) == .superseded)
            let superseded = try #require(try await sql.raw("""
                SELECT state, decision FROM im_v2.content_review_jobs WHERE message_id = \(bind: editedLaterUUID)
                """).first(decoding: ContentReviewCompletionAssertionRow.self))
            #expect(superseded.state == "superseded")
            #expect(superseded.decision == nil)

            // A slow provider may return after its original deadline. If no
            // other worker has replaced the token, validation renews the same
            // claim instead of permanently superseding valid content.
            guard case .accepted(let slowReview) = try await sender.send(.init(
                roomID: roomID,
                actorUserID: senderID,
                clientMessageID: try .init("00000000-0000-0000-0000-000000000d05"),
                text: "slow review"
            )) else {
                Issue.record("expected third accepted message")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let slowStore = PostgresV2ContentReviewStore(
                database: app.db(.psql),
                makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000d06")! }
            )
            let slowLease = try #require(try await slowStore.claimPending(now: now.addingTimeInterval(30), leaseDuration: 1, limit: 1).first)
            #expect(slowLease.input.messageID == slowReview.messageID)
            #expect(try await slowStore.validateAndRenew(slowLease, now: now.addingTimeInterval(32), leaseDuration: 10) == .current)

            let retryAt = now.addingTimeInterval(50)
            try await slowStore.scheduleRetry(slowLease, disposition: .retry(at: retryAt), now: now.addingTimeInterval(33))
            #expect(try await slowStore.claimPending(now: now.addingTimeInterval(49), leaseDuration: 10, limit: 1).isEmpty)
            let retryLease = try #require(try await slowStore.claimPending(now: retryAt, leaseDuration: 10, limit: 1).first)
            #expect(retryLease.attempt == slowLease.attempt + 1)
            try await slowStore.scheduleRetry(retryLease, disposition: .pause, now: now.addingTimeInterval(51))
            let paused = try #require(try await sql.raw("""
                SELECT state, next_attempt_at, paused_at
                FROM im_v2.content_review_jobs
                WHERE message_id = \(bind: UUID(uuidString: slowReview.messageID.rawValue)!)
                """).first(decoding: ContentReviewRetryAssertionRow.self))
            #expect(paused.state == "paused")
            #expect(paused.nextAttemptAt == nil)
            #expect(paused.pausedAt == now.addingTimeInterval(51))
            let reviewMetrics = PostgresV2DurableWorkMetricsSource(database: app.db(.psql))
            #expect((await reviewMetrics.durableWorkMetricsSnapshot()).pausedContentReviews == 1)

            let replay = V2DurableWorkOperatorReplayService(
                store: PostgresV2DurableWorkReplayStore(database: app.db(.psql)),
                operatorPrincipal: "content-safety-oncall",
                now: { now.addingTimeInterval(52) }
            )
            let replayResult = try await replay.replay(.init(
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000d07")!,
                target: try .init(kind: .contentReview, sourceEventID: .init(slowReview.messageID.rawValue)),
                reason: .dependencyRecovered
            ))
            #expect(replayResult.outcome == .requeued)
            let replayedMetrics = await reviewMetrics.durableWorkMetricsSnapshot()
            #expect(replayedMetrics.pausedContentReviews == 0)
            #expect(replayedMetrics.readyContentReviews == 1)
            let replayedLease = try #require(try await slowStore.claimPending(now: now.addingTimeInterval(52), leaseDuration: 10, limit: 1).first)
            #expect(replayedLease.input.messageID == slowReview.messageID)
            #expect(replayedLease.attempt == 1)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("a content-review escalation keeps the message visible and opens exactly one review case")
    func contentReviewEscalationDoesNotRedactTheMessage() async throws {
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
                maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100,
                maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10,
                maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3
            ))
            let sender = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: app.db(.psql)),
                capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64),
                now: { now }
            )
            guard case .accepted(let accepted) = try await sender.send(.init(
                roomID: roomID,
                actorUserID: senderID,
                clientMessageID: clientMessageID,
                text: "needs manual review"
            )) else {
                Issue.record("expected accepted message")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }

            let reviewStore = PostgresV2ContentReviewStore(
                database: app.db(.psql),
                makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000d10")! }
            )
            let moderation = V2TrustedSafetyModerationService(
                store: PostgresV2ModerationStore(database: app.db(.psql)),
                safetyActorUserID: try .init("00000000-0000-0000-0000-000000000d12"),
                capacityProfile: profile,
                identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000d13")! }),
                now: { now.addingTimeInterval(1) }
            )
            let worker = try V2ContentReviewWorker(
                store: reviewStore,
                reviewer: V2ConfiguredContentReviewer(reviewTerms: ["manual"]),
                moderation: moderation,
                now: { now.addingTimeInterval(1) }
            )

            #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, resolvedCount: 1, redactedCount: 0, releasedCount: 0))
            let messageUUID = try #require(UUID(uuidString: accepted.messageID.rawValue))
            let message = try #require(try await sql.raw("""
                SELECT withdrawn_at IS NOT NULL AS withdrawn, content_revision
                FROM im_v2.messages WHERE message_id = \(bind: messageUUID)
                """).first(decoding: ContentReviewRedactionAssertionRow.self))
            let job = try #require(try await sql.raw("""
                SELECT state, decision FROM im_v2.content_review_jobs WHERE message_id = \(bind: messageUUID)
                """).first(decoding: ContentReviewCompletionAssertionRow.self))
            #expect(!message.withdrawn)
            #expect(message.revision == 1)
            #expect(job.state == "completed")
            #expect(job.decision == "review_required")
            #expect(try await count("im_v2.content_review_decisions", on: sql) == 1)
            #expect(try await count("im_v2.content_review_findings", on: sql) == 1)
            #expect(try await count("im_v2.content_review_cases", on: sql) == 1)
            #expect(try await count("im_v2.moderation_operations", on: sql) == 0)
            #expect(try await count("im_v2.moderation_audit_entries", on: sql) == 0)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("a content policy violation resumes its staged finding after a crash following authoritative redaction")
    func contentReviewViolationUsesAuthoritativeRedaction() async throws {
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
                maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100,
                maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10,
                maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3
            ))
            let sender = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: app.db(.psql)),
                capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64),
                now: { now }
            )
            guard case .accepted(let accepted) = try await sender.send(.init(
                roomID: roomID,
                actorUserID: senderID,
                clientMessageID: clientMessageID,
                text: "blocked policy text"
            )) else {
                Issue.record("expected accepted message")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let reviewStore = PostgresV2ContentReviewStore(
                database: app.db(.psql),
                makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000d11")! }
            )
            let moderation = V2TrustedSafetyModerationService(
                store: PostgresV2ModerationStore(database: app.db(.psql)),
                safetyActorUserID: try .init("00000000-0000-0000-0000-000000000d12"),
                capacityProfile: profile,
                identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000d13")! }),
                now: { now.addingTimeInterval(1) }
            )
            let crashedLease = try #require(try await reviewStore.claimPending(
                now: now.addingTimeInterval(1), leaseDuration: 1, limit: 1
            ).first)
            let finding = try V2ContentReviewFinding(category: "configured_policy", severity: 4, confidence: 1)
            #expect(try await reviewStore.stageViolation(crashedLease, finding: finding))
            let redaction = try V2TrustedSafetyModeration(
                roomID: crashedLease.input.roomID,
                operationID: .init(crashedLease.input.messageID.rawValue),
                action: .redactMessage,
                messageID: crashedLease.input.messageID,
                expectedMessageRevision: crashedLease.input.contentRevision,
                reasonCode: .init("content_policy_violation")
            )
            guard case .applied = try await moderation.apply(redaction) else {
                Issue.record("expected the authoritative redaction to commit before the simulated crash")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }

            // Simulate process loss before resolve(). The replacement lease
            // must reuse the staged finding, recognize its stable moderation
            // operation, and never call the provider again.
            let recoveringStore = PostgresV2ContentReviewStore(
                database: app.db(.psql),
                makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000d14")! }
            )
            let recoveringWorker = try V2ContentReviewWorker(
                store: recoveringStore,
                reviewer: UnexpectedContentReviewer(),
                moderation: moderation,
                now: { now.addingTimeInterval(3) }
            )
            #expect(try await recoveringWorker.runOnce(limit: 1) == .init(
                claimedCount: 1, resolvedCount: 1, redactedCount: 1, releasedCount: 0
            ))
            let messageUUID = try #require(UUID(uuidString: accepted.messageID.rawValue))
            let redacted = try #require(try await sql.raw("""
                SELECT withdrawn_at IS NOT NULL AS withdrawn, content_revision
                FROM im_v2.messages WHERE message_id = \(bind: messageUUID)
                """).first(decoding: ContentReviewRedactionAssertionRow.self))
            let job = try #require(try await sql.raw("""
                SELECT state, decision FROM im_v2.content_review_jobs WHERE message_id = \(bind: messageUUID)
                """).first(decoding: ContentReviewCompletionAssertionRow.self))
            #expect(redacted.withdrawn)
            #expect(redacted.revision == 2)
            #expect(job.state == "completed")
            #expect(job.decision == "violation")
            #expect(try await count("im_v2.content_review_decisions", on: sql) == 1)
            #expect(try await count("im_v2.content_review_findings", on: sql) == 1)
            #expect(try await count("im_v2.moderation_operations", on: sql) == 1)
            #expect(try await count("im_v2.moderation_audit_entries", on: sql) == 1)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("multi-forward batches source reads and bounds target-room concurrency without reordering results")
    func multiForwardUsesBoundedTargetLanesAndStableResultOrder() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1),
                as: .psql,
                isDefault: true
            )
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists")
                .first(decoding: ExistsRow.self))?.exists == false
            else {
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
            let messageLimits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let sender = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: app.db(.psql)),
                capacityProfile: profile,
                limits: messageLimits,
                now: { now }
            )
            let sourceClientIDs = try [
                ClientMessageID("00000000-0000-0000-0000-00000000f101"),
                ClientMessageID("00000000-0000-0000-0000-00000000f102")
            ]
            var sourceMessages: [V2AcceptedMessage] = []
            for (index, clientID) in sourceClientIDs.enumerated() {
                guard case .accepted(let message) = try await sender.send(.init(
                    roomID: roomID,
                    actorUserID: senderID,
                    clientMessageID: clientID,
                    text: "source-\(index + 1)"
                )) else {
                    Issue.record("expected source message acceptance")
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                sourceMessages.append(message)
            }

            let targetRoomUUIDs = [
                UUID(uuidString: "00000000-0000-0000-0000-00000000f201")!,
                UUID(uuidString: "00000000-0000-0000-0000-00000000f202")!,
                UUID(uuidString: "00000000-0000-0000-0000-00000000f203")!,
                UUID(uuidString: "00000000-0000-0000-0000-00000000f204")!
            ]
            for (index, targetRoomUUID) in targetRoomUUIDs.enumerated() {
                try await sql.raw("""
                    INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id)
                    VALUES (\(bind: targetRoomUUID), \(bind: "forward-target-\(index)"), 'standard')
                    """).run()
            }
            let targetRooms = try targetRoomUUIDs.map { try RoomID($0.uuidString) }
            let writeStore = BoundedForwardRoomWriteStore()
            let service = V2ForwardMessagesService(
                database: app.db(.psql),
                writeStore: writeStore,
                capacityProfile: profile,
                limits: messageLimits,
                maximumTargetConcurrency: 2,
                now: { now }
            )
            let command = try V2ForwardMessagesCommand(
                operationID: .init("00000000-0000-0000-0000-00000000f301"),
                sourceMessageIDs: sourceMessages.map(\.messageID),
                targetRoomIDs: targetRooms
            )

            let results = try await service.forward(actorUserID: senderID, command: command)
            let observation = await writeStore.observation()
            let expectedPairs = command.sourceMessageIDs.flatMap { sourceMessageID in
                targetRooms.map { (sourceMessageID, $0) }
            }

            #expect(observation.maximumConcurrentAccepts == 2)
            #expect(observation.textsByRoom.count == targetRooms.count)
            #expect(observation.textsByRoom.values.allSatisfy { $0 == ["source-1", "source-2"] })
            #expect(results.count == expectedPairs.count)
            for (result, expected) in zip(results, expectedPairs) {
                #expect(result.sourceMessageID == expected.0)
                #expect(result.targetRoomID == expected.1)
                #expect(result.errorCode == "UNAVAILABLE")
            }
            #expect(try await count("im_v2.message_forward_operations", on: sql) == 8)

            // Simulate the exact crash window between normal message commit
            // and recording result_message_id. A retry must recover from the
            // durable target client ID before inspecting a now-withdrawn
            // source, and it must not call the target write path again.
            let replayOperation = UUID(uuidString: "00000000-0000-0000-0000-00000000f401")!
            let replayTargetRoom = UUID(uuidString: "00000000-0000-0000-0000-00000000f402")!
            let replayClientMessage = UUID(uuidString: "00000000-0000-0000-0000-00000000f403")!
            let replayMessage = UUID(uuidString: "00000000-0000-0000-0000-00000000f404")!
            let sourceMessage = try #require(UUID(uuidString: sourceMessages[0].messageID.rawValue))
            try await sql.raw("""
                INSERT INTO im_v2.rooms
                    (room_id, room_shard_id, capacity_profile_id,
                     room_sequence, timeline_sequence)
                VALUES (\(bind: replayTargetRoom), 'forward-replay-target', 'standard', 1, 1)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.messages
                    (message_id, room_id, room_sequence, timeline_sequence,
                     sender_user_id, client_message_id, text_body, rich_entities,
                     forwarded_from_message_id, forwarded_from_user_id, created_at)
                VALUES (\(bind: replayMessage), \(bind: replayTargetRoom), 1, 1,
                        \(bind: senderUUID), \(bind: replayClientMessage), 'source-1',
                        '[]'::jsonb, \(bind: sourceMessage), \(bind: senderUUID), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.message_forward_operations
                    (actor_user_id, operation_id, source_message_id, target_room_id,
                     target_client_message_id, result_message_id, created_at)
                VALUES (\(bind: senderUUID), \(bind: replayOperation), \(bind: sourceMessage),
                        \(bind: replayTargetRoom), \(bind: replayClientMessage), NULL, \(bind: now))
                """).run()
            try await sql.raw("""
                UPDATE im_v2.messages
                SET withdrawn_at = \(bind: now), withdrawn_by_user_id = \(bind: senderUUID)
                WHERE message_id = \(bind: sourceMessage)
                """).run()
            let recoverablePair = try #require(try await sql.raw("""
                SELECT COUNT(*) AS value
                FROM im_v2.message_forward_operations AS operation
                JOIN im_v2.messages AS message
                  ON message.sender_user_id = operation.actor_user_id
                 AND message.client_message_id = operation.target_client_message_id
                WHERE operation.actor_user_id = \(bind: senderUUID)
                  AND operation.operation_id = \(bind: replayOperation)
                  AND operation.source_message_id = \(bind: sourceMessage)
                  AND operation.target_room_id = \(bind: replayTargetRoom)
                  AND operation.result_message_id IS NULL
                """).first(decoding: CountRow.self))
            #expect(recoverablePair.value == 1)
            let replayStore = BoundedForwardRoomWriteStore()
            let replayService = V2ForwardMessagesService(
                database: app.db(.psql), writeStore: replayStore,
                capacityProfile: profile, limits: messageLimits, now: { now }
            )
            let replayCommand = try V2ForwardMessagesCommand(
                operationID: .init(replayOperation.uuidString),
                sourceMessageIDs: [sourceMessages[0].messageID],
                targetRoomIDs: [.init(replayTargetRoom.uuidString)]
            )
            let replayResults = try await replayService.forward(
                actorUserID: senderID, command: replayCommand
            )
            #expect(replayResults.count == 1)
            #expect(replayResults.first?.sourceMessageID == sourceMessages[0].messageID)
            #expect(replayResults.first?.targetRoomID == (try RoomID(replayTargetRoom.uuidString)))
            #expect(replayResults.first?.messageID == (try MessageID(replayMessage.uuidString)))
            #expect(replayResults.first?.roomSequence == 1)
            #expect(replayResults.first?.errorCode == nil)
            #expect(await replayStore.observation().textsByRoom.isEmpty)
            let repairedResult = try #require(try await sql.raw("""
                SELECT COUNT(*) AS value FROM im_v2.message_forward_operations
                WHERE actor_user_id = \(bind: senderUUID)
                  AND operation_id = \(bind: replayOperation)
                  AND result_message_id = \(bind: replayMessage)
                """).first(decoding: CountRow.self))
            #expect(repairedResult.value == 1)

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

    @Test("a 100k hybrid group creation commits one atomic membership and bootstrap fan-out plan")
    func createsOneHundredThousandMemberHybridRoomAtomically() async throws {
        guard Environment.get("IMV2_RUN_HYBRID_100K_GROUP_CREATE") == "1",
              let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let startedAt = Date()
        let app = try await Application.make(.testing)
        do {
            app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = app.db(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            let schemaElapsed = v2LocalElapsedMilliseconds(since: startedAt)

            let owner = try UserID("00000000-0000-0000-0000-000000000001")
            let operationID = try GroupRoomOperationID("00000000-0000-0000-0000-00000000c001")
            let lease = UUID(uuidString: "00000000-0000-0000-0000-00000000c002")!
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until,
                     command_window_limit, fanout_window_limit, max_outstanding_fanout_units, max_outstanding_plans)
                VALUES ('hybrid-create-100k', 'hybrid-create-100k', \(bind: lease), 1, \(bind: now.addingTimeInterval(600)),
                        100_000, 100_000, 100_000, 100_000)
                """).run()
            let profileLimits = try RoomCapacityProfile(
                maxEligibleMembers: 100_000,
                maxCommandsPerWindow: 100_000,
                maxFanoutUnitsPerWindow: 100_000,
                maxOutstandingFanoutUnits: 100_000,
                maxOutstandingPlans: 100_000,
                maxEnumerationPageSize: 1_000,
                maxPlannerConcurrency: 1,
                maxDeliveryConcurrency: 1,
                retryAfterSeconds: 1
            )
            let ownerUUID = try #require(UUID(uuidString: owner.rawValue))
            let operationUUID = try #require(UUID(uuidString: operationID.rawValue))
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, revision, created_at, updated_at)
                SELECT ('00000000-0000-0000-0000-' || lpad(to_hex(value), 12, '0'))::uuid,
                       'member' || lpad(value::text, 6, '0'),
                       '成员 ' || value::text,
                       1, \(bind: now), \(bind: now)
                FROM generate_series(1, 100000) AS value
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.group_room_creation_drafts
                    (actor_user_id, operation_id, title, state, created_at, updated_at, expires_at)
                VALUES (\(bind: ownerUUID), \(bind: operationUUID), '十万人混合群创建回归',
                        'finalizing', \(bind: now), \(bind: now), \(bind: now.addingTimeInterval(600)))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.group_room_creation_draft_members
                    (actor_user_id, operation_id, user_id)
                SELECT \(bind: ownerUUID), \(bind: operationUUID),
                       ('00000000-0000-0000-0000-' || lpad(to_hex(value), 12, '0'))::uuid
                FROM generate_series(2, 100000) AS value
                """).run()
            let service = try V2GroupMessagingService(
                store: PostgresV2GroupMessagingStore(database: app.db(.psql)),
                capacityProfile: .init(id: "hybrid-create-100k", limits: profileLimits),
                roomShardID: "hybrid-create-100k",
                identifiers: .init(makeUUID: { UUID() }),
                now: { now }
            )

            let creationStartedAt = Date()
            guard case .created(let group) = try await service.createStaged(
                actorUserID: owner,
                operationID: operationID,
                title: "十万人混合群创建回归",
                stagedMemberCount: 99_999
            ) else {
                Issue.record("expected the 100k hybrid group to be created")
                return
            }
            let creationElapsed = v2LocalElapsedMilliseconds(since: creationStartedAt)
            let room = UUID(uuidString: group.roomID.rawValue)!
            let accounting = try #require(try await sql.raw("""
                SELECT
                    (SELECT COUNT(*) FROM im_v2.room_memberships WHERE room_id = \(bind: room)) AS member_count,
                    (SELECT COUNT(*) FROM im_v2.fanout_plan_targets AS target
                     JOIN im_v2.room_events AS event ON event.event_id = target.source_event_id
                     WHERE event.room_id = \(bind: room)) AS target_count,
                    (SELECT delivery_mode FROM im_v2.rooms WHERE room_id = \(bind: room)) AS delivery_mode,
                    (SELECT state FROM im_v2.fanout_plans WHERE room_id = \(bind: room)) AS plan_state,
                    (SELECT COUNT(*) FROM im_v2.group_room_operations WHERE actor_user_id = \(bind: ownerUUID) AND operation_id = \(bind: operationUUID)) AS operation_count,
                    (SELECT audience_kind FROM im_v2.group_room_operations WHERE actor_user_id = \(bind: ownerUUID) AND operation_id = \(bind: operationUUID)) AS audience_kind,
                    (SELECT initial_member_count FROM im_v2.group_room_operations WHERE actor_user_id = \(bind: ownerUUID) AND operation_id = \(bind: operationUUID)) AS operation_member_count,
                    (SELECT cardinality(initial_member_user_ids) FROM im_v2.group_room_operations WHERE actor_user_id = \(bind: ownerUUID) AND operation_id = \(bind: operationUUID)) AS materialized_operation_member_count
                """).first(decoding: GroupCreateScaleAccountingRow.self))

            #expect(group.deliveryMode == .largeGroupHybrid)
            #expect(group.memberCount == 100_000)
            #expect(group.memberUserIDs == [owner])
            #expect(accounting.memberCount == 100_000)
            #expect(accounting.targetCount == 100_000)
            #expect(accounting.deliveryMode == V2GroupDeliveryMode.largeGroupHybrid.rawValue)
            #expect(accounting.planState == "planning")
            #expect(accounting.operationCount == 1)
            #expect(accounting.audienceKind == "staged")
            #expect(accounting.operationMemberCount == 100_000)
            #expect(accounting.materializedOperationMemberCount == 0)
            print("V2_LOCAL_HYBRID_100K_GROUP_CREATE_TIMING total_wall_ms=\(v2LocalElapsedMilliseconds(since: startedAt)) schema_ms=\(schemaElapsed) create_ms=\(creationElapsed) members=\(accounting.memberCount) bootstrap_fanout_targets=\(accounting.targetCount)")

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("an expired presence lease must reacquire the global connection budget")
    func expiredPresenceLeaseCannotResurrectPastTheConnectionLimit() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
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
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let user = UUID(uuidString: "00000000-0000-0000-0000-0000000008c1")!
            let device = UUID(uuidString: "00000000-0000-0000-0000-0000000008c2")!
            try await sql.raw("""
                INSERT INTO im_v2.auth_devices
                    (user_id, device_id, created_at, last_active_at)
                VALUES (\(bind: user), \(bind: device), \(bind: now), \(bind: now))
                """).run()
            let identity = try V2AuthenticatedConnection(
                userID: .init(user.uuidString),
                deviceID: .init(device.uuidString),
                capabilityProfile: "base"
            )
            let firstConnection = UUID(uuidString: "00000000-0000-0000-0000-0000000008c3")!
            let replacementConnection = UUID(uuidString: "00000000-0000-0000-0000-0000000008c4")!
            let policy = V2AuthenticatedConnectionAdmissionPolicy(
                maximumConnectionsPerDevice: 1,
                maximumConnectionsPerUser: 1
            )
            let store = PostgresV2LiveActivityStore(database: app.db(.psql), onlineLease: 10)

            #expect(try await store.admitConnection(
                identity: identity,
                connectionID: firstConnection,
                policy: policy,
                now: now
            ) == .accepted(expiresAt: now.addingTimeInterval(10)))
            #expect(try await store.renewConnection(
                identity: identity,
                connectionID: firstConnection,
                now: now.addingTimeInterval(1)
            ) == .accepted(expiresAt: now.addingTimeInterval(11)))

            let afterExpiry = now.addingTimeInterval(12)
            #expect(try await store.renewConnection(
                identity: identity,
                connectionID: firstConnection,
                now: afterExpiry
            ) == .rejected)
            #expect(try await store.admitConnection(
                identity: identity,
                connectionID: replacementConnection,
                policy: policy,
                now: afterExpiry
            ) == .accepted(expiresAt: afterExpiry.addingTimeInterval(10)))
            #expect(try await store.admitConnection(
                identity: identity,
                connectionID: firstConnection,
                policy: policy,
                now: afterExpiry
            ) == .rejected)
            #expect(try await store.removePresence(
                identity: identity,
                connectionID: firstConnection,
                now: afterExpiry
            ))
            #expect(try await count("im_v2.user_live_presence_leases", on: sql) == 1)
            #expect(try await sql.raw("""
                SELECT EXISTS (
                    SELECT 1 FROM im_v2.user_live_presence_leases
                    WHERE connection_id = \(bind: replacementConnection)
                ) AS exists
                """).first(decoding: ExistsRow.self)?.exists == true)

            #expect(try await !store.removePresence(
                identity: identity,
                connectionID: replacementConnection,
                now: afterExpiry
            ))
            #expect(try await count("im_v2.user_live_presence_leases", on: sql) == 0)

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

    @Test("bounded housekeeping expires capabilities, recovers stale reset fences, and keeps ACK position")
    func boundedHousekeepingRecoversExpiredSyncReset() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
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
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let user = UUID(uuidString: "00000000-0000-0000-0000-0000000008a1")!
            let device = UUID(uuidString: "00000000-0000-0000-0000-0000000008a2")!
            let snapshot = UUID(uuidString: "00000000-0000-0000-0000-0000000008a3")!
            try await sql.raw("""
                INSERT INTO im_v2.device_sync_cursors
                    (user_id, device_id, state, reset_generation, acknowledged_sequence,
                     pending_snapshot_id, pending_base_sequence, pending_snapshot_expires_at)
                VALUES (\(bind: user), \(bind: device), 'reset_pending', 2, 7,
                        \(bind: snapshot), 9, \(bind: now.addingTimeInterval(-1)))
                """).run()
            let digest = String(repeating: "a", count: 64)
            try await sql.raw("""
                INSERT INTO im_v2.sync_snapshot_artifacts
                    (snapshot_id, user_id, base_user_sync_sequence, source_projected_sequence,
                     schema_version, capability_profile, state, next_page_index,
                     rolling_digest, root_digest, page_count, item_count, total_bytes,
                     expires_at, created_at, published_at)
                VALUES (\(bind: snapshot), \(bind: user), 9, 9, 30, 'test', 'published', 1,
                        \(bind: digest), \(bind: digest), 1, 1, 3,
                        \(bind: now.addingTimeInterval(-1)), \(bind: now.addingTimeInterval(-60)),
                        \(bind: now.addingTimeInterval(-30)))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.sync_snapshot_pages
                    (snapshot_id, page_index, first_projection_kind, first_entity_key,
                     last_projection_kind, last_entity_key, item_count, page_digest,
                     payload, byte_count)
                VALUES (\(bind: snapshot), 0, 'message', 'one', 'message', 'one', 1,
                        \(bind: digest), \(bind: Data([1, 2, 3])), 3)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.device_snapshot_resets
                    (user_id, device_id, reset_generation, snapshot_id, state,
                     next_sync_token, snapshot_receipt, expires_at, created_at)
                VALUES (\(bind: user), \(bind: device), 2, \(bind: snapshot), 'ready',
                        'snapshot-token', 'snapshot-receipt',
                        \(bind: now.addingTimeInterval(-1)), \(bind: now.addingTimeInterval(-60)))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.sync_tokens
                    (token, user_id, device_id, reset_generation, watermark, expires_at, created_at)
                VALUES
                    ('expired-token', \(bind: user), \(bind: device), 2, 7, \(bind: now.addingTimeInterval(-1)), \(bind: now.addingTimeInterval(-60))),
                    ('live-token', \(bind: user), \(bind: device), 2, 7, \(bind: now.addingTimeInterval(60)), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.sync_receipts
                    (receipt, user_id, device_id, reset_generation, first_sequence, last_sequence, expires_at, created_at)
                VALUES
                    ('expired-receipt', \(bind: user), \(bind: device), 2, 7, 7, \(bind: now.addingTimeInterval(-1)), \(bind: now.addingTimeInterval(-60))),
                    ('live-receipt', \(bind: user), \(bind: device), 2, 7, 7, \(bind: now.addingTimeInterval(60)), \(bind: now))
                """).run()
            let report = try await V2SyncHousekeepingWorker(
                store: PostgresV2SyncHousekeepingStore(database: app.db(.psql)),
                now: { now }
            ).runOnce(limit: 8)
            #expect(report == .init(expiredTokenCount: 1, expiredReceiptCount: 1, recoveredResetCount: 1, purgedSnapshotCount: 1))
            let cursor = try #require(try await sql.raw("""
                SELECT state, acknowledged_sequence, pending_snapshot_id
                FROM im_v2.device_sync_cursors
                WHERE user_id = \(bind: user) AND device_id = \(bind: device)
                """).first(decoding: HousekeepingCursorAssertionRow.self))
            #expect(cursor.state == "ready")
            #expect(cursor.acknowledgedSequence == 7)
            #expect(cursor.pendingSnapshotID == nil)
            let recoveredGeneration = try #require(try await sql.raw("""
                SELECT reset_generation AS value FROM im_v2.device_sync_cursors
                WHERE user_id = \(bind: user) AND device_id = \(bind: device)
                """).first(decoding: CountRow.self))
            #expect(recoveredGeneration.value == 1)
            #expect(try await count("im_v2.sync_snapshot_artifacts", on: sql) == 0)
            #expect(try await count("im_v2.sync_snapshot_pages", on: sql) == 0)
            #expect(try await count("im_v2.device_snapshot_resets", on: sql) == 0)
            #expect(try await count("im_v2.sync_tokens", on: sql) == 1)
            #expect(try await count("im_v2.sync_receipts", on: sql) == 1)

            // Revoked devices can never authenticate again. Their live
            // capability rows must not pin compaction or make cursor storage
            // grow with account history.
            let revokedDevice = UUID(uuidString: "00000000-0000-0000-0000-0000000008a4")!
            try await sql.raw("""
                INSERT INTO im_v2.auth_devices
                    (user_id, device_id, revoked_at, created_at, last_active_at)
                VALUES (\(bind: user), \(bind: revokedDevice), \(bind: now),
                        \(bind: now.addingTimeInterval(-60)), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.device_sync_cursors
                    (user_id, device_id, state, reset_generation, acknowledged_sequence)
                VALUES (\(bind: user), \(bind: revokedDevice), 'ready', 1, 3)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.sync_tokens
                    (token, user_id, device_id, reset_generation, watermark,
                     expires_at, created_at)
                VALUES ('revoked-live-token', \(bind: user), \(bind: revokedDevice),
                        1, 3, \(bind: now.addingTimeInterval(600)), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.sync_receipts
                    (receipt, user_id, device_id, reset_generation,
                     first_sequence, last_sequence, expires_at, created_at)
                VALUES ('revoked-live-receipt', \(bind: user), \(bind: revokedDevice),
                        1, 3, 3, \(bind: now.addingTimeInterval(600)), \(bind: now))
                """).run()
            try await V2PostgresRevokedDeviceProjectionStore(
                database: app.db(.psql)
            ).clean(
                userID: .init(user.uuidString),
                deviceID: .init(revokedDevice.uuidString),
                revokedAt: now
            )
            #expect(try await sql.raw("""
                SELECT COUNT(*) AS value FROM im_v2.device_sync_cursors
                WHERE user_id = \(bind: user) AND device_id = \(bind: revokedDevice)
                """).first(decoding: CountRow.self)?.value == 0)
            #expect(try await sql.raw("""
                SELECT COUNT(*) AS value FROM im_v2.sync_tokens
                WHERE user_id = \(bind: user) AND device_id = \(bind: revokedDevice)
                """).first(decoding: CountRow.self)?.value == 0)
            #expect(try await sql.raw("""
                SELECT COUNT(*) AS value FROM im_v2.sync_receipts
                WHERE user_id = \(bind: user) AND device_id = \(bind: revokedDevice)
                """).first(decoding: CountRow.self)?.value == 0)
            #expect(try await sql.raw("""
                SELECT COUNT(*) AS value
                FROM im_v2.revoked_device_projection_tombstones
                WHERE user_id = \(bind: user) AND device_id = \(bind: revokedDevice)
                """).first(decoding: CountRow.self)?.value == 1)

            // Stable projection effects are compacted only after their
            // incremental log row is gone and no shard-migration fence can
            // still copy the idempotency result.
            let projectionEvent = UUID(uuidString: "00000000-0000-0000-0000-0000000008a5")!
            let projectionOld = now.addingTimeInterval(-40 * 86_400)
            try await sql.raw("""
                INSERT INTO im_v2.user_projection_checkpoints
                    (user_id, projected_sequence, migration_fence_token,
                     migration_fence_expires_at, updated_at)
                VALUES (\(bind: user), 1, \(bind: UUID()),
                        \(bind: now.addingTimeInterval(60)), \(bind: now))
                ON CONFLICT (user_id) DO UPDATE
                SET projected_sequence = 1,
                    migration_fence_token = EXCLUDED.migration_fence_token,
                    migration_fence_expires_at = EXCLUDED.migration_fence_expires_at,
                    updated_at = EXCLUDED.updated_at
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.user_projection_versions
                    (user_id, projection_kind, entity_key, valid_from_sequence,
                     source_event_id, payload, created_at)
                VALUES (\(bind: user), 'conversation_state', 'housekeeping-room', 1,
                        \(bind: projectionEvent), '{}'::jsonb, \(bind: projectionOld))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.user_projection_effects
                    (user_id, source_event_id, projection_kind,
                     user_sync_sequence, payload, created_at)
                VALUES (\(bind: user), \(bind: projectionEvent), 'conversation_state',
                        1, '{}'::jsonb, \(bind: projectionOld))
                """).run()
            let fencedEffectReport = try await V2SyncHousekeepingWorker(
                store: PostgresV2SyncHousekeepingStore(database: app.db(.psql)),
                now: { now }
            ).runOnce(limit: 8)
            #expect(fencedEffectReport.purgedProjectionEffectCount == 0)
            try await sql.raw("""
                UPDATE im_v2.user_projection_checkpoints
                SET migration_fence_token = NULL, migration_fence_expires_at = NULL
                WHERE user_id = \(bind: user)
                """).run()
            let effectReport = try await V2SyncHousekeepingWorker(
                store: PostgresV2SyncHousekeepingStore(database: app.db(.psql)),
                now: { now }
            ).runOnce(limit: 8)
            #expect(effectReport.purgedProjectionEffectCount == 1)
            #expect(try await count("im_v2.user_projection_effects", on: sql) == 0)
            #expect(try await count("im_v2.user_projection_versions", on: sql) == 1)

            // One old terminal fan-out is dismantled leaf-first in the same
            // bounded pass while its authoritative room event is retained.
            try await seedRoom(on: sql)
            let event = UUID(uuidString: "00000000-0000-0000-0000-0000000008b1")!
            let plan = UUID(uuidString: "00000000-0000-0000-0000-0000000008b2")!
            let unit = UUID(uuidString: "00000000-0000-0000-0000-0000000008b3")!
            let old = now.addingTimeInterval(-8 * 86_400)
            try await sql.raw("""
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id,
                     payload, committed_membership_revision, created_at)
                VALUES (\(bind: event), \(bind: roomUUID), 1, 'housekeeping.test',
                        \(bind: senderUUID), '{}'::jsonb, 0, \(bind: old))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.fanout_plans
                    (plan_id, source_event_id, room_id, source_room_sequence,
                     committed_membership_revision, target_rule, enumeration_checkpoint,
                     target_count, reserved_fanout_cost, state, created_at, terminal_at)
                VALUES (\(bind: plan), \(bind: event), \(bind: roomUUID), 1, 0,
                        '{}'::jsonb, '{}'::jsonb, 1, 1, 'terminal', \(bind: old), \(bind: old))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.fanout_plan_targets (source_event_id, target_user_id)
                VALUES (\(bind: event), \(bind: senderUUID))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.fanout_completion_units
                    (source_event_id, completion_unit_id, target_boundary, target_count,
                     committed_target_count, state, released_at)
                VALUES (\(bind: event), \(bind: unit), '{}'::jsonb, 1, 1, 'released', \(bind: old))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.fanout_deliveries
                    (source_event_id, target_user_id, projection_kind, completion_unit_id,
                     target_shard_bucket, observed_router_epoch, state)
                VALUES (\(bind: event), \(bind: senderUUID), 'message', \(bind: unit),
                        'test-users', 1, 'terminal')
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.consumer_inbox
                    (consumer_name, source_event_id, target_user_id, projection_kind, committed_at)
                VALUES ('v2-fanout-delivery', \(bind: event), \(bind: senderUUID), 'message', \(bind: old))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_outbox
                    (source_event_id, plan_id, state, created_at, terminal_at)
                VALUES (\(bind: event), \(bind: plan), 'terminal', \(bind: old), \(bind: old))
                """).run()
            #expect(try await sql.raw("""
                SELECT to_regclass('im_v2.room_outbox_terminal_cleanup_idx') IS NOT NULL AS exists
                """).first(decoding: ExistsRow.self)?.exists == true)
            try await sql.raw("SET enable_seqscan = off").run()
            let cleanupPlanRows = try await sql.raw("""
                EXPLAIN (COSTS OFF)
                SELECT source_event_id
                FROM im_v2.room_outbox
                WHERE state = 'terminal' AND terminal_at <= \(bind: now)
                ORDER BY terminal_at, source_event_id
                LIMIT 8
                FOR UPDATE SKIP LOCKED
                """).all()
            try await sql.raw("RESET enable_seqscan").run()
            let cleanupPlan = try cleanupPlanRows.map {
                try $0.decode(column: "QUERY PLAN", as: String.self)
            }.joined(separator: "\n")
            #expect(cleanupPlan.contains("room_outbox_terminal_cleanup_idx"))

            let veryOld = now.addingTimeInterval(-40 * 86_400)
            let directOperation = UUID(uuidString: "00000000-0000-0000-0000-0000000008b4")!
            try await sql.raw("""
                INSERT INTO im_v2.direct_room_operations
                    (actor_user_id, operation_id, target_user_id, room_id, created_at)
                VALUES (\(bind: senderUUID), \(bind: directOperation),
                        \(bind: memberTwoUUID), \(bind: roomUUID), \(bind: veryOld))
                """).run()
            let staleConnection = UUID(uuidString: "00000000-0000-0000-0000-0000000008b5")!
            try await sql.raw("""
                INSERT INTO im_v2.user_live_presence_leases
                    (connection_id, user_id, device_id, expires_at, updated_at)
                VALUES (\(bind: staleConnection), \(bind: user), \(bind: revokedDevice),
                        \(bind: now.addingTimeInterval(-1)), \(bind: veryOld))
                """).run()
            let credentialOperation = UUID(uuidString: "00000000-0000-0000-0000-0000000008b6")!
            try await sql.raw("""
                INSERT INTO im_v2.device_credential_operations
                    (device_id, operation_id, operation_kind, user_id,
                     resulting_access_token_hmac, encrypted_access_token,
                     encrypted_refresh_credential, access_token_expires_at,
                     replay_expires_at, created_at)
                VALUES (\(bind: revokedDevice), \(bind: credentialOperation), 'refresh',
                        \(bind: user), \(bind: String(repeating: "a", count: 64)),
                        'encrypted-access', 'encrypted-refresh',
                        \(bind: now.addingTimeInterval(-2)),
                        \(bind: now.addingTimeInterval(-1)), \(bind: veryOld))
                """).run()

            let controlReport = try await V2ControlPlaneHousekeepingWorker(
                store: PostgresV2ControlPlaneHousekeepingStore(database: app.db(.psql)),
                now: { now }
            ).runOnce(limit: 256)
            #expect(controlReport.deletedRows == 9)
            #expect(controlReport.deletedRows <= 256)
            #expect(controlReport.purgedIdempotencyRows == 1)
            #expect(controlReport.purgedExpiredConnectionLeaseRows == 1)
            #expect(controlReport.purgedExpiredCredentialReplayRows == 1)
            #expect(try await count("im_v2.fanout_plans", on: sql) == 0)
            #expect(try await count("im_v2.room_outbox", on: sql) == 0)
            #expect(try await count("im_v2.fanout_deliveries", on: sql) == 0)
            #expect(try await count("im_v2.consumer_inbox", on: sql) == 0)
            #expect(try await count("im_v2.room_events", on: sql) == 1)
            #expect(try await count("im_v2.direct_room_operations", on: sql) == 0)
            #expect(try await count("im_v2.user_live_presence_leases", on: sql) == 0)
            #expect(try await count("im_v2.device_credential_operations", on: sql) == 0)

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

    @Test("message projection backfill deduplicates recipients and compacts only after verification")
    func messageProjectionBackfillAndGC() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1),
                as: .psql,
                isDefault: true
            )
            guard let sql = app.db(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists")
                .first(decoding: ExistsRow.self)?.exists == false
            else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let originEventID = UUID(uuidString: "00000000-0000-0000-0000-000000000f01")!
            let roomID = try RoomID("00000000-0000-0000-0000-000000000f02")
            let messageID = try MessageID("00000000-0000-0000-0000-000000000f03")
            let userA = UUID(uuidString: "00000000-0000-0000-0000-000000000f04")!
            let userB = UUID(uuidString: "00000000-0000-0000-0000-000000000f05")!
            let accepted = V2AcceptedMessage(
                messageID: messageID,
                roomID: roomID,
                roomSequence: 1,
                senderUserID: try .init(userA.uuidString),
                clientMessageID: try .init("00000000-0000-0000-0000-000000000f06"),
                text: "hello shared state",
                mediaPresentations: [],
                createdAt: now
            )
            let state = try V2MessageProjectionState(
                accepted: accepted,
                forwardedFromMessageID: nil,
                forwardedFromUserID: nil
            )
            let payloadJSON = try state.encodedPayloadJSON()
            let messageUUID = UUID(uuidString: messageID.rawValue)!
            let roomUUID = UUID(uuidString: roomID.rawValue)!
            try await sql.raw("""
                INSERT INTO im_v2.user_projection_versions
                    (user_id, projection_kind, entity_key, scope_room_id,
                     valid_from_sequence, source_event_id, payload, created_at)
                VALUES
                    (\(bind: userA), 'message', \(bind: messageID.rawValue),
                     \(bind: roomUUID), 1, \(bind: originEventID),
                     \(bind: payloadJSON)::jsonb, \(bind: now)),
                    (\(bind: userB), 'message', \(bind: messageID.rawValue),
                     \(bind: roomUUID), 1, \(bind: originEventID),
                     \(bind: payloadJSON)::jsonb, \(bind: now))
                """).run()

            let dual = PostgresV2MessageProjectionBackfillWorker(
                database: app.db(.psql), compactInlinePayloads: false
            )
            #expect(try await dual.runOnce(now: now, limit: 10) == .init(
                linkedRowCount: 2, compactedRowCount: 0
            ))
            #expect(try await count("im_v2.message_projection_states", on: sql) == 1)
            let referenceCount = try #require(try await sql.raw("""
                SELECT COUNT(*) AS value
                FROM im_v2.user_projection_versions
                WHERE message_state_id IS NOT NULL AND payload IS NOT NULL
                """).first(decoding: CountRow.self))
            #expect(referenceCount.value == 2)

            let stored = try #require(
                try await PostgresV2MessageProjectionStateRepository()
                    .load(messageID: messageUUID, revision: 1, sql: sql)
            )
            let conflict = V2StoredMessageProjectionState(
                stateID: stored.stateID,
                messageID: stored.messageID,
                roomID: stored.roomID,
                messageRevision: stored.messageRevision,
                variantKey: stored.variantKey,
                originEventID: stored.originEventID,
                stateEventID: stored.stateEventID,
                isWithdrawn: stored.isWithdrawn,
                payloadSchemaVersion: stored.payloadSchemaVersion,
                payloadJSON: stored.payloadJSON.replacingOccurrences(
                    of: "hello shared state", with: "tampered state"
                ),
                createdAt: stored.createdAt
            )
            await #expect(throws: V2MessageProjectionStatePersistenceError.conflictingState) {
                try await PostgresV2MessageProjectionStateRepository()
                    .persist(conflict, sql: sql)
            }

            let shared = PostgresV2MessageProjectionBackfillWorker(
                database: app.db(.psql), compactInlinePayloads: true
            )
            #expect(try await shared.runOnce(now: now, limit: 10) == .init(
                linkedRowCount: 0, compactedRowCount: 2
            ))
            let narrowCount = try #require(try await sql.raw("""
                SELECT COUNT(*) AS value
                FROM im_v2.user_projection_versions
                WHERE message_state_id = \(bind: stored.stateID) AND payload IS NULL
                """).first(decoding: CountRow.self))
            #expect(narrowCount.value == 2)

            // Strict shared reads must emit the identical wire payload even
            // after the per-user JSON has been removed.
            let snapshotID = UUID(uuidString: "00000000-0000-0000-0000-000000000f07")!
            let capabilityProfile = "shared-state-test"
            let initialDigest = V2SnapshotV3Digest.initial(
                baseSequence: 1,
                capabilityProfile: capabilityProfile
            )
            try await sql.raw("""
                INSERT INTO im_v2.user_projection_checkpoints
                    (user_id, projected_sequence, updated_at)
                VALUES (\(bind: userA), 1, \(bind: now))
                ON CONFLICT (user_id) DO UPDATE
                SET projected_sequence = EXCLUDED.projected_sequence,
                    updated_at = EXCLUDED.updated_at
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.sync_snapshot_artifacts
                    (snapshot_id, user_id, base_user_sync_sequence,
                     source_projected_sequence, schema_version,
                     capability_profile, state, rolling_digest,
                     expires_at, created_at)
                VALUES
                    (\(bind: snapshotID), \(bind: userA), 1, 1, 31,
                     \(bind: capabilityProfile), 'building', \(bind: initialDigest),
                     \(bind: now.addingTimeInterval(600)), \(bind: now))
                """).run()
            let builder = PostgresV2SnapshotArtifactBuilder(
                database: app.db(.psql),
                messageReadMode: .shared
            )
            #expect(try await builder.runOnce(now: now) == .init(
                claimed: true, published: false, pageCount: 1, itemCount: 1
            ))
            #expect(try await builder.runOnce(now: now) == .init(
                claimed: true, published: true, pageCount: 1, itemCount: 1
            ))
            let snapshotPayload = try #require(try await sql.raw("""
                SELECT payload
                FROM im_v2.sync_snapshot_pages
                WHERE snapshot_id = \(bind: snapshotID) AND page_index = 0
                """).first(decoding: MessageProjectionSnapshotPageRow.self))
            let snapshotPage = try V2SnapshotProjectionV3Codec.decode(snapshotPayload.payload)
            #expect(snapshotPage.items.first?.payload == Data(stored.payloadJSON.utf8))

            let gc = PostgresV2MessageProjectionStateGCWorker(
                database: app.db(.psql), retention: 1
            )
            #expect(try await gc.runOnce(now: now.addingTimeInterval(2), limit: 10) == 0)
            try await sql.raw("DELETE FROM im_v2.user_projection_versions").run()
            #expect(try await gc.runOnce(now: now.addingTimeInterval(2), limit: 10) == 1)
            #expect(try await count("im_v2.message_projection_states", on: sql) == 0)

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
        let schemaURL = repositoryRoot.appending(path: "IMV2/sql/schema.sql")
        let source = try String(contentsOf: schemaURL, encoding: .utf8)
            .replacingOccurrences(of: "im_v2", with: schema)
        let executableSQL = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
            .joined(separator: "\n")
        for statement in postgresStatements(in: executableSQL) {
            guard !statement.isEmpty, statement != "BEGIN", statement != "COMMIT" else { continue }
            try await sql.raw("\(unsafeRaw: statement)").run()
        }
        try await configureDefaultUserShardRoute(
            .init(bucket: "test-users", observedRouterEpoch: 9),
            now: Date(timeIntervalSince1970: 0),
            on: sql,
            schema: schema
        )
    }

    private func configureDefaultUserShardRoute(
        _ route: V2UserShardRoute,
        now: Date,
        on sql: any SQLDatabase,
        schema: String = "im_v2"
    ) async throws {
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).user_shard_router_configuration
                (configuration_key, router_epoch, default_write_bucket,
                 default_read_fallback_bucket, updated_at)
            VALUES
                (TRUE, \(bind: route.observedRouterEpoch), \(bind: route.bucket),
                 \(bind: route.readFallbackBucket), \(bind: now))
            ON CONFLICT (configuration_key) DO UPDATE
            SET router_epoch = EXCLUDED.router_epoch,
                default_write_bucket = EXCLUDED.default_write_bucket,
                default_read_fallback_bucket = EXCLUDED.default_read_fallback_bucket,
                updated_at = EXCLUDED.updated_at
            """).run()
    }

    private func drainV3Projection(database: any Database) async throws {
        let worker = PostgresV2UserProjectionWorker(database: database, batchSize: 1_000)
        while try await worker.runOnce().claimed {
            try Task.checkCancellation()
        }
    }

    private func currentV3ProjectionItems(
        sql: any SQLDatabase,
        userID: UserID,
        kind: String
    ) async throws -> [CurrentV3ProjectionAssertionRow] {
        guard let userUUID = UUID(uuidString: userID.rawValue) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return try await sql.raw("""
            SELECT version.entity_key,
                   COALESCE(state.payload, version.payload)::text AS payload_json
            FROM im_v2.user_projection_versions AS version
            LEFT JOIN im_v2.message_projection_state_values AS state
              ON state.state_id = version.message_state_id
            WHERE version.user_id = \(bind: userUUID)
              AND version.projection_kind = \(bind: kind)
              AND version.valid_to_sequence IS NULL
            ORDER BY version.entity_key
            """).all(decoding: CurrentV3ProjectionAssertionRow.self)
    }

    private func seedTransferProjection(
        schema: String, user: UUID, device: UUID, eventOne: UUID, eventTwo: UUID,
        snapshot: UUID, now: Date, on sql: any SQLDatabase
    ) async throws {
        let revokedDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000cff")!
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).revoked_device_projection_tombstones
                (user_id, device_id, revoked_at)
            VALUES (\(bind: user), \(bind: revokedDevice), \(bind: now))
            """).run()
        try await sql.raw("INSERT INTO \(unsafeRaw: schema).user_sync_sequences (user_id, next_sequence) VALUES (\(bind: user), 2)").run()
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).user_sync_log
                (user_id, user_sync_sequence, source_event_id, projection_kind, payload, payload_storage, created_at)
            VALUES (\(bind: user), 1, \(bind: eventOne), 'message', '{"body":"one"}'::jsonb, 'inline', \(bind: now)),
                   (\(bind: user), 2, \(bind: eventTwo), 'message', NULL, 'fanout_shared', \(bind: now))
            """).run()
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).fanout_sync_payloads
                (source_event_id, projection_kind, payload, created_at)
            VALUES (\(bind: eventTwo), 'message', '{"body":"two"}'::jsonb, \(bind: now))
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
            INSERT INTO \(unsafeRaw: schema).user_projection_versions
                (user_id, projection_kind, entity_key, valid_from_sequence,
                 source_event_id, payload, created_at)
            VALUES
                (\(bind: user), 'message', \(bind: eventOne.uuidString.lowercased()), 1,
                 \(bind: eventOne), \(bind: "{\"message_id\":\"\(eventOne.uuidString.lowercased())\",\"text\":\"one\"}")::jsonb, \(bind: now)),
                (\(bind: user), 'message', \(bind: eventTwo.uuidString.lowercased()), 2,
                 \(bind: eventTwo), \(bind: "{\"message_id\":\"\(eventTwo.uuidString.lowercased())\",\"text\":\"two\"}")::jsonb, \(bind: now))
            """).run()
        try await sql.raw("""
            UPDATE \(unsafeRaw: schema).user_projection_checkpoints
            SET projected_sequence = 2, updated_at = \(bind: now)
            WHERE user_id = \(bind: user)
            """).run()
        let digest = String(repeating: "b", count: 64)
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).sync_snapshot_artifacts
                (snapshot_id, user_id, base_user_sync_sequence, source_projected_sequence,
                 schema_version, capability_profile, state, next_page_index,
                 rolling_digest, root_digest, page_count, item_count, total_bytes,
                 expires_at, created_at, published_at)
            VALUES (\(bind: snapshot), \(bind: user), 1, 2, 31, 'base', 'published', 1,
                    \(bind: digest), \(bind: digest), 1, 1, 2,
                    \(bind: now.addingTimeInterval(600)), \(bind: now), \(bind: now))
            """).run()
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).sync_snapshot_pages
                (snapshot_id, page_index, first_projection_kind, first_entity_key,
                 last_projection_kind, last_entity_key, item_count, page_digest,
                 payload, byte_count)
            VALUES (\(bind: snapshot), 0, 'message', \(bind: eventOne.uuidString.lowercased()),
                    'message', \(bind: eventOne.uuidString.lowercased()), 1,
                    \(bind: digest), '\\x0102'::bytea, 2)
            """).run()
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).device_snapshot_resets
                (user_id, device_id, reset_generation, snapshot_id, state,
                 next_sync_token, snapshot_receipt, expires_at, created_at, acknowledged_at)
            VALUES (\(bind: user), \(bind: device), 2, \(bind: snapshot), 'acknowledged',
                    'token-snapshot', 'receipt-snapshot',
                    \(bind: now.addingTimeInterval(600)), \(bind: now), \(bind: now))
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
        let seededAt = Date(timeIntervalSince1970: 1_750_000_000)
        try await sql.raw("""
            INSERT INTO im_v2.public_user_profiles
                (user_id, public_handle, display_name, revision, created_at, updated_at)
            VALUES
                (\(bind: senderUUID), 'sender012', '发送者', 1, \(bind: seededAt), \(bind: seededAt)),
                (\(bind: memberTwoUUID), 'member015', '成员二', 1, \(bind: seededAt), \(bind: seededAt)),
                (\(bind: memberThreeUUID), 'member016', '成员三', 1, \(bind: seededAt), \(bind: seededAt))
            """).run()
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

    private func directWriteArtifactCounts(
        sql: any SQLDatabase
    ) async throws -> DirectWriteArtifactCounts {
        try #require(try await sql.raw("""
            SELECT
                (SELECT COUNT(*)::bigint FROM im_v2.messages) AS messages,
                (SELECT COUNT(*)::bigint FROM im_v2.room_events) AS events,
                (SELECT COUNT(*)::bigint FROM im_v2.message_projection_states) AS message_states,
                (SELECT COUNT(*)::bigint FROM im_v2.fanout_plans) AS plans,
                (SELECT COUNT(*)::bigint FROM im_v2.room_outbox) AS outbox_rows,
                (SELECT COUNT(*)::bigint FROM im_v2.fanout_completion_units) AS completion_units,
                (SELECT COUNT(*)::bigint FROM im_v2.fanout_deliveries) AS deliveries
            """).first(decoding: DirectWriteArtifactCounts.self))
    }
}

private actor BoundedForwardRoomWriteStore: V2RoomWriteStore {
    struct Observation: Sendable {
        let maximumConcurrentAccepts: Int
        let textsByRoom: [RoomID: [String]]
    }

    private var concurrentAccepts = 0
    private var maximumConcurrentAccepts = 0
    private var textsByRoom: [RoomID: [String]] = [:]

    func accept(
        command: V2SendMessageCommand,
        capacityProfile _: V2CapacityProfile,
        identifiers _: V2AcceptanceIdentifiers,
        now _: Date
    ) async throws -> V2SendMessageOutcome {
        concurrentAccepts += 1
        maximumConcurrentAccepts = max(maximumConcurrentAccepts, concurrentAccepts)
        textsByRoom[command.roomID, default: []].append(command.text)
        defer { concurrentAccepts -= 1 }
        try await Task.sleep(for: .milliseconds(20))
        return .unavailable(.missingShardLease)
    }

    func observation() -> Observation {
        .init(
            maximumConcurrentAccepts: maximumConcurrentAccepts,
            textsByRoom: textsByRoom
        )
    }
}

/// Test schema installation must handle PostgreSQL function bodies as a
/// single statement. A plain `split(separator: ";")` breaks `$$` blocks and
/// can mask bootstrap failures before a database-backed regression starts.
private func drainFanoutCompletionReleases(
    database: any Database,
    now: @escaping @Sendable () -> Date = Date.init,
    batchSize: Int = 1_024
) async throws -> V2FanoutCompletionReleaseReport {
    precondition(batchSize > 0)
    let worker = V2FanoutCompletionReleaseWorker(
        store: PostgresV2FanoutDeliveryStore(database: database),
        now: now
    )
    var released = 0
    var closedPlans = 0
    while true {
        let report = try await worker.runOnce(limit: batchSize)
        released += report.releasedCount
        closedPlans += report.closedPlanCount
        if report.releasedCount < batchSize { break }
    }
    return .init(releasedCount: released, closedPlanCount: closedPlans)
}

private func postgresStatements(in source: String) -> [String] {
    var statements: [String] = []
    var buffer = ""
    var dollarQuote: String?
    var index = source.startIndex
    while index < source.endIndex {
        let character = source[index]
        if character == "$" {
            let remainder = source[index...]
            if let closing = remainder.dropFirst().firstIndex(of: "$") {
                let tag = String(remainder[...closing])
                let isDollarTag = tag.dropFirst().dropLast().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
                if isDollarTag && (dollarQuote == nil || dollarQuote == tag) {
                    dollarQuote = dollarQuote == nil ? tag : nil
                    buffer.append(contentsOf: tag)
                    index = source.index(after: closing)
                    continue
                }
            }
        }
        if character == ";", dollarQuote == nil {
            let statement = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !statement.isEmpty { statements.append(statement) }
            buffer = ""
        } else {
            buffer.append(character)
        }
        index = source.index(after: index)
    }
    let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty { statements.append(tail) }
    return statements
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
private struct ConcurrentRoomWriteAcceptanceResult: Sendable {
    let outcome: V2SendMessageOutcome
    let elapsedSeconds: TimeInterval
}

private struct V2LocalFanoutDeliverySoakWorkerTiming: Sendable {
    let report: V2FanoutDeliveryReport
    let elapsedMilliseconds: Int
    let claimedBatches: Int
    let emptyBatches: Int
}

/// Coordinates the four test workers by durable commits rather than by a
/// fixed number of empty polls. This keeps the measured delivery wall time
/// comparable when the lease-claim budget changes.
private actor V2LocalFanoutDrainTracker {
    private let expectedCommitCount: Int
    private var committedCount = 0

    init(expectedCommitCount: Int) {
        precondition(expectedCommitCount > 0)
        self.expectedCommitCount = expectedCommitCount
    }

    var isComplete: Bool { committedCount == expectedCommitCount }

    func record(committedCount additionalCount: Int) -> Bool {
        precondition(additionalCount >= 0)
        committedCount += additionalCount
        precondition(committedCount <= expectedCommitCount)
        return isComplete
    }
}

/// One privacy-safe, machine-readable summary for the opt-in 100k drain.
/// It contains only aggregate stage duration and worker distribution facts;
/// no room, source event, target user or payload reaches test output.
private struct V2LocalFanoutDeliverySoakTiming {
    let commitBatchSize: Int
    let deliveryClaimBatchSize: Int
    let plannerPageSize: Int
    let synchronousCommit: String
    let injectedFirstProjectionBatchFailure: Bool
    let totalElapsedMilliseconds: Int
    let schemaElapsedMilliseconds: Int
    let seedElapsedMilliseconds: Int
    let planningElapsedMilliseconds: Int
    let deliveryElapsedMilliseconds: Int
    let verificationElapsedMilliseconds: Int
    let workerTimings: [V2LocalFanoutDeliverySoakWorkerTiming]

    var machineReadableLine: String {
        let workers = workerTimings.sorted { $0.elapsedMilliseconds < $1.elapsedMilliseconds }
        return "V2_LOCAL_100K_DELIVERY_TIMING " +
            "commit_batch_size=\(commitBatchSize) " +
            "delivery_claim_batch_size=\(deliveryClaimBatchSize) " +
            "planner_page_size=\(plannerPageSize) " +
            "synchronous_commit=\(synchronousCommit) " +
            "injected_first_projection_batch_failure=\(injectedFirstProjectionBatchFailure) " +
            "total_wall_ms=\(totalElapsedMilliseconds) " +
            "schema_ms=\(schemaElapsedMilliseconds) " +
            "seed_ms=\(seedElapsedMilliseconds) " +
            "planning_ms=\(planningElapsedMilliseconds) " +
            "delivery_wall_ms=\(deliveryElapsedMilliseconds) " +
            "verification_ms=\(verificationElapsedMilliseconds) " +
            "worker_elapsed_ms=\(workers.map(\.elapsedMilliseconds).map(String.init).joined(separator: ",")) " +
            "worker_claimed_batches=\(workers.map(\.claimedBatches).map(String.init).joined(separator: ",")) " +
            "worker_empty_batches=\(workers.map(\.emptyBatches).map(String.init).joined(separator: ",")) " +
            "worker_committed=\(workers.map(\.report.committedCount).map(String.init).joined(separator: ","))"
    }
}

/// Test-only aggregation for the cross-store ceiling profile. The production
/// store exposes only anonymous batch durations; this actor turns them into a
/// single machine-readable line without collecting room, event, user or
/// payload data.
private actor V2LocalCrossStoreFanoutTimingRecorder: V2CrossStoreFanoutDeliveryTimingRecording {
    private var timings: [V2CrossStoreFanoutBatchTiming] = []

    func record(_ timing: V2CrossStoreFanoutBatchTiming) {
        timings.append(timing)
    }

    func summary() -> V2LocalCrossStoreFanoutTimingSummary {
        .init(timings: timings)
    }
}

private struct V2LocalCrossStoreFanoutTimingSummary {
    let batchCount: Int
    let targetCount: Int
    let migrationReadMilliseconds: Int
    let targetProjectionMilliseconds: Int
    let controlCompletionMilliseconds: Int
    let batchWallMilliseconds: Int
    let targetProjectionMaximumMilliseconds: Int
    let controlCompletionMaximumMilliseconds: Int

    init(timings: [V2CrossStoreFanoutBatchTiming]) {
        batchCount = timings.count
        targetCount = timings.reduce(0) { $0 + $1.targetCount }
        migrationReadMilliseconds = timings.reduce(0) { $0 + $1.migrationReadMilliseconds }
        targetProjectionMilliseconds = timings.reduce(0) { $0 + $1.targetProjectionMilliseconds }
        controlCompletionMilliseconds = timings.reduce(0) { $0 + $1.controlCompletionMilliseconds }
        batchWallMilliseconds = timings.reduce(0) { $0 + $1.totalMilliseconds }
        targetProjectionMaximumMilliseconds = timings.map(\.targetProjectionMilliseconds).max() ?? 0
        controlCompletionMaximumMilliseconds = timings.map(\.controlCompletionMilliseconds).max() ?? 0
    }

    var machineReadableFields: String {
        "cross_store_batches=\(batchCount) " +
            "cross_store_targets=\(targetCount) " +
            "cross_store_migration_read_ms_sum=\(migrationReadMilliseconds) " +
            "cross_store_target_projection_ms_sum=\(targetProjectionMilliseconds) " +
            "cross_store_target_projection_ms_max=\(targetProjectionMaximumMilliseconds) " +
            "cross_store_control_completion_ms_sum=\(controlCompletionMilliseconds) " +
            "cross_store_control_completion_ms_max=\(controlCompletionMaximumMilliseconds) " +
            "cross_store_batch_wall_ms_sum=\(batchWallMilliseconds)"
    }
}

private func v2LocalElapsedMilliseconds(since startedAt: Date, now: Date = Date()) -> Int {
    max(0, Int((now.timeIntervalSince(startedAt) * 1_000).rounded()))
}

/// A compact local workload summary. Nearest-rank percentiles deliberately
/// avoid interpolation: this is a small 16-sample regression report, not a
/// statistically significant production latency distribution.
private struct V2LocalLatencySummary {
    let p50Milliseconds: Int
    let p95Milliseconds: Int
    let p99Milliseconds: Int

    init(samples: [TimeInterval]) {
        precondition(!samples.isEmpty)
        let sorted = samples.sorted()
        p50Milliseconds = Self.milliseconds(Self.nearestRank(sorted, percentile: 0.50))
        p95Milliseconds = Self.milliseconds(Self.nearestRank(sorted, percentile: 0.95))
        p99Milliseconds = Self.milliseconds(Self.nearestRank(sorted, percentile: 0.99))
    }

    private static func nearestRank(_ sorted: [TimeInterval], percentile: Double) -> TimeInterval {
        let index = max(0, min(sorted.count - 1, Int(ceil(percentile * Double(sorted.count))) - 1))
        return sorted[index]
    }

    private static func milliseconds(_ value: TimeInterval) -> Int {
        Int((value * 1_000).rounded())
    }
}

/// Deliberately broad local regression limits for the isolated Docker
/// baseline. They catch order-of-magnitude regressions while remaining
/// overrideable on a differently provisioned local machine; they are never a
/// production SLO or admission policy.
private struct V2LocalCapacityRegressionLimits {
    let maximumAcceptanceP99Milliseconds: Int
    let maximumPipelineWallMilliseconds: Int

    init() throws {
        maximumAcceptanceP99Milliseconds = try Self.read(
            "IMV2_LOCAL_CAPACITY_MAX_ACCEPTANCE_P99_MS", defaultValue: 250
        )
        maximumPipelineWallMilliseconds = try Self.read(
            "IMV2_LOCAL_CAPACITY_MAX_PIPELINE_WALL_MS", defaultValue: 60_000
        )
    }

    private static func read(_ name: String, defaultValue: Int) throws -> Int {
        guard let raw = Environment.get(name) else { return defaultValue }
        guard let value = Int(raw), value > 0 else {
            throw TestConfigurationError.invalidLocalCapacityLimit(name)
        }
        return value
    }
}

/// Bounded shape controls for the opt-in concurrent-room capacity regression.
/// A standard group is intentionally capped at 5,000 members by the product
/// design, so a local test must not silently exercise a different delivery
/// mode by accepting a larger value here. The default remains the fast 16k
/// projection smoke workload; the 5,000-member case is explicitly opt-in.
private struct V2ConcurrentRoomWorkloadConfiguration {
    let messageCount: Int
    let memberCount: Int
    let plannerPageSize: Int
    let deliveryClaimBatchSize: Int
    let deliveryWorkerCount: Int
    /// Test-only body size used to measure the cost of copying an immutable
    /// event payload into each recipient's durable sync log. Zero keeps the
    /// ordinary short-message workload.
    let eventPayloadBytes: Int
    let forceGenericProjectionSequenceReservation: Bool

    init() throws {
        messageCount = try Self.read(
            "IMV2_CONCURRENT_ROOM_MESSAGE_COUNT", defaultValue: 16, range: 1...64
        )
        memberCount = try Self.read(
            "IMV2_CONCURRENT_ROOM_MEMBER_COUNT", defaultValue: 1_000, range: 1...5_000
        )
        plannerPageSize = try Self.read(
            "IMV2_CONCURRENT_ROOM_PLANNER_PAGE_SIZE", defaultValue: 1_000, range: 1...5_000
        )
        deliveryClaimBatchSize = try Self.read(
            "IMV2_CONCURRENT_ROOM_DELIVERY_CLAIM_BATCH_SIZE", defaultValue: 2_000, range: 1...2_000
        )
        deliveryWorkerCount = try Self.read(
            "IMV2_CONCURRENT_ROOM_DELIVERY_WORKER_COUNT", defaultValue: 4, range: 1...16
        )
        eventPayloadBytes = try Self.read(
            "IMV2_CONCURRENT_ROOM_EVENT_PAYLOAD_BYTES", defaultValue: 0, range: 0...16_384
        )
        forceGenericProjectionSequenceReservation = Environment.get("IMV2_FORCE_GENERIC_PROJECTION_SEQUENCE_RESERVATION") == "1"
    }

    private static func read(_ name: String, defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = Environment.get(name) else { return defaultValue }
        guard let value = Int(raw), range.contains(value) else {
            throw TestConfigurationError.invalidConcurrentRoomWorkloadValue(name)
        }
        return value
    }
}

/// Produces deterministic printable ASCII with low repetition, so a payload
/// profile measures the stored event-copy path rather than benefiting from an
/// artificial all-zero string's compression ratio. This is test-only and
/// never accepts a payload from an environment variable directly.
private func v2ConcurrentRoomMessageText(index: Int, payloadBytes: Int) -> String {
    guard payloadBytes > 0 else { return "burst-\(index)" }
    var state = UInt64(index) &+ 1
    var bytes: [UInt8] = []
    bytes.reserveCapacity(payloadBytes)
    for _ in 0..<payloadBytes {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        bytes.append(33 + UInt8(truncatingIfNeeded: state >> 57) % 94)
    }
    // The generated range is printable ASCII, so this conversion cannot fail.
    return String(bytes: bytes, encoding: .ascii)!
}

/// Optional PostgreSQL attribution for the concurrent-room regression. It is
/// deliberately a test-only diagnostic: production code neither requires the
/// extension nor has permission to reset its shared statement statistics.
///
/// Enable it only with the local `capacity-profile` compose overlay and
/// `IMV2_CAPTURE_POSTGRES_DELIVERY_PROFILE=1`. The output uses stable
/// categories rather than SQL text, keeping it both privacy-safe and easy to
/// compare between local runs.
private struct V2LocalPostgresDeliveryProfile {
    private let databaseCounters: V2LocalPostgresDatabaseCounters
    private let walCounters: V2LocalPostgresWALCounters

    static func startIfEnabled(on sql: any SQLDatabase) async throws -> Self? {
        guard Environment.get("IMV2_CAPTURE_POSTGRES_DELIVERY_PROFILE") == "1" else { return nil }
        try await sql.raw("CREATE EXTENSION IF NOT EXISTS pg_stat_statements").run()
        try await sql.raw("SELECT pg_stat_statements_reset()").run()
        // PostgreSQL accumulates database and WAL counters asynchronously.
        // Force a snapshot only in this disposable profiling mode so a
        // database-wide WAL delta can be compared meaningfully with the
        // statement-level WAL attribution below.
        try await sql.raw("SELECT pg_stat_force_next_flush()").run()
        // Statistics views cache a snapshot per backend. Clear it explicitly
        // after the forced collector flush.
        try await sql.raw("SELECT pg_stat_clear_snapshot()").run()
        guard let databaseCounters = try await sql.raw("""
            SELECT xact_commit::bigint AS xact_commit,
                   xact_rollback::bigint AS xact_rollback,
                   temp_bytes::bigint AS temp_bytes,
                   blk_read_time AS blk_read_time,
                   blk_write_time AS blk_write_time
            FROM pg_stat_database
            WHERE datname = current_database()
            """).first(decoding: V2LocalPostgresDatabaseCounters.self),
              let walCounters = try await sql.raw("""
            SELECT wal_records::bigint AS wal_records,
                   wal_fpi::bigint AS wal_fpi,
                   wal_bytes::bigint AS wal_bytes,
                   pg_current_wal_lsn()::text AS wal_lsn
            FROM pg_stat_wal
            """).first(decoding: V2LocalPostgresWALCounters.self)
        else {
            throw TestConfigurationError.postgresProfileUnavailable
        }
        return .init(databaseCounters: databaseCounters, walCounters: walCounters)
    }

    func finish(on sql: any SQLDatabase) async throws -> V2LocalPostgresDeliveryProfileReport {
        try await sql.raw("SELECT pg_stat_force_next_flush()").run()
        try await sql.raw("SELECT pg_stat_clear_snapshot()").run()
        guard let databaseAfter = try await sql.raw("""
            SELECT xact_commit::bigint AS xact_commit,
                   xact_rollback::bigint AS xact_rollback,
                   temp_bytes::bigint AS temp_bytes,
                   blk_read_time AS blk_read_time,
                   blk_write_time AS blk_write_time
            FROM pg_stat_database
            WHERE datname = current_database()
            """).first(decoding: V2LocalPostgresDatabaseCounters.self),
              let walAfter = try await sql.raw("""
            SELECT wal_records::bigint AS wal_records,
                   wal_fpi::bigint AS wal_fpi,
                   wal_bytes::bigint AS wal_bytes,
                   pg_current_wal_lsn()::text AS wal_lsn
            FROM pg_stat_wal
            """).first(decoding: V2LocalPostgresWALCounters.self)
        else {
            throw TestConfigurationError.postgresProfileUnavailable
        }
        let walLSNDelta = try #require(try await sql.raw("""
            SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), \(bind: walCounters.walLSN)::pg_lsn)::bigint AS value
            """).first(decoding: CountRow.self)).value
        let statements = try await sql.raw("""
            WITH classified AS (
                SELECT CASE
                    WHEN query LIKE '%jsonb_to_recordset%' AND query LIKE '%consumer_inbox%' THEN 'projection_cte'
                    WHEN query LIKE '%fanout_deliveries%' AND query LIKE '%FOR UPDATE SKIP LOCKED%' THEN 'delivery_claim'
                    WHEN query LIKE '%jsonb_array_elements_text%' AND query LIKE '%user_shard_migrations%' THEN 'migration_batch_read'
                    WHEN query LIKE '%event_payload_json%' AND query LIKE '%fanout_deliveries%' THEN 'projection_input_batch_read'
                    WHEN query LIKE '%UPDATE im_v2.fanout_completion_units%' THEN 'completion_counter'
                    WHEN query LIKE '%UPDATE im_v2.room_admission%' THEN 'terminal_release'
                    WHEN query LIKE '%routed_members%' THEN 'planner_cte'
                    WHEN query LIKE '%INSERT INTO im_v2.messages%' THEN 'acceptance'
                    WHEN query LIKE '%FOR KEY SHARE%' THEN 'foreign_key_checks'
                    ELSE 'other_im_v2'
                END AS category,
                calls, total_exec_time, rows, shared_blks_hit, shared_blks_read,
                shared_blks_dirtied, shared_blks_written, temp_blks_read,
                temp_blks_written, wal_bytes
                FROM pg_stat_statements
                WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
                  AND query LIKE '%im_v2%'
            )
            SELECT category,
                   SUM(calls)::bigint AS calls,
                   SUM(total_exec_time)::double precision AS total_exec_ms,
                   (SUM(total_exec_time) / NULLIF(SUM(calls), 0))::double precision AS mean_exec_ms,
                   SUM(rows)::bigint AS rows,
                   SUM(shared_blks_hit)::bigint AS shared_blks_hit,
                   SUM(shared_blks_read)::bigint AS shared_blks_read,
                   SUM(shared_blks_dirtied)::bigint AS shared_blks_dirtied,
                   SUM(shared_blks_written)::bigint AS shared_blks_written,
                   SUM(temp_blks_read)::bigint AS temp_blks_read,
                   SUM(temp_blks_written)::bigint AS temp_blks_written,
                   SUM(wal_bytes)::bigint AS wal_bytes
            FROM classified
            GROUP BY category
            ORDER BY total_exec_ms DESC, category
            """).all(decoding: V2LocalPostgresStatementProfile.self)
        return .init(
            databaseDelta: databaseAfter.subtracting(databaseCounters),
            walDelta: walAfter.subtracting(walCounters),
            walLSNDeltaBytes: walLSNDelta,
            durableEffects: try await V2LocalPostgresDurableEffectCounts.capture(on: sql),
            statements: statements
        )
    }
}

private struct V2LocalPostgresDeliveryProfileReport {
    let databaseDelta: V2LocalPostgresDatabaseCounters
    let walDelta: V2LocalPostgresWALCounters
    let walLSNDeltaBytes: Int64
    let durableEffects: V2LocalPostgresDurableEffectCounts
    let statements: [V2LocalPostgresStatementProfile]

    func machineReadableLines(scope: String = "DELIVERY") -> [String] {
        let counters = "V2_LOCAL_POSTGRES_\(scope)_COUNTERS " +
            "xact_commit=\(databaseDelta.xactCommit) " +
            "xact_rollback=\(databaseDelta.xactRollback) " +
            "temp_bytes=\(databaseDelta.tempBytes) " +
            "blk_read_ms=\(databaseDelta.blkReadMilliseconds) " +
            "blk_write_ms=\(databaseDelta.blkWriteMilliseconds) " +
            "wal_records=\(walDelta.walRecords) " +
            "wal_fpi=\(walDelta.walFPI) " +
            "wal_bytes=\(walDelta.walBytes) " +
            "wal_lsn_bytes=\(walLSNDeltaBytes)"
        let effects = "V2_LOCAL_POSTGRES_\(scope)_EFFECTS " +
            "inbox_rows=\(durableEffects.inboxRows) " +
            "sync_log_rows=\(durableEffects.syncLogRows) " +
            "shared_payload_rows=\(durableEffects.sharedPayloadRows) " +
            "sequence_rows=\(durableEffects.sequenceRows) " +
            "sequence_advances=\(durableEffects.sequenceAdvances) " +
            "delivery_rows=\(durableEffects.deliveryRows) " +
            "delivery_claim_attempts=\(durableEffects.deliveryClaimAttempts) " +
            "terminal_deliveries=\(durableEffects.terminalDeliveries) " +
            "completion_units=\(durableEffects.completionUnits) " +
            "released_completion_units=\(durableEffects.releasedCompletionUnits)"
        return [counters, effects] + statements.map { statement in
            "V2_LOCAL_POSTGRES_\(scope)_SQL " +
                "category=\(statement.category) " +
                "calls=\(statement.calls) " +
                "total_exec_ms=\(statement.totalExecMilliseconds) " +
                "mean_exec_ms=\(statement.meanExecMilliseconds) " +
                "rows=\(statement.rows) " +
                "shared_hit=\(statement.sharedBlocksHit) " +
                "shared_read=\(statement.sharedBlocksRead) " +
                "shared_dirtied=\(statement.sharedBlocksDirtied) " +
                "shared_written=\(statement.sharedBlocksWritten) " +
                "temp_read=\(statement.tempBlocksRead) " +
                "temp_written=\(statement.tempBlocksWritten) " +
                "wal_bytes=\(statement.walBytes)"
        }
    }
}

/// Exact durable effect counts, read from the workload's verified state. They
/// intentionally replace `pg_stat_user_tables.n_tup_*` here: those counters
/// are eventually consistent across pooled backends and can lag a completed
/// concurrent run, while these values are the actual rows and increments the
/// delivery contract committed before the test emits its profile.
private struct V2LocalPostgresDurableEffectCounts: Decodable {
    let inboxRows: Int64
    let syncLogRows: Int64
    let sharedPayloadRows: Int64
    let sequenceRows: Int64
    let sequenceAdvances: Int64
    let deliveryRows: Int64
    let deliveryClaimAttempts: Int64
    let terminalDeliveries: Int64
    let completionUnits: Int64
    let releasedCompletionUnits: Int64

    enum CodingKeys: String, CodingKey {
        case inboxRows = "inbox_rows"
        case syncLogRows = "sync_log_rows"
        case sharedPayloadRows = "shared_payload_rows"
        case sequenceRows = "sequence_rows"
        case sequenceAdvances = "sequence_advances"
        case deliveryRows = "delivery_rows"
        case deliveryClaimAttempts = "delivery_claim_attempts"
        case terminalDeliveries = "terminal_deliveries"
        case completionUnits = "completion_units"
        case releasedCompletionUnits = "released_completion_units"
    }

    static func capture(on sql: any SQLDatabase) async throws -> Self {
        guard let effects = try await sql.raw("""
            SELECT
                (SELECT COUNT(*)::bigint FROM im_v2.consumer_inbox) AS inbox_rows,
                (SELECT COUNT(*)::bigint FROM im_v2.user_sync_log) AS sync_log_rows,
                (SELECT COUNT(*)::bigint FROM im_v2.fanout_sync_payloads) AS shared_payload_rows,
                (SELECT COUNT(*)::bigint FROM im_v2.user_sync_sequences) AS sequence_rows,
                (SELECT COALESCE(SUM(next_sequence - 1), 0)::bigint
                   FROM im_v2.user_sync_sequences) AS sequence_advances,
                (SELECT COUNT(*)::bigint FROM im_v2.fanout_deliveries) AS delivery_rows,
                (SELECT COALESCE(SUM(retry_count), 0)::bigint
                   FROM im_v2.fanout_deliveries) AS delivery_claim_attempts,
                (SELECT COUNT(*) FILTER (WHERE state = 'terminal')::bigint
                   FROM im_v2.fanout_deliveries) AS terminal_deliveries,
                (SELECT COUNT(*)::bigint FROM im_v2.fanout_completion_units) AS completion_units,
                (SELECT COUNT(*) FILTER (WHERE state = 'released')::bigint
                   FROM im_v2.fanout_completion_units) AS released_completion_units
            """).first(decoding: Self.self)
        else { throw TestConfigurationError.postgresProfileUnavailable }
        return effects
    }
}

private struct V2LocalPostgresDatabaseCounters: Decodable {
    let xactCommit: Int64
    let xactRollback: Int64
    let tempBytes: Int64
    let blkReadTime: Double
    let blkWriteTime: Double

    enum CodingKeys: String, CodingKey {
        case xactCommit = "xact_commit"
        case xactRollback = "xact_rollback"
        case tempBytes = "temp_bytes"
        case blkReadTime = "blk_read_time"
        case blkWriteTime = "blk_write_time"
    }

    func subtracting(_ other: Self) -> Self {
        .init(
            xactCommit: xactCommit - other.xactCommit,
            xactRollback: xactRollback - other.xactRollback,
            tempBytes: tempBytes - other.tempBytes,
            blkReadTime: blkReadTime - other.blkReadTime,
            blkWriteTime: blkWriteTime - other.blkWriteTime
        )
    }

    var blkReadMilliseconds: Int { Int(blkReadTime.rounded()) }
    var blkWriteMilliseconds: Int { Int(blkWriteTime.rounded()) }
}

private struct V2LocalPostgresWALCounters: Decodable {
    let walRecords: Int64
    let walFPI: Int64
    let walBytes: Int64
    let walLSN: String

    enum CodingKeys: String, CodingKey {
        case walRecords = "wal_records"
        case walFPI = "wal_fpi"
        case walBytes = "wal_bytes"
        case walLSN = "wal_lsn"
    }

    func subtracting(_ other: Self) -> Self {
        .init(
            walRecords: walRecords - other.walRecords,
            walFPI: walFPI - other.walFPI,
            walBytes: walBytes - other.walBytes,
            walLSN: walLSN
        )
    }
}

private struct V2LocalPostgresStatementProfile: Decodable {
    let category: String
    let calls: Int64
    let totalExecMilliseconds: Double
    let meanExecMilliseconds: Double
    let rows: Int64
    let sharedBlocksHit: Int64
    let sharedBlocksRead: Int64
    let sharedBlocksDirtied: Int64
    let sharedBlocksWritten: Int64
    let tempBlocksRead: Int64
    let tempBlocksWritten: Int64
    let walBytes: Int64

    enum CodingKeys: String, CodingKey {
        case category, calls, rows
        case totalExecMilliseconds = "total_exec_ms"
        case meanExecMilliseconds = "mean_exec_ms"
        case sharedBlocksHit = "shared_blks_hit"
        case sharedBlocksRead = "shared_blks_read"
        case sharedBlocksDirtied = "shared_blks_dirtied"
        case sharedBlocksWritten = "shared_blks_written"
        case tempBlocksRead = "temp_blks_read"
        case tempBlocksWritten = "temp_blks_written"
        case walBytes = "wal_bytes"
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

private struct RouteFinalizerNoop: V2UserShardCutoverFinalizing {
    func finalizeForCutover(
        migrationID _: UUID, userID _: UserID,
        sourceBucket _: String, targetBucket _: String, sourceRouterEpoch _: Int64,
        controlTransaction _: any Database
    ) async throws {}

    func finalizeForRollback(
        migrationID _: UUID, userID _: UserID,
        sourceBucket _: String, targetBucket _: String, sourceRouterEpoch _: Int64,
        controlTransaction _: any Database
    ) async throws {}
}
private struct TransferCursorAssertionRow: Decodable {
    let acknowledgedSequence: Int64
    enum CodingKeys: String, CodingKey { case acknowledgedSequence = "acknowledged_sequence" }
}
private struct ExistsRow: Decodable { let exists: Bool }
private struct DirectRoomLockProbeRow: Decodable {
    let lastValue: Int64
    let isCalled: Bool
    enum CodingKeys: String, CodingKey {
        case lastValue = "last_value"
        case isCalled = "is_called"
    }
}
private struct StringValueRow: Decodable { let value: String }
private struct SyncPayloadEnvelopeRow: Decodable {
    let hasNullLogPayload: Bool
    let payloadStorage: String
    let hasSourceEventID: Bool
    let hasProjectionKind: Bool
    enum CodingKeys: String, CodingKey {
        case hasNullLogPayload = "has_null_log_payload"
        case payloadStorage = "payload_storage"
        case hasSourceEventID = "has_source_event_id"
        case hasProjectionKind = "has_projection_kind"
    }
}

private struct EdgeClientRateLimitKeyRow: Decodable {
    let clientKey: String
    enum CodingKeys: String, CodingKey { case clientKey = "client_key" }
}
private struct CountRow: Decodable { let value: Int64 }
private struct DirectWriteArtifactCounts: Decodable, Equatable {
    let messages: Int64
    let events: Int64
    let messageStates: Int64
    let plans: Int64
    let outboxRows: Int64
    let completionUnits: Int64
    let deliveries: Int64

    enum CodingKeys: String, CodingKey {
        case messages, events, plans, deliveries
        case messageStates = "message_states"
        case outboxRows = "outbox_rows"
        case completionUnits = "completion_units"
    }
}
private struct MessageProjectionSnapshotPageRow: Decodable { let payload: Data }
private struct DirectPairProjectionStateAssertionRow: Decodable, Equatable {
    let lowerProfileVisibleToHigher: Bool
    let higherProfileVisibleToLower: Bool
    let lowerCanSend: Bool?
    let higherCanSend: Bool?
    enum CodingKeys: String, CodingKey {
        case lowerProfileVisibleToHigher = "lower_profile_visible_to_higher"
        case higherProfileVisibleToLower = "higher_profile_visible_to_lower"
        case lowerCanSend = "lower_can_send"
        case higherCanSend = "higher_can_send"
    }
}
private struct DirectBatchProjectionSyncAssertionRow: Decodable {
    let userID: UUID
    let userSyncSequence: Int64
    let sourceEventID: UUID
    let projectionKind: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case userSyncSequence = "user_sync_sequence"
        case sourceEventID = "source_event_id"
        case projectionKind = "projection_kind"
    }
}
private struct MessageOperationCardinalityAssertionRow: Decodable, Equatable {
    let acceptedCount: Int64
    let deniedCount: Int64

    enum CodingKeys: String, CodingKey {
        case acceptedCount = "accepted_count"
        case deniedCount = "denied_count"
    }
}

private actor PostgreSQLTransactionGate {
    private var isHeld = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilHeld() async {
        guard !isHeld else { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func holdTransaction() async {
        isHeld = true
        let waiters = heldWaiters
        heldWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func releaseTransaction() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private func waitForAdvisoryWaiters(_ expected: Int64, on sql: any SQLDatabase) async throws {
    try await waitForPostgreSQLLockWaiters(expected, lockType: "advisory", on: sql)
}

private func waitForPostgreSQLLockWaiters(
    _ expected: Int64,
    lockType: String,
    on sql: any SQLDatabase
) async throws {
    for _ in 0 ..< 300 {
        let count = try await sql.raw("""
            SELECT COUNT(*)::bigint AS value
            FROM pg_locks
            WHERE locktype = \(bind: lockType) AND NOT granted
            """).first(decoding: CountRow.self)?.value ?? 0
        if count >= expected { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw TestConfigurationError.lockWaiterTimeout(lockType)
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

private struct CurrentV3ProjectionAssertionRow: Decodable, Sendable {
    let entityKey: String
    let payloadJSON: String

    enum CodingKeys: String, CodingKey {
        case entityKey = "entity_key"
        case payloadJSON = "payload_json"
    }

    func string(_ key: String) -> String? { object()[key] as? String }
    func bool(_ key: String) -> Bool? { object()[key] as? Bool }
    func arrayCount(_ key: String) -> Int? { (object()[key] as? [Any])?.count }
    func arrayString(_ key: String, index: Int, key nestedKey: String) -> String? {
        guard let values = object()[key] as? [[String: Any]], values.indices.contains(index) else { return nil }
        return values[index][nestedKey] as? String
    }

    private func object() -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) as? [String: Any] else {
            return [:]
        }
        return value
    }
}
private struct ContentReviewJobAssertionRow: Decodable {
    let state: String
    let revision: Int64
    let decision: String?
    enum CodingKeys: String, CodingKey {
        case state, decision
        case revision = "expected_content_revision"
    }
}
private struct ContentReviewLeaseFenceAssertionRow: Decodable {
    let state: String
    let hasNewToken: Bool
    let decision: String?
    enum CodingKeys: String, CodingKey {
        case state, decision
        case hasNewToken = "has_new_token"
    }
}
private struct ContentReviewResetAssertionRow: Decodable, Equatable {
    let state: String
    let revision: Int64
    let decision: String?
    let claimReleased: Bool
    let leaseReleased: Bool
    let isUncompleted: Bool

    enum CodingKeys: String, CodingKey {
        case state, decision
        case revision = "expected_content_revision"
        case claimReleased = "claim_released"
        case leaseReleased = "lease_released"
        case isUncompleted = "is_uncompleted"
    }
}
private struct ContentReviewCompletionAssertionRow: Decodable {
    let state: String
    let decision: String?
    let released: Bool?
}
private struct ContentReviewRetryAssertionRow: Decodable {
    let state: String
    let nextAttemptAt: Date?
    let pausedAt: Date?
    enum CodingKeys: String, CodingKey {
        case state
        case nextAttemptAt = "next_attempt_at"
        case pausedAt = "paused_at"
    }
}
private struct ContentReviewRedactionAssertionRow: Decodable {
    let withdrawn: Bool
    let revision: Int64
    enum CodingKeys: String, CodingKey {
        case withdrawn
        case revision = "content_revision"
    }
}
private struct FanoutTerminalLatencyRow: Decodable {
    let elapsedSeconds: TimeInterval
    enum CodingKeys: String, CodingKey { case elapsedSeconds = "elapsed_seconds" }
}
private struct HybridPlanAssertionRow: Decodable, Equatable {
    let roomSequence: Int64
    let state: String
    let targetCount: Int
    let reservedFanoutCost: Int
    enum CodingKeys: String, CodingKey {
        case roomSequence = "source_room_sequence"
        case state
        case targetCount = "target_count"
        case reservedFanoutCost = "reserved_fanout_cost"
    }
}
private struct PasswordAuthenticationAuditRow: Decodable {
    let outcome: String
    let userID: UUID?
    let deviceID: UUID
    let occurredAt: Date

    enum CodingKeys: String, CodingKey {
        case outcome
        case userID = "user_id"
        case deviceID = "device_id"
        case occurredAt = "occurred_at"
    }
}
private struct DirectProfileSyncAssertionRow: Decodable, Equatable {
    let userID: UUID
    let roomID: String
    let targetUserID: UUID
    let publicHandle: String
    let displayName: String
    let revision: Int64

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case roomID = "room_id"
        case targetUserID = "target_user_id"
        case publicHandle = "public_handle"
        case displayName = "display_name"
        case revision
    }
}
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

private struct GroupCreateScaleAccountingRow: Decodable {
    let memberCount: Int64
    let targetCount: Int64
    let deliveryMode: String
    let planState: String
    let operationCount: Int64
    let audienceKind: String
    let operationMemberCount: Int
    let materializedOperationMemberCount: Int
    enum CodingKeys: String, CodingKey {
        case memberCount = "member_count"
        case targetCount = "target_count"
        case deliveryMode = "delivery_mode"
        case planState = "plan_state"
        case operationCount = "operation_count"
        case audienceKind = "audience_kind"
        case operationMemberCount = "operation_member_count"
        case materializedOperationMemberCount = "materialized_operation_member_count"
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
private struct FanoutDeliveryRetryAccountingRow: Decodable {
    let retriedDeliveries: Int64
    let maximumRetryCount: Int64
    enum CodingKeys: String, CodingKey {
        case retriedDeliveries = "retried_deliveries"
        case maximumRetryCount = "maximum_retry_count"
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
private struct FanoutRouteAssertionRow: Decodable {
    let bucket: String
    let epoch: Int64
    enum CodingKeys: String, CodingKey {
        case bucket = "target_shard_bucket"
        case epoch = "observed_router_epoch"
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

private struct ReceiptTombstoneCountAssertionRow: Decodable {
    let value: Int
    let distinctSources: Int
    enum CodingKeys: String, CodingKey {
        case value
        case distinctSources = "distinct_sources"
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
private struct PushStateRow: Decodable { let state: String }
private struct HousekeepingCursorAssertionRow: Decodable {
    let state: String
    let acknowledgedSequence: Int64
    let pendingSnapshotID: UUID?
    enum CodingKeys: String, CodingKey {
        case state
        case acknowledgedSequence = "acknowledged_sequence"
        case pendingSnapshotID = "pending_snapshot_id"
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
private struct PushSuppressionStateRow: Decodable {
    let state: String
    let suppressionReason: String?
    enum CodingKeys: String, CodingKey { case state; case suppressionReason = "suppression_reason" }
}
private struct SyncKindRow: Decodable {
    let sequence: Int64
    let kind: String
    enum CodingKeys: String, CodingKey { case sequence = "user_sync_sequence", kind = "projection_kind" }
}
private struct PayloadLaneCountRow: Decodable, Equatable {
    let payloadLane: String
    let entryCount: Int64

    enum CodingKeys: String, CodingKey {
        case payloadLane = "payload_lane"
        case entryCount = "entry_count"
    }
}
private struct ProfilePropagationOutboxRow: Decodable {
    let state: String
    let checkpointed: Bool
}
private struct ProfilePropagationCompletedRow: Decodable {
    let state: String
    let completed: Bool
}
private struct ProfilePropagationProjectionRow: Decodable {
    let userID: UUID
    let roomID: String
    let displayName: String
    let revision: Int64
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case roomID = "room_id"
        case displayName = "display_name"
        case revision
    }
}
private struct ProfileInvalidationAssertionRow: Decodable {
    let recipientUserID: UUID
    let invalidatedUserID: UUID
    let minimumProfileRevision: Int64

    enum CodingKeys: String, CodingKey {
        case recipientUserID = "user_id"
        case invalidatedUserID = "user_id_payload"
        case minimumProfileRevision = "minimum_profile_revision"
    }
}
private struct ProjectionRecipientAssertionRow: Decodable {
    let userID: UUID
    enum CodingKeys: String, CodingKey { case userID = "user_id" }
}
private struct ProfileSuspensionInvalidationAssertionRow: Decodable {
    let recipientUserID: UUID
    let profileState: String
    let minimumProfileRevision: Int64
    enum CodingKeys: String, CodingKey {
        case recipientUserID = "user_id"
        case profileState = "profile_state"
        case minimumProfileRevision = "minimum_profile_revision"
    }
}
private struct ProfilePropagationFailingShadowForwarder: V2UserShardProjectionShadowing {
    func shadowIfForwarding(
        userID _: UserID,
        sourceEventID _: EventID,
        projectionKinds _: Set<String>
    ) async throws -> UInt64? {
        throw ProfilePropagationShadowFailure.interrupted
    }
}
private struct SuccessfulProjectionShadowForwarder: V2UserShardProjectionShadowing {
    func shadowIfForwarding(
        userID _: UserID,
        sourceEventID _: EventID,
        projectionKinds _: Set<String>
    ) async throws -> UInt64? { 1 }
}
private actor RecordingProjectionShadowForwarder: V2UserShardProjectionShadowing {
    private var requests = 0

    func shadowIfForwarding(
        userID _: UserID,
        sourceEventID _: EventID,
        projectionKinds _: Set<String>
    ) async throws -> UInt64? {
        requests += 1
        return 1
    }

    func requestCount() -> Int { requests }
}
private enum ProfilePropagationShadowFailure: Error, Equatable, Sendable { case interrupted }
private struct UnexpectedContentReviewer: V2ContentReviewing {
    func review(_: V2ContentReviewInput) async throws -> V2ContentReviewVerdict {
        throw V2ContentReviewWorkerError.dispositionNotApplied
    }
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
private struct TimelineActivityTypeAssertionRow: Decodable {
    let activityType: String
    enum CodingKeys: String, CodingKey { case activityType = "activity_type" }
}
private struct MediaReferenceAssertionRow: Decodable {
    let messageID: UUID
    let mediaID: UUID
    let ordinal: Int
    enum CodingKeys: String, CodingKey { case messageID = "message_id", mediaID = "media_id", ordinal }
}
private struct MediaEventContainsRow: Decodable { let contains: Bool }
private struct DirectMessageRowEventRow: Decodable {
    let acceptedEventID: UUID
    let acceptedEventStorage: String
    let acceptedMembershipRevision: Int64
    enum CodingKeys: String, CodingKey {
        case acceptedEventID = "accepted_event_id"
        case acceptedEventStorage = "accepted_event_storage"
        case acceptedMembershipRevision = "accepted_membership_revision"
    }
}
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
private enum TestConfigurationError: Error {
    case schemaAlreadyExists
    case invalidLocalCapacityLimit(String)
    case invalidFanoutCommitBatchSize(String)
    case invalidFanoutDeliveryClaimBatchSize(String)
    case invalidFanoutPlannerPageSize(String)
    case invalidConcurrentRoomWorkloadValue(String)
    case invalidCrossStoreDeliveryConcurrency(String)
    case invalidCrossStoreCommitBatchSize(String)
    case invalidCrossStoreBatchCommitConcurrency(String)
    case invalidCrossStoreEventPayloadBytes(String)
    case postgresProfileUnavailable
    case lockWaiterTimeout(String)
}
