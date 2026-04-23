import Fluent

struct CreateFriendRequest: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(FriendRequest.schema)
            .id()
            .field("requester_user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("addressee_user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("status", .string, .required)
            .field("message", .string)
            .field("requester_remark", .string)
            .field("addressee_remark", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .field("responded_at", .datetime)
            .ignoreExisting()
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(FriendRequest.schema).delete()
    }
}
