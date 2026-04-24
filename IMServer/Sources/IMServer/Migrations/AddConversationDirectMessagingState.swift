import Fluent
import SQLKit

struct AddConversationDirectMessagingState: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("""
                ALTER TABLE \(unsafeRaw: Conversation.schema)
                ADD COLUMN IF NOT EXISTS direct_messaging_state TEXT NOT NULL DEFAULT 'active'
                """).run()
            try await backfillDirectMessagingState(using: sql)
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

        if let sql = database as? any SQLDatabase {
            try await backfillDirectMessagingState(using: sql)
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Conversation.schema)
            .deleteField("direct_messaging_state")
            .update()
    }

    private func backfillDirectMessagingState(using sql: any SQLDatabase) async throws {
        try await sql.raw("""
            UPDATE \(unsafeRaw: Conversation.schema)
            SET direct_messaging_state = 'active'
            WHERE direct_messaging_state IS NULL
               OR direct_messaging_state = ''
            """).run()
    }
}
