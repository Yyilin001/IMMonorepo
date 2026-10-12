@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import IMV2ActorContracts
import IMV2ActorRuntime
import Synchronization
import SQLKit
import Testing
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("bounded mixed-source pages consume invisible windows without skipping later visible events", arguments: [1, 3, 5])
    func boundedRoomLogPagination(pageSize: Int) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            try await seedBoundedLog(count: 20, messageEvery: 2, on: sql)
            // Rejoined viewer: [0,1) and [2,infinity); events 6...15 occurred while absent.
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=1 WHERE room_id=\(bind: roomUUID) AND user_id=\(bind: memberTwoUUID)").run()
            try await sql.raw("INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision) VALUES(\(bind: roomUUID),\(bind: memberTwoUUID),2)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision=2,room_sequence=25,log_trimmed_through_room_sequence=1 WHERE room_id=\(bind: roomUUID)").run()
            // Accepted membership revisions are immutable, so seedBoundedLog creates the same intervals.
            // Withdrawal must not remove the original accepted event from the candidate index.
            try await sql.raw("UPDATE im_v2.messages SET withdrawn_at=clock_timestamp(),withdrawn_by_user_id=\(bind: senderUUID) WHERE room_id=\(bind: roomUUID) AND room_sequence=20").run()
            let reader = PostgresV2GroupEventLogStore(database: database)
            var cursor: UInt64 = 0
            var sequences: [UInt64] = []
            var emptyContinuations = 0
            for _ in 0..<30 {
                let page = try await reader.pull(roomID: roomID, actorUserID: .init(uuid: memberTwoUUID), afterRoomSequence: cursor, pageSize: pageSize)
                #expect(page.events.count <= pageSize)
                #expect(page.logTrimmedThroughRoomSequence == 1)
                #expect(page.nextRoomSequence > cursor)
                #expect(page.events.allSatisfy { $0.roomSequence > cursor && $0.roomSequence <= page.nextRoomSequence })
                if page.hasMore {
                    // Hidden rows count towards the same budget as visible rows.
                    #expect(page.nextRoomSequence == cursor + UInt64(pageSize))
                    if page.events.isEmpty { emptyContinuations += 1 }
                }
                sequences += page.events.map(\.roomSequence)
                cursor = page.nextRoomSequence
                if !page.hasMore { break }
            }
            #expect(sequences == Array(UInt64(1)...5) + Array(UInt64(16)...20))
            #expect(emptyContinuations > 0)
            #expect(cursor == 25) // exhausted sources consume the trailing sequence gap
            let end = try await reader.pull(roomID: roomID, actorUserID: senderID, afterRoomSequence: 25, pageSize: pageSize)
            #expect(end.events.isEmpty && !end.hasMore && end.nextRoomSequence == 25)
            let beyond = try await reader.pull(roomID: roomID, actorUserID: senderID, afterRoomSequence: 30, pageSize: pageSize)
            #expect(beyond.events.isEmpty && !beyond.hasMore && beyond.nextRoomSequence == 30)
            await #expect(throws: V2GroupEventLogError.actorNotMember) {
                try await reader.pull(roomID: roomID, actorUserID: .init(uuid: UUID()), afterRoomSequence: 0, pageSize: pageSize)
            }
            // Inject corrupt persisted data explicitly; current writes reject this payload.
            try await sql.raw("ALTER TABLE im_v2.room_events DISABLE TRIGGER room_events_capture_message_edit_visibility").run()
            try await sql.raw("INSERT INTO im_v2.room_events(event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at) VALUES(gen_random_uuid(),\(bind: roomUUID),26,'message.edited',jsonb_build_object('message_id',gen_random_uuid()::text),2,clock_timestamp())").run()
            try await sql.raw("ALTER TABLE im_v2.room_events ENABLE TRIGGER room_events_capture_message_edit_visibility").run()
            try await sql.raw("UPDATE im_v2.rooms SET room_sequence=26 WHERE room_id=\(bind: roomUUID)").run()
            let beforeCorruption = try await reader.pull(roomID: roomID, actorUserID: senderID, afterRoomSequence: 19, pageSize: 1)
            #expect(beforeCorruption.events.map(\.roomSequence) == [20])
            #expect(beforeCorruption.nextRoomSequence == 20 && beforeCorruption.hasMore)
            await #expect(throws: V2GroupEventLogError.corruptPersistenceState) {
                try await reader.pull(roomID: roomID, actorUserID: senderID, afterRoomSequence: 25, pageSize: pageSize)
            }
        }
    }

    @Test("actual room-log SQL bounds scans at first and middle pages despite sparse message-row storage", arguments: [1_000, 50_000])
    func boundedRoomLogQueryCost(count: Int) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            try await seedBoundedLog(count: count, messageEvery: 100, on: sql)
            try await sql.raw("ANALYZE im_v2.messages").run()
            try await sql.raw("ANALYZE im_v2.room_events").run()
            try await sql.raw("ANALYZE im_v2.room_memberships").run()
            let recorder = RecoveryQueryRecorder(database: database, sql: sql)
            let reader = PostgresV2GroupEventLogStore(database: recorder)
            for cursor in [UInt64(0), UInt64(count / 2)] {
                let page = try await reader.pull(roomID: roomID, actorUserID: senderID, afterRoomSequence: cursor, pageSize: 100)
                #expect(page.events.map(\.roomSequence) == Array((cursor + 1)...(cursor + 100)))
                #expect(page.nextRoomSequence == cursor + 100 && page.hasMore)
            }
            #expect(recorder.snapshot().queries.count == 2)
            for query in recorder.snapshot().queries {
                let plan = try await sql.raw("\(BoundedLogExplain(query: query))").all()
                    .map { try $0.decode(column: "QUERY PLAN", as: String.self) }.joined(separator: "\n")
                #expect(plan.contains("messages_room_log_candidates_idx"))
                #expect(!plan.contains("Seq Scan on messages") && !plan.contains("Seq Scan on room_events"))
                // Check executed tuple counts, not planner estimates or SQL text.
                let scans = plan.split(separator: "\n").filter { $0.contains("Scan") && ($0.contains(" on messages ") || $0.contains(" on room_events ")) }
                #expect(!scans.isEmpty)
                let actualRows = try NSRegularExpression(pattern: #"actual time=[^)]* rows=(\d+) loops=(\d+)"#)
                for scan in scans {
                    let line = String(scan)
                    let match = try #require(actualRows.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)))
                    let range = try #require(Range(match.range(at: 1), in: line))
                    #expect(try #require(Int(line[range])) <= 101, "Unbounded source scan: \(line)")
                }
                #expect(!plan.contains("Filter: (accepted_event_storage"), "Storage mode must be resolved by the partial index")
                print("BOUNDED_ROOM_LOG_PLAN history=\(count) pageSize=100\n\(plan)")
            }
        }
    }

    @Test("same-room send gets its turn after one bounded historical page", arguments: [1_000, 50_000])
    func boundedRoomLogSendWait(count: Int) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            try await seedBoundedLog(count: count, messageEvery: 100, on: sql)
            try await sql.raw("ANALYZE im_v2.messages").run()
            try await sql.raw("ANALYZE im_v2.room_events").run()
            try await withRoomActivation(database: database, roomID: roomID) { token in
                let queries = V2ActorRoomQueryExecutor(database: database)
                let base = Date(timeIntervalSince1970: 1_750_000_000)
                let writes = V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                    store: PostgresV2RoomWriteStore(database: database), shardID: "room-a", epoch: 0,
                    activationToken: token)
                let sender = try V2SendMessageService(store: writes, capacityProfile: forwardImportTestProfile(),
                    limits: .init(maxUTF8Bytes: 64), now: { base })
                let config = try V2RoomRuntimeConfiguration()
                let budget = V2RoomCommandBudget(configuration: config)
                let started = Mutex<ContinuousClock.Instant?>(nil)
                let lane = V2RoomTurnLane<BoundedLogTurn, UInt64>(token: token,
                    configuration: config, budget: budget, classify: { $0 == .send ? .send : .barrier },
                    execute: { turn in
                        do {
                            var results: [UInt64] = []
                            for item in turn.items {
                                switch item.request {
                                case .read:
                                    started.withLock { $0 = .now }
                                    let wire = try V2ActorRoomLogPullWire(roomID: roomID, actorUserID: senderID, afterRoomSequence: 0, pageSize: 100)
                                    guard case .page(let page) = try await queries.log(.pull(wire), token: token) else {
                                        Issue.record("expected log page"); return .rolledBack(.invalidRequest)
                                    }
                                    #expect(page.events.count == 100 && page.hasMore)
                                    results.append(page.nextRoomSequence)
                                case .send:
                                    let began = try #require(started.withLock { $0 })
                                    let wait = began.duration(to: .now)
                                    guard case .accepted(let accepted) = try await sender.send(.init(roomID: roomID, actorUserID: senderID,
                                        clientMessageID: .init(uuid: UUID()), text: "after historical read")) else {
                                        Issue.record("expected accepted send"); return .rolledBack(.invalidRequest)
                                    }
                                    print("BOUNDED_ROOM_LOG_SEND history=\(count) readTurnWait=\(wait) readAndSend=\(began.duration(to: .now))")
                                    results.append(accepted.roomSequence)
                                }
                            }
                            return .committed(results)
                        } catch {
                            Issue.record(error)
                            return .outcomeUnknown
                        }
                    }, onUncertain: { _ in })
                // Hold dispatch only while queuing a read followed by a send. Timing
                // starts inside the real read turn and excludes this synchronization.
                let reservation = try await lane.reserve(requestID: UUID(), deadline: .now + .seconds(10))
                let read = Task { try await lane.submit(request: BoundedLogTurn.read, deadline: .now + .seconds(10)) }
                let queueDeadline = ContinuousClock.now + .seconds(5)
                while await lane.snapshot().queuedCount < 1, ContinuousClock.now < queueDeadline { await Task.yield() }
                #expect(await lane.snapshot().queuedCount == 1)
                let send = Task { try await lane.submit(request: BoundedLogTurn.send, deadline: .now + .seconds(10)) }
                while await lane.snapshot().queuedCount < 2, ContinuousClock.now < queueDeadline { await Task.yield() }
                #expect(await lane.snapshot().queuedCount == 2)
                #expect(await lane.abortReservation(reservation))
                let readResult = await read.result, sendResult = await send.result
                await lane.beginDrain()
                #expect(try readResult.get() == 100)
                #expect(try sendResult.get() == UInt64(count + 1))
            }
        }
    }

    @Test("room-log candidate index rejects a broad or withdrawal-filtered replacement")
    func currentSchemaRequiresRoomLogCandidateIndex() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let schema = "im_v2"
            try await V2SchemaReadiness.verify(database: database, schema: schema)
            for predicate in ["TRUE", "accepted_event_storage = 'message_row' AND withdrawn_at IS NULL"] {
                try await sql.raw("DROP INDEX \(unsafeRaw: schema).messages_room_log_candidates_idx").run()
                try await sql.raw("CREATE INDEX messages_room_log_candidates_idx ON \(unsafeRaw: schema).messages(room_id, timeline_sequence) WHERE \(unsafeRaw: predicate)").run()
                await #expect(throws: V2SchemaReadinessError.unavailableTable(schema + ".rooms[activity-contract]")) {
                    try await V2SchemaReadiness.verify(database: database, schema: schema)
                }
            }
            try await sql.raw("DROP INDEX \(unsafeRaw: schema).messages_room_log_candidates_idx").run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable(schema + ".rooms[activity-contract]")) {
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
            try await sql.raw("CREATE INDEX messages_room_log_candidates_idx ON \(unsafeRaw: schema).messages(room_id, timeline_sequence) WHERE accepted_event_storage = 'message_row'").run()
            try await V2SchemaReadiness.verify(database: database, schema: schema)
        }
    }

    private func seedBoundedLog(count: Int, messageEvery: Int, on sql: any SQLDatabase) async throws {
        try await sql.raw("UPDATE im_v2.rooms SET room_sequence=\(bind: count),timeline_sequence=\(bind: count),membership_revision=2 WHERE room_id=\(bind: roomUUID)").run()
        // Every sequence has a message row, but only a sparse subset is a log source.
        // A broad index would scan the other storage mode before finding its limit.
        try await sql.raw("""
            INSERT INTO im_v2.messages(message_id,room_id,room_sequence,timeline_sequence,sender_user_id,
                client_message_id,text_body,created_at,accepted_event_storage,accepted_event_id,accepted_membership_revision)
            SELECT gen_random_uuid(),\(bind: roomUUID),n,n,\(bind: senderUUID),gen_random_uuid(),'original',clock_timestamp(),
                CASE WHEN n % \(bind: messageEvery)=0 THEN 'message_row' ELSE 'room_event' END,
                CASE WHEN n % \(bind: messageEvery)=0 THEN gen_random_uuid() END,
                CASE WHEN n % \(bind: messageEvery)=0 THEN CASE WHEN n BETWEEN 6 AND 15 THEN 1 ELSE 2 END END
            FROM generate_series(1,\(bind: count)) n
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.room_events(event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at)
            SELECT gen_random_uuid(),\(bind: roomUUID),n,'group.nickname_changed',
                jsonb_build_object('event_type','group.nickname_changed','room_sequence',n),
                CASE WHEN n BETWEEN 6 AND 15 THEN 1 ELSE 2 END,clock_timestamp()
            FROM generate_series(1,\(bind: count)) n WHERE n % \(bind: messageEvery) <> 0
            """).run()
    }
}

private struct BoundedLogExplain: SQLExpression {
    let query: any SQLExpression
    func serialize(to serializer: inout SQLSerializer) {
        serializer.write("EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) ")
        query.serialize(to: &serializer)
    }
}

private enum BoundedLogTurn: String, Codable, Sendable { case read, send }
