import FluentKit
import Foundation
import IMV2Core
import NIOCore
import SQLKit
import Synchronization
import Testing
@testable import IMV2Server

@Suite("Room recovery production query cost", .serialized)
struct PostgresV2RoomRecoveryQueryCostTests {
    @Test("cold, hot, sparse and broad memberships use actual bounded directory/state reads")
    func mixedMembershipQueries() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let users = (0..<4).map { _ in UUID() }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).rooms
                    (room_id, room_shard_id, capacity_profile_id, membership_revision, room_sequence, last_event_at)
                SELECT ('00000000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid,
                    'room-a','standard',1,0,TIMESTAMPTZ '2026-01-01' + n * INTERVAL '1 second'
                FROM generate_series(1,10000) AS n
                """).run()
            for (index, user) in users.enumerated() {
                let predicate: SQLQueryString
                switch index {
                case 0: predicate = "n <= 200"
                case 1: predicate = "n > 9800"
                case 2: predicate = "n % 50 = 0"
                default: predicate = "TRUE"
                }
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision)
                    SELECT ('00000000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid,\(bind: user),1
                    FROM generate_series(1,10000) AS n WHERE \(predicate)
                    """).run()
            }
            try await sql.raw("ANALYZE \(unsafeRaw: schema).rooms").run()
            try await sql.raw("ANALYZE \(unsafeRaw: schema).room_memberships").run()
            let recorder = RecoveryQueryRecorder(database: database, sql: sql)
            let store = try PostgresV2RoomRecoveryStore(database: recorder, schema: schema)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (index, user) in users.enumerated() {
                    group.addTask {
                        let actor = UserID(uuid: user)
                        let first = try await store.rooms(actorUserID: actor, after: nil, limit: 100)
                        #expect(first.entries.count == 100)
                        let firstStates = try await store.states(roomIDs: first.entries.map(\.roomID), actorUserID: actor)
                        #expect(firstStates.count == 100)
                        let after = index == 3
                            ? RoomID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000005000")!)
                            : try #require(first.scannedThrough)
                        let next = try await store.rooms(actorUserID: actor, after: after, limit: 100)
                        #expect(next.entries.count == 100)
                        #expect(Set(first.entries.map(\.roomID)).isDisjoint(with: next.entries.map(\.roomID)))
                        let nextStates = try await store.states(roomIDs: next.entries.map(\.roomID), actorUserID: actor)
                        #expect(nextStates.count == 100)
                    }
                }
                try await group.waitForAll()
            }
            let captured = recorder.snapshot()
            #expect(captured.queries.count == 16)
            #expect(captured.active == 0)
            #expect(captured.peak <= 4)
            print("ROOM_RECOVERY_QUERY_COST users=4 rooms=10000 productionQueries=\(captured.queries.count) peakIssuedQueries=\(captured.peak)")
            // Re-execute precisely the captured production expressions and binds.
            // This is a warm-plan measurement; it does not claim cold disk cache
            // or that client-issued concurrency equals physical DB concurrency.
            for (index, query) in captured.queries.enumerated() {
                var serializer = SQLSerializer(database: sql)
                query.serialize(to: &serializer)
                #expect(!serializer.sql.contains("last_event_at"))
                let plan = try await sql.raw("\(RecoveryExplain(query: query))").all()
                    .map { try $0.decode(column: "QUERY PLAN", as: String.self) }.joined(separator: "\n")
                #expect(!plan.contains("Seq Scan on rooms"), "A bounded directory page scanned the whole room table")
                #expect(!plan.contains("Seq Scan on room_memberships"), "A bounded state batch scanned all memberships")
                print("ROOM_RECOVERY_QUERY_PLAN index=\(index)\n\(plan)")
            }
        }
    }
}

private struct RecoveryExplain: SQLExpression {
    let query: any SQLExpression
    func serialize(to serializer: inout SQLSerializer) {
        serializer.write("EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) ")
        query.serialize(to: &serializer)
    }
}

/// A forwarding SQL boundary: every captured query still executes against the
/// real database. Mutex ownership covers counts and captured Sendable expressions.
final class RecoveryQueryRecorder: Database, SQLDatabase, Sendable {
    struct Capture: Sendable {
        var queries: [any SQLExpression] = []
        var active = 0
        var peak = 0
    }
    let database: any Database
    let sql: any SQLDatabase
    private let capture = Mutex(Capture())
    var context: DatabaseContext { database.context }
    var dialect: any SQLDialect { sql.dialect }
    var inTransaction: Bool { database.inTransaction }
    init(database: any Database, sql: any SQLDatabase) {
        self.database = database; self.sql = sql
    }
    func snapshot() -> Capture { capture.withLock { $0 } }
    func execute(sql query: any SQLExpression, _ onRow: @escaping @Sendable (any SQLRow) -> Void) -> EventLoopFuture<Void> {
        capture.withLock {
            $0.queries.append(query); $0.active += 1; $0.peak = max($0.peak, $0.active)
        }
        let result = sql.execute(sql: query, onRow)
        return result.always { _ in self.capture.withLock { $0.active -= 1 } }
    }
    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        database.transaction(closure)
    }
    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        database.withConnection(closure)
    }
    func execute(query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> Void) -> EventLoopFuture<Void> {
        database.execute(query: query, onOutput: onOutput)
    }
    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> { database.execute(schema: schema) }
    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> { database.execute(enum: `enum`) }
}
