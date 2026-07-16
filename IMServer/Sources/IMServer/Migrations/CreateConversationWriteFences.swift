import Fluent
import SQLKit

struct CreateConversationWriteFences: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationWriteFence.schema)
            .field("conversation_id", .uuid, .identifier(auto: false))
            .field("state", .string, .required)
            .field("epoch", .int, .required)
            .field("updated_at", .datetime, .required)
            .ignoreExisting()
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_write_fences_state_updated_idx
            ON conversation_write_fences (state, updated_at ASC)
            """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS conversation_write_fences_state_updated_idx").run()
        }
        try await database.schema(ConversationWriteFence.schema).delete()
    }
}
