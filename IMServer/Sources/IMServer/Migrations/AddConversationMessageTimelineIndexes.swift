import Fluent
import SQLKit

struct AddConversationMessageTimelineIndexes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS im_messages_conversation_sequence_desc_idx
            ON \(ident: ConversationMessage.schema) (
                \(ident: "conversation_id"),
                \(ident: "server_sequence") DESC
            )
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS im_messages_conversation_sequence_desc_idx").run()
    }
}
