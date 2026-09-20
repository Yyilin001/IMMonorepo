import Foundation
@testable import IMV2Server
import SQLKit
import Testing

/// Measures the incremental row/index write path, not full message-command throughput.
@Suite("Room summary index write cost", .serialized)
struct PostgresV2RoomSummaryIndexCostTests {
    @Test(arguments: ["message_row", "room_event"], [false, true])
    func bulkAcceptance(storage: String, indexed: Bool) async throws {
        try await withUserEventDatabase { _, sql, schema in
            let room = UUID(), sender = UUID()
            if !indexed {
                try await sql.raw("DROP INDEX \(unsafeRaw: schema).messages_visible_membership_idx").run()
                try await sql.raw("DROP INDEX \(unsafeRaw: schema).room_events_accepted_membership_idx").run()
            }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id,membership_revision,room_sequence)
                VALUES (\(bind: room),'room-a','standard',1,10000)
                """).run()
            var statements: [(String, SQLQueryString)] = []
            if storage == "room_event" {
                statements.append(("events", """
                    INSERT INTO \(unsafeRaw: schema).room_events
                        (event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at)
                    SELECT gen_random_uuid(),\(bind: room),n,'message.accepted',
                        jsonb_build_object('message_id',('00000000-0000-0000-0000-' || lpad(n::text,12,'0'))),1,now()
                    FROM generate_series(1,10000) AS n
                    """))
            }
            statements.append(("messages", """
                INSERT INTO \(unsafeRaw: schema).messages
                    (message_id,room_id,room_sequence,timeline_sequence,sender_user_id,client_message_id,
                     text_body,created_at,accepted_event_storage,accepted_event_id,accepted_membership_revision)
                SELECT ('00000000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid,
                    \(bind: room),n,n,\(bind: sender),gen_random_uuid(),'index-write-cost',now(),\(bind: storage),
                    CASE WHEN \(bind: storage) = 'message_row' THEN gen_random_uuid() ELSE NULL END,
                    CASE WHEN \(bind: storage) = 'message_row' THEN 1 ELSE NULL END
                FROM generate_series(1,10000) AS n
                """))
            for (name, statement) in statements {
                let plan = try await sql.raw("EXPLAIN (ANALYZE, BUFFERS, WAL, FORMAT TEXT) \(statement)").all()
                    .map { try $0.decode(column: "QUERY PLAN", as: String.self) }.joined(separator: "\n")
                print("ROOM_SUMMARY_INDEX_WRITE storage=\(storage) indexed=\(indexed) path=\(name) rows=10000\n\(plan)")
            }
            let count = try await sql.raw("SELECT count(*) AS value FROM \(unsafeRaw: schema).messages").first()?.decode(column: "value", as: Int64.self)
            #expect(count == 10000)
            if indexed {
                for index in ["messages_visible_membership_idx", "room_events_accepted_membership_idx"] {
                    let size = try await sql.raw("SELECT pg_relation_size(\(bind: schema + "." + index)::regclass) AS value").first()?.decode(column: "value", as: Int64.self)
                    print("ROOM_SUMMARY_INDEX_SIZE storage=\(storage) index=\(index) bytes=\(try #require(size))")
                }
            }
        }
    }
}
