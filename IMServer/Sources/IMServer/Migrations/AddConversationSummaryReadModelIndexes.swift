import Fluent
import SQLKit

struct AddConversationSummaryReadModelIndexes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_changes_log_owner_updated_idx
            ON conversation_changes_log (owner_user_id, updated_at ASC, id ASC)
            """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_changes_log_owner_conversation_idx
            ON conversation_changes_log (owner_user_id, conversation_id)
            """).run()

        try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS conversation_read_model_tokens_owner_idx
            ON conversation_read_model_tokens (owner_user_id)
            """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_activity_summaries_updated_idx
            ON conversation_activity_summaries (updated_at ASC, conversation_id ASC)
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS conversation_activity_summaries_updated_idx").run()
        try await sql.raw("DROP INDEX IF EXISTS conversation_read_model_tokens_owner_idx").run()
        try await sql.raw("DROP INDEX IF EXISTS conversation_changes_log_owner_conversation_idx").run()
        try await sql.raw("DROP INDEX IF EXISTS conversation_changes_log_owner_updated_idx").run()
    }
}
