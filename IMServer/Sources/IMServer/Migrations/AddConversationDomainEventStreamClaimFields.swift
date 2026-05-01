import Fluent
import SQLKit

struct AddConversationDomainEventStreamClaimFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(ConversationDomainEvent.schema)
                .field("stream_publish_started_at", .datetime)
                .update()
            try await database.schema(ConversationDomainEvent.schema)
                .field("stream_publish_claimed_by", .string)
                .update()
            return
        }

        switch sql.dialect.name {
        case "postgresql":
            try await sql.raw(
                """
                ALTER TABLE IF EXISTS conversation_domain_events
                ADD COLUMN IF NOT EXISTS stream_publish_started_at TIMESTAMPTZ
                """
            ).run()
            try await sql.raw(
                """
                ALTER TABLE IF EXISTS conversation_domain_events
                ADD COLUMN IF NOT EXISTS stream_publish_claimed_by TEXT
                """
            ).run()
            try await sql.raw(
                """
                CREATE INDEX IF NOT EXISTS conversation_domain_events_stream_claim_idx
                ON conversation_domain_events (stream_published_at, stream_publish_started_at, created_at, id)
                """
            ).run()

        case "sqlite":
            struct SQLiteColumnRow: Decodable {
                let name: String
            }

            let rows = try await sql.raw(
                "PRAGMA table_info(conversation_domain_events)"
            ).all(decoding: SQLiteColumnRow.self)
            let existingColumns = Set(rows.map(\.name))

            if !existingColumns.contains("stream_publish_started_at") {
                try await sql.raw(
                    """
                    ALTER TABLE conversation_domain_events
                    ADD COLUMN stream_publish_started_at DATETIME
                    """
                ).run()
            }

            if !existingColumns.contains("stream_publish_claimed_by") {
                try await sql.raw(
                    """
                    ALTER TABLE conversation_domain_events
                    ADD COLUMN stream_publish_claimed_by TEXT
                    """
                ).run()
            }

            try await sql.raw(
                """
                CREATE INDEX IF NOT EXISTS conversation_domain_events_stream_claim_idx
                ON conversation_domain_events (stream_published_at, stream_publish_started_at, created_at, id)
                """
            ).run()

        default:
            try await database.schema(ConversationDomainEvent.schema)
                .field("stream_publish_started_at", .datetime)
                .update()
            try await database.schema(ConversationDomainEvent.schema)
                .field("stream_publish_claimed_by", .string)
                .update()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(ConversationDomainEvent.schema)
                .deleteField("stream_publish_started_at")
                .update()
            try await database.schema(ConversationDomainEvent.schema)
                .deleteField("stream_publish_claimed_by")
                .update()
            return
        }

        switch sql.dialect.name {
        case "postgresql":
            try await sql.raw("DROP INDEX IF EXISTS conversation_domain_events_stream_claim_idx").run()
            try await sql.raw(
                """
                ALTER TABLE IF EXISTS conversation_domain_events
                DROP COLUMN IF EXISTS stream_publish_started_at
                """
            ).run()
            try await sql.raw(
                """
                ALTER TABLE IF EXISTS conversation_domain_events
                DROP COLUMN IF EXISTS stream_publish_claimed_by
                """
            ).run()

        case "sqlite":
            try await sql.raw("DROP INDEX IF EXISTS conversation_domain_events_stream_claim_idx").run()

        default:
            try await database.schema(ConversationDomainEvent.schema)
                .deleteField("stream_publish_started_at")
                .update()
            try await database.schema(ConversationDomainEvent.schema)
                .deleteField("stream_publish_claimed_by")
                .update()
        }
    }
}
