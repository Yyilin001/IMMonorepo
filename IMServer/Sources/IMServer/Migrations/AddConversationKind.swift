import Fluent
import SQLKit

struct AddConversationKind: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("""
                ALTER TABLE \(unsafeRaw: Conversation.schema)
                ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'group'
                """).run()
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

    }

    func revert(on database: any Database) async throws {
        try await database.schema(Conversation.schema)
            .deleteField("kind")
            .update()
    }

}
