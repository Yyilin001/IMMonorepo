@testable import IMV2ServerInfrastructure
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("retention bounds batches across rooms and tied sequences while preserving protected bodies")
    func roomLogRetentionUsesBoundedEventBatches() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let rooms = [
                UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000001")!,
                UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000002")!,
            ]
            for room in rooms {
                let user = UUID()
                try await insertSummaryFixtureRoom(on: sql, room: room, kind: "group",
                    sequence: 6, revision: 1, lastEventAt: now, createdAt: now)
                try await insertSummaryFixtureMembership(on: sql, room: room, user: user,
                    joined: 1, left: nil)
                try await insertSummaryFixtureReadReceipt(on: sql, room: room, user: user,
                    readThrough: 4, at: now)
                for sequence in 1...6 {
                    let event = UUID(), message = UUID()
                    try await sql.raw("""
                        INSERT INTO im_v2.room_events
                            (event_id, room_id, room_sequence, event_type, actor_user_id,
                             payload, committed_membership_revision, created_at)
                        VALUES (\(bind: event), \(bind: room), \(bind: sequence), 'message.accepted',
                            \(bind: user), jsonb_build_object('event_type', 'message.accepted',
                                'room_id', \(bind: room.uuidString.lowercased()),
                                'message_id', \(bind: message.uuidString.lowercased()),
                                'message_revision', 1, 'is_withdrawn', false), 1, \(bind: now))
                        """).run()
                    // One body in the deletion range, one exactly at the protected floor.
                    if sequence == 1 || sequence == 4 {
                        try await sql.raw("""
                            INSERT INTO im_v2.message_projection_states
                                (state_id, message_id, room_id, message_revision, variant_key,
                                 origin_event_id, state_event_id, is_withdrawn,
                                 payload_schema_version, payload, created_at, payload_storage)
                            VALUES (\(bind: UUID()), \(bind: message), \(bind: room), 1, 0,
                                \(bind: event), \(bind: event), false, 1, NULL, \(bind: now), 'room_event')
                            """).run()
                    }
                }
                if room == rooms[0] {
                    // The schema permits distinct event types at the same sequence.
                    // More than one batch shares sequence 1, so advancing the floor
                    // must not prevent the remaining rows from being reclaimed.
                    for type in ["room.title.changed", "room.member.joined", "room.member.left"] {
                        try await sql.raw("""
                            INSERT INTO im_v2.room_events
                                (event_id, room_id, room_sequence, event_type, payload,
                                 committed_membership_revision, created_at)
                            VALUES (\(bind: UUID()), \(bind: room), 1, \(bind: type), '{}', 1, \(bind: now))
                            """).run()
                    }
                }
            }
            let store = V2RoomLogRetentionTestDriver(database: database, eventLimit: 2)
            var deletedEvents = 0
            for _ in 0..<5 {
                let report = try await store.trimRoomLogs(mode: .permanent,
                    window: 3600, now: now, limit: 100)
                #expect((1...2).contains(report.deletedEvents))
                deletedEvents += report.deletedEvents
                for room in rooms {
                    let floor = try #require(try await sql.raw("""
                        SELECT log_trimmed_through_room_sequence AS value FROM im_v2.rooms
                        WHERE room_id = \(bind: room)
                        """).first(decoding: CountRow.self))
                    #expect(floor.value <= 4)
                }
            }
            #expect(deletedEvents == 9)
            for room in rooms {
                #expect(try await sql.raw("""
                    SELECT log_trimmed_through_room_sequence AS value FROM im_v2.rooms
                    WHERE room_id = \(bind: room)
                    """).first(decoding: CountRow.self)?.value == 4)
                #expect(try await sql.raw("""
                    SELECT count(*) AS value FROM im_v2.room_events WHERE room_id = \(bind: room)
                    """).first(decoding: CountRow.self)?.value == 3)
                #expect(try await sql.raw("""
                    SELECT count(*) AS value FROM im_v2.message_projection_states
                    WHERE room_id = \(bind: room) AND payload_storage = 'inline' AND payload IS NOT NULL
                    """).first(decoding: CountRow.self)?.value == 1)
                #expect(try await sql.raw("""
                    SELECT count(*) AS value FROM im_v2.message_projection_states
                    WHERE room_id = \(bind: room) AND payload_storage = 'room_event'
                    """).first(decoding: CountRow.self)?.value == 1)
                #expect(try await sql.raw("""
                    SELECT count(*) AS value FROM im_v2.message_projection_state_values
                    WHERE room_id = \(bind: room)
                    """).first(decoding: CountRow.self)?.value == 2)
            }
            let finished = try await store.trimRoomLogs(mode: .permanent,
                window: 3600, now: now, limit: 100)
            #expect(finished.deletedEvents == 0 && finished.trimmedRooms == 0)
        }
    }
}
