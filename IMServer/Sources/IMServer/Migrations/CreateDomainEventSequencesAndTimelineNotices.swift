import Fluent
import SQLKit

struct CreateDomainEventSequencesAndTimelineNotices: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationDomainEventSequence.schema)
            .field("conversation_id", .uuid, .identifier(auto: false))
            .field("last_sequence", .int, .required, .sql(.default(0)))
            .ignoreExisting()
            .create()

        try await database.schema(OwnerContactEventSequence.schema)
            .field("owner_user_id", .uuid, .identifier(auto: false))
            .field("last_sequence", .int, .required, .sql(.default(0)))
            .ignoreExisting()
            .create()

        try await database.schema(OwnerDomainEventDeliveryCursor.schema)
            .field("owner_user_id", .uuid, .identifier(auto: false))
            .field("last_cursor", .int, .required, .sql(.default(0)))
            .ignoreExisting()
            .create()

        try await database.schema(OwnerDomainEventAggregateSequence.schema)
            .field("id", .string, .identifier(auto: false))
            .field("owner_user_id", .uuid, .required)
            .field("aggregate_type", .string, .required)
            .field("aggregate_id", .uuid, .required)
            .field("last_sequence", .int, .required, .sql(.default(0)))
            .unique(on: "owner_user_id", "aggregate_type", "aggregate_id")
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
            ALTER TABLE conversation_domain_events
            ADD COLUMN IF NOT EXISTS aggregate_sequence BIGINT NOT NULL DEFAULT 1
            """).run()
        try await sql.raw("""
            ALTER TABLE im_messages
            ADD COLUMN IF NOT EXISTS timeline_sequence BIGINT
            """).run()
        try await sql.raw("""
            UPDATE im_messages
            SET timeline_sequence = server_sequence
            WHERE timeline_sequence IS NULL
            """).run()
        try await sql.raw("""
            ALTER TABLE im_messages
            ALTER COLUMN timeline_sequence SET DEFAULT 1,
            ALTER COLUMN timeline_sequence SET NOT NULL
            """).run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_timeline_notices_conversation_sequence_idx
            ON conversation_timeline_notices (conversation_id, timeline_sequence ASC)
            """).run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_domain_events_conversation_sequence_idx
            ON conversation_domain_events (conversation_id, aggregate_sequence ASC)
            """).run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS im_messages_conversation_timeline_sequence_idx
            ON im_messages (conversation_id, timeline_sequence ASC)
            """).run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS owner_domain_event_aggregate_sequences_owner_aggregate_idx
            ON owner_domain_event_aggregate_sequences (owner_user_id, aggregate_type, aggregate_id)
            """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS owner_domain_event_aggregate_sequences_owner_aggregate_idx").run()
            try await sql.raw("DROP INDEX IF EXISTS im_messages_conversation_timeline_sequence_idx").run()
            try await sql.raw("DROP INDEX IF EXISTS conversation_domain_events_conversation_sequence_idx").run()
            try await sql.raw("DROP INDEX IF EXISTS conversation_timeline_notices_conversation_sequence_idx").run()
        }
        try await database.schema(ConversationTimelineNotice.schema).delete()
        try await database.schema(OwnerDomainEventAggregateSequence.schema).delete()
        try await database.schema(OwnerDomainEventDeliveryCursor.schema).delete()
        try await database.schema(OwnerContactEventSequence.schema).delete()
        try await database.schema(ConversationDomainEventSequence.schema).delete()
    }
}
