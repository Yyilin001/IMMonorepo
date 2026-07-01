import Fluent
import SQLKit

struct EnsureUserProfileRevision: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: User.schema)
                ADD COLUMN IF NOT EXISTS profile_revision BIGINT NOT NULL DEFAULT 0
                """).run()
            return
        }

        if let sql = database as? any SQLDatabase, sql.dialect.name == "sqlite" {
            _ = sql
            return
        }

        try await database.schema(User.schema)
            .field("profile_revision", .int, .required, .sql(.default(0)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema)
            .deleteField("profile_revision")
            .update()
    }
}
