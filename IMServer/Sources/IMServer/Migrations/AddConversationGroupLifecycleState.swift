import Fluent
import SQLKit

struct AddConversationGroupLifecycleState: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: Conversation.schema)
                ADD COLUMN IF NOT EXISTS group_lifecycle_state TEXT NOT NULL DEFAULT 'active'
                """).run()
            return
        }

        try await database.schema(Conversation.schema)
            .field("group_lifecycle_state", .string, .required, .sql(.default("active")))
            .update()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: Conversation.schema)
                DROP COLUMN IF EXISTS group_lifecycle_state
                """).run()
            return
        }

        try await database.schema(Conversation.schema)
            .deleteField("group_lifecycle_state")
            .update()
    }
}

struct AddConversationUserSummaryGroupLifecycleState: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: ConversationUserSummary.schema)
                ADD COLUMN IF NOT EXISTS group_lifecycle_state TEXT NOT NULL DEFAULT 'active'
                """).run()
            return
        }

        try await database.schema(ConversationUserSummary.schema)
            .field("group_lifecycle_state", .string, .required, .sql(.default("active")))
            .update()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: ConversationUserSummary.schema)
                DROP COLUMN IF EXISTS group_lifecycle_state
                """).run()
            return
        }
        try await database.schema(ConversationUserSummary.schema)
            .deleteField("group_lifecycle_state")
            .update()
    }
}
