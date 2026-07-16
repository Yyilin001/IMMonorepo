import Fluent
import SQLKit

struct CreateAIStreamLease: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AIStreamLease.schema)
            .field("stream_id", .string, .identifier(auto: false))
            .field("conversation_id", .uuid, .required)
            .field("user_id", .uuid, .required)
            .field("node_id", .string, .required)
            .field("state", .string, .required)
            .field("cancel_requested", .bool, .required)
            .field("expires_at", .datetime, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .ignoreExisting()
            .create()

        guard let sql = database as? any SQLDatabase else {
            return
        }
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS im_ai_stream_leases_user_expires_idx
            ON \(ident: AIStreamLease.schema) (\(ident: "user_id"), \(ident: "expires_at"))
            """).run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS im_ai_stream_leases_conversation_expires_idx
            ON \(ident: AIStreamLease.schema) (\(ident: "conversation_id"), \(ident: "expires_at"))
            """).run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS im_ai_stream_leases_expires_idx
            ON \(ident: AIStreamLease.schema) (\(ident: "expires_at"))
            """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS im_ai_stream_leases_user_expires_idx").run()
            try await sql.raw("DROP INDEX IF EXISTS im_ai_stream_leases_conversation_expires_idx").run()
            try await sql.raw("DROP INDEX IF EXISTS im_ai_stream_leases_expires_idx").run()
        }
        try await database.schema(AIStreamLease.schema).delete()
    }
}
