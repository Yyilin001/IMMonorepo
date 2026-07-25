import Fluent
import SQLKit

struct CreateCrossCellRealtimeDispatchOutbox: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(CrossCellRealtimeDispatch.schema)
            .id()
            .field("origin_cell_id", .string, .required)
            .field("target_cell_id", .string, .required)
            .field("envelope_json", .string, .required)
            .field("status", .string, .required)
            .field("retry_count", .int, .required)
            .field("next_attempt_at", .datetime, .required)
            .field("processing_started_at", .datetime)
            .field("delivered_at", .datetime)
            .field("error_message", .string)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.raw("""
                CREATE INDEX IF NOT EXISTS cross_cell_realtime_dispatch_ready_idx
                ON \(ident: CrossCellRealtimeDispatch.schema) (
                    \(ident: "status"), \(ident: "next_attempt_at"), \(ident: "created_at")
                )
                """).run()
        }
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS cross_cell_realtime_dispatch_ready_idx").run()
        }
        try await database.schema(CrossCellRealtimeDispatch.schema).delete()
    }
}
