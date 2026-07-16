import Fluent
import SQLKit

struct AddReportReviewerAssignmentFields: AsyncMigration {
    private let fields: [(String, String)] = [
        ("assigned_reviewer_user_id", "UUID"),
        ("assigned_reviewer_actor", "TEXT"),
        ("assigned_at", "TIMESTAMP")
    ]

    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            switch sql.dialect.name {
            case "postgresql":
                for (name, type) in fields {
                    try await sql.raw("ALTER TABLE IF EXISTS \(unsafeRaw: UserReport.schema) ADD COLUMN IF NOT EXISTS \(unsafeRaw: name) \(unsafeRaw: type)").run()
                }

            case "sqlite":
                struct SQLiteColumnRow: Decodable {
                    let name: String
                }
                let columns = try await sql.raw("PRAGMA table_info(reports);").all(decoding: SQLiteColumnRow.self)
                let existing = Set(columns.map(\.name))
                for (name, type) in fields where !existing.contains(name) {
                    try await sql.raw("ALTER TABLE \(unsafeRaw: UserReport.schema) ADD COLUMN \(unsafeRaw: name) \(unsafeRaw: type)").run()
                }

            default:
                for (name, type) in fields {
                    try await sql.raw("ALTER TABLE \(unsafeRaw: UserReport.schema) ADD COLUMN \(unsafeRaw: name) \(unsafeRaw: type)").run()
                }
            }
        } else {
            try await database.schema(UserReport.schema)
                .field("assigned_reviewer_user_id", .uuid)
                .field("assigned_reviewer_actor", .string)
                .field("assigned_at", .datetime)
                .update()
        }

        guard let sql = database as? any SQLDatabase else {
            return
        }
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS reports_assigned_reviewer_status_created_idx
            ON reports (assigned_reviewer_user_id, status, created_at DESC)
            """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS reports_assigned_reviewer_status_created_idx").run()
        }
        try await database.schema(UserReport.schema)
            .deleteField("assigned_at")
            .deleteField("assigned_reviewer_actor")
            .deleteField("assigned_reviewer_user_id")
            .update()
    }
}
