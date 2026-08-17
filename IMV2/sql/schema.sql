-- Canonical PostgreSQL bootstrap for a fresh IM V2 database.
-- The project is not deployed; earlier database layouts are unsupported.

BEGIN;

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

CREATE SCHEMA im_v2;

CREATE FUNCTION im_v2.capture_user_projection_effect_v3() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.payload_storage = 'inline' AND NEW.projection_kind NOT IN
        ('message', 'membership', 'moderation', 'room') THEN
        INSERT INTO im_v2.user_projection_effects
            (user_id, source_event_id, projection_kind,
             user_sync_sequence, payload, created_at)
        VALUES (NEW.user_id, NEW.source_event_id, NEW.projection_kind,
                NEW.user_sync_sequence, NEW.payload, NEW.created_at)
        ON CONFLICT (user_id, source_event_id, projection_kind) DO UPDATE
        SET user_sync_sequence = EXCLUDED.user_sync_sequence,
            payload = EXCLUDED.payload,
            created_at = EXCLUDED.created_at
        WHERE im_v2.user_projection_effects.user_sync_sequence =
                  EXCLUDED.user_sync_sequence
          AND im_v2.user_projection_effects.payload = EXCLUDED.payload
          AND im_v2.user_projection_effects.created_at = EXCLUDED.created_at;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'conflicting immutable user projection effect';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION im_v2.enqueue_hybrid_group_event_wake() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO im_v2.group_event_wake_outbox (
        room_id, target_room_sequence, revision, state, next_attempt_at, updated_at
    )
    SELECT NEW.room_id, NEW.room_sequence, 1, 'pending', NEW.created_at, NEW.created_at
    FROM im_v2.rooms
    WHERE room_id = NEW.room_id
      AND room_kind = 'group'
      AND delivery_mode = 'large_group_hybrid'
    ON CONFLICT (room_id) DO UPDATE
    SET target_room_sequence = GREATEST(
            im_v2.group_event_wake_outbox.target_room_sequence,
            EXCLUDED.target_room_sequence
        ),
        revision = im_v2.group_event_wake_outbox.revision + 1,
        state = 'pending',
        lease_token = NULL,
        lease_expires_at = NULL,
        next_attempt_at = EXCLUDED.next_attempt_at,
        updated_at = EXCLUDED.updated_at;
    RETURN NEW;
END;
$$;

CREATE FUNCTION im_v2.enqueue_user_projection_v3() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO im_v2.user_projection_checkpoints (user_id, projected_sequence, updated_at)
    VALUES (NEW.user_id, 0, NEW.created_at)
    ON CONFLICT (user_id) DO UPDATE SET updated_at = LEAST(
        im_v2.user_projection_checkpoints.updated_at,
        EXCLUDED.updated_at
    );
    INSERT INTO im_v2.user_sync_retention
        (user_id, compacted_through_sequence, updated_at)
    VALUES (NEW.user_id, 0, NEW.created_at)
    ON CONFLICT (user_id) DO NOTHING;
    RETURN NEW;
END;
$$;

CREATE FUNCTION im_v2.reject_room_delivery_mode_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.delivery_mode IS DISTINCT FROM OLD.delivery_mode THEN
        RAISE EXCEPTION 'room delivery mode is immutable';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION im_v2.reject_room_event_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION 'room events are append-only';
END;
$$;

SET default_tablespace = '';

SET default_table_access_method = heap;

CREATE TABLE im_v2.account_disables (
    user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    reason text NOT NULL,
    operator_principal text NOT NULL,
    disabled_at timestamp with time zone NOT NULL,
    CONSTRAINT account_disables_operator_principal_check CHECK ((operator_principal ~ '^[A-Za-z0-9._:-]{1,128}$'::text)),
    CONSTRAINT account_disables_reason_check CHECK ((reason = ANY (ARRAY['user_requested'::text, 'credential_compromise'::text, 'policy_enforcement'::text])))
);

CREATE TABLE im_v2.account_edge_client_rate_limits (
    client_key text NOT NULL,
    window_started_at timestamp with time zone NOT NULL,
    request_count integer NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT account_edge_client_rate_limits_client_key_check CHECK ((octet_length(client_key) = 64)),
    CONSTRAINT account_edge_client_rate_limits_request_count_check CHECK ((request_count > 0))
);

CREATE TABLE im_v2.account_password_authentication_audit (
    event_id uuid NOT NULL,
    outcome text NOT NULL,
    user_id uuid,
    device_id uuid NOT NULL,
    occurred_at timestamp with time zone NOT NULL,
    CONSTRAINT account_password_authentication_audit_outcome_check CHECK ((outcome = ANY (ARRAY['registration_succeeded'::text, 'assertion_succeeded'::text, 'assertion_rejected'::text])))
);

CREATE TABLE im_v2.account_password_credentials (
    account_handle text NOT NULL,
    user_id uuid NOT NULL,
    password_hash text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT account_password_credentials_account_handle_check CHECK (((octet_length(account_handle) >= 3) AND (octet_length(account_handle) <= 64))),
    CONSTRAINT account_password_credentials_password_hash_check CHECK (((length(password_hash) >= 60) AND (length(password_hash) <= 255)))
);

CREATE TABLE im_v2.account_password_login_rate_limits (
    account_handle text NOT NULL,
    window_started_at timestamp with time zone NOT NULL,
    failure_count integer NOT NULL,
    blocked_until timestamp with time zone,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT account_password_login_rate_limits_account_handle_check CHECK (((octet_length(account_handle) >= 3) AND (octet_length(account_handle) <= 64))),
    CONSTRAINT account_password_login_rate_limits_failure_count_check CHECK ((failure_count > 0))
);

CREATE TABLE im_v2.auth_devices (
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    revoked_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    display_name text DEFAULT 'This device'::text NOT NULL,
    platform text DEFAULT 'Unknown'::text NOT NULL,
    last_active_at timestamp with time zone NOT NULL,
    CONSTRAINT auth_devices_display_name_length CHECK (((octet_length(display_name) >= 1) AND (octet_length(display_name) <= 128))),
    CONSTRAINT auth_devices_platform_length CHECK (((octet_length(platform) >= 1) AND (octet_length(platform) <= 64)))
);

CREATE TABLE im_v2.consumer_inbox (
    consumer_name text NOT NULL,
    source_event_id uuid NOT NULL,
    target_user_id uuid NOT NULL,
    projection_kind text NOT NULL,
    committed_at timestamp with time zone NOT NULL,
    user_sync_sequence bigint,
    CONSTRAINT consumer_inbox_user_sync_sequence_check CHECK (((user_sync_sequence IS NULL) OR (user_sync_sequence > 0)))
);

CREATE TABLE im_v2.content_review_cases (
    message_id uuid NOT NULL,
    status text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT content_review_cases_status_check CHECK ((status = ANY (ARRAY['open'::text, 'resolved'::text])))
);

CREATE TABLE im_v2.content_review_decisions (
    message_id uuid NOT NULL,
    decision text NOT NULL,
    policy_version text NOT NULL,
    decided_at timestamp with time zone NOT NULL,
    CONSTRAINT content_review_decisions_decision_check CHECK ((decision = ANY (ARRAY['clear'::text, 'review_required'::text, 'violation'::text]))),
    CONSTRAINT content_review_decisions_policy_version_check CHECK (((octet_length(policy_version) >= 1) AND (octet_length(policy_version) <= 64)))
);

CREATE TABLE im_v2.content_review_findings (
    message_id uuid NOT NULL,
    category text NOT NULL,
    severity smallint NOT NULL,
    confidence double precision NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT content_review_findings_category_check CHECK (((octet_length(category) >= 1) AND (octet_length(category) <= 64))),
    CONSTRAINT content_review_findings_confidence_check CHECK (((confidence >= (0)::double precision) AND (confidence <= (1)::double precision))),
    CONSTRAINT content_review_findings_severity_check CHECK (((severity >= 0) AND (severity <= 4)))
);

CREATE TABLE im_v2.content_review_jobs (
    message_id uuid NOT NULL,
    room_id uuid NOT NULL,
    expected_content_revision bigint NOT NULL,
    state text NOT NULL,
    decision text,
    claim_token uuid,
    lease_expires_at timestamp with time zone,
    retry_count integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone NOT NULL,
    completed_at timestamp with time zone,
    next_attempt_at timestamp with time zone,
    paused_at timestamp with time zone,
    finding_category text,
    finding_severity smallint,
    finding_confidence double precision,
    CONSTRAINT content_review_jobs_check CHECK (((state = 'claimed'::text) = ((claim_token IS NOT NULL) AND (lease_expires_at IS NOT NULL)))),
    CONSTRAINT content_review_jobs_decision_check CHECK (((decision IS NULL) OR (decision = ANY (ARRAY['clear'::text, 'review_required'::text, 'violation'::text])))),
    CONSTRAINT content_review_jobs_expected_content_revision_check CHECK ((expected_content_revision > 0)),
    CONSTRAINT content_review_jobs_retry_count_check CHECK ((retry_count >= 0)),
    CONSTRAINT content_review_jobs_retry_state_check CHECK ((((state = 'paused'::text) AND (paused_at IS NOT NULL) AND (next_attempt_at IS NULL)) OR ((state <> 'paused'::text) AND (paused_at IS NULL)))),
    CONSTRAINT content_review_jobs_staged_finding_check CHECK ((((finding_category IS NULL) AND (finding_severity IS NULL) AND (finding_confidence IS NULL)) OR ((decision = ANY (ARRAY['review_required'::text, 'violation'::text])) AND ((octet_length(finding_category) >= 1) AND (octet_length(finding_category) <= 64)) AND ((finding_severity >= 0) AND (finding_severity <= 4)) AND (finding_confidence >= (0)::double precision) AND (finding_confidence <= (1)::double precision)))),
    CONSTRAINT content_review_jobs_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'claimed'::text, 'completed'::text, 'superseded'::text, 'paused'::text])))
);

CREATE TABLE im_v2.device_access_tokens (
    token_hmac text NOT NULL,
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    issued_at timestamp with time zone NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    revoked_at timestamp with time zone,
    CONSTRAINT device_access_tokens_check CHECK ((expires_at > issued_at)),
    CONSTRAINT device_access_tokens_token_hmac_check CHECK ((length(token_hmac) = 64))
);

CREATE TABLE im_v2.device_credential_operations (
    device_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    operation_kind text NOT NULL,
    user_id uuid NOT NULL,
    request_refresh_hmac text,
    resulting_access_token_hmac text NOT NULL,
    encrypted_access_token text NOT NULL,
    encrypted_refresh_credential text NOT NULL,
    access_token_expires_at timestamp with time zone NOT NULL,
    replay_expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT device_credential_operations_check CHECK ((replay_expires_at >= created_at)),
    CONSTRAINT device_credential_operations_operation_kind_check CHECK ((operation_kind = ANY (ARRAY['registration'::text, 'refresh'::text]))),
    CONSTRAINT device_credential_operations_request_refresh_hmac_check CHECK (((request_refresh_hmac IS NULL) OR (length(request_refresh_hmac) = 64))),
    CONSTRAINT device_credential_operations_resulting_access_token_hmac_check CHECK ((length(resulting_access_token_hmac) = 64))
);

CREATE TABLE im_v2.device_refresh_sessions (
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    family_generation bigint DEFAULT 1 NOT NULL,
    refresh_hmac text NOT NULL,
    issued_at timestamp with time zone NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    revoked_at timestamp with time zone,
    CONSTRAINT device_refresh_sessions_check CHECK ((expires_at > issued_at)),
    CONSTRAINT device_refresh_sessions_family_generation_check CHECK ((family_generation > 0)),
    CONSTRAINT device_refresh_sessions_refresh_hmac_check CHECK ((length(refresh_hmac) = 64))
);

CREATE TABLE im_v2.device_registration_rate_limits (
    user_id uuid NOT NULL,
    window_started_at timestamp with time zone NOT NULL,
    successful_registrations integer NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT device_registration_rate_limits_check CHECK ((updated_at >= window_started_at)),
    CONSTRAINT device_registration_rate_limits_successful_registrations_check CHECK ((successful_registrations > 0))
);

CREATE TABLE im_v2.device_revocation_events (
    event_id bigint NOT NULL,
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL
);

ALTER TABLE im_v2.device_revocation_events ALTER COLUMN event_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME im_v2.device_revocation_events_event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE im_v2.device_session_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    operation_kind text NOT NULL,
    target_device_id uuid,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT device_session_operations_check CHECK ((((operation_kind = 'revoke_device'::text) AND (target_device_id IS NOT NULL)) OR ((operation_kind = 'revoke_other_devices'::text) AND (target_device_id IS NULL)))),
    CONSTRAINT device_session_operations_operation_kind_check CHECK ((operation_kind = ANY (ARRAY['revoke_device'::text, 'revoke_other_devices'::text])))
);

CREATE TABLE im_v2.device_snapshot_resets (
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    reset_generation bigint NOT NULL,
    snapshot_id uuid NOT NULL,
    state text NOT NULL,
    next_sync_token text NOT NULL,
    snapshot_receipt text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone NOT NULL,
    acknowledged_at timestamp with time zone,
    CONSTRAINT device_snapshot_resets_reset_generation_check CHECK ((reset_generation > 0)),
    CONSTRAINT device_snapshot_resets_state_check CHECK ((state = ANY (ARRAY['preparing'::text, 'ready'::text, 'acknowledged'::text, 'expired'::text])))
);

CREATE TABLE im_v2.device_sync_cursors (
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    state text NOT NULL,
    reset_generation bigint NOT NULL,
    acknowledged_sequence bigint DEFAULT 0 NOT NULL,
    pending_snapshot_id uuid,
    pending_base_sequence bigint,
    pending_snapshot_expires_at timestamp with time zone,
    completed_snapshot_id uuid,
    completed_snapshot_ack_receipt text,
    completed_snapshot_generation bigint,
    completed_snapshot_base_sequence bigint,
    CONSTRAINT device_sync_cursors_acknowledged_sequence_check CHECK ((acknowledged_sequence >= 0)),
    CONSTRAINT device_sync_cursors_check CHECK ((((state = 'ready'::text) AND (pending_snapshot_id IS NULL) AND (pending_base_sequence IS NULL)) OR ((state = ANY (ARRAY['reset_preparing'::text, 'reset_pending'::text])) AND (pending_snapshot_id IS NOT NULL) AND (pending_base_sequence IS NOT NULL)))),
    CONSTRAINT device_sync_cursors_completed_snapshot_base_sequence_check CHECK (((completed_snapshot_base_sequence IS NULL) OR (completed_snapshot_base_sequence >= 0))),
    CONSTRAINT device_sync_cursors_completed_snapshot_fence_check CHECK ((((completed_snapshot_id IS NULL) AND (completed_snapshot_ack_receipt IS NULL) AND (completed_snapshot_generation IS NULL) AND (completed_snapshot_base_sequence IS NULL)) OR ((completed_snapshot_id IS NOT NULL) AND (completed_snapshot_ack_receipt IS NOT NULL) AND (completed_snapshot_generation IS NOT NULL) AND (completed_snapshot_base_sequence IS NOT NULL)))),
    CONSTRAINT device_sync_cursors_completed_snapshot_generation_check CHECK (((completed_snapshot_generation IS NULL) OR (completed_snapshot_generation > 0))),
    CONSTRAINT device_sync_cursors_pending_base_sequence_check CHECK (((pending_base_sequence IS NULL) OR (pending_base_sequence >= 0))),
    CONSTRAINT device_sync_cursors_reset_generation_check CHECK ((reset_generation > 0)),
    CONSTRAINT device_sync_cursors_state_check CHECK ((state = ANY (ARRAY['ready'::text, 'reset_preparing'::text, 'reset_pending'::text])))
);

CREATE TABLE im_v2.direct_message_denials (
    sender_user_id uuid NOT NULL,
    client_message_id uuid NOT NULL,
    room_id uuid NOT NULL,
    source_event_id uuid NOT NULL,
    timeline_sequence bigint NOT NULL,
    created_at timestamp with time zone NOT NULL,
    reason text DEFAULT 'generic'::text NOT NULL,
    CONSTRAINT direct_message_denials_reason_check CHECK ((reason = ANY (ARRAY['generic'::text, 'system_account_read_only'::text]))),
    CONSTRAINT direct_message_denials_timeline_sequence_check CHECK ((timeline_sequence > 0))
);

CREATE TABLE im_v2.direct_room_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    target_user_id uuid NOT NULL,
    room_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL
);

CREATE TABLE im_v2.direct_room_pairs (
    lower_user_id uuid NOT NULL,
    higher_user_id uuid NOT NULL,
    room_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL,
    lower_profile_visible_to_higher boolean DEFAULT false NOT NULL,
    higher_profile_visible_to_lower boolean DEFAULT false NOT NULL,
    lower_can_send boolean,
    higher_can_send boolean,
    CONSTRAINT direct_room_pairs_check CHECK ((lower_user_id < higher_user_id))
);

CREATE TABLE im_v2.durable_work_replay_audit (
    operation_id uuid NOT NULL,
    operator_principal text NOT NULL,
    target_kind text NOT NULL,
    source_event_id uuid NOT NULL,
    target_user_id uuid,
    projection_kind text,
    reason_code text NOT NULL,
    requested_at timestamp with time zone NOT NULL,
    outcome text NOT NULL,
    CONSTRAINT durable_work_replay_audit_operator_principal_check CHECK (((char_length(operator_principal) >= 1) AND (char_length(operator_principal) <= 128))),
    CONSTRAINT durable_work_replay_audit_outcome_check CHECK ((outcome = ANY (ARRAY['processing'::text, 'requeued'::text, 'not_paused'::text]))),
    CONSTRAINT durable_work_replay_audit_projection_kind_check CHECK (((projection_kind IS NULL) OR ((char_length(projection_kind) >= 1) AND (char_length(projection_kind) <= 64)))),
    CONSTRAINT durable_work_replay_audit_reason_code_check CHECK ((reason_code = ANY (ARRAY['dependency_recovered'::text, 'data_repaired'::text, 'false_positive'::text]))),
    CONSTRAINT durable_work_replay_audit_target_kind_check CHECK ((target_kind = ANY (ARRAY['room_outbox'::text, 'fanout_delivery'::text, 'content_review'::text, 'media_scan'::text, 'media_purge'::text, 'read_receipt_preference_propagation'::text, 'user_projection'::text]))),
    CONSTRAINT durable_work_replay_audit_target_shape_check CHECK ((((target_kind = ANY (ARRAY['room_outbox'::text, 'content_review'::text, 'media_scan'::text, 'media_purge'::text])) AND (target_user_id IS NULL) AND (projection_kind IS NULL)) OR ((target_kind = 'fanout_delivery'::text) AND (target_user_id IS NOT NULL) AND (projection_kind IS NOT NULL)) OR ((target_kind = ANY (ARRAY['read_receipt_preference_propagation'::text, 'user_projection'::text])) AND (target_user_id IS NOT NULL) AND (projection_kind IS NULL))))
);

