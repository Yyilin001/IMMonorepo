import Fluent
import SQLKit

struct AddConversationDirectMessagingState: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("""
                ALTER TABLE \(unsafeRaw: Conversation.schema)
                ADD COLUMN IF NOT EXISTS direct_messaging_state TEXT NOT NULL DEFAULT 'active'
                """).run()
            return
        }

        try await database.schema(Conversation.schema)
            .field(
                "direct_messaging_state",
                .string,
                .required,
                .sql(.default(SQLLiteral.string(IMDirectMessagingState.active.rawValue)))
            )
            .update()

    }

    func revert(on database: any Database) async throws {
        try await database.schema(Conversation.schema)
            .deleteField("direct_messaging_state")
            .update()
    }

}
