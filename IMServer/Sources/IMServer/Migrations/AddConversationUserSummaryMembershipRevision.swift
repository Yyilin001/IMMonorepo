import Fluent
import SQLKit

struct AddConversationUserSummaryMembershipRevision: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(ConversationUserSummary.schema)
                .field("membership_revision", .datetime)
                .update()
            return
        }

        switch sql.dialect.name {
        case "postgresql":
            try await sql.raw("""
                ALTER TABLE \(ident: ConversationUserSummary.schema)
                ADD COLUMN IF NOT EXISTS \(ident: "membership_revision") TIMESTAMPTZ
                """).run()
        case "sqlite":
            try await addSQLiteColumnIfMissing(sql)
        default:
            try await database.schema(ConversationUserSummary.schema)
                .field("membership_revision", .datetime)
                .update()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(ConversationUserSummary.schema)
                .deleteField("membership_revision")
                .update()
            return
        }

        guard sql.dialect.name == "postgresql" else {
            return
        }

        try await sql.raw("""
            ALTER TABLE \(ident: ConversationUserSummary.schema)
            DROP COLUMN IF EXISTS \(ident: "membership_revision")
            """).run()
    }

    private func addSQLiteColumnIfMissing(_ sql: any SQLDatabase) async throws {
        struct SQLiteColumnRow: Decodable {
            let name: String
        }

        let rows = try await sql.raw("PRAGMA table_info(\(unsafeRaw: ConversationUserSummary.schema))")
            .all(decoding: SQLiteColumnRow.self)
        guard !Set(rows.map(\.name)).contains("membership_revision") else {
            return
        }

        try await sql.raw("""
            ALTER TABLE \(ident: ConversationUserSummary.schema)
            ADD COLUMN \(ident: "membership_revision") DATETIME
            """).run()
    }
}
