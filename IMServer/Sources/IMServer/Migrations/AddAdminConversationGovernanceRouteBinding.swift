import Fluent
import SQLKit

struct AddAdminConversationGovernanceRouteBinding: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(AdminConversationGovernanceCommand.schema)
                .field("target_cell_id", .string, .required, .sql(.default("default")))
                .field("target_route_version", .int, .required, .sql(.default(1)))
                .update()
            return
        }

        switch sql.dialect.name {
        case "postgresql":
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: AdminConversationGovernanceCommand.schema)
                ADD COLUMN IF NOT EXISTS target_cell_id TEXT NOT NULL DEFAULT 'default',
                ADD COLUMN IF NOT EXISTS target_route_version INTEGER NOT NULL DEFAULT 1
                """).run()
        case "sqlite":
            struct SQLiteColumnRow: Decodable { let name: String }
            let columns = try await sql.raw(
                "PRAGMA table_info(\(unsafeRaw: AdminConversationGovernanceCommand.schema));"
            ).all(decoding: SQLiteColumnRow.self)
            let existingColumns = Set(columns.map(\.name))
            if !existingColumns.contains("target_cell_id") {
                try await sql.raw("""
                    ALTER TABLE \(unsafeRaw: AdminConversationGovernanceCommand.schema)
                    ADD COLUMN target_cell_id TEXT NOT NULL DEFAULT 'default'
                    """).run()
            }
            if !existingColumns.contains("target_route_version") {
                try await sql.raw("""
                    ALTER TABLE \(unsafeRaw: AdminConversationGovernanceCommand.schema)
                    ADD COLUMN target_route_version INTEGER NOT NULL DEFAULT 1
                    """).run()
            }
        default:
            try await database.schema(AdminConversationGovernanceCommand.schema)
                .field("target_cell_id", .string, .required, .sql(.default("default")))
                .field("target_route_version", .int, .required, .sql(.default(1)))
                .update()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase,
              sql.dialect.name == "postgresql"
        else {
            return
        }
        try await sql.raw("""
            ALTER TABLE IF EXISTS \(unsafeRaw: AdminConversationGovernanceCommand.schema)
            DROP COLUMN IF EXISTS target_route_version,
            DROP COLUMN IF EXISTS target_cell_id
            """).run()
    }
}
