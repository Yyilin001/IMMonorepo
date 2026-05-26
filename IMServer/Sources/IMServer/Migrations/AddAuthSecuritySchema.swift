import Fluent
import SQLKit

struct AddAuthSecuritySchema: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema)
            .field("email_verified_at", .datetime)
            .update()

        try await database.schema(AuthSession.schema)
            .field("revoked_reason", .string)
            .update()

        try await database.schema(AuthEmailVerificationChallenge.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("email", .string, .required)
            .field("code_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("attempt_count", .int, .required)
            .field("consumed_at", .datetime)
            .field("created_ip", .string)
            .field("created_user_agent", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .ignoreExisting()
            .create()

        try await database.schema(AuthPasswordResetChallenge.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("email", .string, .required)
            .field("code_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("attempt_count", .int, .required)
            .field("consumed_at", .datetime)
            .field("created_ip", .string)
            .field("created_user_agent", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .ignoreExisting()
            .create()

        try await database.schema(AuthSecurityEvent.schema)
            .id()
            .field("event_type", .string, .required)
            .field("user_id", .uuid)
            .field("email", .string)
            .field("session_id", .uuid)
            .field("device_id", .string)
            .field("ip_address", .string)
            .field("succeeded", .bool, .required)
            .field("failure_reason", .string)
            .field("metadata", .string)
            .field("created_at", .datetime)
            .ignoreExisting()
            .create()

        guard let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS auth_email_verification_lookup_idx
            ON auth_email_verification_challenges (email, expires_at DESC)
            WHERE consumed_at IS NULL
            """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS auth_password_reset_lookup_idx
            ON auth_password_reset_challenges (email, expires_at DESC)
            WHERE consumed_at IS NULL
            """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS auth_security_events_created_idx
            ON auth_security_events (created_at DESC)
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(AuthSecurityEvent.schema).delete()
            try await database.schema(AuthPasswordResetChallenge.schema).delete()
            try await database.schema(AuthEmailVerificationChallenge.schema).delete()
            try await database.schema(AuthSession.schema).deleteField("revoked_reason").update()
            try await database.schema(User.schema).deleteField("email_verified_at").update()
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS auth_security_events_created_idx").run()
        try await sql.raw("DROP INDEX IF EXISTS auth_password_reset_lookup_idx").run()
        try await sql.raw("DROP INDEX IF EXISTS auth_email_verification_lookup_idx").run()
        try await database.schema(AuthSecurityEvent.schema).delete()
        try await database.schema(AuthPasswordResetChallenge.schema).delete()
        try await database.schema(AuthEmailVerificationChallenge.schema).delete()
        try await database.schema(AuthSession.schema).deleteField("revoked_reason").update()
        try await database.schema(User.schema).deleteField("email_verified_at").update()
    }
}
