import Fluent
import SQLKit

struct AddConversationDomainEventIndexes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_domain_events_status_created_idx
            ON conversation_domain_events (status, created_at, id)
            """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_domain_events_conversation_created_idx
            ON conversation_domain_events (conversation_id, created_at, id)
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS conversation_domain_events_status_created_idx").run()
        try await sql.raw("DROP INDEX IF EXISTS conversation_domain_events_conversation_created_idx").run()
    }
}
