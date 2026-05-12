import Fluent

struct CreateConversationUserSummary: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationUserSummary.schema)
            .field(.id, .string, .identifier(auto: false))
            .field("owner_user_id", .uuid, .required)
            .field("conversation_id", .uuid, .required)
            .field("title", .string)
            .field("kind", .string, .required)
            .field("direct_messaging_state", .string)
            .field("direct_peer_user_id", .uuid)
            .field("direct_peer_email", .string)
            .field("notice", .string)
            .field("avatar_preset", .string)
            .field("mute_all", .bool, .required, .sql(.default(false)))
            .field("member_count", .int, .required)
            .field("member_user_ids_json", .string, .required)
            .field("last_message_json", .string)
            .field("last_read_sequence", .int, .required)
            .field("unread_count", .int, .required)
            .field("is_pinned", .bool, .required)
            .field("pinned_at", .datetime)
            .field("is_muted", .bool, .required)
            .field("last_activity_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .field("is_removed", .bool, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ConversationUserSummary.schema).delete()
    }
}
