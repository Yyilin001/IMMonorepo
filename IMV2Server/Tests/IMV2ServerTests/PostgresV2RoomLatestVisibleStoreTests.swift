@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("Latest visible room snapshots", .serialized)
struct PostgresV2RoomLatestVisibleStoreTests {
    @Test("summary restores only authorized content revisions across membership gaps", arguments: ["message_row", "room_event"], [false, true])
    func contentRevisionMembership(storage: String, invisibleLatest: Bool) async throws {
        try await withUserEventDatabase { db, sql, schema in
            let user = UUID(), sender = UUID(), room = UUID(), message = UUID(), accepted = UUID()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id,membership_revision,room_sequence)
                VALUES (\(bind: room),'room-a','standard',3,3)
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision,left_revision)
                VALUES (\(bind: room),\(bind: user),1,2),(\(bind: room),\(bind: user),3,NULL)
                """).run()
            let acceptedID: UUID? = storage == "message_row" ? accepted : nil
            let acceptedRevision: Int? = storage == "message_row" ? 1 : nil
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).messages
                    (message_id,room_id,room_sequence,timeline_sequence,sender_user_id,client_message_id,
                     text_body,created_at,accepted_event_storage,accepted_event_id,accepted_membership_revision)
                VALUES (\(bind: message),\(bind: room),1,1,\(bind: sender),\(bind: UUID()),
                        'original visible text',now(),\(bind: storage),\(bind: acceptedID),\(bind: acceptedRevision))
                """).run()
            if storage == "room_event" {
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).room_events
                        (event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at)
                    VALUES (\(bind: accepted),\(bind: room),1,'message.accepted',
                        jsonb_build_object('message_id',\(bind: message.uuidString)::text),1,now())
                    """).run()
            }
            if invisibleLatest {
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).messages
                        (message_id,room_id,room_sequence,timeline_sequence,sender_user_id,client_message_id,
                         text_body,created_at,accepted_event_storage,accepted_event_id,accepted_membership_revision)
                    VALUES (\(bind: UUID()),\(bind: room),2,2,\(bind: sender),\(bind: UUID()),
                            'invisible new message',now(),'message_row',\(bind: UUID()),2)
                    """).run()
            }
            func edit(revision: Int, sequence: Int, membership: Int, text: String) async throws {
                try await sql.raw("""
                    UPDATE \(unsafeRaw: schema).messages SET text_body = \(bind: text), content_revision = \(bind: revision)
                    WHERE message_id = \(bind: message)
                    """).run()
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).room_events
                        (event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at)
                    VALUES (\(bind: UUID()),\(bind: room),\(bind: sequence),'message.edited',
                        jsonb_build_object('message_id',\(bind: message.uuidString)::text,
                                           'room_id',\(bind: room.uuidString)::text,'message_revision',\(bind: revision)),
                        \(bind: membership),now())
                    """).run()
                try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence = \(bind: sequence) WHERE room_id = \(bind: room)").run()
            }
            let store = try PostgresV2RoomLatestVisibleStore(database: db, schema: schema)
            let id = RoomID(uuid: room), actor = UserID(uuid: user)
            func summary() async throws -> V2RoomLatestVisible {
                guard case .snapshot(let snapshot)? = try await store.latestVisible(roomIDs: [id], actorUserID: actor)[id] else {
                    throw V2RoomRecoveryReadError.corruptPersistence
                }
                return snapshot
            }
            try await edit(revision: 2, sequence: 3, membership: 2, text: "secret from first membership gap")
            let original = try await summary()
            #expect(original.latest?.id == .init(uuid: message))
            #expect(original.latest?.revision == 1 && original.latest?.preview == "original visible text")
            try await edit(revision: 3, sequence: 4, membership: 3, text: "visible replacement after rejoin")
            let replacement = try await summary()
            #expect(replacement.latest?.revision == 3 && replacement.latest?.preview == "visible replacement after rejoin")
            try await sql.raw("UPDATE \(unsafeRaw: schema).room_memberships SET left_revision = 4 WHERE room_id = \(bind: room) AND joined_revision = 3").run()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision) VALUES (\(bind: room),\(bind: user),5)").run()
            try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET membership_revision = 5 WHERE room_id = \(bind: room)").run()
            try await edit(revision: 4, sequence: 5, membership: 4, text: "secret from second membership gap")
            let retained = try await summary()
            #expect(retained.head == 5 && retained.latest?.revision == 3)
            #expect(retained.latest?.preview == "visible replacement after rejoin")
            try await edit(revision: 5, sequence: 6, membership: 5, text: "second visible replacement")
            // The body and authorization must belong to the same room-head snapshot.
            try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence = 5 WHERE room_id = \(bind: room)").run()
            let olderHead = try await summary()
            #expect(olderHead.latest?.revision == 3 && olderHead.latest?.preview == "visible replacement after rejoin")
            try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence = 6 WHERE room_id = \(bind: room)").run()
            let newest = try await summary()
            #expect(newest.latest?.revision == 5 && newest.latest?.preview == "second visible replacement")
            if storage == "message_row" && !invisibleLatest {
                // Version authorization must seek the chosen message, rather than scan
                // the entire room's edit history for each summary in a batch.
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).room_events
                        (event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at)
                    SELECT gen_random_uuid(),\(bind: room),n,'message.edited',
                        jsonb_build_object('message_id',gen_random_uuid()::text,
                                           'room_id',\(bind: room.uuidString)::text,'message_revision',2),5,now()
                    FROM generate_series(7,10006) AS n
                    """).run()
                try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence = 10006 WHERE room_id = \(bind: room)").run()
                try await sql.raw("ANALYZE \(unsafeRaw: schema).room_events").run()
                try await sql.raw("ANALYZE \(unsafeRaw: schema).message_edit_visibility").run()
                let query = PostgresV2RoomLatestVisibleStore.latestVisibleQuery(schema: schema, ids: [room], actor: user)
                let plan = try await sql.raw("EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) \(query)").all()
                    .map { try $0.decode(column: "QUERY PLAN", as: String.self) }.joined(separator: "\n")
                #expect(plan.contains("message_edit_visibility_latest_idx"))
                #expect(!plan.contains("Seq Scan on message_edit_visibility content_event"))
                print("ROOM_RECOVERY_CONTENT_VERSION_PLAN unrelated_edits=10000\n\(plan)")
            }
            try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence = 5 WHERE room_id = \(bind: room)").run()
            try await sql.raw("DELETE FROM \(unsafeRaw: schema).message_content_versions WHERE message_id = \(bind: message) AND message_revision = 3").run()
            await #expect(throws: V2RoomRecoveryReadError.corruptPersistence) {
                try await store.latestVisible(roomIDs: [id], actorUserID: actor)
            }
            // Current and edit-time membership cannot replace original acceptance-time membership.
            try await sql.raw("DELETE FROM \(unsafeRaw: schema).room_memberships WHERE room_id = \(bind: room) AND joined_revision = 1").run()
            #expect(try await summary().latest == nil)
        }
    }

    @Test("summary plans account for long histories outside the viewer membership interval", arguments: ["message_row", "room_event", "mixed"])
    func invisibleHistoryPlan(storage: String) async throws {
        try await withUserEventDatabase { db, sql, schema in
            let user = UUID(), room = UUID()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id,membership_revision,room_sequence)
                VALUES (\(bind: room),'room-a','standard',3,10000)
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision,left_revision)
                VALUES (\(bind: room),\(bind: user),1,2),(\(bind: room),\(bind: user),3,NULL)
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).messages
                    (message_id,room_id,room_sequence,timeline_sequence,sender_user_id,client_message_id,
                     text_body,created_at,accepted_event_storage,accepted_event_id,accepted_membership_revision)
                SELECT gen_random_uuid(),\(bind: room),n,n,\(bind: user),gen_random_uuid(),
                    'interval-' || n::text,now(),'message_row',gen_random_uuid(),
                    CASE WHEN n <= 100 THEN 1 ELSE 2 END
                FROM generate_series(1,10000) AS n
                """).run()
            if storage != "message_row" {
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).room_events
                        (event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at)
                    SELECT accepted_event_id,room_id,room_sequence,'message.accepted',
                        jsonb_build_object('message_id',message_id::text),accepted_membership_revision,created_at
                    FROM \(unsafeRaw: schema).messages
                    WHERE \(bind: storage) = 'room_event' OR room_sequence % 2 = 0
                    """).run()
                try await sql.raw("""
                    UPDATE \(unsafeRaw: schema).messages SET accepted_event_storage = 'room_event',
                        accepted_event_id = NULL, accepted_membership_revision = NULL
                    WHERE \(bind: storage) = 'room_event' OR room_sequence % 2 = 0
                    """).run()
                try await sql.raw("ANALYZE \(unsafeRaw: schema).room_events").run()
            }
            for table in ["rooms", "room_memberships", "messages"] {
                try await sql.raw("ANALYZE \(unsafeRaw: schema).\(unsafeRaw: table)").run()
            }
            let store = try PostgresV2RoomLatestVisibleStore(database: db, schema: schema)
            let result = try await store.latestVisible(roomIDs: [.init(uuid: room)], actorUserID: .init(uuid: user))
            guard case .snapshot(let snapshot)? = result[.init(uuid: room)] else {
                Issue.record("missing rejoined member snapshot"); return
            }
            #expect(snapshot.latest?.sequence == 100)
            #expect(snapshot.membershipRevision == 3)
            let query = PostgresV2RoomLatestVisibleStore.latestVisibleQuery(schema: schema, ids: [room], actor: user)
            let plan = try await sql.raw("EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) \(query)").all()
                .map { try $0.decode(column: "QUERY PLAN", as: String.self) }.joined(separator: "\n")
            print("ROOM_RECOVERY_INVISIBLE_HISTORY_PLAN storage=\(storage) messages=10000 invisible_tail=9900\n\(plan)")
            #expect(snapshot.latest?.preview == "interval-100")
            if storage != "message_row" {
                try await sql.raw("DELETE FROM \(unsafeRaw: schema).room_memberships WHERE room_id = \(bind: room) AND left_revision IS NOT NULL").run()
                let denied = try await store.latestVisible(roomIDs: [.init(uuid: room)], actorUserID: .init(uuid: user))
                guard case .snapshot(let empty)? = denied[.init(uuid: room)] else {
                    Issue.record("missing current member snapshot"); return
                }
                #expect(empty.latest == nil)
                return
            }
            // Experimental access path only: compare interval filtering before
            // sorting without changing the production query or canonical schema.
            try await sql.raw("""
                CREATE INDEX messages_interval_candidate_idx ON \(unsafeRaw: schema).messages
                (room_id,accepted_membership_revision,room_sequence DESC)
                WHERE accepted_event_storage = 'message_row' AND withdrawn_at IS NULL
                """).run()
            let candidate: SQLQueryString = """
                WITH authorized AS MATERIALIZED (
                    SELECT message.room_sequence
                    FROM \(unsafeRaw: schema).room_memberships AS history
                    CROSS JOIN LATERAL (
                        SELECT message.room_sequence
                        FROM \(unsafeRaw: schema).messages AS message
                        WHERE message.room_id = history.room_id
                          AND message.accepted_event_storage = 'message_row'
                          AND message.withdrawn_at IS NULL
                          AND message.accepted_membership_revision >= history.joined_revision
                          AND message.accepted_membership_revision < COALESCE(history.left_revision,9223372036854775807)
                          AND message.room_sequence <= 10000
                        OFFSET 0
                    ) AS message
                    WHERE history.room_id = \(bind: room) AND history.user_id = \(bind: user)
                ) SELECT room_sequence FROM authorized ORDER BY room_sequence DESC LIMIT 1
                """
            let candidateSequence = try await sql.raw(candidate).first()?.decode(column: "room_sequence", as: Int64.self)
            #expect(candidateSequence == 100)
            let candidatePlan = try await sql.raw("EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) \(candidate)").all()
                .map { try $0.decode(column: "QUERY PLAN", as: String.self) }.joined(separator: "\n")
            print("ROOM_RECOVERY_INTERVAL_CANDIDATE_PLAN messages=10000 invisible_tail=9900\n\(candidatePlan)")
            let combined: SQLQueryString = """
                WITH recent AS MATERIALIZED (
                    SELECT room_sequence,accepted_membership_revision
                    FROM \(unsafeRaw: schema).messages
                    WHERE room_id = \(bind: room) AND room_sequence <= 10000
                      AND accepted_event_storage = 'message_row' AND withdrawn_at IS NULL
                    ORDER BY room_sequence DESC LIMIT 1
                ), fast AS MATERIALIZED (
                    SELECT recent.room_sequence FROM recent
                    WHERE EXISTS (
                        SELECT 1 FROM \(unsafeRaw: schema).room_memberships AS history
                        WHERE history.room_id = \(bind: room) AND history.user_id = \(bind: user)
                          AND history.joined_revision <= recent.accepted_membership_revision
                          AND (history.left_revision IS NULL OR history.left_revision > recent.accepted_membership_revision)
                    ) ORDER BY room_sequence DESC LIMIT 1
                ) SELECT room_sequence FROM fast
                UNION ALL
                SELECT fallback.room_sequence FROM (\(candidate)) AS fallback
                WHERE NOT EXISTS (SELECT 1 FROM fast)
                """
            #expect(try await sql.raw(combined).first()?.decode(column: "room_sequence", as: Int64.self) == 100)
            let combinedPlan = try await sql.raw("EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) \(combined)").all()
                .map { try $0.decode(column: "QUERY PLAN", as: String.self) }.joined(separator: "\n")
            print("ROOM_RECOVERY_COMBINED_COLD_PLAN\n\(combinedPlan)")
            // Current membership alone must never authorize the intervening tail.
            try await sql.raw("DELETE FROM \(unsafeRaw: schema).room_memberships WHERE room_id = \(bind: room) AND left_revision IS NOT NULL").run()
            let noHistory = try await store.latestVisible(roomIDs: [.init(uuid: room)], actorUserID: .init(uuid: user))
            guard case .snapshot(let empty)? = noHistory[.init(uuid: room)] else {
                Issue.record("current member must retain an empty authorized snapshot"); return
            }
            #expect(empty.latest == nil)
            #expect(try await sql.raw(combined).first() == nil)
            // Compare the opposite distribution before considering this access
            // path for production: all 10,000 messages are now authorized.
            try await sql.raw("UPDATE \(unsafeRaw: schema).room_memberships SET joined_revision = 1 WHERE room_id = \(bind: room)").run()
            try await sql.raw("UPDATE \(unsafeRaw: schema).messages SET accepted_membership_revision = 1").run()
            try await sql.raw("ANALYZE \(unsafeRaw: schema).messages").run()
            let hotResult = try await store.latestVisible(roomIDs: [.init(uuid: room)], actorUserID: .init(uuid: user))
            guard case .snapshot(let hot)? = hotResult[.init(uuid: room)] else {
                Issue.record("missing fully authorized snapshot"); return
            }
            #expect(hot.latest?.sequence == 10000)
            #expect(try await sql.raw(candidate).first()?.decode(column: "room_sequence", as: Int64.self) == 10000)
            #expect(try await sql.raw(combined).first()?.decode(column: "room_sequence", as: Int64.self) == 10000)
            for (name, statement) in [("production", query), ("interval-candidate", candidate), ("combined", combined)] {
                let hotPlan = try await sql.raw("EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) \(statement)").all()
                    .map { try $0.decode(column: "QUERY PLAN", as: String.self) }.joined(separator: "\n")
                print("ROOM_RECOVERY_VISIBLE_HISTORY_PLAN path=\(name) messages=10000\n\(hotPlan)")
            }
        }
    }

    @Test("long withdrawn tails report the production summary execution plan", arguments: ["message_row", "room_event"])
    func longHistoryPlan(storage: String) async throws {
        try await withUserEventDatabase { db, sql, schema in
            let user = UUID(), room = UUID()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).rooms(room_id, room_shard_id, capacity_profile_id, membership_revision, room_sequence)
                VALUES (\(bind: room), 'room-a', 'standard', 1, 10000)
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision)
                VALUES (\(bind: room), \(bind: user), 1)
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).messages
                    (message_id,room_id,room_sequence,timeline_sequence,sender_user_id,client_message_id,
                     text_body,created_at,accepted_event_storage,accepted_event_id,accepted_membership_revision,
                     withdrawn_at,withdrawn_by_user_id)
                SELECT gen_random_uuid(), \(bind: room), n, n, \(bind: user), gen_random_uuid(),
                    'history-' || n::text, now(), 'message_row', gen_random_uuid(), 1,
                    CASE WHEN n > 100 THEN now() ELSE NULL END,
                    CASE WHEN n > 100 THEN \(bind: user)::uuid ELSE NULL END
                FROM generate_series(1,10000) AS n
                """).run()
            if storage == "room_event" {
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).room_events
                        (event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at)
                    SELECT accepted_event_id,room_id,room_sequence,'message.accepted',
                        jsonb_build_object('message_id',message_id::text),1,created_at
                    FROM \(unsafeRaw: schema).messages
                    """).run()
                try await sql.raw("""
                    UPDATE \(unsafeRaw: schema).messages SET accepted_event_storage = 'room_event',
                        accepted_event_id = NULL, accepted_membership_revision = NULL
                    """).run()
            }
            for table in ["rooms", "room_memberships", "messages", "room_events"] {
                try await sql.raw("ANALYZE \(unsafeRaw: schema).\(unsafeRaw: table)").run()
            }
            let store = try PostgresV2RoomLatestVisibleStore(database: db, schema: schema)
            let result = try await store.latestVisible(roomIDs: [.init(uuid: room)], actorUserID: .init(uuid: user))
            guard case .snapshot(let snapshot)? = result[.init(uuid: room)] else {
                Issue.record("missing authorized history summary"); return
            }
            #expect(snapshot.latest?.sequence == 100)
            try await sql.raw("DROP INDEX IF EXISTS \(unsafeRaw: schema).messages_latest_visible_idx").run()
            let query = PostgresV2RoomLatestVisibleStore.latestVisibleQuery(schema: schema, ids: [room], actor: user)
            let plan = try await sql.raw("EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) \(query)").all()
                .map { try $0.decode(column: "QUERY PLAN", as: String.self) }.joined(separator: "\n")
            print("ROOM_RECOVERY_LONG_HISTORY_PLAN storage=\(storage)\n\(plan)")
            try await sql.raw("CREATE INDEX messages_latest_visible_idx ON \(unsafeRaw: schema).messages (room_id, room_sequence DESC, message_id DESC) WHERE withdrawn_at IS NULL").run()
            try await sql.raw("ANALYZE \(unsafeRaw: schema).messages").run()
            let indexed = try await sql.raw("EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) \(query)").all()
                .map { try $0.decode(column: "QUERY PLAN", as: String.self) }.joined(separator: "\n")
            print("ROOM_RECOVERY_INDEXED_HISTORY_PLAN storage=\(storage)\n\(indexed)")
            let messageScan = try #require(indexed.split(separator: "\n").first {
                $0.contains("Index Scan using messages_latest_visible_idx")
            })
            #expect(messageScan.contains("rows=1 loops=1"))
            // An empty room-event join may be sorted independently by PostgreSQL.
            #expect(!indexed.contains("Sort Key: message.room_sequence"))
            let indexedResult = try await store.latestVisible(roomIDs: [.init(uuid: room)], actorUserID: .init(uuid: user))
            guard case .snapshot(let indexedSnapshot)? = indexedResult[.init(uuid: room)] else {
                Issue.record("indexed summary missing"); return
            }
            #expect(indexedSnapshot == snapshot)
            let outsider = try await store.latestVisible(roomIDs: [.init(uuid: room)], actorUserID: .init(uuid: UUID()))
            guard case .unavailable? = outsider[.init(uuid: room)] else {
                Issue.record("summary index must not bypass membership authorization"); return
            }

        }
    }

    @Test("state and visible-summary batches scale with nonempty rooms", arguments: [1000, 10000])
    func nonemptyScale(count: Int) async throws {
        try await withUserEventDatabase { db, sql, schema in
            let user = UUID(), peer = UUID(), actor = UserID(uuid: user)
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).rooms
                    (room_id, room_shard_id, capacity_profile_id, membership_revision, room_sequence)
                SELECT ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
                       'room-a', 'standard', 1, 10
                FROM generate_series(1, \(bind: count)) AS n
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_memberships(room_id, user_id, joined_revision)
                SELECT room_id, \(bind: user), 1 FROM \(unsafeRaw: schema).rooms
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).messages
                    (message_id, room_id, room_sequence, timeline_sequence, sender_user_id, client_message_id,
                     text_body, created_at, accepted_event_storage, accepted_event_id, accepted_membership_revision)
                SELECT gen_random_uuid(), room_id, n, n,
                       CASE WHEN n <= 5 THEN \(bind: user)::uuid ELSE \(bind: peer)::uuid END,
                       gen_random_uuid(), 'scale-message-' || n::text, now(), 'message_row', gen_random_uuid(), 1
                FROM \(unsafeRaw: schema).rooms CROSS JOIN generate_series(1, 10) AS n
                """).run()
            try await sql.raw("""
                UPDATE \(unsafeRaw: schema).messages
                SET withdrawn_at = now(), withdrawn_by_user_id = \(bind: peer), content_revision = 2
                WHERE room_sequence = 10
                """).run()
            for table in ["rooms", "room_memberships", "messages"] {
                try await sql.raw("ANALYZE \(unsafeRaw: schema).\(unsafeRaw: table)").run()
            }
            let states = try PostgresV2RoomRecoveryStore(database: db, schema: schema)
            let summaries = try PostgresV2RoomLatestVisibleStore(database: db, schema: schema)
            let start = ContinuousClock.now
            var after: RoomID?, visited: Set<RoomID> = [], batches = 0
            while true {
                let page = try await states.rooms(actorUserID: actor, after: after, limit: 100)
                let ids = page.entries.map(\.roomID)
                #expect(ids.count == 100 && Set(ids).isDisjoint(with: visited))
                visited.formUnion(ids)
                let stateBatch = try await states.states(roomIDs: ids, actorUserID: actor)
                let summaryBatch = try await summaries.latestVisible(roomIDs: ids, actorUserID: actor)
                for id in ids {
                    guard case .state(let state)? = stateBatch[id],
                          case .snapshot(let summary)? = summaryBatch[id] else {
                        Issue.record("authorized nonempty room missing"); continue
                    }
                    #expect(state.head == 10 && state.latestOwnMessageSequence == 5 && state.unreadCount == 5)
                    #expect(summary.head == 10 && summary.latest?.sequence == 9)
                    #expect(summary.latest?.preview == "scale-message-9")
                }
                batches += 1
                guard batches <= count / 100 else { throw V2RoomRecoveryReadError.corruptPersistence }
                if !page.hasMore { break }
                after = try #require(page.scannedThrough)
            }
            #expect(visited.count == count && batches == count / 100)
            print("ROOM_RECOVERY_NONEMPTY_SCALE rooms=\(count) messages=\(count * 10) batches=\(batches) elapsed=\(start.duration(to: .now))")
        }
    }

    @Test(arguments: ["room_event", "message_row"])
    func withdrawalAndMembership(storage: String) async throws {
        try await withUserEventDatabase { db, sql, schema in
            let user = UUID(), room = UUID(), older = UUID(), newer = UUID()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).rooms(room_id, room_shard_id, capacity_profile_id, membership_revision, room_sequence)
                VALUES (\(bind: room), 'room-a', 'standard', 1, 2)
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_memberships(room_id, user_id, joined_revision)
                VALUES (\(bind: room), \(bind: user), 1)
                """).run()
            for (offset, message) in [older, newer].enumerated() {
                let sequence = offset + 1, event = UUID()
                let acceptedID: UUID? = storage == "message_row" ? event : nil
                let acceptedRevision: Int? = storage == "message_row" ? 1 : nil
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).messages
                        (message_id, room_id, room_sequence, timeline_sequence, sender_user_id, client_message_id,
                         text_body, created_at, accepted_event_storage, accepted_event_id, accepted_membership_revision)
                    VALUES (\(bind: message), \(bind: room), \(bind: sequence), \(bind: sequence), \(bind: user), \(bind: UUID()),
                            'preview', now(), \(bind: storage), \(bind: acceptedID), \(bind: acceptedRevision))
                    """).run()
                if storage == "room_event" {
                    try await sql.raw("""
                        INSERT INTO \(unsafeRaw: schema).room_events
                            (event_id, room_id, room_sequence, event_type, payload, committed_membership_revision, created_at)
                        VALUES (\(bind: event), \(bind: room), \(bind: sequence), 'message.accepted',
                                jsonb_build_object('message_id', \(bind: message.uuidString)::text), 1, now())
                        """).run()
                }
            }
            let store = try PostgresV2RoomLatestVisibleStore(database: db, schema: schema)
            let id = RoomID(uuid: room), actor = UserID(uuid: user)
            guard case .snapshot(let first) = try await store.latestVisible(roomIDs: [id], actorUserID: actor)[id] else {
                Issue.record("authorized snapshot missing"); return
            }
            #expect(first.head == 2 && first.latest?.id == .init(uuid: newer))
            try await sql.raw("""
                UPDATE \(unsafeRaw: schema).messages SET withdrawn_at = now(), withdrawn_by_user_id = \(bind: user), content_revision = 2
                WHERE message_id = \(bind: newer)
                """).run()
            guard case .snapshot(let fallback) = try await store.latestVisible(roomIDs: [id], actorUserID: actor)[id] else {
                Issue.record("fallback missing"); return
            }
            #expect(fallback.latest?.id == .init(uuid: older))
            #expect(try await store.latestVisible(roomIDs: [id], actorUserID: .init(uuid: UUID()))[id] == .unavailable)
            try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET membership_revision = 3 WHERE room_id = \(bind: room)").run()
            try await sql.raw("UPDATE \(unsafeRaw: schema).room_memberships SET joined_revision = 3 WHERE room_id = \(bind: room)").run()
            guard case .snapshot(let rejoined) = try await store.latestVisible(roomIDs: [id], actorUserID: actor)[id] else {
                Issue.record("rejoined snapshot missing"); return
            }
            #expect(rejoined.latest == nil)
            // A retained historical membership interval authorizes its own messages.
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_memberships(room_id, user_id, joined_revision, left_revision)
                VALUES (\(bind: room), \(bind: user), 1, 2)
                """).run()
            guard case .snapshot(let history) = try await store.latestVisible(roomIDs: [id], actorUserID: actor)[id] else {
                Issue.record("historical visibility missing"); return
            }
            #expect(history.latest?.id == .init(uuid: older))
        }
    }
}
