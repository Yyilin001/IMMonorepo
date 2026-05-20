import Fluent
import SQLKit

struct CreateAIMessageStreamIndex: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AIMessageStreamIndex.schema)
            .field("stream_id", .string, .identifier(auto: false))
            .field("message_id", .uuid, .required)
            .field("conversation_id", .uuid, .required)
            .field("user_id", .uuid, .required)
            .field("state", .string, .required)
            .field("last_chunk_index", .int, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .field("terminal_at", .datetime)
            .field("error_code", .string)
            .create()

        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS im_ai_message_streams_state_updated_idx
            ON \(ident: AIMessageStreamIndex.schema) (
                \(ident: "state"),
                \(ident: "updated_at")
            )
            """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS im_ai_message_streams_user_state_idx
            ON \(ident: AIMessageStreamIndex.schema) (
                \(ident: "user_id"),
                \(ident: "state")
            )
            """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS im_ai_message_streams_conversation_state_idx
            ON \(ident: AIMessageStreamIndex.schema) (
                \(ident: "conversation_id"),
                \(ident: "state")
            )
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(AIMessageStreamIndex.schema).delete()
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS im_ai_message_streams_state_updated_idx").run()
        try await sql.raw("DROP INDEX IF EXISTS im_ai_message_streams_user_state_idx").run()
        try await sql.raw("DROP INDEX IF EXISTS im_ai_message_streams_conversation_state_idx").run()
        try await database.schema(AIMessageStreamIndex.schema).delete()
    }
}
