import Fluent

struct CreateConversationDomainEvent: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationDomainEvent.schema)
            .id()
            .field("conversation_id", .uuid, .required)
            .field("event_type", .string, .required)
            .field("payload_json", .string, .required)
            .field("status", .string, .required)
            .field("error_message", .string)
            .field("created_at", .datetime, .required)
            .field("processing_started_at", .datetime)
            .field("processed_at", .datetime)
            .field("retry_count", .int, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ConversationDomainEvent.schema).delete()
    }
}
