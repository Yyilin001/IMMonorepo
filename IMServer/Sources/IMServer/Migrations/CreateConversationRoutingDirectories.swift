import Fluent

struct CreateConversationRoutingDirectories: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationDirectoryEntry.schema)
            .field("conversation_id", .uuid, .identifier(auto: false))
            .field("shard_id", .string, .required)
            .field("created_at", .datetime)
            .field("cell_id", .string, .required, .sql(.default("default")))
            .field("route_state", .string, .required, .sql(.default("active")))
            .field("route_version", .int, .required, .sql(.default(1)))
            .field("updated_at", .datetime)
            .field("activated_at", .datetime)
            .create()

        try await database.schema(DirectConversationIndexEntry.schema)
            .field("pair_hash", .string, .identifier(auto: false))
            .field("conversation_id", .uuid, .required)
            .field("shard_id", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "conversation_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(DirectConversationIndexEntry.schema).delete()
        try await database.schema(ConversationDirectoryEntry.schema).delete()
    }
}
