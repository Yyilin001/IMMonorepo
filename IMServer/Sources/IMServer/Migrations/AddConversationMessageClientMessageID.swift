import Fluent

struct AddConversationMessageClientMessageID: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationMessage.schema)
            .field("client_message_id", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ConversationMessage.schema)
            .deleteField("client_message_id")
            .update()
    }
}
