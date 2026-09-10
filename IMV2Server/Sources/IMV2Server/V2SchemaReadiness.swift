import Fluent
import SQLKit

public enum V2SchemaReadinessError: Error, Equatable, Sendable { case unavailableTable(String), unsupportedDatabase }

/// 全新 V2 schema 的启动闸门。
///
/// 它把 schema 供应变为部署前置条件，避免在 TLS 监听已经开始接受已认证流量之后
/// 才发现缺表。
public enum V2SchemaReadiness {
    public static let currentSchemaID = "im-v2-current-30"
    private static let requiredTables = [
        "schema_contract", "auth_devices", "device_access_tokens", "device_refresh_sessions", "device_refresh_token_history", "device_credential_operations", "device_revocation_events", "gateway_worker_cursors", "device_session_operations", "device_revocation_capabilities", "device_registration_cancellations", "legacy_device_registration_cancellations", "device_registration_rate_limits", "account_password_credentials", "account_password_login_rate_limits", "account_password_authentication_audit", "account_edge_client_rate_limits", "account_disables", "public_user_profiles", "public_identity_lookup_rate_limits",
        "rooms", "room_owner_routes", "direct_room_owner_routes", "group_room_creation_intents", "group_room_creation_intent_members", "group_room_creation_intent_pages", "direct_room_pairs", "direct_room_operations", "direct_message_denials", "room_timeline_activities", "special_accounts", "support_conversation_sessions", "special_account_message_operations", "special_account_message_audit", "public_profile_update_outbox", "public_profile_update_operations", "user_contact_aliases", "user_contact_alias_operations", "room_member_nicknames", "room_member_nickname_operations", "group_rooms", "group_room_operations", "group_room_creation_drafts", "group_room_creation_draft_members", "group_invite_links", "group_invite_directory", "group_invite_creation_recovery", "group_invite_directory_import_audit", "group_join_requests", "group_join_approval_recovery_audit", "room_membership_operation_fences", "user_relationships", "user_relationship_operations", "user_blocks", "user_block_operations", "user_stranger_message_preferences", "stranger_message_preference_operations", "user_add_preferences", "user_add_preference_operations", "stranger_message_windows", "user_direct_send_policy_versions", "room_memberships", "room_member_mutes", "room_membership_operations", "message_withdrawal_operations", "message_edit_operations", "message_reactions", "message_reaction_operations", "room_read_receipts", "read_receipt_operations", "user_read_receipt_preferences", "read_receipt_preference_operations", "read_receipt_preference_propagation_outbox", "user_live_activity_preferences", "user_live_activity_preference_operations", "user_live_presence_leases", "room_admission",
        "shard_admission_pools", "messages", "message_send_completions", "message_content_versions", "message_projection_states", "message_projection_state_values", "room_events", "room_outbox", "group_event_wake_outbox", "durable_work_replay_audit", "forward_work_replay_audit",
        "user_room_preferences", "user_room_preference_operations", "user_message_favorites", "user_message_favorite_operations", "room_pinned_messages", "room_pinned_message_operations", "group_announcements", "group_announcement_operations", "group_role_permissions", "group_role_policies", "group_permission_operations", "group_role_operations", "message_forward_operations", "message_forward_exports", "message_forward_inbox", "message_forward_inbox_media", "message_forward_media_imports", "message_forward_export_receipts", "message_forward_delivery_jobs",
        "fanout_plans", "fanout_plan_targets", "fanout_completion_units", "fanout_deliveries", "consumer_inbox",
        "user_sync_sequences", "user_sync_log", "fanout_sync_payloads", "user_projection_effects", "device_sync_cursors", "revoked_device_projection_tombstones",
        "user_projection_versions", "user_projection_checkpoints", "user_projection_ready", "user_sync_retention", "sync_snapshot_artifacts",
        "sync_snapshot_pages", "device_snapshot_resets", "sync_tokens", "sync_receipts", "push_campaigns",
        "push_device_budgets", "push_wake_outbox", "push_device_endpoints", "push_device_intents",
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
                ) AND EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = \(bind: schema) AND table_name = 'auth_devices'
                      AND column_name = 'session_expires_at' AND udt_name = 'timestamptz' AND is_nullable = 'NO'
                ) AND EXISTS (
                    SELECT 1 FROM pg_constraint
                    WHERE conrelid = to_regclass(\(bind: schema + ".auth_devices"))
                      AND conname = 'auth_devices_session_expiry_finite' AND convalidated
                      AND pg_get_constraintdef(oid) = 'CHECK (isfinite(session_expires_at))'
                ) AS exists
            """).first(decoding: ExistsRow.self), contract.exists else {
            throw V2SchemaReadinessError.unavailableTable(
                "\(schema).schema_contract[\(currentSchemaID)]"
            )
        }
        guard let legacyCancellationContract = try await sql.raw("""
            SELECT ((SELECT count(*) = 4 AND bool_and(is_nullable = 'NO') FROM information_schema.columns
                WHERE table_schema = \(bind: schema) AND table_name = 'legacy_device_registration_cancellations'
                AND (column_name, udt_name) IN (('user_id','uuid'),('device_id','uuid'),('operation_id','uuid'),('cancelled_at','timestamptz')))
                AND (SELECT count(*) = 3 FROM pg_constraint WHERE conrelid = to_regclass(\(bind: schema + ".legacy_device_registration_cancellations"))
                    AND convalidated AND NOT condeferrable AND (conname, pg_get_constraintdef(oid)) IN (
                        ('legacy_registration_cancellation_pkey','PRIMARY KEY (user_id, device_id)'),
                        ('legacy_registration_cancellation_operation','UNIQUE (user_id, operation_id)'),
                        ('legacy_registration_cancellation_time','CHECK (isfinite(cancelled_at))')))
                AND (SELECT count(*) = 2 FROM pg_index WHERE indrelid = to_regclass(\(bind: schema + ".legacy_device_registration_cancellations"))
                    AND indisvalid AND indisready AND indisunique)) AS exists
            """).first(decoding: ExistsRow.self), legacyCancellationContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).legacy_device_registration_cancellations[account-scoped]")
        }
        guard let cancellationContract = try await sql.raw("""
            SELECT ((SELECT count(*) = 9 AND bool_and(is_nullable = CASE WHEN column_name IN ('user_id','session_created_at','session_expires_at','cancelled_at') THEN 'YES' ELSE 'NO' END)
             FROM information_schema.columns WHERE table_schema = \(bind: schema) AND table_name = 'device_registration_cancellations'
             AND (column_name, udt_name) IN (('request_digest','text'),('device_id','uuid'),('operation_id','uuid'),('issue_before','timestamptz'),('created_at','timestamptz'),('cancelled_at','timestamptz'),('user_id','uuid'),('session_created_at','timestamptz'),('session_expires_at','timestamptz')))
             AND (SELECT count(*) = 5 FROM pg_constraint WHERE conrelid=to_regclass(\(bind: schema + ".device_registration_cancellations"))
             AND convalidated AND NOT condeferrable AND (conname,pg_get_constraintdef(oid)) IN (
            ('device_registration_cancellations_pkey','PRIMARY KEY (request_digest)'),
            ('registration_cancellation_binding','CHECK ((((user_id IS NULL) AND (session_created_at IS NULL) AND (session_expires_at IS NULL) AND (cancelled_at IS NOT NULL)) OR ((user_id IS NOT NULL) AND (session_created_at IS NOT NULL) AND (session_expires_at IS NOT NULL) AND isfinite(session_created_at) AND isfinite(session_expires_at) AND (session_expires_at > session_created_at))))'),
            ('registration_cancellation_device','FOREIGN KEY (user_id, device_id) REFERENCES \(unsafeRaw: schema).auth_devices(user_id, device_id) ON DELETE RESTRICT'),
            ('registration_cancellation_digest','CHECK ((request_digest ~ ''^[0-9a-f]{64}$''::text))'),
            ('registration_cancellation_times','CHECK ((isfinite(created_at) AND isfinite(issue_before) AND (issue_before > created_at) AND (issue_before <= (created_at + ''1 day''::interval)) AND ((cancelled_at IS NULL) OR isfinite(cancelled_at))))')))
             AND EXISTS (SELECT 1 FROM pg_index WHERE indrelid=to_regclass(\(bind: schema + ".device_registration_cancellations"))
             AND indisvalid AND indisready AND indisunique AND indnkeyatts=1
             AND pg_get_indexdef(indexrelid,1,false)='device_id' AND pg_get_expr(indpred,indrelid)='(user_id IS NOT NULL)')) AS exists
            """).first(decoding: ExistsRow.self), cancellationContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).device_registration_cancellations[proof-bound]")
        }
        guard let credentialReplayContract = try await sql.raw("""
            SELECT ((
                SELECT count(*) = 2 AND bool_and(is_nullable = 'NO') FROM information_schema.columns
                WHERE table_schema = \(bind: schema) AND table_name = 'device_credential_operations'
                  AND (column_name, udt_name) IN (('encrypted_revocation_credential','text'), ('revocation_credential_expires_at','timestamptz'))
            ) AND EXISTS (
                SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass(\(bind: schema + ".device_credential_operations"))
                  AND conname = 'device_credential_operations_revocation_result_check' AND convalidated
                  AND pg_get_constraintdef(oid) = 'CHECK (((encrypted_revocation_credential <> ''''::text) AND isfinite(revocation_credential_expires_at)))'
            )
            ) AS exists
            """).first(decoding: ExistsRow.self), credentialReplayContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).device_credential_operations[revocation-result]")
        }
        guard let capabilityContract = try await sql.raw("""
            SELECT ((
            SELECT count(*) = 6 AND bool_and(is_nullable = 'NO')
            FROM information_schema.columns WHERE table_schema = \(bind: schema) AND table_name = 'device_revocation_capabilities'
            AND (column_name, udt_name) IN (('device_id','uuid'), ('user_id','uuid'), ('credential_digest','text'),
            ('session_created_at','timestamptz'), ('session_expires_at','timestamptz'), ('expires_at','timestamptz')))
            AND (SELECT count(*) = 5 FROM pg_constraint WHERE conrelid = to_regclass(\(bind: schema + ".device_revocation_capabilities"))
            AND convalidated AND NOT condeferrable AND (conname, pg_get_constraintdef(oid)) IN (
            ('device_revocation_capabilities_pkey','PRIMARY KEY (device_id)'),
            ('device_revocation_capabilities_credential_digest_key','UNIQUE (credential_digest)'),
            ('device_revocation_capability_device','FOREIGN KEY (user_id, device_id) REFERENCES \(unsafeRaw: schema).auth_devices(user_id, device_id) ON DELETE CASCADE'),
            ('device_revocation_capability_digest','CHECK ((credential_digest ~ ''^[0-9a-f]{64}$''::text))'),
            ('device_revocation_capability_expiry','CHECK ((isfinite(session_created_at) AND isfinite(session_expires_at) AND isfinite(expires_at) AND (session_expires_at > session_created_at) AND (expires_at = (session_expires_at + ''00:10:00''::interval))))')))
            ) AS exists
            """).first(decoding: ExistsRow.self), capabilityContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).device_revocation_capabilities[session-bound]")
        }
        guard let importContract = try await sql.raw("""
            SELECT ((
             SELECT count(*) = 18 AND bool_and(is_nullable = CASE WHEN column_name IN ('after_invite_id','next_cursor') THEN 'YES' ELSE 'NO' END)
             FROM information_schema.columns WHERE table_schema = \(bind: schema) AND table_name = 'group_invite_directory_import_audit'
             AND (column_name, udt_name) IN (('operation_id','uuid'), ('operator_principal','text'), ('shard_id','text'), ('owner_epoch','int8'), ('room_id','uuid'), ('after_invite_id','uuid'), ('page_size','int8'), ('reason_code','text'), ('requested_at','timestamptz'), ('outcome','text'), ('source_snapshot','jsonb'), ('source_digest','bytea'), ('source_count','int8'), ('inserted_count','int8'), ('published_count','int8'), ('unchanged_count','int8'), ('next_cursor','uuid'), ('conflicting_invite_ids','_uuid'))
            ) AND EXISTS (
             SELECT 1 FROM pg_constraint c JOIN pg_index i ON i.indexrelid = c.conindid
             WHERE c.conrelid = to_regclass(\(bind: "\(schema).group_invite_directory_import_audit")) AND c.contype = 'p'
             AND c.convalidated AND NOT c.condeferrable AND i.indisvalid AND i.indisready AND i.indisunique
             AND pg_get_constraintdef(c.oid) = 'PRIMARY KEY (operation_id)'
            ) AND NOT EXISTS (
             SELECT 1 FROM pg_constraint c WHERE c.conrelid = to_regclass(\(bind: "\(schema).group_invite_directory_import_audit")) AND c.contype = 'f'
            ) AND (
             SELECT count(*) = 10 FROM pg_constraint c WHERE c.conrelid = to_regclass(\(bind: "\(schema).group_invite_directory_import_audit"))
             AND c.contype = 'c' AND c.convalidated AND (c.conname, pg_get_constraintdef(c.oid)) IN (
             ('group_invite_import_counts_check','CHECK (((inserted_count >= 0) AND (published_count >= 0) AND (unchanged_count >= 0) AND (((outcome = ''applied''::text) AND (((inserted_count + published_count) + unchanged_count) = source_count) AND (cardinality(conflicting_invite_ids) = 0)) OR ((outcome = ''conflict''::text) AND (inserted_count = 0) AND (published_count = 0) AND (unchanged_count = 0) AND ((cardinality(conflicting_invite_ids) >= 1) AND (cardinality(conflicting_invite_ids) <= source_count))))))'),
             ('group_invite_import_cursor_check','CHECK (((next_cursor IS NULL) OR ((source_count = page_size) AND (next_cursor = (((source_snapshot -> ''-1''::integer) ->> ''invite_id''::text))::uuid))))'),
             ('group_invite_import_digest_check','CHECK ((source_digest = sha256(convert_to((source_snapshot)::text, ''UTF8''::name))))'),
             ('group_invite_import_epoch_check','CHECK ((owner_epoch >= 0))'),
             ('group_invite_import_outcome_check','CHECK ((outcome = ANY (ARRAY[''applied''::text, ''conflict''::text])))'),
             ('group_invite_import_page_check','CHECK (((page_size >= 1) AND (page_size <= 100)))'),
             ('group_invite_import_principal_check','CHECK ((operator_principal ~ ''^[A-Za-z0-9_.:-]{1,128}$''::text))'),
             ('group_invite_import_reason_check','CHECK ((reason_code = ANY (ARRAY[''dependency_recovered''::text, ''data_repaired''::text, ''false_positive''::text])))'),
             ('group_invite_import_shard_check','CHECK ((((octet_length(shard_id) >= 1) AND (octet_length(shard_id) <= 128)) AND (shard_id = btrim(shard_id))))'),
             ('group_invite_import_snapshot_check','CHECK (((jsonb_typeof(source_snapshot) = ''array''::text) AND (jsonb_array_length(source_snapshot) = source_count) AND ((source_count >= 0) AND (source_count <= page_size))))'))
            ) AND EXISTS (
             SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
             JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_language l ON l.oid = p.prolang
             WHERE t.tgrelid = to_regclass(\(bind: "\(schema).group_invite_directory_import_audit")) AND t.tgname = 'group_invite_import_audit_immutable'
             AND t.tgtype = 27 AND t.tgenabled = 'O' AND NOT t.tgisinternal
             AND n.nspname = \(bind: schema) AND p.proname = 'reject_group_invite_import_audit_mutation'
             AND l.lanname = 'plpgsql' AND NOT p.prosecdef AND p.prorettype = 'trigger'::regtype
             AND encode(sha256(convert_to(p.prosrc, 'UTF8')), 'hex') = '6d5f50ca927c7f256ffa8b1ababb3a2dc8940dd172e67df5f6a97ebc6bc36282'
            ) AND EXISTS (
             SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_am a ON a.oid = c.relam
             WHERE i.indrelid = to_regclass(\(bind: "\(schema).group_invite_links")) AND c.relname = 'group_invite_links_import_page_idx'
             AND i.indisvalid AND i.indisready AND i.indnkeyatts = 2 AND i.indnatts = 2 AND a.amname = 'btree' AND i.indpred IS NULL
             AND pg_get_indexdef(i.indexrelid, 1, false) = 'room_id' AND pg_get_indexdef(i.indexrelid, 2, false) = 'invite_id'
            )) AS exists
            """).first(decoding: ExistsRow.self), importContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).group_invite_directory_import_audit[atomic-import]")
        }
        guard let inviteRecoveryContract = try await sql.raw("""
            SELECT ((
             SELECT count(*) = 10 AND bool_and(is_nullable = CASE WHEN column_name IN ('claim_token','lease_expires_at','last_error_code','completed_at') THEN 'YES' ELSE 'NO' END)
             FROM information_schema.columns WHERE table_schema = \(bind: schema) AND table_name = 'group_invite_creation_recovery'
             AND (column_name, udt_name) IN (('actor_user_id','uuid'), ('operation_id','uuid'), ('state','text'), ('attempt_count','int8'), ('next_attempt_at','timestamptz'), ('claim_token','uuid'), ('lease_expires_at','timestamptz'), ('last_error_code','text'), ('updated_at','timestamptz'), ('completed_at','timestamptz'))
            ) AND EXISTS (
             SELECT 1 FROM pg_constraint c JOIN pg_index i ON i.indexrelid = c.conindid
             WHERE c.conrelid = to_regclass(\(bind: "\(schema).group_invite_creation_recovery")) AND c.contype = 'p'
             AND c.convalidated AND NOT c.condeferrable AND i.indisvalid AND i.indisready AND i.indisunique
             AND pg_get_constraintdef(c.oid) = 'PRIMARY KEY (actor_user_id, operation_id)'
            ) AND EXISTS (
             SELECT 1 FROM pg_constraint c WHERE c.conrelid = to_regclass(\(bind: "\(schema).group_invite_creation_recovery"))
             AND c.contype = 'f' AND c.convalidated AND NOT c.condeferrable
             AND c.confrelid = to_regclass(\(bind: "\(schema).group_invite_directory")) AND c.confdeltype = 'r'
             AND cardinality(c.conkey) = 2 AND cardinality(c.confkey) = 2
             AND c.conkey[1] = (SELECT attnum FROM pg_attribute WHERE attrelid = c.conrelid AND attname = 'actor_user_id')
             AND c.conkey[2] = (SELECT attnum FROM pg_attribute WHERE attrelid = c.conrelid AND attname = 'operation_id')
             AND c.confkey[1] = (SELECT attnum FROM pg_attribute WHERE attrelid = c.confrelid AND attname = 'actor_user_id')
             AND c.confkey[2] = (SELECT attnum FROM pg_attribute WHERE attrelid = c.confrelid AND attname = 'operation_id')
            ) AND (
             SELECT count(*) = 7 FROM pg_constraint c WHERE c.conrelid = to_regclass(\(bind: "\(schema).group_invite_creation_recovery"))
             AND c.contype = 'c' AND c.convalidated AND (c.conname, pg_get_constraintdef(c.oid)) IN (
             ('group_invite_creation_recovery_state_check','CHECK ((state = ANY (ARRAY[''pending''::text, ''claimed''::text, ''completed''::text, ''paused''::text])))'),
             ('group_invite_creation_recovery_attempt_check','CHECK (((attempt_count >= 0) AND (attempt_count <= 1000)))'),
             ('group_invite_creation_recovery_claim_check','CHECK (((state = ''claimed''::text) = (claim_token IS NOT NULL)))'),
             ('group_invite_creation_recovery_lease_check','CHECK (((state = ''claimed''::text) = (lease_expires_at IS NOT NULL)))'),
             ('group_invite_creation_recovery_completed_check','CHECK (((state = ''completed''::text) = (completed_at IS NOT NULL)))'),
             ('group_invite_creation_recovery_paused_check','CHECK (((state <> ''paused''::text) OR (last_error_code IS NOT NULL)))'),
             ('group_invite_creation_recovery_error_check','CHECK ((last_error_code = ANY (ARRAY[''dependency_unavailable''::text, ''owner_changed''::text, ''rate_limited''::text, ''permission_denied''::text, ''creation_expired''::text, ''conflicting_evidence''::text])))'))
            ) AND (
             SELECT count(*) = 2 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_am a ON a.oid = c.relam
             WHERE i.indrelid = to_regclass(\(bind: "\(schema).group_invite_creation_recovery")) AND i.indisvalid AND i.indisready AND i.indnkeyatts = 3 AND a.amname = 'btree'
             AND pg_get_indexdef(i.indexrelid, 2, false) = 'actor_user_id' AND pg_get_indexdef(i.indexrelid, 3, false) = 'operation_id'
             AND ((c.relname = 'group_invite_creation_recovery_pending_idx' AND pg_get_indexdef(i.indexrelid, 1, false) = 'next_attempt_at' AND pg_get_expr(i.indpred, i.indrelid) = '(state = ''pending''::text)')
             OR (c.relname = 'group_invite_creation_recovery_lease_idx' AND pg_get_indexdef(i.indexrelid, 1, false) = 'lease_expires_at' AND pg_get_expr(i.indpred, i.indrelid) = '(state = ''claimed''::text)'))
            )) AS exists
            """).first(decoding: ExistsRow.self), inviteRecoveryContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).group_invite_creation_recovery[claim-state]")
        }
        guard let ownerIdentityContract = try await sql.raw("""
            SELECT NOT EXISTS (
             SELECT 1 FROM pg_constraint c
             WHERE c.conrelid IN (to_regclass(\(bind: "\(schema).group_invite_links")), to_regclass(\(bind: "\(schema).group_join_requests")))
             AND c.contype = 'f' AND c.confrelid IN (to_regclass(\(bind: "\(schema).public_user_profiles")), to_regclass(\(bind: "\(schema).account_disables")))
            ) AS exists
            """).first(decoding: ExistsRow.self), ownerIdentityContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).group_invite_links[control-identity]")
        }
        guard let directoryContract = try await sql.raw("""
            SELECT ((
             SELECT count(*) = 11 AND bool_and(is_nullable = CASE WHEN column_name = 'ready_at' THEN 'YES' ELSE 'NO' END)
             FROM information_schema.columns WHERE table_schema = \(bind: schema) AND table_name = 'group_invite_directory'
             AND (column_name, udt_name) IN (('actor_user_id','uuid'), ('operation_id','uuid'), ('invite_id','uuid'), ('room_id','uuid'), ('token_digest','bytea'), ('requested_lifetime_seconds','int8'), ('maximum_approved_uses','int8'), ('created_at','timestamptz'), ('expires_at','timestamptz'), ('state','text'), ('ready_at','timestamptz'))
            ) AND (
             SELECT count(*) = 3 FROM pg_constraint c JOIN pg_index i ON i.indexrelid = c.conindid
             WHERE c.conrelid = to_regclass(\(bind: "\(schema).group_invite_directory")) AND c.contype IN ('p','u')
             AND c.convalidated AND NOT c.condeferrable AND i.indisvalid AND i.indisready AND i.indisunique
             AND pg_get_constraintdef(c.oid) IN ('PRIMARY KEY (actor_user_id, operation_id)', 'UNIQUE (token_digest)', 'UNIQUE (invite_id)')
            ) AND (
             SELECT count(*) = 6 FROM pg_constraint c WHERE c.conrelid = to_regclass(\(bind: "\(schema).group_invite_directory"))
             AND c.contype = 'c' AND c.convalidated AND (c.conname, pg_get_constraintdef(c.oid)) IN (
             ('group_invite_directory_digest_check', 'CHECK ((octet_length(token_digest) = 32))'),
             ('group_invite_directory_lifetime_check', 'CHECK ((requested_lifetime_seconds > 0))'),
             ('group_invite_directory_uses_check', 'CHECK ((maximum_approved_uses > 0))'),
             ('group_invite_directory_expiry_check', 'CHECK ((expires_at > created_at))'),
             ('group_invite_directory_state_check', 'CHECK ((state = ANY (ARRAY[''prepared''::text, ''ready''::text])))'),
             ('group_invite_directory_ready_check', 'CHECK (((state = ''ready''::text) = (ready_at IS NOT NULL)))'))
            ) AND NOT EXISTS (
             SELECT 1 FROM pg_constraint c WHERE c.conrelid = to_regclass(\(bind: "\(schema).group_invite_directory")) AND c.contype = 'f'
            ) AND EXISTS (
             SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
             JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_language l ON l.oid = p.prolang
             WHERE t.tgrelid = to_regclass(\(bind: "\(schema).group_invite_directory")) AND t.tgname = 'group_invite_directory_immutable'
             AND t.tgtype = 27 AND t.tgenabled = 'O' AND NOT t.tgisinternal
             AND n.nspname = \(bind: schema) AND p.proname = 'reject_group_invite_directory_mutation'
             AND l.lanname = 'plpgsql' AND NOT p.prosecdef AND p.prorettype = 'trigger'::regtype
             AND encode(sha256(convert_to(p.prosrc, 'UTF8')), 'hex') = '78d6c9ce33c4fd0d518390cfdf76215068648c55f1510e32aab9a941ba43ea15'
            )) AS exists
            """).first(decoding: ExistsRow.self), directoryContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).group_invite_directory[intent-binding]")
        }
        guard let approvalRecoveryContract = try await sql.raw("""
            SELECT ((
             SELECT count(*) = 22 AND count(*) FILTER (WHERE is_nullable = 'NO') = 13
             FROM information_schema.columns WHERE table_schema = \(bind: schema) AND table_name = 'group_join_approval_recovery_audit'
             AND (column_name, udt_name) IN (('operation_id', 'uuid'), ('operator_principal', 'text'), ('shard_id', 'text'), ('owner_epoch', 'int8'), ('room_id', 'uuid'), ('request_id', 'uuid'), ('reviewer_user_id', 'uuid'), ('decision_operation_id', 'uuid'), ('reason_code', 'text'), ('outcome', 'text'), ('detail', 'text'), ('requested_at', 'timestamptz'), ('applicant_user_id', 'uuid'), ('prepared_revision', 'int8'), ('member_room_id', 'uuid'), ('member_target_user_id', 'uuid'), ('member_action', 'text'), ('expected_revision', 'int8'), ('resulting_revision', 'int8'), ('room_sequence', 'int8'), ('event_id', 'uuid'), ('plan_id', 'uuid'))
            ) AND (
             SELECT count(*) = 6 AND bool_and(is_nullable = 'NO')
             FROM information_schema.columns WHERE table_schema = \(bind: schema) AND table_name = 'room_membership_operation_fences'
             AND (column_name, udt_name) IN (('actor_user_id', 'uuid'), ('operation_id', 'uuid'), ('room_id', 'uuid'), ('request_id', 'uuid'), ('recovery_operation_id', 'uuid'), ('created_at', 'timestamptz'))
            ) AND (
             SELECT count(*) = 6 FROM pg_constraint c
             WHERE c.conrelid = to_regclass(\(bind: "\(schema).group_join_approval_recovery_audit")) AND c.contype = 'c' AND c.convalidated
             AND (c.conname, pg_get_constraintdef(c.oid)) IN (('group_join_approval_recovery_audit_owner_epoch_check', 'CHECK ((owner_epoch >= 0))'), ('group_join_approval_recovery_audit_reason_code_check', 'CHECK ((reason_code = ANY (ARRAY[''dependency_recovered''::text, ''data_repaired''::text, ''false_positive''::text])))'), ('group_join_approval_recovery_audit_outcome_check', 'CHECK ((outcome = ANY (ARRAY[''completed''::text, ''released''::text, ''quarantined''::text, ''not_approving''::text])))'), ('group_join_approval_recovery_audit_detail_check', 'CHECK ((detail = ANY (ARRAY[''committed_operation''::text, ''no_historical_add''::text, ''operation_mismatch''::text, ''historical_add_without_receipt''::text, ''invalid_revision''::text, ''invite_exhausted''::text, ''not_approving''::text])))'), ('group_join_approval_recovery_audit_completed_check', 'CHECK (((outcome <> ''completed''::text) OR (expected_revision IS NOT NULL)))'), ('group_join_approval_recovery_audit_result_check', 'CHECK ((((member_room_id IS NULL) AND (member_target_user_id IS NULL) AND (member_action IS NULL) AND (expected_revision IS NULL) AND (resulting_revision IS NULL) AND (room_sequence IS NULL) AND (event_id IS NULL) AND (plan_id IS NULL)) OR ((member_room_id IS NOT NULL) AND (member_target_user_id IS NOT NULL) AND (member_action IS NOT NULL) AND (expected_revision IS NOT NULL) AND (resulting_revision IS NOT NULL) AND (room_sequence IS NOT NULL) AND (event_id IS NOT NULL) AND (plan_id IS NOT NULL))))'))
            ) AND (
             SELECT count(*) = 2 FROM pg_constraint c JOIN pg_index i ON i.indexrelid = c.conindid
             WHERE c.contype = 'p' AND c.convalidated AND NOT c.condeferrable AND i.indisvalid AND i.indisready AND i.indisunique
             AND ((c.conrelid = to_regclass(\(bind: "\(schema).group_join_approval_recovery_audit")) AND pg_get_constraintdef(c.oid) = 'PRIMARY KEY (operation_id)')
             OR (c.conrelid = to_regclass(\(bind: "\(schema).room_membership_operation_fences")) AND pg_get_constraintdef(c.oid) = 'PRIMARY KEY (actor_user_id, operation_id)'))
            ) AND EXISTS (
             SELECT 1 FROM pg_constraint c WHERE c.conrelid = to_regclass(\(bind: "\(schema).room_membership_operation_fences"))
             AND c.contype = 'f' AND c.convalidated AND c.confrelid = to_regclass(\(bind: "\(schema).group_join_approval_recovery_audit"))
             AND c.confdeltype = 'r' AND cardinality(c.conkey) = 1 AND cardinality(c.confkey) = 1
             AND c.conkey[1] = (SELECT attnum FROM pg_attribute WHERE attrelid = c.conrelid AND attname = 'recovery_operation_id')
             AND c.confkey[1] = (SELECT attnum FROM pg_attribute WHERE attrelid = c.confrelid AND attname = 'operation_id')
            ) AND (
             SELECT count(*) = 2 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
             JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_language l ON l.oid = p.prolang
             WHERE t.tgtype = 27 AND t.tgenabled = 'O' AND NOT t.tgisinternal
             AND n.nspname = \(bind: schema) AND p.proname = 'reject_approval_recovery_mutation'
             AND l.lanname = 'plpgsql' AND NOT p.prosecdef AND p.prorettype = 'trigger'::regtype
             AND regexp_replace(p.prosrc, '[[:space:]]', '', 'g') = 'BEGINRAISEEXCEPTION''approvalrecoveryevidenceisimmutable'';END;'
             AND ((t.tgrelid = to_regclass(\(bind: "\(schema).group_join_approval_recovery_audit")) AND t.tgname = 'group_join_approval_recovery_audit_immutable')
             OR (t.tgrelid = to_regclass(\(bind: "\(schema).room_membership_operation_fences")) AND t.tgname = 'room_membership_operation_fences_immutable'))
            ) AND EXISTS (
             SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_am a ON a.oid = c.relam
             WHERE i.indrelid = to_regclass(\(bind: "\(schema).group_join_requests"))
             AND i.indexrelid = to_regclass(\(bind: "\(schema).group_join_requests_approving_recovery_idx"))
             AND i.indisvalid AND i.indisready AND i.indnkeyatts = 2 AND a.amname = 'btree'
             AND i.indkey[0] = (SELECT attnum FROM pg_attribute WHERE attrelid = i.indrelid AND attname = 'room_id')
             AND i.indkey[1] = (SELECT attnum FROM pg_attribute WHERE attrelid = i.indrelid AND attname = 'request_id')
             AND pg_get_expr(i.indpred, i.indrelid) = '(state = ''approving''::text)'
            )) AS exists
            """).first(decoding: ExistsRow.self), approvalRecoveryContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).group_join_approval_recovery_audit[recovery-fence]")
        }
        guard let decisionContract = try await sql.raw("""
            SELECT EXISTS (
                SELECT 1 FROM pg_constraint c
                JOIN pg_index i ON i.indexrelid = c.conindid
                WHERE c.conrelid = to_regclass(\(bind: "\(schema).group_join_requests"))
                  AND c.contype = 'u' AND c.convalidated AND NOT c.condeferrable
                  AND i.indisvalid AND i.indisready AND i.indisunique
                  AND pg_get_constraintdef(c.oid) = 'UNIQUE (decided_by_user_id, decision_operation_id)'
            ) AS exists
            """).first(decoding: ExistsRow.self), decisionContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).group_join_requests[decision-operation]")
        }
        guard let pushIntentContract = try await sql.raw("""
            SELECT ((
             SELECT count(*) = 6 AND count(*) FILTER (WHERE is_nullable = 'NO') = 5
             AND count(*) FILTER (WHERE column_name = 'intent_digest' AND is_nullable = 'YES') = 1
             FROM information_schema.columns WHERE table_schema = \(bind: schema) AND table_name = 'push_device_intents'
             AND (column_name, udt_name) IN (('device_id','uuid'), ('session_epoch','int8'), ('session_claim_id','uuid'), ('intent_revision','int8'), ('intent_digest','bytea'), ('updated_at','timestamptz'))
            ) AND EXISTS (
             SELECT 1 FROM pg_constraint c WHERE c.conrelid = to_regclass(\(bind: "\(schema).push_device_intents"))
             AND c.contype = 'p' AND pg_get_constraintdef(c.oid) = 'PRIMARY KEY (device_id)'
            ) AND (
             SELECT count(*) = 3 FROM pg_constraint c WHERE c.conrelid = to_regclass(\(bind: "\(schema).push_device_intents"))
             AND c.contype = 'c' AND c.convalidated AND (c.conname, pg_get_constraintdef(c.oid)) IN (
             ('push_device_intents_session_epoch_check', 'CHECK ((session_epoch > 0))'),
             ('push_device_intents_intent_revision_check', 'CHECK ((intent_revision >= 0))'),
             ('push_device_intents_digest_check', 'CHECK ((((intent_revision = 0) AND (intent_digest IS NULL)) OR ((intent_revision > 0) AND (intent_digest IS NOT NULL) AND (octet_length(intent_digest) = 32))))'))
            ) AND EXISTS (
             SELECT 1 FROM pg_constraint c WHERE c.conrelid = to_regclass(\(bind: "\(schema).push_device_intents"))
             AND c.contype = 'f' AND c.convalidated AND c.confrelid = to_regclass(\(bind: "\(schema).auth_devices"))
             AND c.confdeltype = 'r' AND cardinality(c.conkey) = 1 AND cardinality(c.confkey) = 1
             AND c.conkey[1] = (SELECT attnum FROM pg_attribute WHERE attrelid = c.conrelid AND attname = 'device_id')
             AND c.confkey[1] = (SELECT attnum FROM pg_attribute WHERE attrelid = c.confrelid AND attname = 'device_id')
            )) AS exists
            """).first(decoding: ExistsRow.self), pushIntentContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).push_device_intents[versioned-intent]")
        }
        guard let policyContract = try await sql.raw("""
            SELECT ((
             SELECT count(*) = 2 AND count(*) FILTER (WHERE is_nullable = 'NO') = 2
             FROM information_schema.columns WHERE table_schema = \(bind: schema) AND table_name = 'group_role_policies'
             AND (column_name, udt_name) IN (('room_id','uuid'), ('role','text'))
            ) AND EXISTS (
             SELECT 1 FROM pg_constraint c WHERE c.conrelid = to_regclass(\(bind: "\(schema).group_role_policies"))
             AND c.contype = 'p' AND pg_get_constraintdef(c.oid) = 'PRIMARY KEY (room_id, role)'
            ) AND EXISTS (
             SELECT 1 FROM pg_constraint c WHERE c.conrelid = to_regclass(\(bind: "\(schema).group_role_policies"))
             AND c.conname = 'group_role_policies_role_check' AND c.convalidated AND c.contype = 'c'
             AND pg_get_constraintdef(c.oid) = 'CHECK ((role = ANY (ARRAY[''admin''::text, ''member''::text])))'
            ) AND EXISTS (
             SELECT 1 FROM pg_constraint c WHERE c.conrelid = to_regclass(\(bind: "\(schema).group_role_policies"))
             AND c.contype = 'f' AND c.convalidated AND c.confrelid = to_regclass(\(bind: "\(schema).rooms"))
             AND c.confdeltype = 'r' AND cardinality(c.conkey) = 1
             AND c.conkey[1] = (SELECT attnum FROM pg_attribute WHERE attrelid = c.conrelid AND attname = 'room_id')
            )) AS exists
            """).first(decoding: ExistsRow.self), policyContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).group_role_policies[current-policy]")
        }
        guard let scopedMediaContract = try await sql.raw("""
            SELECT ((
             SELECT count(*) = 4 AND count(*) FILTER (WHERE is_nullable = 'YES') = 4
             FROM information_schema.columns WHERE table_schema = \(bind: schema) AND table_name = 'media_download_grants'
             AND (column_name, udt_name) IN (('message_room_id','uuid'), ('message_id','uuid'), ('owner_shard_id','text'), ('owner_epoch','int8'))
            ) AND EXISTS (
             SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
             WHERE n.nspname = \(bind: schema) AND r.relname = 'media_download_grants'
             AND c.conname = 'media_download_grants_scope_check' AND c.convalidated AND c.contype = 'c'
             AND pg_get_constraintdef(c.oid) = 'CHECK ((((message_room_id IS NULL) AND (message_id IS NULL) AND (owner_shard_id IS NULL) AND (owner_epoch IS NULL)) OR ((message_room_id IS NOT NULL) AND (message_id IS NOT NULL) AND (owner_shard_id IS NOT NULL) AND (length(btrim(owner_shard_id)) > 0) AND (owner_epoch IS NOT NULL) AND (owner_epoch >= 0))))'
            ) AND EXISTS (
             SELECT 1 FROM pg_trigger t JOIN pg_class r ON r.oid = t.tgrelid JOIN pg_namespace n ON n.oid = r.relnamespace JOIN pg_proc p ON p.oid = t.tgfoid
             WHERE n.nspname = \(bind: schema) AND r.relname = 'media_download_grants'
             AND t.tgname = 'media_download_grants_identity' AND t.tgtype = 19 AND t.tgenabled = 'O' AND NOT t.tgisinternal
             AND encode(sha256(convert_to(p.prosrc, 'UTF8')), 'hex') = '7e371b5f666d2e9d466345a5efd112e9d214149a739e287246232638c29e5cb6'
            ) AND NOT EXISTS (
             SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
             WHERE n.nspname = \(bind: schema) AND r.relname = 'media_download_grants' AND c.contype = 'f'
             AND c.confrelid = to_regclass(\(bind: "\(schema).auth_devices"))
            )) AS exists
            """).first(decoding: ExistsRow.self), scopedMediaContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).media_download_grants[message-scope]")
        }
        guard let replayContract = try await sql.raw("""
            SELECT ((
            SELECT count(*) = 9 AND count(*) FILTER (WHERE is_nullable = 'NO') = 8
            FROM information_schema.columns WHERE table_schema = \(bind: schema) AND table_name = 'forward_work_replay_audit'
            AND (column_name, udt_name) IN (('operation_id','uuid'), ('operator_principal','text'), ('shard_id','text'),
            ('target_kind','text'), ('export_id','uuid'), ('ordinal','int4'), ('reason_code','text'), ('requested_at','timestamptz'), ('outcome','text'))
            ) AND EXISTS (
            SELECT 1 FROM pg_trigger t JOIN pg_class r ON r.oid = t.tgrelid JOIN pg_namespace n ON n.oid = r.relnamespace
            WHERE n.nspname = \(bind: schema) AND r.relname = 'forward_work_replay_audit'
            AND t.tgname = 'forward_work_replay_audit_immutable' AND t.tgtype = 27 AND t.tgenabled = 'O' AND NOT t.tgisinternal
            AND t.tgfoid = to_regprocedure(\(bind: "\(schema).reject_forward_replay_audit_mutation()"))
            ) AND EXISTS (
            SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
            WHERE n.nspname = \(bind: schema) AND r.relname = 'forward_work_replay_audit'
            AND c.conname = 'forward_work_replay_audit_target_check' AND c.convalidated AND c.contype = 'c'
            AND pg_get_constraintdef(c.oid) = 'CHECK ((((target_kind = ''delivery''::text) AND (ordinal IS NULL)) OR ((target_kind = ''media''::text) AND (ordinal IS NOT NULL) AND ((ordinal >= 0) AND (ordinal <= 9)))))'
            ) AND EXISTS (
            SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
            WHERE n.nspname = \(bind: schema) AND r.relname = 'forward_work_replay_audit'
            AND c.contype = 'p' AND pg_get_constraintdef(c.oid) = 'PRIMARY KEY (operation_id)'
            )) AS exists
            """).first(decoding: ExistsRow.self), replayContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).forward_work_replay_audit[replay-contract]")
        }
        guard let deliveryContract = try await sql.raw("""
            SELECT (
            (
             SELECT count(*) = 8 AND count(*) FILTER (WHERE is_nullable = 'NO') = 4
             FROM information_schema.columns WHERE table_schema = \(bind: schema) AND table_name = 'message_forward_delivery_jobs'
             AND (column_name, udt_name) IN (('export_id','uuid'), ('state','text'), ('claim_token','uuid'), ('lease_expires_at','timestamptz'),
             ('next_attempt_at','timestamptz'), ('retry_count','int8'), ('created_at','timestamptz'), ('completed_at','timestamptz'))
            ) AND EXISTS (
             SELECT 1 FROM pg_trigger t JOIN pg_class r ON r.oid = t.tgrelid JOIN pg_namespace n ON n.oid = r.relnamespace
             WHERE n.nspname = \(bind: schema) AND r.relname = 'message_forward_delivery_jobs'
             AND t.tgname = 'message_forward_delivery_jobs_immutable' AND t.tgtype = 27 AND t.tgenabled = 'O' AND NOT t.tgisinternal
            ) AND EXISTS (
             SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
             WHERE n.nspname = \(bind: schema) AND r.relname = 'message_forward_delivery_jobs'
             AND c.conname = 'message_forward_delivery_jobs_shape_check' AND c.convalidated AND c.contype = 'c'
            ) AND (
             SELECT count(*) = 2 FROM pg_indexes WHERE schemaname = \(bind: schema) AND tablename = 'message_forward_delivery_jobs'
             AND ((indexname = 'message_forward_delivery_jobs_ready_idx' AND indexdef LIKE '%USING btree (next_attempt_at, created_at, export_id) WHERE (state = ''pending''::text)')
             OR (indexname = 'message_forward_delivery_jobs_lease_idx' AND indexdef LIKE '%USING btree (lease_expires_at, export_id) WHERE (state = ''claimed''::text)'))
            ) AND EXISTS (
             SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
             WHERE n.nspname = \(bind: schema) AND r.relname = 'message_forward_delivery_jobs'
             AND c.conname = 'message_forward_delivery_jobs_export_id_fkey' AND c.convalidated AND c.contype = 'f'
             AND pg_get_constraintdef(c.oid) = 'FOREIGN KEY (export_id) REFERENCES im_v2.message_forward_exports(export_id) ON DELETE RESTRICT'
            )
            ) AS exists
            """).first(decoding: ExistsRow.self), deliveryContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).message_forward_delivery_jobs[delivery-contract]")
        }
        guard let receiptContract = try await sql.raw("""
            SELECT (
            (
                SELECT count(*) = 7 AND count(*) FILTER (WHERE is_nullable = 'NO') = 4
                FROM information_schema.columns WHERE table_schema = \(bind: schema) AND table_name = 'message_forward_export_receipts'
                  AND (column_name, udt_name) IN (
                    ('export_id','uuid'), ('payload_digest','bytea'), ('state','text'), ('result_message_id','uuid'),
                    ('result_room_sequence','int8'), ('error_code','text'), ('recorded_at','timestamptz')
                  )
            ) AND EXISTS (
                SELECT 1 FROM pg_trigger t JOIN pg_class r ON r.oid = t.tgrelid JOIN pg_namespace n ON n.oid = r.relnamespace
                WHERE n.nspname = \(bind: schema) AND r.relname = 'message_forward_export_receipts'
                  AND t.tgname = 'message_forward_export_receipts_immutable' AND t.tgtype = 27 AND t.tgenabled = 'O' AND NOT t.tgisinternal
            ) AND EXISTS (
                SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
                WHERE n.nspname = \(bind: schema) AND r.relname = 'message_forward_export_receipts'
                  AND c.conname = 'message_forward_export_receipts_shape_check' AND c.convalidated AND c.contype = 'c'
            ) AND EXISTS (
                SELECT 1 FROM pg_indexes WHERE schemaname = \(bind: schema) AND tablename = 'message_forward_export_receipts'
                  AND indexname = 'message_forward_export_receipts_pkey'
                  AND indexdef LIKE 'CREATE UNIQUE INDEX %USING btree (export_id)'
            ) AND EXISTS (
                SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
                WHERE n.nspname = \(bind: schema) AND r.relname = 'message_forward_export_receipts'
                  AND c.conname = 'message_forward_export_receipts_export_id_fkey' AND c.convalidated AND c.contype = 'f'
                  AND pg_get_constraintdef(c.oid) = 'FOREIGN KEY (export_id) REFERENCES im_v2.message_forward_exports(export_id) ON DELETE RESTRICT'
            )
            ) AS exists
            """).first(decoding: ExistsRow.self), receiptContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).message_forward_export_receipts[terminal-contract]")
        }
        guard let mediaImportContract = try await sql.raw("""
            SELECT (
            (
                SELECT count(*) = 13 AND count(*) FILTER (WHERE is_nullable = 'NO') = 7
                FROM information_schema.columns WHERE table_schema = \(bind: schema) AND table_name = 'message_forward_media_imports'
                  AND (column_name, udt_name) IN (
                    ('export_id','uuid'), ('ordinal','int4'), ('target_media_id','uuid'), ('target_upload_session_id','uuid'),
                    ('state','text'), ('copied_digest','bytea'), ('copied_at','timestamptz'), ('claim_token','uuid'),
                    ('lease_expires_at','timestamptz'), ('next_attempt_at','timestamptz'), ('retry_count','int8'),
                    ('created_at','timestamptz'), ('completed_at','timestamptz')
                  )
            ) AND EXISTS (
                SELECT 1 FROM pg_trigger t JOIN pg_class r ON r.oid = t.tgrelid JOIN pg_namespace n ON n.oid = r.relnamespace
                WHERE n.nspname = \(bind: schema) AND r.relname = 'message_forward_media_imports'
                  AND t.tgname = 'message_forward_media_imports_immutable' AND t.tgtype = 27 AND t.tgenabled = 'O' AND NOT t.tgisinternal
            ) AND EXISTS (
                SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
                WHERE n.nspname = \(bind: schema) AND r.relname = 'message_forward_media_imports'
                  AND c.conname = 'message_forward_media_imports_shape_check' AND c.convalidated AND c.contype = 'c'
            ) AND EXISTS (
                SELECT 1 FROM pg_indexes WHERE schemaname = \(bind: schema)
                  AND indexname = 'message_forward_media_imports_target_media_id_key'
                  AND indexdef LIKE 'CREATE UNIQUE INDEX %USING btree (target_media_id)'
            )
            ) AS exists
            """).first(decoding: ExistsRow.self), mediaImportContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).message_forward_media_imports[verified-object]")
        }
        guard let inboxContract = try await sql.raw("""
            SELECT NOT EXISTS (
                SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid
                JOIN pg_namespace n ON n.oid = r.relnamespace
                JOIN pg_attribute a ON a.attrelid = r.oid AND a.attnum = ANY(c.conkey)
                WHERE n.nspname = \(bind: schema) AND r.relname = 'messages'
                  AND c.contype = 'f' AND a.attname = 'forwarded_from_message_id'
            ) AND (
            (
                SELECT count(*) = 15 AND count(*) FILTER (WHERE is_nullable = 'NO') = 10
                FROM information_schema.columns WHERE table_schema = \(bind: schema) AND table_name = 'message_forward_inbox'
                  AND (column_name, udt_name) IN (
                    ('export_id','uuid'), ('actor_user_id','uuid'), ('operation_id','uuid'), ('source_message_id','uuid'),
                    ('target_room_id','uuid'), ('target_client_message_id','uuid'), ('payload','bytea'), ('payload_digest','bytea'),
                    ('state','text'), ('result_message_id','uuid'), ('result_room_sequence','int8'), ('error_code','text'),
                    ('created_at','timestamptz'), ('accepted_at','timestamptz'), ('completed_at','timestamptz')
                  )
            ) AND (
                SELECT count(*) = 6 FROM information_schema.columns
                WHERE table_schema = \(bind: schema) AND table_name = 'message_forward_inbox_media'
                  AND (column_name, udt_name) IN (('export_id','uuid'), ('ordinal','int4'), ('source_media_id','uuid'), ('target_media_id','uuid'), ('object_digest','bytea'), ('state','text'))
            ) AND (
                SELECT count(*) = 2 FROM pg_trigger t JOIN pg_class r ON r.oid = t.tgrelid JOIN pg_namespace n ON n.oid = r.relnamespace
                WHERE n.nspname = \(bind: schema) AND t.tgenabled = 'O' AND t.tgtype = 27 AND NOT t.tgisinternal
                  AND (r.relname, t.tgname) IN (('message_forward_inbox','message_forward_inbox_immutable'), ('message_forward_inbox_media','message_forward_inbox_media_immutable'))
            ) AND (
                SELECT count(*) = 2 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
                WHERE n.nspname = \(bind: schema) AND c.convalidated AND c.contype = 'c'
                  AND (r.relname, c.conname) IN (('message_forward_inbox','message_forward_inbox_outcome_check'), ('message_forward_inbox_media','message_forward_inbox_media_ready_check'))
            ) AND (
                SELECT count(*) = 3 FROM pg_indexes WHERE schemaname = \(bind: schema) AND (
                    (indexname = 'message_forward_inbox_pair_key' AND indexdef LIKE 'CREATE UNIQUE INDEX %USING btree (actor_user_id, operation_id, source_message_id, target_room_id)')
                    OR (indexname = 'message_forward_inbox_client_key' AND indexdef LIKE 'CREATE UNIQUE INDEX %USING btree (actor_user_id, target_client_message_id)')
                    OR (indexname = 'message_forward_inbox_media_target_media_id_key' AND indexdef LIKE 'CREATE UNIQUE INDEX %USING btree (target_media_id)')
                )
            )
            ) AS exists
            """).first(decoding: ExistsRow.self), inboxContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).message_forward_inbox[durable-import]")
        }
        guard let exportContract = try await sql.raw("""
            SELECT (EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = \(bind: schema) AND table_name = 'rooms'
                      AND column_name = 'owner_epoch' AND data_type = 'bigint' AND is_nullable = 'NO'
                ) AND (
                    SELECT count(*) = 16 FROM information_schema.columns
                    WHERE table_schema = \(bind: schema) AND table_name = 'message_forward_exports' AND is_nullable = 'NO'
                      AND (column_name, udt_name) IN (
                        ('export_id', 'uuid'), ('actor_user_id', 'uuid'), ('operation_id', 'uuid'),
                        ('source_room_id', 'uuid'), ('source_message_id', 'uuid'), ('source_content_revision', 'int8'),
                        ('source_shard_id', 'text'), ('source_epoch', 'int8'), ('target_room_id', 'uuid'),
                        ('target_client_message_id', 'uuid'), ('target_shard_id', 'text'), ('target_epoch', 'int8'),
                        ('payload', 'bytea'), ('payload_digest', 'bytea'), ('media_ids', '_uuid'), ('created_at', 'timestamptz')
                      )
                ) AND EXISTS (
                    SELECT 1 FROM pg_trigger t
                    JOIN pg_class r ON r.oid = t.tgrelid JOIN pg_namespace n ON n.oid = r.relnamespace
                    WHERE n.nspname = \(bind: schema) AND r.relname = 'message_forward_exports'
                      AND t.tgname = 'message_forward_exports_immutable' AND t.tgenabled = 'O'
                      AND t.tgtype = 27 AND NOT t.tgisinternal
                ) AND EXISTS (
                    SELECT 1 FROM pg_indexes
                    WHERE schemaname = \(bind: schema) AND tablename = 'message_forward_exports'
                      AND indexname = 'message_forward_exports_media_idx'
                      AND indexdef LIKE '%USING gin (media_ids)'
                ) AND EXISTS (
                    SELECT 1 FROM pg_indexes
                    WHERE schemaname = \(bind: schema) AND tablename = 'message_forward_exports'
                      AND indexname = 'message_forward_exports_pair_key'
                      AND indexdef LIKE 'CREATE UNIQUE INDEX %USING btree (actor_user_id, operation_id, source_message_id, target_room_id)'
                )) AS exists
            """).first(decoding: ExistsRow.self), exportContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).message_forward_exports[immutable-export]")
        }
        guard let forwardRevisionContract = try await sql.raw("""
            SELECT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_schema = \(bind: schema)
                  AND table_name = 'message_forward_operations'
                  AND column_name = 'source_content_revision' AND data_type = 'bigint'
            ) AND EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_schema = \(bind: schema) AND table_name = 'message_forward_operations'
                  AND column_name = 'source_room_id' AND data_type = 'uuid'
            ) AND EXISTS (
                SELECT 1 FROM pg_trigger t
                JOIN pg_class r ON r.oid = t.tgrelid
                JOIN pg_namespace n ON n.oid = r.relnamespace
                WHERE n.nspname = \(bind: schema) AND r.relname = 'message_forward_operations'
                  AND t.tgname = 'message_forward_operations_identity_immutable'
                  AND t.tgenabled <> 'D' AND NOT t.tgisinternal
            ) AND (
                SELECT count(*) = 2
                FROM pg_constraint AS constraint_record
                JOIN pg_class AS relation ON relation.oid = constraint_record.conrelid
                JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
                WHERE namespace.nspname = \(bind: schema)
                  AND (relation.relname, constraint_record.conname) IN (
                      ('message_send_completions', 'message_send_completions_fingerprint_version_check'),
                      ('direct_message_denials', 'direct_message_denials_fingerprint_version_check')
                  )
                  AND constraint_record.convalidated
                  AND pg_get_expr(constraint_record.conbin, constraint_record.conrelid)
                      = '(fingerprint_version = ANY (ARRAY[1, 2]))'
            ) AS exists
            """).first(decoding: ExistsRow.self), forwardRevisionContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).message_forward_operations[source-revision]")
        }
        guard let contentAudienceIndex = try await sql.raw("""
            SELECT EXISTS (
                SELECT 1 FROM pg_index i
                JOIN pg_class r ON r.oid = i.indexrelid
                JOIN pg_namespace n ON n.oid = r.relnamespace
                WHERE n.nspname = \(bind: schema) AND r.relname = 'room_events_message_edit_revision_idx'
                  AND i.indrelid = to_regclass(\(bind: "\(schema).room_events"))
                  AND i.indisunique AND i.indisvalid AND i.indisready AND i.indnkeyatts = 3
                  AND pg_get_indexdef(i.indexrelid, 1, false) = 'room_id'
                  AND pg_get_indexdef(i.indexrelid, 2, false) = \(bind: "lower((payload ->> 'message_id'::text))")
                  AND pg_get_indexdef(i.indexrelid, 3, false) = \(bind: "((payload ->> 'message_revision'::text))")
                  AND pg_get_expr(i.indpred, i.indrelid) = \(bind: "(event_type = 'message.edited'::text)")
            ) AS exists
            """).first(decoding: ExistsRow.self), contentAudienceIndex.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).room_events[message-version-audience]")
        }
        guard let refreshHistoryContract = try await sql.raw("""
            SELECT
                COUNT(*) FILTER (
                    WHERE column_name IN (
                        'user_id', 'device_id', 'family_generation',
                        'refresh_hmac', 'consumed_at', 'expires_at'
                    )
                ) = 6
                AND to_regclass(
                    \(bind: "\(schema).device_refresh_token_history_device_hmac_idx")
                ) IS NOT NULL
                AND to_regclass(
                    \(bind: "\(schema).device_refresh_token_history_expiry_idx")
                ) IS NOT NULL AS exists
            FROM information_schema.columns
            WHERE table_schema = \(bind: schema)
              AND table_name = 'device_refresh_token_history'
            """).first(decoding: ExistsRow.self), refreshHistoryContract.exists else {
            throw V2SchemaReadinessError.unavailableTable(
                "\(schema).device_refresh_token_history[family-reuse]"
            )
        }
        guard let groupInvitationContract = try await sql.raw("""
            SELECT
                EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = \(bind: schema)
                      AND table_name = 'group_invite_links'
                      AND column_name = 'token_digest'
                      AND is_nullable = 'NO'
                )
                AND EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = \(bind: schema)
                      AND table_name = 'group_join_requests'
                      AND column_name = 'approval_membership_revision'
                      AND is_nullable = 'YES'
                )
                AND EXISTS (
                    SELECT 1
                    FROM pg_constraint AS constraint_record
                    JOIN pg_class AS relation ON relation.oid = constraint_record.conrelid
                    JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
                    WHERE namespace.nspname = \(bind: schema)
                      AND relation.relname = 'group_join_requests'
                      AND constraint_record.conname = 'group_join_requests_invite_room_fkey'
                      AND constraint_record.contype = 'f'
                      AND constraint_record.convalidated
                )
                AND to_regclass(\(bind: "\(schema).group_invite_links_room_active_idx")) IS NOT NULL
                AND to_regclass(\(bind: "\(schema).group_join_requests_room_pending_idx")) IS NOT NULL
                AND to_regclass(\(bind: "\(schema).group_join_requests_applicant_pending_idx")) IS NOT NULL
                AND to_regclass(\(bind: "\(schema).group_join_requests_invite_approving_idx")) IS NOT NULL
                AS exists
            """).first(decoding: ExistsRow.self), groupInvitationContract.exists else {
            throw V2SchemaReadinessError.unavailableTable(
                "\(schema).group_invite_links[approval-contract]"
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
        // Compact hybrid-group accepts are materialized by the same message
        // row contract, but they additionally require a transactional wake so
        // connected members learn the new room high-watermark. A missing or
        // disabled statement trigger would make durable messages discoverable
        // only by polling, so fail startup before enabling that writer.
        guard let hybridGroupMessageWakeContract = try await sql.raw("""
            SELECT EXISTS (
                SELECT 1
                FROM pg_trigger AS trigger_record
                JOIN pg_class AS relation
                  ON relation.oid = trigger_record.tgrelid
                JOIN pg_namespace AS namespace
                  ON namespace.oid = relation.relnamespace
                WHERE namespace.nspname = \(bind: schema)
                  AND relation.relname = 'messages'
                  AND trigger_record.tgname =
                      'messages_enqueue_hybrid_group_wake'
                  AND trigger_record.tgenabled <> 'D'
                  AND NOT trigger_record.tgisinternal
                  AND trigger_record.tgtype & 1 = 0
            ) AS exists
            """).first(decoding: ExistsRow.self), hybridGroupMessageWakeContract.exists else {
            throw V2SchemaReadinessError.unavailableTable(
                "\(schema).messages[hybrid-group-wake]"
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
