import Fluent
import SQLKit

public enum V2SchemaReadinessError: Error, Equatable, Sendable { case unavailableTable(String), unsupportedDatabase }

/// Startup gate for the clean V2 schema. It makes schema provisioning a
/// deployment prerequisite instead of discovering a missing table after a TLS
/// listener is already accepting authenticated traffic.
public enum V2SchemaReadiness {
    private static let requiredTables = [
        "auth_devices", "device_access_tokens", "device_revocation_events", "gateway_worker_cursors", "account_password_credentials",
        "rooms", "direct_room_pairs", "direct_room_operations", "group_rooms", "group_room_operations", "user_relationships", "user_blocks", "user_stranger_message_preferences", "stranger_message_preference_operations", "stranger_message_windows", "room_memberships", "room_membership_operations", "message_withdrawal_operations", "message_edit_operations", "message_reactions", "message_reaction_operations", "room_read_receipts", "read_receipt_operations", "room_admission",
        "shard_admission_pools", "messages", "room_events", "room_outbox", "durable_work_replay_audit",
        "fanout_plans", "fanout_plan_targets", "fanout_completion_units", "fanout_deliveries", "consumer_inbox",
        "user_sync_sequences", "user_sync_log", "device_sync_cursors", "sync_snapshots",
        "sync_snapshot_pages", "sync_tokens", "sync_receipts", "push_campaigns",
        "push_device_budgets", "push_wake_outbox", "push_device_endpoints",
        "user_shard_router_configuration", "user_shard_route_overrides",
        "user_shard_route_operations", "user_shard_migrations",
    ]

    public static func verify(database: any Database, schema: String = "im_v2") async throws {
        guard let sql = database as? any SQLDatabase else { throw V2SchemaReadinessError.unsupportedDatabase }
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw V2SchemaReadinessError.unavailableTable(schema)
        }
        for table in requiredTables {
            let name = "\(schema).\(table)"
            guard let row = try await sql.raw("SELECT to_regclass(\(bind: name)) IS NOT NULL AS exists").first(decoding: ExistsRow.self), row.exists else {
                throw V2SchemaReadinessError.unavailableTable(name)
            }
        }
    }
}

private struct ExistsRow: Decodable { let exists: Bool }
