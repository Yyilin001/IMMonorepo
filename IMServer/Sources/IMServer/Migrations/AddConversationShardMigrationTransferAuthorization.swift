import Fluent
import SQLKit

/// Adds the capability used by a source Cell to upload pages into a remote
/// migration target. Existing local-only migrations intentionally have no
/// token and cannot be used by the remote ingress endpoint.
struct AddConversationShardMigrationTransferAuthorization: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(ConversationShardMigration.schema)
                .field("transfer_token", .string)
                .field("transfer_token_expires_at", .datetime)
                .update()
            return
        }

        switch sql.dialect.name {
        case "postgresql":
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: ConversationShardMigration.schema)
                ADD COLUMN IF NOT EXISTS transfer_token TEXT,
                ADD COLUMN IF NOT EXISTS transfer_token_expires_at TIMESTAMP
                """).run()
        case "sqlite":
            struct SQLiteColumnRow: Decodable { let name: String }
            let existing = Set(
                try await sql.raw("PRAGMA table_info(\(unsafeRaw: ConversationShardMigration.schema))")
                    .all(decoding: SQLiteColumnRow.self)
                    .map(\.name)
            )
            if !existing.contains("transfer_token") {
                try await sql.raw("""
                    ALTER TABLE \(unsafeRaw: ConversationShardMigration.schema)
                    ADD COLUMN transfer_token TEXT
                    """).run()
            }
            if !existing.contains("transfer_token_expires_at") {
                try await sql.raw("""
                    ALTER TABLE \(unsafeRaw: ConversationShardMigration.schema)
                    ADD COLUMN transfer_token_expires_at DATETIME
                    """).run()
            }
        default:
            try await database.schema(ConversationShardMigration.schema)
                .field("transfer_token", .string)
                .field("transfer_token_expires_at", .datetime)
                .update()
        }
    }

    func revert(on database: any Database) async throws {
        // Migration capabilities remain in the audit record during rollback.
    }
}
