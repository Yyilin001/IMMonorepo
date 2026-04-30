import Fluent
import SQLKit

struct AddConversationMessageClientMessageID: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: ConversationMessage.schema)
                ADD COLUMN IF NOT EXISTS client_message_id TEXT
                """).run()
            return
        }

        try await database.schema(ConversationMessage.schema)
            .field("client_message_id", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ConversationMessage.schema)
            .deleteField("client_message_id")
            .update()
    }
}
