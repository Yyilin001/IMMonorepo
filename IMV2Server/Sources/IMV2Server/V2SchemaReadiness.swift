import Fluent
import SQLKit

public enum V2SchemaReadinessError: Error, Equatable, Sendable { case unavailableTable(String), unsupportedDatabase }

/// Startup gate for the clean V2 schema. It makes schema provisioning a
/// deployment prerequisite instead of discovering a missing table after a TLS
/// listener is already accepting authenticated traffic.
public enum V2SchemaReadiness {
    public static let currentSchemaID = "im-v2-current-3"
    private static let requiredTables = [
        "schema_contract", "auth_devices", "device_access_tokens", "device_refresh_sessions", "device_credential_operations", "device_revocation_events", "gateway_worker_cursors", "device_session_operations", "device_registration_rate_limits", "account_password_credentials", "account_password_login_rate_limits", "account_password_authentication_audit", "account_edge_client_rate_limits", "account_disables", "public_user_profiles", "public_identity_lookup_rate_limits",
        "rooms", "room_owner_routes", "direct_room_owner_routes", "direct_room_pairs", "direct_room_operations", "direct_message_denials", "room_timeline_activities", "special_accounts", "support_conversation_sessions", "special_account_message_operations", "special_account_message_audit", "public_profile_update_outbox", "public_profile_update_operations", "user_contact_aliases", "user_contact_alias_operations", "room_member_nicknames", "room_member_nickname_operations", "group_rooms", "group_room_operations", "group_room_creation_drafts", "group_room_creation_draft_members", "user_relationships", "user_relationship_operations", "user_blocks", "user_block_operations", "user_stranger_message_preferences", "stranger_message_preference_operations", "user_add_preferences", "user_add_preference_operations", "stranger_message_windows", "user_direct_send_policy_versions", "room_memberships", "room_member_mutes", "room_membership_operations", "message_withdrawal_operations", "message_edit_operations", "message_reactions", "message_reaction_operations", "room_read_receipts", "read_receipt_operations", "user_read_receipt_preferences", "read_receipt_preference_operations", "read_receipt_preference_propagation_outbox", "user_live_activity_preferences", "user_live_activity_preference_operations", "user_live_presence_leases", "room_admission",
        "shard_admission_pools", "messages", "message_content_versions", "message_projection_states", "message_projection_state_values", "room_events", "room_outbox", "group_event_wake_outbox", "durable_work_replay_audit",
        "user_room_preferences", "user_room_preference_operations", "user_message_favorites", "user_message_favorite_operations", "room_pinned_messages", "room_pinned_message_operations", "group_announcements", "group_announcement_operations", "group_role_permissions", "group_permission_operations", "group_role_operations", "message_forward_operations",
        "fanout_plans", "fanout_plan_targets", "fanout_completion_units", "fanout_deliveries", "consumer_inbox",
        "user_sync_sequences", "user_sync_log", "fanout_sync_payloads", "user_projection_effects", "device_sync_cursors", "revoked_device_projection_tombstones",
        "user_projection_versions", "user_projection_checkpoints", "user_projection_ready", "user_sync_retention", "sync_snapshot_artifacts",
        "sync_snapshot_pages", "device_snapshot_resets", "sync_tokens", "sync_receipts", "push_campaigns",
        "push_device_budgets", "push_wake_outbox", "push_device_endpoints",
        "media_objects", "media_upload_operations", "media_upload_grants", "media_scan_outbox", "media_download_grants", "media_purge_outbox", "message_media_references", "message_mentions", "moderation_operations", "moderation_audit_entries", "content_review_jobs", "content_review_decisions", "content_review_findings", "content_review_cases",
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
        guard let contract = try await sql.raw("""
            SELECT
                COALESCE((
                    SELECT column_default = '''\(unsafeRaw: currentSchemaID)''::text'
                    FROM information_schema.columns
                    WHERE table_schema = \(bind: schema)
                      AND table_name = 'schema_contract'
                      AND column_name = 'schema_id'
                      AND is_nullable = 'NO'
                ), FALSE)
                AND EXISTS (
                    SELECT 1
                    FROM pg_constraint AS constraint_record
                    JOIN pg_class AS relation
                      ON relation.oid = constraint_record.conrelid
                    JOIN pg_namespace AS namespace
                      ON namespace.oid = relation.relnamespace
                    WHERE namespace.nspname = \(bind: schema)
                      AND relation.relname = 'schema_contract'
                      AND constraint_record.contype = 'c'
                      AND pg_get_constraintdef(constraint_record.oid)
                          LIKE \(bind: "%\(currentSchemaID)%")
                ) AS exists
            """).first(decoding: ExistsRow.self), contract.exists else {
            throw V2SchemaReadinessError.unavailableTable(
                "\(schema).schema_contract[\(currentSchemaID)]"
            )
        }
        guard let fanoutPayloadReferenceContract = try await sql.raw("""
            SELECT
                EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = \(bind: schema)
                      AND table_name = 'fanout_sync_payloads'
                      AND column_name = 'payload'
                      AND is_nullable = 'YES'
                )
                AND COUNT(*) FILTER (
                    WHERE constraint_record.conname IN (
                        'fanout_sync_payloads_payload_reference_check',
                        'fanout_sync_payloads_message_state_kind_check'
                    ) AND constraint_record.convalidated
                ) = 2 AS exists
            FROM pg_constraint AS constraint_record
            JOIN pg_class AS relation ON relation.oid = constraint_record.conrelid
            JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
            WHERE namespace.nspname = \(bind: schema)
              AND relation.relname = 'fanout_sync_payloads'
            """).first(decoding: ExistsRow.self), fanoutPayloadReferenceContract.exists else {
            throw V2SchemaReadinessError.unavailableTable(
                "\(schema).fanout_sync_payloads[payload-reference]"
            )
        }
        guard let messageStateStorageContract = try await sql.raw("""
            SELECT
                EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = \(bind: schema)
                      AND table_name = 'message_projection_states'
                      AND column_name = 'payload_storage'
                      AND is_nullable = 'NO'
                )
                AND EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = \(bind: schema)
                      AND table_name = 'message_projection_states'
                      AND column_name = 'payload'
                      AND is_nullable = 'YES'
                )
                AND EXISTS (
                    SELECT 1
                    FROM pg_constraint AS constraint_record
                    JOIN pg_class AS relation
                      ON relation.oid = constraint_record.conrelid
                    JOIN pg_namespace AS namespace
                      ON namespace.oid = relation.relnamespace
                    WHERE namespace.nspname = \(bind: schema)
                      AND relation.relname = 'message_projection_states'
                      AND constraint_record.conname =
                          'message_projection_states_payload_storage_check'
                      AND constraint_record.convalidated
                )
                AND EXISTS (
                    SELECT 1
                    FROM pg_trigger AS trigger_record
                    JOIN pg_class AS relation
                      ON relation.oid = trigger_record.tgrelid
                    JOIN pg_namespace AS namespace
                      ON namespace.oid = relation.relnamespace
                    WHERE namespace.nspname = \(bind: schema)
                      AND relation.relname = 'room_events'
                      AND trigger_record.tgname = 'room_events_immutable'
                      AND trigger_record.tgenabled <> 'D'
                      AND NOT trigger_record.tgisinternal
                ) AS exists
            """).first(decoding: ExistsRow.self), messageStateStorageContract.exists else {
            throw V2SchemaReadinessError.unavailableTable(
                "\(schema).message_projection_states[room-event-storage]"
            )
        }
        // Plain direct-room appends may use `messages` as the durable event
        // source.  Keep this explicit even though the schema-contract bump is
        // last in the migration: it turns a partially applied/manual schema
        // change into a startup failure instead of a silently incomplete room
        // log.
        guard let directMessageEventSourceContract = try await sql.raw("""
            SELECT
                COUNT(*) FILTER (
                    WHERE column_name IN (
                        'accepted_event_id',
                        'accepted_event_storage',
                        'accepted_membership_revision'
                    )
                ) = 3
                AND EXISTS (
                    SELECT 1
                    FROM pg_constraint AS constraint_record
                    JOIN pg_class AS relation
                      ON relation.oid = constraint_record.conrelid
                    JOIN pg_namespace AS namespace
                      ON namespace.oid = relation.relnamespace
                    WHERE namespace.nspname = \(bind: schema)
                      AND relation.relname = 'messages'
                      AND constraint_record.conname =
                          'messages_accepted_event_storage_check'
                      AND constraint_record.convalidated
                )
                -- The reader is intentionally compatible with both sides of
                -- the online cursor-index consolidation.  Before the
                -- migration it uses the legacy partial cursor index; after
                -- the migration the validated sequence invariant lets it use
                -- the existing unique room/timeline index instead.  Requiring
                -- either complete contract keeps the deploy-before-DDL order
                -- safe without admitting a partially applied new contract.
                AND (
                    EXISTS (
                        SELECT 1
                        FROM pg_index AS index_record
                        JOIN pg_class AS index_relation
                          ON index_relation.oid = index_record.indexrelid
                        JOIN pg_namespace AS namespace
                          ON namespace.oid = index_relation.relnamespace
                        WHERE namespace.nspname = \(bind: schema)
                          AND index_relation.relname =
                              'messages_direct_event_cursor_idx'
                          AND index_record.indisvalid
                          AND index_record.indisready
                    )
                    OR (
                        EXISTS (
                            SELECT 1
                            FROM pg_constraint AS constraint_record
                            JOIN pg_class AS relation
                              ON relation.oid = constraint_record.conrelid
                            JOIN pg_namespace AS namespace
                              ON namespace.oid = relation.relnamespace
                            WHERE namespace.nspname = \(bind: schema)
                              AND relation.relname = 'messages'
                              AND constraint_record.conname =
                                  'messages_message_row_sequences_match'
                              AND constraint_record.convalidated
                        )
                        AND EXISTS (
                            SELECT 1
                            FROM pg_index AS index_record
                            JOIN pg_class AS index_relation
                              ON index_relation.oid = index_record.indexrelid
                            JOIN pg_namespace AS namespace
                              ON namespace.oid = index_relation.relnamespace
                            WHERE namespace.nspname = \(bind: schema)
                              AND index_relation.relname =
                                  'messages_room_timeline_sequence_key'
                              AND index_record.indisvalid
                              AND index_record.indisready
                        )
                    )
                ) AS exists
            FROM information_schema.columns
            WHERE table_schema = \(bind: schema)
              AND table_name = 'messages'
            """).first(decoding: ExistsRow.self), directMessageEventSourceContract.exists else {
            throw V2SchemaReadinessError.unavailableTable(
                "\(schema).messages[direct-event-source]"
            )
        }
        guard let freshDeliveryContract = try await sql.raw("""
            SELECT EXISTS (
                SELECT 1
                FROM information_schema.columns
                WHERE table_schema = \(bind: schema)
                  AND table_name = 'fanout_deliveries'
                  AND column_name = 'fresh_direct_eligible'
                  AND is_nullable = 'NO'
            ) AND EXISTS (
                SELECT 1
                FROM pg_constraint AS constraint_record
                JOIN pg_class AS relation
                  ON relation.oid = constraint_record.conrelid
                JOIN pg_namespace AS namespace
                  ON namespace.oid = relation.relnamespace
                WHERE namespace.nspname = \(bind: schema)
                  AND relation.relname = 'fanout_deliveries'
                  AND constraint_record.conname =
                      'fanout_deliveries_fresh_direct_kind_check'
                  AND constraint_record.convalidated
            ) AND (
                SELECT COUNT(*) = 2
                FROM pg_index AS index_record
                JOIN pg_class AS index_relation
                  ON index_relation.oid = index_record.indexrelid
                JOIN pg_namespace AS namespace
                  ON namespace.oid = index_relation.relnamespace
                WHERE namespace.nspname = \(bind: schema)
                  AND index_relation.relname IN (
                      'fanout_deliveries_fresh_direct_user_microbatch_claim_idx',
                      'fanout_deliveries_fresh_generic_target_lane_claim_idx'
                  )
                  AND index_record.indisvalid
                  AND index_record.indisready
            ) AND EXISTS (
                SELECT 1
                FROM pg_constraint AS constraint_record
                JOIN pg_class AS relation
                  ON relation.oid = constraint_record.conrelid
                JOIN pg_namespace AS namespace
                  ON namespace.oid = relation.relnamespace
                WHERE namespace.nspname = \(bind: schema)
                  AND relation.relname = 'fanout_plans'
                  AND constraint_record.conname =
                      'fanout_plans_direct_preplanned_shape_check'
                  AND constraint_record.convalidated
            ) AND (
                SELECT COUNT(*) = 3
                FROM pg_trigger AS trigger_record
                JOIN pg_class AS relation
                  ON relation.oid = trigger_record.tgrelid
                JOIN pg_namespace AS namespace
                  ON namespace.oid = relation.relnamespace
                WHERE namespace.nspname = \(bind: schema)
                  AND (
                      (
                          relation.relname = 'fanout_deliveries'
                          AND trigger_record.tgname IN (
                              'fanout_deliveries_fresh_direct_batch_validate',
                              'fanout_deliveries_fresh_direct_immutable'
                          )
                      ) OR (
                          relation.relname = 'fanout_plans'
                          AND trigger_record.tgname =
                              'fanout_plans_identity_immutable'
                      )
                  )
                  AND trigger_record.tgenabled <> 'D'
                  AND NOT trigger_record.tgisinternal
            ) AS exists
            """).first(decoding: ExistsRow.self), freshDeliveryContract.exists else {
            throw V2SchemaReadinessError.unavailableTable(
                "\(schema).fanout_deliveries[fresh-delivery-contract]"
            )
        }
        guard let syncProjectionTriggerContract = try await sql.raw("""
            SELECT COUNT(*) = 2
                AND COUNT(*) FILTER (
                    WHERE trigger_record.tgname IN (
                        'user_sync_log_projection_effect_v4',
                        'user_sync_log_snapshot_v7_projection'
                    )
                ) = 2 AS exists
            FROM pg_trigger AS trigger_record
            JOIN pg_class AS relation
              ON relation.oid = trigger_record.tgrelid
            JOIN pg_namespace AS namespace
              ON namespace.oid = relation.relnamespace
            WHERE namespace.nspname = \(bind: schema)
              AND relation.relname = 'user_sync_log'
              AND trigger_record.tgenabled <> 'D'
              AND NOT trigger_record.tgisinternal
            """).first(decoding: ExistsRow.self), syncProjectionTriggerContract.exists else {
            throw V2SchemaReadinessError.unavailableTable(
                "\(schema).user_sync_log[statement-projection-triggers]"
            )
        }
    }
}

private struct ExistsRow: Decodable { let exists: Bool }