CREATE TABLE im_v2.fanout_completion_units (
    source_event_id uuid NOT NULL,
    completion_unit_id uuid NOT NULL,
    target_boundary jsonb NOT NULL,
    target_count bigint NOT NULL,
    committed_target_count bigint DEFAULT 0 NOT NULL,
    policy_skipped_target_count bigint DEFAULT 0 NOT NULL,
    state text NOT NULL,
    lease_expires_at timestamp with time zone,
    retry_count bigint DEFAULT 0 NOT NULL,
    released_at timestamp with time zone,
    CONSTRAINT fanout_completion_units_check CHECK (((committed_target_count + policy_skipped_target_count) <= target_count)),
    CONSTRAINT fanout_completion_units_check1 CHECK (((state = 'pending'::text) OR ((committed_target_count + policy_skipped_target_count) = target_count))),
    CONSTRAINT fanout_completion_units_check2 CHECK (((state <> 'released'::text) OR (released_at IS NOT NULL))),
    CONSTRAINT fanout_completion_units_committed_target_count_check CHECK ((committed_target_count >= 0)),
    CONSTRAINT fanout_completion_units_policy_skipped_target_count_check CHECK ((policy_skipped_target_count >= 0)),
    CONSTRAINT fanout_completion_units_retry_count_check CHECK ((retry_count >= 0)),
    CONSTRAINT fanout_completion_units_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'terminal'::text, 'released'::text]))),
    CONSTRAINT fanout_completion_units_target_count_check CHECK ((target_count >= 0))
);

CREATE TABLE im_v2.fanout_deliveries (
    source_event_id uuid NOT NULL,
    target_user_id uuid NOT NULL,
    projection_kind text NOT NULL,
    completion_unit_id uuid NOT NULL,
    target_shard_bucket text NOT NULL,
    observed_router_epoch bigint NOT NULL,
    state text DEFAULT 'pending'::text NOT NULL,
    claim_token uuid,
    lease_expires_at timestamp with time zone,
    retry_count bigint DEFAULT 0 NOT NULL,
    diagnostic_terminal_reason text,
    next_attempt_at timestamp with time zone,
    paused_at timestamp with time zone,
    last_failure_code text,
    fresh_direct_eligible boolean DEFAULT false NOT NULL,
    CONSTRAINT fanout_deliveries_fresh_direct_kind_check CHECK (((NOT fresh_direct_eligible) OR (projection_kind = 'message'::text))),
    CONSTRAINT fanout_deliveries_observed_router_epoch_check CHECK ((observed_router_epoch >= 0)),
    CONSTRAINT fanout_deliveries_pause_state_check CHECK (((state = 'paused'::text) = (paused_at IS NOT NULL))),
    CONSTRAINT fanout_deliveries_retry_count_check CHECK ((retry_count >= 0)),
    CONSTRAINT fanout_deliveries_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'terminal'::text, 'paused'::text])))
);

CREATE TABLE im_v2.fanout_plan_targets (
    source_event_id uuid NOT NULL,
    target_user_id uuid NOT NULL
);

CREATE TABLE im_v2.fanout_plans (
    plan_id uuid NOT NULL,
    source_event_id uuid NOT NULL,
    room_id uuid NOT NULL,
    source_room_sequence bigint NOT NULL,
    committed_membership_revision bigint NOT NULL,
    target_rule jsonb NOT NULL,
    enumeration_checkpoint jsonb NOT NULL,
    target_count bigint,
    reserved_fanout_cost bigint NOT NULL,
    state text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    terminal_at timestamp with time zone,
    enumerated_target_count bigint DEFAULT 0 NOT NULL,
    CONSTRAINT fanout_plans_check CHECK (((enumerated_target_count >= 0) AND ((target_count IS NULL) OR (enumerated_target_count <= target_count)))),
    CONSTRAINT fanout_plans_committed_membership_revision_check CHECK ((committed_membership_revision >= 0)),
    CONSTRAINT fanout_plans_reserved_fanout_cost_check CHECK ((reserved_fanout_cost >= 0)),
    CONSTRAINT fanout_plans_source_room_sequence_check CHECK ((source_room_sequence > 0)),
    CONSTRAINT fanout_plans_state_check CHECK ((state = ANY (ARRAY['planning'::text, 'planned'::text, 'terminal'::text]))),
    CONSTRAINT fanout_plans_target_count_check CHECK (((target_count IS NULL) OR (target_count >= 0)))
);

CREATE TABLE im_v2.fanout_sync_payloads (
    source_event_id uuid NOT NULL,
    projection_kind text NOT NULL,
    payload jsonb,
    created_at timestamp with time zone NOT NULL,
    message_state_id uuid,
    CONSTRAINT fanout_sync_payloads_message_state_kind_check CHECK (((message_state_id IS NULL) OR (projection_kind = 'message'::text))),
    CONSTRAINT fanout_sync_payloads_payload_reference_check CHECK (((payload IS NOT NULL) OR (message_state_id IS NOT NULL)))
);

CREATE TABLE im_v2.gateway_worker_cursors (
    worker_name text NOT NULL,
    node_id text NOT NULL,
    last_event_id bigint DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT gateway_worker_cursors_last_event_id_check CHECK ((last_event_id >= 0))
);

CREATE TABLE im_v2.group_announcement_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    room_id uuid NOT NULL,
    body text NOT NULL,
    expected_revision bigint NOT NULL,
    resulting_revision bigint NOT NULL,
    room_sequence bigint NOT NULL,
    event_id uuid NOT NULL,
    plan_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT group_announcement_operations_body_check CHECK (((length(body) > 0) AND (octet_length(body) <= 4096))),
    CONSTRAINT group_announcement_operations_expected_revision_check CHECK ((expected_revision >= 0)),
    CONSTRAINT group_announcement_operations_resulting_revision_check CHECK ((resulting_revision > 0)),
    CONSTRAINT group_announcement_operations_room_sequence_check CHECK ((room_sequence > 0))
);

CREATE TABLE im_v2.group_announcements (
    room_id uuid NOT NULL,
    body text NOT NULL,
    revision bigint NOT NULL,
    updated_by_user_id uuid NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT group_announcements_body_check CHECK (((length(body) > 0) AND (octet_length(body) <= 4096))),
    CONSTRAINT group_announcements_revision_check CHECK ((revision > 0))
);

CREATE TABLE im_v2.group_event_wake_outbox (
    room_id uuid NOT NULL,
    target_room_sequence bigint NOT NULL,
    revision bigint NOT NULL,
    state text NOT NULL,
    lease_token uuid,
    lease_expires_at timestamp with time zone,
    attempt_count integer DEFAULT 0 NOT NULL,
    next_attempt_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT group_event_wake_outbox_attempt_count_check CHECK ((attempt_count >= 0)),
    CONSTRAINT group_event_wake_outbox_check CHECK ((((state = 'pending'::text) AND (lease_token IS NULL) AND (lease_expires_at IS NULL)) OR ((state = 'leased'::text) AND (lease_token IS NOT NULL) AND (lease_expires_at IS NOT NULL)))),
    CONSTRAINT group_event_wake_outbox_revision_check CHECK ((revision > 0)),
    CONSTRAINT group_event_wake_outbox_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'leased'::text]))),
    CONSTRAINT group_event_wake_outbox_target_room_sequence_check CHECK ((target_room_sequence > 0))
);

CREATE TABLE im_v2.group_permission_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    room_id uuid NOT NULL,
    expected_revision bigint NOT NULL,
    resulting_revision bigint NOT NULL,
    role text NOT NULL,
    permissions jsonb NOT NULL,
    room_sequence bigint NOT NULL,
    event_id uuid NOT NULL,
    plan_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT group_permission_operations_check CHECK ((resulting_revision > expected_revision)),
    CONSTRAINT group_permission_operations_expected_revision_check CHECK ((expected_revision > 0)),
    CONSTRAINT group_permission_operations_role_check CHECK ((role = ANY (ARRAY['admin'::text, 'member'::text]))),
    CONSTRAINT group_permission_operations_room_sequence_check CHECK ((room_sequence > 0))
);

CREATE TABLE im_v2.group_role_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    room_id uuid NOT NULL,
    target_user_id uuid NOT NULL,
    role text NOT NULL,
    expected_membership_revision bigint NOT NULL,
    resulting_membership_revision bigint NOT NULL,
    room_sequence bigint NOT NULL,
    event_id uuid NOT NULL,
    plan_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT group_role_operations_check CHECK ((resulting_membership_revision > expected_membership_revision)),
    CONSTRAINT group_role_operations_check1 CHECK ((actor_user_id <> target_user_id)),
    CONSTRAINT group_role_operations_expected_membership_revision_check CHECK ((expected_membership_revision > 0)),
    CONSTRAINT group_role_operations_role_check CHECK ((role = ANY (ARRAY['admin'::text, 'member'::text]))),
    CONSTRAINT group_role_operations_room_sequence_check CHECK ((room_sequence > 0))
);

CREATE TABLE im_v2.group_role_permissions (
    room_id uuid NOT NULL,
    role text NOT NULL,
    permission text NOT NULL,
    CONSTRAINT group_role_permissions_permission_check CHECK ((permission = ANY (ARRAY['send_messages'::text, 'invite_members'::text, 'remove_members'::text, 'change_member_roles'::text, 'pin_messages'::text, 'manage_announcements'::text, 'moderate_messages'::text, 'mute_members'::text]))),
    CONSTRAINT group_role_permissions_role_check CHECK ((role = ANY (ARRAY['admin'::text, 'member'::text])))
);

CREATE TABLE im_v2.group_room_creation_draft_members (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    user_id uuid NOT NULL,
    CONSTRAINT group_room_creation_draft_members_check CHECK ((user_id <> actor_user_id))
);

CREATE TABLE im_v2.group_room_creation_drafts (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    title text NOT NULL,
    state text NOT NULL,
    room_id uuid,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    CONSTRAINT group_room_creation_drafts_check CHECK (((state = 'completed'::text) = (room_id IS NOT NULL))),
    CONSTRAINT group_room_creation_drafts_state_check CHECK ((state = ANY (ARRAY['staging'::text, 'finalizing'::text, 'completed'::text]))),
    CONSTRAINT group_room_creation_drafts_title_check CHECK (((octet_length(title) >= 1) AND (octet_length(title) <= 120)))
);

CREATE TABLE im_v2.group_room_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    room_id uuid NOT NULL,
    title text NOT NULL,
    initial_member_user_ids uuid[] NOT NULL,
    created_at timestamp with time zone NOT NULL,
    delivery_mode text DEFAULT 'standard_fanout'::text NOT NULL,
    audience_kind text DEFAULT 'inline'::text NOT NULL,
    initial_member_count integer NOT NULL,
    CONSTRAINT group_room_operations_audience_fingerprint_check CHECK ((((audience_kind = 'inline'::text) AND (initial_member_count = (cardinality(initial_member_user_ids) + 1))) OR ((audience_kind = 'staged'::text) AND (cardinality(initial_member_user_ids) = 0)))),
    CONSTRAINT group_room_operations_audience_kind_check CHECK ((audience_kind = ANY (ARRAY['inline'::text, 'staged'::text]))),
    CONSTRAINT group_room_operations_check CHECK ((array_position(initial_member_user_ids, actor_user_id) IS NULL)),
    CONSTRAINT group_room_operations_delivery_mode_check CHECK ((delivery_mode = ANY (ARRAY['standard_fanout'::text, 'large_group_hybrid'::text]))),
    CONSTRAINT group_room_operations_initial_member_count_check CHECK (((initial_member_count >= 1) AND (initial_member_count <= 100000))),
    CONSTRAINT group_room_operations_initial_member_user_ids_check CHECK ((cardinality(initial_member_user_ids) >= 0)),
    CONSTRAINT group_room_operations_title_check CHECK (((octet_length(title) >= 1) AND (octet_length(title) <= 120)))
);

CREATE TABLE im_v2.group_rooms (
    room_id uuid NOT NULL,
    owner_user_id uuid NOT NULL,
    title text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT group_rooms_title_check CHECK (((octet_length(title) >= 1) AND (octet_length(title) <= 120)))
);

CREATE TABLE im_v2.media_download_grants (
    download_session_id uuid NOT NULL,
    media_id uuid NOT NULL,
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    state text DEFAULT 'pending'::text NOT NULL,
    claim_token uuid,
    lease_expires_at timestamp with time zone,
    retry_count bigint DEFAULT 0 NOT NULL,
    redeemed_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT media_download_grants_check CHECK ((expires_at > created_at)),
    CONSTRAINT media_download_grants_check1 CHECK (((state = 'claimed'::text) = (claim_token IS NOT NULL))),
    CONSTRAINT media_download_grants_check2 CHECK (((state = 'claimed'::text) = (lease_expires_at IS NOT NULL))),
    CONSTRAINT media_download_grants_check3 CHECK (((state = 'consumed'::text) = (redeemed_at IS NOT NULL))),
    CONSTRAINT media_download_grants_retry_count_check CHECK ((retry_count >= 0)),
    CONSTRAINT media_download_grants_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'claimed'::text, 'consumed'::text])))
);

CREATE TABLE im_v2.media_objects (
    media_id uuid NOT NULL,
    owner_user_id uuid NOT NULL,
    content_type text NOT NULL,
    byte_count bigint NOT NULL,
    state text NOT NULL,
    upload_session_id uuid NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    state_updated_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT media_objects_byte_count_check CHECK ((byte_count > 0)),
    CONSTRAINT media_objects_content_type_check CHECK (((octet_length(content_type) > 0) AND (octet_length(content_type) <= 127))),
    CONSTRAINT media_objects_state_check CHECK ((state = ANY (ARRAY['pending_upload'::text, 'scanning'::text, 'available'::text, 'failed'::text, 'expired'::text])))
);

CREATE TABLE im_v2.media_purge_outbox (
    media_id uuid NOT NULL,
    reason text NOT NULL,
    state text NOT NULL,
    claim_token uuid,
    lease_expires_at timestamp with time zone,
    retry_count bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone NOT NULL,
    completed_at timestamp with time zone,
    next_attempt_at timestamp with time zone,
    paused_at timestamp with time zone,
    CONSTRAINT media_purge_outbox_claim_shape_check CHECK (((state = 'claimed'::text) = (claim_token IS NOT NULL))),
    CONSTRAINT media_purge_outbox_completion_shape_check CHECK (((state = 'completed'::text) = (completed_at IS NOT NULL))),
    CONSTRAINT media_purge_outbox_lease_shape_check CHECK (((state = 'claimed'::text) = (lease_expires_at IS NOT NULL))),
    CONSTRAINT media_purge_outbox_paused_shape_check CHECK (((state = 'paused'::text) = (paused_at IS NOT NULL))),
    CONSTRAINT media_purge_outbox_reason_check CHECK ((reason = ANY (ARRAY['unreferenced_expired'::text, 'withdrawn_retention_elapsed'::text]))),
    CONSTRAINT media_purge_outbox_retry_count_check CHECK ((retry_count >= 0)),
    CONSTRAINT media_purge_outbox_retry_deadline_shape_check CHECK (((next_attempt_at IS NULL) OR (state = 'pending'::text))),
    CONSTRAINT media_purge_outbox_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'claimed'::text, 'completed'::text, 'paused'::text])))
);

CREATE TABLE im_v2.media_scan_outbox (
    media_id uuid NOT NULL,
    state text NOT NULL,
    claim_token uuid,
    lease_expires_at timestamp with time zone,
    retry_count bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone NOT NULL,
    completed_at timestamp with time zone,
    next_attempt_at timestamp with time zone,
    paused_at timestamp with time zone,
    CONSTRAINT media_scan_outbox_check CHECK (((state = 'claimed'::text) = (claim_token IS NOT NULL))),
    CONSTRAINT media_scan_outbox_check1 CHECK (((state = 'claimed'::text) = (lease_expires_at IS NOT NULL))),
    CONSTRAINT media_scan_outbox_check2 CHECK (((state = 'completed'::text) = (completed_at IS NOT NULL))),
    CONSTRAINT media_scan_outbox_paused_shape_check CHECK (((state = 'paused'::text) = (paused_at IS NOT NULL))),
    CONSTRAINT media_scan_outbox_retry_count_check CHECK ((retry_count >= 0)),
    CONSTRAINT media_scan_outbox_retry_deadline_shape_check CHECK (((next_attempt_at IS NULL) OR (state = 'pending'::text))),
    CONSTRAINT media_scan_outbox_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'claimed'::text, 'completed'::text, 'paused'::text])))
);

CREATE TABLE im_v2.media_upload_grants (
    upload_session_id uuid NOT NULL,
    media_id uuid NOT NULL,
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    content_type text NOT NULL,
    byte_count bigint NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    state text DEFAULT 'pending'::text NOT NULL,
    claim_token uuid,
    lease_expires_at timestamp with time zone,
    retry_count bigint DEFAULT 0 NOT NULL,
    redeemed_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT media_upload_grants_byte_count_check CHECK ((byte_count > 0)),
    CONSTRAINT media_upload_grants_check CHECK ((expires_at > created_at)),
    CONSTRAINT media_upload_grants_check1 CHECK (((state = 'claimed'::text) = (claim_token IS NOT NULL))),
    CONSTRAINT media_upload_grants_check2 CHECK (((state = 'claimed'::text) = (lease_expires_at IS NOT NULL))),
    CONSTRAINT media_upload_grants_check3 CHECK (((state = 'consumed'::text) = (redeemed_at IS NOT NULL))),
    CONSTRAINT media_upload_grants_content_type_check CHECK (((octet_length(content_type) > 0) AND (octet_length(content_type) <= 127))),
    CONSTRAINT media_upload_grants_retry_count_check CHECK ((retry_count >= 0)),
    CONSTRAINT media_upload_grants_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'claimed'::text, 'consumed'::text])))
);

CREATE TABLE im_v2.media_upload_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    media_id uuid NOT NULL,
    content_type text NOT NULL,
    byte_count bigint NOT NULL,
    upload_session_id uuid NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone NOT NULL,
    requesting_device_id uuid NOT NULL,
    CONSTRAINT media_upload_operations_byte_count_check CHECK ((byte_count > 0))
);

CREATE TABLE im_v2.message_edit_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    room_id uuid NOT NULL,
    message_id uuid NOT NULL,
    expected_message_revision bigint NOT NULL,
    text_body text NOT NULL,
    resulting_message_revision bigint NOT NULL,
    room_sequence bigint NOT NULL,
    event_id uuid NOT NULL,
    plan_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT message_edit_operations_expected_message_revision_check CHECK ((expected_message_revision > 0)),
    CONSTRAINT message_edit_operations_resulting_message_revision_check CHECK ((resulting_message_revision > 0)),
    CONSTRAINT message_edit_operations_room_sequence_check CHECK ((room_sequence > 0)),
    CONSTRAINT message_edit_operations_text_body_check CHECK ((octet_length(text_body) > 0))
);

CREATE TABLE im_v2.message_forward_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    source_message_id uuid NOT NULL,
    target_room_id uuid NOT NULL,
    target_client_message_id uuid NOT NULL,
    result_message_id uuid,
    created_at timestamp with time zone NOT NULL
);

CREATE TABLE im_v2.message_media_references (
    message_id uuid NOT NULL,
    media_id uuid NOT NULL,
    ordinal smallint NOT NULL,
    referenced_at timestamp with time zone NOT NULL,
    revoked_at timestamp with time zone,
    CONSTRAINT message_media_references_ordinal_check CHECK ((ordinal >= 0))
);

CREATE TABLE im_v2.message_mentions (
    message_id uuid NOT NULL,
    ordinal smallint NOT NULL,
    mention_kind text NOT NULL,
    mentioned_user_id uuid,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT message_mentions_check CHECK ((((mention_kind = 'user'::text) AND (mentioned_user_id IS NOT NULL)) OR ((mention_kind = 'everyone'::text) AND (mentioned_user_id IS NULL)))),
    CONSTRAINT message_mentions_mention_kind_check CHECK ((mention_kind = ANY (ARRAY['user'::text, 'everyone'::text]))),
    CONSTRAINT message_mentions_ordinal_check CHECK ((ordinal >= 0))
);

