import Fluent

struct CreateConversation: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Conversation.schema)
            .id()
            .field("title", .string)
            .field("updated_at", .datetime, .required)
            .field("created_at", .datetime)
            .ignoreExisting()
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Conversation.schema).delete()
    }
}

struct CreateConversationMember: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationMember.schema)
            .id()
            .field("conversation_id", .uuid, .required, .references(Conversation.schema, "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("joined_at", .datetime)
            .unique(on: "conversation_id", "user_id")
            .ignoreExisting()
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ConversationMember.schema).delete()
    }
}

struct CreateConversationMessage: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationMessage.schema)
            .id()
            .field("conversation_id", .uuid, .required, .references(Conversation.schema, "id", onDelete: .cascade))
            .field("sender_user_id", .uuid, .required, .references(User.schema, "id", onDelete: .restrict))
            .field("server_sequence", .int, .required)
            .field("kind", .string, .required)
            .field("body_json", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "conversation_id", "server_sequence")
            .ignoreExisting()
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ConversationMessage.schema).delete()
    }
}
