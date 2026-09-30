@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import Foundation
import IMV2Core
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("summary edit audiences survive actual room-log retention",
          arguments: [false, true], [false, true])
    func latestVisibleSurvivesLogRetention(hiddenLatest: Bool, eventBeforeBody: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let user = UUID(), room = UUID(), message = UUID()
            try await insertSummaryFixtureRoom(on: sql, room: room, kind: "group", sequence: 4,
                revision: hiddenLatest ? 3 : 1, lastEventAt: now, createdAt: now)
            try await insertSummaryFixtureMembership(on: sql, room: room, user: user,
                joined: 1, left: hiddenLatest ? 2 : nil)
            if hiddenLatest {
                try await insertSummaryFixtureMembership(on: sql, room: room, user: user, joined: 3, left: nil)
            }
            try await sql.raw("""
                INSERT INTO im_v2.messages
                    (message_id,room_id,room_sequence,timeline_sequence,sender_user_id,client_message_id,
                     text_body,created_at,accepted_event_storage,accepted_event_id,accepted_membership_revision)
                VALUES (\(bind: message),\(bind: room),1,1,\(bind: user),\(bind: UUID()),
                        'original revision',\(bind: now),'message_row',\(bind: UUID()),1)
                """).run()
            for revision in 2...3 {
                let text = revision == 2 ? "authorized revision two"
                    : (hiddenLatest ? "secret during membership gap" : "authorized revision three")
                let update: SQLQueryString = """
                    UPDATE im_v2.messages SET text_body=\(bind: text),content_revision=\(bind: revision)
                    WHERE message_id=\(bind: message)
                    """
                let insert: SQLQueryString = """
                    INSERT INTO im_v2.room_events
                        (event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at)
                    VALUES (\(bind: UUID()),\(bind: room),\(bind: revision),'message.edited',
                        jsonb_build_object('message_id',\(bind: message.uuidString)::text,
                            'room_id',\(bind: room.uuidString)::text,'message_revision',\(bind: revision)),
                        \(bind: revision == 3 && hiddenLatest ? 2 : 1),\(bind: now))
                    """
                // Producer ordering does not change the immutable grant facts:
                // the event trigger never consults the mutable current body.
                try await database.transaction { transaction in
                    let writer = try #require(transaction as? any SQLDatabase)
                    if eventBeforeBody {
                        try await writer.raw(insert).run()
                        try await writer.raw(update).run()
                    } else {
                        try await writer.raw(update).run()
                        try await writer.raw(insert).run()
                    }
                }
            }
            let store = try PostgresV2RoomLatestVisibleStore(database: database)
            let roomID = RoomID(uuid: room), actor = UserID(uuid: user)
            guard case .snapshot(let before)? = try await store.latestVisible(roomIDs: [roomID], actorUserID: actor)[roomID] else {
                Issue.record("missing summary before retention"); return
            }
            #expect(before.latest?.revision == (hiddenLatest ? 2 : 3))
            #expect(before.latest?.preview == (hiddenLatest ? "authorized revision two" : "authorized revision three"))
            try await insertSummaryFixtureReadReceipt(on: sql, room: room, user: user, readThrough: 4, at: now)
            let retention = PostgresV2RoomLogRetentionStore(database: database)
            let report = try await retention.trimRoomLogs(mode: .permanent, window: 3600, now: now, limit: 100)
            #expect(report.trimmedRooms == 1 && report.deletedEvents == 2)
            #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.room_events WHERE room_id=\(bind: room)").first(decoding: CountRow.self)?.value == 0)
            #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.message_edit_visibility WHERE message_id=\(bind: message)").first(decoding: CountRow.self)?.value == 2)
            guard case .snapshot(let after)? = try await store.latestVisible(roomIDs: [roomID], actorUserID: actor)[roomID] else {
                Issue.record("missing summary after retention"); return
            }
            #expect(after == before)
            await #expect(throws: (any Error).self) {
                try await sql.raw("UPDATE im_v2.message_edit_visibility SET committed_membership_revision=99 WHERE message_id=\(bind: message)").run()
            }
            await #expect(throws: (any Error).self) {
                try await sql.raw("DELETE FROM im_v2.message_edit_visibility WHERE message_id=\(bind: message)").run()
            }
        }
    }
}
