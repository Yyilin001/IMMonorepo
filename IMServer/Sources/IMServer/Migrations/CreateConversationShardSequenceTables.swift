import Fluent
import SQLKit

/// Conversation-shard-only sequence and timeline tables.
///
/// The historical migration also creates owner-delivery sequence tables, which
/// belong to the owner summary shard. Keeping this migration scoped lets a
/// conversation shard be provisioned without user-directory dependencies.
struct CreateConversationShardSequenceTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationDomainEventSequence.schema)
            .field("conversation_id", .uuid, .identifier(auto: false))
            .field("last_sequence", .int, .required, .sql(.default(0)))
            .ignoreExisting()
            .create()

        try await database.schema(ConversationTimelineNotice.schema)
            .field("event_id", .uuid, .identifier(auto: false))
            .field("conversation_id", .uuid, .required)
            .field("timeline_sequence", .int, .required)
            .field("event_type", .string, .required)
            .field("actor_user_id", .uuid)
            .field("target_user_ids_json", .string, .required)
            .field("notice_kind", .string, .required)
            .field("params_json", .string, .required)
            .field("fallback_text", .string, .required)
            .field("created_at", .datetime, .required)
            .ignoreExisting()
            .create()

        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_timeline_notices_conversation_sequence_idx
            ON \(ident: ConversationTimelineNotice.schema) (
                \(ident: "conversation_id"),
                \(ident: "timeline_sequence") ASC
            )
            """).run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_domain_events_conversation_sequence_idx
            ON \(ident: ConversationDomainEvent.schema) (
                \(ident: "conversation_id"),
                \(ident: "aggregate_sequence") ASC
            )
            """).run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS im_messages_conversation_timeline_sequence_idx
            ON \(ident: ConversationMessage.schema) (
                \(ident: "conversation_id"),
                \(ident: "timeline_sequence") ASC
            )
            """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS im_messages_conversation_timeline_sequence_idx").run()
            try await sql.raw("DROP INDEX IF EXISTS conversation_domain_events_conversation_sequence_idx").run()
            try await sql.raw("DROP INDEX IF EXISTS conversation_timeline_notices_conversation_sequence_idx").run()
        }
        try await database.schema(ConversationTimelineNotice.schema).delete()
        try await database.schema(ConversationDomainEventSequence.schema).delete()
    }
}
