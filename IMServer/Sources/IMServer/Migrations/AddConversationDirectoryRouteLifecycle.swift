import Fluent
import SQLKit

struct AddConversationDirectoryRouteLifecycle: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(ConversationDirectoryEntry.schema)
                .field("route_state", .string, .required, .sql(.default("active")))
                .field("route_version", .int, .required, .sql(.default(1)))
                .field("updated_at", .datetime)
                .field("activated_at", .datetime)
                .update()
            return
        }

        switch sql.dialect.name {
        case "postgresql":
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: ConversationDirectoryEntry.schema)
                ADD COLUMN IF NOT EXISTS route_state TEXT NOT NULL DEFAULT 'active',
                ADD COLUMN IF NOT EXISTS route_version INTEGER NOT NULL DEFAULT 1,
                ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP,
                ADD COLUMN IF NOT EXISTS activated_at TIMESTAMP
                """).run()
        case "sqlite":
            struct SQLiteColumnRow: Decodable { let name: String }
            let columns = try await sql.raw(
                "PRAGMA table_info(\(unsafeRaw: ConversationDirectoryEntry.schema));"
            ).all(decoding: SQLiteColumnRow.self)
            let existingColumns = Set(columns.map(\.name))
            if !existingColumns.contains("route_state") {
                try await sql.raw("""
                    ALTER TABLE \(unsafeRaw: ConversationDirectoryEntry.schema)
                    ADD COLUMN route_state TEXT NOT NULL DEFAULT 'active'
                    """).run()
            }
            if !existingColumns.contains("route_version") {
                try await sql.raw("""
                    ALTER TABLE \(unsafeRaw: ConversationDirectoryEntry.schema)
                    ADD COLUMN route_version INTEGER NOT NULL DEFAULT 1
                    """).run()
            }
            if !existingColumns.contains("updated_at") {
                try await sql.raw("""
                    ALTER TABLE \(unsafeRaw: ConversationDirectoryEntry.schema)
                    ADD COLUMN updated_at DATETIME
                    """).run()
            }
            if !existingColumns.contains("activated_at") {
                try await sql.raw("""
                    ALTER TABLE \(unsafeRaw: ConversationDirectoryEntry.schema)
                    ADD COLUMN activated_at DATETIME
                    """).run()
            }
        default:
            try await database.schema(ConversationDirectoryEntry.schema)
                .field("route_state", .string, .required, .sql(.default("active")))
                .field("route_version", .int, .required, .sql(.default(1)))
                .field("updated_at", .datetime)
                .field("activated_at", .datetime)
                .update()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase,
              sql.dialect.name == "postgresql"
        else {
            return
        }
        try await sql.raw("""
            ALTER TABLE IF EXISTS \(unsafeRaw: ConversationDirectoryEntry.schema)
            DROP COLUMN IF EXISTS activated_at,
            DROP COLUMN IF EXISTS updated_at,
            DROP COLUMN IF EXISTS route_version,
            DROP COLUMN IF EXISTS route_state
            """).run()
    }
}