CREATE TABLE im_v2.message_projection_states (
    state_id uuid NOT NULL,
    message_id uuid NOT NULL,
    room_id uuid NOT NULL,
    message_revision bigint NOT NULL,
    variant_key smallint DEFAULT 0 NOT NULL,
    origin_event_id uuid NOT NULL,
    state_event_id uuid,
    is_withdrawn boolean NOT NULL,
    payload_schema_version smallint NOT NULL,
    payload jsonb,
    created_at timestamp with time zone NOT NULL,
    payload_storage text DEFAULT 'inline'::text NOT NULL,
    CONSTRAINT message_projection_states_message_revision_check CHECK ((message_revision > 0)),
    CONSTRAINT message_projection_states_payload_check CHECK (((payload ->> 'event_type'::text) = 'message.accepted'::text)),
    CONSTRAINT message_projection_states_payload_message_check CHECK ((lower((payload ->> 'message_id'::text)) = (message_id)::text)),
    CONSTRAINT message_projection_states_payload_revision_check CHECK ((((payload ->> 'message_revision'::text))::bigint = message_revision)),
    CONSTRAINT message_projection_states_payload_room_check CHECK ((lower((payload ->> 'room_id'::text)) = (room_id)::text)),
    CONSTRAINT message_projection_states_payload_schema_check CHECK ((payload_schema_version = 1)),
    CONSTRAINT message_projection_states_payload_storage_check CHECK ((((payload_storage = 'inline'::text) AND (payload IS NOT NULL)) OR ((payload_storage = 'room_event'::text) AND (payload IS NULL) AND (message_revision = 1) AND (variant_key = 0) AND (state_event_id IS NOT NULL) AND (origin_event_id = state_event_id) AND (NOT is_withdrawn)))),
    CONSTRAINT message_projection_states_payload_withdrawn_check CHECK ((COALESCE(((payload ->> 'is_withdrawn'::text))::boolean, false) = is_withdrawn)),
    CONSTRAINT message_projection_states_variant_key_check CHECK ((variant_key >= 0))
);

CREATE TABLE im_v2.room_events (
    event_id uuid NOT NULL,
    room_id uuid NOT NULL,
    room_sequence bigint NOT NULL,
    event_type text NOT NULL,
    actor_user_id uuid,
    payload jsonb NOT NULL,
    committed_membership_revision bigint NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT room_events_committed_membership_revision_check CHECK ((committed_membership_revision >= 0)),
    CONSTRAINT room_events_room_sequence_check CHECK ((room_sequence > 0))
);

CREATE VIEW im_v2.message_projection_state_values AS
 SELECT state.state_id,
    state.message_id,
    state.room_id,
    state.message_revision,
    state.variant_key,
    state.origin_event_id,
    state.state_event_id,
    state.is_withdrawn,
    state.payload_schema_version,
    COALESCE(state.payload, event.payload) AS payload,
    state.created_at,
    state.payload_storage
   FROM (im_v2.message_projection_states state
     LEFT JOIN im_v2.room_events event ON (((state.payload_storage = 'room_event'::text) AND (event.event_id = state.state_event_id) AND (event.room_id = state.room_id) AND (event.event_type = 'message.accepted'::text) AND (lower((event.payload ->> 'message_id'::text)) = (state.message_id)::text) AND (lower((event.payload ->> 'room_id'::text)) = (state.room_id)::text) AND (((event.payload ->> 'message_revision'::text))::bigint = state.message_revision))))
  WHERE ((state.payload_storage = 'inline'::text) OR (event.event_id IS NOT NULL));

CREATE TABLE im_v2.message_reaction_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    room_id uuid NOT NULL,
    message_id uuid NOT NULL,
    reaction text NOT NULL,
    action text NOT NULL,
    room_sequence bigint NOT NULL,
    event_id uuid NOT NULL,
    plan_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT message_reaction_operations_action_check CHECK ((action = ANY (ARRAY['add'::text, 'remove'::text]))),
    CONSTRAINT message_reaction_operations_room_sequence_check CHECK ((room_sequence > 0))
);

CREATE TABLE im_v2.message_reactions (
    message_id uuid NOT NULL,
    actor_user_id uuid NOT NULL,
    reaction text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT message_reactions_reaction_check CHECK (((octet_length(reaction) > 0) AND (octet_length(reaction) <= 16)))
);

CREATE TABLE im_v2.message_withdrawal_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    room_id uuid NOT NULL,
    message_id uuid NOT NULL,
    expected_message_revision bigint NOT NULL,
    resulting_message_revision bigint NOT NULL,
    room_sequence bigint NOT NULL,
    event_id uuid NOT NULL,
    plan_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT message_withdrawal_operations_expected_message_revision_check CHECK ((expected_message_revision > 0)),
    CONSTRAINT message_withdrawal_operations_resulting_message_revision_check CHECK ((resulting_message_revision > 0)),
    CONSTRAINT message_withdrawal_operations_room_sequence_check CHECK ((room_sequence > 0))
);

CREATE TABLE im_v2.messages (
    message_id uuid NOT NULL,
    room_id uuid NOT NULL,
    room_sequence bigint NOT NULL,
    sender_user_id uuid NOT NULL,
    client_message_id uuid NOT NULL,
    text_body text NOT NULL,
    content_revision bigint DEFAULT 1 NOT NULL,
    withdrawn_at timestamp with time zone,
    withdrawn_by_user_id uuid,
    created_at timestamp with time zone NOT NULL,
    rich_entities jsonb DEFAULT '[]'::jsonb NOT NULL,
    reply_to_message_id uuid,
    forwarded_from_message_id uuid,
    forwarded_from_user_id uuid,
    timeline_sequence bigint NOT NULL,
    CONSTRAINT messages_check CHECK ((((withdrawn_at IS NULL) AND (withdrawn_by_user_id IS NULL)) OR ((withdrawn_at IS NOT NULL) AND (withdrawn_by_user_id IS NOT NULL)))),
    CONSTRAINT messages_content_revision_check CHECK ((content_revision > 0)),
    CONSTRAINT messages_rich_entities_array CHECK ((jsonb_typeof(rich_entities) = 'array'::text)),
    CONSTRAINT messages_room_sequence_check CHECK ((room_sequence > 0)),
    CONSTRAINT messages_timeline_sequence_positive CHECK ((timeline_sequence > 0))
);

CREATE TABLE im_v2.moderation_audit_entries (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    room_id uuid NOT NULL,
    action text NOT NULL,
    target_user_id uuid,
    message_id uuid,
    reason_code text NOT NULL,
    occurred_at timestamp with time zone NOT NULL,
    retain_until timestamp with time zone NOT NULL
);

CREATE TABLE im_v2.moderation_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    room_id uuid NOT NULL,
    action text NOT NULL,
    target_user_id uuid,
    message_id uuid,
    resulting_message_revision bigint,
    resulting_membership_revision bigint,
    mute_until timestamp with time zone,
    reason_code text NOT NULL,
    room_sequence bigint NOT NULL,
    event_id uuid NOT NULL,
    plan_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT moderation_operations_action_check CHECK ((action = ANY (ARRAY['redact_message'::text, 'remove_member'::text, 'mute_member'::text, 'freeze_room'::text, 'unfreeze_room'::text]))),
    CONSTRAINT moderation_operations_check CHECK ((((action = 'redact_message'::text) AND (target_user_id IS NULL) AND (message_id IS NOT NULL) AND (mute_until IS NULL)) OR ((action = ANY (ARRAY['remove_member'::text, 'mute_member'::text])) AND (target_user_id IS NOT NULL) AND (message_id IS NULL)) OR ((action = ANY (ARRAY['freeze_room'::text, 'unfreeze_room'::text])) AND (target_user_id IS NULL) AND (message_id IS NULL) AND (mute_until IS NULL)))),
    CONSTRAINT moderation_operations_check1 CHECK ((((action = 'mute_member'::text) AND (mute_until IS NOT NULL)) OR ((action <> 'mute_member'::text) AND (mute_until IS NULL)))),
    CONSTRAINT moderation_operations_check2 CHECK ((((action = 'redact_message'::text) AND (resulting_message_revision IS NOT NULL)) OR ((action <> 'redact_message'::text) AND (resulting_message_revision IS NULL)))),
    CONSTRAINT moderation_operations_check3 CHECK ((((action = 'remove_member'::text) AND (resulting_membership_revision IS NOT NULL)) OR ((action <> 'remove_member'::text) AND (resulting_membership_revision IS NULL)))),
    CONSTRAINT moderation_operations_reason_code_check CHECK (((octet_length(reason_code) > 0) AND (octet_length(reason_code) <= 64))),
    CONSTRAINT moderation_operations_resulting_membership_revision_check CHECK ((resulting_membership_revision > 0)),
    CONSTRAINT moderation_operations_resulting_message_revision_check CHECK ((resulting_message_revision > 0)),
    CONSTRAINT moderation_operations_room_sequence_check CHECK ((room_sequence > 0))
);

CREATE TABLE im_v2.public_identity_lookup_rate_limits (
    actor_user_id uuid NOT NULL,
    window_started_at timestamp with time zone NOT NULL,
    query_count integer NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT public_identity_lookup_rate_limits_query_count_check CHECK ((query_count > 0))
);

CREATE TABLE im_v2.public_profile_update_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    expected_revision bigint NOT NULL,
    requested_display_name text NOT NULL,
    requested_avatar_media_id uuid,
    result_revision bigint NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT public_profile_update_operations_expected_revision_check CHECK ((expected_revision > 0)),
    CONSTRAINT public_profile_update_operations_requested_display_name_check CHECK (((octet_length(requested_display_name) >= 1) AND (octet_length(requested_display_name) <= 240))),
    CONSTRAINT public_profile_update_operations_result_revision_check CHECK ((result_revision > 0))
);

CREATE TABLE im_v2.public_profile_update_outbox (
    source_event_id uuid NOT NULL,
    source_user_id uuid NOT NULL,
    public_handle text NOT NULL,
    display_name text NOT NULL,
    revision bigint NOT NULL,
    profile_updated_at timestamp with time zone NOT NULL,
    state text DEFAULT 'pending'::text NOT NULL,
    claim_token uuid,
    lease_expires_at timestamp with time zone,
    enumeration_checkpoint uuid,
    retry_count bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone NOT NULL,
    completed_at timestamp with time zone,
    account_kind text DEFAULT 'regular'::text NOT NULL,
    profile_state text DEFAULT 'active'::text NOT NULL,
    CONSTRAINT public_profile_update_outbox_account_kind_check CHECK ((account_kind = ANY (ARRAY['regular'::text, 'system'::text, 'customer_support'::text]))),
    CONSTRAINT public_profile_update_outbox_check CHECK (((state = 'claimed'::text) = (claim_token IS NOT NULL))),
    CONSTRAINT public_profile_update_outbox_check1 CHECK (((state = 'claimed'::text) = (lease_expires_at IS NOT NULL))),
    CONSTRAINT public_profile_update_outbox_check2 CHECK (((state = 'completed'::text) = (completed_at IS NOT NULL))),
    CONSTRAINT public_profile_update_outbox_profile_state_check CHECK ((profile_state = ANY (ARRAY['active'::text, 'deleted'::text, 'suspended'::text, 'hidden'::text]))),
    CONSTRAINT public_profile_update_outbox_retry_count_check CHECK ((retry_count >= 0)),
    CONSTRAINT public_profile_update_outbox_revision_check CHECK ((revision > 0)),
    CONSTRAINT public_profile_update_outbox_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'claimed'::text, 'completed'::text])))
);

CREATE TABLE im_v2.public_user_profiles (
    user_id uuid NOT NULL,
    public_handle text NOT NULL,
    display_name text NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    avatar_media_id uuid,
    state text DEFAULT 'active'::text NOT NULL,
    visibility_revision bigint DEFAULT 1 NOT NULL,
    account_kind text DEFAULT 'regular'::text NOT NULL,
    CONSTRAINT public_user_profiles_account_kind_check CHECK ((account_kind = ANY (ARRAY['regular'::text, 'system'::text, 'customer_support'::text]))),
    CONSTRAINT public_user_profiles_display_name_check CHECK (((octet_length(display_name) >= 1) AND (octet_length(display_name) <= 80))),
    CONSTRAINT public_user_profiles_public_handle_check CHECK ((public_handle ~ '^[a-z0-9_]{3,32}$'::text)),
    CONSTRAINT public_user_profiles_revision_check CHECK ((revision > 0)),
    CONSTRAINT public_user_profiles_state_check CHECK ((state = ANY (ARRAY['active'::text, 'deleted'::text, 'suspended'::text, 'hidden'::text]))),
    CONSTRAINT public_user_profiles_visibility_revision_check CHECK ((visibility_revision > 0))
);

CREATE TABLE im_v2.push_campaigns (
    campaign_id text NOT NULL,
    state text NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT push_campaigns_state_check CHECK ((state = ANY (ARRAY['enabled'::text, 'disabled'::text])))
);

CREATE TABLE im_v2.push_device_budgets (
    device_id uuid NOT NULL,
    campaign_id text NOT NULL,
    window_started_at timestamp with time zone NOT NULL,
    max_work_units bigint NOT NULL,
    used_work_units bigint DEFAULT 0 NOT NULL,
    max_new_key_operations bigint NOT NULL,
    used_new_key_operations bigint DEFAULT 0 NOT NULL,
    CONSTRAINT push_device_budgets_check CHECK ((used_work_units <= max_work_units)),
    CONSTRAINT push_device_budgets_check1 CHECK ((used_new_key_operations <= max_new_key_operations)),
    CONSTRAINT push_device_budgets_max_new_key_operations_check CHECK ((max_new_key_operations >= 0)),
    CONSTRAINT push_device_budgets_max_work_units_check CHECK ((max_work_units >= 0)),
    CONSTRAINT push_device_budgets_used_new_key_operations_check CHECK ((used_new_key_operations >= 0)),
    CONSTRAINT push_device_budgets_used_work_units_check CHECK ((used_work_units >= 0))
);

CREATE TABLE im_v2.push_device_endpoints (
    device_id uuid NOT NULL,
    provider text NOT NULL,
    environment text NOT NULL,
    endpoint_generation uuid NOT NULL,
    encrypted_token text NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    disabled_at timestamp with time zone,
    CONSTRAINT push_device_endpoints_encrypted_token_check CHECK ((length(encrypted_token) > 0)),
    CONSTRAINT push_device_endpoints_environment_check CHECK ((environment = ANY (ARRAY['development'::text, 'production'::text]))),
    CONSTRAINT push_device_endpoints_provider_check CHECK ((provider = 'apns'::text))
);

CREATE TABLE im_v2.push_wake_outbox (
    dispatch_id uuid NOT NULL,
    source_event_id uuid NOT NULL,
    target_user_id uuid NOT NULL,
    target_device_id uuid NOT NULL,
    campaign_id text NOT NULL,
    budget_window_started_at timestamp with time zone NOT NULL,
    requires_new_key_operation boolean DEFAULT false NOT NULL,
    state text DEFAULT 'pending'::text NOT NULL,
    claim_token uuid,
    lease_expires_at timestamp with time zone,
    retry_count bigint DEFAULT 0 NOT NULL,
    suppression_reason text,
    created_at timestamp with time zone NOT NULL,
    sent_at timestamp with time zone,
    admitted_at timestamp with time zone,
    CONSTRAINT push_wake_outbox_retry_count_check CHECK ((retry_count >= 0)),
    CONSTRAINT push_wake_outbox_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'claimed'::text, 'sent'::text, 'suppressed'::text])))
);

CREATE TABLE im_v2.read_receipt_operations (
    user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    room_id uuid NOT NULL,
    requested_room_sequence bigint NOT NULL,
    resulting_room_sequence bigint NOT NULL,
    recorded_at timestamp with time zone NOT NULL,
    projection_recipient_user_id uuid,
    CONSTRAINT read_receipt_operations_requested_room_sequence_check CHECK ((requested_room_sequence > 0)),
    CONSTRAINT read_receipt_operations_resulting_room_sequence_check CHECK ((resulting_room_sequence > 0))
);

CREATE TABLE im_v2.read_receipt_preference_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    allows_direct_read_receipts boolean NOT NULL,
    allows_group_read_receipts boolean NOT NULL,
    updated_at timestamp with time zone NOT NULL
);

CREATE TABLE im_v2.read_receipt_preference_propagation_outbox (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    recorded_at timestamp with time zone NOT NULL,
    state text DEFAULT 'pending'::text NOT NULL,
    claim_token uuid,
    lease_expires_at timestamp with time zone,
    next_attempt_at timestamp with time zone,
    paused_at timestamp with time zone,
    last_failure_code text,
    enumeration_checkpoint uuid,
    retry_count bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone NOT NULL,
    completed_at timestamp with time zone,
    CONSTRAINT read_receipt_preference_propagation_outbox_check CHECK (((state = 'claimed'::text) = (claim_token IS NOT NULL))),
    CONSTRAINT read_receipt_preference_propagation_outbox_check1 CHECK (((state = 'claimed'::text) = (lease_expires_at IS NOT NULL))),
    CONSTRAINT read_receipt_preference_propagation_outbox_check2 CHECK (((state = 'completed'::text) = (completed_at IS NOT NULL))),
    CONSTRAINT read_receipt_preference_propagation_outbox_check3 CHECK (((state = 'paused'::text) = (paused_at IS NOT NULL))),
    CONSTRAINT read_receipt_preference_propagation_outbox_check4 CHECK (((next_attempt_at IS NULL) OR (state = 'pending'::text))),
    CONSTRAINT read_receipt_preference_propagation_outbox_retry_count_check CHECK ((retry_count >= 0)),
    CONSTRAINT read_receipt_preference_propagation_outbox_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'claimed'::text, 'completed'::text, 'paused'::text])))
);

CREATE TABLE im_v2.revoked_device_projection_tombstones (
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    revoked_at timestamp with time zone NOT NULL
);

CREATE TABLE im_v2.room_admission (
    room_id uuid NOT NULL,
    eligible_member_count bigint DEFAULT 0 NOT NULL,
    command_window_limit bigint NOT NULL,
    command_window_used bigint DEFAULT 0 NOT NULL,
    fanout_window_limit bigint NOT NULL,
    fanout_window_used bigint DEFAULT 0 NOT NULL,
    max_outstanding_fanout_units bigint NOT NULL,
    outstanding_fanout_units bigint DEFAULT 0 NOT NULL,
    max_outstanding_plans bigint NOT NULL,
    outstanding_plans bigint DEFAULT 0 NOT NULL,
    shard_lease_id uuid NOT NULL,
    shard_lease_generation bigint NOT NULL,
    CONSTRAINT room_admission_check CHECK ((command_window_used <= command_window_limit)),
    CONSTRAINT room_admission_check1 CHECK ((fanout_window_used <= fanout_window_limit)),
    CONSTRAINT room_admission_check2 CHECK ((outstanding_fanout_units <= max_outstanding_fanout_units)),
    CONSTRAINT room_admission_check3 CHECK ((outstanding_plans <= max_outstanding_plans)),
    CONSTRAINT room_admission_command_window_limit_check CHECK ((command_window_limit >= 0)),
    CONSTRAINT room_admission_command_window_used_check CHECK ((command_window_used >= 0)),
    CONSTRAINT room_admission_eligible_member_count_check CHECK ((eligible_member_count >= 0)),
    CONSTRAINT room_admission_fanout_window_limit_check CHECK ((fanout_window_limit >= 0)),
    CONSTRAINT room_admission_fanout_window_used_check CHECK ((fanout_window_used >= 0)),
    CONSTRAINT room_admission_max_outstanding_fanout_units_check CHECK ((max_outstanding_fanout_units >= 0)),
    CONSTRAINT room_admission_max_outstanding_plans_check CHECK ((max_outstanding_plans >= 0)),
    CONSTRAINT room_admission_outstanding_fanout_units_check CHECK ((outstanding_fanout_units >= 0)),
    CONSTRAINT room_admission_outstanding_plans_check CHECK ((outstanding_plans >= 0)),
    CONSTRAINT room_admission_shard_lease_generation_check CHECK ((shard_lease_generation > 0))
);

