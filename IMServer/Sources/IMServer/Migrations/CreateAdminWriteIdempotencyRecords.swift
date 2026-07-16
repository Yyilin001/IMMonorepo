import Fluent
import SQLKit

struct CreateAdminWriteIdempotencyRecords: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AdminWriteIdempotencyRecord.schema)
            .id()
            .field("scope", .string, .required)
            .field("actor", .string, .required)
            .field("idempotency_key", .string, .required)
            .field("target_id", .string, .required)
            .field("request_digest", .string, .required)
            .field("created_at", .datetime)
            .ignoreExisting()
            .create()

        guard let sql = database as? any SQLDatabase else {
            return
        }
        try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS admin_write_idempotency_scope_key_idx
            ON admin_write_idempotency_records (scope, actor, idempotency_key)
            """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS admin_write_idempotency_scope_key_idx").run()
        }
        try await database.schema(AdminWriteIdempotencyRecord.schema).delete()
    }
}
