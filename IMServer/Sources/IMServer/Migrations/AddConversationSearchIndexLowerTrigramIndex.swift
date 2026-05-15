import Fluent
import SQLKit

struct AddConversationSearchIndexLowerTrigramIndex: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase,
              sql.dialect.name == "postgresql"
        else {
            return
        }

        try await sql.raw("CREATE EXTENSION IF NOT EXISTS pg_trgm").run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_message_search_index_lower_trgm_idx
            ON conversation_message_search_index
            USING GIN (LOWER(searchable_text) gin_trgm_ops)
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase,
              sql.dialect.name == "postgresql"
        else {
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS conversation_message_search_index_lower_trgm_idx").run()
    }
}