CREATE TABLE im_v2.room_member_mutes (
    room_id uuid NOT NULL,
    user_id uuid NOT NULL,
    mute_until timestamp with time zone NOT NULL,
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT room_member_mutes_check CHECK ((mute_until > created_at))
);

CREATE TABLE im_v2.room_member_nickname_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    room_id uuid NOT NULL,
    expected_revision bigint,
    requested_nickname text,
    result_revision bigint NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT room_member_nickname_operations_expected_revision_check CHECK (((expected_revision IS NULL) OR (expected_revision > 0))),
    CONSTRAINT room_member_nickname_operations_requested_nickname_check CHECK (((requested_nickname IS NULL) OR ((octet_length(requested_nickname) >= 1) AND (octet_length(requested_nickname) <= 80)))),
    CONSTRAINT room_member_nickname_operations_result_revision_check CHECK ((result_revision > 0))
);

CREATE TABLE im_v2.room_member_nicknames (
    room_id uuid NOT NULL,
    user_id uuid NOT NULL,
    nickname text,
    revision bigint NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT room_member_nicknames_nickname_check CHECK (((nickname IS NULL) OR ((octet_length(nickname) >= 1) AND (octet_length(nickname) <= 80)))),
    CONSTRAINT room_member_nicknames_revision_check CHECK ((revision > 0))
);

CREATE TABLE im_v2.room_membership_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    room_id uuid NOT NULL,
    target_user_id uuid NOT NULL,
    action text NOT NULL,
    expected_membership_revision bigint NOT NULL,
    resulting_membership_revision bigint NOT NULL,
    room_sequence bigint NOT NULL,
    event_id uuid NOT NULL,
    plan_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT room_membership_operations_action_check CHECK ((action = ANY (ARRAY['add'::text, 'remove'::text]))),
    CONSTRAINT room_membership_operations_expected_membership_revision_check CHECK ((expected_membership_revision >= 0)),
    CONSTRAINT room_membership_operations_resulting_membership_revision_check CHECK ((resulting_membership_revision >= 0)),
    CONSTRAINT room_membership_operations_room_sequence_check CHECK ((room_sequence > 0))
);

CREATE TABLE im_v2.room_memberships (
    room_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role text DEFAULT 'member'::text NOT NULL,
    joined_revision bigint NOT NULL,
    left_revision bigint,
    CONSTRAINT room_memberships_check CHECK (((left_revision IS NULL) OR (left_revision >= joined_revision))),
    CONSTRAINT room_memberships_joined_revision_check CHECK ((joined_revision >= 0)),
    CONSTRAINT room_memberships_role_check CHECK ((role = ANY (ARRAY['owner'::text, 'admin'::text, 'member'::text])))
);

CREATE TABLE im_v2.room_outbox (
    source_event_id uuid NOT NULL,
    plan_id uuid NOT NULL,
    state text NOT NULL,
    claim_token uuid,
    lease_expires_at timestamp with time zone,
    retry_count bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone NOT NULL,
    terminal_at timestamp with time zone,
    next_attempt_at timestamp with time zone,
    paused_at timestamp with time zone,
    last_failure_code text,
    CONSTRAINT room_outbox_pause_state_check CHECK (((state = 'paused'::text) = (paused_at IS NOT NULL))),
    CONSTRAINT room_outbox_retry_count_check CHECK ((retry_count >= 0)),
    CONSTRAINT room_outbox_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'published'::text, 'terminal'::text, 'paused'::text])))
);

CREATE TABLE im_v2.room_pinned_message_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    room_id uuid NOT NULL,
    message_id uuid NOT NULL,
    is_pinned boolean NOT NULL,
    room_sequence bigint NOT NULL,
    event_id uuid NOT NULL,
    plan_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT room_pinned_message_operations_room_sequence_check CHECK ((room_sequence > 0))
);

CREATE TABLE im_v2.room_pinned_messages (
    room_id uuid NOT NULL,
    message_id uuid NOT NULL,
    pinned_by_user_id uuid NOT NULL,
    pinned_at timestamp with time zone NOT NULL
);

CREATE TABLE im_v2.room_read_receipts (
    room_id uuid NOT NULL,
    user_id uuid NOT NULL,
    read_through_room_sequence bigint NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT room_read_receipts_read_through_room_sequence_check CHECK ((read_through_room_sequence > 0))
);

CREATE TABLE im_v2.room_timeline_activities (
    source_event_id uuid NOT NULL,
    room_id uuid NOT NULL,
    timeline_sequence bigint NOT NULL,
    activity_type text NOT NULL,
    recipient_user_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT room_timeline_activities_activity_type_check CHECK ((activity_type = ANY (ARRAY['direct_message_restricted'::text, 'system_account_read_only'::text]))),
    CONSTRAINT room_timeline_activities_timeline_sequence_check CHECK ((timeline_sequence > 0))
);

CREATE TABLE im_v2.rooms (
    room_id uuid NOT NULL,
    room_kind text DEFAULT 'group'::text NOT NULL,
    room_shard_id text NOT NULL,
    room_sequence bigint DEFAULT 0 NOT NULL,
    membership_revision bigint DEFAULT 0 NOT NULL,
    capacity_profile_id text NOT NULL,
    frozen_at timestamp with time zone,
    frozen_by_user_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    delivery_mode text DEFAULT 'standard_fanout'::text NOT NULL,
    group_permission_revision bigint DEFAULT 1 NOT NULL,
    timeline_sequence bigint DEFAULT 0 NOT NULL,
    CONSTRAINT rooms_check CHECK ((((frozen_at IS NULL) AND (frozen_by_user_id IS NULL)) OR ((frozen_at IS NOT NULL) AND (frozen_by_user_id IS NOT NULL)))),
    CONSTRAINT rooms_delivery_mode_check CHECK ((delivery_mode = ANY (ARRAY['standard_fanout'::text, 'large_group_hybrid'::text]))),
    CONSTRAINT rooms_direct_delivery_mode_check CHECK (((room_kind = 'group'::text) OR (delivery_mode = 'standard_fanout'::text))),
    CONSTRAINT rooms_group_permission_revision_check CHECK ((group_permission_revision > 0)),
    CONSTRAINT rooms_membership_revision_check CHECK ((membership_revision >= 0)),
    CONSTRAINT rooms_room_kind_check CHECK ((room_kind = ANY (ARRAY['group'::text, 'direct'::text]))),
    CONSTRAINT rooms_room_sequence_check CHECK ((room_sequence >= 0)),
    CONSTRAINT rooms_timeline_sequence_check CHECK ((timeline_sequence >= 0))
);

CREATE TABLE im_v2.schema_contract (
    schema_id text DEFAULT 'im-v2-current-2'::text NOT NULL,
    CONSTRAINT schema_contract_schema_id_check CHECK ((schema_id = 'im-v2-current-2'::text))
);

CREATE TABLE im_v2.shard_admission_pools (
    room_shard_id text NOT NULL,
    capacity_profile_id text NOT NULL,
    lease_id uuid NOT NULL,
    generation bigint NOT NULL,
    valid_until timestamp with time zone NOT NULL,
    command_window_limit bigint NOT NULL,
    command_window_used bigint DEFAULT 0 NOT NULL,
    fanout_window_limit bigint NOT NULL,
    fanout_window_used bigint DEFAULT 0 NOT NULL,
    max_outstanding_fanout_units bigint NOT NULL,
    outstanding_fanout_units bigint DEFAULT 0 NOT NULL,
    max_outstanding_plans bigint NOT NULL,
    outstanding_plans bigint DEFAULT 0 NOT NULL,
    CONSTRAINT shard_admission_pools_check CHECK ((command_window_used <= command_window_limit)),
    CONSTRAINT shard_admission_pools_check1 CHECK ((fanout_window_used <= fanout_window_limit)),
    CONSTRAINT shard_admission_pools_check2 CHECK ((outstanding_fanout_units <= max_outstanding_fanout_units)),
    CONSTRAINT shard_admission_pools_check3 CHECK ((outstanding_plans <= max_outstanding_plans)),
    CONSTRAINT shard_admission_pools_command_window_limit_check CHECK ((command_window_limit >= 0)),
    CONSTRAINT shard_admission_pools_command_window_used_check CHECK ((command_window_used >= 0)),
    CONSTRAINT shard_admission_pools_fanout_window_limit_check CHECK ((fanout_window_limit >= 0)),
    CONSTRAINT shard_admission_pools_fanout_window_used_check CHECK ((fanout_window_used >= 0)),
    CONSTRAINT shard_admission_pools_generation_check CHECK ((generation > 0)),
    CONSTRAINT shard_admission_pools_max_outstanding_fanout_units_check CHECK ((max_outstanding_fanout_units >= 0)),
    CONSTRAINT shard_admission_pools_max_outstanding_plans_check CHECK ((max_outstanding_plans >= 0)),
    CONSTRAINT shard_admission_pools_outstanding_fanout_units_check CHECK ((outstanding_fanout_units >= 0)),
    CONSTRAINT shard_admission_pools_outstanding_plans_check CHECK ((outstanding_plans >= 0))
);

CREATE TABLE im_v2.special_account_message_audit (
    message_id uuid NOT NULL,
    account_user_id uuid NOT NULL,
    service_principal text NOT NULL,
    operator_id text,
    support_session_room_id uuid,
    content_fingerprint text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT special_account_message_audit_content_fingerprint_check CHECK (((length(content_fingerprint) >= 16) AND (length(content_fingerprint) <= 128))),
    CONSTRAINT special_account_message_audit_operator_id_check CHECK (((operator_id IS NULL) OR ((length(operator_id) >= 1) AND (length(operator_id) <= 128)))),
    CONSTRAINT special_account_message_audit_service_principal_check CHECK (((length(service_principal) >= 1) AND (length(service_principal) <= 128)))
);

CREATE TABLE im_v2.special_account_message_operations (
    account_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    request_fingerprint text NOT NULL,
    room_id uuid NOT NULL,
    message_id uuid,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT special_account_message_operations_request_fingerprint_check CHECK (((length(request_fingerprint) >= 16) AND (length(request_fingerprint) <= 128)))
);

CREATE TABLE im_v2.special_accounts (
    account_user_id uuid NOT NULL,
    stable_key text NOT NULL,
    account_kind text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    allows_customer_messages boolean NOT NULL,
    allows_service_messages boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT special_accounts_account_kind_check CHECK ((account_kind = ANY (ARRAY['system'::text, 'customer_support'::text]))),
    CONSTRAINT special_accounts_check CHECK ((((account_kind = 'system'::text) AND (allows_customer_messages = false)) OR (account_kind = 'customer_support'::text))),
    CONSTRAINT special_accounts_stable_key_check CHECK ((stable_key ~ '^[a-z][a-z0-9_]{2,63}$'::text)),
    CONSTRAINT special_accounts_status_check CHECK ((status = ANY (ARRAY['active'::text, 'paused'::text, 'retired'::text])))
);

CREATE TABLE im_v2.stranger_message_preference_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    allows_stranger_messages boolean NOT NULL,
    updated_at timestamp with time zone NOT NULL
);

CREATE TABLE im_v2.stranger_message_windows (
    sender_user_id uuid NOT NULL,
    recipient_user_id uuid NOT NULL,
    window_started_at timestamp with time zone NOT NULL,
    message_count integer NOT NULL,
    CONSTRAINT stranger_message_windows_check CHECK ((sender_user_id <> recipient_user_id)),
    CONSTRAINT stranger_message_windows_message_count_check CHECK ((message_count > 0))
);

CREATE TABLE im_v2.support_conversation_sessions (
    room_id uuid NOT NULL,
    support_account_user_id uuid NOT NULL,
    customer_user_id uuid NOT NULL,
    state text NOT NULL,
    assigned_operator_id text,
    opened_at timestamp with time zone NOT NULL,
    last_activity_at timestamp with time zone NOT NULL,
    closed_at timestamp with time zone,
    CONSTRAINT support_conversation_sessions_assigned_operator_id_check CHECK (((assigned_operator_id IS NULL) OR ((length(assigned_operator_id) >= 1) AND (length(assigned_operator_id) <= 128)))),
    CONSTRAINT support_conversation_sessions_check CHECK (((state = ANY (ARRAY['resolved'::text, 'closed'::text])) = (closed_at IS NOT NULL))),
    CONSTRAINT support_conversation_sessions_state_check CHECK ((state = ANY (ARRAY['open'::text, 'assigned'::text, 'waiting_customer'::text, 'resolved'::text, 'closed'::text])))
);

CREATE TABLE im_v2.sync_receipts (
    receipt text NOT NULL,
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    reset_generation bigint NOT NULL,
    first_sequence bigint NOT NULL,
    last_sequence bigint NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT sync_receipts_check CHECK ((last_sequence >= first_sequence)),
    CONSTRAINT sync_receipts_first_sequence_check CHECK ((first_sequence >= 0)),
    CONSTRAINT sync_receipts_reset_generation_check CHECK ((reset_generation > 0))
);

CREATE TABLE im_v2.sync_snapshot_artifacts (
    snapshot_id uuid NOT NULL,
    user_id uuid NOT NULL,
    base_user_sync_sequence bigint NOT NULL,
    source_projected_sequence bigint NOT NULL,
    schema_version integer NOT NULL,
    capability_profile text NOT NULL,
    state text NOT NULL,
    after_projection_kind text,
    after_entity_key text,
    next_page_index integer DEFAULT 0 NOT NULL,
    rolling_digest text NOT NULL,
    root_digest text,
    page_count integer,
    item_count bigint DEFAULT 0 NOT NULL,
    total_bytes bigint DEFAULT 0 NOT NULL,
    lease_token uuid,
    lease_expires_at timestamp with time zone,
    expires_at timestamp with time zone NOT NULL,
    failure_code text,
    created_at timestamp with time zone NOT NULL,
    published_at timestamp with time zone,
    CONSTRAINT sync_snapshot_artifacts_base_user_sync_sequence_check CHECK ((base_user_sync_sequence >= 0)),
    CONSTRAINT sync_snapshot_artifacts_capability_profile_check CHECK (((length(capability_profile) >= 1) AND (length(capability_profile) <= 128))),
    CONSTRAINT sync_snapshot_artifacts_check CHECK (((after_projection_kind IS NULL) = (after_entity_key IS NULL))),
    CONSTRAINT sync_snapshot_artifacts_check1 CHECK ((source_projected_sequence >= base_user_sync_sequence)),
    CONSTRAINT sync_snapshot_artifacts_check2 CHECK ((((state = 'published'::text) AND (root_digest IS NOT NULL) AND (page_count IS NOT NULL) AND (published_at IS NOT NULL)) OR (state <> 'published'::text))),
    CONSTRAINT sync_snapshot_artifacts_item_count_check CHECK (((item_count >= 0) AND (item_count <= 1000000))),
    CONSTRAINT sync_snapshot_artifacts_next_page_index_check CHECK (((next_page_index >= 0) AND (next_page_index <= 4096))),
    CONSTRAINT sync_snapshot_artifacts_page_count_check CHECK (((page_count IS NULL) OR ((page_count >= 0) AND (page_count <= 4096)))),
    CONSTRAINT sync_snapshot_artifacts_schema_version_check CHECK ((schema_version > 0)),
    CONSTRAINT sync_snapshot_artifacts_source_projected_sequence_check CHECK ((source_projected_sequence >= 0)),
    CONSTRAINT sync_snapshot_artifacts_state_check CHECK ((state = ANY (ARRAY['building'::text, 'published'::text, 'failed'::text, 'expired'::text]))),
    CONSTRAINT sync_snapshot_artifacts_total_bytes_check CHECK (((total_bytes >= 0) AND (total_bytes <= 268435456)))
);

CREATE TABLE im_v2.sync_snapshot_pages (
    snapshot_id uuid NOT NULL,
    page_index integer NOT NULL,
    first_projection_kind text NOT NULL,
    first_entity_key text NOT NULL,
    last_projection_kind text NOT NULL,
    last_entity_key text NOT NULL,
    item_count integer NOT NULL,
    page_digest text NOT NULL,
    payload bytea NOT NULL,
    byte_count integer NOT NULL,
    CONSTRAINT sync_snapshot_pages_byte_count_check CHECK (((byte_count >= 1) AND (byte_count <= 61440))),
    CONSTRAINT sync_snapshot_pages_check CHECK ((ROW(first_projection_kind, first_entity_key) <= ROW(last_projection_kind, last_entity_key))),
    CONSTRAINT sync_snapshot_pages_item_count_check CHECK (((item_count >= 1) AND (item_count <= 500))),
    CONSTRAINT sync_snapshot_pages_page_digest_check CHECK ((length(page_digest) = 64)),
    CONSTRAINT sync_snapshot_pages_page_index_check CHECK (((page_index >= 0) AND (page_index <= 4095)))
);

CREATE TABLE im_v2.sync_tokens (
    token text NOT NULL,
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    reset_generation bigint NOT NULL,
    watermark bigint NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT sync_tokens_reset_generation_check CHECK ((reset_generation > 0)),
    CONSTRAINT sync_tokens_watermark_check CHECK ((watermark >= 0))
);

CREATE TABLE im_v2.user_add_preference_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    allows_being_added boolean NOT NULL,
    updated_at timestamp with time zone NOT NULL
);

CREATE TABLE im_v2.user_add_preferences (
    user_id uuid NOT NULL,
    allows_being_added boolean DEFAULT true NOT NULL,
    updated_at timestamp with time zone NOT NULL
);

CREATE TABLE im_v2.user_block_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    target_user_id uuid NOT NULL,
    action text NOT NULL,
    is_blocked boolean NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT user_block_operations_action_check CHECK ((action = ANY (ARRAY['block'::text, 'unblock'::text]))),
    CONSTRAINT user_block_operations_check CHECK ((actor_user_id <> target_user_id)),
    CONSTRAINT user_block_operations_check1 CHECK ((((action = 'block'::text) AND is_blocked) OR ((action = 'unblock'::text) AND (NOT is_blocked))))
);

CREATE TABLE im_v2.user_blocks (
    blocker_user_id uuid NOT NULL,
    blocked_user_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT user_blocks_check CHECK ((blocker_user_id <> blocked_user_id))
);

CREATE TABLE im_v2.user_contact_alias_operations (
    owner_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    target_user_id uuid NOT NULL,
    expected_revision bigint,
    requested_remark_name text,
    result_revision bigint NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT user_contact_alias_operations_expected_revision_check CHECK (((expected_revision IS NULL) OR (expected_revision > 0))),
    CONSTRAINT user_contact_alias_operations_requested_remark_name_check CHECK (((requested_remark_name IS NULL) OR ((octet_length(requested_remark_name) >= 1) AND (octet_length(requested_remark_name) <= 80)))),
    CONSTRAINT user_contact_alias_operations_result_revision_check CHECK ((result_revision > 0))
);

CREATE TABLE im_v2.user_contact_aliases (
    owner_user_id uuid NOT NULL,
    target_user_id uuid NOT NULL,
    remark_name text,
    revision bigint NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT user_contact_aliases_check CHECK ((owner_user_id <> target_user_id)),
    CONSTRAINT user_contact_aliases_remark_name_check CHECK (((remark_name IS NULL) OR ((octet_length(remark_name) >= 1) AND (octet_length(remark_name) <= 80)))),
    CONSTRAINT user_contact_aliases_revision_check CHECK ((revision > 0))
);

