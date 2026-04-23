import Fluent
import SQLKit

struct AddAuthIndexes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS auth_sessions_active_by_user_idx
            ON auth_sessions (user_id, last_seen_at DESC, refresh_expires_at DESC)
            WHERE revoked_at IS NULL
            """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS auth_sessions_active_by_device_idx
            ON auth_sessions (user_id, device_id)
            WHERE revoked_at IS NULL AND device_id IS NOT NULL
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS auth_sessions_active_by_user_idx").run()
        try await sql.raw("DROP INDEX IF EXISTS auth_sessions_active_by_device_idx").run()
    }
}
