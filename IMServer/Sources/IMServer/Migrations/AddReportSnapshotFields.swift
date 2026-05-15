import Fluent
import SQLKit

struct AddReportSnapshotFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: UserReport.schema)
                ADD COLUMN IF NOT EXISTS message_snapshot_json TEXT
                """).run()
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: UserReport.schema)
                ADD COLUMN IF NOT EXISTS handled_note TEXT
                """).run()
            return
        }
        if let sql = database as? any SQLDatabase, sql.dialect.name == "sqlite" {
            return
        }
        try await database.schema(UserReport.schema)
            .field("message_snapshot_json", .string)
            .field("handled_note", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserReport.schema)
            .deleteField("handled_note")
            .deleteField("message_snapshot_json")
            .update()
    }
}
