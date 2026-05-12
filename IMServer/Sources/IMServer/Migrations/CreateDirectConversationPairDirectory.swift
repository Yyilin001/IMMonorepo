import Fluent

struct CreateDirectConversationPairDirectory: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(DirectConversationPairDirectory.schema)
            .field("id", .string, .identifier(auto: false))
            .field("lower_user_id", .uuid, .required)
            .field("higher_user_id", .uuid, .required)
            .field("conversation_id", .uuid, .required)
            .field("direct_messaging_state", .string)
            .field("updated_at", .datetime, .required)
            .unique(on: "conversation_id")
            .unique(on: "lower_user_id", "higher_user_id", "conversation_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(DirectConversationPairDirectory.schema).delete()
    }
}
