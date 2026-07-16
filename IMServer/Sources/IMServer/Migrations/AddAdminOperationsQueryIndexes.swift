import Fluent
import SQLKit

struct AddAdminOperationsQueryIndexes: AsyncMigration {
    private let indexes: [(name: String, table: String, columns: String)] = [
        ("reports_status_created_idx", UserReport.schema, "status, created_at DESC"),
        ("admin_audit_events_actor_created_idx", AdminAuditEvent.schema, "actor, created_at DESC"),
        ("admin_audit_events_target_created_idx", AdminAuditEvent.schema, "target_type, target_id, created_at DESC"),
        ("admin_audit_events_request_id_created_idx", AdminAuditEvent.schema, "request_id, created_at DESC")
    ]

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }
        for index in indexes {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS \(unsafeRaw: index.name) ON \(unsafeRaw: index.table) (\(unsafeRaw: index.columns))"
            ).run()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }
        for index in indexes.reversed() {
            try await sql.raw("DROP INDEX IF EXISTS \(unsafeRaw: index.name)").run()
        }
    }
}
