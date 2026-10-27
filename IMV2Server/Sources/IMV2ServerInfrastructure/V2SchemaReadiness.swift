import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import SQLKit

public enum V2SchemaReadinessError: Error, Equatable, Sendable { case unavailableTable(String), unsupportedDatabase }

/// 全新 V2 schema 的启动闸门。
///
/// 它把 schema 供应变为部署前置条件，避免在 TLS 监听已经开始接受已认证流量之后
/// 才发现缺表。
public enum V2SchemaReadiness {
    public static let currentSchemaID = "im-v2-current-72"
    private static let requiredTables = [
        "schema_contract", "control_housekeeping_cursor", "realtime_device_control_versions", "auth_devices", "device_access_tokens", "device_refresh_sessions", "device_refresh_token_history", "device_credential_operations", "device_revocation_events", "gateway_worker_cursors", "device_session_operations", "remote_device_revocation_baselines", "remote_device_revocation_receipts", "device_revocation_capabilities", "device_registration_cancellations", "device_registration_rate_limits", "account_password_credentials", "account_password_login_rate_limits", "account_password_authentication_audit", "account_edge_client_rate_limits", "account_disables", "public_user_profiles", "public_identity_lookup_rate_limits",
        "rooms", "room_owner_routes", "direct_room_owner_routes", "group_room_creation_intents", "group_room_creation_intent_members", "group_room_creation_intent_pages", "direct_room_pairs", "room_timeline_activities", "special_accounts", "support_conversation_sessions", "special_account_message_operations", "special_account_message_audit", "public_profile_update_outbox", "public_profile_update_operations", "user_contact_aliases", "contact_alias_operation_receipts", "room_member_nicknames", "group_nickname_operation_receipts", "group_rooms", "group_invitation_admissions", "group_invitation_receipts", "group_invitation_control_commands", "group_invite_links", "group_invite_directory", "group_invite_creation_recovery", "group_join_requests", "group_join_quota_intents",
        "group_join_quota_aliases", "group_join_submission_receipts", "user_relationships", "user_blocks", "user_stranger_message_preferences", "user_add_preferences", "stranger_message_windows", "user_direct_send_policy_versions", "room_memberships", "room_member_mutes", "room_membership_operations", "message_reactions", "message_reaction_key_revisions", "message_reaction_receipts", "room_read_receipts", "read_receipt_operations", "user_read_receipt_preferences", "read_receipt_preference_propagation_outbox", "user_live_activity_preferences", "user_live_presence_leases", "room_admission",
        "shard_admission_pools", "messages", "message_send_completions", "message_mutation_receipts", "message_content_versions", "message_edit_visibility", "message_projection_states", "message_projection_state_values", "room_events", "realtime_partition_leases", "user_sync_wake_outbox", "durable_work_replay_audit", "forward_work_replay_audit",
        "personal_preference_operation_receipts", "user_room_preferences", "user_message_favorites", "room_pinned_messages", "group_announcements", "group_role_permissions", "group_role_policies", "message_moderation_admissions", "message_moderation_receipts", "member_administration_admissions", "member_administration_receipts", "membership_operation_admissions", "membership_operation_receipts", "group_capability_admissions", "group_capability_receipts", "account_preference_receipts", "account_preference_revisions", "group_creation_operations", "group_creation_pages", "group_creation_owner_receipts", "direct_room_operation_handoffs", "direct_room_owner_receipts", "social_operation_receipts", "social_relationship_revisions", "social_block_revisions", "forward_plan_operations", "forward_preparation_rejections", "message_forward_operations", "message_forward_exports", "message_forward_inbox", "message_forward_inbox_media", "message_forward_media_imports", "message_forward_export_receipts", "message_forward_delivery_jobs",
        "user_state_event_outbox", "user_state_event_receipts", "user_sync_sequences", "user_sync_log", "user_projection_effects", "device_sync_cursors", "revoked_device_projection_tombstones",
        "user_projection_versions", "user_projection_checkpoints", "user_projection_ready", "user_sync_retention", "sync_snapshot_artifacts",
        "sync_snapshot_pages", "device_snapshot_resets", "sync_tokens", "sync_receipts", "push_campaigns",
        "push_device_budgets", "push_wake_outbox", "mention_push_wake_intents", "mention_push_wake_receipts", "push_device_endpoints", "push_device_intents",
        "resource_group_avatar_closures", "resource_group_avatars", "resource_group_avatar_operations", "resource_catalog", "resource_forward_outputs", "resource_upload_sessions", "resource_blob_placements", "resource_variants", "resource_imports", "resource_import_holds", "resource_import_source_closures", "resource_storage_migrations",
        "media_objects", "media_scan_outbox", "media_download_grants", "media_purge_outbox", "message_media_references", "message_mentions", "moderation_operations", "moderation_audit_entries", "content_review_jobs", "content_review_decisions", "content_review_findings", "content_review_cases",
        "room_recovery_topology", "user_shard_router_configuration", "user_shard_route_overrides",
        "device_room_progress",
        "policy_authorization_scopes",
        "policy_authorization_changes",
        "policy_authorization_outbox", "policy_owner_deployment",
    ]

