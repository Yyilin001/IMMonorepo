import Fluent
import SQLKit

struct AddConversationKind: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("""
                ALTER TABLE \(unsafeRaw: Conversation.schema)
                ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'group'
                """).run()
            try await backfillConversationKinds(using: sql)
            return
        }

        try await database.schema(Conversation.schema)
            .field(
                "kind",
                .string,
                .required,
                .sql(.default(SQLLiteral.string(IMConversationKind.group.rawValue)))
            )
            .update()

        if let sql = database as? any SQLDatabase {
            try await backfillConversationKinds(using: sql)
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Conversation.schema)
            .deleteField("kind")
            .update()
    }

    private func backfillConversationKinds(using sql: any SQLDatabase) async throws {
        try await sql.raw("""
            UPDATE \(unsafeRaw: Conversation.schema)
            SET kind = CASE
                WHEN title IS NULL
                 AND (
                    SELECT COUNT(*)
                    FROM \(unsafeRaw: ConversationMember.schema)
                    WHERE \(unsafeRaw: ConversationMember.schema).conversation_id = \(unsafeRaw: Conversation.schema).id
                 ) = 2
                THEN 'direct'
                ELSE 'group'
            END
            """).run()
    }
}
