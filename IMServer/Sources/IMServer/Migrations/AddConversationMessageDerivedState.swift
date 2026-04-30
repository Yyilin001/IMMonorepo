import Fluent
import SQLKit

struct AddConversationMessageDerivedState: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: ConversationMessage.schema)
                ADD COLUMN IF NOT EXISTS derived_state_json TEXT
                """).run()
            return
        }

        try await database.schema(ConversationMessage.schema)
            .field("derived_state_json", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ConversationMessage.schema)
            .deleteField("derived_state_json")
            .update()
    }
}
