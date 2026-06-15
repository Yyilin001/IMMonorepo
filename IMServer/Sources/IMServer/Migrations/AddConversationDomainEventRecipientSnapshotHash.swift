import Fluent

struct AddConversationDomainEventRecipientSnapshotHash: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationDomainEventRecipientSnapshot.schema)
            .field("recipient_hash", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ConversationDomainEventRecipientSnapshot.schema)
            .deleteField("recipient_hash")
            .update()
    }
}
