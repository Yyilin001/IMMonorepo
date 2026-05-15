import Fluent
import SQLKit

struct CreateContactChangesLog: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ContactChangeLogEntry.schema)
            .field("id", .string, .identifier(auto: false))
            .field("owner_user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("entity_type", .string, .required)
            .field("entity_id", .uuid, .required)
            .field("updated_at", .datetime, .required)
            .field("is_removed", .bool, .required)
            .unique(on: "owner_user_id", "entity_type", "entity_id")
            .ignoreExisting()
            .create()

        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS contact_changes_owner_updated_id_idx
            ON contact_changes_log (owner_user_id, updated_at ASC, id ASC)
            """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS contact_changes_owner_updated_id_idx").run()
        }
        try await database.schema(ContactChangeLogEntry.schema).delete()
    }
}
