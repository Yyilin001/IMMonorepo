import Fluent
import SQLKit

struct AddConversationMemberPreferences: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            switch sql.dialect.name {
            case "postgresql":
                try await sql.raw("""
                    ALTER TABLE IF EXISTS \(unsafeRaw: ConversationMember.schema)
                    ADD COLUMN IF NOT EXISTS is_pinned BOOLEAN NOT NULL DEFAULT FALSE
                    """).run()
                try await sql.raw("""
                    ALTER TABLE IF EXISTS \(unsafeRaw: ConversationMember.schema)
                    ADD COLUMN IF NOT EXISTS pinned_at TIMESTAMP
                    """).run()
                try await sql.raw("""
                    ALTER TABLE IF EXISTS \(unsafeRaw: ConversationMember.schema)
                    ADD COLUMN IF NOT EXISTS is_muted BOOLEAN NOT NULL DEFAULT FALSE
                    """).run()
                return
            case "sqlite":
                try await addSQLiteColumnIfMissing(
                    sql,
                    column: "is_pinned",
                    definition: "INTEGER NOT NULL DEFAULT 0"
                )
                try await addSQLiteColumnIfMissing(
                    sql,
                    column: "pinned_at",
                    definition: "DATETIME"
                )
                try await addSQLiteColumnIfMissing(
                    sql,
                    column: "is_muted",
                    definition: "INTEGER NOT NULL DEFAULT 0"
                )
                return
            default:
                break
            }
        }

        try await database.schema(ConversationMember.schema)
            .field("is_pinned", .bool, .required, .sql(.default(false)))
            .field("pinned_at", .datetime)
            .field("is_muted", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ConversationMember.schema)
            .deleteField("is_muted")
            .deleteField("pinned_at")
            .deleteField("is_pinned")
            .update()
    }

    private func addSQLiteColumnIfMissing(
        _ database: any SQLDatabase,
        column: String,
        definition: String
    ) async throws {
        struct Column: Decodable {
            let name: String
        }

        let columns = try await database.raw(
            "PRAGMA table_info(\(ident: ConversationMember.schema))"
        ).all(decoding: Column.self)
        guard !columns.contains(where: { $0.name == column }) else {
            return
        }
        try await database.raw("""
            ALTER TABLE \(ident: ConversationMember.schema)
            ADD COLUMN \(ident: column) \(unsafeRaw: definition)
            """).run()
    }
}
