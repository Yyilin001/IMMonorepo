import Foundation
import FluentKit
import IMV2Core
@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("Plain direct append skips empty event statements and preserves divergent events and realtime heads",
          arguments: ["aligned", "diverged", "mixed"])
    func plainDirectEventStatementSelection(mode: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { _, owner, _, sql, _ in
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let journal = try String(contentsOf: root.appending(path: "IMV2/sql/realtime-change-journal.sql"), encoding: .utf8)
            for statement in postgresStatements(in: journal) where !statement.isEmpty && statement != "BEGIN" && statement != "COMMIT" {
                try await sql.raw("\(unsafeRaw: statement)").run()
            }
            try await sql.raw("CREATE TABLE im_v2.test_event_statements (inserted_rows bigint NOT NULL)").run()
            try await sql.raw("""
                CREATE FUNCTION im_v2.test_capture_event_statement() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    INSERT INTO im_v2.test_event_statements SELECT count(*) FROM test_new_events;
                    RETURN NULL;
                END $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER test_capture_event_statement AFTER INSERT ON im_v2.room_events
                REFERENCING NEW TABLE AS test_new_events FOR EACH STATEMENT
                EXECUTE FUNCTION im_v2.test_capture_event_statement()
                """).run()
            let now = Date(), fingerprint = try V2SendMessageFingerprint(version: 3, digest: Data(repeating: 7, count: 32))
            var inputs: [PlainRoomLogMessageInput] = []
            for ordinal in 0..<2 {
                let room = UUID(), diverged = mode == "diverged" || (mode == "mixed" && ordinal == 1)
                try await insertSummaryFixtureRoom(on: sql, room: room, kind: "direct", sequence: 10,
                    revision: 1, lastEventAt: now, createdAt: now)
                try await sql.raw("UPDATE im_v2.rooms SET timeline_sequence=\(bind: diverged ? 9 : 10) WHERE room_id=\(bind: room)").run()
                inputs.append(.init(ordinal: ordinal, roomID: room, messageID: UUID(), eventID: UUID(),
                    senderID: senderUUID, clientMessageID: UUID(), persistsRoomAdmission: false,
                    roomSequence: 11, timelineSequence: diverged ? 10 : 11, commandWindowUsed: 0,
                    text: "event selection \(ordinal)", entities: [], replyToMessageID: nil,
                    forwardedFromMessageID: nil, forwardedFromUserID: nil, membershipRevision: 1,
                    fingerprint: fingerprint, createdAtPostgresMicroseconds: 1_000_000,
                    runtimeGuard: .init(capacityProfileID: "standard"), directRecipientID: memberTwoUUID))
            }
            let batch = inputs
            try await v2WithRoomActivationTransaction(database: owner, deadline: .now + .seconds(5)) { borrowed in
                try await PlainDirectRoomLogBatchWritePath.persist(inputs: batch, sql: borrowed as! any SQLDatabase)
            }
            struct Statement: Decodable { let inserted_rows: Int64 }
            let statements = try await sql.raw("SELECT inserted_rows FROM im_v2.test_event_statements").all(decoding: Statement.self)
            #expect(statements.map(\.inserted_rows) == (mode == "aligned" ? [] : [mode == "mixed" ? 1 : 2]))
            struct Stored: Decodable {
                let storage: String, message_event: UUID?, completion_event: UUID, persisted_event: UUID?
                let fingerprint: Data, room_sequence: Int64, timeline_sequence: Int64, head_sequence: Int64
            }
            for input in batch {
                let stored = try #require(try await sql.raw("""
                    SELECT m.accepted_event_storage AS storage, m.accepted_event_id AS message_event,
                           c.event_id AS completion_event, e.event_id AS persisted_event,
                           c.request_fingerprint AS fingerprint, r.room_sequence, r.timeline_sequence,
                           h.room_sequence AS head_sequence
                    FROM im_v2.messages m JOIN im_v2.message_send_completions c USING(message_id)
                    JOIN im_v2.rooms r ON r.room_id=m.room_id
                    JOIN im_v2.realtime_dirty_room_heads h ON h.room_id=m.room_id
                    LEFT JOIN im_v2.room_events e ON e.event_id=c.event_id
                    WHERE m.message_id=\(bind: input.messageID)
                    """).first(decoding: Stored.self))
                let aligned = input.roomSequence == input.timelineSequence
                #expect(stored.storage == (aligned ? "message_row" : "room_event"))
                #expect(stored.message_event == (aligned ? input.eventID : nil))
                #expect(stored.persisted_event == (aligned ? nil : input.eventID))
                #expect(stored.completion_event == input.eventID)
                #expect(stored.fingerprint == fingerprint.digest)
                #expect(stored.room_sequence == input.roomSequence)
                #expect(stored.timeline_sequence == input.timelineSequence)
                #expect(stored.head_sequence == input.roomSequence)
            }
        }
    }

    @Test("Typed message inputs preserve full batches, binary fingerprints, text, entities and microseconds")
    func typedPlainDirectMessageInputs() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, _, sql, _ in
            let profile = try forwardImportTestProfile(), now = Date()
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '10 minutes',command_window_limit=1000").run()
            let opened = try await V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner,
                identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: profile, roomShardID: "room-b", now: { now }).openedIdentity(actorUserID: senderID,
                    operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                    firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            let roomID = try #require(opened.roomID.uuidValue)
            try await sql.raw("UPDATE im_v2.room_admission SET command_window_limit=0,command_window_used=0 WHERE room_id=\(bind: roomID)").run()
            struct State: Decodable { let room_sequence: Int64, timeline_sequence: Int64, membership_revision: Int64, command_window_used: Int }
            let initial = try #require(try await sql.raw("""
                SELECT r.room_sequence,r.timeline_sequence,r.membership_revision,a.command_window_used
                FROM im_v2.rooms r JOIN im_v2.room_admission a USING(room_id) WHERE r.room_id=\(bind: roomID)
                """).first(decoding: State.self))
            let fingerprint = try V2SendMessageFingerprint(version: 3, digest: Data((0..<32).map { UInt8($0 * 8) }))
            let entities = [try V2MessageEntity(offsetUTF16: 0, lengthUTF16: 2, kind: .bold)]
            let inputs = (0..<256).map { i in
                PlainRoomLogMessageInput(ordinal: i, roomID: roomID, messageID: UUID(), eventID: UUID(),
                    senderID: senderUUID, clientMessageID: UUID(), persistsRoomAdmission: true,
                    roomSequence: initial.room_sequence + Int64(i + 1), timelineSequence: initial.timeline_sequence + Int64(i + 1),
                    commandWindowUsed: initial.command_window_used + i + 1,
                    text: "你好 ' \\ ; -- \n 🚀 \(i)", entities: i.isMultiple(of: 2) ? entities : [],
                    replyToMessageID: nil, forwardedFromMessageID: nil, forwardedFromUserID: nil,
                    membershipRevision: initial.membership_revision, fingerprint: fingerprint,
                    createdAtPostgresMicroseconds: Int64(i - 128), directRecipientID: memberTwoUUID)
            }
            try await v2WithRoomActivationTransaction(database: owner, deadline: .now + .seconds(5)) { borrowed in
                try await PlainDirectRoomLogBatchWritePath.persist(inputs: inputs, sql: borrowed as! any SQLDatabase)
            }
            struct Stored: Decodable {
                let text_body: String, entities: String, fingerprint: Data, micros: Int64
            }
            let stored = try await sql.raw("""
                SELECT m.text_body,m.rich_entities::text AS entities,c.request_fingerprint AS fingerprint,
                       (extract(epoch FROM (m.created_at-TIMESTAMPTZ '2000-01-01 00:00:00+00'))*1000000)::bigint AS micros
                FROM im_v2.messages m JOIN im_v2.message_send_completions c USING(message_id)
                WHERE m.room_id=\(bind: roomID) ORDER BY m.room_sequence
                """).all(decoding: Stored.self)
            #expect(stored.count == inputs.count)
            for (row, input) in zip(stored, inputs) {
                #expect(row.text_body == input.text)
                #expect(row.fingerprint == input.fingerprint.digest)
                #expect(row.micros == input.createdAtPostgresMicroseconds)
                #expect(try JSONDecoder().decode([V2MessageEntity].self, from: Data(row.entities.utf8)) == input.entities)
            }
            struct Sequence: Decodable { let value: Int64 }
            let finalSequence = try #require(try await sql.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: roomID)").first(decoding: Sequence.self)).value
            #expect(finalSequence == initial.room_sequence + 256)
            #expect(try await sql.raw("SELECT command_window_used::bigint AS value FROM im_v2.room_admission WHERE room_id=\(bind: roomID)").first(decoding: Sequence.self)?.value == 0)
            await #expect(throws: (any Error).self) {
                try await v2WithRoomActivationTransaction(database: owner, deadline: .now + .seconds(5)) { borrowed in
                    try await PlainDirectRoomLogBatchWritePath.persist(inputs: inputs, sql: borrowed as! any SQLDatabase)
                }
            }
            #expect(try await sql.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: roomID)").first(decoding: Sequence.self)?.value == finalSequence)
        }
    }
}
