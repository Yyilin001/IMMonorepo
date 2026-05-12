import Fluent
import SQLKit

struct CreateConversationMediaAssetReferenceDirectory: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationMediaAssetReferenceDirectory.schema)
            .field(.id, .string, .identifier(auto: false))
            .field("asset_id", .string, .required)
            .field("shard_id", .string, .required)
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
            CREATE INDEX IF NOT EXISTS conversation_media_asset_reference_directory_asset_idx
            ON conversation_media_asset_reference_directory (asset_id, shard_id, conversation_id, server_sequence)
            """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_media_asset_reference_directory_message_idx
            ON conversation_media_asset_reference_directory (message_id)
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(ConversationMediaAssetReferenceDirectory.schema).delete()
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS conversation_media_asset_reference_directory_asset_idx").run()
        try await sql.raw("DROP INDEX IF EXISTS conversation_media_asset_reference_directory_message_idx").run()
        try await database.schema(ConversationMediaAssetReferenceDirectory.schema).delete()
    }
}
