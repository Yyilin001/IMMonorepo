import Fluent
import SQLKit

struct AddConversationShardMigrationCutoverLease: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(ConversationShardMigration.schema)
                .field("cutover_lease_token", .string)
                .field("cutover_lease_expires_at", .datetime)
                .update()
            return
        }

        switch sql.dialect.name {
        case "postgresql":
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: ConversationShardMigration.schema)
                ADD COLUMN IF NOT EXISTS cutover_lease_token TEXT,
                ADD COLUMN IF NOT EXISTS cutover_lease_expires_at TIMESTAMP
                """).run()
        case "sqlite":
            struct SQLiteColumnRow: Decodable { let name: String }
            let existing = Set(
                try await sql.raw("PRAGMA table_info(\(unsafeRaw: ConversationShardMigration.schema))")
                    .all(decoding: SQLiteColumnRow.self)
                    .map(\.name)
            )
            if !existing.contains("cutover_lease_token") {
                try await sql.raw("""
                    ALTER TABLE \(unsafeRaw: ConversationShardMigration.schema)
                    ADD COLUMN cutover_lease_token TEXT
                    """).run()
            }
            if !existing.contains("cutover_lease_expires_at") {
                try await sql.raw("""
                    ALTER TABLE \(unsafeRaw: ConversationShardMigration.schema)
                    ADD COLUMN cutover_lease_expires_at DATETIME
                    """).run()
            }
        default:
            try await database.schema(ConversationShardMigration.schema)
                .field("cutover_lease_token", .string)
                .field("cutover_lease_expires_at", .datetime)
                .update()
        }
    }

    func revert(on database: any Database) async throws {
        // Keep audit state during production rollback; remove manually after
        // every active migration is completed or cancelled.
    }
}
