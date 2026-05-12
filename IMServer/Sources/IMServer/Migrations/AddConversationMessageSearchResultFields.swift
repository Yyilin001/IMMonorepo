import Fluent
import SQLKit

struct AddConversationMessageSearchResultFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(ConversationMessageSearchIndex.schema)
                .field("sender_user_id", .uuid)
                .update()
            try await database.schema(ConversationMessageSearchIndex.schema)
                .field("content_json", .string)
                .update()
            try await database.schema(ConversationMessageSearchIndex.schema)
                .field("derived_state_json", .string)
                .update()
            return
        }

        switch sql.dialect.name {
        case "postgresql":
            try await sql.raw("""
                ALTER TABLE \(ident: ConversationMessageSearchIndex.schema)
                ADD COLUMN IF NOT EXISTS \(ident: "sender_user_id") UUID
                """).run()
            try await sql.raw("""
                ALTER TABLE \(ident: ConversationMessageSearchIndex.schema)
                ADD COLUMN IF NOT EXISTS \(ident: "content_json") TEXT
                """).run()
            try await sql.raw("""
                ALTER TABLE \(ident: ConversationMessageSearchIndex.schema)
                ADD COLUMN IF NOT EXISTS \(ident: "derived_state_json") TEXT
                """).run()
        case "sqlite":
            struct SQLiteColumnRow: Decodable {
                let name: String
            }

            let rows = try await sql.raw("""
                PRAGMA table_info(\(unsafeRaw: ConversationMessageSearchIndex.schema))
                """).all(decoding: SQLiteColumnRow.self)
            let existingColumns = Set(rows.map(\.name))

            if !existingColumns.contains("sender_user_id") {
                try await sql.raw("""
                    ALTER TABLE \(ident: ConversationMessageSearchIndex.schema)
                    ADD COLUMN \(ident: "sender_user_id") TEXT
                    """).run()
            }
            if !existingColumns.contains("content_json") {
                try await sql.raw("""
                    ALTER TABLE \(ident: ConversationMessageSearchIndex.schema)
                    ADD COLUMN \(ident: "content_json") TEXT
                    """).run()
            }
            if !existingColumns.contains("derived_state_json") {
                try await sql.raw("""
                    ALTER TABLE \(ident: ConversationMessageSearchIndex.schema)
                    ADD COLUMN \(ident: "derived_state_json") TEXT
                    """).run()
            }
        default:
            try await sql.raw("""
                ALTER TABLE \(ident: ConversationMessageSearchIndex.schema)
                ADD COLUMN \(ident: "sender_user_id") UUID
                """).run()
            try await sql.raw("""
                ALTER TABLE \(ident: ConversationMessageSearchIndex.schema)
                ADD COLUMN \(ident: "content_json") TEXT
                """).run()
            try await sql.raw("""
                ALTER TABLE \(ident: ConversationMessageSearchIndex.schema)
                ADD COLUMN \(ident: "derived_state_json") TEXT
                """).run()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(ConversationMessageSearchIndex.schema)
                .deleteField("sender_user_id")
                .deleteField("content_json")
                .deleteField("derived_state_json")
                .update()
            return
        }

        switch sql.dialect.name {
        case "postgresql":
            try await sql.raw("""
                ALTER TABLE \(ident: ConversationMessageSearchIndex.schema)
                DROP COLUMN IF EXISTS \(ident: "sender_user_id")
                """).run()
            try await sql.raw("""
                ALTER TABLE \(ident: ConversationMessageSearchIndex.schema)
                DROP COLUMN IF EXISTS \(ident: "content_json")
                """).run()
            try await sql.raw("""
                ALTER TABLE \(ident: ConversationMessageSearchIndex.schema)
                DROP COLUMN IF EXISTS \(ident: "derived_state_json")
                """).run()
        case "sqlite":
            return
        default:
            try await sql.raw("""
                ALTER TABLE \(ident: ConversationMessageSearchIndex.schema)
                DROP COLUMN \(ident: "sender_user_id")
                """).run()
            try await sql.raw("""
                ALTER TABLE \(ident: ConversationMessageSearchIndex.schema)
                DROP COLUMN \(ident: "content_json")
                """).run()
            try await sql.raw("""
                ALTER TABLE \(ident: ConversationMessageSearchIndex.schema)
                DROP COLUMN \(ident: "derived_state_json")
                """).run()
        }
    }
}
