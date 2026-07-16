import Fluent
import SQLKit

struct AddReportModerationIdempotencyKeys: AsyncMigration {
    private let tables = [
        ReportModerationDecision.schema,
        ReportModerationEvidence.schema
    ]

    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            switch sql.dialect.name {
            case "postgresql":
                for table in tables {
                    try await sql.raw("ALTER TABLE IF EXISTS \(unsafeRaw: table) ADD COLUMN IF NOT EXISTS idempotency_key TEXT").run()
                }
            case "sqlite":
                for table in tables {
                    struct SQLiteColumnRow: Decodable { let name: String }
                    let columns = try await sql.raw("PRAGMA table_info(\(unsafeRaw: table));").all(decoding: SQLiteColumnRow.self)
                    if !columns.contains(where: { $0.name == "idempotency_key" }) {
                        try await sql.raw("ALTER TABLE \(unsafeRaw: table) ADD COLUMN idempotency_key TEXT").run()
                    }
                }
            default:
                for table in tables {
                    try await sql.raw("ALTER TABLE \(unsafeRaw: table) ADD COLUMN idempotency_key TEXT").run()
                }
            }
        } else {
            for table in tables {
                try await database.schema(table).field("idempotency_key", .string).update()
            }
        }

        guard let sql = database as? any SQLDatabase else {
            return
        }
        try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS report_moderation_decisions_report_idempotency_key_idx
            ON report_moderation_decisions (report_id, idempotency_key)
            """).run()
        try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS report_moderation_evidence_report_idempotency_key_idx
            ON report_moderation_evidence (report_id, idempotency_key)
            """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS report_moderation_evidence_report_idempotency_key_idx").run()
            try await sql.raw("DROP INDEX IF EXISTS report_moderation_decisions_report_idempotency_key_idx").run()
        }
        for table in tables {
            try await database.schema(table).deleteField("idempotency_key").update()
        }
    }
}
