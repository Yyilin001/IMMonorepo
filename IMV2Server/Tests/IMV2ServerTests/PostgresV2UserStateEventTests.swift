import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing

@Suite("Independent user state events", .serialized)
struct PostgresV2UserStateEventTests {
    @Test("personal event GC preserves busy and missing source rooms")
    func sourceRoomGCFence() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let room = UUID(), healthy = UUID(), missing = UUID()
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            for id in [room, healthy] {
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).rooms (room_id, room_shard_id, capacity_profile_id)
                    VALUES (\(bind: id), 'source', 'standard')
                    """).run()
            }
            for source in [room, healthy, missing, nil] as [UUID?] {
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).user_state_event_outbox
                        (source_event_id, user_id, projection_kind, payload, source_room_id,
                         created_at, next_attempt_at, state, delivered_at, user_sync_sequence)
                    VALUES (\(bind: UUID()), \(bind: UUID()), 'membership',
                        jsonb_build_object('room_id', \(bind: (source ?? room).uuidString)), \(bind: source),
                        \(bind: now), \(bind: now), 'delivered', \(bind: now), 1)
                    """).run()
            }
            let gc = PostgresV2UserStateEventGCWorker(database: database, schema: schema, retention: 60)
            try await database.transaction { transaction in
                let scoped = try #require(transaction as? any SQLDatabase)
                try await scoped.raw("""
                    SELECT room_id FROM \(unsafeRaw: schema).rooms WHERE room_id = \(bind: room) FOR UPDATE
                    """).run()
                #expect(try await gc.runOnce(now: now.addingTimeInterval(120), limit: 10) == 2)
            }
            #expect(try await sql.raw("""
                SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_state_event_outbox
                WHERE source_room_id IN (\(bind: room), \(bind: missing))
                """).first(decoding: UserStateCountRow.self)?.value == 2)
            #expect(try await gc.runOnce(now: now.addingTimeInterval(121), limit: 10) == 1)
        }
    }


    @Test("source ownership distinguishes room events from control events with the same room payload")
    func sourceRoomOwnership() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            func event() throws -> V2UserStateEvent {
                try .init(sourceEventID: .init(uuid: UUID()), userID: user, kind: .directReadReceipt,
                    payload: JSONSerialization.data(withJSONObject: ["room_id": room.rawValue]), createdAt: now)
            }
            let outbox = try PostgresV2UserStateEventOutbox(database: database, schema: schema)
            let owner = try event(), control = try event()
            try await outbox.enqueue(owner, sourceRoomID: room, in: sql)
            try await outbox.enqueue(owner, sourceRoomID: room, in: sql)
            try await outbox.enqueue(control, in: sql)
            await #expect(throws: V2UserStateEventError.identityConflict) { try await outbox.enqueue(owner, in: sql) }
            await #expect(throws: V2UserStateEventError.identityConflict) { try await outbox.enqueue(control, sourceRoomID: room, in: sql) }
            await #expect(throws: (any Error).self) {
                try await outbox.enqueue(event(), sourceRoomID: .init(uuid: UUID()), in: sql)
            }
            #expect(try await sql.raw("""
                SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_state_event_outbox
                WHERE source_room_id = \(bind: room.uuidValue!)
                """).first(decoding: UserStateCountRow.self)?.value == 1)
            #expect(try await sql.raw("""
                SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_state_event_outbox
                WHERE source_room_id IS NULL
                """).first(decoding: UserStateCountRow.self)?.value == 1)
            try await V2SchemaReadiness.verify(database: database, schema: schema)
            try await sql.raw("ALTER TABLE \(unsafeRaw: schema).user_state_event_outbox DROP COLUMN source_room_id CASCADE").run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable("\(schema).user_state_event_outbox[source-room]")) {
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
        }
    }

    @Test("first resolved payload survives lost acknowledgement and compaction")
    func preservesFirstResolvedPayload() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let event = try userStateFixture()
            let visible = Data("{\"is_visible\":true,\"revision\":0}".utf8)
            let hidden = Data("{\"is_visible\":false,\"revision\":1}".utf8)
            let source = try PostgresV2UserStateEventProjector(database: database, schema: schema)
            let first = try await source.projectResolved(event, projectionPayload: visible)
            let retried = try await source.projectResolved(event, projectionPayload: hidden)
            #expect(first.sequence == retried.sequence)
            #expect(try JSONSerialization.jsonObject(with: Data(retried.payloadJSON.utf8)) as? NSDictionary ==
                JSONSerialization.jsonObject(with: visible) as? NSDictionary)
            try await sql.raw("DELETE FROM \(unsafeRaw: schema).user_sync_log").run()
            let restored = try PostgresV2UserStateEventProjector(database: database, schema: schema)
            let replay = try await restored.projectResolved(event, projectionPayload: hidden)
            #expect(replay.sequence == first.sequence)
            #expect(try JSONSerialization.jsonObject(with: Data(replay.payloadJSON.utf8)) as? NSDictionary ==
                JSONSerialization.jsonObject(with: visible) as? NSDictionary)
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_sync_log").first(decoding: UserStateCountRow.self)?.value == 0)
        }
    }

    @Test("direct receipt delivery uses authoritative preferences across databases and freezes retries", arguments: [false, true])
    func authoritativeDirectReceiptPolicy(viewerDisables: Bool) async throws {
        guard let secondary = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"] else { return }
        try await withUserEventDatabase { control, controlSQL, controlSchema in
            try await withUserEventDatabase(databaseURL: secondary) { target, targetSQL, targetSchema in
                let viewer = UUID(), reader = UUID(), room = UUID()
                func candidate(_ watermark: Int) throws -> V2UserStateEvent {
                    try .init(sourceEventID: .init(uuid: UUID()), userID: .init(uuid: viewer), kind: .directReadReceipt,
                        payload: JSONSerialization.data(withJSONObject: [
                            "room_id": room.uuidString, "reader_user_id": reader.uuidString,
                            "read_through_room_sequence": watermark, "recorded_at_ms": 1750000000000,
                        ]), createdAt: Date())
                }
                let registry = try V2StaticUserShardStorageRegistry(locations: [
                    .init(bucket: "target", database: target, schema: targetSchema),
                ])
                let fence = try UserStateTestRouteFence(database: control,
                    route: V2UserShardRoute(bucket: "target", observedRouterEpoch: 1))
                let routed = try V2RoutedUserStateEventProjector(routeFence: fence, registry: registry, controlSchema: controlSchema)
                let first = try candidate(3)
                #expect(try await routed.project(first) == 1)
                let policyUser = viewerDisables ? viewer : reader
                try await controlSQL.raw("""
                    INSERT INTO \(unsafeRaw: controlSchema).user_read_receipt_preferences
                        (user_id, allows_direct_read_receipts, preference_revision, updated_at)
                    VALUES (\(bind: policyUser), false, 1, now())
                    """).run()
                #expect(try await routed.project(candidate(10)) == 2)
                // A lost acknowledgement must return the first committed payload,
                // while a fresh event sees the new authoritative policy.
                #expect(try await routed.project(first) == 1)
                let revisionKey = viewerDisables ? "viewer_preference_revision" : "reader_preference_revision"
                #expect(try await targetSQL.raw("""
                    SELECT count(*)::bigint AS value FROM \(unsafeRaw: targetSchema).user_sync_log
                    WHERE user_sync_sequence = 2 AND payload->>'is_visible' = 'false'
                      AND payload->>'read_through_room_sequence' = '0'
                      AND payload->>\(bind: revisionKey) = '1'
                    """).first(decoding: UserStateCountRow.self)?.value == 1)
                #expect(try await targetSQL.raw("""
                    SELECT count(*)::bigint AS value FROM \(unsafeRaw: targetSchema).user_sync_log
                    WHERE user_sync_sequence = 1 AND payload->>'is_visible' = 'true'
                      AND payload->>'read_through_room_sequence' = '3'
                    """).first(decoding: UserStateCountRow.self)?.value == 1)
                try await controlSQL.raw("""
                    UPDATE \(unsafeRaw: controlSchema).user_read_receipt_preferences
                    SET allows_direct_read_receipts = true, preference_revision = 2
                    WHERE user_id = \(bind: policyUser)
                    """).run()
                #expect(try await routed.project(candidate(40)) == 3)
                let worker = PostgresV2UserProjectionWorker(database: target, schema: targetSchema)
                #expect(try await worker.runOnce().appliedRecordCount == 3)
                #expect(try await targetSQL.raw("""
                    SELECT count(*)::bigint AS value FROM \(unsafeRaw: targetSchema).user_projection_versions
                    WHERE projection_kind = 'direct_read_receipt' AND valid_to_sequence IS NULL
                      AND payload->>'is_visible' = 'true' AND payload->>'read_through_room_sequence' = '40'
                      AND payload->>\(bind: revisionKey) = '2'
                    """).first(decoding: UserStateCountRow.self)?.value == 1)
                #expect(try await targetSQL.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: targetSchema).user_read_receipt_preferences").first(decoding: UserStateCountRow.self)?.value == 0)
            }
        }
    }

    @Test("preference snapshots ignore delayed revisions and reject conflicting settings")
    func preferenceSnapshotOrdering() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let user = UserID(uuid: UUID())
            func event(_ revision: Int, _ allowed: Bool) throws -> V2UserStateEvent {
                try .init(sourceEventID: .init(uuid: UUID()), userID: user, kind: .readReceiptPreferences,
                    payload: JSONSerialization.data(withJSONObject: [
                        "preference_revision": revision, "allows_direct_read_receipts": allowed,
                        "allows_group_read_receipts": true, "updated_at_ms": 1750000000000,
                    ]), createdAt: Date())
            }
            let delivery = try PostgresV2UserStateEventProjector(database: database, schema: schema)
            let worker = PostgresV2UserProjectionWorker(database: database, schema: schema)
            for value in try [event(2, false), event(1, true), event(2, false), event(3, true)] {
                _ = try await delivery.project(value)
            }
            #expect(try await worker.runOnce().appliedRecordCount == 4)
            _ = try await delivery.project(event(3, false))
            #expect(try await worker.runOnce().failedRecordCount == 1)
            #expect(try await sql.raw("""
                SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_projection_versions
                WHERE projection_kind = 'read_receipt_preferences' AND valid_to_sequence IS NULL
                  AND payload->>'preference_revision' = '3' AND payload->>'allows_direct_read_receipts' = 'true'
                """).first(decoding: UserStateCountRow.self)?.value == 1)
        }
    }

    @Test("public content cannot be routed through the user state event type")
    func excludesPublicContent() throws {
        for kind in ["message", "message_reaction", "group_capability"] {
            #expect(V2UserStateEventKind(rawValue: kind) == nil)
            #expect(throws: V2DurableWorkReplayValidationError.invalidTargetShape) {
                _ = try V2DurableWorkReplayTarget(kind: .userStateEvent, sourceEventID: .init(uuid: UUID()),
                    targetUserID: .init(uuid: UUID()), projectionKind: kind)
            }
        }
        #expect(throws: V2UserStateEventError.invalidEvent) {
            _ = try V2UserStateEvent(sourceEventID: .init(uuid: UUID()), userID: .init(uuid: UUID()),
                kind: .membership, payload: Data("[]".utf8), createdAt: Date())
        }
    }

    @Test("personal queue metrics distinguish lease expiry, backoff, pause and completed work")
    func personalQueueMetrics() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let source = PostgresV2UserStateEventMetricsSource(database: database, schema: schema)
            let empty = try await source.loadDurableWorkMetrics()
            #expect(empty.isAvailable && empty.readyUserStateEventRows == 0)
            #expect(empty.oldestUnfinishedUserStateEventAgeSeconds == 0)
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).user_state_event_outbox
                    (source_event_id, user_id, projection_kind, payload, created_at, state,
                     next_attempt_at, claim_token, lease_until, user_sync_sequence, delivered_at)
                SELECT gen_random_uuid(), gen_random_uuid(), 'membership', '{}'::jsonb,
                    CURRENT_TIMESTAMP - CASE WHEN n = 6 THEN interval '1 day' ELSE interval '10 minutes' END,
                    CASE WHEN n IN (1, 2) THEN 'pending' WHEN n IN (3, 4) THEN 'leased'
                         WHEN n = 5 THEN 'paused' ELSE 'delivered' END,
                    CURRENT_TIMESTAMP + CASE WHEN n = 2 THEN interval '1 hour' ELSE interval '-1 hour' END,
                    CASE WHEN n IN (3, 4) THEN gen_random_uuid() END,
                    CASE WHEN n = 3 THEN CURRENT_TIMESTAMP + interval '1 hour'
                         WHEN n = 4 THEN CURRENT_TIMESTAMP - interval '1 hour' END,
                    CASE WHEN n = 6 THEN 1 END,
                    CASE WHEN n = 6 THEN CURRENT_TIMESTAMP END
                FROM generate_series(1, 6) AS n
                """).run()
            let snapshot = try await source.loadDurableWorkMetrics()
            #expect(snapshot.readyUserStateEventRows == 2)
            #expect(snapshot.leasedUserStateEventRows == 1)
            #expect(snapshot.scheduledUserStateEventRows == 1)
            #expect(snapshot.pausedUserStateEventRows == 1)
            #expect((600...630).contains(snapshot.oldestUnfinishedUserStateEventAgeSeconds))
            let rendered = v2RenderPrometheusDurableWorkMetrics(snapshot)
            #expect(rendered.contains("im_v2_user_state_event_backlog{state=\"ready\"} 2"))
            #expect(!rendered.contains("im_v2_room_outbox_"))
            #expect(!rendered.contains("im_v2_fanout_"))
            try await sql.raw("DROP TABLE \(unsafeRaw: schema).user_state_event_outbox").run()
            #expect(await source.durableWorkMetricsSnapshot().isAvailable == false)
        }
    }

    @Test("room state metrics belong only to the room owner and fail independently")
    func roomStateMetricsOwnership() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let room = PostgresV2RoomMessageStateMetricsSource(database: database, schema: schema)
            let user = PostgresV2UserShardDurableWorkMetricsSource(database: database, schema: schema)
            let roomMetrics = try await room.loadDurableWorkMetrics()
            let userMetrics = await user.durableWorkMetricsSnapshot()
            #expect(roomMetrics.isAvailable && roomMetrics.messageProjectionStatesRelationBytes > 0)
            #expect(userMetrics.isAvailable && userMetrics.messageProjectionStatesRelationBytes == 0)
            let aggregate = await V2AggregateDurableWorkMetricsSource(sources: [room, user]).durableWorkMetricsSnapshot()
            #expect(aggregate.isAvailable)
            #expect(aggregate.messageProjectionStatesRelationBytes == roomMetrics.messageProjectionStatesRelationBytes)
            try await sql.raw("DROP TABLE \(unsafeRaw: schema).message_projection_states CASCADE").run()
            #expect(await room.durableWorkMetricsSnapshot().isAvailable == false)
            #expect(await user.durableWorkMetricsSnapshot().isAvailable)
        }
    }

    @Test("historical personal events before the Unix epoch remain deliverable")
    func historicalSourceDate() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let event = try V2UserStateEvent(sourceEventID: .init(uuid: UUID()), userID: .init(uuid: UUID()),
                kind: .membership, payload: Data("{}".utf8), createdAt: Date(timeIntervalSince1970: -1))
            let outbox = try PostgresV2UserStateEventOutbox(database: database, schema: schema)
            try await outbox.enqueue(event, in: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let worker = V2UserStateEventWorker(outbox: outbox,
                projector: try PostgresV2UserStateEventProjector(database: database, schema: schema), now: { now })
            #expect(try await worker.runOnce(limit: 10) == 1)
            #expect(try await worker.runOnce(limit: 10) == 0)
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_sync_log WHERE created_at = \(bind: event.createdAt)").first(decoding: UserStateCountRow.self)?.value == 1)
        }
    }

    @Test("a received event is idempotent after log compaction and rejects identity reuse")
    func replayAfterCompaction() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let event = try userStateFixture()
            let projector = try PostgresV2UserStateEventProjector(database: database, schema: schema)
            #expect(try await projector.project(event) == 1)
            #expect(try await projector.project(event) == 1)
            let rows = try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_sync_log WHERE payload = \(bind: event.payloadJSON)::jsonb").first(decoding: UserStateCountRow.self)
            #expect(rows?.value == 1)
            try await sql.raw("DELETE FROM \(unsafeRaw: schema).user_sync_log").run()
            #expect(try await projector.project(event) == 1)
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_sync_log").first(decoding: UserStateCountRow.self)?.value == 0)
            let changed = try V2UserStateEvent(sourceEventID: event.sourceEventID, userID: event.userID, kind: event.kind,
                payload: Data("{\"room_id\":\"different\"}".utf8), createdAt: event.createdAt)
            await #expect(throws: V2UserStateEventError.identityConflict) { _ = try await projector.project(changed) }
            #expect(try await projector.project(userStateFixture(user: event.userID)) == 2)
        }
    }

    @Test("completed personal event GC is bounded and replay retains the original sequence")
    func completedEventGC() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let outbox = try PostgresV2UserStateEventOutbox(database: database, schema: schema)
            let projector = try PostgresV2UserStateEventProjector(database: database, schema: schema)
            let first = try userStateFixture()
            let second = try userStateFixture(user: first.userID)
            let now = first.createdAt.addingTimeInterval(120)
            var oldLeases: [V2UserStateEventLease] = []
            for event in [first, second] {
                try await outbox.enqueue(event, in: sql)
                let lease = try #require(try await outbox.claim(now: event.createdAt, leaseDuration: 30, limit: 1).first)
                let sequence = try await projector.project(lease.event)
                #expect(try await outbox.acknowledge(lease, sequence: sequence, now: event.createdAt.addingTimeInterval(1)))
                oldLeases.append(lease)
            }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).user_state_event_outbox
                    (source_event_id, user_id, projection_kind, payload, created_at, state, next_attempt_at,
                     claim_token, lease_until, user_sync_sequence, delivered_at)
                SELECT gen_random_uuid(), gen_random_uuid(), 'room', '{}'::jsonb, \(bind: first.createdAt),
                    CASE n WHEN 1 THEN 'pending' WHEN 2 THEN 'leased' WHEN 3 THEN 'paused' ELSE 'delivered' END,
                    \(bind: first.createdAt), CASE WHEN n = 2 THEN gen_random_uuid() END,
                    CASE WHEN n = 2 THEN \(bind: now.addingTimeInterval(60))::timestamptz END,
                    CASE WHEN n = 4 THEN 1 END, CASE WHEN n = 4 THEN \(bind: now)::timestamptz END
                FROM generate_series(1, 4) AS n
                """).run()
            let gc = PostgresV2UserStateEventGCWorker(database: database, schema: schema, retention: 60)
            await #expect(throws: V2UserStateEventGCError.invalidLimit) { try await gc.runOnce(now: now, limit: 0) }
            await #expect(throws: V2UserStateEventGCError.corruptPersistence) { try await gc.runOnce(now: Date(timeIntervalSince1970: .infinity)) }
            #expect(try await gc.runOnce(now: first.createdAt.addingTimeInterval(61), limit: 1) == 0)
            #expect(try await gc.runOnce(now: now, limit: 1) == 1)
            #expect(try await gc.runOnce(now: now, limit: 1) == 1)
            #expect(try await gc.runOnce(now: now, limit: 1) == 0)
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_state_event_outbox").first(decoding: UserStateCountRow.self)?.value == 4)
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_state_event_receipts").first(decoding: UserStateCountRow.self)?.value == 2)
            try await sql.raw("DELETE FROM \(unsafeRaw: schema).user_sync_log").run()
            try await outbox.enqueue(first, in: sql)
            // The extra pending fixture has a different user; isolate the replay claim.
            try await sql.raw("UPDATE \(unsafeRaw: schema).user_state_event_outbox SET next_attempt_at = \(bind: now.addingTimeInterval(60)) WHERE state = 'pending' AND user_id <> \(bind: first.userID.uuidValue!)").run()
            let replay = try #require(try await outbox.claim(now: now, leaseDuration: 30, limit: 1).first)
            #expect(replay.event.sourceEventID == first.sourceEventID)
            #expect(try await projector.project(replay.event) == 1)
            #expect(try await outbox.acknowledge(oldLeases[0], sequence: 1, now: now) == false)
            #expect(try await outbox.acknowledge(replay, sequence: 1, now: now))
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_sync_log").first(decoding: UserStateCountRow.self)?.value == 0)
            #expect(try await projector.project(userStateFixture(user: first.userID)) == 3)
        }
    }

    @Test("outbox rolls back with its source transaction and rejects changed retry payload")
    func sourceTransactionAtomicity() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let outbox = try PostgresV2UserStateEventOutbox(database: database, schema: schema)
            let event = try userStateFixture()
            await #expect(throws: UserStateTestFailure.rollback) {
                try await database.transaction { transaction in
                    let transactionSQL = try #require(transaction as? any SQLDatabase)
                    try await outbox.enqueue(event, in: transactionSQL)
                    throw UserStateTestFailure.rollback
                }
            }
            #expect(try await outbox.claim(now: event.createdAt, leaseDuration: 30, limit: 10).isEmpty)
            try await outbox.enqueue(event, in: sql)
            try await outbox.enqueue(event, in: sql)
            let changed = try V2UserStateEvent(sourceEventID: event.sourceEventID, userID: event.userID, kind: event.kind,
                payload: Data("{\"room_id\":\"different\"}".utf8), createdAt: event.createdAt)
            await #expect(throws: V2UserStateEventError.identityConflict) { try await outbox.enqueue(changed, in: sql) }
            #expect(try await outbox.claim(now: event.createdAt, leaseDuration: 30, limit: 10).count == 1)
        }
    }

    @Test("lost source acknowledgement retries the target once and fences stale leases")
    func recoversLostAcknowledgement() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let outbox = try PostgresV2UserStateEventOutbox(database: database, schema: schema)
            let projector = try PostgresV2UserStateEventProjector(database: database, schema: schema)
            let event = try userStateFixture()
            try await outbox.enqueue(event, in: sql)
            let first = try #require(try await outbox.claim(now: event.createdAt, leaseDuration: 1, limit: 1).first)
            let sequence = try await projector.project(first.event)
            let later = event.createdAt.addingTimeInterval(2)
            #expect(try await outbox.acknowledge(first, sequence: sequence, now: later) == false)
            let second = try #require(try await outbox.claim(now: later, leaseDuration: 30, limit: 1).first)
            #expect(second.attempt == 2)
            #expect(second.token != first.token)
            try await outbox.retry(first, disposition: .pause)
            #expect(try await projector.project(second.event) == sequence)
            #expect(try await outbox.acknowledge(second, sequence: sequence, now: later))
            #expect(try await outbox.claim(now: later, leaseDuration: 30, limit: 1).isEmpty)
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_sync_log").first(decoding: UserStateCountRow.self)?.value == 1)
        }
    }

    @Test("concurrent duplicate receives share one sequence")
    func concurrentReceives() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let projector = try PostgresV2UserStateEventProjector(database: database, schema: schema)
            let event = try userStateFixture()
            async let first = projector.project(event)
            async let second = projector.project(event)
            let values = try await [first, second]
            #expect(values == [1, 1])
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_sync_log").first(decoding: UserStateCountRow.self)?.value == 1)
        }
    }


    @Test("routed events reach only the current owner and replay after compaction")
    func routedCurrentOwnerRecovery() async throws {
        try await withUserStateRouteConnection { control in
        try await withUserEventDatabase { database, sql, schema in
            try await withUserEventDatabase { target, targetSQL, targetSchema in
                let event = try userStateFixture()
                                let registry = try V2StaticUserShardStorageRegistry(locations: [
                    .init(bucket: "source", database: database, schema: schema),
                    .init(bucket: "target", database: target, schema: targetSchema),
                ])
                let route = try UserStateTestRouteFence(database: control,
                    route: V2UserShardRoute(bucket: "target", observedRouterEpoch: 1))
                let routed = try V2RoutedUserStateEventProjector(routeFence: route, registry: registry, controlSchema: schema)
                #expect(try await routed.project(event) == 1)
                #expect(try await routed.project(event) == 1)
                #expect(try await targetSQL.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: targetSchema).user_sync_log").first(decoding: UserStateCountRow.self)?.value == 1)
                try await targetSQL.raw("DELETE FROM \(unsafeRaw: targetSchema).user_sync_log").run()
                #expect(try await routed.project(event) == 1)
                #expect(try await targetSQL.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: targetSchema).user_sync_log").first(decoding: UserStateCountRow.self)?.value == 0)
                #expect(try await routed.project(userStateFixture(user: event.userID)) == 2)
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_sync_log").first(decoding: UserStateCountRow.self)?.value == 0)
            }
        }
        }
    }

    @Test("direct receipt snapshots retain privacy versions across late delivery and reenable", arguments: ["visibility", "incomparable", "reader"], [Int64(-1), Int64(1750000000000)])
    func directReceiptSnapshotOrdering(conflict: String, milliseconds: Int64) async throws {
        try await withUserEventDatabase { database, sql, schema in
            let user = UserID(uuid: UUID()), room = UUID(), reader = UUID()
            func event(_ readerVersion: Int, _ viewerVersion: Int, _ visible: Bool,
                       _ watermark: Int, readerID: UUID? = nil) throws -> V2UserStateEvent {
                try .init(sourceEventID: .init(uuid: UUID()), userID: user, kind: .directReadReceipt,
                    payload: JSONSerialization.data(withJSONObject: [
                        "room_id": room.uuidString, "reader_user_id": (readerID ?? reader).uuidString,
                        "reader_preference_revision": readerVersion, "viewer_preference_revision": viewerVersion,
                        "is_visible": visible, "read_through_room_sequence": watermark,
                        "recorded_at_ms": milliseconds,
                    ]), createdAt: Date())
            }
            let delivery = try PostgresV2UserStateEventProjector(database: database, schema: schema)
            let worker = PostgresV2UserProjectionWorker(database: database, schema: schema)
            for value in try [event(0, 0, true, 3), event(1, 0, false, 0), event(0, 0, true, 100)] {
                _ = try await delivery.project(value)
            }
            #expect(try await worker.runOnce().appliedRecordCount == 3)
            #expect(try await sql.raw("""
                SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_projection_versions
                WHERE projection_kind = 'direct_read_receipt' AND valid_to_sequence IS NULL
                  AND payload->>'is_visible' = 'false' AND payload->>'reader_preference_revision' = '1'
                  AND payload->>'read_through_room_sequence' = '0'
                """).first(decoding: UserStateCountRow.self)?.value == 1)
            for value in try [event(2, 0, true, 101), event(1, 0, false, 0), event(2, 0, true, 4)] {
                _ = try await delivery.project(value)
            }
            // A new worker must recover the retained version from the database.
            let restarted = PostgresV2UserProjectionWorker(database: database, schema: schema)
            #expect(try await restarted.runOnce().appliedRecordCount == 3)
            #expect(try await sql.raw("""
                SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_projection_versions
                WHERE projection_kind = 'direct_read_receipt' AND valid_to_sequence IS NULL
                  AND payload->>'is_visible' = 'true' AND payload->>'reader_preference_revision' = '2'
                  AND payload->>'read_through_room_sequence' = '101'
                """).first(decoding: UserStateCountRow.self)?.value == 1)
            _ = try await delivery.project(event(2, 1, false, 0))
            #expect(try await restarted.runOnce().appliedRecordCount == 1)
            let invalid: V2UserStateEvent
            switch conflict {
            case "visibility": invalid = try event(2, 1, true, 200)
            case "incomparable": invalid = try event(1, 2, false, 0)
            default: invalid = try event(3, 2, true, 200, readerID: UUID())
            }
            _ = try await delivery.project(invalid)
            #expect(try await restarted.runOnce().failedRecordCount == 1)
            #expect(try await sql.raw("""
                SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_projection_versions
                WHERE projection_kind = 'direct_read_receipt' AND valid_to_sequence IS NULL
                  AND payload->>'is_visible' = 'false' AND payload->>'reader_preference_revision' = '2'
                  AND payload->>'viewer_preference_revision' = '1'
                """).first(decoding: UserStateCountRow.self)?.value == 1)
        }
    }

    @Test("direct profile snapshots preserve revision and immutable creation time",
          arguments: ["name", "olderCreation", "sameCreation", "newerCreation", "missingCreation", "negativeCreation"])
    func directProfileSnapshotOrdering(conflict: String) async throws {
        try await withUserEventDatabase { database, sql, schema in
            let user = UserID(uuid: UUID()), room = UUID(), peer = UUID()
            func event(_ revision: Int, _ name: String, created: Int64? = 1750000000000) throws -> V2UserStateEvent {
                var payload: [String: Any] = [
                    "room_id": room.uuidString, "target_user_id": peer.uuidString,
                    "public_handle": "profile_user", "display_name": name, "account_kind": "regular",
                    "revision": revision, "updated_at_ms": 1750000000000,
                ]
                if let created { payload["room_created_at_ms"] = created }
                return try .init(sourceEventID: .init(uuid: UUID()), userID: user, kind: .directRoomProfile,
                    payload: JSONSerialization.data(withJSONObject: payload), createdAt: Date())
            }
            let delivery = try PostgresV2UserStateEventProjector(database: database, schema: schema)
            let worker = PostgresV2UserProjectionWorker(database: database, schema: schema)
            for event in try [event(4, "current"), event(3, "old"), event(4, "current")] {
                _ = try await delivery.project(event)
            }
            #expect(try await worker.runOnce().appliedRecordCount == 3)
            #expect(try await sql.raw("""
                SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_projection_versions
                WHERE projection_kind = 'direct_room_profile' AND valid_to_sequence IS NULL
                  AND payload->>'revision' = '4' AND payload->>'display_name' = 'current'
                """).first(decoding: UserStateCountRow.self)?.value == 1)
            let invalid: V2UserStateEvent
            switch conflict {
            case "olderCreation": invalid = try event(3, "old", created: 1750000000001)
            case "sameCreation": invalid = try event(4, "current", created: 1750000000001)
            case "newerCreation": invalid = try event(5, "new", created: 1750000000001)
            case "missingCreation": invalid = try event(5, "new", created: nil)
            case "negativeCreation": invalid = try event(5, "new", created: -1)
            default: invalid = try event(4, "conflict")
            }
            _ = try await delivery.project(invalid)
            #expect(try await worker.runOnce().failedRecordCount == 1)
            #expect(try await sql.raw("""
                SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_projection_versions
                WHERE projection_kind = 'direct_room_profile' AND valid_to_sequence IS NULL
                  AND payload->>'revision' = '4' AND payload->>'display_name' = 'current'
                  AND payload->>'room_created_at_ms' = '1750000000000'
                """).first(decoding: UserStateCountRow.self)?.value == 1)
        }
    }

    @Test("capability snapshots ignore late room versions and reject conflicting versions")
    func capabilitySnapshotOrdering() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let user = UserID(uuid: UUID()), room = UUID()
            func event(_ version: Int, _ canSend: Bool) throws -> V2UserStateEvent {
                try .init(sourceEventID: .init(uuid: UUID()), userID: user,
                    kind: .directSendingCapability, payload: JSONSerialization.data(withJSONObject: [
                        "room_id": room.uuidString, "state_version": version,
                        "can_send": canSend, "updated_at_ms": 1750000000000,
                    ]), createdAt: Date())
            }
            let delivery = try PostgresV2UserStateEventProjector(database: database, schema: schema)
            let worker = PostgresV2UserProjectionWorker(database: database, schema: schema)
            for event in try [event(4, true), event(3, false), event(4, true), event(5, false)] {
                _ = try await delivery.project(event)
            }
            #expect(try await worker.runOnce().appliedRecordCount == 4)
            let current = try await sql.raw("""
                SELECT (payload->>'state_version')::bigint AS value
                FROM \(unsafeRaw: schema).user_projection_versions
                WHERE projection_kind = 'direct_sending_capability' AND valid_to_sequence IS NULL
                  AND payload->>'can_send' = 'false'
                """).first(decoding: UserStateCountRow.self)
            #expect(current?.value == 5)
            _ = try await delivery.project(event(5, true))
            #expect(try await worker.runOnce().failedRecordCount == 1)
            #expect(try await sql.raw("""
                SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_projection_versions
                WHERE projection_kind = 'direct_sending_capability' AND valid_to_sequence IS NULL
                  AND payload->>'can_send' = 'false' AND payload->>'state_version' = '5'
                """).first(decoding: UserStateCountRow.self)?.value == 1)
        }
    }

    @Test("personal snapshots retain membership revocation across late discovery and rejoin")
    func membershipSnapshotOrdering() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let user = UserID(uuid: UUID()), room = UUID(), owner = UUID()
            func event(_ revision: Int, action: String? = nil, other: Bool = false) throws -> V2UserStateEvent {
                var payload: [String: Any] = ["event_type": action == nil ? "room.created" : "membership_changed",
                    "room_id": room.uuidString, "membership_revision": revision, "title": "Membership",
                    "owner_user_id": owner.uuidString, "capacity_class": "standard", "created_at_ms": 1750000000000]
                if let action { payload["action"] = action; payload["target_user_id"] = other ? UUID().uuidString : user.rawValue }
                return try .init(sourceEventID: .init(uuid: UUID()), userID: user,
                    kind: action == nil ? .room : .membership, payload: JSONSerialization.data(withJSONObject: payload), createdAt: Date())
            }
            let delivery = try PostgresV2UserStateEventProjector(database: database, schema: schema)
            let worker = PostgresV2UserProjectionWorker(database: database, schema: schema)
            let events = try [event(2, action: "add"), event(10, action: "add", other: true),
                              event(3, action: "remove"), event(1), event(11, action: "add", other: true)]
            for event in events { _ = try await delivery.project(event) }
            #expect(try await worker.runOnce().appliedRecordCount == 5)
            let negative = try await sql.raw("""
                SELECT (payload->>'viewer_is_member')::boolean AS member,
                       (payload->>'viewer_membership_revision')::bigint AS revision
                FROM \(unsafeRaw: schema).user_projection_versions WHERE projection_kind = 'room' AND valid_to_sequence IS NULL
                """).first(decoding: UserStateMembershipRow.self)
            #expect(negative?.member == false && negative?.revision == 3)
            _ = try await delivery.project(event(12, action: "add"))
            _ = try await delivery.project(event(4, action: "remove"))
            #expect(try await worker.runOnce().appliedRecordCount == 2)
            let rejoined = try await sql.raw("""
                SELECT (payload->>'viewer_is_member')::boolean AS member,
                       (payload->>'viewer_membership_revision')::bigint AS revision
                FROM \(unsafeRaw: schema).user_projection_versions WHERE projection_kind = 'room' AND valid_to_sequence IS NULL
                """).first(decoding: UserStateMembershipRow.self)
            #expect(rejoined?.member == true && rejoined?.revision == 12)
        }
    }

    @Test("public content in a personal stream pauses without advancing the checkpoint", arguments: ["message", "message_reaction", "group_capability", "moderation"])
    func rejectsPublicProjection(kind: String) async throws {
        try await withUserEventDatabase { database, sql, schema in
            let user = UUID(), source = UUID(), now = Date()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).user_sync_sequences (user_id, next_sequence) VALUES (\(bind: user), 1)").run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                VALUES (\(bind: user), 1, \(bind: source), \(bind: kind), '{}'::jsonb, \(bind: now))
                """).run()
            let worker = PostgresV2UserProjectionWorker(database: database, schema: schema)
            let result = try await worker.runOnce(now: now)
            #expect(result.appliedRecordCount == 0 && result.failedRecordCount == 1 && result.pausedUserCount == 1)
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_projection_checkpoints WHERE user_id = \(bind: user) AND state = 'paused' AND projected_sequence = 0 AND failed_sequence = 1").first(decoding: UserStateCountRow.self)?.value == 1)
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_projection_versions WHERE user_id = \(bind: user)").first(decoding: UserStateCountRow.self)?.value == 0)
        }
    }

    @Test("personal read snapshots retain the highest watermark across late events", arguments: [-2000, 0])
    func personalReadWatermarkProjection(timeOffset: Int) async throws {
        try await withUserEventDatabase { database, sql, schema in
            let user = UUID(), room = UUID(), now = Date()
            let projector = try PostgresV2UserStateEventProjector(database: database, schema: schema)
            let worker = PostgresV2UserProjectionWorker(database: database, schema: schema)
            for (position, timestamp) in [(42, 1000), (7, 2000), (42, 900), (42, 1100), (100, 800)] {
                let event = try V2UserStateEvent(sourceEventID: .init(uuid: UUID()), userID: .init(uuid: user), kind: .ownReadWatermark,
                    payload: JSONSerialization.data(withJSONObject: ["room_id": room.uuidString,
                        "read_through_room_sequence": position, "recorded_at_ms": timestamp + timeOffset]), createdAt: now)
                _ = try await projector.project(event)
                let result = try await worker.runOnce(now: now)
                #expect(result.appliedRecordCount == 1 && result.failedRecordCount == 0)
                let expected = position == 100 ? 100 : 42
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_projection_versions WHERE user_id = \(bind: user) AND projection_kind = 'own_read_watermark' AND scope_room_id = \(bind: room) AND valid_to_sequence IS NULL AND (payload->>'read_through_room_sequence')::bigint = \(bind: expected)").first(decoding: UserStateCountRow.self)?.value == 1)
            }
            // Stale arrivals advance the log checkpoint but create no replacement versions.
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_projection_versions WHERE user_id = \(bind: user) AND projection_kind = 'own_read_watermark'").first(decoding: UserStateCountRow.self)?.value == 3)
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_projection_checkpoints WHERE user_id = \(bind: user) AND projected_sequence = 5").first(decoding: UserStateCountRow.self)?.value == 1)
        }
    }

    @Test("invalid personal watermark payloads do not advance snapshot checkpoints", arguments: [
        "{\"read_timeline_sequence\":7}",
        "{\"read_through_room_sequence\":0,\"recorded_at_ms\":1}",
        "{\"read_through_room_sequence\":true,\"recorded_at_ms\":1}",
        "{\"read_through_room_sequence\":1,\"recorded_at_ms\":9223372036854775808}"
    ])
    func rejectsInvalidReadWatermark(fields: String) async throws {
        try await withUserEventDatabase { database, sql, schema in
            let user = UUID(), room = UUID(), now = Date()
            var object = try #require(JSONSerialization.jsonObject(with: Data(fields.utf8)) as? [String: Any])
            object["room_id"] = room.uuidString
            let event = try V2UserStateEvent(sourceEventID: .init(uuid: UUID()), userID: .init(uuid: user), kind: .ownReadWatermark,
                payload: JSONSerialization.data(withJSONObject: object), createdAt: now)
            _ = try await PostgresV2UserStateEventProjector(database: database, schema: schema).project(event)
            let result = try await PostgresV2UserProjectionWorker(database: database, schema: schema).runOnce(now: now)
            #expect(result.appliedRecordCount == 0 && result.failedRecordCount == 1)
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).user_projection_checkpoints WHERE user_id = \(bind: user) AND projected_sequence = 0 AND last_failure_code = 'invalid_payload'").first(decoding: UserStateCountRow.self)?.value == 1)
        }
    }

}

