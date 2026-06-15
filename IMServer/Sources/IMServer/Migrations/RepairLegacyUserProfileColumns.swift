import Fluent
import SQLKit

struct RepairLegacyUserProfileColumns: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        if sql.dialect.name == "sqlite" {
            try await addSQLiteColumnIfMissing(
                table: User.schema,
                column: "display_name",
                definition: "TEXT",
                on: sql
            )
            try await addSQLiteColumnIfMissing(
                table: User.schema,
                column: "avatar_preset",
                definition: "TEXT",
                on: sql
            )
            try await addSQLiteColumnIfMissing(
                table: User.schema,
                column: "profile_revision",
                definition: "INTEGER NOT NULL DEFAULT 0",
                on: sql
            )
            try await addSQLiteColumnIfMissing(
                table: User.schema,
                column: "email_verified_at",
                definition: "DATETIME",
                on: sql
            )
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
        guard sql.dialect.name != "sqlite" else {
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

    private func addSQLiteColumnIfMissing(
        table: String,
        column: String,
        definition: String,
        on sql: any SQLDatabase
    ) async throws {
        struct SQLiteColumnRow: Decodable {
            let name: String
        }
        let rows = try await sql.raw("PRAGMA table_info(\(unsafeRaw: table))")
            .all(decoding: SQLiteColumnRow.self)
        guard !rows.contains(where: { $0.name == column }) else {
            return
        }
        try await sql.raw("""
            ALTER TABLE \(unsafeRaw: table)
            ADD COLUMN \(unsafeRaw: column) \(unsafeRaw: definition)
            """).run()
    }
}
