import Fluent
import SQLKit

struct AddAdminManagementSchema: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await addAdminRoleColumnIfNeeded(on: sql)
        } else {
            try await database.schema(User.schema)
                .field("admin_role", .string)
                .update()
        }

        try await database.schema(AdminAuditEvent.schema)
            .id()
            .field("actor", .string, .required)
            .field("action", .string, .required)
            .field("target_type", .string)
            .field("target_id", .string)
            .field("request_id", .string)
            .field("ip_address", .string)
            .field("metadata_json", .string)
            .field("created_at", .datetime)
            .ignoreExisting()
            .create()

        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS admin_audit_events_created_idx
            ON admin_audit_events (created_at DESC)
            """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS admin_audit_events_action_created_idx
            ON admin_audit_events (action, created_at DESC)
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(AdminAuditEvent.schema).delete()
            try await database.schema(User.schema).deleteField("admin_role").update()
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS admin_audit_events_action_created_idx").run()
        try await sql.raw("DROP INDEX IF EXISTS admin_audit_events_created_idx").run()
        try await database.schema(AdminAuditEvent.schema).delete()
        try await database.schema(User.schema).deleteField("admin_role").update()
    }

    private func addAdminRoleColumnIfNeeded(on sql: any SQLDatabase) async throws {
        switch sql.dialect.name {
        case "postgresql":
            try await sql.raw("ALTER TABLE users ADD COLUMN IF NOT EXISTS admin_role TEXT").run()

        case "sqlite":
            struct SQLiteColumnRow: Decodable {
                let name: String
            }
            let columns = try await sql.raw("PRAGMA table_info(users);").all(decoding: SQLiteColumnRow.self)
            if columns.contains(where: { $0.name == "admin_role" }) {
                return
            }
            try await sql.raw("ALTER TABLE users ADD COLUMN admin_role TEXT").run()

        default:
            try await sql.raw("ALTER TABLE users ADD COLUMN admin_role TEXT").run()
        }
    }
}
