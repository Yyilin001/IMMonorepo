import Fluent
import SQLKit

struct AddConversationUserSummaryIndexes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS im_conversation_user_summaries_list_idx
            ON im_conversation_user_summaries (owner_user_id, is_removed, last_activity_at DESC, id DESC)
            """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS im_conversation_user_summaries_changes_idx
            ON im_conversation_user_summaries (owner_user_id, updated_at ASC, id ASC)
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS im_conversation_user_summaries_list_idx").run()
        try await sql.raw("DROP INDEX IF EXISTS im_conversation_user_summaries_changes_idx").run()
    }
}
