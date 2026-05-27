import Fluent
import SQLKit

struct AddConversationDomainEventActor: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationDomainEvent.schema)
            .field("actor_user_id", .uuid)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ConversationDomainEvent.schema)
            .deleteField("actor_user_id")
            .update()
    }
}

struct CreateContactDomainEvent: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ContactDomainEvent.schema)
            .id()
            .field("owner_user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("event_type", .string, .required)
            .field("aggregate_id", .uuid, .required)
            .field("owner_sequence", .int, .required)
            .field("actor_user_id", .uuid)
            .field("payload_json", .string, .required)
            .field("status", .string, .required)
            .field("error_message", .string)
            .field("created_at", .datetime, .required)
            .field("processing_started_at", .datetime)
            .field("processed_at", .datetime)
            .field("retry_count", .int, .required)
            .unique(on: "owner_user_id", "owner_sequence")
            .ignoreExisting()
            .create()

        guard let sql = database as? any SQLDatabase else {
            return
        }
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS contact_domain_events_status_created_idx
            ON contact_domain_events (status, created_at ASC, id ASC)
            """).run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS contact_domain_events_owner_created_idx
            ON contact_domain_events (owner_user_id, created_at ASC, id ASC)
            """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS contact_domain_events_status_created_idx").run()
            try await sql.raw("DROP INDEX IF EXISTS contact_domain_events_owner_created_idx").run()
        }
        try await database.schema(ContactDomainEvent.schema).delete()
    }
}

struct CreateOwnerDomainEventDelivery: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(OwnerDomainEventDelivery.schema)
            .field("id", .string, .identifier(auto: false))
            .field("owner_user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("owner_cursor", .int, .required)
            .field("owner_aggregate_sequence", .int, .required)
            .field("aggregate_type", .string, .required)
            .field("aggregate_id", .uuid, .required)
            .field("event_id", .uuid, .required)
            .field("source_type", .string, .required)
            .field("source_event_id", .uuid, .required)
            .field("event_pb_base64", .string, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "owner_user_id", "owner_cursor")
            .unique(on: "owner_user_id", "event_id")
            .unique(on: "owner_user_id", "aggregate_type", "aggregate_id", "owner_aggregate_sequence")
            .ignoreExisting()
            .create()

        guard let sql = database as? any SQLDatabase else {
            return
        }
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS owner_domain_event_deliveries_owner_cursor_idx
            ON owner_domain_event_deliveries (owner_user_id, owner_cursor ASC)
            """).run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS owner_domain_event_deliveries_owner_aggregate_sequence_idx
            ON owner_domain_event_deliveries (owner_user_id, aggregate_type, aggregate_id, owner_aggregate_sequence ASC)
            """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS owner_domain_event_deliveries_owner_aggregate_sequence_idx").run()
            try await sql.raw("DROP INDEX IF EXISTS owner_domain_event_deliveries_owner_cursor_idx").run()
        }
        try await database.schema(OwnerDomainEventDelivery.schema).delete()
    }
}