CREATE TABLE im_v2.user_live_activity_preference_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    allows_online_presence boolean NOT NULL,
    allows_typing_indicators boolean NOT NULL,
    updated_at timestamp with time zone NOT NULL
);

CREATE TABLE im_v2.user_live_activity_preferences (
    user_id uuid NOT NULL,
    allows_online_presence boolean DEFAULT true NOT NULL,
    allows_typing_indicators boolean DEFAULT true NOT NULL,
    updated_at timestamp with time zone NOT NULL
);

CREATE TABLE im_v2.user_live_presence_leases (
    connection_id uuid NOT NULL,
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);

CREATE TABLE im_v2.user_message_favorite_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    message_id uuid NOT NULL,
    room_id uuid NOT NULL,
    is_favorited boolean NOT NULL,
    updated_at timestamp with time zone NOT NULL
);

CREATE TABLE im_v2.user_message_favorites (
    user_id uuid NOT NULL,
    message_id uuid NOT NULL,
    room_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL
);

CREATE TABLE im_v2.user_projection_checkpoints (
    user_id uuid NOT NULL,
    projected_sequence bigint DEFAULT 0 NOT NULL,
    state text DEFAULT 'ready'::text NOT NULL,
    failure_count bigint DEFAULT 0 NOT NULL,
    failed_sequence bigint,
    next_attempt_at timestamp with time zone,
    last_failure_code text,
    paused_at timestamp with time zone,
    migration_fence_token uuid,
    migration_fence_expires_at timestamp with time zone,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT user_projection_checkpoints_check CHECK (((migration_fence_token IS NULL) = (migration_fence_expires_at IS NULL))),
    CONSTRAINT user_projection_checkpoints_check1 CHECK (((state = 'paused'::text) = (paused_at IS NOT NULL))),
    CONSTRAINT user_projection_checkpoints_check2 CHECK (((next_attempt_at IS NULL) OR (state = 'ready'::text))),
    CONSTRAINT user_projection_checkpoints_check3 CHECK (((failure_count = 0) = (failed_sequence IS NULL))),
    CONSTRAINT user_projection_checkpoints_check4 CHECK (((failure_count = 0) = (last_failure_code IS NULL))),
    CONSTRAINT user_projection_checkpoints_failed_sequence_check CHECK (((failed_sequence IS NULL) OR (failed_sequence > 0))),
    CONSTRAINT user_projection_checkpoints_failure_count_check CHECK ((failure_count >= 0)),
    CONSTRAINT user_projection_checkpoints_projected_sequence_check CHECK ((projected_sequence >= 0)),
    CONSTRAINT user_projection_checkpoints_state_check CHECK ((state = ANY (ARRAY['ready'::text, 'paused'::text])))
);

CREATE TABLE im_v2.user_projection_effects (
    user_id uuid NOT NULL,
    source_event_id uuid NOT NULL,
    projection_kind text NOT NULL,
    user_sync_sequence bigint NOT NULL,
    payload jsonb NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT user_projection_effects_projection_kind_check CHECK (((length(projection_kind) >= 1) AND (length(projection_kind) <= 64))),
    CONSTRAINT user_projection_effects_user_sync_sequence_check CHECK ((user_sync_sequence > 0))
);

CREATE TABLE im_v2.user_projection_versions (
    user_id uuid NOT NULL,
    projection_kind text NOT NULL,
    entity_key text NOT NULL,
    scope_room_id uuid,
    valid_from_sequence bigint NOT NULL,
    valid_to_sequence bigint,
    source_event_id uuid NOT NULL,
    payload jsonb,
    created_at timestamp with time zone NOT NULL,
    message_state_id uuid,
    CONSTRAINT user_projection_versions_check CHECK (((valid_to_sequence IS NULL) OR (valid_to_sequence > valid_from_sequence))),
    CONSTRAINT user_projection_versions_check1 CHECK (((scope_room_id IS NULL) OR ((payload IS NOT NULL) AND (lower((payload ->> 'room_id'::text)) = (scope_room_id)::text)) OR ((projection_kind = 'message'::text) AND (message_state_id IS NOT NULL)))),
    CONSTRAINT user_projection_versions_entity_key_check CHECK (((length(entity_key) >= 1) AND (length(entity_key) <= 512))),
    CONSTRAINT user_projection_versions_payload_storage_check CHECK (((payload IS NOT NULL) OR ((projection_kind = 'message'::text) AND (message_state_id IS NOT NULL)))),
    CONSTRAINT user_projection_versions_projection_kind_check CHECK (((length(projection_kind) >= 1) AND (length(projection_kind) <= 64))),
    CONSTRAINT user_projection_versions_valid_from_sequence_check CHECK ((valid_from_sequence > 0))
);

CREATE TABLE im_v2.user_read_receipt_preferences (
    user_id uuid NOT NULL,
    allows_direct_read_receipts boolean DEFAULT true NOT NULL,
    allows_group_read_receipts boolean DEFAULT true NOT NULL,
    updated_at timestamp with time zone NOT NULL
);

CREATE TABLE im_v2.user_relationship_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    target_user_id uuid NOT NULL,
    action text NOT NULL,
    resulting_state text NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT user_relationship_operations_action_check CHECK ((action = ANY (ARRAY['request'::text, 'accept'::text, 'reject'::text, 'remove'::text]))),
    CONSTRAINT user_relationship_operations_check CHECK ((actor_user_id <> target_user_id)),
    CONSTRAINT user_relationship_operations_resulting_state_check CHECK ((resulting_state = ANY (ARRAY['none'::text, 'pending'::text, 'accepted'::text])))
);

CREATE TABLE im_v2.user_relationships (
    lower_user_id uuid NOT NULL,
    higher_user_id uuid NOT NULL,
    state text NOT NULL,
    requested_by_user_id uuid NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT user_relationships_check CHECK ((lower_user_id < higher_user_id)),
    CONSTRAINT user_relationships_check1 CHECK (((requested_by_user_id = lower_user_id) OR (requested_by_user_id = higher_user_id))),
    CONSTRAINT user_relationships_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'accepted'::text])))
);

CREATE TABLE im_v2.user_room_preference_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    room_id uuid NOT NULL,
    pinned_at timestamp with time zone,
    archived_at timestamp with time zone,
    mute_until timestamp with time zone,
    updated_at timestamp with time zone NOT NULL
);

CREATE TABLE im_v2.user_room_preferences (
    user_id uuid NOT NULL,
    room_id uuid NOT NULL,
    pinned_at timestamp with time zone,
    archived_at timestamp with time zone,
    mute_until timestamp with time zone,
    updated_at timestamp with time zone NOT NULL
);

CREATE TABLE im_v2.user_shard_migrations (
    migration_id uuid NOT NULL,
    user_id uuid NOT NULL,
    source_bucket text NOT NULL,
    target_bucket text NOT NULL,
    source_router_epoch bigint NOT NULL,
    phase text NOT NULL,
    source_fingerprint text,
    target_fingerprint text,
    verified_at timestamp with time zone,
    cutover_operation_id uuid,
    retention_until timestamp with time zone,
    last_error_code text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    retention_claim_token uuid,
    retention_claim_expires_at timestamp with time zone,
    retention_retry_count bigint DEFAULT 0 NOT NULL,
    CONSTRAINT user_shard_migrations_check CHECK (((length(btrim(target_bucket)) > 0) AND (target_bucket <> source_bucket))),
    CONSTRAINT user_shard_migrations_phase_check CHECK ((phase = ANY (ARRAY['prepared'::text, 'copying'::text, 'copied'::text, 'verifying'::text, 'forwarding'::text, 'verified'::text, 'cutover'::text, 'retention'::text, 'completed'::text, 'rolled_back'::text, 'failed'::text]))),
    CONSTRAINT user_shard_migrations_retention_claim_shape CHECK ((((retention_claim_token IS NULL) AND (retention_claim_expires_at IS NULL)) OR ((retention_claim_token IS NOT NULL) AND (retention_claim_expires_at IS NOT NULL)))),
    CONSTRAINT user_shard_migrations_retention_retry_count_check CHECK ((retention_retry_count >= 0)),
    CONSTRAINT user_shard_migrations_source_bucket_check CHECK ((length(btrim(source_bucket)) > 0)),
    CONSTRAINT user_shard_migrations_source_router_epoch_check CHECK ((source_router_epoch >= 0))
);

CREATE TABLE im_v2.user_shard_route_operations (
    operation_id uuid NOT NULL,
    operator_principal text NOT NULL,
    user_id uuid NOT NULL,
    write_bucket text NOT NULL,
    read_fallback_bucket text,
    resulting_router_epoch bigint NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT user_shard_route_operations_operator_principal_check CHECK ((length(btrim(operator_principal)) > 0)),
    CONSTRAINT user_shard_route_operations_resulting_router_epoch_check CHECK ((resulting_router_epoch >= 0))
);

CREATE TABLE im_v2.user_shard_route_overrides (
    user_id uuid NOT NULL,
    write_bucket text NOT NULL,
    read_fallback_bucket text,
    router_epoch bigint NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT user_shard_route_overrides_check CHECK (((read_fallback_bucket IS NULL) OR ((length(btrim(read_fallback_bucket)) > 0) AND (read_fallback_bucket <> write_bucket)))),
    CONSTRAINT user_shard_route_overrides_router_epoch_check CHECK ((router_epoch >= 0)),
    CONSTRAINT user_shard_route_overrides_write_bucket_check CHECK ((length(btrim(write_bucket)) > 0))
);

CREATE TABLE im_v2.user_shard_router_configuration (
    configuration_key boolean DEFAULT true NOT NULL,
    router_epoch bigint NOT NULL,
    default_write_bucket text NOT NULL,
    default_read_fallback_bucket text,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT user_shard_router_configuration_check CHECK (((default_read_fallback_bucket IS NULL) OR ((length(btrim(default_read_fallback_bucket)) > 0) AND (default_read_fallback_bucket <> default_write_bucket)))),
    CONSTRAINT user_shard_router_configuration_configuration_key_check CHECK (configuration_key),
    CONSTRAINT user_shard_router_configuration_default_write_bucket_check CHECK ((length(btrim(default_write_bucket)) > 0)),
    CONSTRAINT user_shard_router_configuration_router_epoch_check CHECK ((router_epoch >= 0))
);

CREATE TABLE im_v2.user_stranger_message_preferences (
    user_id uuid NOT NULL,
    allows_stranger_messages boolean DEFAULT true NOT NULL,
    updated_at timestamp with time zone NOT NULL
);

CREATE TABLE im_v2.user_sync_log (
    user_id uuid NOT NULL,
    user_sync_sequence bigint NOT NULL,
    source_event_id uuid NOT NULL,
    projection_kind text NOT NULL,
    payload jsonb,
    payload_storage text DEFAULT 'inline'::text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT user_sync_log_check CHECK ((((payload_storage = 'inline'::text) AND (payload IS NOT NULL)) OR ((payload_storage = 'fanout_shared'::text) AND (payload IS NULL)))),
    CONSTRAINT user_sync_log_payload_storage_check CHECK ((((payload_storage = 'inline'::text) AND (payload IS NOT NULL)) OR ((payload_storage = 'fanout_shared'::text) AND (payload IS NULL)))),
    CONSTRAINT user_sync_log_user_sync_sequence_check CHECK ((user_sync_sequence > 0))
);

CREATE TABLE im_v2.user_sync_retention (
    user_id uuid NOT NULL,
    compacted_through_sequence bigint DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT user_sync_retention_compacted_through_sequence_check CHECK ((compacted_through_sequence >= 0))
);

CREATE TABLE im_v2.user_sync_sequences (
    user_id uuid NOT NULL,
    next_sequence bigint NOT NULL,
    CONSTRAINT user_sync_sequences_next_sequence_check CHECK ((next_sequence > 0))
);

ALTER TABLE ONLY im_v2.account_disables
    ADD CONSTRAINT account_disables_operation_id_key UNIQUE (operation_id);

ALTER TABLE ONLY im_v2.account_disables
    ADD CONSTRAINT account_disables_pkey PRIMARY KEY (user_id);

ALTER TABLE ONLY im_v2.account_edge_client_rate_limits
    ADD CONSTRAINT account_edge_client_rate_limits_pkey PRIMARY KEY (client_key);

ALTER TABLE ONLY im_v2.account_password_authentication_audit
    ADD CONSTRAINT account_password_authentication_audit_pkey PRIMARY KEY (event_id);

ALTER TABLE ONLY im_v2.account_password_credentials
    ADD CONSTRAINT account_password_credentials_pkey PRIMARY KEY (account_handle);

ALTER TABLE ONLY im_v2.account_password_credentials
    ADD CONSTRAINT account_password_credentials_user_id_key UNIQUE (user_id);

ALTER TABLE ONLY im_v2.account_password_login_rate_limits
    ADD CONSTRAINT account_password_login_rate_limits_pkey PRIMARY KEY (account_handle);

ALTER TABLE ONLY im_v2.auth_devices
    ADD CONSTRAINT auth_devices_device_id_key UNIQUE (device_id);

ALTER TABLE ONLY im_v2.auth_devices
    ADD CONSTRAINT auth_devices_pkey PRIMARY KEY (user_id, device_id);

ALTER TABLE ONLY im_v2.consumer_inbox
    ADD CONSTRAINT consumer_inbox_pkey PRIMARY KEY (consumer_name, source_event_id, target_user_id, projection_kind);

ALTER TABLE ONLY im_v2.content_review_cases
    ADD CONSTRAINT content_review_cases_pkey PRIMARY KEY (message_id);

ALTER TABLE ONLY im_v2.content_review_decisions
    ADD CONSTRAINT content_review_decisions_pkey PRIMARY KEY (message_id);

ALTER TABLE ONLY im_v2.content_review_findings
    ADD CONSTRAINT content_review_findings_pkey PRIMARY KEY (message_id, category);

ALTER TABLE ONLY im_v2.content_review_jobs
    ADD CONSTRAINT content_review_jobs_pkey PRIMARY KEY (message_id);

ALTER TABLE ONLY im_v2.device_access_tokens
    ADD CONSTRAINT device_access_tokens_pkey PRIMARY KEY (token_hmac);

ALTER TABLE ONLY im_v2.device_credential_operations
    ADD CONSTRAINT device_credential_operations_pkey PRIMARY KEY (device_id, operation_id);

ALTER TABLE ONLY im_v2.device_refresh_sessions
    ADD CONSTRAINT device_refresh_sessions_pkey PRIMARY KEY (device_id);

ALTER TABLE ONLY im_v2.device_registration_rate_limits
    ADD CONSTRAINT device_registration_rate_limits_pkey PRIMARY KEY (user_id);

ALTER TABLE ONLY im_v2.device_revocation_events
    ADD CONSTRAINT device_revocation_events_device_id_key UNIQUE (device_id);

ALTER TABLE ONLY im_v2.device_revocation_events
    ADD CONSTRAINT device_revocation_events_pkey PRIMARY KEY (event_id);

ALTER TABLE ONLY im_v2.device_session_operations
    ADD CONSTRAINT device_session_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.device_snapshot_resets
    ADD CONSTRAINT device_snapshot_resets_pkey PRIMARY KEY (user_id, device_id, reset_generation);

ALTER TABLE ONLY im_v2.device_snapshot_resets
    ADD CONSTRAINT device_snapshot_resets_snapshot_id_device_id_reset_generati_key UNIQUE (snapshot_id, device_id, reset_generation);

ALTER TABLE ONLY im_v2.device_sync_cursors
    ADD CONSTRAINT device_sync_cursors_pkey PRIMARY KEY (user_id, device_id);

ALTER TABLE ONLY im_v2.direct_message_denials
    ADD CONSTRAINT direct_message_denials_pkey PRIMARY KEY (sender_user_id, client_message_id);

ALTER TABLE ONLY im_v2.direct_message_denials
    ADD CONSTRAINT direct_message_denials_room_id_timeline_sequence_key UNIQUE (room_id, timeline_sequence);

ALTER TABLE ONLY im_v2.direct_message_denials
    ADD CONSTRAINT direct_message_denials_source_event_id_key UNIQUE (source_event_id);

ALTER TABLE ONLY im_v2.direct_room_operations
    ADD CONSTRAINT direct_room_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.direct_room_pairs
    ADD CONSTRAINT direct_room_pairs_pkey PRIMARY KEY (lower_user_id, higher_user_id);

ALTER TABLE ONLY im_v2.direct_room_pairs
    ADD CONSTRAINT direct_room_pairs_room_id_key UNIQUE (room_id);

ALTER TABLE ONLY im_v2.durable_work_replay_audit
    ADD CONSTRAINT durable_work_replay_audit_pkey PRIMARY KEY (operation_id);

ALTER TABLE ONLY im_v2.fanout_completion_units
    ADD CONSTRAINT fanout_completion_units_pkey PRIMARY KEY (source_event_id, completion_unit_id);

ALTER TABLE ONLY im_v2.fanout_deliveries
    ADD CONSTRAINT fanout_deliveries_pkey PRIMARY KEY (source_event_id, target_user_id, projection_kind);

ALTER TABLE ONLY im_v2.fanout_plan_targets
    ADD CONSTRAINT fanout_plan_targets_pkey PRIMARY KEY (source_event_id, target_user_id);

ALTER TABLE ONLY im_v2.fanout_plans
    ADD CONSTRAINT fanout_plans_pkey PRIMARY KEY (plan_id);

ALTER TABLE ONLY im_v2.fanout_plans
    ADD CONSTRAINT fanout_plans_source_event_id_key UNIQUE (source_event_id);

ALTER TABLE ONLY im_v2.fanout_sync_payloads
    ADD CONSTRAINT fanout_sync_payloads_pkey PRIMARY KEY (source_event_id, projection_kind);

ALTER TABLE ONLY im_v2.gateway_worker_cursors
    ADD CONSTRAINT gateway_worker_cursors_pkey PRIMARY KEY (worker_name, node_id);

ALTER TABLE ONLY im_v2.group_announcement_operations
    ADD CONSTRAINT group_announcement_operations_event_id_key UNIQUE (event_id);

ALTER TABLE ONLY im_v2.group_announcement_operations
    ADD CONSTRAINT group_announcement_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.group_announcement_operations
    ADD CONSTRAINT group_announcement_operations_plan_id_key UNIQUE (plan_id);

ALTER TABLE ONLY im_v2.group_announcements
    ADD CONSTRAINT group_announcements_pkey PRIMARY KEY (room_id);

ALTER TABLE ONLY im_v2.group_event_wake_outbox
    ADD CONSTRAINT group_event_wake_outbox_pkey PRIMARY KEY (room_id);

ALTER TABLE ONLY im_v2.group_permission_operations
    ADD CONSTRAINT group_permission_operations_event_id_key UNIQUE (event_id);

ALTER TABLE ONLY im_v2.group_permission_operations
    ADD CONSTRAINT group_permission_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.group_permission_operations
    ADD CONSTRAINT group_permission_operations_plan_id_key UNIQUE (plan_id);

ALTER TABLE ONLY im_v2.group_role_operations
    ADD CONSTRAINT group_role_operations_event_id_key UNIQUE (event_id);

ALTER TABLE ONLY im_v2.group_role_operations
    ADD CONSTRAINT group_role_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.group_role_operations
    ADD CONSTRAINT group_role_operations_plan_id_key UNIQUE (plan_id);

ALTER TABLE ONLY im_v2.group_role_permissions
    ADD CONSTRAINT group_role_permissions_pkey PRIMARY KEY (room_id, role, permission);

ALTER TABLE ONLY im_v2.group_room_creation_draft_members
    ADD CONSTRAINT group_room_creation_draft_members_pkey PRIMARY KEY (actor_user_id, operation_id, user_id);

