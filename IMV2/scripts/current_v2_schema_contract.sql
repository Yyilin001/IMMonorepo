SELECT ((SELECT count(*) = 4 AND bool_and(is_nullable = 'NO') FROM information_schema.columns
 WHERE table_schema = 'im_v2' AND table_name = 'legacy_device_registration_cancellations'
 AND (column_name, udt_name) IN (('user_id','uuid'),('device_id','uuid'),('operation_id','uuid'),('cancelled_at','timestamptz')))
 AND (SELECT count(*) = 3 FROM pg_constraint WHERE conrelid=to_regclass('im_v2.legacy_device_registration_cancellations')
 AND convalidated AND NOT condeferrable AND (conname,pg_get_constraintdef(oid)) IN (
 ('legacy_registration_cancellation_pkey','PRIMARY KEY (user_id, device_id)'),
 ('legacy_registration_cancellation_operation','UNIQUE (user_id, operation_id)'),
 ('legacy_registration_cancellation_time','CHECK (isfinite(cancelled_at))')))
 AND (SELECT count(*) = 2 FROM pg_index WHERE indrelid=to_regclass('im_v2.legacy_device_registration_cancellations') AND indisvalid AND indisready AND indisunique)) AND ((SELECT count(*) = 9 AND bool_and(is_nullable = CASE WHEN column_name IN ('user_id','session_created_at','session_expires_at','cancelled_at') THEN 'YES' ELSE 'NO' END)
 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'device_registration_cancellations'
 AND (column_name, udt_name) IN (('request_digest','text'),('device_id','uuid'),('operation_id','uuid'),('issue_before','timestamptz'),('created_at','timestamptz'),('cancelled_at','timestamptz'),('user_id','uuid'),('session_created_at','timestamptz'),('session_expires_at','timestamptz')))
 AND (SELECT count(*) = 5 FROM pg_constraint WHERE conrelid=to_regclass('im_v2.device_registration_cancellations')
 AND convalidated AND NOT condeferrable AND (conname,pg_get_constraintdef(oid)) IN (
('device_registration_cancellations_pkey','PRIMARY KEY (request_digest)'),
('registration_cancellation_binding','CHECK ((((user_id IS NULL) AND (session_created_at IS NULL) AND (session_expires_at IS NULL) AND (cancelled_at IS NOT NULL)) OR ((user_id IS NOT NULL) AND (session_created_at IS NOT NULL) AND (session_expires_at IS NOT NULL) AND isfinite(session_created_at) AND isfinite(session_expires_at) AND (session_expires_at > session_created_at))))'),
('registration_cancellation_device','FOREIGN KEY (user_id, device_id) REFERENCES im_v2.auth_devices(user_id, device_id) ON DELETE RESTRICT'),
('registration_cancellation_digest','CHECK ((request_digest ~ ''^[0-9a-f]{64}$''::text))'),
('registration_cancellation_times','CHECK ((isfinite(created_at) AND isfinite(issue_before) AND (issue_before > created_at) AND (issue_before <= (created_at + ''1 day''::interval)) AND ((cancelled_at IS NULL) OR isfinite(cancelled_at))))')))
 AND EXISTS (SELECT 1 FROM pg_index WHERE indrelid=to_regclass('im_v2.device_registration_cancellations')
 AND indisvalid AND indisready AND indisunique AND indnkeyatts=1
 AND pg_get_indexdef(indexrelid,1,false)='device_id' AND pg_get_expr(indpred,indrelid)='(user_id IS NOT NULL)')) AND (((
 SELECT count(*) = 18 AND bool_and(is_nullable = CASE WHEN column_name IN ('after_invite_id','next_cursor') THEN 'YES' ELSE 'NO' END)
 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'group_invite_directory_import_audit'
 AND (column_name, udt_name) IN (('operation_id','uuid'), ('operator_principal','text'), ('shard_id','text'), ('owner_epoch','int8'), ('room_id','uuid'), ('after_invite_id','uuid'), ('page_size','int8'), ('reason_code','text'), ('requested_at','timestamptz'), ('outcome','text'), ('source_snapshot','jsonb'), ('source_digest','bytea'), ('source_count','int8'), ('inserted_count','int8'), ('published_count','int8'), ('unchanged_count','int8'), ('next_cursor','uuid'), ('conflicting_invite_ids','_uuid'))
) AND EXISTS (
 SELECT 1 FROM pg_constraint c JOIN pg_index i ON i.indexrelid = c.conindid
 WHERE c.conrelid = to_regclass('im_v2.group_invite_directory_import_audit') AND c.contype = 'p'
 AND c.convalidated AND NOT c.condeferrable AND i.indisvalid AND i.indisready AND i.indisunique
 AND pg_get_constraintdef(c.oid) = 'PRIMARY KEY (operation_id)'
) AND NOT EXISTS (
 SELECT 1 FROM pg_constraint c WHERE c.conrelid = to_regclass('im_v2.group_invite_directory_import_audit') AND c.contype = 'f'
) AND (
 SELECT count(*) = 10 FROM pg_constraint c WHERE c.conrelid = to_regclass('im_v2.group_invite_directory_import_audit')
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
 WHERE t.tgrelid = to_regclass('im_v2.group_invite_directory_import_audit') AND t.tgname = 'group_invite_import_audit_immutable'
 AND t.tgtype = 27 AND t.tgenabled = 'O' AND NOT t.tgisinternal
 AND n.nspname = 'im_v2' AND p.proname = 'reject_group_invite_import_audit_mutation'
 AND l.lanname = 'plpgsql' AND NOT p.prosecdef AND p.prorettype = 'trigger'::regtype
 AND encode(sha256(convert_to(p.prosrc, 'UTF8')), 'hex') = '6d5f50ca927c7f256ffa8b1ababb3a2dc8940dd172e67df5f6a97ebc6bc36282'
) AND EXISTS (
 SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_am a ON a.oid = c.relam
 WHERE i.indrelid = to_regclass('im_v2.group_invite_links') AND c.relname = 'group_invite_links_import_page_idx'
 AND i.indisvalid AND i.indisready AND i.indnkeyatts = 2 AND i.indnatts = 2 AND a.amname = 'btree' AND i.indpred IS NULL
 AND pg_get_indexdef(i.indexrelid, 1, false) = 'room_id' AND pg_get_indexdef(i.indexrelid, 2, false) = 'invite_id'
)) AND ((
 SELECT count(*) = 10 AND bool_and(is_nullable = CASE WHEN column_name IN ('claim_token','lease_expires_at','last_error_code','completed_at') THEN 'YES' ELSE 'NO' END)
 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'group_invite_creation_recovery'
 AND (column_name, udt_name) IN (('actor_user_id','uuid'), ('operation_id','uuid'), ('state','text'), ('attempt_count','int8'), ('next_attempt_at','timestamptz'), ('claim_token','uuid'), ('lease_expires_at','timestamptz'), ('last_error_code','text'), ('updated_at','timestamptz'), ('completed_at','timestamptz'))
) AND EXISTS (
 SELECT 1 FROM pg_constraint c JOIN pg_index i ON i.indexrelid = c.conindid
 WHERE c.conrelid = to_regclass('im_v2.group_invite_creation_recovery') AND c.contype = 'p'
 AND c.convalidated AND NOT c.condeferrable AND i.indisvalid AND i.indisready AND i.indisunique
 AND pg_get_constraintdef(c.oid) = 'PRIMARY KEY (actor_user_id, operation_id)'
) AND EXISTS (
 SELECT 1 FROM pg_constraint c WHERE c.conrelid = to_regclass('im_v2.group_invite_creation_recovery')
 AND c.contype = 'f' AND c.convalidated AND NOT c.condeferrable
 AND c.confrelid = to_regclass('im_v2.group_invite_directory') AND c.confdeltype = 'r'
 AND cardinality(c.conkey) = 2 AND cardinality(c.confkey) = 2
 AND c.conkey[1] = (SELECT attnum FROM pg_attribute WHERE attrelid = c.conrelid AND attname = 'actor_user_id')
 AND c.conkey[2] = (SELECT attnum FROM pg_attribute WHERE attrelid = c.conrelid AND attname = 'operation_id')
 AND c.confkey[1] = (SELECT attnum FROM pg_attribute WHERE attrelid = c.confrelid AND attname = 'actor_user_id')
 AND c.confkey[2] = (SELECT attnum FROM pg_attribute WHERE attrelid = c.confrelid AND attname = 'operation_id')
) AND (
 SELECT count(*) = 7 FROM pg_constraint c WHERE c.conrelid = to_regclass('im_v2.group_invite_creation_recovery')
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
 WHERE i.indrelid = to_regclass('im_v2.group_invite_creation_recovery') AND i.indisvalid AND i.indisready AND i.indnkeyatts = 3 AND a.amname = 'btree'
 AND pg_get_indexdef(i.indexrelid, 2, false) = 'actor_user_id' AND pg_get_indexdef(i.indexrelid, 3, false) = 'operation_id'
 AND ((c.relname = 'group_invite_creation_recovery_pending_idx' AND pg_get_indexdef(i.indexrelid, 1, false) = 'next_attempt_at' AND pg_get_expr(i.indpred, i.indrelid) = '(state = ''pending''::text)')
 OR (c.relname = 'group_invite_creation_recovery_lease_idx' AND pg_get_indexdef(i.indexrelid, 1, false) = 'lease_expires_at' AND pg_get_expr(i.indpred, i.indrelid) = '(state = ''claimed''::text)'))
)) AND (NOT EXISTS (
 SELECT 1 FROM pg_constraint c
 WHERE c.conrelid IN (to_regclass('im_v2.group_invite_links'), to_regclass('im_v2.group_join_requests'))
 AND c.contype = 'f' AND c.confrelid IN (to_regclass('im_v2.public_user_profiles'), to_regclass('im_v2.account_disables'))
) AND (((
 SELECT count(*) = 11 AND bool_and(is_nullable = CASE WHEN column_name = 'ready_at' THEN 'YES' ELSE 'NO' END)
 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'group_invite_directory'
 AND (column_name, udt_name) IN (('actor_user_id','uuid'), ('operation_id','uuid'), ('invite_id','uuid'), ('room_id','uuid'), ('token_digest','bytea'), ('requested_lifetime_seconds','int8'), ('maximum_approved_uses','int8'), ('created_at','timestamptz'), ('expires_at','timestamptz'), ('state','text'), ('ready_at','timestamptz'))
) AND (
 SELECT count(*) = 3 FROM pg_constraint c JOIN pg_index i ON i.indexrelid = c.conindid
 WHERE c.conrelid = to_regclass('im_v2.group_invite_directory') AND c.contype IN ('p','u')
 AND c.convalidated AND NOT c.condeferrable AND i.indisvalid AND i.indisready AND i.indisunique
 AND pg_get_constraintdef(c.oid) IN ('PRIMARY KEY (actor_user_id, operation_id)', 'UNIQUE (token_digest)', 'UNIQUE (invite_id)')
) AND (
 SELECT count(*) = 6 FROM pg_constraint c WHERE c.conrelid = to_regclass('im_v2.group_invite_directory')
 AND c.contype = 'c' AND c.convalidated AND (c.conname, pg_get_constraintdef(c.oid)) IN (
 ('group_invite_directory_digest_check', 'CHECK ((octet_length(token_digest) = 32))'),
 ('group_invite_directory_lifetime_check', 'CHECK ((requested_lifetime_seconds > 0))'),
 ('group_invite_directory_uses_check', 'CHECK ((maximum_approved_uses > 0))'),
 ('group_invite_directory_expiry_check', 'CHECK ((expires_at > created_at))'),
 ('group_invite_directory_state_check', 'CHECK ((state = ANY (ARRAY[''prepared''::text, ''ready''::text])))'),
 ('group_invite_directory_ready_check', 'CHECK (((state = ''ready''::text) = (ready_at IS NOT NULL)))'))
) AND NOT EXISTS (
 SELECT 1 FROM pg_constraint c WHERE c.conrelid = to_regclass('im_v2.group_invite_directory') AND c.contype = 'f'
) AND EXISTS (
 SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
 JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_language l ON l.oid = p.prolang
 WHERE t.tgrelid = to_regclass('im_v2.group_invite_directory') AND t.tgname = 'group_invite_directory_immutable'
 AND t.tgtype = 27 AND t.tgenabled = 'O' AND NOT t.tgisinternal
 AND n.nspname = 'im_v2' AND p.proname = 'reject_group_invite_directory_mutation'
 AND l.lanname = 'plpgsql' AND NOT p.prosecdef AND p.prorettype = 'trigger'::regtype
 AND encode(sha256(convert_to(p.prosrc, 'UTF8')), 'hex') = '78d6c9ce33c4fd0d518390cfdf76215068648c55f1510e32aab9a941ba43ea15'
)) AND (((
 SELECT count(*) = 22 AND count(*) FILTER (WHERE is_nullable = 'NO') = 13
 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'group_join_approval_recovery_audit'
 AND (column_name, udt_name) IN (('operation_id', 'uuid'), ('operator_principal', 'text'), ('shard_id', 'text'), ('owner_epoch', 'int8'), ('room_id', 'uuid'), ('request_id', 'uuid'), ('reviewer_user_id', 'uuid'), ('decision_operation_id', 'uuid'), ('reason_code', 'text'), ('outcome', 'text'), ('detail', 'text'), ('requested_at', 'timestamptz'), ('applicant_user_id', 'uuid'), ('prepared_revision', 'int8'), ('member_room_id', 'uuid'), ('member_target_user_id', 'uuid'), ('member_action', 'text'), ('expected_revision', 'int8'), ('resulting_revision', 'int8'), ('room_sequence', 'int8'), ('event_id', 'uuid'), ('plan_id', 'uuid'))
) AND (
 SELECT count(*) = 6 AND bool_and(is_nullable = 'NO')
 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'room_membership_operation_fences'
 AND (column_name, udt_name) IN (('actor_user_id', 'uuid'), ('operation_id', 'uuid'), ('room_id', 'uuid'), ('request_id', 'uuid'), ('recovery_operation_id', 'uuid'), ('created_at', 'timestamptz'))
) AND (
 SELECT count(*) = 6 FROM pg_constraint c
 WHERE c.conrelid = to_regclass('im_v2.group_join_approval_recovery_audit') AND c.contype = 'c' AND c.convalidated
 AND (c.conname, pg_get_constraintdef(c.oid)) IN (('group_join_approval_recovery_audit_owner_epoch_check', 'CHECK ((owner_epoch >= 0))'), ('group_join_approval_recovery_audit_reason_code_check', 'CHECK ((reason_code = ANY (ARRAY[''dependency_recovered''::text, ''data_repaired''::text, ''false_positive''::text])))'), ('group_join_approval_recovery_audit_outcome_check', 'CHECK ((outcome = ANY (ARRAY[''completed''::text, ''released''::text, ''quarantined''::text, ''not_approving''::text])))'), ('group_join_approval_recovery_audit_detail_check', 'CHECK ((detail = ANY (ARRAY[''committed_operation''::text, ''no_historical_add''::text, ''operation_mismatch''::text, ''historical_add_without_receipt''::text, ''invalid_revision''::text, ''invite_exhausted''::text, ''not_approving''::text])))'), ('group_join_approval_recovery_audit_completed_check', 'CHECK (((outcome <> ''completed''::text) OR (expected_revision IS NOT NULL)))'), ('group_join_approval_recovery_audit_result_check', 'CHECK ((((member_room_id IS NULL) AND (member_target_user_id IS NULL) AND (member_action IS NULL) AND (expected_revision IS NULL) AND (resulting_revision IS NULL) AND (room_sequence IS NULL) AND (event_id IS NULL) AND (plan_id IS NULL)) OR ((member_room_id IS NOT NULL) AND (member_target_user_id IS NOT NULL) AND (member_action IS NOT NULL) AND (expected_revision IS NOT NULL) AND (resulting_revision IS NOT NULL) AND (room_sequence IS NOT NULL) AND (event_id IS NOT NULL) AND (plan_id IS NOT NULL))))'))
) AND (
 SELECT count(*) = 2 FROM pg_constraint c JOIN pg_index i ON i.indexrelid = c.conindid
 WHERE c.contype = 'p' AND c.convalidated AND NOT c.condeferrable AND i.indisvalid AND i.indisready AND i.indisunique
 AND ((c.conrelid = to_regclass('im_v2.group_join_approval_recovery_audit') AND pg_get_constraintdef(c.oid) = 'PRIMARY KEY (operation_id)')
 OR (c.conrelid = to_regclass('im_v2.room_membership_operation_fences') AND pg_get_constraintdef(c.oid) = 'PRIMARY KEY (actor_user_id, operation_id)'))
) AND EXISTS (
 SELECT 1 FROM pg_constraint c WHERE c.conrelid = to_regclass('im_v2.room_membership_operation_fences')
 AND c.contype = 'f' AND c.convalidated AND c.confrelid = to_regclass('im_v2.group_join_approval_recovery_audit')
 AND c.confdeltype = 'r' AND cardinality(c.conkey) = 1 AND cardinality(c.confkey) = 1
 AND c.conkey[1] = (SELECT attnum FROM pg_attribute WHERE attrelid = c.conrelid AND attname = 'recovery_operation_id')
 AND c.confkey[1] = (SELECT attnum FROM pg_attribute WHERE attrelid = c.confrelid AND attname = 'operation_id')
) AND (
 SELECT count(*) = 2 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
 JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_language l ON l.oid = p.prolang
 WHERE t.tgtype = 27 AND t.tgenabled = 'O' AND NOT t.tgisinternal
 AND n.nspname = 'im_v2' AND p.proname = 'reject_approval_recovery_mutation'
 AND l.lanname = 'plpgsql' AND NOT p.prosecdef AND p.prorettype = 'trigger'::regtype
 AND regexp_replace(p.prosrc, '[[:space:]]', '', 'g') = 'BEGINRAISEEXCEPTION''approvalrecoveryevidenceisimmutable'';END;'
 AND ((t.tgrelid = to_regclass('im_v2.group_join_approval_recovery_audit') AND t.tgname = 'group_join_approval_recovery_audit_immutable')
 OR (t.tgrelid = to_regclass('im_v2.room_membership_operation_fences') AND t.tgname = 'room_membership_operation_fences_immutable'))
) AND EXISTS (
 SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_am a ON a.oid = c.relam
 WHERE i.indrelid = to_regclass('im_v2.group_join_requests')
 AND i.indexrelid = to_regclass('im_v2.group_join_requests_approving_recovery_idx')
 AND i.indisvalid AND i.indisready AND i.indnkeyatts = 2 AND a.amname = 'btree'
 AND i.indkey[0] = (SELECT attnum FROM pg_attribute WHERE attrelid = i.indrelid AND attname = 'room_id')
 AND i.indkey[1] = (SELECT attnum FROM pg_attribute WHERE attrelid = i.indrelid AND attname = 'request_id')
 AND pg_get_expr(i.indpred, i.indrelid) = '(state = ''approving''::text)'
)) AND EXISTS (
 SELECT 1 FROM pg_constraint c JOIN pg_index i ON i.indexrelid = c.conindid
 WHERE c.conrelid = to_regclass('im_v2.group_join_requests')
 AND c.contype = 'u' AND c.convalidated AND NOT c.condeferrable
 AND i.indisvalid AND i.indisready AND i.indisunique
 AND pg_get_constraintdef(c.oid) = 'UNIQUE (decided_by_user_id, decision_operation_id)'
) AND ((
 SELECT count(*) = 6 AND count(*) FILTER (WHERE is_nullable = 'NO') = 5
 AND count(*) FILTER (WHERE column_name = 'intent_digest' AND is_nullable = 'YES') = 1
 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'push_device_intents'
 AND (column_name, udt_name) IN (('device_id','uuid'), ('session_epoch','int8'), ('session_claim_id','uuid'), ('intent_revision','int8'), ('intent_digest','bytea'), ('updated_at','timestamptz'))
) AND EXISTS (
 SELECT 1 FROM pg_constraint c WHERE c.conrelid = to_regclass('im_v2.push_device_intents')
 AND c.contype = 'p' AND pg_get_constraintdef(c.oid) = 'PRIMARY KEY (device_id)'
) AND (
 SELECT count(*) = 3 FROM pg_constraint c WHERE c.conrelid = to_regclass('im_v2.push_device_intents')
 AND c.contype = 'c' AND c.convalidated AND (c.conname, pg_get_constraintdef(c.oid)) IN (
 ('push_device_intents_session_epoch_check', 'CHECK ((session_epoch > 0))'),
 ('push_device_intents_intent_revision_check', 'CHECK ((intent_revision >= 0))'),
 ('push_device_intents_digest_check', 'CHECK ((((intent_revision = 0) AND (intent_digest IS NULL)) OR ((intent_revision > 0) AND (intent_digest IS NOT NULL) AND (octet_length(intent_digest) = 32))))'))
) AND EXISTS (
 SELECT 1 FROM pg_constraint c WHERE c.conrelid = to_regclass('im_v2.push_device_intents')
 AND c.contype = 'f' AND c.convalidated AND c.confrelid = to_regclass('im_v2.auth_devices')
 AND c.confdeltype = 'r' AND cardinality(c.conkey) = 1 AND cardinality(c.confkey) = 1
 AND c.conkey[1] = (SELECT attnum FROM pg_attribute WHERE attrelid = c.conrelid AND attname = 'device_id')
 AND c.confkey[1] = (SELECT attnum FROM pg_attribute WHERE attrelid = c.confrelid AND attname = 'device_id')
)) AND ((
 SELECT count(*) = 2 AND count(*) FILTER (WHERE is_nullable = 'NO') = 2
 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'group_role_policies'
 AND (column_name, udt_name) IN (('room_id','uuid'), ('role','text'))
) AND EXISTS (
 SELECT 1 FROM pg_constraint c WHERE c.conrelid = to_regclass('im_v2.group_role_policies')
 AND c.contype = 'p' AND pg_get_constraintdef(c.oid) = 'PRIMARY KEY (room_id, role)'
) AND EXISTS (
 SELECT 1 FROM pg_constraint c WHERE c.conrelid = to_regclass('im_v2.group_role_policies')
 AND c.conname = 'group_role_policies_role_check' AND c.convalidated AND c.contype = 'c'
 AND pg_get_constraintdef(c.oid) = 'CHECK ((role = ANY (ARRAY[''admin''::text, ''member''::text])))'
) AND EXISTS (
 SELECT 1 FROM pg_constraint c WHERE c.conrelid = to_regclass('im_v2.group_role_policies')
 AND c.contype = 'f' AND c.convalidated AND c.confrelid = to_regclass('im_v2.rooms')
 AND c.confdeltype = 'r' AND cardinality(c.conkey) = 1
 AND c.conkey[1] = (SELECT attnum FROM pg_attribute WHERE attrelid = c.conrelid AND attname = 'room_id')
)) AND (((
 SELECT count(*) = 4 AND count(*) FILTER (WHERE is_nullable = 'YES') = 4
 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'media_download_grants'
 AND (column_name, udt_name) IN (('message_room_id','uuid'), ('message_id','uuid'), ('owner_shard_id','text'), ('owner_epoch','int8'))
) AND EXISTS (
 SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
 WHERE n.nspname = 'im_v2' AND r.relname = 'media_download_grants'
 AND c.conname = 'media_download_grants_scope_check' AND c.convalidated AND c.contype = 'c'
 AND pg_get_constraintdef(c.oid) = 'CHECK ((((message_room_id IS NULL) AND (message_id IS NULL) AND (owner_shard_id IS NULL) AND (owner_epoch IS NULL)) OR ((message_room_id IS NOT NULL) AND (message_id IS NOT NULL) AND (owner_shard_id IS NOT NULL) AND (length(btrim(owner_shard_id)) > 0) AND (owner_epoch IS NOT NULL) AND (owner_epoch >= 0))))'
) AND EXISTS (
 SELECT 1 FROM pg_trigger t JOIN pg_class r ON r.oid = t.tgrelid JOIN pg_namespace n ON n.oid = r.relnamespace JOIN pg_proc p ON p.oid = t.tgfoid
 WHERE n.nspname = 'im_v2' AND r.relname = 'media_download_grants'
 AND t.tgname = 'media_download_grants_identity' AND t.tgtype = 19 AND t.tgenabled = 'O' AND NOT t.tgisinternal
 AND encode(sha256(convert_to(p.prosrc, 'UTF8')), 'hex') = '7e371b5f666d2e9d466345a5efd112e9d214149a739e287246232638c29e5cb6'
) AND NOT EXISTS (
 SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
 WHERE n.nspname = 'im_v2' AND r.relname = 'media_download_grants' AND c.contype = 'f'
 AND c.confrelid = to_regclass('im_v2.auth_devices')
)) AND ((
 SELECT count(*) = 9 AND count(*) FILTER (WHERE is_nullable = 'NO') = 8
 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'forward_work_replay_audit'
 AND (column_name, udt_name) IN (('operation_id','uuid'), ('operator_principal','text'), ('shard_id','text'),
 ('target_kind','text'), ('export_id','uuid'), ('ordinal','int4'), ('reason_code','text'), ('requested_at','timestamptz'), ('outcome','text'))
) AND EXISTS (
 SELECT 1 FROM pg_trigger t JOIN pg_class r ON r.oid = t.tgrelid JOIN pg_namespace n ON n.oid = r.relnamespace
 WHERE n.nspname = 'im_v2' AND r.relname = 'forward_work_replay_audit'
 AND t.tgname = 'forward_work_replay_audit_immutable' AND t.tgtype = 27 AND t.tgenabled = 'O' AND NOT t.tgisinternal
 AND t.tgfoid = to_regprocedure('im_v2.reject_forward_replay_audit_mutation()')
) AND EXISTS (
 SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
 WHERE n.nspname = 'im_v2' AND r.relname = 'forward_work_replay_audit'
 AND c.conname = 'forward_work_replay_audit_target_check' AND c.convalidated AND c.contype = 'c'
            AND pg_get_constraintdef(c.oid) = 'CHECK ((((target_kind = ''delivery''::text) AND (ordinal IS NULL)) OR ((target_kind = ''media''::text) AND (ordinal IS NOT NULL) AND ((ordinal >= 0) AND (ordinal <= 9)))))'
) AND EXISTS (
 SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
 WHERE n.nspname = 'im_v2' AND r.relname = 'forward_work_replay_audit'
 AND c.contype = 'p' AND pg_get_constraintdef(c.oid) = 'PRIMARY KEY (operation_id)'
)) AND ((
 SELECT count(*) = 8 AND count(*) FILTER (WHERE is_nullable = 'NO') = 4
 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'message_forward_delivery_jobs'
 AND (column_name, udt_name) IN (('export_id','uuid'), ('state','text'), ('claim_token','uuid'), ('lease_expires_at','timestamptz'),
 ('next_attempt_at','timestamptz'), ('retry_count','int8'), ('created_at','timestamptz'), ('completed_at','timestamptz'))
) AND EXISTS (
 SELECT 1 FROM pg_trigger t JOIN pg_class r ON r.oid = t.tgrelid JOIN pg_namespace n ON n.oid = r.relnamespace
 WHERE n.nspname = 'im_v2' AND r.relname = 'message_forward_delivery_jobs'
 AND t.tgname = 'message_forward_delivery_jobs_immutable' AND t.tgtype = 27 AND t.tgenabled = 'O' AND NOT t.tgisinternal
) AND EXISTS (
 SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
 WHERE n.nspname = 'im_v2' AND r.relname = 'message_forward_delivery_jobs'
 AND c.conname = 'message_forward_delivery_jobs_shape_check' AND c.convalidated AND c.contype = 'c'
) AND (
 SELECT count(*) = 2 FROM pg_indexes WHERE schemaname = 'im_v2' AND tablename = 'message_forward_delivery_jobs'
 AND ((indexname = 'message_forward_delivery_jobs_ready_idx' AND indexdef LIKE '%USING btree (next_attempt_at, created_at, export_id) WHERE (state = ''pending''::text)')
 OR (indexname = 'message_forward_delivery_jobs_lease_idx' AND indexdef LIKE '%USING btree (lease_expires_at, export_id) WHERE (state = ''claimed''::text)'))
) AND EXISTS (
 SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
 WHERE n.nspname = 'im_v2' AND r.relname = 'message_forward_delivery_jobs'
 AND c.conname = 'message_forward_delivery_jobs_export_id_fkey' AND c.convalidated AND c.contype = 'f'
 AND pg_get_constraintdef(c.oid) = 'FOREIGN KEY (export_id) REFERENCES im_v2.message_forward_exports(export_id) ON DELETE RESTRICT'
)) AND ((
    SELECT count(*) = 7 AND count(*) FILTER (WHERE is_nullable = 'NO') = 4
    FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'message_forward_export_receipts'
      AND (column_name, udt_name) IN (
        ('export_id','uuid'), ('payload_digest','bytea'), ('state','text'), ('result_message_id','uuid'),
        ('result_room_sequence','int8'), ('error_code','text'), ('recorded_at','timestamptz')
      )
) AND EXISTS (
    SELECT 1 FROM pg_trigger t JOIN pg_class r ON r.oid = t.tgrelid JOIN pg_namespace n ON n.oid = r.relnamespace
    WHERE n.nspname = 'im_v2' AND r.relname = 'message_forward_export_receipts'
      AND t.tgname = 'message_forward_export_receipts_immutable' AND t.tgtype = 27 AND t.tgenabled = 'O' AND NOT t.tgisinternal
) AND EXISTS (
    SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
    WHERE n.nspname = 'im_v2' AND r.relname = 'message_forward_export_receipts'
      AND c.conname = 'message_forward_export_receipts_shape_check' AND c.convalidated AND c.contype = 'c'
) AND EXISTS (
    SELECT 1 FROM pg_indexes WHERE schemaname = 'im_v2' AND tablename = 'message_forward_export_receipts'
      AND indexname = 'message_forward_export_receipts_pkey'
      AND indexdef LIKE 'CREATE UNIQUE INDEX %USING btree (export_id)'
) AND EXISTS (
    SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
    WHERE n.nspname = 'im_v2' AND r.relname = 'message_forward_export_receipts'
      AND c.conname = 'message_forward_export_receipts_export_id_fkey' AND c.convalidated AND c.contype = 'f'
      AND pg_get_constraintdef(c.oid) = 'FOREIGN KEY (export_id) REFERENCES im_v2.message_forward_exports(export_id) ON DELETE RESTRICT'
)) AND ((
    SELECT count(*) = 13 AND count(*) FILTER (WHERE is_nullable = 'NO') = 7
    FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'message_forward_media_imports'
      AND (column_name, udt_name) IN (
        ('export_id','uuid'), ('ordinal','int4'), ('target_media_id','uuid'), ('target_upload_session_id','uuid'),
        ('state','text'), ('copied_digest','bytea'), ('copied_at','timestamptz'), ('claim_token','uuid'),
        ('lease_expires_at','timestamptz'), ('next_attempt_at','timestamptz'), ('retry_count','int8'),
        ('created_at','timestamptz'), ('completed_at','timestamptz')
      )
) AND EXISTS (
    SELECT 1 FROM pg_trigger t JOIN pg_class r ON r.oid = t.tgrelid JOIN pg_namespace n ON n.oid = r.relnamespace
    WHERE n.nspname = 'im_v2' AND r.relname = 'message_forward_media_imports'
      AND t.tgname = 'message_forward_media_imports_immutable' AND t.tgtype = 27 AND t.tgenabled = 'O' AND NOT t.tgisinternal
) AND EXISTS (
    SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
    WHERE n.nspname = 'im_v2' AND r.relname = 'message_forward_media_imports'
      AND c.conname = 'message_forward_media_imports_shape_check' AND c.convalidated AND c.contype = 'c'
) AND EXISTS (
    SELECT 1 FROM pg_indexes WHERE schemaname = 'im_v2'
      AND indexname = 'message_forward_media_imports_target_media_id_key'
      AND indexdef LIKE 'CREATE UNIQUE INDEX %USING btree (target_media_id)'
)) AND NOT EXISTS (
    SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = r.relnamespace
    JOIN pg_attribute a ON a.attrelid = r.oid AND a.attnum = ANY(c.conkey)
    WHERE n.nspname = 'im_v2' AND r.relname = 'messages'
      AND c.contype = 'f' AND a.attname = 'forwarded_from_message_id'
)
   AND ((
    SELECT count(*) = 15 AND count(*) FILTER (WHERE is_nullable = 'NO') = 10
    FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'message_forward_inbox'
      AND (column_name, udt_name) IN (
        ('export_id','uuid'), ('actor_user_id','uuid'), ('operation_id','uuid'), ('source_message_id','uuid'),
        ('target_room_id','uuid'), ('target_client_message_id','uuid'), ('payload','bytea'), ('payload_digest','bytea'),
        ('state','text'), ('result_message_id','uuid'), ('result_room_sequence','int8'), ('error_code','text'),
        ('created_at','timestamptz'), ('accepted_at','timestamptz'), ('completed_at','timestamptz')
      )
) AND (
    SELECT count(*) = 6 FROM information_schema.columns
    WHERE table_schema = 'im_v2' AND table_name = 'message_forward_inbox_media'
      AND (column_name, udt_name) IN (('export_id','uuid'), ('ordinal','int4'), ('source_media_id','uuid'), ('target_media_id','uuid'), ('object_digest','bytea'), ('state','text'))
) AND (
    SELECT count(*) = 2 FROM pg_trigger t JOIN pg_class r ON r.oid = t.tgrelid JOIN pg_namespace n ON n.oid = r.relnamespace
    WHERE n.nspname = 'im_v2' AND t.tgenabled = 'O' AND t.tgtype = 27 AND NOT t.tgisinternal
      AND (r.relname, t.tgname) IN (('message_forward_inbox','message_forward_inbox_immutable'), ('message_forward_inbox_media','message_forward_inbox_media_immutable'))
) AND (
    SELECT count(*) = 2 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
    WHERE n.nspname = 'im_v2' AND c.convalidated AND c.contype = 'c'
      AND (r.relname, c.conname) IN (('message_forward_inbox','message_forward_inbox_outcome_check'), ('message_forward_inbox_media','message_forward_inbox_media_ready_check'))
) AND (
    SELECT count(*) = 3 FROM pg_indexes WHERE schemaname = 'im_v2' AND (
        (indexname = 'message_forward_inbox_pair_key' AND indexdef LIKE 'CREATE UNIQUE INDEX %USING btree (actor_user_id, operation_id, source_message_id, target_room_id)')
        OR (indexname = 'message_forward_inbox_client_key' AND indexdef LIKE 'CREATE UNIQUE INDEX %USING btree (actor_user_id, target_client_message_id)')
        OR (indexname = 'message_forward_inbox_media_target_media_id_key' AND indexdef LIKE 'CREATE UNIQUE INDEX %USING btree (target_media_id)')
    )
))
   AND (EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'im_v2' AND table_name = 'rooms'
          AND column_name = 'owner_epoch' AND data_type = 'bigint' AND is_nullable = 'NO'
    ) AND (
        SELECT count(*) = 16 FROM information_schema.columns
        WHERE table_schema = 'im_v2' AND table_name = 'message_forward_exports' AND is_nullable = 'NO'
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
        WHERE n.nspname = 'im_v2' AND r.relname = 'message_forward_exports'
          AND t.tgname = 'message_forward_exports_immutable' AND t.tgenabled = 'O'
          AND t.tgtype = 27 AND NOT t.tgisinternal
    ) AND EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'im_v2' AND tablename = 'message_forward_exports'
          AND indexname = 'message_forward_exports_media_idx'
          AND indexdef LIKE '%USING gin (media_ids)'
    ) AND EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'im_v2' AND tablename = 'message_forward_exports'
          AND indexname = 'message_forward_exports_pair_key'
          AND indexdef LIKE 'CREATE UNIQUE INDEX %USING btree (actor_user_id, operation_id, source_message_id, target_room_id)'
    ))
   AND ((
    SELECT count(*) = 6 AND bool_and(is_nullable = 'NO')
    FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'device_revocation_capabilities'
    AND (column_name, udt_name) IN (('device_id','uuid'), ('user_id','uuid'), ('credential_digest','text'),
        ('session_created_at','timestamptz'), ('session_expires_at','timestamptz'), ('expires_at','timestamptz')))
AND (SELECT count(*) = 5 FROM pg_constraint WHERE conrelid = to_regclass('im_v2.device_revocation_capabilities')
    AND convalidated AND NOT condeferrable AND (conname, pg_get_constraintdef(oid)) IN (
        ('device_revocation_capabilities_pkey','PRIMARY KEY (device_id)'),
        ('device_revocation_capabilities_credential_digest_key','UNIQUE (credential_digest)'),
        ('device_revocation_capability_device','FOREIGN KEY (user_id, device_id) REFERENCES im_v2.auth_devices(user_id, device_id) ON DELETE CASCADE'),
        ('device_revocation_capability_digest','CHECK ((credential_digest ~ ''^[0-9a-f]{64}$''::text))'),
        ('device_revocation_capability_expiry','CHECK ((isfinite(session_created_at) AND isfinite(session_expires_at) AND isfinite(expires_at) AND (session_expires_at > session_created_at) AND (expires_at = (session_expires_at + ''00:10:00''::interval))))')))
)
   AND ((
    SELECT count(*) = 2 AND bool_and(is_nullable = 'NO') FROM information_schema.columns
    WHERE table_schema = 'im_v2' AND table_name = 'device_credential_operations'
      AND (column_name, udt_name) IN (('encrypted_revocation_credential','text'), ('revocation_credential_expires_at','timestamptz'))
) AND EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass('im_v2.device_credential_operations')
      AND conname = 'device_credential_operations_revocation_result_check' AND convalidated
      AND pg_get_constraintdef(oid) = 'CHECK (((encrypted_revocation_credential <> ''''::text) AND isfinite(revocation_credential_expires_at)))'
)
)
   AND to_regnamespace('im_v2') IS NOT NULL
   AND EXISTS (
     SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'im_v2' AND table_name = 'auth_devices'
       AND column_name = 'session_expires_at' AND udt_name = 'timestamptz' AND is_nullable = 'NO'
   )
   AND EXISTS (
     SELECT 1 FROM pg_constraint
     WHERE conrelid = to_regclass('im_v2.auth_devices')
       AND conname = 'auth_devices_session_expiry_finite' AND convalidated
       AND pg_get_constraintdef(oid) = 'CHECK (isfinite(session_expires_at))'
   )
   AND to_regclass('im_v2.message_send_completions') IS NOT NULL
   AND EXISTS (
     SELECT 1
     FROM information_schema.columns
     WHERE table_schema = 'im_v2'
       AND table_name = 'schema_contract'
       AND column_name = 'schema_id'
       AND is_nullable = 'NO'
       AND column_default = '''im-v2-current-33''::text'
   )
   AND EXISTS (
     SELECT 1
     FROM pg_constraint AS constraint_record
     JOIN pg_class AS relation ON relation.oid = constraint_record.conrelid
     JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
     WHERE namespace.nspname = 'im_v2'
       AND relation.relname = 'schema_contract'
       AND constraint_record.contype = 'c'
       AND pg_get_constraintdef(constraint_record.oid) LIKE '%im-v2-current-33%'
   )
   AND EXISTS (
     SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'im_v2' AND table_name = 'message_forward_operations'
       AND column_name = 'source_content_revision' AND data_type = 'bigint'
   )
   AND EXISTS (
     SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'im_v2' AND table_name = 'message_forward_operations'
       AND column_name = 'source_room_id' AND data_type = 'uuid'
   )
   AND (
     SELECT count(*) = 2
     FROM pg_constraint c
     JOIN pg_class r ON r.oid = c.conrelid
     JOIN pg_namespace n ON n.oid = r.relnamespace
     WHERE n.nspname = 'im_v2'
       AND (r.relname, c.conname) IN (
         ('message_send_completions', 'message_send_completions_fingerprint_version_check'),
         ('direct_message_denials', 'direct_message_denials_fingerprint_version_check')
       ) AND c.convalidated
       AND pg_get_expr(c.conbin, c.conrelid) = '(fingerprint_version = ANY (ARRAY[1, 2]))'
   )
   AND EXISTS (
     SELECT 1 FROM pg_trigger t
     JOIN pg_class r ON r.oid = t.tgrelid
     JOIN pg_namespace n ON n.oid = r.relnamespace
     WHERE n.nspname = 'im_v2' AND r.relname = 'message_forward_operations'
       AND t.tgname = 'message_forward_operations_identity_immutable'
       AND t.tgenabled <> 'D' AND NOT t.tgisinternal
   )
   AND EXISTS (
     SELECT 1 FROM pg_index i
     JOIN pg_class r ON r.oid = i.indexrelid
     JOIN pg_namespace n ON n.oid = r.relnamespace
     WHERE n.nspname = 'im_v2' AND r.relname = 'room_events_message_edit_revision_idx'
       AND i.indrelid = to_regclass('im_v2.room_events')
       AND i.indisunique AND i.indisvalid AND i.indisready AND i.indnkeyatts = 3
       AND pg_get_indexdef(i.indexrelid, 1, false) = 'room_id'
       AND pg_get_indexdef(i.indexrelid, 2, false) = 'lower((payload ->> ''message_id''::text))'
       AND pg_get_indexdef(i.indexrelid, 3, false) = '((payload ->> ''message_revision''::text))'
       AND pg_get_expr(i.indpred, i.indrelid) = '(event_type = ''message.edited''::text)'
   )
   AND EXISTS (
       SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'im_v2' AND table_name = 'rooms'
         AND column_name = 'last_event_at' AND udt_name = 'timestamptz'
         AND is_nullable = 'NO'
   )
   AND EXISTS (
       SELECT 1 FROM pg_class AS index_record
       JOIN pg_namespace AS namespace ON namespace.oid = index_record.relnamespace
       WHERE namespace.nspname = 'im_v2'
         AND index_record.relname = 'rooms_last_event_at_idx'
         AND index_record.relkind = 'i'
   )
   AND EXISTS (
       SELECT 1 FROM pg_trigger AS trigger_record
       JOIN pg_class AS relation ON relation.oid = trigger_record.tgrelid
       JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
       WHERE namespace.nspname = 'im_v2' AND relation.relname = 'rooms'
         AND trigger_record.tgname = 'rooms_touch_last_event_at'
         AND trigger_record.tgenabled = 'O'
         AND NOT trigger_record.tgisinternal
   )
   AND EXISTS (
       SELECT 1 FROM pg_class AS index_record
       JOIN pg_namespace AS namespace ON namespace.oid = index_record.relnamespace
       WHERE namespace.nspname = 'im_v2'
         AND index_record.relname = 'messages_room_sender_sequence_idx'
         AND index_record.relkind = 'i'
   )
   AND EXISTS (
       SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'im_v2' AND table_name = 'rooms'
         AND column_name = 'delivery_authority' AND udt_name = 'text'
         AND is_nullable = 'NO'
   )
   AND EXISTS (
       SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'im_v2' AND table_name = 'rooms'
         AND column_name = 'log_trimmed_through_room_sequence' AND udt_name = 'int8'
         AND is_nullable = 'NO'
   )
   AND to_regclass('im_v2.local_schema_migrations') IS NULL)))));
