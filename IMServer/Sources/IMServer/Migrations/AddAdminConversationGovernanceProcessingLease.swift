import Fluent
import SQLKit

struct AddAdminConversationGovernanceProcessingLease: AsyncMigration {
    private let fields: [(name: String, type: String)] = [
        ("processing_token", "TEXT"),
        ("processing_started_at", "TIMESTAMP")
    ]

    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            switch sql.dialect.name {
            case "postgresql":
                for field in fields {
                    try await sql.raw(
                        "ALTER TABLE IF EXISTS \(unsafeRaw: AdminConversationGovernanceCommand.schema) ADD COLUMN IF NOT EXISTS \(unsafeRaw: field.name) \(unsafeRaw: field.type)"
                    ).run()
                }
            case "sqlite":
                struct SQLiteColumnRow: Decodable { let name: String }
                let columns = try await sql.raw(
                    "PRAGMA table_info(\(unsafeRaw: AdminConversationGovernanceCommand.schema));"
                ).all(decoding: SQLiteColumnRow.self)
                let existing = Set(columns.map(\.name))
                for field in fields where !existing.contains(field.name) {
                    try await sql.raw(
                        "ALTER TABLE \(unsafeRaw: AdminConversationGovernanceCommand.schema) ADD COLUMN \(unsafeRaw: field.name) \(unsafeRaw: field.type)"
                    ).run()
                }
            default:
                for field in fields {
                    try await sql.raw(
                        "ALTER TABLE \(unsafeRaw: AdminConversationGovernanceCommand.schema) ADD COLUMN \(unsafeRaw: field.name) \(unsafeRaw: field.type)"
                    ).run()
                }
            }

            try await sql.raw("""
                CREATE INDEX IF NOT EXISTS admin_governance_command_recovery_idx
                ON \(unsafeRaw: AdminConversationGovernanceCommand.schema) (status, processing_started_at ASC)
                """).run()
            return
        }

        try await database.schema(AdminConversationGovernanceCommand.schema)
            .field("processing_token", .string)
            .field("processing_started_at", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS admin_governance_command_recovery_idx").run()
            guard sql.dialect.name == "postgresql" else {
                return
            }
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: AdminConversationGovernanceCommand.schema)
                DROP COLUMN IF EXISTS processing_started_at,
                DROP COLUMN IF EXISTS processing_token
                """).run()
            return
        }

        try await database.schema(AdminConversationGovernanceCommand.schema)
            .deleteField("processing_started_at")
            .deleteField("processing_token")
            .update()
    }
}
