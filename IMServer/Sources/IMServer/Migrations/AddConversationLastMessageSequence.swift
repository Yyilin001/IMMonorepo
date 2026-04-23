import Fluent
import SQLKit

struct AddConversationLastMessageSequence: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("""
                ALTER TABLE \(unsafeRaw: Conversation.schema)
                ADD COLUMN IF NOT EXISTS last_message_sequence INTEGER NOT NULL DEFAULT 0
                """).run()
            return
        }

        try await database.schema(Conversation.schema)
            .field(
                "last_message_sequence",
                .int,
                .required,
                .sql(.default(SQLLiteral.numeric("0")))
            )
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Conversation.schema)
            .deleteField("last_message_sequence")
            .update()
    }
}
