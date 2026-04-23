import Fluent
import SQLKit

struct AddConversationMemberLastReadSequence: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("""
                ALTER TABLE \(unsafeRaw: ConversationMember.schema)
                ADD COLUMN IF NOT EXISTS last_read_sequence INTEGER NOT NULL DEFAULT 0
                """).run()
            return
        }

        try await database.schema(ConversationMember.schema)
            .field(
                "last_read_sequence",
                .int,
                .required,
                .sql(.default(SQLLiteral.numeric("0")))
            )
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ConversationMember.schema)
            .deleteField("last_read_sequence")
            .update()
    }
}