ALTER TABLE ONLY im_v2.group_room_creation_drafts
    ADD CONSTRAINT group_room_creation_drafts_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.group_room_creation_drafts
    ADD CONSTRAINT group_room_creation_drafts_room_id_key UNIQUE (room_id);

ALTER TABLE ONLY im_v2.group_room_operations
    ADD CONSTRAINT group_room_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.group_room_operations
    ADD CONSTRAINT group_room_operations_room_id_key UNIQUE (room_id);

ALTER TABLE ONLY im_v2.group_rooms
    ADD CONSTRAINT group_rooms_pkey PRIMARY KEY (room_id);

ALTER TABLE ONLY im_v2.media_download_grants
    ADD CONSTRAINT media_download_grants_pkey PRIMARY KEY (download_session_id);

ALTER TABLE ONLY im_v2.media_objects
    ADD CONSTRAINT media_objects_pkey PRIMARY KEY (media_id);

ALTER TABLE ONLY im_v2.media_objects
    ADD CONSTRAINT media_objects_upload_session_id_key UNIQUE (upload_session_id);

ALTER TABLE ONLY im_v2.media_purge_outbox
    ADD CONSTRAINT media_purge_outbox_pkey PRIMARY KEY (media_id);

ALTER TABLE ONLY im_v2.media_scan_outbox
    ADD CONSTRAINT media_scan_outbox_pkey PRIMARY KEY (media_id);

ALTER TABLE ONLY im_v2.media_upload_grants
    ADD CONSTRAINT media_upload_grants_pkey PRIMARY KEY (upload_session_id);

ALTER TABLE ONLY im_v2.media_upload_operations
    ADD CONSTRAINT media_upload_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.media_upload_operations
    ADD CONSTRAINT media_upload_operations_upload_session_id_key UNIQUE (upload_session_id);

ALTER TABLE ONLY im_v2.message_edit_operations
    ADD CONSTRAINT message_edit_operations_event_id_key UNIQUE (event_id);

ALTER TABLE ONLY im_v2.message_edit_operations
    ADD CONSTRAINT message_edit_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.message_edit_operations
    ADD CONSTRAINT message_edit_operations_plan_id_key UNIQUE (plan_id);

ALTER TABLE ONLY im_v2.message_forward_operations
    ADD CONSTRAINT message_forward_operations_actor_user_id_target_client_mess_key UNIQUE (actor_user_id, target_client_message_id);

ALTER TABLE ONLY im_v2.message_forward_operations
    ADD CONSTRAINT message_forward_operations_pkey PRIMARY KEY (actor_user_id, operation_id, source_message_id, target_room_id);

ALTER TABLE ONLY im_v2.message_media_references
    ADD CONSTRAINT message_media_references_message_id_ordinal_key UNIQUE (message_id, ordinal);

ALTER TABLE ONLY im_v2.message_media_references
    ADD CONSTRAINT message_media_references_pkey PRIMARY KEY (message_id, media_id);

ALTER TABLE ONLY im_v2.message_mentions
    ADD CONSTRAINT message_mentions_pkey PRIMARY KEY (message_id, ordinal);

ALTER TABLE ONLY im_v2.message_projection_states
    ADD CONSTRAINT message_projection_states_message_revision_key UNIQUE (message_id, message_revision, variant_key);

ALTER TABLE ONLY im_v2.message_projection_states
    ADD CONSTRAINT message_projection_states_pkey PRIMARY KEY (state_id);

ALTER TABLE ONLY im_v2.message_projection_states
    ADD CONSTRAINT message_projection_states_state_event_key UNIQUE (state_event_id, variant_key);

ALTER TABLE ONLY im_v2.message_projection_states
    ADD CONSTRAINT message_projection_states_state_room_key UNIQUE (state_id, room_id);

ALTER TABLE ONLY im_v2.message_reaction_operations
    ADD CONSTRAINT message_reaction_operations_event_id_key UNIQUE (event_id);

ALTER TABLE ONLY im_v2.message_reaction_operations
    ADD CONSTRAINT message_reaction_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.message_reaction_operations
    ADD CONSTRAINT message_reaction_operations_plan_id_key UNIQUE (plan_id);

ALTER TABLE ONLY im_v2.message_reactions
    ADD CONSTRAINT message_reactions_pkey PRIMARY KEY (message_id, actor_user_id, reaction);

ALTER TABLE ONLY im_v2.message_withdrawal_operations
    ADD CONSTRAINT message_withdrawal_operations_event_id_key UNIQUE (event_id);

ALTER TABLE ONLY im_v2.message_withdrawal_operations
    ADD CONSTRAINT message_withdrawal_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.message_withdrawal_operations
    ADD CONSTRAINT message_withdrawal_operations_plan_id_key UNIQUE (plan_id);

ALTER TABLE ONLY im_v2.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (message_id);

ALTER TABLE ONLY im_v2.messages
    ADD CONSTRAINT messages_room_id_room_sequence_key UNIQUE (room_id, room_sequence);

ALTER TABLE ONLY im_v2.messages
    ADD CONSTRAINT messages_room_timeline_sequence_key UNIQUE (room_id, timeline_sequence);

ALTER TABLE ONLY im_v2.messages
    ADD CONSTRAINT messages_sender_user_id_client_message_id_key UNIQUE (sender_user_id, client_message_id);

ALTER TABLE ONLY im_v2.moderation_audit_entries
    ADD CONSTRAINT moderation_audit_entries_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.moderation_operations
    ADD CONSTRAINT moderation_operations_event_id_key UNIQUE (event_id);

ALTER TABLE ONLY im_v2.moderation_operations
    ADD CONSTRAINT moderation_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.moderation_operations
    ADD CONSTRAINT moderation_operations_plan_id_key UNIQUE (plan_id);

ALTER TABLE ONLY im_v2.public_identity_lookup_rate_limits
    ADD CONSTRAINT public_identity_lookup_rate_limits_pkey PRIMARY KEY (actor_user_id);

ALTER TABLE ONLY im_v2.public_profile_update_operations
    ADD CONSTRAINT public_profile_update_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.public_profile_update_outbox
    ADD CONSTRAINT public_profile_update_outbox_pkey PRIMARY KEY (source_event_id);

ALTER TABLE ONLY im_v2.public_user_profiles
    ADD CONSTRAINT public_user_profiles_pkey PRIMARY KEY (user_id);

ALTER TABLE ONLY im_v2.public_user_profiles
    ADD CONSTRAINT public_user_profiles_public_handle_key UNIQUE (public_handle);

ALTER TABLE ONLY im_v2.push_campaigns
    ADD CONSTRAINT push_campaigns_pkey PRIMARY KEY (campaign_id);

ALTER TABLE ONLY im_v2.push_device_budgets
    ADD CONSTRAINT push_device_budgets_pkey PRIMARY KEY (device_id, campaign_id, window_started_at);

ALTER TABLE ONLY im_v2.push_device_endpoints
    ADD CONSTRAINT push_device_endpoints_pkey PRIMARY KEY (device_id, provider);

ALTER TABLE ONLY im_v2.push_wake_outbox
    ADD CONSTRAINT push_wake_outbox_pkey PRIMARY KEY (dispatch_id);

ALTER TABLE ONLY im_v2.read_receipt_operations
    ADD CONSTRAINT read_receipt_operations_pkey PRIMARY KEY (user_id, operation_id);

ALTER TABLE ONLY im_v2.read_receipt_preference_operations
    ADD CONSTRAINT read_receipt_preference_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.read_receipt_preference_propagation_outbox
    ADD CONSTRAINT read_receipt_preference_propagation_outbox_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.revoked_device_projection_tombstones
    ADD CONSTRAINT revoked_device_projection_tombstones_pkey PRIMARY KEY (user_id, device_id);

ALTER TABLE ONLY im_v2.room_admission
    ADD CONSTRAINT room_admission_pkey PRIMARY KEY (room_id);

ALTER TABLE ONLY im_v2.room_events
    ADD CONSTRAINT room_events_pkey PRIMARY KEY (event_id);

ALTER TABLE ONLY im_v2.room_events
    ADD CONSTRAINT room_events_room_id_room_sequence_event_type_key UNIQUE (room_id, room_sequence, event_type);

