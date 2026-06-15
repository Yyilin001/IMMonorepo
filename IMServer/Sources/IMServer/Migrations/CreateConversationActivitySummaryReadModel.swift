import Fluent
import SQLKit

struct CreateConversationActivitySummaryReadModel: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationActivitySummary.schema)
            .field("conversation_id", .uuid, .identifier(auto: false))
            .field("last_message_json", .string)
            .field("last_message_server_sequence", .int, .required)
            .field("last_activity_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .ignoreExisting()
            .create()

        guard let sql = database as? any SQLDatabase else {
            return
        }
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_activity_summaries_updated_idx
            ON conversation_activity_summaries (updated_at ASC, conversation_id ASC)
            """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS conversation_activity_summaries_updated_idx").run()
        }
        try await database.schema(ConversationActivitySummary.schema).delete()
    }
}
