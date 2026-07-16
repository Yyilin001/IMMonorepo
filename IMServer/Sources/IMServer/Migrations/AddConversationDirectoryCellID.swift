import Fluent
import SQLKit

struct AddConversationDirectoryCellID: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(ConversationDirectoryEntry.schema)
                .field("cell_id", .string)
                .update()
            return
        }

        switch sql.dialect.name {
        case "postgresql":
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: ConversationDirectoryEntry.schema)
                ADD COLUMN IF NOT EXISTS cell_id TEXT NOT NULL DEFAULT 'default'
                """).run()
        case "sqlite":
            struct SQLiteColumnRow: Decodable { let name: String }
            let columns = try await sql.raw(
                "PRAGMA table_info(\(unsafeRaw: ConversationDirectoryEntry.schema));"
            ).all(decoding: SQLiteColumnRow.self)
            guard !columns.contains(where: { $0.name == "cell_id" }) else {
                return
            }
            try await sql.raw("""
                ALTER TABLE \(unsafeRaw: ConversationDirectoryEntry.schema)
                ADD COLUMN cell_id TEXT NOT NULL DEFAULT 'default'
                """).run()
        default:
            try await sql.raw("""
                ALTER TABLE \(unsafeRaw: ConversationDirectoryEntry.schema)
                ADD COLUMN cell_id TEXT NOT NULL DEFAULT 'default'
                """).run()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            return
        }
        try await sql.raw("""
            ALTER TABLE IF EXISTS \(unsafeRaw: ConversationDirectoryEntry.schema)
            DROP COLUMN IF EXISTS cell_id
            """).run()
    }
}
