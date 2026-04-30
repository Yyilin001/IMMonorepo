import Fluent
import SQLKit

struct AddConversationMessageSearchIndexIndexes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_message_search_index_lookup_idx
            ON conversation_message_search_index (conversation_id, server_sequence DESC, id)
            """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_message_search_index_message_idx
            ON conversation_message_search_index (message_id)
            """).run()

        guard sql.dialect.name == "postgresql" else {
            return
        }

        try await sql.raw("CREATE EXTENSION IF NOT EXISTS pg_trgm").run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_message_search_index_trgm_idx
            ON conversation_message_search_index
            USING GIN (searchable_text gin_trgm_ops)
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS conversation_message_search_index_lookup_idx").run()
        try await sql.raw("DROP INDEX IF EXISTS conversation_message_search_index_message_idx").run()
        guard sql.dialect.name == "postgresql" else {
            return
        }
        try await sql.raw("DROP INDEX IF EXISTS conversation_message_search_index_trgm_idx").run()
    }
}
