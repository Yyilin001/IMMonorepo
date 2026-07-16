import Fluent
import SQLKit

struct CreateAdminConversationGovernanceCommands: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AdminConversationGovernanceCommand.schema)
            .id()
            .field("action", .string, .required)
            .field("conversation_id", .uuid, .required)
            .field("target_shard_id", .string, .required)
            .field("target_cell_id", .string, .required, .sql(.default("default")))
            .field("target_route_version", .int, .required, .sql(.default(1)))
            .field("actor", .string, .required)
            .field("actor_user_id", .uuid)
            .field("actor_role", .string, .required)
            .field("authentication_method", .string, .required)
            .field("idempotency_key", .string, .required)
            .field("request_digest", .string, .required)
            .field("requested_mute_all", .bool, .required)
            .field("reason", .string, .required)
            .field("status", .string, .required)
            .field("attempt_count", .int, .required)
            .field("last_error_code", .string)
            .field("accepted_at", .datetime, .required)
            .field("applied_at", .datetime)
            .field("updated_at", .datetime, .required)
            .ignoreExisting()
            .create()

        guard let sql = database as? any SQLDatabase else {
            return
        }
        try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS admin_governance_command_actor_action_key_idx
            ON admin_conversation_governance_commands (actor, action, idempotency_key)
            """).run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS admin_governance_command_status_updated_idx
            ON admin_conversation_governance_commands (status, updated_at ASC)
            """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS admin_governance_command_status_updated_idx").run()
            try await sql.raw("DROP INDEX IF EXISTS admin_governance_command_actor_action_key_idx").run()
        }
        try await database.schema(AdminConversationGovernanceCommand.schema).delete()
    }
}
