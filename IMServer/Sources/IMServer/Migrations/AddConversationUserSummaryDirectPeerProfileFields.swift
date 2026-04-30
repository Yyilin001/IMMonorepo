import Fluent
import SQLKit

struct AddConversationUserSummaryDirectPeerProfileFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: ConversationUserSummary.schema)
                ADD COLUMN IF NOT EXISTS direct_peer_display_name TEXT
                """).run()
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: ConversationUserSummary.schema)
                ADD COLUMN IF NOT EXISTS direct_peer_avatar_preset TEXT
                """).run()
            return
        }

        try await database.schema(ConversationUserSummary.schema)
            .field("direct_peer_display_name", .string)
            .update()
        try await database.schema(ConversationUserSummary.schema)
            .field("direct_peer_avatar_preset", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ConversationUserSummary.schema)
            .deleteField("direct_peer_display_name")
            .update()
        try await database.schema(ConversationUserSummary.schema)
            .deleteField("direct_peer_avatar_preset")
            .update()
    }
}
