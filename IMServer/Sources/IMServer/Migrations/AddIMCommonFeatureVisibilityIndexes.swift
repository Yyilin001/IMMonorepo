import Fluent
import SQLKit

struct AddIMCommonFeatureVisibilityIndexes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS message_visibility_overrides_owner_message_idx
            ON \(ident: MessageVisibilityOverride.schema) (
                \(ident: "owner_user_id"),
                \(ident: "message_id")
            )
            """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS message_visibility_overrides_owner_conversation_sequence_idx
            ON \(ident: MessageVisibilityOverride.schema) (
                \(ident: "owner_user_id"),
                \(ident: "conversation_id"),
                \(ident: "server_sequence")
            )
            """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS conversation_visibility_overrides_owner_conversation_idx
            ON \(ident: ConversationVisibilityOverride.schema) (
                \(ident: "owner_user_id"),
                \(ident: "conversation_id")
            )
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS conversation_visibility_overrides_owner_conversation_idx").run()
        try await sql.raw("DROP INDEX IF EXISTS message_visibility_overrides_owner_conversation_sequence_idx").run()
        try await sql.raw("DROP INDEX IF EXISTS message_visibility_overrides_owner_message_idx").run()
    }
}
