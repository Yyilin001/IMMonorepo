-- pg_get_constraintdef and pg_get_indexdef qualify im_v2 objects according to
-- the caller's search_path. Evaluate the contract in a private empty path so
-- the exact DDL checks work from psql, Compose, and application sessions alike.
WITH schema_visibility AS MATERIALIZED (
 SELECT pg_catalog.set_config('search_path', '', true) AS active_path
)
SELECT (to_regclass('im_v2.device_room_progress') IS NOT NULL
 AND to_regclass('im_v2.room_activation_leases') IS NULL
 AND (SELECT count(*) = 4 FROM pg_attribute WHERE attrelid = to_regclass('im_v2.device_room_progress') AND attnum > 0 AND NOT attisdropped AND attnotnull
      AND ((attname IN ('user_id','device_id','room_id') AND atttypid = 'uuid'::regtype) OR (attname = 'applied_through' AND atttypid = 'bigint'::regtype)))
 AND EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass('im_v2.device_room_progress') AND contype = 'p' AND pg_get_constraintdef(oid) = 'PRIMARY KEY (user_id, device_id, room_id)')
 AND EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass('im_v2.device_room_progress') AND contype = 'c' AND pg_get_constraintdef(oid) = 'CHECK ((applied_through >= 0))')
 AND EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass('im_v2.social_operation_receipts') AND tgname='social_operation_receipts_immutable' AND tgtype=27 AND tgenabled='O') AND to_regclass('im_v2.social_relationship_revisions') IS NOT NULL AND to_regclass('im_v2.social_block_revisions') IS NOT NULL AND to_regclass('im_v2.user_relationship_operations') IS NULL AND to_regclass('im_v2.user_block_operations') IS NULL AND EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass('im_v2.membership_operation_admissions') AND tgname='membership_operation_admissions_immutable' AND tgtype=27 AND tgenabled='O') AND EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass('im_v2.membership_operation_receipts') AND tgname='membership_operation_receipts_immutable' AND tgtype=27 AND tgenabled='O') AND EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass('im_v2.group_capability_admissions') AND tgname='group_capability_admissions_immutable' AND tgtype=27 AND tgenabled='O') AND EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass('im_v2.group_capability_receipts') AND tgname='group_capability_receipts_immutable' AND tgtype=27 AND tgenabled='O') AND to_regclass('im_v2.room_pinned_message_operations') IS NULL AND to_regclass('im_v2.group_announcement_operations') IS NULL AND to_regclass('im_v2.group_permission_operations') IS NULL AND to_regclass('im_v2.group_role_operations') IS NULL AND EXISTS(SELECT 1 FROM pg_proc WHERE pronamespace=to_regnamespace('im_v2') AND proname='reject_message_mutation_receipt_mutation' AND encode(sha256(convert_to(prosrc,'UTF8')),'hex')='3a110559fbb4f875263df3b192f1eebe272b3d51a0a6f7354ca389e00a8583b2') AND EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass('im_v2.member_administration_admissions') AND tgname='member_administration_admissions_immutable' AND tgtype=27 AND tgenabled='O') AND EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass('im_v2.member_administration_receipts') AND tgname='member_administration_receipts_immutable' AND tgtype=27 AND tgenabled='O') AND to_regclass('im_v2.message_reaction_operations') IS NULL AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass('im_v2.message_reaction_receipts') AND tgname='message_reaction_receipts_immutable' AND tgtype=27 AND tgenabled='O') AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass('im_v2.message_mutation_receipts') AND tgname='message_mutation_receipts_immutable' AND tgtype=27 AND tgenabled='O') AND to_regclass('im_v2.message_send_operation_receipts') IS NULL AND (SELECT count(*)=2 FROM information_schema.columns WHERE table_schema='im_v2' AND table_name='message_send_completions' AND ((column_name='operation_fingerprint' AND udt_name='bytea') OR (column_name='operation_resolved_at_ms' AND udt_name='int8'))) AND to_regclass('im_v2.message_edit_operations') IS NULL AND to_regclass('im_v2.message_withdrawal_operations') IS NULL AND to_regclass('im_v2.direct_message_denials') IS NULL AND to_regclass('im_v2.direct_authorization_intents') IS NULL AND to_regclass('im_v2.policy_authorization_holders') IS NULL AND to_regclass('im_v2.policy_authorization_revocations') IS NULL AND to_regclass('im_v2.policy_authorization_holder_generation') IS NULL AND to_regclass('im_v2.room_policy_authorization_leases') IS NULL AND to_regclass('im_v2.direct_authorization_receipts') IS NULL AND to_regprocedure('im_v2.guard_direct_authorization_intent()') IS NULL AND to_regprocedure('im_v2.reject_direct_authorization_receipt_mutation()') IS NULL) AND ((SELECT count(*) = 19 FROM information_schema.columns
 WHERE table_schema = 'im_v2' AND table_name = 'group_join_quota_intents'
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
 AND (SELECT count(*) = 14 FROM pg_constraint WHERE conrelid = to_regclass('im_v2.group_join_quota_intents') AND convalidated AND NOT condeferrable
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
 AND (SELECT count(*) = 5 FROM pg_index WHERE indrelid = to_regclass('im_v2.group_join_quota_intents') AND indisvalid AND indisready
 AND pg_get_indexdef(indexrelid) IN ('CREATE UNIQUE INDEX group_join_quota_intents_pkey ON im_v2.group_join_quota_intents USING btree (applicant_user_id, operation_id)',
'CREATE UNIQUE INDEX group_join_quota_intents_request_id_key ON im_v2.group_join_quota_intents USING btree (request_id)',
'CREATE UNIQUE INDEX group_join_quota_active_invite_idx ON im_v2.group_join_quota_intents USING btree (applicant_user_id, invite_id) WHERE (phase = ANY (ARRAY[''held''::text, ''tracking''::text]))',
'CREATE INDEX group_join_quota_recovery_idx ON im_v2.group_join_quota_intents USING btree (next_check_at, applicant_user_id, operation_id) WHERE (phase = ANY (ARRAY[''held''::text, ''tracking''::text]))',
'CREATE INDEX group_join_quota_terminal_invite_idx ON im_v2.group_join_quota_intents USING btree (applicant_user_id, invite_id, created_at DESC) WHERE ((phase = ''terminal''::text) AND (outcome = ANY (ARRAY[''approved''::text, ''rejected''::text])))'))) AND ((SELECT count(*) = 14 FROM information_schema.columns
 WHERE table_schema = 'im_v2' AND table_name = 'group_join_submission_receipts'
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
 AND (SELECT count(*) = 11 FROM pg_constraint WHERE conrelid = to_regclass('im_v2.group_join_submission_receipts') AND convalidated AND NOT condeferrable
 AND (conname,pg_get_constraintdef(oid)) IN (('group_join_receipt_room_fkey','FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id)'),
('group_join_receipt_target_fkey','FOREIGN KEY (target_request_id) REFERENCES im_v2.group_join_requests(request_id)'),
('group_join_submission_receipt_result_check','CHECK ((((disposition = ''request''::text) AND (target_request_id IS NOT NULL)) OR ((disposition = ANY (ARRAY[''already_member''::text, ''unavailable''::text, ''rate_limited''::text, ''permission_denied''::text])) AND (target_request_id IS NULL))))'),
('group_join_submission_receipts_attempt_created_at_check','CHECK (isfinite(attempt_created_at))'),
('group_join_submission_receipts_generation_check','CHECK ((generation > 0))'),
('group_join_submission_receipts_intent_created_at_check','CHECK (isfinite(intent_created_at))'),
('group_join_submission_receipts_maximum_pending_per_invite_check','CHECK ((maximum_pending_per_invite > 0))'),
('group_join_submission_receipts_note_check','CHECK (((note IS NULL) OR ((octet_length(note) >= 1) AND (octet_length(note) <= 500))))'),
('group_join_submission_receipts_pkey','PRIMARY KEY (applicant_user_id, operation_id, generation)'),
('group_join_submission_receipts_recorded_at_check','CHECK (isfinite(recorded_at))'),
('group_join_submission_receipts_token_digest_check','CHECK ((octet_length(token_digest) = 32))')))
 AND (SELECT count(*) = 1 FROM pg_index WHERE indrelid = to_regclass('im_v2.group_join_submission_receipts') AND indisvalid AND indisready
 AND pg_get_indexdef(indexrelid) IN ('CREATE UNIQUE INDEX group_join_submission_receipts_pkey ON im_v2.group_join_submission_receipts USING btree (applicant_user_id, operation_id, generation)'))) AND ((SELECT count(*) = 8 FROM information_schema.columns
 WHERE table_schema = 'im_v2' AND table_name = 'group_join_quota_aliases'
 AND (column_name,udt_name,is_nullable,COALESCE(column_default,'')) IN (('applicant_user_id','uuid','NO',''),
('operation_id','uuid','NO',''),
('canonical_operation_id','uuid','NO',''),
('room_id','uuid','NO',''),
('invite_id','uuid','NO',''),
('token_digest','bytea','NO',''),
('note','text','YES',''),
('created_at','timestamptz','NO','')))
 AND (SELECT count(*) = 6 FROM pg_constraint WHERE conrelid = to_regclass('im_v2.group_join_quota_aliases') AND convalidated AND NOT condeferrable
 AND (conname,pg_get_constraintdef(oid)) IN (('group_join_quota_aliases_applicant_user_id_canonical_opera_fkey','FOREIGN KEY (applicant_user_id, canonical_operation_id) REFERENCES im_v2.group_join_quota_intents(applicant_user_id, operation_id)'),
('group_join_quota_aliases_check','CHECK ((operation_id <> canonical_operation_id))'),
('group_join_quota_aliases_created_at_check','CHECK (isfinite(created_at))'),
('group_join_quota_aliases_note_check','CHECK (((note IS NULL) OR ((octet_length(note) >= 1) AND (octet_length(note) <= 500))))'),
('group_join_quota_aliases_pkey','PRIMARY KEY (applicant_user_id, operation_id)'),
('group_join_quota_aliases_token_digest_check','CHECK ((octet_length(token_digest) = 32))')))
 AND (SELECT count(*) = 1 FROM pg_index WHERE indrelid = to_regclass('im_v2.group_join_quota_aliases') AND indisvalid AND indisready
 AND pg_get_indexdef(indexrelid) IN ('CREATE UNIQUE INDEX group_join_quota_aliases_pkey ON im_v2.group_join_quota_aliases USING btree (applicant_user_id, operation_id)'))) AND EXISTS (SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_am a ON a.oid = c.relam
 WHERE i.indrelid = to_regclass('im_v2.group_join_requests')
 AND i.indexrelid = to_regclass('im_v2.group_join_requests_applicant_history_idx')
 AND i.indisvalid AND i.indisready AND i.indnkeyatts = 5 AND a.amname = 'btree' AND i.indpred IS NULL
 AND pg_get_indexdef(i.indexrelid, 1, false) = 'invite_id'
 AND pg_get_indexdef(i.indexrelid, 2, false) = 'applicant_user_id'
 AND pg_get_indexdef(i.indexrelid, 3, false) = '((state <> ''cancelled''::text))'
 AND pg_get_indexdef(i.indexrelid, 4, false) = 'created_at'
 AND pg_get_indexdef(i.indexrelid, 5, false) = 'request_id'
 AND i.indoption::text = '0 0 3 3 3') AND ((SELECT count(*) = 2 FROM pg_constraint
 WHERE conrelid = to_regclass('im_v2.group_join_requests') AND convalidated AND NOT condeferrable
 AND (conname, pg_get_constraintdef(oid)) IN (('group_join_requests_decision_check', 'CHECK ((((state = ''cancelled''::text) AND (decision_operation_id IS NULL) AND (decided_by_user_id = applicant_user_id) AND (decided_by_user_id IS NOT NULL) AND (approval_membership_revision IS NULL) AND (decided_at IS NOT NULL)) OR ((state = ''pending''::text) AND (decision_operation_id IS NULL) AND (decided_by_user_id IS NULL) AND (approval_membership_revision IS NULL) AND (decided_at IS NULL)) OR ((state = ''approved''::text) AND (decision_operation_id IS NOT NULL) AND (decided_by_user_id IS NOT NULL) AND (approval_membership_revision IS NOT NULL) AND (decided_at IS NOT NULL)) OR ((state = ''rejected''::text) AND (decision_operation_id IS NOT NULL) AND (decided_by_user_id IS NOT NULL) AND (approval_membership_revision IS NULL) AND (decided_at IS NOT NULL))))'),
('group_join_requests_state_check', 'CHECK ((state = ANY (ARRAY[''pending''::text, ''approved''::text, ''rejected''::text, ''cancelled''::text])))')))
 AND EXISTS (SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_am a ON a.oid = c.relam
 WHERE i.indrelid = to_regclass('im_v2.group_join_requests')
 AND i.indexrelid = to_regclass('im_v2.group_join_requests_invite_id_applicant_user_id_key')
 AND i.indisvalid AND i.indisready AND i.indisunique AND i.indnkeyatts = 2 AND a.amname = 'btree'
 AND pg_get_indexdef(i.indexrelid, 1, false) = 'invite_id'
 AND pg_get_indexdef(i.indexrelid, 2, false) = 'applicant_user_id'
 AND pg_get_expr(i.indpred, i.indrelid) = '(state <> ''cancelled''::text)')) AND ((CASE WHEN to_regclass('im_v2.room_recovery_topology') IS NULL THEN false
 ELSE COALESCE(((xpath('/row/present/text()', query_to_xml(
   'SELECT EXISTS (SELECT 1 FROM im_v2.room_recovery_topology WHERE singleton = true) AS present',
   false, true, '')))[1]::text)::boolean, false) END)
 AND (SELECT count(*) = 2 FROM pg_trigger
      WHERE tgrelid = to_regclass('im_v2.room_owner_routes')
        AND NOT tgisinternal AND tgenabled IN ('O', 'A')
        AND tgfoid = to_regprocedure('im_v2.invalidate_room_recovery_topology()')
        AND (tgname, tgtype::integer) IN (
            ('room_owner_routes_recovery_fence', 29),
            ('room_owner_routes_recovery_truncate_fence', 32))))
 AND ((SELECT count(*) = 9 AND bool_and(is_nullable = CASE WHEN column_name IN ('user_id','session_created_at','session_expires_at','cancelled_at') THEN 'YES' ELSE 'NO' END)
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
 AND pg_get_indexdef(indexrelid,1,false)='device_id' AND pg_get_expr(indpred,indrelid)='(user_id IS NOT NULL)')) AND ((
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
    SELECT count(*) = 18 AND count(*) FILTER (WHERE is_nullable = 'NO') = 11
                  AND count(*) FILTER (WHERE column_name IN ('payload', 'payload_compacted_at') AND is_nullable = 'YES') = 2
    FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'message_forward_inbox'
      AND (column_name, udt_name) IN (
        ('export_id','uuid'), ('actor_user_id','uuid'), ('operation_id','uuid'), ('source_message_id','uuid'),
        ('target_room_id','uuid'), ('target_client_message_id','uuid'), ('target_shard_id','text'), ('target_epoch','int8'), ('payload','bytea'), ('payload_digest','bytea'),
        ('state','text'), ('result_message_id','uuid'), ('result_room_sequence','int8'), ('error_code','text'),
        ('created_at','timestamptz'), ('accepted_at','timestamptz'), ('completed_at','timestamptz'), ('payload_compacted_at','timestamptz')
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
    SELECT count(*) = 4 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
    WHERE n.nspname = 'im_v2' AND c.convalidated AND c.contype = 'c'
      AND (r.relname, c.conname) IN (('message_forward_inbox','message_forward_inbox_outcome_check'), ('message_forward_inbox','message_forward_inbox_owner_check'), ('message_forward_inbox','message_forward_inbox_compaction_check'), ('message_forward_inbox_media','message_forward_inbox_media_ready_check'))
) AND (
    SELECT count(*) = 4 FROM pg_indexes WHERE schemaname = 'im_v2' AND (
        (indexname = 'message_forward_inbox_pair_key' AND indexdef LIKE 'CREATE UNIQUE INDEX %USING btree (actor_user_id, operation_id, source_message_id, target_room_id)')
        OR (indexname = 'message_forward_inbox_client_key' AND indexdef LIKE 'CREATE UNIQUE INDEX %USING btree (actor_user_id, target_client_message_id)')
        OR (indexname = 'message_forward_inbox_media_target_media_id_key' AND indexdef LIKE 'CREATE UNIQUE INDEX %USING btree (target_media_id)')
                    OR (indexname = 'message_forward_inbox_compaction_idx' AND indexdef LIKE '%USING btree (completed_at, export_id) WHERE%payload IS NOT NULL%')
    )
))
   AND (EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'im_v2' AND table_name = 'rooms'
          AND column_name = 'owner_epoch' AND data_type = 'bigint' AND is_nullable = 'NO'
    ) AND (
        SELECT count(*) = 18 AND count(*) FILTER (WHERE is_nullable = 'NO') = 15
                    AND count(*) FILTER (WHERE column_name IN ('payload', 'delivery_completed_at', 'payload_compacted_at') AND is_nullable = 'YES') = 3
                    FROM information_schema.columns
        WHERE table_schema = 'im_v2' AND table_name = 'message_forward_exports'
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
        WHERE n.nspname = 'im_v2' AND r.relname = 'message_forward_exports'
          AND t.tgname = 'message_forward_exports_immutable' AND t.tgenabled = 'O'
          AND t.tgtype = 27 AND NOT t.tgisinternal
    ) AND EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'im_v2' AND tablename = 'message_forward_exports'
          AND indexname = 'message_forward_exports_media_idx'
          AND indexdef LIKE '%USING gin (media_ids)'
                ) AND EXISTS (
                    SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace
                    WHERE n.nspname = 'im_v2' AND r.relname = 'message_forward_exports'
                      AND c.conname = 'message_forward_exports_compaction_check' AND c.convalidated AND c.contype = 'c'
                ) AND EXISTS (
                    SELECT 1 FROM pg_indexes WHERE schemaname = 'im_v2' AND indexname = 'message_forward_exports_compaction_idx'
                      AND indexdef LIKE '%USING btree (delivery_completed_at, export_id) WHERE%payload IS NOT NULL%'
                ) AND EXISTS (
                    SELECT 1 FROM pg_trigger t JOIN pg_class r ON r.oid = t.tgrelid JOIN pg_namespace n ON n.oid = r.relnamespace
                    WHERE n.nspname = 'im_v2' AND r.relname = 'message_forward_delivery_jobs'
                      AND t.tgname = 'message_forward_delivery_compaction_ready' AND t.tgenabled = 'O'
                      AND t.tgtype = 21 AND NOT t.tgisinternal
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
   AND to_regclass('im_v2.user_state_event_outbox') IS NOT NULL
   AND EXISTS (SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'im_v2' AND table_name = 'user_state_event_outbox'
       AND column_name = 'source_room_id' AND udt_name = 'uuid' AND is_nullable = 'YES')
   AND EXISTS (SELECT 1 FROM pg_constraint
     WHERE conrelid = to_regclass('im_v2.user_state_event_outbox')
       AND conname = 'user_state_event_outbox_room_binding' AND convalidated)
   AND to_regclass('im_v2.user_state_event_outbox_source_room_idx') IS NOT NULL
   AND to_regclass('im_v2.user_state_event_outbox_user_head_idx') IS NOT NULL
   AND to_regclass('im_v2.user_state_event_receipts') IS NOT NULL
   AND (
     SELECT count(*) = 1 FROM information_schema.columns
     WHERE table_schema = 'im_v2'
       AND table_name = 'user_read_receipt_preferences'
       AND column_name = 'preference_revision' AND udt_name = 'int8' AND is_nullable = 'NO'
   )
   AND EXISTS (
     SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'im_v2' AND table_name = 'user_state_event_receipts'
       AND column_name = 'projection_payload' AND udt_name = 'jsonb' AND is_nullable = 'NO'
   )
   AND EXISTS (
     SELECT 1 FROM pg_constraint
     WHERE conrelid = to_regclass('im_v2.user_state_event_receipts')
       AND conname = 'user_state_event_receipts_projection_payload_check' AND convalidated
       AND pg_get_constraintdef(oid) = 'CHECK ((jsonb_typeof(projection_payload) = ''object''::text))'
   )
   AND to_regclass('im_v2.user_state_event_outbox_delivered_idx') IS NOT NULL
   AND to_regclass('im_v2.personal_preference_operation_receipts') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM (VALUES
       ('personal_preference_operation_receipts','receipt','jsonb','NO'),
       ('personal_preference_operation_receipts','request_fingerprint','bytea','NO'),
       ('personal_preference_operation_receipts','fingerprint_version','int2','NO'),
       ('personal_preference_operation_receipts','identity_key','text','NO'),
       ('user_room_preferences','revision','int8','NO'),
       ('user_message_favorites','revision','int8','NO'),
       ('user_message_favorites','is_favorited','bool','NO')) expected(table_name,column_name,udt_name,is_nullable)
       LEFT JOIN information_schema.columns actual ON actual.table_schema='im_v2'
          AND (actual.table_name,actual.column_name,actual.udt_name,actual.is_nullable)=
              (expected.table_name,expected.column_name,expected.udt_name,expected.is_nullable)
       WHERE actual.column_name IS NULL)
   AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass('im_v2.personal_preference_operation_receipts')
       AND tgname='personal_preference_operation_immutable' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27)
   AND to_regclass('im_v2.public_profile_update_operations') IS NOT NULL
   AND (SELECT count(*) = 3 FROM information_schema.columns
        WHERE table_schema='im_v2' AND table_name='public_profile_update_operations'
          AND (column_name,udt_name,is_nullable) IN
          (('request_fingerprint','bytea','NO'),('receipt','jsonb','NO'),('outcome_kind','text','NO')))
   AND EXISTS (SELECT 1 FROM pg_trigger
        WHERE tgrelid=to_regclass('im_v2.public_profile_update_operations')
          AND tgname='public_profile_operation_immutable' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27)
   AND EXISTS (SELECT 1 FROM pg_constraint
        WHERE conrelid=to_regclass('im_v2.public_profile_update_operations')
          AND conname='public_profile_update_operations_result_check' AND convalidated
          AND pg_get_constraintdef(oid) LIKE '%result_revision IS NOT NULL%')
   AND to_regclass('im_v2.message_send_completions') IS NOT NULL
   AND (SELECT count(*) = 5 FROM information_schema.columns
     WHERE table_schema = 'im_v2' AND table_name = 'message_edit_visibility'
       AND (column_name, udt_name, is_nullable) IN (
         ('message_id','uuid','NO'), ('message_revision','int8','NO'), ('room_id','uuid','NO'),
         ('room_sequence','int8','NO'), ('committed_membership_revision','int8','NO')))
   AND (SELECT count(*) = 5 FROM pg_constraint
     WHERE conrelid = to_regclass('im_v2.message_edit_visibility')
       AND convalidated AND NOT condeferrable AND pg_get_constraintdef(oid) IN (
         'PRIMARY KEY (message_id, message_revision)', 'UNIQUE (room_id, room_sequence)',
         'CHECK ((message_revision > 1))', 'CHECK ((room_sequence > 0))',
         'CHECK ((committed_membership_revision >= 0))'))
   AND EXISTS (SELECT 1 FROM pg_index WHERE indrelid = to_regclass('im_v2.message_edit_visibility')
     AND indisvalid AND indisready AND pg_get_indexdef(indexrelid) =
       'CREATE INDEX message_edit_visibility_latest_idx ON im_v2.message_edit_visibility USING btree (message_id, room_sequence DESC) INCLUDE (message_revision, room_id, committed_membership_revision)')
   AND EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
     WHERE t.tgrelid = to_regclass('im_v2.room_events')
       AND t.tgname = 'room_events_capture_message_edit_visibility' AND t.tgtype = 5
       AND t.tgenabled = 'O' AND NOT t.tgisinternal AND t.tgnargs = 0
       AND pg_get_triggerdef(t.oid) =
         'CREATE TRIGGER room_events_capture_message_edit_visibility AFTER INSERT ON im_v2.room_events FOR EACH ROW WHEN ((new.event_type = ''message.edited''::text)) EXECUTE FUNCTION im_v2.capture_message_edit_visibility()'
       AND p.pronamespace = to_regnamespace('im_v2')
       AND p.proname = 'capture_message_edit_visibility' AND p.provolatile = 'v'
       AND encode(sha256(convert_to(p.prosrc, 'UTF8')), 'hex') =
         'e937a94bd50aa8842ed4c2d555fceb0f5a6a5ce729f69d1b817d2ccbda90d4c2')
   AND EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
     WHERE t.tgrelid = to_regclass('im_v2.message_edit_visibility')
       AND t.tgname = 'message_edit_visibility_immutable' AND t.tgtype = 27
       AND t.tgenabled = 'O' AND NOT t.tgisinternal AND t.tgqual IS NULL AND t.tgnargs = 0
       AND p.pronamespace = to_regnamespace('im_v2')
       AND p.proname = 'reject_message_edit_visibility_mutation' AND p.provolatile = 'v'
       AND encode(sha256(convert_to(p.prosrc, 'UTF8')), 'hex') =
         '129858c982b37359241ca4bdabd9a403b7d4e6661989a2abfcebcec57bbf1c51')
   AND EXISTS (
     SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
     JOIN pg_language l ON l.oid = p.prolang
     WHERE t.tgrelid = to_regclass('im_v2.device_revocation_events')
       AND t.tgname = 'device_revocation_events_commit_order'
       AND t.tgtype = 6 AND t.tgenabled = 'O' AND NOT t.tgisinternal
       AND t.tgqual IS NULL AND t.tgnargs = 0
       AND p.pronamespace = to_regnamespace('im_v2')
       AND p.proname = 'serialize_device_revocation_events'
       AND p.provolatile = 'v' AND NOT p.prosecdef AND l.lanname = 'plpgsql'
       AND encode(sha256(convert_to(p.prosrc, 'UTF8')), 'hex') = 'e07c509b2a449890909eb9b8ba54622f477857fa3d49b949de7bc6b09726a107'
   )
   AND EXISTS (
     SELECT 1 FROM pg_attribute a JOIN pg_depend d
       ON d.refobjid = a.attrelid AND d.refobjsubid = a.attnum
      AND d.classid = 'pg_class'::regclass AND d.refclassid = 'pg_class'::regclass AND d.deptype = 'i'
     JOIN pg_sequence s ON s.seqrelid = d.objid
     WHERE a.attrelid = to_regclass('im_v2.device_revocation_events')
       AND a.attname = 'event_id' AND a.attidentity = 'a' AND a.attnotnull
       AND s.seqincrement = 1 AND s.seqcache = 1 AND NOT s.seqcycle
   )
   AND EXISTS (
     SELECT 1
     FROM information_schema.columns
     WHERE table_schema = 'im_v2'
       AND table_name = 'schema_contract'
       AND column_name = 'schema_id'
       AND is_nullable = 'NO'
       AND column_default = '''im-v2-current-72''::text'
   )
   AND EXISTS (
     SELECT 1
     FROM pg_constraint AS constraint_record
     JOIN pg_class AS relation ON relation.oid = constraint_record.conrelid
     JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
     WHERE namespace.nspname = 'im_v2'
       AND relation.relname = 'schema_contract'
       AND constraint_record.contype = 'c'
       AND pg_get_constraintdef(constraint_record.oid) LIKE '%im-v2-current-72%'
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
     SELECT count(*) = 1
     FROM pg_constraint c
     JOIN pg_class r ON r.oid = c.conrelid
     JOIN pg_namespace n ON n.oid = r.relnamespace
     WHERE n.nspname = 'im_v2'
       AND (r.relname, c.conname) IN (
         ('message_send_completions', 'message_send_completions_fingerprint_version_check')
       ) AND c.convalidated
       AND pg_get_expr(c.conbin, c.conrelid) = '(fingerprint_version = 3)'
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
   AND NOT EXISTS (
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
       SELECT 1 FROM pg_index AS definition
       JOIN pg_class AS index_record ON index_record.oid = definition.indexrelid
       JOIN pg_class AS relation ON relation.oid = definition.indrelid
       JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
       WHERE namespace.nspname = 'im_v2' AND relation.relname = 'messages'
         AND index_record.relname = 'messages_latest_visible_idx'
         AND definition.indisvalid AND definition.indisready
         AND pg_get_indexdef(definition.indexrelid) LIKE '%USING btree (room_id, room_sequence DESC, message_id DESC) WHERE (withdrawn_at IS NULL)'
   )
   AND EXISTS (
       SELECT 1 FROM pg_index AS definition
       JOIN pg_class AS index_record ON index_record.oid = definition.indexrelid
       JOIN pg_class AS relation ON relation.oid = definition.indrelid
       JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
       WHERE namespace.nspname = 'im_v2' AND relation.relname = 'messages'
         AND index_record.relname = 'messages_room_log_candidates_idx'
         AND definition.indisvalid AND definition.indisready
         AND pg_get_indexdef(definition.indexrelid) LIKE '%USING btree (room_id, timeline_sequence) WHERE (accepted_event_storage = ''message_row''::text)'
   )
   AND EXISTS (
       SELECT 1 FROM pg_index AS definition
       JOIN pg_class AS index_record ON index_record.oid = definition.indexrelid
       JOIN pg_class AS relation ON relation.oid = definition.indrelid
       JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
       WHERE namespace.nspname = 'im_v2' AND relation.relname = 'messages'
         AND index_record.relname = 'messages_visible_membership_idx'
         AND definition.indisvalid AND definition.indisready
         AND pg_get_indexdef(definition.indexrelid) LIKE '%USING btree (room_id, accepted_membership_revision, room_sequence DESC) WHERE ((accepted_event_storage = ''message_row''::text) AND (withdrawn_at IS NULL))'
   )
   AND EXISTS (
       SELECT 1 FROM pg_index AS definition
       JOIN pg_class AS index_record ON index_record.oid = definition.indexrelid
       JOIN pg_class AS relation ON relation.oid = definition.indrelid
       JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
       WHERE namespace.nspname = 'im_v2' AND relation.relname = 'room_events'
         AND index_record.relname = 'room_events_accepted_membership_idx'
         AND definition.indisvalid AND definition.indisready
         AND pg_get_indexdef(definition.indexrelid) LIKE '%USING btree (room_id, committed_membership_revision, room_sequence DESC) WHERE (event_type = ''message.accepted''::text)'
   )
   AND EXISTS (
       SELECT 1 FROM pg_class AS index_record
       JOIN pg_namespace AS namespace ON namespace.oid = index_record.relnamespace
       WHERE namespace.nspname = 'im_v2'
         AND index_record.relname = 'messages_room_sender_sequence_idx'
         AND index_record.relkind = 'i'
   )
   AND NOT EXISTS (
       SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'im_v2' AND table_name IN ('rooms', 'message_send_completions')
         AND column_name = 'delivery_authority'
   )
   AND EXISTS (
       SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'im_v2' AND table_name = 'rooms'
         AND column_name = 'log_trimmed_through_room_sequence' AND udt_name = 'int8'
         AND is_nullable = 'NO'
   )
   AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name IN ('room_admission', 'shard_admission_pools') AND column_name IN ('fanout_window_limit', 'fanout_window_used', 'max_outstanding_fanout_units', 'outstanding_fanout_units', 'max_outstanding_plans', 'outstanding_plans'))
   AND EXISTS (
       SELECT 1 FROM pg_constraint
       WHERE conrelid = to_regclass('im_v2.messages')
         AND conname = 'messages_message_row_sequences_match' AND convalidated
   )
   AND EXISTS (
       SELECT 1 FROM pg_index
       WHERE indexrelid = to_regclass('im_v2.messages_room_timeline_sequence_key')
         AND indisvalid AND indisready
   )
   AND EXISTS (SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'im_v2' AND table_name = 'account_password_credentials'
         AND column_name = 'credential_revision' AND udt_name = 'int8' AND is_nullable = 'NO')
   AND EXISTS (SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'im_v2' AND table_name = 'account_password_credentials'
         AND column_name = 'recovery_code_hmac' AND udt_name = 'text' AND is_nullable = 'YES')
   AND (SELECT count(*) = 2 FROM information_schema.columns
       WHERE table_schema = 'im_v2' AND table_name = 'control_housekeeping_cursor'
         AND is_nullable = 'NO' AND ((column_name = 'singleton' AND udt_name = 'bool')
           OR (column_name = 'rotation' AND udt_name = 'int8')))
   AND (SELECT count(*) = 3 FROM pg_constraint
       WHERE conrelid = to_regclass('im_v2.control_housekeeping_cursor') AND convalidated AND NOT condeferrable
         AND pg_get_constraintdef(oid) IN ('PRIMARY KEY (singleton)', 'CHECK (singleton)', 'CHECK ((rotation >= 0))'))
   AND to_regclass('im_v2.group_room_operations') IS NULL
   AND to_regclass('im_v2.group_room_creation_drafts') IS NULL
   AND to_regclass('im_v2.group_room_creation_draft_members') IS NULL
   AND to_regclass('im_v2.local_schema_migrations') IS NULL)))
AND (NOT EXISTS (
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
      ('resource_catalog','home_kind','text','NO'),
      ('resource_catalog','home_id','uuid','NO'),
      ('resource_catalog','usage_kind','text','NO'),
      ('resource_catalog','generation','int8','NO'),
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
      ON actual.table_schema = 'im_v2' AND actual.table_name=expected.table_name
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
      WHERE c.conrelid=to_regclass('im_v2.' || expected.table_name)
      AND c.convalidated AND NOT c.condeferrable AND pg_get_constraintdef(c.oid)=expected.definition)
))
AND EXISTS (
                SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
                WHERE t.tgrelid=to_regclass('im_v2.resource_group_avatar_operations')
                  AND t.tgname='resource_group_avatar_operations_immutable' AND t.tgenabled='O'
                  AND NOT t.tgisinternal AND t.tgtype=27 AND t.tgqual IS NULL
                  AND p.pronamespace=(SELECT oid FROM pg_namespace WHERE nspname='im_v2')
                  AND p.proname='reject_group_avatar_operation_mutation'
                  AND encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')='4296ae3a368755188ceb1df59239b3860fe445da8ab147d948b411c1645aa542'
            )
AND (SELECT count(*)=3 FROM pg_index
    WHERE indrelid=to_regclass('im_v2.resource_storage_migrations') AND indisvalid AND indisready
      AND pg_get_indexdef(indexrelid) IN (
        'CREATE UNIQUE INDEX resource_storage_migrations_active_media_idx ON im_v2.resource_storage_migrations USING btree (media_id) WHERE (state = ANY (ARRAY[''pending''::text, ''copying''::text]))',
        'CREATE INDEX resource_storage_migrations_recovery_idx ON im_v2.resource_storage_migrations USING btree (updated_at, operation_id) WHERE (state = ANY (ARRAY[''pending''::text, ''copying''::text]))',
        'CREATE INDEX resource_storage_migrations_retained_idx ON im_v2.resource_storage_migrations USING btree (media_id) WHERE (source_released_at IS NULL)'))
AND EXISTS (SELECT 1 FROM pg_index
    WHERE indrelid=to_regclass('im_v2.resource_imports') AND indisvalid AND indisready
      AND pg_get_indexdef(indexrelid) =
        'CREATE INDEX resource_imports_pending_idx ON im_v2.resource_imports USING btree (updated_at, operation_id) WHERE ((state = ANY (ARRAY[''pending''::text, ''copying''::text, ''processing''::text])) OR (source_released_at IS NULL))')
AND EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
    WHERE t.tgrelid=to_regclass('im_v2.resource_import_source_closures')
      AND t.tgname='resource_import_source_closures_immutable' AND t.tgenabled='O'
      AND NOT t.tgisinternal AND t.tgtype=27 AND t.tgqual IS NULL
      AND p.pronamespace=(SELECT oid FROM pg_namespace WHERE nspname='im_v2')
      AND p.proname='reject_resource_import_source_closure_mutation'
      AND encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')='12ddbdfcf09ecb0d8a1b825f56786746463fc42ed7074494aa3c515bf85f7a3b')
AND (current_setting('transaction_isolation') = 'read committed'
            AND NOT EXISTS (
                SELECT 1 FROM pg_trigger t
                WHERE t.tgrelid = to_regclass('im_v2.message_send_completions')
                  AND t.tgname = 'message_send_completion_close_fence'
            ))
AND (current_setting('transaction_isolation') = 'read committed'
            AND NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid=to_regclass('im_v2.resource_group_avatar_closures') AND contype='f')
            AND NOT EXISTS(
                SELECT 1 FROM (VALUES
                    ('resource_group_avatar_operations','resource_group_avatar_operations_close_fence'),
                    ('resource_group_avatar_closures','resource_group_avatar_closures_commit_fence')
                ) expected(table_name,trigger_name)
                WHERE NOT EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
                    WHERE t.tgrelid=to_regclass('im_v2.' || expected.table_name) AND t.tgname=expected.trigger_name
                      AND t.tgenabled='O' AND NOT t.tgisinternal AND t.tgtype=7 AND t.tgqual IS NULL
                      AND p.pronamespace=(SELECT oid FROM pg_namespace WHERE nspname='im_v2')
                      AND p.proname='fence_group_avatar_terminal_result' AND p.provolatile='v'
                      AND encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')='e480bc5dcdcd3f5640cae14ca8ad77c1c25d93d80f5ecc5894696757935144e4')
            ) AND EXISTS(
                SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
                WHERE t.tgrelid=to_regclass('im_v2.resource_group_avatar_closures')
                  AND t.tgname='resource_group_avatar_closures_immutable' AND t.tgenabled='O'
                  AND NOT t.tgisinternal AND t.tgtype=27 AND t.tgqual IS NULL
                  AND p.pronamespace=(SELECT oid FROM pg_namespace WHERE nspname='im_v2')
                  AND p.proname='reject_group_avatar_operation_mutation'
                  AND encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')='4296ae3a368755188ceb1df59239b3860fe445da8ab147d948b411c1645aa542'
            ))
AND (to_regclass('im_v2.forward_plan_operations') IS NOT NULL AND to_regclass('im_v2.forward_preparation_rejections') IS NOT NULL
 AND EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid WHERE t.tgrelid=to_regclass('im_v2.forward_plan_operations') AND t.tgname='forward_plan_operations_original' AND t.tgenabled='O' AND NOT t.tgisinternal AND t.tgtype=27 AND encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')='80cbb1adb53b73cdadf02e34c635e15e575f28e6656a786af2eb041a97e718cd')
 AND EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass('im_v2.forward_preparation_rejections') AND tgname='forward_preparation_rejections_immutable' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27))
 AND EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass('im_v2.account_preference_receipts') AND tgname='account_preference_receipts_immutable' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27)
 AND EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass('im_v2.group_creation_owner_receipts') AND tgname='group_creation_owner_receipts_immutable' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27)
 AND EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass('im_v2.direct_room_owner_receipts') AND tgname='direct_room_owner_receipts_immutable' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27)
 AND EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid WHERE tgrelid=to_regclass('im_v2.group_creation_operations') AND tgname='group_creation_operations_immutable' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27 AND p.pronamespace=to_regnamespace('im_v2') AND p.proname='protect_group_creation_operation' AND encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')='55675fc998fe04d8e6cd2fd5bc8cfce6c5fa2f109a480deabc2a16404124374c')
 AND EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid WHERE tgrelid=to_regclass('im_v2.group_creation_pages') AND tgname='group_creation_pages_immutable' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27 AND p.pronamespace=to_regnamespace('im_v2') AND p.proname='protect_group_creation_page' AND encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')='96145f80f282327d00b5057937e88f4ce38c179485df552dbf8cd1fcf05a279d')
 AND EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid WHERE tgrelid=to_regclass('im_v2.direct_room_operation_handoffs') AND tgname='direct_room_handoff_protected' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27 AND p.pronamespace=to_regnamespace('im_v2') AND p.proname='protect_direct_room_handoff' AND encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')='50f166da94a12a8fbc19826e0180d1e483786cfae2f5ed96bafc42cd0883b9b1')
 AND to_regclass('im_v2.direct_room_operations') IS NULL
 AND EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass('im_v2.message_moderation_admissions') AND tgname='message_moderation_admissions_immutable' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27)
 AND EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass('im_v2.message_moderation_receipts') AND tgname='message_moderation_receipts_immutable' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27)
 AND EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='im_v2' AND table_name='user_live_presence_leases' AND column_name='publication_suppressed' AND udt_name='bool' AND is_nullable='NO' AND column_default='true')
 AND EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid WHERE tgrelid=to_regclass('im_v2.group_invitation_admissions') AND tgname='group_invitation_admission_immutable' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27 AND p.pronamespace=to_regnamespace('im_v2') AND p.proname='reject_group_invitation_operation_mutation' AND encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')='ce8a82cb032c668a6f5bafaeec509440491e5284df8e4812ef2d0b5d3c54d3df')
 AND EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid WHERE tgrelid=to_regclass('im_v2.group_invitation_receipts') AND tgname='group_invitation_receipt_immutable' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27 AND p.pronamespace=to_regnamespace('im_v2') AND p.proname='reject_group_invitation_operation_mutation' AND encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')='ce8a82cb032c668a6f5bafaeec509440491e5284df8e4812ef2d0b5d3c54d3df')
 AND EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid WHERE tgrelid=to_regclass('im_v2.group_invitation_control_commands') AND tgname='group_invitation_command_immutable' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27 AND p.pronamespace=to_regnamespace('im_v2') AND p.proname='reject_group_invitation_operation_mutation' AND encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')='ce8a82cb032c668a6f5bafaeec509440491e5284df8e4812ef2d0b5d3c54d3df')
 AND EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid WHERE tgrelid=to_regclass('im_v2.remote_device_revocation_baselines') AND tgname='remote_device_revocation_baseline_immutable' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27 AND p.pronamespace=to_regnamespace('im_v2') AND p.proname='guard_remote_device_revocation_metadata' AND encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')='1454e5f25a2fc7b4b156af0e678ae84170cc1664029ac6b9df6af631f9595c60')
 AND (SELECT count(*)=3 FROM information_schema.columns WHERE table_schema='im_v2' AND table_name='remote_device_revocation_baselines' AND is_nullable='NO' AND (column_name,udt_name) IN (('actor_user_id','uuid'),('current_device_id','uuid'),('baseline','jsonb')))
 AND EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid WHERE tgrelid=to_regclass('im_v2.remote_device_revocation_receipts') AND tgname='remote_device_revocation_receipt_immutable' AND tgenabled='O' AND NOT tgisinternal AND tgtype=27 AND p.pronamespace=to_regnamespace('im_v2') AND p.proname='guard_remote_device_revocation_metadata' AND encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')='1454e5f25a2fc7b4b156af0e678ae84170cc1664029ac6b9df6af631f9595c60')
 AND (SELECT count(*)=3 FROM information_schema.columns WHERE table_schema='im_v2' AND table_name='remote_device_revocation_receipts' AND is_nullable='NO' AND (column_name,udt_name) IN (('actor_user_id','uuid'),('current_device_id','uuid'),('receipt','jsonb')))
 AND EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid=to_regclass('im_v2.remote_device_revocation_baselines') AND contype='p' AND convalidated AND NOT condeferrable AND pg_get_constraintdef(oid)='PRIMARY KEY (baseline_id)')
 AND EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid=to_regclass('im_v2.remote_device_revocation_baselines') AND contype='c' AND convalidated AND position('jsonb_typeof' in pg_get_constraintdef(oid))>0 AND position('octet_length' in pg_get_constraintdef(oid))>0 AND position('32768' in pg_get_constraintdef(oid))>0)
 AND EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid=to_regclass('im_v2.remote_device_revocation_receipts') AND contype='p' AND convalidated AND NOT condeferrable AND pg_get_constraintdef(oid)='PRIMARY KEY (actor_user_id, operation_id)')
 AND EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid=to_regclass('im_v2.remote_device_revocation_receipts') AND contype='c' AND convalidated AND position('jsonb_typeof' in pg_get_constraintdef(oid))>0 AND position('octet_length' in pg_get_constraintdef(oid))>0 AND position('65536' in pg_get_constraintdef(oid))>0)
 AND (SELECT count(*)=2 FROM information_schema.columns WHERE table_schema='im_v2' AND table_name='remote_device_revocation_baselines' AND is_nullable='NO' AND (column_name,udt_name) IN (('baseline_id','uuid'),('expires_at','timestamptz')))
 AND EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='im_v2' AND table_name='remote_device_revocation_receipts' AND column_name='operation_id' AND udt_name='uuid' AND is_nullable='NO')
 AND EXISTS(SELECT 1 FROM pg_index i JOIN pg_class idx ON idx.oid=i.indexrelid JOIN pg_am am ON am.oid=idx.relam WHERE i.indrelid=to_regclass('im_v2.remote_device_revocation_baselines') AND idx.relname='remote_device_revocation_baseline_expiry_idx' AND am.amname='btree' AND i.indisvalid AND i.indisready AND i.indpred IS NULL AND i.indexprs IS NULL AND pg_get_indexdef(i.indexrelid,1,TRUE)='expires_at')
 AND (SELECT (SELECT count(*) = 3 FROM pg_indexes WHERE schemaname = 'im_v2' AND (
                (indexname = 'mention_push_wake_intents_claim_idx' AND indexdef LIKE '%USING btree (created_at, source_event_id, target_user_id)')
                OR (indexname = 'mention_push_wake_receipts_cleanup_idx' AND indexdef LIKE '%USING btree (recorded_at, source_event_id, target_user_id)')
                OR (indexname = 'account_password_login_rate_limits_cleanup_idx' AND indexdef LIKE '%USING btree (updated_at, account_handle)')
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
                    WHERE c.table_schema = 'im_v2' AND c.table_name = expected.table_name
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
                WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c
                    WHERE c.conrelid = to_regclass('im_v2.' || expected.table_name)
                      AND c.convalidated AND NOT c.condeferrable
                      AND pg_get_constraintdef(c.oid) = expected.definition)
            ) AND NOT EXISTS (
                SELECT 1 FROM pg_constraint WHERE contype = 'f'
                  AND conrelid IN (to_regclass('im_v2.mention_push_wake_intents'),
                                   to_regclass('im_v2.mention_push_wake_receipts'))
            ) AND NOT EXISTS (
                SELECT 1 FROM pg_constraint WHERE contype = 'f'
                  AND conrelid = to_regclass('im_v2.push_wake_outbox')
                  AND confrelid = to_regclass('im_v2.room_events')
            ) )
AND NOT EXISTS (
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
  WHERE c.conrelid=to_regclass('im_v2.realtime_partition_leases')
  AND c.convalidated AND NOT c.condeferrable AND pg_get_constraintdef(c.oid)=expected.definition)
)
AND (NOT EXISTS (
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
    LEFT JOIN information_schema.columns actual ON actual.table_schema='im_v2'
      AND actual.table_name=expected.table_name AND actual.column_name=expected.column_name
      AND actual.udt_name=expected.type_name AND actual.is_nullable='NO'
    WHERE actual.column_name IS NULL
 ) AND to_regclass('im_v2.room_event_wake_outbox') IS NULL
 AND to_regclass('im_v2.realtime_gateway_leases') IS NULL
AND to_regclass('im_v2.realtime_interests') IS NULL
AND NOT EXISTS (
    SELECT 1 FROM (VALUES
    ('host_id','text'),('service_id','text'),('process_incarnation','uuid'),('lease_token','uuid')
    ) expected(column_name,type_name)
    LEFT JOIN information_schema.columns actual ON actual.table_schema='im_v2'
      AND actual.table_name='realtime_partition_leases' AND actual.column_name=expected.column_name
      AND actual.udt_name=expected.type_name AND actual.is_nullable='YES'
    WHERE actual.column_name IS NULL
) AND NOT EXISTS (
    SELECT 1 FROM (VALUES
    ('realtime_partition_leases_pkey'),('user_sync_wake_outbox_pkey'),
    ('user_sync_wake_claim_idx'),('user_sync_wake_expired_idx')
    ) expected(index_name)
    WHERE NOT EXISTS (SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid
      JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='im_v2' AND c.relname=expected.index_name
      AND i.indisvalid AND i.indisready)
) AND NOT EXISTS (
    SELECT 1 FROM (VALUES
    ('user_sync_log','user_sync_log_enqueue_wake')
    ) expected(table_name,trigger_name)
    WHERE NOT EXISTS (SELECT 1 FROM pg_trigger t
      WHERE t.tgrelid=to_regclass('im_v2' || '.' || expected.table_name)
        AND t.tgname=expected.trigger_name AND t.tgtype=4 AND t.tgenabled='O' AND NOT t.tgisinternal)
) AND NOT EXISTS (
    SELECT 1 FROM (VALUES
('enqueue_user_sync_wake','17acd1000a304365fc0d2429df8f6484eaa5d40853c378145748a16d66c1e4ec')
    ) expected(function_name,body_digest)
    WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='im_v2' AND p.proname=expected.function_name
        AND encode(sha256(convert_to(replace(p.prosrc,'im_v2' || '.', 'im_v2.'),'UTF8')),'hex')=expected.body_digest)
))
FROM schema_visibility WHERE active_path = '';