ALTER TABLE ONLY im_v2.room_member_mutes
    ADD CONSTRAINT room_member_mutes_actor_user_id_operation_id_key UNIQUE (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.room_member_mutes
    ADD CONSTRAINT room_member_mutes_pkey PRIMARY KEY (room_id, user_id);

ALTER TABLE ONLY im_v2.room_member_nickname_operations
    ADD CONSTRAINT room_member_nickname_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.room_member_nicknames
    ADD CONSTRAINT room_member_nicknames_pkey PRIMARY KEY (room_id, user_id);

ALTER TABLE ONLY im_v2.room_membership_operations
    ADD CONSTRAINT room_membership_operations_event_id_key UNIQUE (event_id);

ALTER TABLE ONLY im_v2.room_membership_operations
    ADD CONSTRAINT room_membership_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.room_membership_operations
    ADD CONSTRAINT room_membership_operations_plan_id_key UNIQUE (plan_id);

ALTER TABLE ONLY im_v2.room_memberships
    ADD CONSTRAINT room_memberships_pkey PRIMARY KEY (room_id, user_id, joined_revision);

ALTER TABLE ONLY im_v2.room_outbox
    ADD CONSTRAINT room_outbox_pkey PRIMARY KEY (source_event_id);

ALTER TABLE ONLY im_v2.room_outbox
    ADD CONSTRAINT room_outbox_plan_id_key UNIQUE (plan_id);

ALTER TABLE ONLY im_v2.room_pinned_message_operations
    ADD CONSTRAINT room_pinned_message_operations_event_id_key UNIQUE (event_id);

ALTER TABLE ONLY im_v2.room_pinned_message_operations
    ADD CONSTRAINT room_pinned_message_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.room_pinned_message_operations
    ADD CONSTRAINT room_pinned_message_operations_plan_id_key UNIQUE (plan_id);

ALTER TABLE ONLY im_v2.room_pinned_messages
    ADD CONSTRAINT room_pinned_messages_pkey PRIMARY KEY (room_id, message_id);

ALTER TABLE ONLY im_v2.room_read_receipts
    ADD CONSTRAINT room_read_receipts_pkey PRIMARY KEY (room_id, user_id);

ALTER TABLE ONLY im_v2.room_timeline_activities
    ADD CONSTRAINT room_timeline_activities_pkey PRIMARY KEY (source_event_id);

ALTER TABLE ONLY im_v2.room_timeline_activities
    ADD CONSTRAINT room_timeline_activities_room_id_timeline_sequence_key UNIQUE (room_id, timeline_sequence);

ALTER TABLE ONLY im_v2.rooms
    ADD CONSTRAINT rooms_pkey PRIMARY KEY (room_id);

ALTER TABLE ONLY im_v2.schema_contract
    ADD CONSTRAINT schema_contract_pkey PRIMARY KEY (schema_id);

ALTER TABLE ONLY im_v2.shard_admission_pools
    ADD CONSTRAINT shard_admission_pools_lease_id_generation_key UNIQUE (lease_id, generation);

ALTER TABLE ONLY im_v2.shard_admission_pools
    ADD CONSTRAINT shard_admission_pools_pkey PRIMARY KEY (room_shard_id, capacity_profile_id);

ALTER TABLE ONLY im_v2.special_account_message_audit
    ADD CONSTRAINT special_account_message_audit_pkey PRIMARY KEY (message_id);

ALTER TABLE ONLY im_v2.special_account_message_operations
    ADD CONSTRAINT special_account_message_operations_pkey PRIMARY KEY (account_user_id, operation_id);

ALTER TABLE ONLY im_v2.special_accounts
    ADD CONSTRAINT special_accounts_pkey PRIMARY KEY (account_user_id);

ALTER TABLE ONLY im_v2.special_accounts
    ADD CONSTRAINT special_accounts_stable_key_key UNIQUE (stable_key);

ALTER TABLE ONLY im_v2.stranger_message_preference_operations
    ADD CONSTRAINT stranger_message_preference_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.stranger_message_windows
    ADD CONSTRAINT stranger_message_windows_pkey PRIMARY KEY (sender_user_id, recipient_user_id);

ALTER TABLE ONLY im_v2.support_conversation_sessions
    ADD CONSTRAINT support_conversation_sessions_pkey PRIMARY KEY (room_id);

ALTER TABLE ONLY im_v2.sync_receipts
    ADD CONSTRAINT sync_receipts_pkey PRIMARY KEY (receipt);

ALTER TABLE ONLY im_v2.sync_snapshot_artifacts
    ADD CONSTRAINT sync_snapshot_artifacts_pkey PRIMARY KEY (snapshot_id);

ALTER TABLE ONLY im_v2.sync_snapshot_pages
    ADD CONSTRAINT sync_snapshot_pages_pkey PRIMARY KEY (snapshot_id, page_index);

ALTER TABLE ONLY im_v2.sync_snapshot_pages
    ADD CONSTRAINT sync_snapshot_pages_snapshot_id_last_projection_kind_last_e_key UNIQUE (snapshot_id, last_projection_kind, last_entity_key);

ALTER TABLE ONLY im_v2.sync_tokens
    ADD CONSTRAINT sync_tokens_pkey PRIMARY KEY (token);

ALTER TABLE ONLY im_v2.user_add_preference_operations
    ADD CONSTRAINT user_add_preference_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.user_add_preferences
    ADD CONSTRAINT user_add_preferences_pkey PRIMARY KEY (user_id);

ALTER TABLE ONLY im_v2.user_block_operations
    ADD CONSTRAINT user_block_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.user_blocks
    ADD CONSTRAINT user_blocks_pkey PRIMARY KEY (blocker_user_id, blocked_user_id);

ALTER TABLE ONLY im_v2.user_contact_alias_operations
    ADD CONSTRAINT user_contact_alias_operations_pkey PRIMARY KEY (owner_user_id, operation_id);

ALTER TABLE ONLY im_v2.user_contact_aliases
    ADD CONSTRAINT user_contact_aliases_pkey PRIMARY KEY (owner_user_id, target_user_id);

ALTER TABLE ONLY im_v2.user_live_activity_preference_operations
    ADD CONSTRAINT user_live_activity_preference_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.user_live_activity_preferences
    ADD CONSTRAINT user_live_activity_preferences_pkey PRIMARY KEY (user_id);

ALTER TABLE ONLY im_v2.user_live_presence_leases
    ADD CONSTRAINT user_live_presence_leases_pkey PRIMARY KEY (connection_id);

ALTER TABLE ONLY im_v2.user_message_favorite_operations
    ADD CONSTRAINT user_message_favorite_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.user_message_favorites
    ADD CONSTRAINT user_message_favorites_pkey PRIMARY KEY (user_id, message_id);

ALTER TABLE ONLY im_v2.user_projection_checkpoints
    ADD CONSTRAINT user_projection_checkpoints_pkey PRIMARY KEY (user_id);

ALTER TABLE ONLY im_v2.user_projection_effects
    ADD CONSTRAINT user_projection_effects_pkey PRIMARY KEY (user_id, source_event_id, projection_kind);

ALTER TABLE ONLY im_v2.user_projection_versions
    ADD CONSTRAINT user_projection_versions_pkey PRIMARY KEY (user_id, projection_kind, entity_key, valid_from_sequence);

ALTER TABLE ONLY im_v2.user_read_receipt_preferences
    ADD CONSTRAINT user_read_receipt_preferences_pkey PRIMARY KEY (user_id);

ALTER TABLE ONLY im_v2.user_relationship_operations
    ADD CONSTRAINT user_relationship_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.user_relationships
    ADD CONSTRAINT user_relationships_pkey PRIMARY KEY (lower_user_id, higher_user_id);

ALTER TABLE ONLY im_v2.user_room_preference_operations
    ADD CONSTRAINT user_room_preference_operations_pkey PRIMARY KEY (actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.user_room_preferences
    ADD CONSTRAINT user_room_preferences_pkey PRIMARY KEY (user_id, room_id);

ALTER TABLE ONLY im_v2.user_shard_migrations
    ADD CONSTRAINT user_shard_migrations_cutover_operation_id_key UNIQUE (cutover_operation_id);

ALTER TABLE ONLY im_v2.user_shard_migrations
    ADD CONSTRAINT user_shard_migrations_pkey PRIMARY KEY (migration_id);

ALTER TABLE ONLY im_v2.user_shard_migrations
    ADD CONSTRAINT user_shard_migrations_user_id_key UNIQUE (user_id);

ALTER TABLE ONLY im_v2.user_shard_route_operations
    ADD CONSTRAINT user_shard_route_operations_pkey PRIMARY KEY (operation_id);

ALTER TABLE ONLY im_v2.user_shard_route_overrides
    ADD CONSTRAINT user_shard_route_overrides_pkey PRIMARY KEY (user_id);

ALTER TABLE ONLY im_v2.user_shard_router_configuration
    ADD CONSTRAINT user_shard_router_configuration_pkey PRIMARY KEY (configuration_key);

ALTER TABLE ONLY im_v2.user_stranger_message_preferences
    ADD CONSTRAINT user_stranger_message_preferences_pkey PRIMARY KEY (user_id);

ALTER TABLE ONLY im_v2.user_sync_log
    ADD CONSTRAINT user_sync_log_pkey PRIMARY KEY (user_id, user_sync_sequence);

ALTER TABLE ONLY im_v2.user_sync_retention
    ADD CONSTRAINT user_sync_retention_pkey PRIMARY KEY (user_id);

ALTER TABLE ONLY im_v2.user_sync_sequences
    ADD CONSTRAINT user_sync_sequences_pkey PRIMARY KEY (user_id);

CREATE INDEX account_edge_client_rate_limits_updated_at_idx ON im_v2.account_edge_client_rate_limits USING btree (updated_at);

CREATE INDEX account_password_authentication_audit_device_occurred_idx ON im_v2.account_password_authentication_audit USING btree (device_id, occurred_at DESC);

CREATE INDEX account_password_authentication_audit_user_occurred_idx ON im_v2.account_password_authentication_audit USING btree (user_id, occurred_at DESC) WHERE (user_id IS NOT NULL);

CREATE INDEX account_password_login_rate_limits_blocked_until_idx ON im_v2.account_password_login_rate_limits USING btree (blocked_until) WHERE (blocked_until IS NOT NULL);

CREATE INDEX auth_devices_active_sessions_idx ON im_v2.auth_devices USING btree (user_id, last_active_at DESC, device_id) WHERE (revoked_at IS NULL);

CREATE INDEX auth_devices_revoked_cleanup_idx ON im_v2.auth_devices USING btree (revoked_at, user_id, device_id) WHERE (revoked_at IS NOT NULL);

CREATE INDEX consumer_inbox_compaction_result_idx ON im_v2.consumer_inbox USING btree (target_user_id, user_sync_sequence, source_event_id, projection_kind) WHERE ((consumer_name = 'v2-fanout-delivery'::text) AND (user_sync_sequence IS NOT NULL));

CREATE INDEX consumer_inbox_source_event_idx ON im_v2.consumer_inbox USING btree (source_event_id, consumer_name, target_user_id, projection_kind);

CREATE INDEX content_review_jobs_claim_idx ON im_v2.content_review_jobs USING btree (state, next_attempt_at, lease_expires_at, created_at, message_id);

CREATE INDEX content_review_jobs_completed_cleanup_idx ON im_v2.content_review_jobs USING btree (completed_at, message_id) WHERE (state = ANY (ARRAY['completed'::text, 'superseded'::text]));

CREATE INDEX device_access_tokens_active_idx ON im_v2.device_access_tokens USING btree (device_id, expires_at) WHERE (revoked_at IS NULL);

CREATE INDEX device_credential_operations_expiry_idx ON im_v2.device_credential_operations USING btree (replay_expires_at);

CREATE INDEX device_credential_operations_replay_idx ON im_v2.device_credential_operations USING btree (device_id, replay_expires_at);

CREATE UNIQUE INDEX device_refresh_sessions_active_refresh_hmac_idx ON im_v2.device_refresh_sessions USING btree (refresh_hmac) WHERE (revoked_at IS NULL);

CREATE INDEX device_session_operations_cleanup_idx ON im_v2.device_session_operations USING btree (created_at);

CREATE INDEX device_snapshot_resets_cleanup_idx ON im_v2.device_snapshot_resets USING btree (state, expires_at, user_id, device_id);

CREATE INDEX device_snapshot_resets_snapshot_idx ON im_v2.device_snapshot_resets USING btree (snapshot_id, state);

CREATE INDEX direct_room_operations_cleanup_idx ON im_v2.direct_room_operations USING btree (created_at);

CREATE INDEX direct_room_pairs_higher_user_idx ON im_v2.direct_room_pairs USING btree (higher_user_id, room_id, lower_user_id);

CREATE INDEX durable_work_replay_audit_requested_at_idx ON im_v2.durable_work_replay_audit USING btree (requested_at DESC);

CREATE INDEX fanout_completion_units_released_cleanup_idx ON im_v2.fanout_completion_units USING btree (released_at, source_event_id, completion_unit_id) WHERE (state = 'released'::text);

CREATE INDEX fanout_completion_units_terminal_release_idx ON im_v2.fanout_completion_units USING btree (source_event_id, completion_unit_id) INCLUDE (target_count) WHERE (state = 'terminal'::text);

CREATE INDEX fanout_deliveries_expired_lease_claim_idx ON im_v2.fanout_deliveries USING btree (target_shard_bucket, lease_expires_at, source_event_id, target_user_id, projection_kind) WHERE ((state = 'pending'::text) AND (lease_expires_at IS NOT NULL));

CREATE INDEX fanout_deliveries_fresh_claim_idx ON im_v2.fanout_deliveries USING btree (target_shard_bucket, source_event_id, target_user_id, projection_kind) WHERE ((state = 'pending'::text) AND (next_attempt_at IS NULL) AND (lease_expires_at IS NULL));

CREATE INDEX fanout_deliveries_fresh_direct_source_lane_claim_idx ON im_v2.fanout_deliveries USING btree (target_shard_bucket, mod((hashtextextended((source_event_id)::text, (0)::bigint) & '9223372036854775807'::bigint), (8)::bigint), source_event_id, target_user_id, projection_kind) WHERE (fresh_direct_eligible AND (state = 'pending'::text) AND (next_attempt_at IS NULL) AND (lease_expires_at IS NULL));

CREATE INDEX fanout_deliveries_fresh_generic_target_lane_claim_idx ON im_v2.fanout_deliveries USING btree (target_shard_bucket, mod((hashtextextended((target_user_id)::text, (0)::bigint) & '9223372036854775807'::bigint), (8)::bigint), source_event_id, target_user_id, projection_kind) WHERE ((NOT fresh_direct_eligible) AND (state = 'pending'::text) AND (next_attempt_at IS NULL) AND (lease_expires_at IS NULL));

CREATE INDEX fanout_deliveries_retry_due_claim_idx ON im_v2.fanout_deliveries USING btree (target_shard_bucket, next_attempt_at, source_event_id, target_user_id, projection_kind) WHERE ((state = 'pending'::text) AND (next_attempt_at IS NOT NULL) AND (lease_expires_at IS NULL));

CREATE INDEX fanout_deliveries_terminal_source_idx ON im_v2.fanout_deliveries USING btree (source_event_id, target_user_id, projection_kind) WHERE (state = 'terminal'::text);

CREATE INDEX fanout_plans_pending_idx ON im_v2.fanout_plans USING btree (state, created_at) WHERE (state <> 'terminal'::text);

CREATE INDEX fanout_plans_terminal_cleanup_idx ON im_v2.fanout_plans USING btree (terminal_at, source_event_id) WHERE (state = 'terminal'::text);

CREATE INDEX fanout_sync_payloads_message_state_idx ON im_v2.fanout_sync_payloads USING btree (message_state_id) WHERE (message_state_id IS NOT NULL);

CREATE INDEX group_announcement_operations_cleanup_idx ON im_v2.group_announcement_operations USING btree (created_at);

CREATE INDEX group_event_wake_outbox_claim_idx ON im_v2.group_event_wake_outbox USING btree (next_attempt_at, updated_at) WHERE (state = 'pending'::text);

CREATE INDEX group_permission_operations_cleanup_idx ON im_v2.group_permission_operations USING btree (created_at);

CREATE INDEX group_role_operations_cleanup_idx ON im_v2.group_role_operations USING btree (created_at);

CREATE INDEX group_room_creation_drafts_actor_state_idx ON im_v2.group_room_creation_drafts USING btree (actor_user_id, state, expires_at);

CREATE INDEX group_room_creation_drafts_expiry_idx ON im_v2.group_room_creation_drafts USING btree (state, expires_at);

CREATE INDEX group_room_creation_drafts_finalizing_recovery_idx ON im_v2.group_room_creation_drafts USING btree (updated_at) WHERE (state = 'finalizing'::text);

CREATE INDEX group_room_operations_cleanup_idx ON im_v2.group_room_operations USING btree (created_at);

CREATE INDEX media_download_grants_claim_idx ON im_v2.media_download_grants USING btree (state, lease_expires_at, expires_at) WHERE (state <> 'consumed'::text);

CREATE INDEX media_download_grants_expiry_idx ON im_v2.media_download_grants USING btree (expires_at);

CREATE INDEX media_objects_owner_state_idx ON im_v2.media_objects USING btree (owner_user_id, state, expires_at);

CREATE INDEX media_purge_outbox_claim_idx ON im_v2.media_purge_outbox USING btree (state, next_attempt_at, lease_expires_at, created_at) WHERE (state = ANY (ARRAY['pending'::text, 'claimed'::text]));

CREATE INDEX media_purge_outbox_completed_cleanup_idx ON im_v2.media_purge_outbox USING btree (completed_at, media_id) WHERE (state = 'completed'::text);

CREATE INDEX media_scan_outbox_claim_idx ON im_v2.media_scan_outbox USING btree (state, next_attempt_at, lease_expires_at, created_at) WHERE (state = ANY (ARRAY['pending'::text, 'claimed'::text]));

CREATE INDEX media_scan_outbox_completed_cleanup_idx ON im_v2.media_scan_outbox USING btree (completed_at, media_id) WHERE (state = 'completed'::text);

CREATE INDEX media_upload_grants_claim_idx ON im_v2.media_upload_grants USING btree (state, lease_expires_at, expires_at) WHERE (state <> 'consumed'::text);

CREATE INDEX media_upload_operations_cleanup_idx ON im_v2.media_upload_operations USING btree (created_at);

CREATE INDEX message_edit_operations_cleanup_idx ON im_v2.message_edit_operations USING btree (created_at);

CREATE INDEX message_forward_operations_cleanup_idx ON im_v2.message_forward_operations USING btree (created_at);

CREATE UNIQUE INDEX message_mentions_one_everyone_idx ON im_v2.message_mentions USING btree (message_id) WHERE (mention_kind = 'everyone'::text);

CREATE UNIQUE INDEX message_mentions_unique_user_idx ON im_v2.message_mentions USING btree (message_id, mentioned_user_id) WHERE (mentioned_user_id IS NOT NULL);

CREATE INDEX message_projection_states_gc_idx ON im_v2.message_projection_states USING btree (created_at, state_id);

CREATE INDEX message_projection_states_inline_accepted_idx ON im_v2.message_projection_states USING btree (state_event_id, state_id) WHERE ((payload_storage = 'inline'::text) AND (message_revision = 1) AND (variant_key = 0) AND (state_event_id IS NOT NULL));

CREATE INDEX message_reaction_operations_cleanup_idx ON im_v2.message_reaction_operations USING btree (created_at);

CREATE INDEX message_withdrawal_operations_cleanup_idx ON im_v2.message_withdrawal_operations USING btree (created_at);

CREATE INDEX messages_forwarded_from_idx ON im_v2.messages USING btree (forwarded_from_message_id) WHERE (forwarded_from_message_id IS NOT NULL);

CREATE INDEX messages_reply_to_message_idx ON im_v2.messages USING btree (reply_to_message_id) WHERE (reply_to_message_id IS NOT NULL);

CREATE INDEX messages_room_sender_idx ON im_v2.messages USING btree (room_id, sender_user_id);

CREATE INDEX moderation_audit_retention_idx ON im_v2.moderation_audit_entries USING btree (retain_until);

CREATE INDEX moderation_operations_cleanup_idx ON im_v2.moderation_operations USING btree (created_at);

CREATE INDEX public_profile_update_operations_cleanup_idx ON im_v2.public_profile_update_operations USING btree (created_at);

CREATE INDEX public_profile_update_outbox_claim_idx ON im_v2.public_profile_update_outbox USING btree (state, lease_expires_at, created_at) WHERE (state <> 'completed'::text);

CREATE INDEX public_profile_update_outbox_completed_cleanup_idx ON im_v2.public_profile_update_outbox USING btree (completed_at, source_event_id) WHERE (state = 'completed'::text);

CREATE INDEX public_user_profiles_active_avatar_idx ON im_v2.public_user_profiles USING btree (avatar_media_id) WHERE (avatar_media_id IS NOT NULL);

CREATE INDEX public_user_profiles_active_handle_idx ON im_v2.public_user_profiles USING btree (public_handle) WHERE (state = 'active'::text);

CREATE INDEX push_device_endpoints_active_idx ON im_v2.push_device_endpoints USING btree (device_id, updated_at DESC) WHERE (disabled_at IS NULL);

CREATE INDEX push_wake_outbox_claim_idx ON im_v2.push_wake_outbox USING btree (state, lease_expires_at, created_at) WHERE (state = ANY (ARRAY['pending'::text, 'claimed'::text]));

CREATE INDEX push_wake_outbox_reclaim_idx ON im_v2.push_wake_outbox USING btree (lease_expires_at, created_at) WHERE (state = 'claimed'::text);

CREATE INDEX push_wake_outbox_terminal_cleanup_idx ON im_v2.push_wake_outbox USING btree (created_at, dispatch_id) WHERE (state = ANY (ARRAY['sent'::text, 'suppressed'::text]));

CREATE INDEX read_receipt_operations_cleanup_idx ON im_v2.read_receipt_operations USING btree (recorded_at);

CREATE INDEX read_receipt_preference_operations_cleanup_idx ON im_v2.read_receipt_preference_operations USING btree (updated_at);

CREATE INDEX read_receipt_preference_propagation_claim_idx ON im_v2.read_receipt_preference_propagation_outbox USING btree (state, next_attempt_at, lease_expires_at, created_at, actor_user_id, operation_id) WHERE (state = ANY (ARRAY['pending'::text, 'claimed'::text]));

CREATE INDEX read_receipt_preference_propagation_completed_cleanup_idx ON im_v2.read_receipt_preference_propagation_outbox USING btree (completed_at, actor_user_id, operation_id) WHERE (state = 'completed'::text);

CREATE INDEX room_member_mutes_active_idx ON im_v2.room_member_mutes USING btree (room_id, user_id, mute_until);

CREATE INDEX room_member_nickname_operations_cleanup_idx ON im_v2.room_member_nickname_operations USING btree (created_at);

CREATE INDEX room_membership_operations_cleanup_idx ON im_v2.room_membership_operations USING btree (created_at);

CREATE INDEX room_memberships_current_user_rooms_idx ON im_v2.room_memberships USING btree (user_id, room_id, joined_revision DESC) INCLUDE (role) WHERE (left_revision IS NULL);

CREATE INDEX room_memberships_eligible_at_revision_idx ON im_v2.room_memberships USING btree (room_id, joined_revision, left_revision, user_id);

CREATE INDEX room_outbox_claim_idx ON im_v2.room_outbox USING btree (state, lease_expires_at, created_at) WHERE (state <> 'terminal'::text);

CREATE INDEX room_outbox_retry_claim_idx ON im_v2.room_outbox USING btree (next_attempt_at, created_at) WHERE (state = 'pending'::text);

CREATE INDEX room_outbox_terminal_cleanup_idx ON im_v2.room_outbox USING btree (terminal_at, source_event_id) WHERE (state = 'terminal'::text);

CREATE INDEX room_pinned_message_operations_cleanup_idx ON im_v2.room_pinned_message_operations USING btree (created_at);

CREATE INDEX room_pinned_messages_order_idx ON im_v2.room_pinned_messages USING btree (room_id, pinned_at DESC, message_id);

CREATE INDEX room_read_receipts_sequence_page_idx ON im_v2.room_read_receipts USING btree (room_id, read_through_room_sequence DESC, user_id DESC);

CREATE INDEX room_timeline_activities_recipient_order_idx ON im_v2.room_timeline_activities USING btree (recipient_user_id, room_id, timeline_sequence);

CREATE INDEX special_account_message_audit_account_created_idx ON im_v2.special_account_message_audit USING btree (account_user_id, created_at DESC);

CREATE INDEX special_account_message_operations_cleanup_idx ON im_v2.special_account_message_operations USING btree (created_at);

CREATE INDEX stranger_message_preference_operations_cleanup_idx ON im_v2.stranger_message_preference_operations USING btree (updated_at);

CREATE INDEX support_conversation_sessions_customer_idx ON im_v2.support_conversation_sessions USING btree (customer_user_id, last_activity_at DESC);

CREATE INDEX sync_receipts_compaction_protection_idx ON im_v2.sync_receipts USING btree (user_id, expires_at, first_sequence);

CREATE INDEX sync_receipts_expiry_idx ON im_v2.sync_receipts USING btree (expires_at, receipt);

CREATE INDEX sync_receipts_scope_idx ON im_v2.sync_receipts USING btree (user_id, device_id, reset_generation, expires_at);

CREATE INDEX sync_snapshot_artifacts_claim_idx ON im_v2.sync_snapshot_artifacts USING btree (state, lease_expires_at, created_at, snapshot_id) WHERE (state = 'building'::text);

CREATE INDEX sync_snapshot_artifacts_cleanup_idx ON im_v2.sync_snapshot_artifacts USING btree (state, expires_at, snapshot_id);

CREATE INDEX sync_snapshot_artifacts_reusable_idx ON im_v2.sync_snapshot_artifacts USING btree (user_id, capability_profile, schema_version, base_user_sync_sequence DESC, created_at DESC) WHERE ((state = ANY (ARRAY['building'::text, 'published'::text])) AND (source_projected_sequence = base_user_sync_sequence));

CREATE INDEX sync_tokens_compaction_protection_idx ON im_v2.sync_tokens USING btree (user_id, expires_at, watermark);

CREATE INDEX sync_tokens_expiry_idx ON im_v2.sync_tokens USING btree (expires_at, token);

CREATE INDEX sync_tokens_scope_idx ON im_v2.sync_tokens USING btree (user_id, device_id, reset_generation, expires_at);

CREATE INDEX user_add_preference_operations_cleanup_idx ON im_v2.user_add_preference_operations USING btree (updated_at);

CREATE INDEX user_block_operations_cleanup_idx ON im_v2.user_block_operations USING btree (updated_at);

CREATE INDEX user_blocks_blocked_blocker_idx ON im_v2.user_blocks USING btree (blocked_user_id, blocker_user_id);

CREATE INDEX user_contact_alias_operations_cleanup_idx ON im_v2.user_contact_alias_operations USING btree (created_at);

CREATE INDEX user_live_activity_preference_operations_cleanup_idx ON im_v2.user_live_activity_preference_operations USING btree (updated_at);

CREATE INDEX user_live_presence_leases_expiry_idx ON im_v2.user_live_presence_leases USING btree (expires_at, connection_id);

CREATE INDEX user_live_presence_leases_lookup_idx ON im_v2.user_live_presence_leases USING btree (user_id, expires_at DESC);

CREATE INDEX user_message_favorite_operations_cleanup_idx ON im_v2.user_message_favorite_operations USING btree (updated_at);

CREATE INDEX user_message_favorites_room_idx ON im_v2.user_message_favorites USING btree (user_id, room_id, created_at DESC, message_id);

CREATE INDEX user_projection_checkpoints_claim_idx ON im_v2.user_projection_checkpoints USING btree (next_attempt_at, updated_at, user_id) WHERE (state = 'ready'::text);

CREATE INDEX user_projection_checkpoints_ready_order_idx ON im_v2.user_projection_checkpoints USING btree (updated_at, user_id) WHERE (state = 'ready'::text);

CREATE INDEX user_projection_effects_cleanup_idx ON im_v2.user_projection_effects USING btree (created_at, user_id, user_sync_sequence, source_event_id);

CREATE INDEX user_projection_effects_direct_capability_idx ON im_v2.user_projection_effects USING btree (user_id, ((payload ->> 'room_id'::text))) WHERE (projection_kind = 'direct_sending_capability'::text);

CREATE INDEX user_projection_effects_direct_room_idx ON im_v2.user_projection_effects USING btree (user_id, ((payload ->> 'room_id'::text))) WHERE (projection_kind = 'direct_room_profile'::text);

CREATE INDEX user_projection_effects_user_sequence_idx ON im_v2.user_projection_effects USING btree (user_id, user_sync_sequence);

CREATE UNIQUE INDEX user_projection_versions_current_idx ON im_v2.user_projection_versions USING btree (user_id, projection_kind, entity_key) WHERE (valid_to_sequence IS NULL);

CREATE INDEX user_projection_versions_current_room_idx ON im_v2.user_projection_versions USING btree (user_id, scope_room_id) WHERE ((valid_to_sequence IS NULL) AND (scope_room_id IS NOT NULL));

CREATE INDEX user_projection_versions_gc_idx ON im_v2.user_projection_versions USING btree (valid_to_sequence, user_id) WHERE (valid_to_sequence IS NOT NULL);

CREATE INDEX user_projection_versions_message_backfill_idx ON im_v2.user_projection_versions USING btree (user_id, entity_key, valid_from_sequence) WHERE ((projection_kind = 'message'::text) AND (message_state_id IS NULL) AND (payload IS NOT NULL));

CREATE INDEX user_projection_versions_message_inline_idx ON im_v2.user_projection_versions USING btree (user_id, entity_key, valid_from_sequence) WHERE ((projection_kind = 'message'::text) AND (payload IS NOT NULL));

CREATE INDEX user_projection_versions_message_state_idx ON im_v2.user_projection_versions USING btree (message_state_id) WHERE (message_state_id IS NOT NULL);

CREATE INDEX user_projection_versions_snapshot_scan_idx ON im_v2.user_projection_versions USING btree (user_id, projection_kind, entity_key, valid_from_sequence, valid_to_sequence);

CREATE INDEX user_relationship_operations_cleanup_idx ON im_v2.user_relationship_operations USING btree (updated_at);

CREATE INDEX user_room_preference_operations_cleanup_idx ON im_v2.user_room_preference_operations USING btree (updated_at);

CREATE INDEX user_room_preferences_visible_idx ON im_v2.user_room_preferences USING btree (user_id, archived_at, pinned_at DESC, updated_at DESC);

CREATE INDEX user_shard_migrations_retention_claim_idx ON im_v2.user_shard_migrations USING btree (phase, retention_until, retention_claim_expires_at) WHERE (phase = 'retention'::text);

CREATE INDEX user_shard_route_operations_user_idx ON im_v2.user_shard_route_operations USING btree (user_id, created_at DESC);

CREATE INDEX user_sync_log_compaction_age_idx ON im_v2.user_sync_log USING btree (user_id, created_at, user_sync_sequence);

CREATE INDEX user_sync_log_direct_projection_room_idx ON im_v2.user_sync_log USING btree (user_id, projection_kind, ((payload ->> 'room_id'::text))) WHERE ((projection_kind = ANY (ARRAY['direct_room_profile'::text, 'direct_sending_capability'::text])) AND (payload IS NOT NULL));

CREATE UNIQUE INDEX user_sync_log_nonfanout_identity_idx ON im_v2.user_sync_log USING btree (user_id, source_event_id, projection_kind) WHERE (projection_kind <> ALL (ARRAY['message'::text, 'membership'::text, 'moderation'::text, 'room'::text]));

CREATE INDEX user_sync_retention_claim_idx ON im_v2.user_sync_retention USING btree (updated_at, user_id);

CREATE TRIGGER room_events_enqueue_hybrid_group_wake AFTER INSERT ON im_v2.room_events FOR EACH ROW EXECUTE FUNCTION im_v2.enqueue_hybrid_group_event_wake();

CREATE TRIGGER room_events_immutable BEFORE DELETE OR UPDATE ON im_v2.room_events FOR EACH ROW EXECUTE FUNCTION im_v2.reject_room_event_mutation();

CREATE TRIGGER rooms_delivery_mode_immutable BEFORE UPDATE OF delivery_mode ON im_v2.rooms FOR EACH ROW EXECUTE FUNCTION im_v2.reject_room_delivery_mode_mutation();

CREATE TRIGGER user_sync_log_projection_effect_v3 AFTER INSERT ON im_v2.user_sync_log FOR EACH ROW EXECUTE FUNCTION im_v2.capture_user_projection_effect_v3();

CREATE TRIGGER user_sync_log_snapshot_v3_projection AFTER INSERT ON im_v2.user_sync_log FOR EACH ROW EXECUTE FUNCTION im_v2.enqueue_user_projection_v3();

ALTER TABLE ONLY im_v2.content_review_cases
    ADD CONSTRAINT content_review_cases_message_id_fkey FOREIGN KEY (message_id) REFERENCES im_v2.messages(message_id) ON DELETE CASCADE;

ALTER TABLE ONLY im_v2.content_review_decisions
    ADD CONSTRAINT content_review_decisions_message_id_fkey FOREIGN KEY (message_id) REFERENCES im_v2.messages(message_id) ON DELETE CASCADE;

ALTER TABLE ONLY im_v2.content_review_findings
    ADD CONSTRAINT content_review_findings_message_id_fkey FOREIGN KEY (message_id) REFERENCES im_v2.messages(message_id) ON DELETE CASCADE;

ALTER TABLE ONLY im_v2.content_review_jobs
    ADD CONSTRAINT content_review_jobs_message_id_fkey FOREIGN KEY (message_id) REFERENCES im_v2.messages(message_id) ON DELETE CASCADE;

ALTER TABLE ONLY im_v2.content_review_jobs
    ADD CONSTRAINT content_review_jobs_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE CASCADE;

ALTER TABLE ONLY im_v2.device_access_tokens
    ADD CONSTRAINT device_access_tokens_user_id_device_id_fkey FOREIGN KEY (user_id, device_id) REFERENCES im_v2.auth_devices(user_id, device_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.device_credential_operations
    ADD CONSTRAINT device_credential_operations_device_id_fkey FOREIGN KEY (device_id) REFERENCES im_v2.auth_devices(device_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.device_refresh_sessions
    ADD CONSTRAINT device_refresh_sessions_user_id_device_id_fkey FOREIGN KEY (user_id, device_id) REFERENCES im_v2.auth_devices(user_id, device_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.device_revocation_events
    ADD CONSTRAINT device_revocation_events_user_id_device_id_fkey FOREIGN KEY (user_id, device_id) REFERENCES im_v2.auth_devices(user_id, device_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.device_snapshot_resets
    ADD CONSTRAINT device_snapshot_resets_snapshot_id_fkey FOREIGN KEY (snapshot_id) REFERENCES im_v2.sync_snapshot_artifacts(snapshot_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.direct_message_denials
    ADD CONSTRAINT direct_message_denials_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.direct_message_denials
    ADD CONSTRAINT direct_message_denials_source_event_id_fkey FOREIGN KEY (source_event_id) REFERENCES im_v2.room_timeline_activities(source_event_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.direct_room_operations
    ADD CONSTRAINT direct_room_operations_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.direct_room_pairs
    ADD CONSTRAINT direct_room_pairs_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.fanout_completion_units
    ADD CONSTRAINT fanout_completion_units_source_event_id_fkey FOREIGN KEY (source_event_id) REFERENCES im_v2.room_events(event_id);

ALTER TABLE ONLY im_v2.fanout_deliveries
    ADD CONSTRAINT fanout_deliveries_source_event_id_completion_unit_id_fkey FOREIGN KEY (source_event_id, completion_unit_id) REFERENCES im_v2.fanout_completion_units(source_event_id, completion_unit_id);

ALTER TABLE ONLY im_v2.fanout_plan_targets
    ADD CONSTRAINT fanout_plan_targets_source_event_id_fkey FOREIGN KEY (source_event_id) REFERENCES im_v2.room_events(event_id);

ALTER TABLE ONLY im_v2.fanout_plans
    ADD CONSTRAINT fanout_plans_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id);

ALTER TABLE ONLY im_v2.fanout_plans
    ADD CONSTRAINT fanout_plans_source_event_id_fkey FOREIGN KEY (source_event_id) REFERENCES im_v2.room_events(event_id);

ALTER TABLE ONLY im_v2.fanout_sync_payloads
    ADD CONSTRAINT fanout_sync_payloads_message_state_id_fkey FOREIGN KEY (message_state_id) REFERENCES im_v2.message_projection_states(state_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.group_announcement_operations
    ADD CONSTRAINT group_announcement_operations_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.group_announcements
    ADD CONSTRAINT group_announcements_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.group_event_wake_outbox
    ADD CONSTRAINT group_event_wake_outbox_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id);

ALTER TABLE ONLY im_v2.group_permission_operations
    ADD CONSTRAINT group_permission_operations_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.group_role_operations
    ADD CONSTRAINT group_role_operations_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.group_role_permissions
    ADD CONSTRAINT group_role_permissions_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.group_room_creation_draft_members
    ADD CONSTRAINT group_room_creation_draft_membe_actor_user_id_operation_id_fkey FOREIGN KEY (actor_user_id, operation_id) REFERENCES im_v2.group_room_creation_drafts(actor_user_id, operation_id) ON DELETE CASCADE;

ALTER TABLE ONLY im_v2.group_room_creation_drafts
    ADD CONSTRAINT group_room_creation_drafts_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.group_room_operations
    ADD CONSTRAINT group_room_operations_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.group_rooms
    ADD CONSTRAINT group_rooms_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.media_download_grants
    ADD CONSTRAINT media_download_grants_media_id_fkey FOREIGN KEY (media_id) REFERENCES im_v2.media_objects(media_id);

ALTER TABLE ONLY im_v2.media_download_grants
    ADD CONSTRAINT media_download_grants_user_id_device_id_fkey FOREIGN KEY (user_id, device_id) REFERENCES im_v2.auth_devices(user_id, device_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.media_purge_outbox
    ADD CONSTRAINT media_purge_outbox_media_id_fkey FOREIGN KEY (media_id) REFERENCES im_v2.media_objects(media_id);

ALTER TABLE ONLY im_v2.media_scan_outbox
    ADD CONSTRAINT media_scan_outbox_media_id_fkey FOREIGN KEY (media_id) REFERENCES im_v2.media_objects(media_id);

ALTER TABLE ONLY im_v2.media_upload_grants
    ADD CONSTRAINT media_upload_grants_media_id_fkey FOREIGN KEY (media_id) REFERENCES im_v2.media_objects(media_id) ON DELETE CASCADE;

ALTER TABLE ONLY im_v2.media_upload_grants
    ADD CONSTRAINT media_upload_grants_upload_session_id_fkey FOREIGN KEY (upload_session_id) REFERENCES im_v2.media_objects(upload_session_id) ON DELETE CASCADE;

ALTER TABLE ONLY im_v2.media_upload_grants
    ADD CONSTRAINT media_upload_grants_user_id_device_id_fkey FOREIGN KEY (user_id, device_id) REFERENCES im_v2.auth_devices(user_id, device_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.media_upload_operations
    ADD CONSTRAINT media_upload_operations_media_id_fkey FOREIGN KEY (media_id) REFERENCES im_v2.media_objects(media_id);

ALTER TABLE ONLY im_v2.media_upload_operations
    ADD CONSTRAINT media_upload_operations_requesting_device_fk FOREIGN KEY (actor_user_id, requesting_device_id) REFERENCES im_v2.auth_devices(user_id, device_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.message_edit_operations
    ADD CONSTRAINT message_edit_operations_message_id_fkey FOREIGN KEY (message_id) REFERENCES im_v2.messages(message_id);

ALTER TABLE ONLY im_v2.message_edit_operations
    ADD CONSTRAINT message_edit_operations_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id);

ALTER TABLE ONLY im_v2.message_forward_operations
    ADD CONSTRAINT message_forward_operations_result_message_id_fkey FOREIGN KEY (result_message_id) REFERENCES im_v2.messages(message_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.message_forward_operations
    ADD CONSTRAINT message_forward_operations_source_message_id_fkey FOREIGN KEY (source_message_id) REFERENCES im_v2.messages(message_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.message_forward_operations
    ADD CONSTRAINT message_forward_operations_target_room_id_fkey FOREIGN KEY (target_room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.message_media_references
    ADD CONSTRAINT message_media_references_media_id_fkey FOREIGN KEY (media_id) REFERENCES im_v2.media_objects(media_id);

ALTER TABLE ONLY im_v2.message_media_references
    ADD CONSTRAINT message_media_references_message_id_fkey FOREIGN KEY (message_id) REFERENCES im_v2.messages(message_id);

ALTER TABLE ONLY im_v2.message_mentions
    ADD CONSTRAINT message_mentions_message_id_fkey FOREIGN KEY (message_id) REFERENCES im_v2.messages(message_id);

ALTER TABLE ONLY im_v2.message_reaction_operations
    ADD CONSTRAINT message_reaction_operations_message_id_fkey FOREIGN KEY (message_id) REFERENCES im_v2.messages(message_id);

ALTER TABLE ONLY im_v2.message_reaction_operations
    ADD CONSTRAINT message_reaction_operations_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id);

ALTER TABLE ONLY im_v2.message_reactions
    ADD CONSTRAINT message_reactions_message_id_fkey FOREIGN KEY (message_id) REFERENCES im_v2.messages(message_id);

ALTER TABLE ONLY im_v2.message_withdrawal_operations
    ADD CONSTRAINT message_withdrawal_operations_message_id_fkey FOREIGN KEY (message_id) REFERENCES im_v2.messages(message_id);

ALTER TABLE ONLY im_v2.message_withdrawal_operations
    ADD CONSTRAINT message_withdrawal_operations_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id);

ALTER TABLE ONLY im_v2.messages
    ADD CONSTRAINT messages_forwarded_from_message_id_fkey FOREIGN KEY (forwarded_from_message_id) REFERENCES im_v2.messages(message_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.messages
    ADD CONSTRAINT messages_reply_to_message_id_fkey FOREIGN KEY (reply_to_message_id) REFERENCES im_v2.messages(message_id);

ALTER TABLE ONLY im_v2.messages
    ADD CONSTRAINT messages_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id);

ALTER TABLE ONLY im_v2.moderation_audit_entries
    ADD CONSTRAINT moderation_audit_entries_actor_user_id_operation_id_fkey FOREIGN KEY (actor_user_id, operation_id) REFERENCES im_v2.moderation_operations(actor_user_id, operation_id);

ALTER TABLE ONLY im_v2.moderation_audit_entries
    ADD CONSTRAINT moderation_audit_entries_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id);

ALTER TABLE ONLY im_v2.moderation_operations
    ADD CONSTRAINT moderation_operations_message_id_fkey FOREIGN KEY (message_id) REFERENCES im_v2.messages(message_id);

ALTER TABLE ONLY im_v2.moderation_operations
    ADD CONSTRAINT moderation_operations_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id);

ALTER TABLE ONLY im_v2.public_user_profiles
    ADD CONSTRAINT public_user_profiles_avatar_media_id_fkey FOREIGN KEY (avatar_media_id) REFERENCES im_v2.media_objects(media_id) ON DELETE SET NULL;

ALTER TABLE ONLY im_v2.push_device_budgets
    ADD CONSTRAINT push_device_budgets_campaign_id_fkey FOREIGN KEY (campaign_id) REFERENCES im_v2.push_campaigns(campaign_id);

ALTER TABLE ONLY im_v2.push_device_endpoints
    ADD CONSTRAINT push_device_endpoints_device_id_fkey FOREIGN KEY (device_id) REFERENCES im_v2.auth_devices(device_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.push_wake_outbox
    ADD CONSTRAINT push_wake_outbox_campaign_id_fkey FOREIGN KEY (campaign_id) REFERENCES im_v2.push_campaigns(campaign_id);

ALTER TABLE ONLY im_v2.push_wake_outbox
    ADD CONSTRAINT push_wake_outbox_source_event_id_fkey FOREIGN KEY (source_event_id) REFERENCES im_v2.room_events(event_id);

ALTER TABLE ONLY im_v2.read_receipt_operations
    ADD CONSTRAINT read_receipt_operations_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id);

ALTER TABLE ONLY im_v2.read_receipt_preference_propagation_outbox
    ADD CONSTRAINT read_receipt_preference_propaga_actor_user_id_operation_id_fkey FOREIGN KEY (actor_user_id, operation_id) REFERENCES im_v2.read_receipt_preference_operations(actor_user_id, operation_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.room_admission
    ADD CONSTRAINT room_admission_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id);

ALTER TABLE ONLY im_v2.room_admission
    ADD CONSTRAINT room_admission_shard_lease_id_shard_lease_generation_fkey FOREIGN KEY (shard_lease_id, shard_lease_generation) REFERENCES im_v2.shard_admission_pools(lease_id, generation) ON UPDATE CASCADE;

ALTER TABLE ONLY im_v2.room_events
    ADD CONSTRAINT room_events_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id);

ALTER TABLE ONLY im_v2.room_member_mutes
    ADD CONSTRAINT room_member_mutes_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.room_member_nicknames
    ADD CONSTRAINT room_member_nicknames_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE CASCADE;

ALTER TABLE ONLY im_v2.room_member_nicknames
    ADD CONSTRAINT room_member_nicknames_user_id_fkey FOREIGN KEY (user_id) REFERENCES im_v2.public_user_profiles(user_id) ON DELETE CASCADE;

ALTER TABLE ONLY im_v2.room_membership_operations
    ADD CONSTRAINT room_membership_operations_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id);

ALTER TABLE ONLY im_v2.room_memberships
    ADD CONSTRAINT room_memberships_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id);

ALTER TABLE ONLY im_v2.room_outbox
    ADD CONSTRAINT room_outbox_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES im_v2.fanout_plans(plan_id);

ALTER TABLE ONLY im_v2.room_outbox
    ADD CONSTRAINT room_outbox_source_event_id_fkey FOREIGN KEY (source_event_id) REFERENCES im_v2.room_events(event_id);

ALTER TABLE ONLY im_v2.room_pinned_message_operations
    ADD CONSTRAINT room_pinned_message_operations_message_id_fkey FOREIGN KEY (message_id) REFERENCES im_v2.messages(message_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.room_pinned_message_operations
    ADD CONSTRAINT room_pinned_message_operations_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.room_pinned_messages
    ADD CONSTRAINT room_pinned_messages_message_id_fkey FOREIGN KEY (message_id) REFERENCES im_v2.messages(message_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.room_pinned_messages
    ADD CONSTRAINT room_pinned_messages_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.room_read_receipts
    ADD CONSTRAINT room_read_receipts_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id);

ALTER TABLE ONLY im_v2.room_timeline_activities
    ADD CONSTRAINT room_timeline_activities_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.special_account_message_audit
    ADD CONSTRAINT special_account_message_audit_account_user_id_fkey FOREIGN KEY (account_user_id) REFERENCES im_v2.special_accounts(account_user_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.special_account_message_audit
    ADD CONSTRAINT special_account_message_audit_message_id_fkey FOREIGN KEY (message_id) REFERENCES im_v2.messages(message_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.special_account_message_audit
    ADD CONSTRAINT special_account_message_audit_support_session_room_id_fkey FOREIGN KEY (support_session_room_id) REFERENCES im_v2.support_conversation_sessions(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.special_account_message_operations
    ADD CONSTRAINT special_account_message_operations_account_user_id_fkey FOREIGN KEY (account_user_id) REFERENCES im_v2.special_accounts(account_user_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.special_account_message_operations
    ADD CONSTRAINT special_account_message_operations_message_id_fkey FOREIGN KEY (message_id) REFERENCES im_v2.messages(message_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.special_account_message_operations
    ADD CONSTRAINT special_account_message_operations_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.special_accounts
    ADD CONSTRAINT special_accounts_account_user_id_fkey FOREIGN KEY (account_user_id) REFERENCES im_v2.public_user_profiles(user_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.support_conversation_sessions
    ADD CONSTRAINT support_conversation_sessions_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.support_conversation_sessions
    ADD CONSTRAINT support_conversation_sessions_support_account_user_id_fkey FOREIGN KEY (support_account_user_id) REFERENCES im_v2.special_accounts(account_user_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.sync_snapshot_pages
    ADD CONSTRAINT sync_snapshot_pages_snapshot_id_fkey FOREIGN KEY (snapshot_id) REFERENCES im_v2.sync_snapshot_artifacts(snapshot_id) ON DELETE CASCADE;

ALTER TABLE ONLY im_v2.user_contact_aliases
    ADD CONSTRAINT user_contact_aliases_owner_user_id_fkey FOREIGN KEY (owner_user_id) REFERENCES im_v2.public_user_profiles(user_id) ON DELETE CASCADE;

ALTER TABLE ONLY im_v2.user_contact_aliases
    ADD CONSTRAINT user_contact_aliases_target_user_id_fkey FOREIGN KEY (target_user_id) REFERENCES im_v2.public_user_profiles(user_id) ON DELETE CASCADE;

ALTER TABLE ONLY im_v2.user_live_presence_leases
    ADD CONSTRAINT user_live_presence_leases_user_id_device_id_fkey FOREIGN KEY (user_id, device_id) REFERENCES im_v2.auth_devices(user_id, device_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.user_message_favorite_operations
    ADD CONSTRAINT user_message_favorite_operations_message_id_fkey FOREIGN KEY (message_id) REFERENCES im_v2.messages(message_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.user_message_favorite_operations
    ADD CONSTRAINT user_message_favorite_operations_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.user_message_favorites
    ADD CONSTRAINT user_message_favorites_message_id_fkey FOREIGN KEY (message_id) REFERENCES im_v2.messages(message_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.user_message_favorites
    ADD CONSTRAINT user_message_favorites_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.user_projection_versions
    ADD CONSTRAINT user_projection_versions_message_state_room_fkey FOREIGN KEY (message_state_id, scope_room_id) REFERENCES im_v2.message_projection_states(state_id, room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.user_room_preference_operations
    ADD CONSTRAINT user_room_preference_operations_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

ALTER TABLE ONLY im_v2.user_room_preferences
    ADD CONSTRAINT user_room_preferences_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

COMMIT;
