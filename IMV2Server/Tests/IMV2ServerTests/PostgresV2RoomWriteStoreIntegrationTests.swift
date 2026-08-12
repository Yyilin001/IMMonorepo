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
            let nonFanoutSyncIdentityIndexExists = try #require(try await sql.raw("""
                SELECT to_regclass('im_v2.user_sync_log_nonfanout_identity_idx') IS NOT NULL AS exists
                """).first(decoding: ExistsRow.self))
            #expect(nonFanoutSyncIdentityIndexExists.exists)
            let fullSyncIdentityConstraintIsAbsent = try #require(try await sql.raw("""
                SELECT NOT EXISTS (
                    SELECT 1 FROM pg_constraint
                    WHERE conname = 'user_sync_log_user_id_source_event_id_projection_kind_key'
                      AND conrelid = 'im_v2.user_sync_log'::regclass
                ) AS exists
                """).first(decoding: ExistsRow.self))
            #expect(fullSyncIdentityConstraintIsAbsent.exists)
            // Non-fan-out writers do not acquire `consumer_inbox`, so they
            // retain the source-event semantic uniqueness that existed before
            // migration 0028.
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
            let syncedRecord = try #require(records.first)
            #expect(syncedRecord.sourceEventID.rawValue == triggerRow.sourceEventID.uuidString)
            #expect(syncedRecord.projectionKind == "message")
            let syncedMessage = try #require(try await sql.raw("""
                SELECT shared.payload->>'room_id' AS room_id, shared.payload->>'message_id' AS message_id,
                       shared.payload->>'sender_user_id' AS sender_user_id, shared.payload->>'text' AS text,
                       shared.payload->>'event_type' AS event_type
                FROM im_v2.user_sync_log AS log
                JOIN im_v2.fanout_sync_payloads AS shared
                  ON shared.source_event_id = log.source_event_id
                 AND shared.projection_kind = log.projection_kind
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
                       shared.payload ? 'source_event_id' AS has_source_event_id,
                       shared.payload ? 'projection_kind' AS has_projection_kind
                FROM im_v2.user_sync_log AS log
                JOIN im_v2.fanout_sync_payloads AS shared
                  ON shared.source_event_id = log.source_event_id
                 AND shared.projection_kind = log.projection_kind
                WHERE log.projection_kind = 'message'
                LIMIT 1
                """).first(decoding: SyncPayloadEnvelopeRow.self))
            #expect(payloadEnvelope.hasNullLogPayload)
            #expect(payloadEnvelope.payloadStorage == "fanout_shared")
            #expect(!payloadEnvelope.hasSourceEventID)
            #expect(!payloadEnvelope.hasProjectionKind)
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
            let plannerRouter = V2PostgresUserShardRouter(database: app.db(.psql))
            try await plannerRouter.bootstrap(defaultRoute: try .init(bucket: "test-users", observedRouterEpoch: 9), now: now)
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
                        database: app.db(.psql),
                        router: plannerRouter
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
                store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: plannerRouter),
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

            #expect(interrupted.state == "planning")
            #expect(interrupted.afterUserID == senderUUID.uuidString)
            #expect(interruptedCompletionUnits == 1)
            #expect(interruptedDeliveries == 1)
            #expect(prematureDelivery == .init(claimedCount: 0, committedCount: 0, staleCount: 0, releasedCount: 0))
            #expect(resumed == .init(createdCompletionUnits: 2, createdDeliveries: 2, wasAlreadyPlanned: false))
            #expect(overriddenRoute.bucket == "test-users-override")
            #expect(overriddenRoute.epoch == 10)
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
            try await sql.raw("INSERT INTO im_v2.public_user_profiles (user_id, public_handle, display_name, revision, created_at, updated_at) VALUES (\(bind: senderUUID), 'sender012', '发送者', 1, \(bind: now), \(bind: now)), (\(bind: memberTwoUUID), 'member015', '成员二', 1, \(bind: now), \(bind: now))").run()
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
            let snapshot = try await PostgresV2SnapshotProjectionMaterializer(database: app.db(.psql)).materialize(userID: senderID, now: now)
            let snapshotDirectProfiles = try snapshot.pages.flatMap { try V2SnapshotProjectionCodec.decodePage($0.payload).directRoomProfiles }
            #expect(snapshotDirectProfiles == [try .init(sourceEventID: .init(room.roomID.rawValue), roomID: room.roomID, publicIdentity: .init(userID: recipient, handle: .init("member015"), displayName: "成员二"), revision: 1, updatedAt: now)])
            // Account-owned add permissions are present in delivered history,
            // but a reset must rebuild them from their authoritative table.
            // This also proves the materializer accepts the non-message record.
            _ = try await directService.setUserAddPermission(
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000082"),
                permission: .deny
            )
            let preferenceSnapshot = try await PostgresV2SnapshotProjectionMaterializer(database: app.db(.psql)).materialize(userID: senderID, now: now)
            let userAddPreferences = try preferenceSnapshot.pages.compactMap {
                try V2SnapshotProjectionCodec.decodePage($0.payload).userAddPreference
            }
            #expect(userAddPreferences == [.init(allowsBeingAdded: false, updatedAt: now)])

            _ = try await directService.setStrangerMessagePermission(actorUserID: recipient, operationID: try .init("00000000-0000-0000-0000-000000000073"), permission: .deny)
            let writer = PostgresV2RoomWriteStore(database: app.db(.psql), strangerMessagePolicy: try .init(maximumMessagesPerWindow: 3, window: 86_400))
            let messages = V2SendMessageService(store: writer, capacityProfile: profile, limits: try .init(maxUTF8Bytes: 64), now: { now })
            await #expect(throws: V2RoomWriteStoreError.strangerMessagePermissionDenied) {
                _ = try await messages.send(.init(roomID: room.roomID, actorUserID: senderID, clientMessageID: try .init("00000000-0000-0000-0000-000000000074"), text: "blocked-by-setting"))
            }
            let deniedRecipientProfiles = try #require(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE user_id = \(bind: memberTwoUUID) AND projection_kind = 'direct_room_profile'").first(decoding: CountRow.self))
            #expect(deniedRecipientProfiles.value == 0)

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
            try await plannerRouter.bootstrap(
                defaultRoute: try .init(bucket: "test-users", observedRouterEpoch: 9),
                now: now
            )
            let planningStartedAt = Date()
            #expect(try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: plannerRouter),
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
            try await userShardRouter.bootstrap(
                defaultRoute: try .init(bucket: "test-users", observedRouterEpoch: 9),
                now: now
            )

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
                        store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: userShardRouter),
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
            #expect(relayResults.reduce(0) { $0 + $1.publishedCount } == messageCount)
            #expect(relayResults.reduce(0) { $0 + $1.pausedCount } == 0)
            #expect(await drainTracker.isComplete)
            #expect(deliveryResults.reduce(0) { $0 + $1.committedCount } == messageCount * memberCount)
            #expect(deliveryResults.reduce(0) { $0 + $1.staleCount } == 0)
            #expect(deliveryResults.reduce(0) { $0 + $1.staleRouteCount } == 0)
            #expect(deliveryResults.reduce(0) { $0 + $1.pausedCount } == 0)
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
            #expect(!(try await reviewStore.isCurrent(oldLease, now: now.addingTimeInterval(3))))
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
            let mediaReference = try #require(try await sql.raw("""
                SELECT revoked_at IS NOT NULL AS exists
                FROM im_v2.message_media_references
                WHERE message_id = \(bind: messageUUID) AND media_id = \(bind: mediaUUID)
                """).first(decoding: ExistsRow.self))
            let planning = try await V2FanoutPlanner(store: PostgresV2FanoutPlanStore(database: app.db(.psql), router: testUserShardRouter), pageSize: 2, now: { now.addingTimeInterval(3) }).plan(.init(sourceEventID: result.eventID, planID: result.fanoutPlanID))
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
            let snapshot = try await PostgresV2SnapshotProjectionMaterializer(database: app.db(.psql)).materialize(userID: senderID, now: now.addingTimeInterval(5))
            let snapshotMessages = try snapshot.pages.flatMap { try V2SnapshotProjectionCodec.decodePage($0.payload).messages }
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
            let revocationNodeID = "metrics-revocation-gateway"
            let metrics = PostgresV2DurableWorkMetricsSource(
                database: app.db(.psql),
                deliveryBucket: "test-users",
                gatewayNodeID: revocationNodeID
            )
            #expect(try await metrics.loadDurableWorkMetrics() == .init(isAvailable: true))

            let firstRevokedUser = UUID(uuidString: "00000000-0000-0000-0000-000000000711")!
            let firstRevokedDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000712")!
            let secondRevokedUser = UUID(uuidString: "00000000-0000-0000-0000-000000000713")!
            let secondRevokedDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000714")!
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at) VALUES (\(bind: firstRevokedUser), \(bind: firstRevokedDevice), \(bind: now)), (\(bind: secondRevokedUser), \(bind: secondRevokedDevice), \(bind: now))").run()
            try await sql.raw("INSERT INTO im_v2.device_revocation_events (user_id, device_id, created_at) VALUES (\(bind: firstRevokedUser), \(bind: firstRevokedDevice), \(bind: now)), (\(bind: secondRevokedUser), \(bind: secondRevokedDevice), \(bind: now))").run()
            #expect((await metrics.durableWorkMetricsSnapshot()).pendingDeviceRevocationEvents == 2)
            let revocationStore = V2PostgresDeviceRevocationEventStore(database: app.db(.psql))
            let firstRevocation = try #require(try await revocationStore.events(afterCursorFor: revocationNodeID, limit: 1).first)
            try await revocationStore.markProcessed(eventID: firstRevocation.eventID, nodeID: revocationNodeID, now: now)
            #expect((await metrics.durableWorkMetricsSnapshot()).pendingDeviceRevocationEvents == 1)

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

    @Test("device sessions list metadata and atomically revoke one remote installation")
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
            guard case .issued(let currentCredentials) = try await issuer.register(.init(userID: userID, deviceID: currentDeviceID, operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000a04")!, metadata: .init(displayName: "Current iPhone", platform: "iPhone"))),
                  case .issued(let remoteCredentials) = try await issuer.register(.init(userID: userID, deviceID: remoteDeviceID, operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000a05")!, metadata: .init(displayName: "Remote iPad", platform: "iPad")))
            else { Issue.record("expected device credentials"); return }
            let remoteUUID = try #require(UUID(uuidString: remoteDeviceID.rawValue))
            let endpointGeneration = UUID(uuidString: "00000000-0000-0000-0000-000000000a06")!
            try await sql.raw("INSERT INTO im_v2.push_device_endpoints (device_id, provider, environment, endpoint_generation, encrypted_token, updated_at) VALUES (\(bind: remoteUUID), 'apns', 'development', \(bind: endpointGeneration), 'sealed', \(bind: now))").run()

            let service = V2PostgresDeviceSessionService(database: app.db(.psql), now: { now.addingTimeInterval(1) })
            let listed = try await service.sessions(for: userID)
            #expect(listed.map(\.deviceID) == [currentDeviceID, remoteDeviceID])
            #expect(listed.map(\.displayName) == ["Current iPhone", "Remote iPad"])
            let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000a07")!
            #expect(try await service.revokeDevice(actorUserID: userID, currentDeviceID: currentDeviceID, targetDeviceID: remoteDeviceID, operationID: operationID) == .applied)
            #expect(try await service.revokeDevice(actorUserID: userID, currentDeviceID: currentDeviceID, targetDeviceID: remoteDeviceID, operationID: operationID) == .idempotent)

            let gateway = V2PostgresGatewayAuthenticator(database: app.db(.psql), tokenKey: tokenKey, now: { now.addingTimeInterval(2) })
            #expect(try await gateway.authenticate(accessToken: currentCredentials.accessToken, deviceID: currentDeviceID) == userID)
            await #expect(throws: V2GatewayAuthenticationError.unauthenticated) {
                try await gateway.authenticate(accessToken: remoteCredentials.accessToken, deviceID: remoteDeviceID)
            }
            #expect(try await count("im_v2.auth_devices WHERE revoked_at IS NULL", on: sql) == 1)
            #expect(try await count("im_v2.device_session_operations", on: sql) == 1)
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 1)
            #expect(try await count("im_v2.push_device_endpoints WHERE disabled_at IS NOT NULL", on: sql) == 1)
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
                try await gateway.authenticate(accessToken: firstCredentials.accessToken, deviceID: firstDeviceID)
            }
            await #expect(throws: V2GatewayAuthenticationError.unauthenticated) {
                try await gateway.authenticate(accessToken: secondCredentials.accessToken, deviceID: secondDeviceID)
            }
            #expect(try await issuer.register(firstRegistration) == .deviceUnavailable)
            let refresh = try V2DeviceCredentialRefresh(
                userID: userID, deviceID: firstDeviceID, refreshCredential: firstCredentials.refreshCredential,
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000998")!
            )
            #expect(try await issuer.refresh(refresh) == .terminalRejection)
            #expect(try await V2PostgresPasswordAccountStore(database: app.db(.psql)).passwordCredential(for: "account991") == nil)
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
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at) VALUES (\(bind: firstUser), \(bind: firstDevice), \(bind: occurredAt)), (\(bind: secondUser), \(bind: secondDevice), \(bind: occurredAt))").run()
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
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at) VALUES (\(bind: laterUser), \(bind: laterDevice), \(bind: occurredAt))").run()
            try await sql.raw("INSERT INTO im_v2.device_revocation_events (user_id, device_id, created_at) VALUES (\(bind: laterUser), \(bind: laterDevice), \(bind: occurredAt))").run()
            let laterPage = try await store.events(afterCursorFor: freshNodeID, limit: 8)
            #expect(laterPage.map(\.deviceID) == [try DeviceID(laterDevice.uuidString)])
            // Startup initialization must not advance an already-created
            // cursor, otherwise a duplicate node ID could skip live work.
            try await store.initializeCursorIfNeeded(nodeID: freshNodeID, now: occurredAt)
            #expect(try await store.events(afterCursorFor: freshNodeID, limit: 8).map(\.eventID) == laterPage.map(\.eventID))

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
            #expect(try await count("\(targetSchema).fanout_sync_payloads", on: sql) == 1)
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
            let crossStore = V2CrossStoreFanoutDeliveryStore(
                control: control, registry: registry, migrations: migrations
            )
            #expect(crossStore.maximumConcurrentClaimsPerBucket == 1)
            let coLocatedCrossStore = V2CrossStoreFanoutDeliveryStore(
                control: control, registry: registry, migrations: migrations,
                coLocatedControlBucket: "users-source"
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
                database: location.database, schema: location.schema
            ).project(input, now: now.addingTimeInterval(2))
            try await control.release(abandoned)

            let report = try await V2FanoutDeliveryWorker(
                store: crossStore,
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
            let trigger = try V2FanoutPlanTrigger(sourceEventID: .init(event.uuidString), planID: .init(plan.uuidString))
            let planningStartedAt = Date()
            #expect(try await V2FanoutPlanner(
                store: PostgresV2FanoutPlanStore(
                    database: app.db(.psql), router: V2SingleUserShardRouter(route: remoteRoute)
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
                            database: app.db(.psql), router: V2SingleUserShardRouter(route: remoteRoute)
                        ),
                        pageSize: plannerPageSize,
                        now: Date.init
                    )),
                    retryPolicy: .init(initialDelay: 0.01, maximumDelay: 0.1, maximumAttempts: 10, jitterFraction: 0),
                    now: Date.init
                ),
                deliveryWorker: worker
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
            let controlProfileReport = try await controlProfile?.finish(on: controlSQL)
            let targetProfileReport = try await targetProfile?.finish(on: targetSQL)
            let crossStoreTiming = await timingRecorder.summary()

            #expect(aggregate == .init(
                claimedCount: memberCount, committedCount: memberCount, staleCount: 0,
                staleRouteCount: 0, releasedCount: 0, pausedCount: 0
            ))
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
            try await router.bootstrap(defaultRoute: .init(bucket: "users-source", observedRouterEpoch: 1), now: now)
            let shadow = V2PostgresUserShardProjectionShadowForwarder(
                control: app.db(.psql), router: router,
                migrations: migrations, registry: registry
            )
            let direct = PostgresV2DirectMessagingStore(database: app.db(.psql), shadowForwarder: shadow)
            let capacityProfile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3))
            let forwardingLeaseID = UUID(uuidString: "00000000-0000-0000-0000-000000000f17")!
            try await sql.raw("INSERT INTO im_v2.shard_admission_pools (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit, fanout_window_limit, max_outstanding_fanout_units, max_outstanding_plans) VALUES ('rooms-primary', 'standard', \(bind: forwardingLeaseID), 1, \(bind: now.addingTimeInterval(600)), 10, 100, 100, 10)").run()
            try await sql.raw("INSERT INTO im_v2.public_user_profiles (user_id, public_handle, display_name, revision, created_at, updated_at) VALUES (\(bind: senderUUID), 'sender012', '发送者', 1, \(bind: now), \(bind: now)), (\(bind: memberTwoUUID), 'member015', '成员二', 1, \(bind: now), \(bind: now))").run()
            let directService = try V2DirectMessagingService(store: direct, capacityProfile: capacityProfile, roomShardID: "rooms-primary", now: { now })
            guard case .opened = try await directService.open(actorUserID: senderID, operationID: try .init("00000000-0000-0000-0000-000000000f18"), targetUserID: try .init(memberTwoUUID.uuidString)) else {
                Issue.record("expected direct room")
                return
            }
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

            #expect(try await scopedCount("im_v2", "user_sync_log", user: senderUUID, on: sql) == 4)
            #expect(try await scopedCount("im_v2", "user_sync_log", user: senderUUID, on: secondarySQL) == 4)
            let targetRows = try await secondarySQL.raw("""
                SELECT user_sync_sequence, projection_kind
                FROM im_v2.user_sync_log WHERE user_id = \(bind: senderUUID)
                ORDER BY user_sync_sequence
                """).all(decoding: SyncKindRow.self)
            #expect(targetRows.map(\.sequence) == [1, 2, 3, 4])
            #expect(targetRows.map(\.kind) == ["direct_room_profile", "stranger_message_permission", "relationship", "direct_room_profile"])
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
            #expect(try await scopedCount("im_v2", "user_sync_log", user: senderUUID, on: secondarySQL) == 6)
            let postCutover = try #require(try await secondarySQL.raw("""
                SELECT user_sync_sequence, projection_kind FROM im_v2.user_sync_log
                WHERE user_id = \(bind: senderUUID) ORDER BY user_sync_sequence DESC LIMIT 1
                """).first(decoding: SyncKindRow.self))
            #expect(postCutover.sequence == 6)
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
            #expect(persistedKeys.count == 2)
            #expect(persistedKeys.allSatisfy { $0.clientKey != "198.51.100.8" && $0.clientKey != "2001:db8::8" })
            #expect(persistedKeys.allSatisfy { $0.clientKey.count == 64 })

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
            try await router.bootstrap(defaultRoute: .init(bucket: "users-primary", observedRouterEpoch: 1), now: now)
            let migrations = PostgresV2UserShardMigrationStore(database: app.db(.psql))
            let registry = try V2StaticUserShardStorageRegistry(locations: [
                try .init(bucket: "users-primary", database: app.db(.psql), schema: "im_v2"),
            ])
            let shadow = V2PostgresUserShardProjectionShadowForwarder(
                control: app.db(.psql), router: router, migrations: migrations, registry: registry
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
            #expect(try await oldStore.isCurrent(oldLease, now: now.addingTimeInterval(1)))

            let renewedStore = PostgresV2ContentReviewStore(database: app.db(.psql), makeUUID: { newToken })
            let renewedLease = try #require(try await renewedStore.claimPending(now: now.addingTimeInterval(11), leaseDuration: 10, limit: 1).first)
            #expect(renewedLease.claimToken == newToken)
            #expect(renewedLease.claimToken != oldLease.claimToken)

            // An old worker may resume after its lease expires, but it must
            // never release or resolve the newer owner's claim.
            try await oldStore.release(oldLease)
            try await oldStore.resolve(oldLease, verdict: .clear, now: now.addingTimeInterval(12))
            let fenced = try #require(try await sql.raw("""
                SELECT state, claim_token = \(bind: newToken) AS has_new_token, decision
                FROM im_v2.content_review_jobs WHERE message_id = \(bind: messageUUID)
                """).first(decoding: ContentReviewLeaseFenceAssertionRow.self))
            #expect(fenced.state == "claimed")
            #expect(fenced.hasNewToken)
            #expect(fenced.decision == nil)

            try await renewedStore.resolve(
                renewedLease,
                verdict: .reviewRequired(category: "manual_review", severity: 2, confidence: 0.75),
                now: now.addingTimeInterval(12)
            )
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
            #expect(!(try await staleStore.isCurrent(staleLease, now: now.addingTimeInterval(21))))
            let superseded = try #require(try await sql.raw("""
                SELECT state, decision FROM im_v2.content_review_jobs WHERE message_id = \(bind: editedLaterUUID)
                """).first(decoding: ContentReviewCompletionAssertionRow.self))
            #expect(superseded.state == "superseded")
            #expect(superseded.decision == nil)

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

    @Test("a content policy violation redacts the reviewed revision through the authoritative moderation transaction")
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
            let worker = try V2ContentReviewWorker(
                store: reviewStore,
                reviewer: V2ConfiguredContentReviewer(violatingTerms: ["blocked"]),
                moderation: moderation,
                now: { now.addingTimeInterval(1) }
            )

            #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, resolvedCount: 1, redactedCount: 1, releasedCount: 0))
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
            let members = try (2...100_000).map {
                try UserID(String(format: "00000000-0000-0000-0000-%012x", $0))
            }
            let service = try V2GroupMessagingService(
                store: PostgresV2GroupMessagingStore(database: app.db(.psql)),
                capacityProfile: .init(id: "hybrid-create-100k", limits: profileLimits),
                roomShardID: "hybrid-create-100k",
                identifiers: .init(makeUUID: { UUID() }),
                now: { now }
            )

            let creationStartedAt = Date()
            guard case .created(let group) = try await service.create(
                actorUserID: owner,
                operationID: operationID,
                title: "十万人混合群创建回归",
                initialMemberUserIDs: members
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
                    (SELECT COUNT(*) FROM im_v2.group_room_operations WHERE actor_user_id = \(bind: UUID(uuidString: owner.rawValue)!) AND operation_id = \(bind: UUID(uuidString: operationID.rawValue)!)) AS operation_count
                """).first(decoding: GroupCreateScaleAccountingRow.self))

            #expect(group.deliveryMode == .largeGroupHybrid)
            #expect(group.memberUserIDs.count == 100_000)
            #expect(accounting.memberCount == 100_000)
            #expect(accounting.targetCount == 100_000)
            #expect(accounting.deliveryMode == V2GroupDeliveryMode.largeGroupHybrid.rawValue)
            #expect(accounting.planState == "planning")
            #expect(accounting.operationCount == 1)
            print("V2_LOCAL_HYBRID_100K_GROUP_CREATE_TIMING total_wall_ms=\(v2LocalElapsedMilliseconds(since: startedAt)) schema_ms=\(schemaElapsed) create_ms=\(creationElapsed) members=\(accounting.memberCount) bootstrap_fanout_targets=\(accounting.targetCount)")

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.asyncShutdown()
        } catch {
            if let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
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
            for statement in postgresStatements(in: executableSQL) {
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

/// Test schema installation must handle PostgreSQL function bodies as a
/// single statement. A plain `split(separator: ";")` breaks `$$` blocks and
/// can mask migration failures before a database-backed regression starts.
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

private struct ExistsRow: Decodable { let exists: Bool }
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
    enum CodingKeys: String, CodingKey {
        case memberCount = "member_count"
        case targetCount = "target_count"
        case deliveryMode = "delivery_mode"
        case planState = "plan_state"
        case operationCount = "operation_count"
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
private struct PushStateRow: Decodable { let state: String }
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
private struct ProfilePropagationFailingShadowForwarder: V2UserShardProjectionShadowing {
    func shadowIfForwarding(
        userID _: UserID,
        sourceEventID _: EventID,
        projectionKinds _: Set<String>
    ) async throws -> UInt64? {
        throw ProfilePropagationShadowFailure.interrupted
    }
}
private enum ProfilePropagationShadowFailure: Error, Equatable, Sendable { case interrupted }
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
}
