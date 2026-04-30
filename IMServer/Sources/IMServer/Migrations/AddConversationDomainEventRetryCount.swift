import Fluent
import SQLKit

struct AddConversationDomainEventRetryCount: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            return
        }

        try await sql.raw("""
            ALTER TABLE IF EXISTS conversation_domain_events
            ADD COLUMN IF NOT EXISTS retry_count INTEGER NOT NULL DEFAULT 0
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            return
        }

        try await sql.raw("""
            ALTER TABLE IF EXISTS conversation_domain_events
            DROP COLUMN IF EXISTS retry_count
            """).run()
    }
}
