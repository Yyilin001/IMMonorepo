@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import Foundation
import IMV2Core
import SQLKit
import Testing

@Suite("Latest visible revision heads", .serialized)
struct PostgresV2RoomLatestVisibleRevisionHeadsTests {
    @Test("revision heads preserve sequence order, visibility, withdrawal and room head", arguments: ["message_row", "room_event", "mixed"])
    func revisionHeads(storage: String) async throws {
        try await withUserEventDatabase { db, sql, schema in
            let room = UUID(), user = UUID()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id,membership_revision,room_sequence)
                VALUES (\(bind: room),'room-a','standard',11,11)
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision,left_revision)
                VALUES (\(bind: room),\(bind: user),1,10),(\(bind: room),\(bind: user),11,NULL)
                """).run()
            // Deliberately do not assume that revision order implies message order.
            // 11 is invisible, 12 is beyond the captured head, 10 is withdrawn.
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).messages
                    (message_id,room_id,room_sequence,timeline_sequence,sender_user_id,client_message_id,
                     text_body,created_at,accepted_event_storage,accepted_event_id,accepted_membership_revision,
                     withdrawn_at,withdrawn_by_user_id)
                SELECT gen_random_uuid(),\(bind: room),n,n,\(bind: user),gen_random_uuid(),
                    'sequence-'||n::text,now(),'message_row',gen_random_uuid(),
                    CASE WHEN n=11 THEN 10 WHEN n IN (8,10,12) THEN 9 WHEN n=9 THEN 1 ELSE 3 END,
                    CASE WHEN n=10 THEN now() END,CASE WHEN n=10 THEN \(bind: user)::uuid END
                FROM generate_series(1,12) n
                """).run()
            if storage != "message_row" {
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).room_events
                        (event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at)
                    SELECT accepted_event_id,room_id,room_sequence,'message.accepted',
                        jsonb_build_object('message_id',message_id::text),accepted_membership_revision,created_at
                    FROM \(unsafeRaw: schema).messages
                    WHERE \(bind: storage)='room_event' OR room_sequence%2=0
                    """).run()
                try await sql.raw("""
                    UPDATE \(unsafeRaw: schema).messages SET accepted_event_storage='room_event',
                        accepted_event_id=NULL,accepted_membership_revision=NULL
                    WHERE \(bind: storage)='room_event' OR room_sequence%2=0
                    """).run()
            }
            let store = try PostgresV2RoomLatestVisibleStore(database: db, schema: schema)
            func latest() async throws -> V2RoomLatestVisible {
                let result = try await store.latestVisible(roomIDs: [.init(uuid: room)], actorUserID: .init(uuid: user))
                guard case .snapshot(let snapshot)? = result[.init(uuid: room)] else {
                    throw V2RoomRecoveryReadError.corruptPersistence
                }
                return snapshot
            }
            #expect(try await latest().latest?.sequence == 9)
            try await sql.raw("UPDATE \(unsafeRaw: schema).messages SET withdrawn_at=now(),withdrawn_by_user_id=\(bind: user) WHERE room_sequence=9").run()
            #expect(try await latest().latest?.sequence == 8)
            try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence=7 WHERE room_id=\(bind: room)").run()
            #expect(try await latest().latest?.sequence == 7)
            try await sql.raw("DELETE FROM \(unsafeRaw: schema).room_memberships WHERE room_id=\(bind: room) AND joined_revision=1").run()
            #expect(try await latest().latest == nil)
            let outsider = try await store.latestVisible(roomIDs: [.init(uuid: room)], actorUserID: .init(uuid: UUID()))
            #expect(outsider[.init(uuid: room)] == .unavailable)
        }
    }
}
