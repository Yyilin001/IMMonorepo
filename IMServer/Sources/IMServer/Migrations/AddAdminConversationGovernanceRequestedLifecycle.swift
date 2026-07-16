import Fluent
import SQLKit

struct AddAdminConversationGovernanceRequestedLifecycle: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            switch sql.dialect.name {
            case "postgresql":
                try await sql.raw("""
                    ALTER TABLE IF EXISTS \(unsafeRaw: AdminConversationGovernanceCommand.schema)
                    ADD COLUMN IF NOT EXISTS requested_group_lifecycle_state TEXT NOT NULL DEFAULT 'active'
                    """).run()
            case "sqlite":
                struct SQLiteColumnRow: Decodable { let name: String }
                let columns = try await sql.raw(
                    "PRAGMA table_info(\(unsafeRaw: AdminConversationGovernanceCommand.schema));"
                ).all(decoding: SQLiteColumnRow.self)
                if !Set(columns.map(\.name)).contains("requested_group_lifecycle_state") {
                    try await sql.raw("""
                        ALTER TABLE \(unsafeRaw: AdminConversationGovernanceCommand.schema)
                        ADD COLUMN requested_group_lifecycle_state TEXT NOT NULL DEFAULT 'active'
                        """).run()
                }
            default:
                try await database.schema(AdminConversationGovernanceCommand.schema)
                    .field("requested_group_lifecycle_state", .string, .required, .sql(.default("active")))
                    .update()
            }
            return
        }

        try await database.schema(AdminConversationGovernanceCommand.schema)
            .field("requested_group_lifecycle_state", .string, .required, .sql(.default("active")))
            .update()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: AdminConversationGovernanceCommand.schema)
                DROP COLUMN IF EXISTS requested_group_lifecycle_state
                """).run()
            return
        }
        if database is any SQLDatabase {
            return
        }
        try await database.schema(AdminConversationGovernanceCommand.schema)
            .deleteField("requested_group_lifecycle_state")
            .update()
    }
}
