import Fluent
import Foundation
import SQLKit

/// Adds an idempotency identity to the Cross-Cell outbox without assuming the
/// initial table migration has not already run in a deployed Cell.
struct AddCrossCellRealtimeDispatchDedupeKey: AsyncMigration {
    private struct ExistingRow: Decodable {
        let id: UUID
        let originCellID: String
        let targetCellID: String
        let envelopeJSON: String

        enum CodingKeys: String, CodingKey {
            case id
            case originCellID = "origin_cell_id"
            case targetCellID = "target_cell_id"
            case envelopeJSON = "envelope_json"
        }
    }

    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            switch sql.dialect.name {
            case "postgresql":
                try await sql.raw("""
                    ALTER TABLE IF EXISTS \(ident: CrossCellRealtimeDispatch.schema)
                    ADD COLUMN IF NOT EXISTS \(ident: "dedupe_key") TEXT
                    """).run()
            case "sqlite":
                struct SQLiteColumn: Decodable { let name: String }
                let columns = try await sql.raw(
                    "PRAGMA table_info(\(unsafeRaw: CrossCellRealtimeDispatch.schema));"
                ).all(decoding: SQLiteColumn.self)
                if !columns.contains(where: { $0.name == "dedupe_key" }) {
                    try await sql.raw("""
                        ALTER TABLE \(ident: CrossCellRealtimeDispatch.schema)
                        ADD COLUMN \(ident: "dedupe_key") TEXT
                        """).run()
                }
            default:
                try await database.schema(CrossCellRealtimeDispatch.schema)
                    .field("dedupe_key", .string)
                    .update()
            }

            let rows = try await sql.raw("""
                SELECT \(ident: "id"), \(ident: "origin_cell_id"), \(ident: "target_cell_id"), \(ident: "envelope_json")
                FROM \(ident: CrossCellRealtimeDispatch.schema)
                ORDER BY CASE \(ident: "status")
                    WHEN 'delivered' THEN 0
                    WHEN 'pending' THEN 1
                    ELSE 2
                END, \(ident: "created_at") ASC
                """).all(decoding: ExistingRow.self)
            var retainedKeys = Set<String>()
            for row in rows {
                let key = try CrossCellRealtimeDispatch.canonicalDedupeKey(
                    originCellID: row.originCellID,
                    targetCellID: row.targetCellID,
                    storedEnvelopeJSON: row.envelopeJSON
                )
                // Older versions did not have a database idempotency boundary,
                // so a crash between source persistence and Kafka offset commit
                // may already have created identical rows. They represent the
                // same at-least-once handoff; retaining one preserves recovery
                // while allowing the new unique index to be installed.
                guard retainedKeys.insert(key).inserted else {
                    try await sql.raw("""
                        DELETE FROM \(ident: CrossCellRealtimeDispatch.schema)
                        WHERE \(ident: "id") = \(bind: row.id)
                        """).run()
                    continue
                }
                try await sql.raw("""
                    UPDATE \(ident: CrossCellRealtimeDispatch.schema)
                    SET \(ident: "dedupe_key") = \(bind: key)
                    WHERE \(ident: "id") = \(bind: row.id)
                    """).run()
            }
            try await sql.raw("""
                CREATE UNIQUE INDEX IF NOT EXISTS cross_cell_realtime_dispatch_dedupe_uidx
                ON \(ident: CrossCellRealtimeDispatch.schema) (\(ident: "dedupe_key"))
                """).run()
            return
        }

        try await database.schema(CrossCellRealtimeDispatch.schema)
            .field("dedupe_key", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS cross_cell_realtime_dispatch_dedupe_uidx").run()
        }
        try await database.schema(CrossCellRealtimeDispatch.schema)
            .deleteField("dedupe_key")
            .update()
    }
}
