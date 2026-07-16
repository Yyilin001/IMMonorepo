import Fluent
import SQLKit

struct CreateConversationShardMigrations: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationShardMigration.schema)
            .field("conversation_id", .uuid, .identifier(auto: false))
            .field("source_cell_id", .string, .required)
            .field("source_shard_id", .string, .required)
            .field("source_route_version", .int, .required)
            .field("target_cell_id", .string, .required)
            .field("target_shard_id", .string, .required)
            .field("status", .string, .required)
            .field("source_member_count", .int, .required)
            .field("source_message_count", .int, .required)
            .field("source_domain_event_count", .int, .required)
            .field("source_domain_event_sequence_count", .int, .required)
            .field("source_timeline_notice_count", .int, .required)
            .field("source_media_reference_count", .int, .required)
            .field("source_recipient_snapshot_count", .int, .required, .sql(.default(0)))
            .field("copy_conversation_watermark", .int, .required, .sql(.default(0)))
            .field("copy_member_watermark", .int, .required, .sql(.default(0)))
            .field("copy_message_watermark", .int, .required, .sql(.default(0)))
            .field("copy_domain_event_watermark", .int, .required, .sql(.default(0)))
            .field("copy_domain_event_sequence_watermark", .int, .required, .sql(.default(0)))
            .field("copy_timeline_notice_watermark", .int, .required, .sql(.default(0)))
            .field("copy_media_reference_watermark", .int, .required, .sql(.default(0)))
            .field("copy_recipient_snapshot_watermark", .int, .required, .sql(.default(0)))
            .field("source_fingerprint", .string)
            .field("target_fingerprint", .string)
            .field("last_error_code", .string)
            .field("prepared_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .field("copy_started_at", .datetime)
            .field("copied_at", .datetime)
            .field("verified_at", .datetime)
            .field("cutover_at", .datetime)
            .field("cutover_lease_token", .string)
            .field("cutover_lease_expires_at", .datetime)
            .field("transfer_token", .string)
            .field("transfer_token_expires_at", .datetime)
            .ignoreExisting()
            .create()

        guard let sql = database as? any SQLDatabase else {
            return
        }
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_shard_migration_status_updated_idx
            ON conversation_shard_migrations (status, updated_at ASC)
            """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS conversation_shard_migration_status_updated_idx").run()
        }
        try await database.schema(ConversationShardMigration.schema).delete()
    }
}
