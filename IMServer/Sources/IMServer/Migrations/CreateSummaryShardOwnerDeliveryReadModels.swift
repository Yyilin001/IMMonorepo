import Fluent
import SQLKit

// Owner delivery is read and written through SummaryShardRouter. These tables
// must therefore exist in every summary shard, not only in the primary DB.
struct CreateSummaryShardOwnerDeliveryReadModels: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(OwnerDomainEventDelivery.schema)
            .field("id", .string, .identifier(auto: false))
            .field("owner_user_id", .uuid, .required)
            .field("owner_cursor", .int, .required)
            .field("owner_aggregate_sequence", .int, .required)
            .field("aggregate_type", .string, .required)
            .field("aggregate_id", .uuid, .required)
            .field("event_id", .uuid, .required)
            .field("source_type", .string, .required)
            .field("source_event_id", .uuid, .required)
            .field("event_pb_base64", .string, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "owner_user_id", "owner_cursor", name: "uq_owner_delivery_cursor")
            .unique(on: "owner_user_id", "event_id", name: "uq_owner_delivery_event")
            .unique(
                on: "owner_user_id", "aggregate_type", "aggregate_id", "owner_aggregate_sequence",
                name: "uq_owner_delivery_aggregate_seq"
            )
            .ignoreExisting()
            .create()

        try await database.schema(OwnerDomainEventDeliveryCursor.schema)
            .field("owner_user_id", .uuid, .identifier(auto: false))
            .field("last_cursor", .int, .required, .sql(.default(0)))
            .ignoreExisting()
            .create()

        try await database.schema(OwnerDomainEventAggregateSequence.schema)
            .field("id", .string, .identifier(auto: false))
            .field("owner_user_id", .uuid, .required)
            .field("aggregate_type", .string, .required)
            .field("aggregate_id", .uuid, .required)
            .field("last_sequence", .int, .required, .sql(.default(0)))
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
        try await database.schema(OwnerDomainEventAggregateSequence.schema).delete()
        try await database.schema(OwnerDomainEventDeliveryCursor.schema).delete()
        try await database.schema(OwnerDomainEventDelivery.schema).delete()
    }
}
