import Foundation
import Testing
import SQLKit
import FluentKit
@testable import IMV2ServerInfrastructure

@Suite("Journal source schema contract", .serialized)
struct V2RealtimeJournalSchemaReadinessTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func canonicalCaptureIsRepeatableAndRejectsDisabledTriggers() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let source = try String(contentsOf: root.appending(path: "IMV2/sql/realtime-change-journal.sql"), encoding: .utf8)
                .replacingOccurrences(of: "im_v2", with: schema)
            func install() async throws {
                for statement in postgresStatements(in: source) where !statement.isEmpty && statement != "BEGIN" && statement != "COMMIT" {
                    try await sql.raw("\(unsafeRaw: statement)").run()
                }
            }
            try await install()
            try await V2RealtimeJournalSchemaReadiness.verify(database: database, schema: schema)
            struct Absence: Decodable { let absent: Bool }
            let retired = try #require(try await sql.raw("SELECT to_regclass(\(bind: schema) || '.room_event_wake_outbox') IS NULL AS absent").first(decoding: Absence.self))
            #expect(retired.absent)
            try await sql.raw("CREATE TABLE \(unsafeRaw: schema).room_event_wake_outbox (room_id uuid)").run()
            await #expect(throws: V2RealtimeJournalSchemaReadinessError.unavailableContract) {
                try await V2RealtimeJournalSchemaReadiness.verify(database: database, schema: schema)
            }
            try await sql.raw("DROP TABLE \(unsafeRaw: schema).room_event_wake_outbox").run()
            let room = UUID()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id,room_sequence) VALUES(\(bind: room),'source','standard',1)").run()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).room_events(event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at) VALUES(\(bind: UUID()),\(bind: room),1,'test.head','{}'::jsonb,0,clock_timestamp())").run()
            struct Cut: Decodable, Equatable { let room_sequence: Int64; let revision: Int64; let pending: Bool }
            func cut() async throws -> Cut {
                try #require(try await sql.raw("SELECT room_sequence,revision,pending FROM \(unsafeRaw: schema).realtime_dirty_room_heads WHERE room_id=\(bind: room)").first(decoding: Cut.self))
            }
            let first = try await cut()
            #expect(first.room_sequence == 1 && first.pending)
            try await sql.raw("UPDATE \(unsafeRaw: schema).realtime_dirty_room_heads SET pending=false WHERE room_id=\(bind: room)").run()
            let settled = try await cut()
            try await install()
            #expect(try await cut() == settled)
            try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence=2 WHERE room_id=\(bind: room)").run()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).room_events(event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at) VALUES(\(bind: UUID()),\(bind: room),2,'test.head','{}'::jsonb,0,clock_timestamp())").run()
            try await sql.raw("UPDATE \(unsafeRaw: schema).realtime_dirty_room_heads SET pending=false WHERE room_id=\(bind: room) AND revision=\(bind: first.revision)").run()
            let advanced = try await cut()
            #expect(advanced.room_sequence == 2 && advanced.revision > first.revision && advanced.pending)
            try await sql.raw("ALTER TABLE \(unsafeRaw: schema).messages DISABLE TRIGGER realtime_journal_capture").run()
            await #expect(throws: V2RealtimeJournalSchemaReadinessError.unavailableContract) {
                try await V2RealtimeJournalSchemaReadiness.verify(database: database, schema: schema)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func installedControlOnlyUPSERTPassesReadinessAndMissingCASRevisionIsRejected() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let source = try String(contentsOf: root.appending(path: "IMV2/sql/realtime-change-journal.sql"), encoding: .utf8)
                .replacingOccurrences(of: "im_v2", with: schema)
            for statement in postgresStatements(in: source) where !statement.isEmpty && statement != "BEGIN" && statement != "COMMIT" {
                try await sql.raw("\(unsafeRaw: statement)").run()
            }
            try await V2RealtimeJournalSchemaReadiness.verify(database: database, schema: schema)
            let room = UUID(), user = UUID()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id) VALUES(\(bind: room),'source','standard')").run()
            struct Cut: Decodable { let room_sequence: Int64; let room_control_version: Int64; let revision: Int64; let pending: Bool }
            let original = try #require(try await sql.raw("SELECT room_sequence,room_control_version,revision,pending FROM \(unsafeRaw: schema).realtime_dirty_room_heads WHERE room_id=\(bind: room)").first(decoding: Cut.self))
            #expect(original.room_sequence == 0 && original.pending)
            // Clear the previous responsibility, then a membership INSERT with
            // no new room H must create a new revision and set pending again.
            try await sql.raw("UPDATE \(unsafeRaw: schema).realtime_dirty_room_heads SET pending=false WHERE room_id=\(bind: room)").run()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision) VALUES(\(bind: room),\(bind: user),0)").run()
            let changed = try #require(try await sql.raw("SELECT room_sequence,room_control_version,revision,pending FROM \(unsafeRaw: schema).realtime_dirty_room_heads WHERE room_id=\(bind: room)").first(decoding: Cut.self))
            #expect(changed.room_sequence == 0 && changed.pending)
            #expect(changed.revision == original.revision + 1)
            #expect(changed.room_control_version == original.room_control_version + 1)
            try await V2RealtimeJournalSchemaReadiness.verify(database: database, schema: schema)
            struct Definition: Decodable { let definition: String }
            let installed = try #require(try await sql.raw("SELECT pg_get_functiondef(to_regprocedure(\(bind: schema + ".capture_realtime_change()"))) AS definition").first(decoding: Definition.self))
            let exact = "revision=\(schema).realtime_dirty_room_heads.revision+1,pending=true"
            #expect(installed.definition.contains(exact))
            let damaged = installed.definition.replacingOccurrences(of: exact, with: "pending=true")
            try await sql.raw("\(unsafeRaw: damaged)").run()
            // The trigger still exists and fires, but losing revision++ allows
            // an old same-H receipt to clear a newer permission responsibility.
            await #expect(throws: V2RealtimeJournalSchemaReadinessError.unavailableContract) {
                try await V2RealtimeJournalSchemaReadiness.verify(database: database, schema: schema)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func repeatableInstallPreservesIdentityAndReadinessRejectsDisabledDiscovery() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let source = try String(contentsOf: root.appending(path: "IMV2/sql/realtime-change-journal.sql"), encoding: .utf8)
                .replacingOccurrences(of: "im_v2", with: schema)
            for statement in postgresStatements(in: source) where !statement.isEmpty && statement != "BEGIN" && statement != "COMMIT" {
                try await sql.raw("\(unsafeRaw: statement)").run()
            }
            try await V2RealtimeJournalSchemaReadiness.verify(database: database, schema: schema)
            let store = try PostgresV2RealtimeChangeJournalStore(database: database, schema: schema)
            let identity = try await store.sourceIdentity()
            for statement in postgresStatements(in: source) where !statement.isEmpty && statement != "BEGIN" && statement != "COMMIT" {
                try await sql.raw("\(unsafeRaw: statement)").run()
            }
            #expect(try await store.sourceIdentity() == identity)
            try await V2RealtimeJournalSchemaReadiness.verify(database: database, schema: schema)
            try await sql.raw("ALTER TABLE \(unsafeRaw: schema).messages DISABLE TRIGGER realtime_journal_capture").run()
            await #expect(throws: V2RealtimeJournalSchemaReadinessError.unavailableContract) {
                try await V2RealtimeJournalSchemaReadiness.verify(database: database, schema: schema)
            }
            try await sql.raw("ALTER TABLE \(unsafeRaw: schema).messages ENABLE TRIGGER realtime_journal_capture").run()
            try await sql.raw("DROP INDEX \(unsafeRaw: schema).realtime_dirty_room_heads_pending_idx").run()
            await #expect(throws: V2RealtimeJournalSchemaReadinessError.unavailableContract) {
                try await V2RealtimeJournalSchemaReadiness.verify(database: database, schema: schema)
            }
        }
    }
}
