import Fluent
import SQLKit

struct CreateConversationMediaAssetReference: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationMediaAssetReference.schema)
            .field(.id, .string, .identifier(auto: false))
            .field("asset_id", .string, .required)
            .field("owner_user_id", .uuid, .required)
            .field("conversation_id", .uuid, .required)
            .field("message_id", .uuid, .required)
            .field("server_sequence", .int, .required)
            .field("kind", .string, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .unique(on: "message_id")
            .ignoreExisting()
            .create()

        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_media_asset_references_asset_idx
            ON conversation_media_asset_references (asset_id, conversation_id, server_sequence)
            """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_media_asset_references_conversation_sequence_idx
            ON conversation_media_asset_references (conversation_id, server_sequence)
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(ConversationMediaAssetReference.schema).delete()
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS conversation_media_asset_references_asset_idx").run()
        try await sql.raw("DROP INDEX IF EXISTS conversation_media_asset_references_conversation_sequence_idx").run()
        try await database.schema(ConversationMediaAssetReference.schema).delete()
    }
}
