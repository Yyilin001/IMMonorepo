import Fluent
import SQLKit

struct CreateConversationDomainEvent: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationDomainEvent.schema)
            .id()
            .field("conversation_id", .uuid, .required)
            .field("event_type", .string, .required)
            .field("aggregate_sequence", .int, .required)
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

struct AddConversationDomainEventSideEffectKey: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationDomainEventSideEffect.schema)
            .field("side_effect_key", .string, .identifier(auto: false))
            .field("event_id", .uuid, .required)
            .field("created_at", .datetime, .required)
            .ignoreExisting()
            .create()

        try await database.schema(ConversationDomainEvent.schema)
            .field("side_effect_key", .string)
            .update()
        if let sql = database as? any SQLDatabase {
            try await sql.raw("""
                CREATE UNIQUE INDEX IF NOT EXISTS conversation_domain_events_side_effect_key_idx
                ON conversation_domain_events (side_effect_key)
                WHERE side_effect_key IS NOT NULL
                """).run()
        }
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS conversation_domain_events_side_effect_key_idx").run()
        }
        try await database.schema(ConversationDomainEvent.schema)
            .deleteField("side_effect_key")
            .update()
        try await database.schema(ConversationDomainEventSideEffect.schema).delete()
    }
}
