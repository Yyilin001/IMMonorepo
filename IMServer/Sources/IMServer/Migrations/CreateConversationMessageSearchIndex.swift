import Fluent

struct CreateConversationMessageSearchIndex: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationMessageSearchIndex.schema)
            .field(.id, .string, .identifier(auto: false))
            .field("conversation_id", .uuid, .required)
            .field("message_id", .uuid, .required)
            .field("server_sequence", .int, .required)
            .field("message_type", .string, .required)
            .field("searchable_text", .string, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ConversationMessageSearchIndex.schema).delete()
    }
}
