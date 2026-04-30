import Fluent
import SQLKit

struct AddConversationMessageClientMessageIDUniqueIndex: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        switch sql.dialect.name {
        case "postgresql":
            try await sql.raw(
                """
                DO $$
                BEGIN
                    IF EXISTS (
                        SELECT 1
                        FROM information_schema.tables
                        WHERE table_schema = 'public'
                          AND table_name = 'im_messages'
                    ) THEN
                        CREATE UNIQUE INDEX IF NOT EXISTS im_messages_sender_client_message_unique_idx
                        ON im_messages (conversation_id, sender_user_id, client_message_id)
                        WHERE client_message_id IS NOT NULL;
                    END IF;
                END $$;
                """
            ).run()

        case "sqlite":
            struct SQLiteTableRow: Decodable {
                let name: String
            }

            let rows = try await sql.raw(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'im_messages'"
            ).all(decoding: SQLiteTableRow.self)
            guard !rows.isEmpty else {
                return
            }

            try await sql.raw(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS im_messages_sender_client_message_unique_idx
                ON im_messages (conversation_id, sender_user_id, client_message_id)
                WHERE client_message_id IS NOT NULL
                """
            ).run()

        default:
            try await sql.raw(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS im_messages_sender_client_message_unique_idx
                ON im_messages (conversation_id, sender_user_id, client_message_id)
                WHERE client_message_id IS NOT NULL
                """
            ).run()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS im_messages_sender_client_message_unique_idx").run()
    }
}
