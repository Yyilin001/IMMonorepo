import Fluent
import SQLKit

struct AddConversationEventAuxiliaryReadModelIndexes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_notification_events_owner_updated_idx
            ON conversation_notification_events (owner_user_id, updated_at DESC)
            """).run()

        try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS conversation_notification_events_owner_event_idx
            ON conversation_notification_events (owner_user_id, event_id)
            """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_event_replay_records_status_updated_idx
            ON conversation_event_replay_records (status, updated_at ASC)
            """).run()

        try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS conversation_event_replay_records_group_event_idx
            ON conversation_event_replay_records (consumer_group_id, event_id)
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS conversation_event_replay_records_group_event_idx").run()
        try await sql.raw("DROP INDEX IF EXISTS conversation_event_replay_records_status_updated_idx").run()
        try await sql.raw("DROP INDEX IF EXISTS conversation_notification_events_owner_event_idx").run()
        try await sql.raw("DROP INDEX IF EXISTS conversation_notification_events_owner_updated_idx").run()
    }
}
