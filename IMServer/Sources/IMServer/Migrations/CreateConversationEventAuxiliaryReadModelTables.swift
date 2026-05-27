import Fluent

struct CreateConversationEventAuxiliaryReadModelTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationNotificationEntry.schema)
            .field(.id, .string, .identifier(auto: false))
            .field("owner_user_id", .uuid, .required)
            .field("event_id", .uuid, .required)
            .field("conversation_id", .uuid, .required)
            .field("event_type", .string, .required)
            .field("payload_json", .string, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .create()

        try await database.schema(ConversationReplayRecord.schema)
            .field(.id, .string, .identifier(auto: false))
            .field("event_id", .uuid, .required)
            .field("consumer_group_id", .string, .required)
            .field("source_topic", .string, .required)
            .field("conversation_id", .uuid, .required)
            .field("event_type", .string, .required)
            .field("aggregate_sequence", .int, .required)
            .field("producer_shard", .string, .required)
            .field("payload_json", .string, .required)
            .field("status", .string, .required)
            .field("last_error", .string)
            .field("receive_count", .int, .required)
            .field("replayed_at", .datetime)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ConversationReplayRecord.schema).delete()
        try await database.schema(ConversationNotificationEntry.schema).delete()
    }
}
