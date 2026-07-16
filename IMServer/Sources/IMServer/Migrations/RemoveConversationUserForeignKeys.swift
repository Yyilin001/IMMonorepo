import Fluent
import SQLKit

// Conversation shards own membership and message facts; user IDs are resolved
// through the primary user directory rather than a local users table.
struct RemoveConversationUserForeignKeys: AsyncMigration {
    private struct ForeignKeyConstraint: Decodable {
        let tableName: String
        let constraintName: String
    }

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase,
              sql.dialect.name == "postgresql"
        else {
            return
        }

        let constraints = try await sql.raw("""
            SELECT
                tc.table_name AS "tableName",
                tc.constraint_name AS "constraintName"
            FROM information_schema.table_constraints AS tc
            INNER JOIN information_schema.key_column_usage AS kcu
                ON tc.constraint_name = kcu.constraint_name
                AND tc.table_schema = kcu.table_schema
            INNER JOIN information_schema.constraint_column_usage AS ccu
                ON tc.constraint_name = ccu.constraint_name
                AND tc.table_schema = ccu.table_schema
            WHERE tc.constraint_type = 'FOREIGN KEY'
              AND tc.table_schema = current_schema()
              AND ccu.table_name = 'users'
              AND (
                    (tc.table_name = 'conversation_members' AND kcu.column_name = 'user_id')
                 OR (tc.table_name = 'im_messages' AND kcu.column_name = 'sender_user_id')
              )
            """).all(decoding: ForeignKeyConstraint.self)

        for constraint in constraints {
            try await sql.raw("""
                ALTER TABLE \(ident: constraint.tableName)
                DROP CONSTRAINT IF EXISTS \(ident: constraint.constraintName)
                """).run()
        }
    }

    func revert(on database: any Database) async throws {
        // Reintroducing cross-database user foreign keys would make a shard
        // undeployable without a replicated users table, so this is intentionally a no-op.
    }
}
