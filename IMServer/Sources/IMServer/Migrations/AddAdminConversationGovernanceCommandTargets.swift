import Fluent
import SQLKit

struct AddAdminConversationGovernanceCommandTargets: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            switch sql.dialect.name {
            case "postgresql":
                try await sql.raw("""
                    ALTER TABLE IF EXISTS \(unsafeRaw: AdminConversationGovernanceCommand.schema)
                    ADD COLUMN IF NOT EXISTS target_member_user_id UUID,
                    ADD COLUMN IF NOT EXISTS destructive_confirmed BOOLEAN NOT NULL DEFAULT FALSE
                    """).run()
            case "sqlite":
                struct SQLiteColumnRow: Decodable { let name: String }
                let columns = try await sql.raw(
                    "PRAGMA table_info(\(unsafeRaw: AdminConversationGovernanceCommand.schema));"
                ).all(decoding: SQLiteColumnRow.self)
                let existing = Set(columns.map(\.name))
                if !existing.contains("target_member_user_id") {
                    try await sql.raw("""
                        ALTER TABLE \(unsafeRaw: AdminConversationGovernanceCommand.schema)
                        ADD COLUMN target_member_user_id UUID
                        """).run()
                }
                if !existing.contains("destructive_confirmed") {
                    try await sql.raw("""
                        ALTER TABLE \(unsafeRaw: AdminConversationGovernanceCommand.schema)
                        ADD COLUMN destructive_confirmed BOOLEAN NOT NULL DEFAULT FALSE
                        """).run()
                }
            default:
                try await database.schema(AdminConversationGovernanceCommand.schema)
                    .field("target_member_user_id", .uuid)
                    .field("destructive_confirmed", .bool, .required, .sql(.default(false)))
                    .update()
            }

            try await sql.raw("""
                CREATE INDEX IF NOT EXISTS admin_governance_command_target_member_idx
                ON \(unsafeRaw: AdminConversationGovernanceCommand.schema) (conversation_id, target_member_user_id)
                """).run()
            return
        }

        try await database.schema(AdminConversationGovernanceCommand.schema)
            .field("target_member_user_id", .uuid)
            .field("destructive_confirmed", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS admin_governance_command_target_member_idx").run()
            guard sql.dialect.name == "postgresql" else {
                return
            }
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: AdminConversationGovernanceCommand.schema)
                DROP COLUMN IF EXISTS destructive_confirmed,
                DROP COLUMN IF EXISTS target_member_user_id
                """).run()
            return
        }

        try await database.schema(AdminConversationGovernanceCommand.schema)
            .deleteField("destructive_confirmed")
            .deleteField("target_member_user_id")
            .update()
    }
}
