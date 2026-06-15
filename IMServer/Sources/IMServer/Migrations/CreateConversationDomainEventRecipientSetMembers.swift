import Fluent
import SQLKit

struct CreateConversationDomainEventRecipientSetMembers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationDomainEventRecipientSetMember.schema)
            .field("id", .string, .identifier(auto: false))
            .field("recipient_hash", .string, .required)
            .field("user_id", .uuid, .required)
            .field("created_at", .datetime, .required)
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.raw("""
                CREATE INDEX IF NOT EXISTS conversation_domain_event_recipient_set_members_hash_user_idx
                ON \(ident: ConversationDomainEventRecipientSetMember.schema) (
                    \(ident: "recipient_hash"),
                    \(ident: "user_id")
                )
                """).run()
            try await sql.raw("""
                CREATE INDEX IF NOT EXISTS conversation_domain_event_recipient_set_members_user_idx
                ON \(ident: ConversationDomainEventRecipientSetMember.schema) (\(ident: "user_id"))
                """).run()
        }

        let recipientSets = try await ConversationDomainEventRecipientSet.query(on: database).all()
        for recipientSet in recipientSets {
            guard let recipientHash = recipientSet.id else {
                continue
            }
            try await ConversationDomainEventRecipientSetMember.writeMemberIndex(
                recipientHash: recipientHash,
                recipientUserIDs: recipientSet.recipientUserIDs(),
                createdAt: recipientSet.createdAt,
                on: database
            )
        }
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS conversation_domain_event_recipient_set_members_user_idx").run()
            try await sql.raw("DROP INDEX IF EXISTS conversation_domain_event_recipient_set_members_hash_user_idx").run()
        }
        try await database.schema(ConversationDomainEventRecipientSetMember.schema).delete()
    }
}
