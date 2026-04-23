import Fluent

struct CreateUserContact: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserContact.schema)
            .id()
            .field("owner_user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("contact_user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .unique(on: "owner_user_id", "contact_user_id")
            .ignoreExisting()
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserContact.schema).delete()
    }
}

