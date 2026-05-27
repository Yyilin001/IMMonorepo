import Fluent
import SQLKit

struct AddUserProfileFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: User.schema)
                ADD COLUMN IF NOT EXISTS display_name TEXT
                """).run()
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: User.schema)
                ADD COLUMN IF NOT EXISTS avatar_preset TEXT
                """).run()
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: User.schema)
                ADD COLUMN IF NOT EXISTS profile_revision BIGINT NOT NULL DEFAULT 0
                """).run()
            return
        }

        try await database.schema(User.schema)
            .field("display_name", .string)
            .update()
        try await database.schema(User.schema)
            .field("avatar_preset", .string)
            .update()
        try await database.schema(User.schema)
            .field("profile_revision", .int, .required, .sql(.default(0)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema)
            .deleteField("display_name")
            .update()
        try await database.schema(User.schema)
            .deleteField("avatar_preset")
            .update()
        try await database.schema(User.schema)
            .deleteField("profile_revision")
            .update()
    }
}
