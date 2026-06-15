import Fluent
import SQLKit

struct AddTimelineReadPathIndexes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS im_messages_conversation_timeline_server_sequence_idx
            ON \(ident: ConversationMessage.schema) (
                \(ident: "conversation_id"),
                \(ident: "timeline_sequence") ASC,
                \(ident: "server_sequence") ASC
            )
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS im_messages_conversation_timeline_server_sequence_idx").run()
    }
}
