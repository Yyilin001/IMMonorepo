import Fluent
import SQLKit

struct AddConversationUserSummaryListOrderIndex: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS im_conversation_user_summaries_list_order_idx
            ON im_conversation_user_summaries (
                owner_user_id,
                is_removed,
                is_pinned DESC,
                pinned_at DESC,
                last_activity_at DESC,
                id DESC
            )
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS im_conversation_user_summaries_list_order_idx").run()
    }
}
