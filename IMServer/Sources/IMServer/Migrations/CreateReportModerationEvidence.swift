import Fluent
import SQLKit

struct CreateReportModerationEvidence: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ReportModerationEvidence.schema)
            .id()
            .field("report_id", .uuid, .required, .references(UserReport.schema, "id", onDelete: .cascade))
            .field("evidence_url", .string, .required)
            .field("label", .string)
            .field("submitted_by_actor", .string, .required)
            .field("submitted_by_user_id", .uuid)
            .field("submitter_role", .string, .required)
            .field("authentication_method", .string, .required)
            .field("request_id", .string)
            .field("idempotency_key", .string)
            .field("created_at", .datetime)
            .ignoreExisting()
            .create()

        guard let sql = database as? any SQLDatabase else {
            return
        }
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS report_moderation_evidence_report_created_idx
            ON report_moderation_evidence (report_id, created_at DESC)
            """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS report_moderation_evidence_report_created_idx").run()
        }
        try await database.schema(ReportModerationEvidence.schema).delete()
    }
}
