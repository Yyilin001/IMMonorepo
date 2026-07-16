import Fluent
import SQLKit

struct CreateReportModerationDecisionHistory: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ReportModerationDecision.schema)
            .id()
            .field("report_id", .uuid, .required, .references(UserReport.schema, "id", onDelete: .cascade))
            .field("reviewer_actor", .string, .required)
            .field("reviewer_user_id", .uuid)
            .field("reviewer_role", .string, .required)
            .field("authentication_method", .string, .required)
            .field("previous_status", .string, .required)
            .field("status", .string, .required)
            .field("resolution_category", .string)
            .field("handled_note", .string)
            .field("request_id", .string)
            .field("idempotency_key", .string)
            .field("created_at", .datetime)
            .ignoreExisting()
            .create()

        guard let sql = database as? any SQLDatabase else {
            return
        }
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS report_moderation_decisions_report_created_idx
            ON report_moderation_decisions (report_id, created_at DESC)
            """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS report_moderation_decisions_report_created_idx").run()
        }
        try await database.schema(ReportModerationDecision.schema).delete()
    }
}
