import Fluent
import SQLKit

struct CreateIMRealtimeCellRegistry: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(IMRealtimeCellRegistryEntry.schema)
            .field("cell_id", .string, .identifier(auto: false))
            .field("status", .string, .required)
            .field("command_endpoint", .string, .required)
            .field("query_endpoint", .string, .required)
            .field("realtime_endpoint", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .ignoreExisting()
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS im_realtime_cell_registry_status_idx
            ON im_realtime_cell_registry (status)
            """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS im_realtime_cell_registry_status_idx").run()
        }
        try await database.schema(IMRealtimeCellRegistryEntry.schema).delete()
    }
}
