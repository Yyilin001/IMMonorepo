import Fluent

struct CreateConversationSummaryReadModelTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationChangesLogEntry.schema)
            .field(.id, .string, .identifier(auto: false))
            .field("owner_user_id", .uuid, .required)
            .field("conversation_id", .uuid, .required)
            .field("summary_record_id", .string, .required)
            .field("updated_at", .datetime, .required)
            .field("is_removed", .bool, .required)
            .create()

        try await database.schema(ConversationReadModelToken.schema)
            .field(.id, .string, .identifier(auto: false))
            .field("owner_user_id", .uuid, .required)
            .field("target_token", .string, .required)
            .field("updated_at", .datetime, .required)
            .create()

        try await database.schema(ConversationActivitySummary.schema)
            .field("conversation_id", .uuid, .identifier(auto: false))
            .field("last_message_json", .string)
            .field("last_message_server_sequence", .int, .required)
            .field("last_activity_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ConversationActivitySummary.schema).delete()
        try await database.schema(ConversationReadModelToken.schema).delete()
        try await database.schema(ConversationChangesLogEntry.schema).delete()
    }
}
