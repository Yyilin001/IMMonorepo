import Fluent
import SQLKit

struct CreateConversationDomainEventRecipientSet: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationDomainEventRecipientSet.schema)
            .field("recipient_hash", .string, .identifier(auto: false))
            .field("recipient_user_ids_json", .string, .required)
            .field("recipient_count", .int, .required)
            .field("created_at", .datetime, .required)
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.raw("""
                CREATE INDEX IF NOT EXISTS conversation_domain_event_recipient_sets_count_idx
                ON \(ident: ConversationDomainEventRecipientSet.schema) (\(ident: "recipient_count"))
                """).run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ConversationDomainEventRecipientSet.schema).delete()
    }
}
