import Fluent

struct AddConversationUserSummaryDirectPeerProfileFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
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
