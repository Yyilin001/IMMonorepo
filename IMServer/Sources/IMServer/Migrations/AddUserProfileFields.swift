import Fluent

struct AddUserProfileFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema)
            .field("display_name", .string)
            .update()
        try await database.schema(User.schema)
            .field("avatar_preset", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema)
            .deleteField("display_name")
            .update()
        try await database.schema(User.schema)
            .deleteField("avatar_preset")
            .update()
    }
}