private func userStateFixture(user: UserID = .init(uuid: UUID())) throws -> V2UserStateEvent {
    try .init(sourceEventID: .init(uuid: UUID()), userID: user, kind: .room,
              payload: Data("{\"room_id\":\"test-room\"}".utf8), createdAt: Date(timeIntervalSince1970: 1_750_000_000))
}
private enum UserStateTestFailure: Error { case rollback }

private struct UserStateCountRow: Decodable { let value: Int64 }
private var userStateRepoRoot: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}
private func executeUserStateSQL(_ source: String, on sql: any SQLDatabase) async throws {
    // The parser removes SQL comments outside dollar-quoted bodies. Preserve
    // comments inside function source so readiness verifies the canonical hash.
    for statement in postgresStatements(in: source) where !statement.isEmpty && statement != "BEGIN" && statement != "COMMIT" {
        try await sql.raw("\(unsafeRaw: statement)").run()
    }
}
func withUserEventDatabase(databaseURL: String? = nil, _ operation: (any Database, any SQLDatabase, String) async throws -> Void) async throws {
    guard let url = databaseURL ?? ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
          ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1" else { return }
    let resources = makeV2DatabaseTestResources()
    let schema = "state_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    do {
        resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
        let sql = try #require(resources.database(.psql) as? any SQLDatabase)
        let source = try String(contentsOf: userStateRepoRoot.appending(path: "IMV2/sql/schema.sql"), encoding: .utf8)
            .replacingOccurrences(of: "im_v2", with: schema)
        try await executeUserStateSQL(source, on: sql)
        try await operation(resources.database(.psql), sql, schema)
        try await sql.raw("DROP SCHEMA \(unsafeRaw: schema) CASCADE").run()
        try await resources.shutdown()
    } catch {
        if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS \(unsafeRaw: schema) CASCADE").run() }
        try? await resources.shutdown()
        throw error
    }
}

private struct UserStateTestRouteFence: V2UserShardRouteFencing {
    let database: any Database
    let route: V2UserShardRoute
    func withCurrentRoute<Result: Sendable>(for userID: UserID,
        _ operation: @escaping @Sendable (V2UserShardRoute, any Database) async throws -> Result) async throws -> Result {
        try await database.transaction { transaction in try await operation(route, transaction) }
    }
}


private func withUserStateRouteConnection(_ operation: @escaping @Sendable (any Database) async throws -> Void) async throws {
    guard let url = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
          ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1" else { return }
    let resources = makeV2DatabaseTestResources()
    do {
        resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
        try await operation(resources.database(.psql))
        try await resources.shutdown()
    } catch {
        try? await resources.shutdown()
        throw error
    }
}

private struct UserStateMembershipRow: Decodable { let member: Bool; let revision: Int64 }
