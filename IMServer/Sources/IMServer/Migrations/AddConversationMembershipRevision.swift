import Fluent
import SQLKit

struct AddConversationMembershipRevision: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(Conversation.schema)
                .field("membership_revision", .datetime)
                .update()
            return
        }

        switch sql.dialect.name {
        case "postgresql":
            try await sql.raw("""
                ALTER TABLE \(ident: Conversation.schema)
                ADD COLUMN IF NOT EXISTS \(ident: "membership_revision") TIMESTAMPTZ
                """).run()
        case "sqlite":
            try await addSQLiteColumnIfMissing(
                sql,
                table: Conversation.schema,
                column: "membership_revision",
                definition: "DATETIME"
            )
        default:
            try await database.schema(Conversation.schema)
                .field("membership_revision", .datetime)
                .update()
        }

        try await sql.raw("""
            UPDATE \(ident: Conversation.schema)
            SET \(ident: "membership_revision") = COALESCE(\(ident: "membership_revision"), \(ident: "updated_at"))
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(Conversation.schema)
                .deleteField("membership_revision")
                .update()
            return
        }

        guard sql.dialect.name == "postgresql" else {
            return
        }

        try await sql.raw("""
            ALTER TABLE \(ident: Conversation.schema)
            DROP COLUMN IF EXISTS \(ident: "membership_revision")
            """).run()
    }

    private func addSQLiteColumnIfMissing(
        _ sql: any SQLDatabase,
        table: String,
        column: String,
        definition: String
    ) async throws {
        struct SQLiteColumnRow: Decodable {
            let name: String
        }

        let rows = try await sql.raw("PRAGMA table_info(\(unsafeRaw: table))")
            .all(decoding: SQLiteColumnRow.self)
        guard !Set(rows.map(\.name)).contains(column) else {
            return
        }

        try await sql.raw("""
            ALTER TABLE \(ident: table)
            ADD COLUMN \(ident: column) \(unsafeRaw: definition)
            """).run()
    }
}
