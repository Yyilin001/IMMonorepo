import Fluent
import SQLKit

struct AddConversationDomainEventStreamPublicationFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(ConversationDomainEvent.schema)
                .field("stream_published_at", .datetime)
                .update()
            try await database.schema(ConversationDomainEvent.schema)
                .field("stream_publish_error", .string)
                .update()
            return
        }

        switch sql.dialect.name {
        case "postgresql":
            try await sql.raw(
                """
                ALTER TABLE IF EXISTS conversation_domain_events
                ADD COLUMN IF NOT EXISTS stream_published_at TIMESTAMPTZ
                """
            ).run()
            try await sql.raw(
                """
                ALTER TABLE IF EXISTS conversation_domain_events
                ADD COLUMN IF NOT EXISTS stream_publish_error TEXT
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

            if !existingColumns.contains("stream_published_at") {
                try await sql.raw(
                    """
                    ALTER TABLE conversation_domain_events
                    ADD COLUMN stream_published_at DATETIME
                    """
                ).run()
            }

            if !existingColumns.contains("stream_publish_error") {
                try await sql.raw(
                    """
                    ALTER TABLE conversation_domain_events
                    ADD COLUMN stream_publish_error TEXT
                    """
                ).run()
            }

        default:
            try await database.schema(ConversationDomainEvent.schema)
                .field("stream_published_at", .datetime)
                .update()
            try await database.schema(ConversationDomainEvent.schema)
                .field("stream_publish_error", .string)
                .update()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(ConversationDomainEvent.schema)
                .deleteField("stream_published_at")
                .update()
            try await database.schema(ConversationDomainEvent.schema)
                .deleteField("stream_publish_error")
                .update()
            return
        }

        switch sql.dialect.name {
        case "postgresql":
            try await sql.raw(
                """
                ALTER TABLE IF EXISTS conversation_domain_events
                DROP COLUMN IF EXISTS stream_published_at
                """
            ).run()
            try await sql.raw(
                """
                ALTER TABLE IF EXISTS conversation_domain_events
                DROP COLUMN IF EXISTS stream_publish_error
                """
            ).run()

        case "sqlite":
            return

        default:
            try await database.schema(ConversationDomainEvent.schema)
                .deleteField("stream_published_at")
                .update()
            try await database.schema(ConversationDomainEvent.schema)
                .deleteField("stream_publish_error")
                .update()
        }
    }
}
