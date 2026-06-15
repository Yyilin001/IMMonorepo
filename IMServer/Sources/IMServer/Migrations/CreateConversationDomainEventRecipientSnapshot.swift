import Fluent
import SQLKit

struct CreateConversationDomainEventRecipientSnapshot: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationDomainEventRecipientSnapshot.schema)
            .field("event_id", .uuid, .identifier(auto: false))
            .field("conversation_id", .uuid, .required)
            .field("recipient_user_ids_json", .string, .required)
            .field("recipient_count", .int, .required)
            .field("created_at", .datetime, .required)
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.raw("""
                CREATE INDEX IF NOT EXISTS conversation_domain_event_recipient_snapshots_conversation_idx
                ON \(ident: ConversationDomainEventRecipientSnapshot.schema) (\(ident: "conversation_id")
                )
                """).run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ConversationDomainEventRecipientSnapshot.schema).delete()
    }
}
