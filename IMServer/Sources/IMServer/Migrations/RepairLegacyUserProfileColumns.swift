import Fluent
import SQLKit

struct RepairLegacyUserProfileColumns: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

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
        try await sql.raw("""
            ALTER TABLE IF EXISTS \(unsafeRaw: User.schema)
            ADD COLUMN IF NOT EXISTS email_verified_at TIMESTAMPTZ
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("""
            ALTER TABLE IF EXISTS \(unsafeRaw: User.schema)
            DROP COLUMN IF EXISTS email_verified_at,
            DROP COLUMN IF EXISTS profile_revision,
            DROP COLUMN IF EXISTS avatar_preset,
            DROP COLUMN IF EXISTS display_name
            """).run()
    }
}
