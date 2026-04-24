import Fluent
import SQLKit

struct AddConversationMetadataAndPreferences: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("""
                ALTER TABLE \(unsafeRaw: Conversation.schema)
                ADD COLUMN IF NOT EXISTS notice TEXT
                """).run()
            try await sql.raw("""
                ALTER TABLE \(unsafeRaw: Conversation.schema)
                ADD COLUMN IF NOT EXISTS avatar_preset TEXT
                """).run()
            try await sql.raw("""
                ALTER TABLE \(unsafeRaw: ConversationMember.schema)
                ADD COLUMN IF NOT EXISTS visible_from_sequence INTEGER NOT NULL DEFAULT 0
                """).run()
            try await sql.raw("""
                ALTER TABLE \(unsafeRaw: ConversationUserSummary.schema)
                ADD COLUMN IF NOT EXISTS notice TEXT
                """).run()
            try await sql.raw("""
                ALTER TABLE \(unsafeRaw: ConversationUserSummary.schema)
                ADD COLUMN IF NOT EXISTS avatar_preset TEXT
                """).run()
            try await sql.raw("""
                ALTER TABLE \(unsafeRaw: ConversationUserSummary.schema)
                ADD COLUMN IF NOT EXISTS is_pinned BOOLEAN NOT NULL DEFAULT FALSE
                """).run()
            try await sql.raw("""
                ALTER TABLE \(unsafeRaw: ConversationUserSummary.schema)
                ADD COLUMN IF NOT EXISTS pinned_at TIMESTAMP
                """).run()
            try await sql.raw("""
                ALTER TABLE \(unsafeRaw: ConversationUserSummary.schema)
                ADD COLUMN IF NOT EXISTS is_muted BOOLEAN NOT NULL DEFAULT FALSE
                """).run()
            return
        }
        return
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "sqlite" {
            return
        }
        try await database.schema(ConversationUserSummary.schema)
            .deleteField("is_muted")
            .deleteField("pinned_at")
            .deleteField("is_pinned")
            .deleteField("avatar_preset")
            .deleteField("notice")
            .update()

        try await database.schema(ConversationMember.schema)
            .deleteField("visible_from_sequence")
            .update()

        try await database.schema(Conversation.schema)
            .deleteField("avatar_preset")
            .deleteField("notice")
            .update()
    }
}
