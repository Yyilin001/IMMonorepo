import Fluent

struct CreateAuthSession: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AuthSession.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("current_nonce", .string, .required)
            .field("previous_nonce", .string)
            .field("previous_valid_until", .datetime)
            .field("refresh_expires_at", .datetime, .required)
            .field("revoked_at", .datetime)
            .field("device_id", .string)
            .field("device_name", .string)
            .field("platform", .string)
            .field("app_version", .string)
            .field("last_seen_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .ignoreExisting()
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(AuthSession.schema).delete()
    }
}
