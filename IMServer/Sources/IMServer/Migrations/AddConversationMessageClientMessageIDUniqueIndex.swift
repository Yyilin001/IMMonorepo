import Fluent
import SQLKit

struct AddConversationMessageClientMessageIDUniqueIndex: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS im_messages_sender_client_message_unique_idx
            ON im_messages (conversation_id, sender_user_id, client_message_id)
            WHERE client_message_id IS NOT NULL
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS im_messages_sender_client_message_unique_idx").run()
    }
}