    public static func verify(database: any Database, schema: String = "im_v2") async throws {
        guard database is any SQLDatabase else { throw V2SchemaReadinessError.unsupportedDatabase }
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw V2SchemaReadinessError.unavailableTable(schema)
        }
        // 即使调用方只请求 withConnection，Fluent 固定的连接也会报告
        // inTransaction，因此 transaction() 会跳过 BEGIN，SET LOCAL 也不会生效。
        // 须显式恢复这个固定会话；普通连接池句柄则使用真正的事务。
        if database.inTransaction {
            guard let sql = database as? any SQLDatabase else {
                throw V2SchemaReadinessError.unsupportedDatabase
            }
            guard let original = try await sql.raw("SELECT current_setting('search_path') AS path")
                .first(decoding: SearchPathRow.self)?.path else {
                throw V2SchemaReadinessError.unsupportedDatabase
            }
            try await sql.raw("SELECT set_config('search_path', '', false)").run()
            do {
                try await verifySchema(sql: sql, schema: schema)
                try await sql.raw("SELECT set_config('search_path', \(bind: original), false)").run()
            } catch {
                try? await sql.raw("SELECT set_config('search_path', \(bind: original), false)").run()
                throw error
            }
            return
        }
        // schema 位于 search_path 时，pg_get_constraintdef 和 pg_get_indexdef
        // 会省略 schema 限定符。SET LOCAL 只在就绪检查期间改变目录呈现；
        // PostgreSQL 会在提交或回滚时恢复路径。
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2SchemaReadinessError.unsupportedDatabase
            }
            try await sql.raw("SET LOCAL search_path TO ''").run()
            try await verifySchema(sql: sql, schema: schema)
        }
    }

    private static func verifySchema(sql: any SQLDatabase, schema: String) async throws {
        for table in requiredTables {
            let name = "\(schema).\(table)"
            guard let row = try await sql.raw("SELECT to_regclass(\(bind: name)) IS NOT NULL AS exists").first(decoding: ExistsRow.self), row.exists else {
                throw V2SchemaReadinessError.unavailableTable(name)
            }
        }
        guard let notifications = try await sql.raw("""
            WITH scoped_indexes AS MATERIALIZED (
                SELECT i.oid, i.relname AS indexname
                FROM pg_class i JOIN pg_namespace n ON n.oid = i.relnamespace
                WHERE n.nspname = \(bind: schema) AND i.relkind = 'i'
            ), scoped_constraints AS MATERIALIZED (
                SELECT c.* FROM pg_constraint c
                JOIN pg_class r ON r.oid = c.conrelid
                JOIN pg_namespace n ON n.oid = r.relnamespace
                WHERE n.nspname = \(bind: schema)
            )
            SELECT (SELECT count(*) = 3 FROM scoped_indexes WHERE (
                (indexname = 'mention_push_wake_intents_claim_idx' AND pg_get_indexdef(oid) LIKE '%USING btree (created_at, source_event_id, target_user_id)')
                OR (indexname = 'mention_push_wake_receipts_cleanup_idx' AND pg_get_indexdef(oid) LIKE '%USING btree (recorded_at, source_event_id, target_user_id)')
                OR (indexname = 'account_password_login_rate_limits_cleanup_idx' AND pg_get_indexdef(oid) LIKE '%USING btree (updated_at, account_handle)')
            )) AND NOT EXISTS (
                SELECT 1 FROM (VALUES
                    ('mention_push_wake_intents','source_event_id','uuid','NO'),
                    ('mention_push_wake_intents','room_id','uuid','NO'),
                    ('mention_push_wake_intents','target_user_id','uuid','NO'),
                    ('mention_push_wake_intents','created_at','timestamptz','NO'),
                    ('mention_push_wake_intents','claim_token','uuid','YES'),
                    ('mention_push_wake_intents','lease_expires_at','timestamptz','YES'),
                    ('mention_push_wake_receipts','source_event_id','uuid','NO'),
                    ('mention_push_wake_receipts','target_user_id','uuid','NO'),
                    ('mention_push_wake_receipts','recorded_at','timestamptz','NO'),
                    ('push_wake_outbox','source_room_id','uuid','NO')
                ) expected(table_name,column_name,udt_name,is_nullable)
                WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns c
                    WHERE c.table_schema = \(bind: schema) AND c.table_name = expected.table_name
                      AND c.column_name = expected.column_name AND c.udt_name = expected.udt_name
                      AND c.is_nullable = expected.is_nullable)
            ) AND NOT EXISTS (
                SELECT 1 FROM (VALUES
                    ('mention_push_wake_intents','PRIMARY KEY (source_event_id, target_user_id)'),
                    ('mention_push_wake_intents','CHECK (isfinite(created_at))'),
                    ('mention_push_wake_intents','CHECK (((claim_token IS NULL) = (lease_expires_at IS NULL)))'),
                    ('mention_push_wake_receipts','PRIMARY KEY (source_event_id, target_user_id)'),
                    ('mention_push_wake_receipts','CHECK (isfinite(recorded_at))')
                ) expected(table_name,definition)
                WHERE NOT EXISTS (SELECT 1 FROM scoped_constraints c
                    WHERE c.conrelid = to_regclass(\(bind: schema + ".") || expected.table_name)
                      AND c.convalidated AND NOT c.condeferrable
                      AND pg_get_constraintdef(c.oid) = expected.definition)
            ) AND NOT EXISTS (
                SELECT 1 FROM scoped_constraints WHERE contype = 'f'
                  AND conrelid IN (to_regclass(\(bind: schema + ".mention_push_wake_intents")),
                                   to_regclass(\(bind: schema + ".mention_push_wake_receipts")))
            ) AND NOT EXISTS (
                SELECT 1 FROM scoped_constraints WHERE contype = 'f'
                  AND conrelid = to_regclass(\(bind: schema + ".push_wake_outbox"))
                  AND confrelid = to_regclass(\(bind: schema + ".room_events"))
            ) AS valid
            """).first(decoding: ProfileOperationContractRow.self), notifications.valid else {
            throw V2SchemaReadinessError.unavailableTable(schema + ".mention_push_wake.contract")
        }
        // Both revocation consumers use an ID watermark. The database must
        // serialize statements before allocating IDs and keep the lock through
        // commit; sequence caching or a row trigger would break that contract.
        guard let revocations = try await sql.raw("""
            SELECT EXISTS (
                SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
                JOIN pg_language l ON l.oid = p.prolang
                WHERE t.tgrelid = to_regclass(\(bind: schema + ".device_revocation_events"))
                  AND t.tgname = 'device_revocation_events_commit_order'
                  AND t.tgtype = 6 AND t.tgenabled = 'O' AND NOT t.tgisinternal
                  AND t.tgqual IS NULL AND t.tgnargs = 0
                  AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = \(bind: schema))
                  AND p.proname = 'serialize_device_revocation_events'
                  AND p.provolatile = 'v' AND NOT p.prosecdef AND l.lanname = 'plpgsql'
                  AND encode(sha256(convert_to(p.prosrc, 'UTF8')), 'hex') = 'e07c509b2a449890909eb9b8ba54622f477857fa3d49b949de7bc6b09726a107'
            ) AND EXISTS (
                SELECT 1 FROM pg_attribute a JOIN pg_depend d
                  ON d.refobjid = a.attrelid AND d.refobjsubid = a.attnum
                 AND d.classid = 'pg_class'::regclass AND d.refclassid = 'pg_class'::regclass AND d.deptype = 'i'
                JOIN pg_sequence s ON s.seqrelid = d.objid
                WHERE a.attrelid = to_regclass(\(bind: schema + ".device_revocation_events"))
                  AND a.attname = 'event_id' AND a.attidentity = 'a' AND a.attnotnull
                  AND s.seqincrement = 1 AND s.seqcache = 1 AND NOT s.seqcycle
            ) AS valid
            """).first(decoding: ProfileOperationContractRow.self), revocations.valid else {
            throw V2SchemaReadinessError.unavailableTable(schema + ".device_revocation_events.commit_order")
        }
        guard let editVisibility = try await sql.raw("""
            SELECT (SELECT count(*) = 5 FROM information_schema.columns
                WHERE table_schema = \(bind: schema) AND table_name = 'message_edit_visibility'
                  AND (column_name, udt_name, is_nullable) IN (
                    ('message_id','uuid','NO'), ('message_revision','int8','NO'), ('room_id','uuid','NO'),
                    ('room_sequence','int8','NO'), ('committed_membership_revision','int8','NO')))
            AND (SELECT count(*) = 5 FROM pg_constraint
                WHERE conrelid = to_regclass(\(bind: schema + ".message_edit_visibility"))
                  AND convalidated AND NOT condeferrable AND pg_get_constraintdef(oid) IN (
                    'PRIMARY KEY (message_id, message_revision)', 'UNIQUE (room_id, room_sequence)',
                    'CHECK ((message_revision > 1))', 'CHECK ((room_sequence > 0))',
                    'CHECK ((committed_membership_revision >= 0))'))
            AND EXISTS (SELECT 1 FROM pg_index WHERE indrelid = to_regclass(\(bind: schema + ".message_edit_visibility"))
                AND indisvalid AND indisready AND replace(pg_get_indexdef(indexrelid), \(bind: schema + "."), 'im_v2.') =
                  'CREATE INDEX message_edit_visibility_latest_idx ON im_v2.message_edit_visibility USING btree (message_id, room_sequence DESC) INCLUDE (message_revision, room_id, committed_membership_revision)')
            AND EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
                WHERE t.tgrelid = to_regclass(\(bind: schema + ".room_events"))
                  AND t.tgname = 'room_events_capture_message_edit_visibility' AND t.tgtype = 5
                  AND t.tgenabled = 'O' AND NOT t.tgisinternal AND t.tgnargs = 0
                  AND replace(pg_get_triggerdef(t.oid), \(bind: schema + "."), 'im_v2.') =
                    'CREATE TRIGGER room_events_capture_message_edit_visibility AFTER INSERT ON im_v2.room_events FOR EACH ROW WHEN ((new.event_type = ''message.edited''::text)) EXECUTE FUNCTION im_v2.capture_message_edit_visibility()'
                  AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = \(bind: schema))
                  AND p.proname = 'capture_message_edit_visibility' AND p.provolatile = 'v'
                  AND encode(sha256(convert_to(replace(p.prosrc, \(bind: schema + "."), 'im_v2.'), 'UTF8')), 'hex') =
                    'e937a94bd50aa8842ed4c2d555fceb0f5a6a5ce729f69d1b817d2ccbda90d4c2')
            AND EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
                WHERE t.tgrelid = to_regclass(\(bind: schema + ".message_edit_visibility"))
                  AND t.tgname = 'message_edit_visibility_immutable' AND t.tgtype = 27
                  AND t.tgenabled = 'O' AND NOT t.tgisinternal AND t.tgqual IS NULL AND t.tgnargs = 0
                  AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = \(bind: schema))
                  AND p.proname = 'reject_message_edit_visibility_mutation' AND p.provolatile = 'v'
                  AND encode(sha256(convert_to(p.prosrc, 'UTF8')), 'hex') =
                    '129858c982b37359241ca4bdabd9a403b7d4e6661989a2abfcebcec57bbf1c51') AS valid
            """).first(decoding: ProfileOperationContractRow.self), editVisibility.valid else {
            throw V2SchemaReadinessError.unavailableTable(schema + ".message_edit_visibility.retained_audience")
        }
        let retiredTables = ["room_activation_leases","direct_message_denials","direct_authorization_intents","direct_authorization_receipts","policy_authorization_holders","policy_authorization_revocations","policy_authorization_holder_generation","room_policy_authorization_leases","room_pinned_message_operations","group_announcement_operations","group_permission_operations","group_role_operations","user_relationship_operations","user_block_operations","user_stranger_message_preference_operations","user_add_preference_operations","user_read_receipt_preference_operations","user_live_activity_preference_operations","group_room_operations","group_room_creation_drafts","group_room_creation_draft_members","direct_room_operations"]
        if let retired = try await sql.raw("""
            SELECT retired.name
            FROM unnest(string_to_array(\(bind: retiredTables.joined(separator: ",")), ','))
                WITH ORDINALITY AS retired(name, position)
            WHERE to_regclass(\(bind: schema) || '.' || retired.name) IS NOT NULL
            ORDER BY retired.position
            LIMIT 1
            """).first(decoding: RetiredTableRow.self) {
            throw V2SchemaReadinessError.unavailableTable(schema + "." + retired.name + ".retired")
        }
        for (table,payload) in [("message_moderation_admissions","admission"),("message_moderation_receipts","receipt"),("member_administration_admissions","admission"),("member_administration_receipts","receipt"),("membership_operation_admissions","admission"),("membership_operation_receipts","receipt"),("group_capability_admissions","admission"),("group_capability_receipts","receipt")] {
            guard let contract=try await sql.raw("""
                SELECT NOT EXISTS(SELECT 1 FROM (VALUES ('actor_user_id','uuid'),('operation_id','uuid'),('room_id','uuid'),(\(bind:payload),'jsonb')) expected(name,type)
                    LEFT JOIN information_schema.columns actual ON actual.table_schema=\(bind:schema) AND actual.table_name=\(bind:table)
                    AND actual.column_name=expected.name AND actual.udt_name=expected.type WHERE actual.column_name IS NULL)
                    AND EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
                    WHERE t.tgrelid=to_regclass(\(bind:schema+"."+table)) AND t.tgname=\(bind:table+"_immutable")
                    AND t.tgtype=27 AND t.tgenabled='O' AND NOT t.tgisinternal AND p.proname='reject_message_mutation_receipt_mutation'
                    AND p.pronamespace=(SELECT oid FROM pg_namespace WHERE nspname=\(bind:schema))
                    AND encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')='3a110559fbb4f875263df3b192f1eebe272b3d51a0a6f7354ca389e00a8583b2') AS valid
                """).first(decoding:ProfileOperationContractRow.self),contract.valid else {
                throw V2SchemaReadinessError.unavailableTable("\(schema).\(table).contract")
            }
        }
        guard let social=try await sql.raw("""
            SELECT NOT EXISTS(SELECT 1 FROM (VALUES ('actor_user_id','uuid'),('operation_id','uuid'),('kind','text'),('receipt','jsonb')) expected(name,type)
            LEFT JOIN information_schema.columns actual ON actual.table_schema=\(bind:schema) AND actual.table_name='social_operation_receipts'
            AND actual.column_name=expected.name AND actual.udt_name=expected.type WHERE actual.column_name IS NULL)
            AND EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid WHERE t.tgrelid=to_regclass(\(bind:schema+".social_operation_receipts"))
            AND t.tgname='social_operation_receipts_immutable' AND t.tgtype=27 AND t.tgenabled='O' AND NOT t.tgisinternal
            AND p.pronamespace=(SELECT oid FROM pg_namespace WHERE nspname=\(bind:schema)) AND p.proname='reject_message_mutation_receipt_mutation'
            AND encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')='3a110559fbb4f875263df3b192f1eebe272b3d51a0a6f7354ca389e00a8583b2') AS valid
            """).first(decoding:ProfileOperationContractRow.self),social.valid else { throw V2SchemaReadinessError.unavailableTable(schema+".social_operation_receipts.contract") }
        for table in ["account_preference_receipts","group_creation_owner_receipts","direct_room_owner_receipts"] {
            guard let proof=try await sql.raw("""
                SELECT NOT EXISTS(SELECT 1 FROM (VALUES ('actor_user_id','uuid'),('operation_id','uuid'),('receipt','jsonb')) expected(name,type)
                  LEFT JOIN information_schema.columns actual ON actual.table_schema=\(bind:schema) AND actual.table_name=\(bind:table)
                  AND actual.column_name=expected.name AND actual.udt_name=expected.type WHERE actual.column_name IS NULL)
                  AND EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
                  WHERE t.tgrelid=to_regclass(\(bind:schema+"."+table)) AND t.tgname=\(bind:table+"_immutable")
                  AND t.tgtype=27 AND t.tgenabled='O' AND NOT t.tgisinternal
                  AND p.pronamespace=(SELECT oid FROM pg_namespace WHERE nspname=\(bind:schema))
                  AND p.proname='reject_message_mutation_receipt_mutation'
                  AND encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')='3a110559fbb4f875263df3b192f1eebe272b3d51a0a6f7354ca389e00a8583b2') AS valid
                """).first(decoding:ProfileOperationContractRow.self),proof.valid else { throw V2SchemaReadinessError.unavailableTable(schema+"."+table+".proof_contract") }
        }
        guard let phase=try await sql.raw("""
            SELECT EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
            WHERE t.tgrelid=to_regclass(\(bind:schema+".group_creation_operations")) AND t.tgname='group_creation_operations_immutable' AND t.tgtype=27 AND t.tgenabled='O' AND NOT t.tgisinternal
            AND p.pronamespace=(SELECT oid FROM pg_namespace WHERE nspname=\(bind:schema)) AND p.proname='protect_group_creation_operation'
            AND encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')='55675fc998fe04d8e6cd2fd5bc8cfce6c5fa2f109a480deabc2a16404124374c') AS valid
            """).first(decoding:ProfileOperationContractRow.self),phase.valid else { throw V2SchemaReadinessError.unavailableTable(schema+".group_creation_operations.phase_contract") }
        guard let phase=try await sql.raw("""
            SELECT EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
            WHERE t.tgrelid=to_regclass(\(bind:schema+".group_creation_pages")) AND t.tgname='group_creation_pages_immutable' AND t.tgtype=27 AND t.tgenabled='O' AND NOT t.tgisinternal
            AND p.pronamespace=(SELECT oid FROM pg_namespace WHERE nspname=\(bind:schema)) AND p.proname='protect_group_creation_page'
            AND encode(sha256(convert_to(replace(p.prosrc,\(bind:schema+"."),'im_v2.'),'UTF8')),'hex')='96145f80f282327d00b5057937e88f4ce38c179485df552dbf8cd1fcf05a279d') AS valid
            """).first(decoding:ProfileOperationContractRow.self),phase.valid else { throw V2SchemaReadinessError.unavailableTable(schema+".group_creation_pages.phase_contract") }
        guard let phase=try await sql.raw("""
            SELECT EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
            WHERE t.tgrelid=to_regclass(\(bind:schema+".direct_room_operation_handoffs")) AND t.tgname='direct_room_handoff_protected' AND t.tgtype=27 AND t.tgenabled='O' AND NOT t.tgisinternal
            AND p.pronamespace=(SELECT oid FROM pg_namespace WHERE nspname=\(bind:schema)) AND p.proname='protect_direct_room_handoff'
            AND encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')='50f166da94a12a8fbc19826e0180d1e483786cfae2f5ed96bafc42cd0883b9b1') AS valid
            """).first(decoding:ProfileOperationContractRow.self),phase.valid else { throw V2SchemaReadinessError.unavailableTable(schema+".direct_room_operation_handoffs.phase_contract") }
        for (table,payload,trigger) in [("group_invitation_admissions","admission","group_invitation_admission_immutable"),("group_invitation_receipts","receipt","group_invitation_receipt_immutable"),("group_invitation_control_commands","command","group_invitation_command_immutable")] {
            guard let invitation=try await sql.raw("""
                SELECT NOT EXISTS(SELECT 1 FROM (VALUES ('actor_user_id','uuid'),('operation_id','uuid'),(\(bind:payload),'jsonb')) expected(name,type)
                LEFT JOIN information_schema.columns actual ON actual.table_schema=\(bind:schema) AND actual.table_name=\(bind:table)
                AND actual.column_name=expected.name AND actual.udt_name=expected.type WHERE actual.column_name IS NULL)
                AND EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid WHERE t.tgrelid=to_regclass(\(bind:schema+"."+table))
                AND t.tgname=\(bind:trigger) AND t.tgenabled='O' AND NOT t.tgisinternal AND t.tgtype=27
                AND p.pronamespace=(SELECT oid FROM pg_namespace WHERE nspname=\(bind:schema)) AND p.proname='reject_group_invitation_operation_mutation'
                AND encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')='ce8a82cb032c668a6f5bafaeec509440491e5284df8e4812ef2d0b5d3c54d3df') AS valid
                """).first(decoding:ProfileOperationContractRow.self),invitation.valid else { throw V2SchemaReadinessError.unavailableTable(schema+"."+table+".operation_contract") }
        }
        for (table,payload,trigger) in [("remote_device_revocation_baselines","baseline","remote_device_revocation_baseline_immutable"),("remote_device_revocation_receipts","receipt","remote_device_revocation_receipt_immutable")] {
            guard let remote=try await sql.raw("""
                SELECT NOT EXISTS(SELECT 1 FROM (VALUES ('actor_user_id','uuid'),('current_device_id','uuid'),(\(bind:payload),'jsonb')) expected(name,type)
                LEFT JOIN information_schema.columns actual ON actual.table_schema=\(bind:schema) AND actual.table_name=\(bind:table)
                AND actual.column_name=expected.name AND actual.udt_name=expected.type AND actual.is_nullable='NO' WHERE actual.column_name IS NULL)
                AND EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid=to_regclass(\(bind:schema+"."+table)) AND contype='p' AND convalidated AND NOT condeferrable
                    AND pg_get_constraintdef(oid)=\(bind:table == "remote_device_revocation_baselines" ? "PRIMARY KEY (baseline_id)" : "PRIMARY KEY (actor_user_id, operation_id)"))
                AND EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid=to_regclass(\(bind:schema+"."+table)) AND contype='c' AND convalidated
                    AND position('jsonb_typeof' in pg_get_constraintdef(oid))>0 AND position('octet_length' in pg_get_constraintdef(oid))>0
                    AND position(\(bind:table == "remote_device_revocation_baselines" ? "32768" : "65536") in pg_get_constraintdef(oid))>0)
                AND EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid WHERE t.tgrelid=to_regclass(\(bind:schema+"."+table))
                AND t.tgname=\(bind:trigger) AND t.tgenabled='O' AND NOT t.tgisinternal AND t.tgtype=27
                AND p.pronamespace=(SELECT oid FROM pg_namespace WHERE nspname=\(bind:schema)) AND p.proname='guard_remote_device_revocation_metadata'
                AND encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')='1454e5f25a2fc7b4b156af0e678ae84170cc1664029ac6b9df6af631f9595c60') AS valid
                """).first(decoding:ProfileOperationContractRow.self),remote.valid else { throw V2SchemaReadinessError.unavailableTable(schema+"."+table+".operation_contract") }
        }
        guard let remoteBaseline=try await sql.raw("""
            SELECT (SELECT count(*)=2 FROM information_schema.columns WHERE table_schema=\(bind:schema)
              AND table_name='remote_device_revocation_baselines' AND is_nullable='NO'
              AND (column_name,udt_name) IN (('baseline_id','uuid'),('expires_at','timestamptz')))
            AND EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema=\(bind:schema)
              AND table_name='remote_device_revocation_receipts' AND column_name='operation_id' AND udt_name='uuid' AND is_nullable='NO')
            AND EXISTS(SELECT 1 FROM pg_index i JOIN pg_class idx ON idx.oid=i.indexrelid JOIN pg_am am ON am.oid=idx.relam
              WHERE i.indrelid=to_regclass(\(bind:schema+".remote_device_revocation_baselines")) AND idx.relname='remote_device_revocation_baseline_expiry_idx'
              AND am.amname='btree' AND i.indisvalid AND i.indisready AND i.indpred IS NULL AND i.indexprs IS NULL
              AND pg_get_indexdef(i.indexrelid,1,TRUE)='expires_at') AS valid
            """).first(decoding:ProfileOperationContractRow.self),remoteBaseline.valid else { throw V2SchemaReadinessError.unavailableTable(schema+".remote_device_revocation_baselines.expiry_contract") }
        guard let privacy=try await sql.raw("""
            SELECT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema=\(bind:schema)
            AND table_name='user_live_presence_leases' AND column_name='publication_suppressed'
            AND udt_name='bool' AND is_nullable='NO' AND column_default='true') AS valid
            """).first(decoding:ProfileOperationContractRow.self),privacy.valid else { throw V2SchemaReadinessError.unavailableTable(schema+".user_live_presence_leases.publication_contract") }
        guard let forward = try await sql.raw("""
            SELECT NOT EXISTS (SELECT 1 FROM (VALUES ('actor_user_id','uuid'),('operation_id','uuid'),
                ('command_json','jsonb'),('progress_json','jsonb'),('resolved_json','jsonb'),('next_action_at','timestamptz')) expected(name,type)
                LEFT JOIN information_schema.columns actual ON actual.table_schema=\(bind:schema)
                    AND actual.table_name='forward_plan_operations' AND actual.column_name=expected.name AND actual.udt_name=expected.type
                WHERE actual.column_name IS NULL)
                AND EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass(\(bind:schema + ".forward_plan_operations"))
                    AND tgname='forward_plan_operations_original' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27)
                AND EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
                    WHERE t.tgrelid=to_regclass(\(bind:schema + ".forward_plan_operations")) AND t.tgname='forward_plan_operations_original'
                    AND p.pronamespace=(SELECT oid FROM pg_namespace WHERE nspname=\(bind:schema))
                    AND encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')='80cbb1adb53b73cdadf02e34c635e15e575f28e6656a786af2eb041a97e718cd')
                AND EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass(\(bind:schema + ".forward_preparation_rejections"))
                    AND tgname='forward_preparation_rejections_immutable' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27) AS valid
            """).first(decoding:ProfileOperationContractRow.self), forward.valid else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).forward_plan_operations.contract")
        }
        guard let sendContract = try await sql.raw("""
            SELECT NOT EXISTS (
                SELECT 1 FROM (VALUES ('operation_fingerprint','bytea'),('operation_resolved_at_ms','int8')) expected(name,type)
                LEFT JOIN information_schema.columns actual ON actual.table_schema=\(bind:schema)
                    AND actual.table_name='message_send_completions' AND actual.column_name=expected.name
                    AND actual.udt_name=expected.type
                WHERE actual.column_name IS NULL)
              AND to_regclass(\(bind:schema + ".message_send_operation_receipts")) IS NULL
              AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass(\(bind:schema + ".message_send_completions"))
                AND tgname='message_send_completions_immutable' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27) AS valid
            """).first(decoding:ProfileOperationContractRow.self), sendContract.valid else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).message_send_completions.contract")
        }
        guard let mutationContract = try await sql.raw("""
            SELECT NOT EXISTS (
                SELECT 1 FROM (VALUES ('actor_user_id','uuid'),('operation_id','uuid'),
                    ('room_id','uuid'),('message_id','uuid'),('kind','text'),('fingerprint_version','int2'),
                    ('request_fingerprint','bytea'),('receipt','jsonb'),('resolved_at','timestamptz')) expected(name,type)
                LEFT JOIN information_schema.columns actual ON actual.table_schema=\(bind:schema)
                    AND actual.table_name='message_mutation_receipts' AND actual.column_name=expected.name
                    AND actual.udt_name=expected.type AND actual.is_nullable='NO'
                WHERE actual.column_name IS NULL)
              AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass(\(bind:schema + ".message_mutation_receipts"))
                AND tgname='message_mutation_receipts_immutable' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27) AS valid
            """).first(decoding:ProfileOperationContractRow.self), mutationContract.valid else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).message_mutation_receipts.contract")
        }
        guard let reactionContract = try await sql.raw("""
            SELECT NOT EXISTS (
                SELECT 1 FROM (VALUES ('actor_user_id','uuid'),('operation_id','uuid'),
                    ('room_id','uuid'),('message_id','uuid'),('fingerprint_version','int2'),
                    ('request_fingerprint','bytea'),('receipt','jsonb'),('resolved_at','timestamptz')) expected(name,type)
                LEFT JOIN information_schema.columns actual ON actual.table_schema=\(bind:schema)
                    AND actual.table_name='message_reaction_receipts' AND actual.column_name=expected.name
                    AND actual.udt_name=expected.type AND actual.is_nullable='NO'
                WHERE actual.column_name IS NULL)
              AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass(\(bind:schema + ".message_reaction_receipts"))
                AND tgname='message_reaction_receipts_immutable' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27)
              AND to_regclass(\(bind:schema + ".message_reaction_operations")) IS NULL
              AND NOT EXISTS (
                SELECT 1 FROM (VALUES ('room_id','uuid'),('message_id','uuid'),('actor_user_id','uuid'),
                    ('reaction','text'),('revision','int8'),('target_state','text')) expected(name,type)
                LEFT JOIN information_schema.columns actual ON actual.table_schema=\(bind:schema)
                    AND actual.table_name='message_reaction_key_revisions' AND actual.column_name=expected.name
                    AND actual.udt_name=expected.type AND actual.is_nullable='NO'
                WHERE actual.column_name IS NULL) AS valid
            """).first(decoding:ProfileOperationContractRow.self), reactionContract.valid else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).message_reaction_receipts.contract")
        }
        guard let personalContract = try await sql.raw("""
            SELECT NOT EXISTS (
                SELECT 1 FROM (VALUES
                    ('personal_preference_operation_receipts','receipt','jsonb','NO'),
                    ('personal_preference_operation_receipts','request_fingerprint','bytea','NO'),
                    ('personal_preference_operation_receipts','fingerprint_version','int2','NO'),
                    ('personal_preference_operation_receipts','identity_key','text','NO'),
                    ('user_room_preferences','revision','int8','NO'),
                    ('user_message_favorites','revision','int8','NO'),
                    ('user_message_favorites','is_favorited','bool','NO')) AS expected(table_name,column_name,udt_name,is_nullable)
                LEFT JOIN information_schema.columns actual ON actual.table_schema=\(bind:schema)
                    AND (actual.table_name,actual.column_name,actual.udt_name,actual.is_nullable)=
                        (expected.table_name,expected.column_name,expected.udt_name,expected.is_nullable)
                WHERE actual.column_name IS NULL)
              AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass(\(bind:schema + ".personal_preference_operation_receipts"))
                AND tgname='personal_preference_operation_immutable' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27) AS valid
            """).first(decoding: ProfileOperationContractRow.self), personalContract.valid else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).personal_preference_operation_receipts.contract")
        }
        for (table, entity, trigger) in [
            ("contact_alias_operation_receipts", "target_user_id", "contact_alias_operation_immutable"),
            ("group_nickname_operation_receipts", "room_id", "group_nickname_operation_immutable")
        ] {
            guard let contract = try await sql.raw("""
                SELECT NOT EXISTS (
                    SELECT 1 FROM (VALUES ('identity_key','text'), ('actor_user_id','uuid'),
                        ('operation_id','uuid'), (\(bind:entity),'uuid'), ('fingerprint_version','int2'),
                        ('request_fingerprint','bytea'), ('receipt','jsonb'), ('created_at','timestamptz')) expected(name,type)
                    LEFT JOIN information_schema.columns actual ON actual.table_schema=\(bind:schema)
                        AND actual.table_name=\(bind:table) AND actual.column_name=expected.name
                        AND actual.udt_name=expected.type AND actual.is_nullable='NO'
                    WHERE actual.column_name IS NULL)
                  AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass(\(bind:schema + "." + table))
                    AND tgname=\(bind:trigger) AND tgenabled='O' AND NOT tgisinternal AND tgtype=27)
                  AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid=to_regclass(\(bind:schema + "." + table))
                    AND contype='u' AND convalidated AND pg_get_constraintdef(oid)='UNIQUE (actor_user_id, operation_id)') AS valid
                """).first(decoding:ProfileOperationContractRow.self), contract.valid else {
                throw V2SchemaReadinessError.unavailableTable("\(schema).\(table).contract")
            }
        }
        guard let profileContract = try await sql.raw("""
            SELECT EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema=\(bind:schema) AND table_name='public_profile_update_operations'
                  AND column_name='receipt' AND data_type='jsonb' AND is_nullable='NO')
              AND EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema=\(bind:schema) AND table_name='public_profile_update_operations'
                  AND column_name='request_fingerprint' AND data_type='bytea' AND is_nullable='NO')
              AND EXISTS (SELECT 1 FROM pg_trigger trigger
                JOIN pg_class relation ON relation.oid=trigger.tgrelid JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
                WHERE namespace.nspname=\(bind:schema) AND relation.relname='public_profile_update_operations'
                  AND trigger.tgname='public_profile_operation_immutable' AND NOT trigger.tgisinternal AND trigger.tgenabled='O' AND trigger.tgtype=27)
              AND EXISTS (SELECT 1 FROM pg_constraint
                WHERE conrelid=to_regclass(\(bind:schema + ".public_profile_update_operations"))
                  AND conname='public_profile_update_operations_result_check' AND convalidated
                  AND pg_get_constraintdef(oid) LIKE '%result_revision IS NOT NULL%')
              AND EXISTS (SELECT 1 FROM pg_proc procedure
                JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
                WHERE namespace.nspname=\(bind:schema) AND procedure.proname='protect_profile_operation_receipt'
                  AND procedure.prosrc LIKE '%RAISE EXCEPTION ''profile operation receipts are immutable''%') AS valid
            """).first(decoding: ProfileOperationContractRow.self), profileContract.valid else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).public_profile_update_operations.contract")
        }
        guard let resourceContract = try await sql.raw("""
            SELECT NOT EXISTS (
                SELECT 1 FROM (VALUES
                  ('resource_group_avatar_closures','actor_user_id','uuid','NO'),
                  ('resource_group_avatar_closures','operation_id','uuid','NO'),
                  ('resource_group_avatar_closures','room_id','uuid','NO'),
                  ('resource_group_avatar_closures','requested_media_id','uuid','YES'),
                  ('resource_group_avatar_closures','expected_revision','int8','NO'),
                  ('resource_group_avatar_closures','closed_at','timestamptz','NO'),
                  ('resource_group_avatars','room_id','uuid','NO'),
                  ('resource_group_avatars','media_id','uuid','YES'),
                  ('resource_group_avatars','revision','int8','NO'),
                  ('resource_group_avatars','updated_by_user_id','uuid','NO'),
                  ('resource_group_avatars','updated_at','timestamptz','NO'),
                  ('resource_group_avatar_operations','actor_user_id','uuid','NO'),
                  ('resource_group_avatar_operations','operation_id','uuid','NO'),
                  ('resource_group_avatar_operations','room_id','uuid','NO'),
                  ('resource_group_avatar_operations','requested_media_id','uuid','YES'),
                  ('resource_group_avatar_operations','expected_revision','int8','NO'),
                  ('resource_group_avatar_operations','resulting_revision','int8','NO'),
                  ('resource_group_avatar_operations','room_sequence','int8','NO'),
                  ('resource_group_avatar_operations','event_id','uuid','NO'),
                  ('resource_group_avatar_operations','created_at','timestamptz','NO'),
                  ('resource_catalog','media_id','uuid','NO'),
                  ('message_media_references','room_id','uuid','NO'),
                  ('message_media_references','room_sequence','int8','NO'),
                  ('resource_catalog','home_kind','text','NO'),
                  ('resource_catalog','home_id','uuid','NO'),
                  ('resource_catalog','usage_kind','text','NO'),
                  ('resource_catalog','generation','int8','NO'),
                  ('resource_catalog','display_name','text','NO'),
                  ('resource_catalog','pixel_width','int4','YES'),
                  ('resource_catalog','pixel_height','int4','YES'),
                  ('resource_catalog','duration_ms','int8','YES'),
                  ('resource_forward_outputs','export_id','uuid','NO'),
                  ('resource_forward_outputs','ordinal','int4','NO'),
                  ('resource_forward_outputs','target_media_id','uuid','NO'),
                  ('resource_forward_outputs','reference_json','jsonb','NO'),
                  ('resource_forward_outputs','byte_count','int8','NO'),
                  ('resource_forward_outputs','sha256','bytea','NO'),
                  ('resource_upload_sessions','session_id','uuid','NO'),
                  ('resource_upload_sessions','media_id','uuid','NO'),
                  ('resource_upload_sessions','home_kind','text','NO'),
                  ('resource_upload_sessions','home_id','uuid','NO'),
                  ('resource_upload_sessions','actor_user_id','uuid','NO'),
                  ('resource_upload_sessions','device_id','uuid','NO'),
                  ('resource_upload_sessions','operation_id','uuid','NO'),
                  ('resource_upload_sessions','request_json','jsonb','NO'),
                  ('resource_upload_sessions','generation','int8','NO'),
                  ('resource_upload_sessions','storage_binding_id','text','NO'),
                  ('resource_upload_sessions','storage_configuration_revision','int4','NO'),
                  ('resource_upload_sessions','placement_json','jsonb','NO'),
                  ('resource_blob_placements','reference_json','jsonb','NO'),
                  ('resource_blob_placements','byte_count','int8','NO'),
                  ('resource_blob_placements','sha256','bytea','NO'),
                  ('resource_variants','reference_json','jsonb','NO'),
                  ('resource_variants','variant_id','uuid','NO'),
                  ('resource_storage_migrations','operation_id','uuid','NO'),
                  ('resource_storage_migrations','media_id','uuid','NO'),
                  ('resource_storage_migrations','generation','int8','NO'),
                  ('resource_storage_migrations','variant_id','uuid','YES'),
                  ('resource_storage_migrations','request_json','jsonb','NO'),
                  ('resource_storage_migrations','source_json','jsonb','NO'),
                  ('resource_storage_migrations','destination_json','jsonb','NO'),
                  ('resource_storage_migrations','destination_placement_id','uuid','NO'),
                  ('resource_storage_migrations','byte_count','int8','NO'),
                  ('resource_storage_migrations','sha256','bytea','NO'),
                  ('resource_storage_migrations','source_released_at','timestamptz','YES'),
                  ('resource_storage_migrations','state','text','NO'),
                  ('resource_storage_migrations','claim_token','uuid','YES'),
                  ('resource_storage_migrations','lease_expires_at','timestamptz','YES'),
                  ('resource_storage_migrations','attempt_count','int8','NO'),
                  ('resource_storage_migrations','retry_at','timestamptz','NO'),
                  ('resource_storage_migrations','switched_at','timestamptz','YES'),
                  ('resource_storage_migrations','created_at','timestamptz','NO'),
                  ('resource_storage_migrations','updated_at','timestamptz','NO'),
                  ('resource_imports','home_json','jsonb','NO'),
                  ('resource_imports','request_json','jsonb','NO'),
                  ('resource_imports','target_media_id','uuid','NO'),
                  ('resource_imports','source_released_at','timestamptz','YES'),
                  ('resource_import_holds','reference_json','jsonb','NO'),
                  ('resource_import_holds','request_json','jsonb','NO'),
                  ('resource_import_holds','byte_count','int8','NO'),
                  ('resource_import_holds','sha256','bytea','NO'),
                  ('resource_import_holds','content_type','text','NO'),
                  ('resource_import_source_closures','actor_user_id','uuid','NO'),
                  ('resource_import_source_closures','operation_id','uuid','NO'),
                  ('resource_import_source_closures','closed_at','timestamptz','NO')
                ) expected(table_name,column_name,udt_name,is_nullable)
                LEFT JOIN information_schema.columns actual
                  ON actual.table_schema = \(bind: schema) AND actual.table_name=expected.table_name
                  AND actual.column_name=expected.column_name AND actual.udt_name=expected.udt_name
                  AND actual.is_nullable=expected.is_nullable
                WHERE actual.column_name IS NULL
            ) AND NOT EXISTS (
                SELECT 1 FROM (VALUES
                  ('resource_group_avatar_closures','PRIMARY KEY (actor_user_id, operation_id)'),
                  ('resource_group_avatar_closures','CHECK ((expected_revision >= 0))'),
                  ('resource_group_avatar_closures','CHECK (isfinite(closed_at))'),
                  ('resource_group_avatars','PRIMARY KEY (room_id)'),
                  ('resource_group_avatars','FOREIGN KEY (room_id) REFERENCES im_v2.group_rooms(room_id)'),
                  ('resource_group_avatars','FOREIGN KEY (media_id) REFERENCES im_v2.media_objects(media_id)'),
                  ('resource_group_avatars','CHECK ((revision > 0))'),
                  ('resource_group_avatar_operations','PRIMARY KEY (actor_user_id, operation_id)'),
                  ('resource_group_avatar_operations','UNIQUE (event_id)'),
                  ('resource_group_avatar_operations','CHECK ((expected_revision >= 0))'),
                  ('resource_group_avatar_operations','CHECK ((resulting_revision > 0))'),
                  ('resource_group_avatar_operations','CHECK ((room_sequence > 0))'),
                  ('resource_catalog','PRIMARY KEY (media_id)'),
                  ('resource_catalog','CHECK ((generation > 0))'),
                  ('resource_catalog','CHECK (((duration_ms >= 1) AND (duration_ms <= ''2678400000''::bigint)))'),
                  ('resource_catalog','CHECK ((((pixel_width IS NULL) AND (pixel_height IS NULL)) OR ((pixel_width IS NOT NULL) AND (pixel_height IS NOT NULL) AND ((pixel_width >= 1) AND (pixel_width <= 16384)) AND ((pixel_height >= 1) AND (pixel_height <= 16384)) AND (((pixel_width)::bigint * pixel_height) <= 40000000))))'),
                  ('resource_catalog','FOREIGN KEY (media_id) REFERENCES im_v2.media_objects(media_id)'),
                  ('resource_catalog','CHECK ((((usage_kind = ''user_avatar''::text) AND (home_kind = ''account''::text)) OR ((usage_kind = ANY (ARRAY[''message_attachment''::text, ''group_avatar''::text])) AND (home_kind = ''room''::text))))'),
                  ('resource_forward_outputs','PRIMARY KEY (export_id, ordinal)'),
                  ('resource_forward_outputs','UNIQUE (target_media_id)'),
                  ('resource_forward_outputs','FOREIGN KEY (target_media_id) REFERENCES im_v2.media_objects(media_id)'),
                  ('resource_forward_outputs','FOREIGN KEY (export_id, ordinal) REFERENCES im_v2.message_forward_media_imports(export_id, ordinal)'),
                  ('resource_forward_outputs','CHECK ((byte_count > 0))'),
                  ('resource_forward_outputs','CHECK ((octet_length(sha256) = 32))'),
                  ('resource_upload_sessions','PRIMARY KEY (session_id)'),
                  ('resource_upload_sessions','UNIQUE (media_id)'),
                  ('resource_upload_sessions','UNIQUE (home_kind, home_id, actor_user_id, operation_id)'),
                  ('resource_upload_sessions','CHECK ((generation > 0))'),
                  ('resource_upload_sessions','CHECK ((storage_configuration_revision > 0))'),
                  ('resource_blob_placements','PRIMARY KEY (placement_id)'),
                  ('resource_blob_placements','UNIQUE (media_id, generation)'),
                  ('resource_blob_placements','CHECK ((octet_length(sha256) = 32))'),
                  ('resource_blob_placements','CHECK ((byte_count > 0))'),
                  ('resource_variants','PRIMARY KEY (media_id, generation, recipe, recipe_version, size)'),
                  ('resource_variants','UNIQUE (variant_id)'),
                  ('resource_storage_migrations','PRIMARY KEY (operation_id)'),
                  ('resource_storage_migrations','UNIQUE (destination_placement_id)'),
                  ('resource_storage_migrations','FOREIGN KEY (media_id) REFERENCES im_v2.media_objects(media_id)'),
                  ('resource_storage_migrations','CHECK ((generation > 0))'),
                  ('resource_storage_migrations','CHECK ((byte_count > 0))'),
                  ('resource_storage_migrations','CHECK ((octet_length(sha256) = 32))'),
                  ('resource_storage_migrations','CHECK (((state = ''copying''::text) = (claim_token IS NOT NULL)))'),
                  ('resource_storage_migrations','CHECK (((state = ''copying''::text) = (lease_expires_at IS NOT NULL)))'),
                  ('resource_storage_migrations','CHECK (((state = ''switched''::text) = (switched_at IS NOT NULL)))'),
                  ('resource_storage_migrations','CHECK (((source_released_at IS NULL) OR ((state = ''switched''::text) AND isfinite(source_released_at))))'),
                  ('resource_variants','CHECK (((state <> ''ready''::text) OR ((byte_count IS NOT NULL) AND (sha256 IS NOT NULL) AND (byte_count > 0) AND (octet_length(sha256) = 32))))'),
                  ('resource_imports','PRIMARY KEY (actor_user_id, operation_id)'),
                  ('resource_imports','CHECK (((source_released_at IS NULL) OR ((state = ANY (ARRAY[''processing''::text, ''ready''::text, ''cancelled''::text, ''failed''::text])) AND isfinite(source_released_at))))'),
                  ('resource_import_holds','PRIMARY KEY (actor_user_id, operation_id)'),
                  ('resource_import_holds','CHECK ((byte_count > 0))'),
                  ('resource_import_holds','CHECK ((octet_length(sha256) = 32))'),
                  ('resource_import_holds','CHECK (((length(content_type) >= 1) AND (length(content_type) <= 127)))'),
                  ('resource_import_source_closures','PRIMARY KEY (actor_user_id, operation_id)'),
                  ('resource_import_source_closures','CHECK (isfinite(closed_at))')
                ) expected(table_name,definition)
                WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c
                  WHERE c.conrelid=to_regclass(\(bind: schema + ".") || expected.table_name)
                  AND c.convalidated AND NOT c.condeferrable AND replace(pg_get_constraintdef(c.oid),\(bind: schema + "."),'im_v2.')=expected.definition)
            ) AND EXISTS (
                SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
                WHERE t.tgrelid=to_regclass(\(bind: schema + ".resource_group_avatar_operations"))
                  AND t.tgname='resource_group_avatar_operations_immutable' AND t.tgenabled='O'
                  AND NOT t.tgisinternal AND t.tgtype=27 AND t.tgqual IS NULL
                  AND p.pronamespace=(SELECT oid FROM pg_namespace WHERE nspname=\(bind: schema))
                  AND p.proname='reject_group_avatar_operation_mutation'
                  AND encode(sha256(convert_to(replace(p.prosrc,\(bind: schema + "."),'im_v2.'),'UTF8')),'hex')='4296ae3a368755188ceb1df59239b3860fe445da8ab147d948b411c1645aa542'
            )
            AND (SELECT count(*)=3 FROM pg_index
                WHERE indrelid=to_regclass(\(bind: schema + ".resource_storage_migrations")) AND indisvalid AND indisready
                  AND replace(pg_get_indexdef(indexrelid),\(bind: schema + "."),'im_v2.') IN (
                    'CREATE UNIQUE INDEX resource_storage_migrations_active_media_idx ON im_v2.resource_storage_migrations USING btree (media_id) WHERE (state = ANY (ARRAY[''pending''::text, ''copying''::text]))',
                    'CREATE INDEX resource_storage_migrations_recovery_idx ON im_v2.resource_storage_migrations USING btree (updated_at, operation_id) WHERE (state = ANY (ARRAY[''pending''::text, ''copying''::text]))',
                    'CREATE INDEX resource_storage_migrations_retained_idx ON im_v2.resource_storage_migrations USING btree (media_id) WHERE (source_released_at IS NULL)'))
            AND EXISTS (SELECT 1 FROM pg_index
                WHERE indrelid=to_regclass(\(bind: schema + ".resource_imports")) AND indisvalid AND indisready
                  AND replace(pg_get_indexdef(indexrelid),\(bind: schema + "."),'im_v2.') =
                    'CREATE INDEX resource_imports_pending_idx ON im_v2.resource_imports USING btree (updated_at, operation_id) WHERE ((state = ANY (ARRAY[''pending''::text, ''copying''::text, ''processing''::text])) OR (source_released_at IS NULL))')
            AND EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
                WHERE t.tgrelid=to_regclass(\(bind: schema + ".resource_import_source_closures"))
                  AND t.tgname='resource_import_source_closures_immutable' AND t.tgenabled='O'
                  AND NOT t.tgisinternal AND t.tgtype=27 AND t.tgqual IS NULL
                  AND p.pronamespace=(SELECT oid FROM pg_namespace WHERE nspname=\(bind: schema))
                  AND p.proname='reject_resource_import_source_closure_mutation'
                  AND encode(sha256(convert_to(replace(p.prosrc,\(bind: schema + "."),'im_v2.'),'UTF8')),'hex')='12ddbdfcf09ecb0d8a1b825f56786746463fc42ed7074494aa3c515bf85f7a3b')
            AS exists
            """).first(decoding: ExistsRow.self), resourceContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).resource_upload_sessions[lifecycle-contract]")
        }
        // Both writes and bounded directory reads depend on these exact DDL facts.
        // An old/mutated trigger must not let the listener start accepting work.
        guard let directoryContract = try await sql.raw("""
            SELECT EXISTS (
                SELECT 1 FROM pg_index
                WHERE indrelid=to_regclass(\(bind: schema + ".message_media_references")) AND indisvalid AND indisready
                  AND replace(pg_get_indexdef(indexrelid),\(bind: schema + "."),'im_v2.') =
                    'CREATE INDEX message_media_references_room_directory_idx ON im_v2.message_media_references USING btree (room_id, room_sequence DESC, ordinal DESC, media_id DESC) WHERE (revoked_at IS NULL)'
            )
            AND EXISTS (
                SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
                WHERE t.tgrelid=to_regclass(\(bind: schema + ".message_media_references")) AND t.tgname='message_media_references_room_position'
                  AND t.tgenabled='O' AND NOT t.tgisinternal AND t.tgtype=23 AND t.tgqual IS NULL
                  AND (SELECT array_agg(a.attname::text ORDER BY k.ordinal)
                       FROM unnest(t.tgattr::smallint[]) WITH ORDINALITY k(attnum,ordinal)
                       JOIN pg_attribute a ON a.attrelid=t.tgrelid AND a.attnum=k.attnum)
                      = ARRAY['message_id','room_id','room_sequence']
                  AND p.pronamespace=to_regnamespace(\(bind: schema)) AND p.proname='bind_message_media_room_position'
                  AND p.pronargs=0 AND p.prorettype='trigger'::regtype AND p.provolatile='v' AND NOT p.prosecdef
                  AND p.proconfig=ARRAY[\(bind: "search_path=pg_catalog, " + schema)]
                  AND encode(sha256(convert_to(replace(p.prosrc,\(bind: schema + "."),'im_v2.'),'UTF8')),'hex')='87a78224a9113f060a302c49e979fc68e7914b49e9d170323663e05730daf3eb'
            )
            AS exists
            """).first(decoding: ExistsRow.self), directoryContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).message_media_references[directory-contract]")
        }
        guard let groupAvatarRecovery = try await sql.raw("""
            SELECT current_setting('transaction_isolation') = 'read committed'
            AND NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid=to_regclass(\(bind: schema + ".resource_group_avatar_closures")) AND contype='f')
            AND NOT EXISTS(
                SELECT 1 FROM (VALUES
                    ('resource_group_avatar_operations','resource_group_avatar_operations_close_fence'),
                    ('resource_group_avatar_closures','resource_group_avatar_closures_commit_fence')
                ) expected(table_name,trigger_name)
                WHERE NOT EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
                    WHERE t.tgrelid=to_regclass(\(bind: schema + ".") || expected.table_name) AND t.tgname=expected.trigger_name
                      AND t.tgenabled='O' AND NOT t.tgisinternal AND t.tgtype=7 AND t.tgqual IS NULL
                      AND p.pronamespace=(SELECT oid FROM pg_namespace WHERE nspname=\(bind: schema))
                      AND p.proname='fence_group_avatar_terminal_result' AND p.provolatile='v'
                      AND encode(sha256(convert_to(replace(p.prosrc,\(bind: schema + "."),'im_v2.'),'UTF8')),'hex')='e480bc5dcdcd3f5640cae14ca8ad77c1c25d93d80f5ecc5894696757935144e4')
            ) AND EXISTS(
                SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
                WHERE t.tgrelid=to_regclass(\(bind: schema + ".resource_group_avatar_closures"))
                  AND t.tgname='resource_group_avatar_closures_immutable' AND t.tgenabled='O'
                  AND NOT t.tgisinternal AND t.tgtype=27 AND t.tgqual IS NULL
                  AND p.pronamespace=(SELECT oid FROM pg_namespace WHERE nspname=\(bind: schema))
                  AND p.proname='reject_group_avatar_operation_mutation'
                  AND encode(sha256(convert_to(replace(p.prosrc,\(bind: schema + "."),'im_v2.'),'UTF8')),'hex')='4296ae3a368755188ceb1df59239b3860fe445da8ab147d948b411c1645aa542'
            ) AS exists
            """).first(decoding: ExistsRow.self), groupAvatarRecovery.exists else {
            throw V2SchemaReadinessError.unavailableTable("im_v2.resource_group_avatar_closures[terminal-contract]")
        }
        guard let operationRecovery = try await sql.raw("""
            SELECT current_setting('transaction_isolation') = 'read committed'
            AND NOT EXISTS (
                SELECT 1 FROM pg_trigger t
                WHERE t.tgrelid = to_regclass(\(bind: schema + ".message_send_completions"))
                  AND t.tgname = 'message_send_completion_close_fence'
            ) AS exists
            """).first(decoding: ExistsRow.self), operationRecovery.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).message_send_completions[query-recovery]")
        }
        guard let cursor = try await sql.raw("""
            SELECT (SELECT count(*) = 2 FROM information_schema.columns
                WHERE table_schema = \(bind: schema) AND table_name = 'control_housekeeping_cursor'
                  AND is_nullable = 'NO' AND ((column_name = 'singleton' AND udt_name = 'bool')
                    OR (column_name = 'rotation' AND udt_name = 'int8')))
              AND (SELECT count(*) = 3 FROM pg_constraint
                WHERE conrelid = to_regclass(\(bind: "\(schema).control_housekeeping_cursor")) AND convalidated AND NOT condeferrable
                  AND pg_get_constraintdef(oid) IN ('PRIMARY KEY (singleton)', 'CHECK (singleton)', 'CHECK ((rotation >= 0))'))
              AND (SELECT count(*) = 1 AND bool_and(singleton AND rotation >= 0 AND rotation < \(bind: PostgresV2ControlPlaneHousekeepingStore.housekeepingRotationPeriod))
                FROM \(unsafeRaw: schema).control_housekeeping_cursor) AS exists
            """).first(decoding: ExistsRow.self), cursor.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).control_housekeeping_cursor[rotation]")
        }
        guard let ownership = try await sql.raw("""
            SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = \(bind: schema)
                AND table_name = 'user_state_event_outbox' AND column_name = 'source_room_id'
                AND udt_name = 'uuid' AND is_nullable = 'YES')
            AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass(\(bind: "\(schema).user_state_event_outbox"))
                AND conname = 'user_state_event_outbox_room_binding' AND convalidated)
            AND to_regclass(\(bind: "\(schema).user_state_event_outbox_source_room_idx")) IS NOT NULL
            AND to_regclass(\(bind: "\(schema).user_state_event_outbox_user_head_idx")) IS NOT NULL AS exists
            """).first(decoding: ExistsRow.self), ownership.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).user_state_event_outbox[source-room]")
        }
        try await verifyRoomRecoveryFence(sql: sql, schema: schema)
        guard let progress = try await sql.raw("""
            SELECT (SELECT count(*) = 4 FROM pg_attribute
                WHERE attrelid = to_regclass(\(bind: "\(schema).device_room_progress"))
                  AND attnum > 0 AND NOT attisdropped AND attnotnull
                  AND ((attname IN ('user_id','device_id','room_id') AND atttypid = 'uuid'::regtype)
                    OR (attname = 'applied_through' AND atttypid = 'bigint'::regtype)))
            AND EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass(\(bind: "\(schema).device_room_progress"))
                AND contype = 'p' AND pg_get_constraintdef(oid) = 'PRIMARY KEY (user_id, device_id, room_id)')
            AND EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass(\(bind: "\(schema).device_room_progress"))
                AND contype = 'c' AND pg_get_constraintdef(oid) = 'CHECK ((applied_through >= 0))') AS exists
            """).first(decoding: ExistsRow.self), progress.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).device_room_progress[device-cursor]")
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
                ) AND (
                    SELECT count(*) = 1 FROM information_schema.columns
                    WHERE table_schema = \(bind: schema)
                      AND table_name = 'user_read_receipt_preferences'
                      AND column_name = 'preference_revision' AND udt_name = 'int8' AND is_nullable = 'NO'
                ) AND EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = \(bind: schema) AND table_name = 'user_state_event_receipts'
                      AND column_name = 'projection_payload' AND udt_name = 'jsonb' AND is_nullable = 'NO'
                ) AND EXISTS (
                    SELECT 1 FROM pg_constraint
                    WHERE conrelid = to_regclass(\(bind: schema + ".user_state_event_receipts"))
                      AND conname = 'user_state_event_receipts_projection_payload_check' AND convalidated
                      AND pg_get_constraintdef(oid) = 'CHECK ((jsonb_typeof(projection_payload) = ''object''::text))'
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
        guard let passwordContract = try await sql.raw("""
            SELECT EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = \(bind: schema) AND table_name = 'account_password_credentials'
                  AND column_name = 'credential_revision' AND udt_name = 'int8' AND is_nullable = 'NO')
              AND EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = \(bind: schema) AND table_name = 'account_password_credentials'
                  AND column_name = 'recovery_code_hmac' AND udt_name = 'text' AND is_nullable = 'YES') AS exists
            """).first(decoding: ExistsRow.self), passwordContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).account_password_credentials[lifecycle]")
        }
        // 房间事件时间仍是服务端事实，但会话排序由客户端负责。
        // 旧全局活动排序索引必须移除，避免每次房间写入维护无用索引。
        guard let roomActivityContract = try await sql.raw("""
            SELECT
                EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = \(bind: schema) AND table_name = 'rooms'
                      AND column_name = 'last_event_at' AND udt_name = 'timestamptz'
                      AND is_nullable = 'NO'
                )
                AND NOT EXISTS (
                    SELECT 1 FROM pg_class AS index_record
                    JOIN pg_namespace AS namespace ON namespace.oid = index_record.relnamespace
                    WHERE namespace.nspname = \(bind: schema)
                      AND index_record.relname = 'rooms_last_event_at_idx'
                      AND index_record.relkind = 'i'
                )
                AND EXISTS (
                    SELECT 1 FROM pg_trigger AS trigger_record
                    JOIN pg_class AS relation ON relation.oid = trigger_record.tgrelid
                    JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
                    WHERE namespace.nspname = \(bind: schema)
                      AND relation.relname = 'rooms'
                      AND trigger_record.tgname = 'rooms_touch_last_event_at'
                      AND trigger_record.tgenabled = 'O'
                      AND NOT trigger_record.tgisinternal
                )
                AND EXISTS (
                    SELECT 1 FROM pg_index AS definition
                    JOIN pg_class AS index_record ON index_record.oid = definition.indexrelid
                    JOIN pg_class AS relation ON relation.oid = definition.indrelid
                    JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
                    WHERE namespace.nspname = \(bind: schema) AND relation.relname = 'messages'
                      AND index_record.relname = 'messages_latest_visible_idx'
                      AND definition.indisvalid AND definition.indisready
                      AND pg_get_indexdef(definition.indexrelid) LIKE '%USING btree (room_id, room_sequence DESC, message_id DESC) WHERE (withdrawn_at IS NULL)'
                )
                AND EXISTS (
                    SELECT 1 FROM pg_index AS definition
                    JOIN pg_class AS index_record ON index_record.oid = definition.indexrelid
                    JOIN pg_class AS relation ON relation.oid = definition.indrelid
                    JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
                    WHERE namespace.nspname = \(bind: schema) AND relation.relname = 'messages'
                      AND index_record.relname = 'messages_room_log_candidates_idx'
                      AND definition.indisvalid AND definition.indisready
                      AND pg_get_indexdef(definition.indexrelid) LIKE '%USING btree (room_id, timeline_sequence) WHERE (accepted_event_storage = ''message_row''::text)'
                )
                AND EXISTS (
                    SELECT 1 FROM pg_index AS definition
                    JOIN pg_class AS index_record ON index_record.oid = definition.indexrelid
                    JOIN pg_class AS relation ON relation.oid = definition.indrelid
                    JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
                    WHERE namespace.nspname = \(bind: schema) AND relation.relname = 'messages'
                      AND index_record.relname = 'messages_visible_membership_idx'
                      AND definition.indisvalid AND definition.indisready
                      AND pg_get_indexdef(definition.indexrelid) LIKE '%USING btree (room_id, accepted_membership_revision, room_sequence DESC) WHERE ((accepted_event_storage = ''message_row''::text) AND (withdrawn_at IS NULL))'
                )
                AND EXISTS (
                    SELECT 1 FROM pg_index AS definition
                    JOIN pg_class AS index_record ON index_record.oid = definition.indexrelid
                    JOIN pg_class AS relation ON relation.oid = definition.indrelid
                    JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
                    WHERE namespace.nspname = \(bind: schema) AND relation.relname = 'room_events'
                      AND index_record.relname = 'room_events_accepted_membership_idx'
                      AND definition.indisvalid AND definition.indisready
                      AND pg_get_indexdef(definition.indexrelid) LIKE '%USING btree (room_id, committed_membership_revision, room_sequence DESC) WHERE (event_type = ''message.accepted''::text)'
                )
                AND EXISTS (
                    SELECT 1 FROM pg_class AS index_record
                    JOIN pg_namespace AS namespace ON namespace.oid = index_record.relnamespace
                    WHERE namespace.nspname = \(bind: schema)
                      AND index_record.relname = 'messages_room_sender_sequence_idx'
                      AND index_record.relkind = 'i'
                )
                -- 公共内容统一从房间日志恢复，当前结构不再提供旧投递选择列。
                AND NOT EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = \(bind: schema) AND table_name IN ('rooms', 'message_send_completions')
                      AND column_name = 'delivery_authority'
                )
                AND NOT EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = \(bind: schema)
                      AND table_name IN ('room_admission', 'shard_admission_pools')
                      AND column_name IN ('fanout_window_limit', 'fanout_window_used', 'max_outstanding_fanout_units', 'outstanding_fanout_units', 'max_outstanding_plans', 'outstanding_plans')
                )
                -- 保留裁剪的下界也必须存在：缺了它，客户端无法判断历史是否被裁剪过，
                -- 也就无法避免"静默少几条"。
                AND EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = \(bind: schema) AND table_name = 'rooms'
                      AND column_name = 'log_trimmed_through_room_sequence' AND udt_name = 'int8'
                      AND is_nullable = 'NO'
                ) AS exists
            """).first(decoding: ExistsRow.self), roomActivityContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).rooms[activity-contract]")
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
             AND encode(sha256(convert_to(replace(p.prosrc,\(bind: schema + "."),'im_v2.'), 'UTF8')), 'hex') = '78d6c9ce33c4fd0d518390cfdf76215068648c55f1510e32aab9a941ba43ea15'
            )) AS exists
            """).first(decoding: ExistsRow.self), directoryContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).group_invite_directory[intent-binding]")
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
        guard let joinQuotaContract = try await sql.raw("""
            SELECT ((SELECT count(*) = 19 FROM information_schema.columns
             WHERE table_schema = \(bind: schema) AND table_name = 'group_join_quota_intents'
             AND (column_name,udt_name,is_nullable,COALESCE(column_default,'')) IN (('applicant_user_id','uuid','NO',''),
            ('operation_id','uuid','NO',''),
            ('request_id','uuid','NO',''),
            ('room_id','uuid','NO',''),
            ('invite_id','uuid','NO',''),
            ('token_digest','bytea','NO',''),
            ('note','text','YES',''),
            ('maximum_pending_per_invite','int8','NO',''),
            ('generation','int8','NO',''),
            ('phase','text','NO',''),
            ('outcome','text','YES',''),
            ('target_request_id','uuid','YES',''),
            ('created_at','timestamptz','NO',''),
            ('attempt_created_at','timestamptz','NO',''),
            ('updated_at','timestamptz','NO',''),
            ('next_check_at','timestamptz','NO',''),
            ('lease_token','uuid','YES',''),
            ('lease_until','timestamptz','YES',''),
            ('attempt_count','int8','NO','0')))
             AND (SELECT count(*) = 14 FROM pg_constraint WHERE conrelid = to_regclass('\(unsafeRaw: schema).group_join_quota_intents') AND convalidated AND NOT condeferrable
             AND (conname,pg_get_constraintdef(oid)) IN (('group_join_quota_intents_attempt_count_check','CHECK ((attempt_count >= 0))'),
            ('group_join_quota_intents_attempt_created_at_check','CHECK (isfinite(attempt_created_at))'),
            ('group_join_quota_intents_created_at_check','CHECK (isfinite(created_at))'),
            ('group_join_quota_intents_generation_check','CHECK ((generation > 0))'),
            ('group_join_quota_intents_maximum_pending_per_invite_check','CHECK ((maximum_pending_per_invite > 0))'),
            ('group_join_quota_intents_next_check_at_check','CHECK (isfinite(next_check_at))'),
            ('group_join_quota_intents_note_check','CHECK (((note IS NULL) OR ((octet_length(note) >= 1) AND (octet_length(note) <= 500))))'),
            ('group_join_quota_intents_phase_check','CHECK ((phase = ANY (ARRAY[''held''::text, ''tracking''::text, ''denied''::text, ''terminal''::text])))'),
            ('group_join_quota_intents_pkey','PRIMARY KEY (applicant_user_id, operation_id)'),
            ('group_join_quota_intents_request_id_key','UNIQUE (request_id)'),
            ('group_join_quota_intents_token_digest_check','CHECK ((octet_length(token_digest) = 32))'),
            ('group_join_quota_intents_updated_at_check','CHECK (isfinite(updated_at))'),
            ('group_join_quota_lease_check','CHECK ((((lease_token IS NULL) AND (lease_until IS NULL)) OR ((lease_token IS NOT NULL) AND (lease_until IS NOT NULL) AND isfinite(lease_until) AND (phase = ANY (ARRAY[''held''::text, ''tracking''::text])))))'),
            ('group_join_quota_outcome_check','CHECK ((((phase = ''held''::text) AND (outcome IS NULL) AND (target_request_id IS NULL)) OR ((phase = ''tracking''::text) AND (outcome IS NOT NULL) AND (outcome = ''pending''::text) AND (target_request_id IS NOT NULL)) OR ((phase = ''denied''::text) AND (outcome IS NOT NULL) AND (outcome = ANY (ARRAY[''unavailable''::text, ''rate_limited''::text, ''permission_denied''::text])) AND (target_request_id IS NULL)) OR ((phase = ''terminal''::text) AND (outcome IS NOT NULL) AND (((outcome = ANY (ARRAY[''approved''::text, ''rejected''::text, ''cancelled''::text])) AND (target_request_id IS NOT NULL)) OR ((outcome = ''already_member''::text) AND (target_request_id IS NULL))))))')))
             AND (SELECT count(*) = 5 FROM pg_index WHERE indrelid = to_regclass('\(unsafeRaw: schema).group_join_quota_intents') AND indisvalid AND indisready
             AND pg_get_indexdef(indexrelid) IN ('CREATE UNIQUE INDEX group_join_quota_intents_pkey ON \(unsafeRaw: schema).group_join_quota_intents USING btree (applicant_user_id, operation_id)',
            'CREATE UNIQUE INDEX group_join_quota_intents_request_id_key ON \(unsafeRaw: schema).group_join_quota_intents USING btree (request_id)',
            'CREATE UNIQUE INDEX group_join_quota_active_invite_idx ON \(unsafeRaw: schema).group_join_quota_intents USING btree (applicant_user_id, invite_id) WHERE (phase = ANY (ARRAY[''held''::text, ''tracking''::text]))',
            'CREATE INDEX group_join_quota_recovery_idx ON \(unsafeRaw: schema).group_join_quota_intents USING btree (next_check_at, applicant_user_id, operation_id) WHERE (phase = ANY (ARRAY[''held''::text, ''tracking''::text]))',
            'CREATE INDEX group_join_quota_terminal_invite_idx ON \(unsafeRaw: schema).group_join_quota_intents USING btree (applicant_user_id, invite_id, created_at DESC) WHERE ((phase = ''terminal''::text) AND (outcome = ANY (ARRAY[''approved''::text, ''rejected''::text])))'))) AS exists
            """).first(decoding: ExistsRow.self), joinQuotaContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).group_join_quota_intents[reservation-contract]")
        }
        guard let joinReceiptContract = try await sql.raw("""
            SELECT ((SELECT count(*) = 14 FROM information_schema.columns
             WHERE table_schema = \(bind: schema) AND table_name = 'group_join_submission_receipts'
             AND (column_name,udt_name,is_nullable,COALESCE(column_default,'')) IN (('applicant_user_id','uuid','NO',''),
            ('operation_id','uuid','NO',''),
            ('generation','int8','NO',''),
            ('request_id','uuid','NO',''),
            ('room_id','uuid','NO',''),
            ('invite_id','uuid','NO',''),
            ('token_digest','bytea','NO',''),
            ('note','text','YES',''),
            ('maximum_pending_per_invite','int8','NO',''),
            ('intent_created_at','timestamptz','NO',''),
            ('attempt_created_at','timestamptz','NO',''),
            ('disposition','text','NO',''),
            ('target_request_id','uuid','YES',''),
            ('recorded_at','timestamptz','NO','')))
             AND (SELECT count(*) = 11 FROM pg_constraint WHERE conrelid = to_regclass('\(unsafeRaw: schema).group_join_submission_receipts') AND convalidated AND NOT condeferrable
             AND (conname,pg_get_constraintdef(oid)) IN (('group_join_receipt_room_fkey','FOREIGN KEY (room_id) REFERENCES \(unsafeRaw: schema).rooms(room_id)'),
            ('group_join_receipt_target_fkey','FOREIGN KEY (target_request_id) REFERENCES \(unsafeRaw: schema).group_join_requests(request_id)'),
            ('group_join_submission_receipt_result_check','CHECK ((((disposition = ''request''::text) AND (target_request_id IS NOT NULL)) OR ((disposition = ANY (ARRAY[''already_member''::text, ''unavailable''::text, ''rate_limited''::text, ''permission_denied''::text])) AND (target_request_id IS NULL))))'),
            ('group_join_submission_receipts_attempt_created_at_check','CHECK (isfinite(attempt_created_at))'),
            ('group_join_submission_receipts_generation_check','CHECK ((generation > 0))'),
            ('group_join_submission_receipts_intent_created_at_check','CHECK (isfinite(intent_created_at))'),
            ('group_join_submission_receipts_maximum_pending_per_invite_check','CHECK ((maximum_pending_per_invite > 0))'),
            ('group_join_submission_receipts_note_check','CHECK (((note IS NULL) OR ((octet_length(note) >= 1) AND (octet_length(note) <= 500))))'),
            ('group_join_submission_receipts_pkey','PRIMARY KEY (applicant_user_id, operation_id, generation)'),
            ('group_join_submission_receipts_recorded_at_check','CHECK (isfinite(recorded_at))'),
            ('group_join_submission_receipts_token_digest_check','CHECK ((octet_length(token_digest) = 32))')))
             AND (SELECT count(*) = 1 FROM pg_index WHERE indrelid = to_regclass('\(unsafeRaw: schema).group_join_submission_receipts') AND indisvalid AND indisready
             AND pg_get_indexdef(indexrelid) IN ('CREATE UNIQUE INDEX group_join_submission_receipts_pkey ON \(unsafeRaw: schema).group_join_submission_receipts USING btree (applicant_user_id, operation_id, generation)'))) AS exists
            """).first(decoding: ExistsRow.self), joinReceiptContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).group_join_submission_receipts[admission-receipt]")
        }
        guard let joinAliasContract = try await sql.raw("""
            SELECT ((SELECT count(*) = 8 FROM information_schema.columns
             WHERE table_schema = \(bind: schema) AND table_name = 'group_join_quota_aliases'
             AND (column_name,udt_name,is_nullable,COALESCE(column_default,'')) IN (('applicant_user_id','uuid','NO',''),
            ('operation_id','uuid','NO',''),
            ('canonical_operation_id','uuid','NO',''),
            ('room_id','uuid','NO',''),
            ('invite_id','uuid','NO',''),
            ('token_digest','bytea','NO',''),
            ('note','text','YES',''),
            ('created_at','timestamptz','NO','')))
             AND (SELECT count(*) = 6 FROM pg_constraint WHERE conrelid = to_regclass('\(unsafeRaw: schema).group_join_quota_aliases') AND convalidated AND NOT condeferrable
             AND (conname,pg_get_constraintdef(oid)) IN (('group_join_quota_aliases_applicant_user_id_canonical_opera_fkey','FOREIGN KEY (applicant_user_id, canonical_operation_id) REFERENCES \(unsafeRaw: schema).group_join_quota_intents(applicant_user_id, operation_id)'),
            ('group_join_quota_aliases_check','CHECK ((operation_id <> canonical_operation_id))'),
            ('group_join_quota_aliases_created_at_check','CHECK (isfinite(created_at))'),
            ('group_join_quota_aliases_note_check','CHECK (((note IS NULL) OR ((octet_length(note) >= 1) AND (octet_length(note) <= 500))))'),
            ('group_join_quota_aliases_pkey','PRIMARY KEY (applicant_user_id, operation_id)'),
            ('group_join_quota_aliases_token_digest_check','CHECK ((octet_length(token_digest) = 32))')))
             AND (SELECT count(*) = 1 FROM pg_index WHERE indrelid = to_regclass('\(unsafeRaw: schema).group_join_quota_aliases') AND indisvalid AND indisready
             AND pg_get_indexdef(indexrelid) IN ('CREATE UNIQUE INDEX group_join_quota_aliases_pkey ON \(unsafeRaw: schema).group_join_quota_aliases USING btree (applicant_user_id, operation_id)'))) AS exists
            """).first(decoding: ExistsRow.self), joinAliasContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).group_join_quota_aliases[operation-binding]")
        }
        guard let joinCancellationContract = try await sql.raw("""
            SELECT EXISTS (SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_am a ON a.oid = c.relam
             WHERE i.indrelid = to_regclass(\(bind: "\(schema).group_join_requests"))
             AND i.indexrelid = to_regclass(\(bind: "\(schema).group_join_requests_applicant_history_idx"))
             AND i.indisvalid AND i.indisready AND i.indnkeyatts = 5 AND a.amname = 'btree' AND i.indpred IS NULL
             AND pg_get_indexdef(i.indexrelid, 1, false) = 'invite_id'
             AND pg_get_indexdef(i.indexrelid, 2, false) = 'applicant_user_id'
             AND pg_get_indexdef(i.indexrelid, 3, false) = '((state <> ''cancelled''::text))'
             AND pg_get_indexdef(i.indexrelid, 4, false) = 'created_at'
             AND pg_get_indexdef(i.indexrelid, 5, false) = 'request_id'
             AND i.indoption::text = '0 0 3 3 3') AND ((SELECT count(*) = 2 FROM pg_constraint
             WHERE conrelid = to_regclass(\(bind: "\(schema).group_join_requests")) AND convalidated AND NOT condeferrable
             AND (conname, pg_get_constraintdef(oid)) IN (('group_join_requests_decision_check', 'CHECK ((((state = ''cancelled''::text) AND (decision_operation_id IS NULL) AND (decided_by_user_id = applicant_user_id) AND (decided_by_user_id IS NOT NULL) AND (approval_membership_revision IS NULL) AND (decided_at IS NOT NULL)) OR ((state = ''pending''::text) AND (decision_operation_id IS NULL) AND (decided_by_user_id IS NULL) AND (approval_membership_revision IS NULL) AND (decided_at IS NULL)) OR ((state = ''approved''::text) AND (decision_operation_id IS NOT NULL) AND (decided_by_user_id IS NOT NULL) AND (approval_membership_revision IS NOT NULL) AND (decided_at IS NOT NULL)) OR ((state = ''rejected''::text) AND (decision_operation_id IS NOT NULL) AND (decided_by_user_id IS NOT NULL) AND (approval_membership_revision IS NULL) AND (decided_at IS NOT NULL))))'),
            ('group_join_requests_state_check', 'CHECK ((state = ANY (ARRAY[''pending''::text, ''approved''::text, ''rejected''::text, ''cancelled''::text])))')))
             AND EXISTS (SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_am a ON a.oid = c.relam
             WHERE i.indrelid = to_regclass(\(bind: "\(schema).group_join_requests"))
             AND i.indexrelid = to_regclass(\(bind: "\(schema).group_join_requests_invite_id_applicant_user_id_key"))
             AND i.indisvalid AND i.indisready AND i.indisunique AND i.indnkeyatts = 2 AND a.amname = 'btree'
             AND pg_get_indexdef(i.indexrelid, 1, false) = 'invite_id'
             AND pg_get_indexdef(i.indexrelid, 2, false) = 'applicant_user_id'
             AND pg_get_expr(i.indpred, i.indrelid) = '(state <> ''cancelled''::text)')) AS exists
            """).first(decoding: ExistsRow.self), joinCancellationContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).group_join_requests[cancellation]")
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
             AND encode(sha256(convert_to(replace(p.prosrc,\(bind: schema + "."),'im_v2.'), 'UTF8')), 'hex') = '7e371b5f666d2e9d466345a5efd112e9d214149a739e287246232638c29e5cb6'
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
             AND pg_get_constraintdef(c.oid) = format('FOREIGN KEY (export_id) REFERENCES %s(export_id) ON DELETE RESTRICT', to_regclass(\(bind: schema + ".message_forward_exports")))
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
                  AND pg_get_constraintdef(c.oid) = format('FOREIGN KEY (export_id) REFERENCES %s(export_id) ON DELETE RESTRICT', to_regclass(\(bind: schema + ".message_forward_exports")))
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
                SELECT count(*) = 18 AND count(*) FILTER (WHERE is_nullable = 'NO') = 11
                  AND count(*) FILTER (WHERE column_name IN ('payload', 'payload_compacted_at') AND is_nullable = 'YES') = 2
                FROM information_schema.columns WHERE table_schema = \(bind: schema) AND table_name = 'message_forward_inbox'
                  AND (column_name, udt_name) IN (
                    ('export_id','uuid'), ('actor_user_id','uuid'), ('operation_id','uuid'), ('source_message_id','uuid'),
                    ('target_room_id','uuid'), ('target_client_message_id','uuid'), ('target_shard_id','text'), ('target_epoch','int8'), ('payload','bytea'), ('payload_digest','bytea'),
                    ('state','text'), ('result_message_id','uuid'), ('result_room_sequence','int8'), ('error_code','text'),
                    ('created_at','timestamptz'), ('accepted_at','timestamptz'), ('completed_at','timestamptz'), ('payload_compacted_at','timestamptz')
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
                SELECT count(*) = 4 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
                WHERE n.nspname = \(bind: schema) AND c.convalidated AND c.contype = 'c'
                  AND (r.relname, c.conname) IN (('message_forward_inbox','message_forward_inbox_outcome_check'), ('message_forward_inbox','message_forward_inbox_owner_check'), ('message_forward_inbox','message_forward_inbox_compaction_check'), ('message_forward_inbox_media','message_forward_inbox_media_ready_check'))
            ) AND (
                SELECT count(*) = 4 FROM pg_indexes WHERE schemaname = \(bind: schema) AND (
                    (indexname = 'message_forward_inbox_pair_key' AND indexdef LIKE 'CREATE UNIQUE INDEX %USING btree (actor_user_id, operation_id, source_message_id, target_room_id)')
                    OR (indexname = 'message_forward_inbox_client_key' AND indexdef LIKE 'CREATE UNIQUE INDEX %USING btree (actor_user_id, target_client_message_id)')
                    OR (indexname = 'message_forward_inbox_media_target_media_id_key' AND indexdef LIKE 'CREATE UNIQUE INDEX %USING btree (target_media_id)')
                    OR (indexname = 'message_forward_inbox_compaction_idx' AND indexdef LIKE '%USING btree (completed_at, export_id) WHERE%payload IS NOT NULL%')
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
                    SELECT count(*) = 18 AND count(*) FILTER (WHERE is_nullable = 'NO') = 15
                    AND count(*) FILTER (WHERE column_name IN ('payload', 'delivery_completed_at', 'payload_compacted_at') AND is_nullable = 'YES') = 3
                    FROM information_schema.columns
                    WHERE table_schema = \(bind: schema) AND table_name = 'message_forward_exports'
                      AND (column_name, udt_name) IN (
                        ('export_id', 'uuid'), ('actor_user_id', 'uuid'), ('operation_id', 'uuid'),
                        ('source_room_id', 'uuid'), ('source_message_id', 'uuid'), ('source_content_revision', 'int8'),
                        ('source_shard_id', 'text'), ('source_epoch', 'int8'), ('target_room_id', 'uuid'),
                        ('target_client_message_id', 'uuid'), ('target_shard_id', 'text'), ('target_epoch', 'int8'),
                        ('payload', 'bytea'), ('payload_digest', 'bytea'), ('media_ids', '_uuid'), ('created_at', 'timestamptz'),
                        ('delivery_completed_at', 'timestamptz'), ('payload_compacted_at', 'timestamptz')
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
                    SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
                    WHERE n.nspname = \(bind: schema) AND r.relname = 'message_forward_exports'
                      AND c.conname = 'message_forward_exports_compaction_check' AND c.convalidated AND c.contype = 'c'
                ) AND EXISTS (
                    SELECT 1 FROM pg_indexes WHERE schemaname = \(bind: schema) AND indexname = 'message_forward_exports_compaction_idx'
                      AND indexdef LIKE '%USING btree (delivery_completed_at, export_id) WHERE%payload IS NOT NULL%'
                ) AND EXISTS (
                    SELECT 1 FROM pg_trigger t JOIN pg_class r ON r.oid = t.tgrelid JOIN pg_namespace n ON n.oid = r.relnamespace
                    WHERE n.nspname = \(bind: schema) AND r.relname = 'message_forward_delivery_jobs'
                      AND t.tgname = 'message_forward_delivery_compaction_ready' AND t.tgenabled = 'O'
                      AND t.tgtype = 21 AND NOT t.tgisinternal
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
                SELECT count(*) = 1
                FROM pg_constraint AS constraint_record
                JOIN pg_class AS relation ON relation.oid = constraint_record.conrelid
                JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
                WHERE namespace.nspname = \(bind: schema)
                  AND (relation.relname, constraint_record.conname) IN (
                      ('message_send_completions', 'message_send_completions_fingerprint_version_check')
                  )
                  AND constraint_record.convalidated
                  AND pg_get_expr(constraint_record.conbin, constraint_record.conrelid)
                      = '(fingerprint_version = 3)'
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
                AS exists
            """).first(decoding: ExistsRow.self), groupInvitationContract.exists else {
            throw V2SchemaReadinessError.unavailableTable(
                "\(schema).group_invite_links[approval-contract]"
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
        // 普通私聊房间追加可能将 `messages` 作为持久化事件源。
        // 必须验证当前序号不变量，使不完整 schema 在启动时失败，
        // 而不是悄然遗漏房间事件。
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
                -- Only the current sequence invariant and cursor index are valid.
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
                ) AS exists
            FROM information_schema.columns
            WHERE table_schema = \(bind: schema)
              AND table_name = 'messages'
            """).first(decoding: ExistsRow.self), directMessageEventSourceContract.exists else {
            throw V2SchemaReadinessError.unavailableTable(
                "\(schema).messages[direct-event-source]"
            )
        }
        guard let syncProjectionTriggerContract = try await sql.raw("""
            SELECT COUNT(*) = 3
                AND COUNT(*) FILTER (
                    WHERE trigger_record.tgname IN (
                        'user_sync_log_projection_effect_v4',
                        'user_sync_log_snapshot_v7_projection',
                        'user_sync_log_enqueue_wake'
                    )
                ) = 3 AS exists
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
        guard let realtimeContract = try await sql.raw("""
            SELECT NOT EXISTS (
            SELECT 1 FROM (VALUES
            ('realtime_partition_leases','partition_id','int4'),
            ('realtime_partition_leases','lease_epoch','int8'),
            ('realtime_partition_leases','expires_at','timestamptz'),
            ('realtime_partition_leases','updated_at','timestamptz'),
            ('user_sync_wake_outbox','user_id','uuid'),
            ('user_sync_wake_outbox','target_user_sequence','int8'),
            ('user_sync_wake_outbox','revision','int8'),
            ('user_sync_wake_outbox','state','text'),
            ('user_sync_wake_outbox','attempt_count','int4'),
            ('user_sync_wake_outbox','next_attempt_at','timestamptz'),
            ('user_sync_wake_outbox','updated_at','timestamptz')
            ) expected(table_name,column_name,type_name)
            LEFT JOIN information_schema.columns actual ON actual.table_schema=\(bind: schema)
            AND actual.table_name=expected.table_name AND actual.column_name=expected.column_name
            AND actual.udt_name=expected.type_name AND actual.is_nullable='NO'
            WHERE actual.column_name IS NULL
            ) AND NOT EXISTS (
            SELECT 1 FROM (VALUES
            ('PRIMARY KEY (partition_id)'),
            ('CHECK (((partition_id >= 0) AND (partition_id <= 255)))'),
            ('CHECK ((lease_epoch >= 0))'),
            ('CHECK (((octet_length(host_id) >= 1) AND (octet_length(host_id) <= 128)))'),
            ('CHECK (((octet_length(service_id) >= 1) AND (octet_length(service_id) <= 128)))'),
            ('CHECK (isfinite(expires_at))'),
            ('CHECK (isfinite(updated_at))'),
            ('CHECK ((((lease_epoch = 0) AND (host_id IS NULL) AND (service_id IS NULL) AND (process_incarnation IS NULL) AND (lease_token IS NULL)) OR ((lease_epoch > 0) AND (host_id IS NOT NULL) AND (service_id IS NOT NULL) AND (process_incarnation IS NOT NULL) AND (lease_token IS NOT NULL))))')
            ) expected(definition)
            WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c
                WHERE c.conrelid=to_regclass(\(bind: schema) || '.realtime_partition_leases')
                AND c.convalidated AND NOT c.condeferrable AND pg_get_constraintdef(c.oid)=expected.definition)
            ) AND to_regclass(\(bind: schema) || '.room_event_wake_outbox') IS NULL
            AND to_regclass(\(bind: schema) || '.realtime_gateway_leases') IS NULL
            AND to_regclass(\(bind: schema) || '.realtime_interests') IS NULL
            AND NOT EXISTS (
            SELECT 1 FROM (VALUES
            ('host_id','text'),('service_id','text'),('process_incarnation','uuid'),('lease_token','uuid')
            ) expected(column_name,type_name)
            LEFT JOIN information_schema.columns actual ON actual.table_schema=\(bind: schema)
            AND actual.table_name='realtime_partition_leases' AND actual.column_name=expected.column_name
            AND actual.udt_name=expected.type_name AND actual.is_nullable='YES'
            WHERE actual.column_name IS NULL
            ) AND NOT EXISTS (
            SELECT 1 FROM (VALUES
            ('realtime_partition_leases_pkey'),('user_sync_wake_outbox_pkey'),
            ('user_sync_wake_claim_idx'),('user_sync_wake_expired_idx')
            ) expected(index_name)
            WHERE NOT EXISTS (SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid
            JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=\(bind: schema) AND c.relname=expected.index_name
            AND i.indisvalid AND i.indisready)
            ) AND NOT EXISTS (
            SELECT 1 FROM (VALUES
            ('user_sync_log','user_sync_log_enqueue_wake')
            ) expected(table_name,trigger_name)
            WHERE NOT EXISTS (SELECT 1 FROM pg_trigger t
            WHERE t.tgrelid=to_regclass(\(bind: schema) || '.' || expected.table_name)
            AND t.tgname=expected.trigger_name AND t.tgtype=4
            AND ((expected.table_name='user_sync_log' AND t.tgenabled='O')
              OR (expected.table_name<>'user_sync_log' AND t.tgenabled IN('O','A','D')))
            AND NOT t.tgisinternal)
            ) AND NOT EXISTS (
            SELECT 1 FROM (VALUES
            ('enqueue_user_sync_wake','17acd1000a304365fc0d2429df8f6484eaa5d40853c378145748a16d66c1e4ec')
            ) expected(function_name,body_digest)
            WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
            WHERE n.nspname=\(bind: schema) AND p.proname=expected.function_name
            AND encode(sha256(convert_to(replace(p.prosrc,\(bind: schema) || '.', 'im_v2.'),'UTF8')),'hex')=expected.body_digest)
            ) AS exists
            """).first(decoding: ExistsRow.self), realtimeContract.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).realtime-routing[contract]")
        }
        guard let partitionSeed = try await sql.raw("""
            SELECT count(*) = 256 AND min(partition_id) = 0 AND max(partition_id) = 255 AS exists
            FROM \(unsafeRaw: schema).realtime_partition_leases
            """).first(decoding: ExistsRow.self), partitionSeed.exists else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).realtime_partition_leases[fixed-seed]")
        }
    }
    static func verifyRoomRecoveryFence(sql: any SQLDatabase, schema: String) async throws {
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw V2SchemaReadinessError.unavailableTable(schema)
        }
        guard let fence = try await sql.raw("""
            SELECT EXISTS (
                SELECT 1 FROM \(unsafeRaw: schema).room_recovery_topology WHERE singleton = true
            ) AND (
                SELECT count(*) = 2 FROM pg_trigger
                WHERE tgrelid = to_regclass(\(bind: schema + ".room_owner_routes"))
                  AND NOT tgisinternal AND tgenabled IN ('O', 'A')
                  AND tgfoid = to_regprocedure(\(bind: schema + ".invalidate_room_recovery_topology()"))
                  AND (tgname, tgtype::integer) IN (
                      ('room_owner_routes_recovery_fence', 29),
                      ('room_owner_routes_recovery_truncate_fence', 32)
                  )
            ) AS exists
            """).first(decoding: ExistsRow.self), fence.exists else {
            throw V2SchemaReadinessError.unavailableTable(schema + ".room_recovery_topology[fence]")
        }
    }

}

private struct ExistsRow: Decodable { let exists: Bool }
private struct RetiredTableRow: Decodable { let name: String }
private struct SearchPathRow: Decodable { let path: String }

private struct ProfileOperationContractRow: Decodable { let valid: Bool }
