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

CREATE FUNCTION im_v2.capture_user_projection_effect_v4() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO im_v2.user_projection_effects
        (user_id, source_event_id, projection_kind,
         user_sync_sequence, payload, created_at)
    SELECT user_id, source_event_id, projection_kind,
           user_sync_sequence, payload, created_at
    FROM inserted_user_sync_rows
    WHERE payload_storage = 'inline'
      AND projection_kind NOT IN ('message', 'membership', 'moderation', 'room')
    ON CONFLICT (user_id, source_event_id, projection_kind) DO NOTHING;

    IF EXISTS (
        SELECT 1
        FROM inserted_user_sync_rows AS inserted
        JOIN im_v2.user_projection_effects AS effect
          USING (user_id, source_event_id, projection_kind)
        WHERE inserted.payload_storage = 'inline'
          AND inserted.projection_kind NOT IN
              ('message', 'membership', 'moderation', 'room')
          AND ROW(effect.user_sync_sequence, effect.payload, effect.created_at)
              IS DISTINCT FROM
              ROW(inserted.user_sync_sequence, inserted.payload, inserted.created_at)
    ) THEN
        RAISE EXCEPTION 'conflicting immutable user projection effect';
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION im_v2.enqueue_hybrid_group_event_wake() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO im_v2.group_event_wake_outbox (
        room_id, target_room_sequence, revision, state, next_attempt_at, updated_at
    )
    SELECT inserted.room_id,
           max(inserted.room_sequence),
           1,
           'pending',
           min(inserted.created_at),
           max(inserted.created_at)
    FROM inserted_room_events AS inserted
    JOIN im_v2.rooms AS room ON room.room_id = inserted.room_id
    WHERE room.room_kind = 'group'
      AND room.delivery_mode = 'large_group_hybrid'
    GROUP BY inserted.room_id
    ON CONFLICT (room_id) DO UPDATE
    SET target_room_sequence = GREATEST(
            im_v2.group_event_wake_outbox.target_room_sequence,
            EXCLUDED.target_room_sequence
        ),
        revision = im_v2.group_event_wake_outbox.revision + 1,
        state = 'pending',
        lease_token = NULL,
        lease_expires_at = NULL,
        next_attempt_at = LEAST(
            im_v2.group_event_wake_outbox.next_attempt_at,
            EXCLUDED.next_attempt_at
        ),
        updated_at = GREATEST(
            im_v2.group_event_wake_outbox.updated_at,
            EXCLUDED.updated_at
        )
    -- A pending row already guarantees that the relay will revisit this room.
    -- Its authoritative high-watermark is read from `rooms` after the relay
    -- owns the lease, so rewriting this hot row for every append is redundant.
    -- A leased row must still be replaced: that revision/token transition is
    -- the durable fence that prevents an in-flight publisher from deleting a
    -- wake created by a later commit.
    WHERE im_v2.group_event_wake_outbox.state = 'leased';
    RETURN NULL;
END;
$$;

-- Plain message-row events are the canonical accepted event for the compact
-- hybrid-group path.  Keep wake publication in the same transaction and
-- coalesce it once per affected room, exactly like the legacy room-event
-- source.  Direct rooms also use message-row events but deliberately do not
-- enter the group wake pipeline.
CREATE FUNCTION im_v2.enqueue_hybrid_group_message_wake() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO im_v2.group_event_wake_outbox (
        room_id, target_room_sequence, revision, state, next_attempt_at, updated_at
    )
    SELECT inserted.room_id,
           max(inserted.room_sequence),
           1,
           'pending',
           min(inserted.created_at),
           max(inserted.created_at)
    FROM inserted_messages AS inserted
    JOIN im_v2.rooms AS room ON room.room_id = inserted.room_id
    WHERE inserted.accepted_event_storage = 'message_row'
      AND room.room_kind = 'group'
      AND room.delivery_mode = 'large_group_hybrid'
    GROUP BY inserted.room_id
    ON CONFLICT (room_id) DO UPDATE
    SET target_room_sequence = GREATEST(
            im_v2.group_event_wake_outbox.target_room_sequence,
            EXCLUDED.target_room_sequence
        ),
        revision = im_v2.group_event_wake_outbox.revision + 1,
        state = 'pending',
        lease_token = NULL,
        lease_expires_at = NULL,
        next_attempt_at = LEAST(
            im_v2.group_event_wake_outbox.next_attempt_at,
            EXCLUDED.next_attempt_at
        ),
        updated_at = GREATEST(
            im_v2.group_event_wake_outbox.updated_at,
            EXCLUDED.updated_at
        )
    WHERE im_v2.group_event_wake_outbox.state = 'leased';
    RETURN NULL;
END;
$$;

CREATE FUNCTION im_v2.enqueue_user_projection_v7() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Checkpoint and retention rows live for the lifetime of a user. Avoid an
    -- INSERT conflict attempt for every later Sync Log batch: it can wait on
    -- the projector's update lock even though DO NOTHING would win. The final
    -- conflict fence remains necessary for two first-ever batches racing.
    WITH users AS MATERIALIZED (
        SELECT user_id, min(created_at) AS created_at
        FROM inserted_user_sync_rows
        GROUP BY user_id
    )
    INSERT INTO im_v2.user_projection_checkpoints
        (user_id, projected_sequence, updated_at)
    SELECT users.user_id, 0, users.created_at
    FROM users
    WHERE NOT EXISTS (
        SELECT 1 FROM im_v2.user_projection_checkpoints AS checkpoint
        WHERE checkpoint.user_id = users.user_id
    )
    ON CONFLICT (user_id) DO NOTHING;

    WITH users AS MATERIALIZED (
        SELECT user_id, min(created_at) AS created_at
        FROM inserted_user_sync_rows
        GROUP BY user_id
    )
    INSERT INTO im_v2.user_projection_ready
        (user_id, available_at, enqueued_at, updated_at)
    SELECT users.user_id, users.created_at,
           users.created_at, users.created_at
    FROM users
    JOIN im_v2.user_projection_checkpoints AS checkpoint
      ON checkpoint.user_id = users.user_id
     AND checkpoint.state = 'ready'
    WHERE NOT EXISTS (
        SELECT 1 FROM im_v2.user_projection_ready AS ready
        WHERE ready.user_id = users.user_id
    )
    ON CONFLICT (user_id) DO NOTHING;

    WITH users AS MATERIALIZED (
        SELECT user_id, min(created_at) AS created_at
        FROM inserted_user_sync_rows
        GROUP BY user_id
    )
    INSERT INTO im_v2.user_sync_retention
        (user_id, compacted_through_sequence, updated_at)
    SELECT users.user_id, 0, users.created_at
    FROM users
    WHERE NOT EXISTS (
        SELECT 1 FROM im_v2.user_sync_retention AS retention
        WHERE retention.user_id = users.user_id
    )
    ON CONFLICT (user_id) DO NOTHING;
    RETURN NULL;
END;
$$;

CREATE FUNCTION im_v2.reject_fanout_plan_identity_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.source_event_id IS DISTINCT FROM OLD.source_event_id
       OR NEW.target_rule IS DISTINCT FROM OLD.target_rule THEN
        RAISE EXCEPTION 'fanout plan identity and target rule are immutable';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION im_v2.reject_fresh_direct_delivery_identity_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.fresh_direct_eligible IS DISTINCT FROM OLD.fresh_direct_eligible THEN
        RAISE EXCEPTION 'fresh direct eligibility is immutable';
    END IF;
    IF OLD.fresh_direct_eligible
       AND (
           NEW.source_event_id IS DISTINCT FROM OLD.source_event_id
           OR NEW.target_user_id IS DISTINCT FROM OLD.target_user_id
           OR NEW.projection_kind IS DISTINCT FROM OLD.projection_kind
           OR NEW.completion_unit_id IS DISTINCT FROM OLD.completion_unit_id
       ) THEN
        RAISE EXCEPTION 'fresh direct delivery identity is immutable';
    END IF;
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

-- A shard admission lease is also the epoch for the room-local command and
-- fanout windows.  `ON UPDATE CASCADE` advances the durable room fence when a
-- lease is replaced; reset only the epoch-scoped counters in that same row
-- update.  Outstanding work is intentionally preserved because it has its
-- own completion/release lifecycle and remains bounded across lease epochs.
CREATE FUNCTION im_v2.reset_room_admission_windows_on_shard_lease_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.shard_lease_id IS DISTINCT FROM OLD.shard_lease_id
       OR NEW.shard_lease_generation IS DISTINCT FROM OLD.shard_lease_generation THEN
        NEW.command_window_used := 0;
        NEW.fanout_window_used := 0;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION im_v2.validate_fresh_direct_delivery_batch() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM inserted_fanout_deliveries
        WHERE fresh_direct_eligible
    ) THEN
        RETURN NULL;
    END IF;

    IF EXISTS (
        SELECT source_event_id
        FROM inserted_fanout_deliveries
        WHERE fresh_direct_eligible
        GROUP BY source_event_id
        HAVING count(*) <> 2
            OR count(DISTINCT completion_unit_id) <> 1
    ) OR EXISTS (
        SELECT 1
        FROM inserted_fanout_deliveries AS delivery
        LEFT JOIN im_v2.fanout_plans AS plan
          ON plan.source_event_id = delivery.source_event_id
        LEFT JOIN im_v2.fanout_completion_units AS unit
          ON unit.source_event_id = delivery.source_event_id
         AND unit.completion_unit_id = delivery.completion_unit_id
        WHERE delivery.fresh_direct_eligible
          AND (
              plan.source_event_id IS NULL
              OR plan.target_rule->>'planning_strategy' <> 'direct_preplanned'
              OR plan.state <> 'planned'
              OR plan.target_count <> 2
              OR plan.enumerated_target_count <> 2
              OR unit.completion_unit_id IS NULL
              OR unit.target_count <> 2
              OR unit.target_boundary->>'audience_kind' <> 'direct_preplanned'
          )
    ) THEN
        RAISE EXCEPTION 'invalid fresh direct delivery batch';
    END IF;
    RETURN NULL;
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
    session_expires_at timestamp with time zone DEFAULT (CURRENT_TIMESTAMP + interval '30 days') NOT NULL,
    CONSTRAINT auth_devices_session_expiry_finite CHECK (isfinite(session_expires_at)),
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
    encrypted_revocation_credential text NOT NULL,
    revocation_credential_expires_at timestamptz NOT NULL,
    CONSTRAINT device_credential_operations_revocation_result_check CHECK (encrypted_revocation_credential <> '' AND isfinite(revocation_credential_expires_at)),
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

CREATE TABLE im_v2.device_refresh_token_history (
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    family_generation bigint NOT NULL,
    refresh_hmac text NOT NULL,
    consumed_at timestamp with time zone NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    CONSTRAINT device_refresh_token_history_generation_check CHECK ((family_generation > 0)),
    CONSTRAINT device_refresh_token_history_refresh_hmac_check CHECK ((length(refresh_hmac) = 64)),
    CONSTRAINT device_refresh_token_history_time_check CHECK ((expires_at > consumed_at))
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
    fingerprint_version smallint NOT NULL CHECK (fingerprint_version IN (1, 2)),
    request_fingerprint bytea NOT NULL CHECK (octet_length(request_fingerprint) = 32),
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
    lower_has_replied boolean DEFAULT false NOT NULL,
    higher_has_replied boolean DEFAULT false NOT NULL,
    direct_policy_revision bigint DEFAULT 1 NOT NULL,
    CONSTRAINT direct_room_pairs_direct_policy_revision_check CHECK ((direct_policy_revision > 0)),
    CONSTRAINT direct_room_pairs_check CHECK ((lower_user_id < higher_user_id))
);

-- One durable revision per user for direct-message policy inputs that are not
-- pair-local (account state and stranger-message preference). Gateway caches
-- are only hints; these revisions are checked by the authoritative write.
CREATE TABLE im_v2.user_direct_send_policy_versions (
    user_id uuid NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_direct_send_policy_versions_revision_check CHECK ((revision > 0))
);

CREATE TABLE im_v2.forward_work_replay_audit (
    operation_id uuid PRIMARY KEY,
    operator_principal text NOT NULL CHECK (char_length(operator_principal) BETWEEN 1 AND 128),
    shard_id text NOT NULL CHECK (char_length(shard_id) BETWEEN 1 AND 128),
    target_kind text NOT NULL,
    export_id uuid NOT NULL,
    ordinal integer,
    reason_code text NOT NULL CHECK (reason_code IN ('dependency_recovered', 'data_repaired', 'false_positive')),
    requested_at timestamptz NOT NULL,
    outcome text NOT NULL CHECK (outcome IN ('processing', 'requeued', 'not_paused')),
    CONSTRAINT forward_work_replay_audit_target_check CHECK (
        (target_kind = 'delivery' AND ordinal IS NULL)
        OR (target_kind = 'media' AND ordinal IS NOT NULL AND ordinal BETWEEN 0 AND 9)
    )
);
CREATE INDEX forward_work_replay_audit_requested_idx ON im_v2.forward_work_replay_audit (requested_at DESC);
CREATE FUNCTION im_v2.reject_forward_replay_audit_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'forward replay audit cannot be deleted' USING ERRCODE = '23514';
    END IF;
    IF ROW(NEW.operation_id, NEW.operator_principal, NEW.shard_id, NEW.target_kind, NEW.export_id, NEW.ordinal, NEW.reason_code, NEW.requested_at)
       IS DISTINCT FROM ROW(OLD.operation_id, OLD.operator_principal, OLD.shard_id, OLD.target_kind, OLD.export_id, OLD.ordinal, OLD.reason_code, OLD.requested_at)
       OR (OLD.outcome <> 'processing' AND NEW IS DISTINCT FROM OLD)
       OR (OLD.outcome = 'processing' AND NEW.outcome NOT IN ('requeued', 'not_paused')) THEN
        RAISE EXCEPTION 'forward replay audit identity and result are immutable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER forward_work_replay_audit_immutable BEFORE UPDATE OR DELETE ON im_v2.forward_work_replay_audit
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_forward_replay_audit_mutation();

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

-- Fan-out bookkeeping is update-heavy: pending rows become terminal within
-- seconds, while the normal retention worker removes them days later. Use a
-- row-count-independent vacuum threshold so dead tuples and partial-index
-- entries cannot grow for hours at sustained message rates.
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
)
WITH (autovacuum_vacuum_scale_factor='0.02', autovacuum_vacuum_threshold='1000', autovacuum_analyze_scale_factor='0.02', autovacuum_analyze_threshold='1000');

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
)
WITH (autovacuum_vacuum_scale_factor='0.02', autovacuum_vacuum_threshold='1000', autovacuum_analyze_scale_factor='0.02', autovacuum_analyze_threshold='1000');

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
    CONSTRAINT fanout_plans_direct_preplanned_shape_check CHECK ((((target_rule ->> 'planning_strategy'::text) IS DISTINCT FROM 'direct_preplanned'::text) OR ((state = ANY (ARRAY['planned'::text, 'terminal'::text])) AND (target_count = 2) AND (enumerated_target_count = 2) AND (reserved_fanout_cost = 2)))),
    CONSTRAINT fanout_plans_reserved_fanout_cost_check CHECK ((reserved_fanout_cost >= 0)),
    CONSTRAINT fanout_plans_source_room_sequence_check CHECK ((source_room_sequence > 0)),
    CONSTRAINT fanout_plans_state_check CHECK ((state = ANY (ARRAY['planning'::text, 'planned'::text, 'terminal'::text]))),
    CONSTRAINT fanout_plans_target_count_check CHECK (((target_count IS NULL) OR (target_count >= 0)))
)
WITH (autovacuum_vacuum_scale_factor='0.02', autovacuum_vacuum_threshold='1000', autovacuum_analyze_scale_factor='0.02', autovacuum_analyze_threshold='1000');

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

CREATE TABLE im_v2.group_role_policies (
    room_id uuid NOT NULL,
    role text NOT NULL,
    CONSTRAINT group_role_policies_pkey PRIMARY KEY (room_id, role),
    CONSTRAINT group_role_policies_role_check CHECK (role IN ('admin', 'member'))
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

CREATE TABLE im_v2.group_invite_links (
    invite_id uuid NOT NULL,
    room_id uuid NOT NULL,
    created_by_user_id uuid NOT NULL,
    creation_operation_id uuid NOT NULL,
    token_digest bytea NOT NULL,
    requested_lifetime_seconds integer NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    maximum_approved_uses integer NOT NULL,
    approved_use_count integer DEFAULT 0 NOT NULL,
    state text DEFAULT 'active'::text NOT NULL,
    revocation_operation_id uuid,
    revoked_by_user_id uuid,
    revoked_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT group_invite_links_token_digest_check CHECK ((octet_length(token_digest) = 32)),
    CONSTRAINT group_invite_links_lifetime_check CHECK (((requested_lifetime_seconds >= 300) AND (requested_lifetime_seconds <= 2592000))),
    CONSTRAINT group_invite_links_expiry_check CHECK ((expires_at > created_at)),
    CONSTRAINT group_invite_links_use_count_check CHECK (((maximum_approved_uses > 0) AND (approved_use_count >= 0) AND (approved_use_count <= maximum_approved_uses))),
    CONSTRAINT group_invite_links_state_check CHECK ((state = ANY (ARRAY['active'::text, 'revoked'::text]))),
    CONSTRAINT group_invite_links_revocation_check CHECK ((((state = 'active'::text) AND (revocation_operation_id IS NULL) AND (revoked_by_user_id IS NULL) AND (revoked_at IS NULL)) OR ((state = 'revoked'::text) AND (revocation_operation_id IS NOT NULL) AND (revoked_by_user_id IS NOT NULL) AND (revoked_at IS NOT NULL))))
);

CREATE TABLE im_v2.group_join_requests (
    request_id uuid NOT NULL,
    invite_id uuid NOT NULL,
    room_id uuid NOT NULL,
    applicant_user_id uuid NOT NULL,
    submission_operation_id uuid NOT NULL,
    note text,
    state text DEFAULT 'pending'::text NOT NULL,
    decision_operation_id uuid,
    decided_by_user_id uuid,
    approval_membership_revision bigint,
    decided_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT group_join_requests_note_check CHECK (((note IS NULL) OR ((octet_length(note) >= 1) AND (octet_length(note) <= 500)))),
    CONSTRAINT group_join_requests_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'approving'::text, 'approved'::text, 'rejected'::text]))),
    CONSTRAINT group_join_requests_decision_check CHECK ((((state = 'pending'::text) AND (decision_operation_id IS NULL) AND (decided_by_user_id IS NULL) AND (approval_membership_revision IS NULL) AND (decided_at IS NULL)) OR ((state = 'approving'::text) AND (decision_operation_id IS NOT NULL) AND (decided_by_user_id IS NOT NULL) AND (approval_membership_revision IS NOT NULL) AND (decided_at IS NULL)) OR ((state = 'approved'::text) AND (decision_operation_id IS NOT NULL) AND (decided_by_user_id IS NOT NULL) AND (approval_membership_revision IS NOT NULL) AND (decided_at IS NOT NULL)) OR ((state = 'rejected'::text) AND (decision_operation_id IS NOT NULL) AND (decided_by_user_id IS NOT NULL) AND (approval_membership_revision IS NULL) AND (decided_at IS NOT NULL))))
);

CREATE TABLE im_v2.group_join_approval_recovery_audit (
    operation_id uuid PRIMARY KEY,
    operator_principal text NOT NULL,
    shard_id text NOT NULL,
    owner_epoch bigint NOT NULL CHECK (owner_epoch >= 0),
    room_id uuid NOT NULL,
    request_id uuid NOT NULL,
    reviewer_user_id uuid NOT NULL,
    decision_operation_id uuid NOT NULL,
    reason_code text NOT NULL CHECK (reason_code IN ('dependency_recovered', 'data_repaired', 'false_positive')),
    outcome text NOT NULL CHECK (outcome IN ('completed', 'released', 'quarantined', 'not_approving')),
    detail text NOT NULL CHECK (detail IN ('committed_operation', 'no_historical_add', 'operation_mismatch', 'historical_add_without_receipt', 'invalid_revision', 'invite_exhausted', 'not_approving')),
    requested_at timestamp with time zone NOT NULL,
    applicant_user_id uuid NOT NULL,
    prepared_revision bigint,
    member_room_id uuid,
    member_target_user_id uuid,
    member_action text,
    expected_revision bigint,
    resulting_revision bigint,
    room_sequence bigint,
    event_id uuid,
    plan_id uuid,
    CONSTRAINT group_join_approval_recovery_audit_result_check CHECK (
        (member_room_id IS NULL AND member_target_user_id IS NULL AND member_action IS NULL AND expected_revision IS NULL AND resulting_revision IS NULL AND room_sequence IS NULL AND event_id IS NULL AND plan_id IS NULL)
        OR (member_room_id IS NOT NULL AND member_target_user_id IS NOT NULL AND member_action IS NOT NULL AND expected_revision IS NOT NULL AND resulting_revision IS NOT NULL AND room_sequence IS NOT NULL AND event_id IS NOT NULL AND plan_id IS NOT NULL)
    ),
    CONSTRAINT group_join_approval_recovery_audit_completed_check CHECK (outcome <> 'completed' OR expected_revision IS NOT NULL)
);

CREATE TABLE im_v2.room_membership_operation_fences (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    room_id uuid NOT NULL,
    request_id uuid NOT NULL,
    recovery_operation_id uuid NOT NULL REFERENCES im_v2.group_join_approval_recovery_audit(operation_id) ON DELETE RESTRICT,
    created_at timestamp with time zone NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id)
);

CREATE FUNCTION im_v2.reject_approval_recovery_mutation() RETURNS trigger
    LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'approval recovery evidence is immutable'; END;$$;

CREATE TRIGGER group_join_approval_recovery_audit_immutable
    BEFORE UPDATE OR DELETE ON im_v2.group_join_approval_recovery_audit
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_approval_recovery_mutation();
CREATE TRIGGER room_membership_operation_fences_immutable
    BEFORE UPDATE OR DELETE ON im_v2.room_membership_operation_fences
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_approval_recovery_mutation();
CREATE INDEX group_join_requests_approving_recovery_idx
    ON im_v2.group_join_requests (room_id, request_id) WHERE state = 'approving';

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

-- Immutable source authorization envelopes double as the durable export outbox.
-- No source/target message FK: source retention cannot erase committed evidence,
-- and the destination room deliberately lives in a different physical database.
CREATE TABLE im_v2.message_forward_exports (
    export_id uuid PRIMARY KEY,
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    source_room_id uuid NOT NULL,
    source_message_id uuid NOT NULL,
    source_content_revision bigint NOT NULL CHECK (source_content_revision > 0),
    source_shard_id text NOT NULL CHECK (length(btrim(source_shard_id)) > 0),
    source_epoch bigint NOT NULL CHECK (source_epoch >= 0),
    target_room_id uuid NOT NULL,
    target_client_message_id uuid NOT NULL,
    target_shard_id text NOT NULL CHECK (length(btrim(target_shard_id)) > 0),
    target_epoch bigint NOT NULL CHECK (target_epoch >= 0),
    payload bytea NOT NULL CHECK (octet_length(payload) BETWEEN 1 AND 1048576),
    payload_digest bytea NOT NULL CHECK (octet_length(payload_digest) = 32),
    media_ids uuid[] NOT NULL CHECK (cardinality(media_ids) <= 10 AND array_position(media_ids, NULL) IS NULL),
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT message_forward_exports_pair_key UNIQUE (actor_user_id, operation_id, source_message_id, target_room_id),
    CONSTRAINT message_forward_exports_client_key UNIQUE (actor_user_id, target_client_message_id)
);
CREATE INDEX message_forward_exports_room_idx ON im_v2.message_forward_exports (source_room_id, created_at, export_id);
CREATE INDEX message_forward_exports_delivery_idx ON im_v2.message_forward_exports (source_shard_id, created_at, export_id);
CREATE INDEX message_forward_exports_media_idx ON im_v2.message_forward_exports USING gin (media_ids);
CREATE FUNCTION im_v2.reject_forward_export_mutation() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'committed forward export is immutable' USING ERRCODE = '23514';
END;
$$;
CREATE TRIGGER message_forward_exports_immutable
    BEFORE UPDATE OR DELETE ON im_v2.message_forward_exports FOR EACH ROW
    EXECUTE FUNCTION im_v2.reject_forward_export_mutation();

-- Terminal source receipts release delivery capacity and source object pins.
-- No FK to a target message: the target is a different physical database.
CREATE TABLE im_v2.message_forward_export_receipts (
    export_id uuid PRIMARY KEY REFERENCES im_v2.message_forward_exports(export_id) ON DELETE RESTRICT,
    payload_digest bytea NOT NULL CHECK (octet_length(payload_digest) = 32),
    state text NOT NULL,
    result_message_id uuid,
    result_room_sequence bigint,
    error_code text,
    recorded_at timestamptz NOT NULL,
    CONSTRAINT message_forward_export_receipts_shape_check CHECK (
        (state = 'completed' AND result_message_id IS NOT NULL
         AND result_room_sequence IS NOT NULL AND result_room_sequence > 0 AND error_code IS NULL)
        OR (state = 'rejected' AND result_message_id IS NULL AND result_room_sequence IS NULL
            AND error_code IS NOT NULL AND octet_length(error_code) BETWEEN 1 AND 128)
    )
);
CREATE FUNCTION im_v2.reject_forward_export_receipt_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'forward export terminal receipt is immutable' USING ERRCODE = '23514';
END;
$$;
CREATE TRIGGER message_forward_export_receipts_immutable
    BEFORE UPDATE OR DELETE ON im_v2.message_forward_export_receipts FOR EACH ROW
    EXECUTE FUNCTION im_v2.reject_forward_export_receipt_mutation();

CREATE TABLE im_v2.message_forward_delivery_jobs (
    export_id uuid PRIMARY KEY REFERENCES im_v2.message_forward_exports(export_id) ON DELETE RESTRICT,
    state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'claimed', 'paused', 'completed')),
    claim_token uuid,
    lease_expires_at timestamptz,
    next_attempt_at timestamptz,
    retry_count bigint NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    created_at timestamptz NOT NULL,
    completed_at timestamptz,
    CONSTRAINT message_forward_delivery_jobs_shape_check CHECK (
        ((state = 'claimed') = (claim_token IS NOT NULL)) AND ((state = 'claimed') = (lease_expires_at IS NOT NULL))
        AND ((state = 'pending') = (next_attempt_at IS NOT NULL))
        AND ((state = 'completed') = (completed_at IS NOT NULL))
    )
);
CREATE INDEX message_forward_delivery_jobs_ready_idx ON im_v2.message_forward_delivery_jobs (next_attempt_at, created_at, export_id) WHERE state = 'pending';
CREATE INDEX message_forward_delivery_jobs_lease_idx ON im_v2.message_forward_delivery_jobs (lease_expires_at, export_id) WHERE state = 'claimed';
CREATE FUNCTION im_v2.reject_forward_delivery_job_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'forward delivery identity cannot be deleted' USING ERRCODE = '23514';
    END IF;
    IF ROW(NEW.export_id, NEW.created_at) IS DISTINCT FROM ROW(OLD.export_id, OLD.created_at)
       OR (OLD.state = 'completed' AND NEW IS DISTINCT FROM OLD)
       OR (OLD.state = 'pending' AND NEW.state NOT IN ('pending', 'claimed'))
       OR (OLD.state = 'paused' AND NEW.state NOT IN ('paused', 'pending')) THEN
        RAISE EXCEPTION 'forward delivery identity and terminal result are immutable' USING ERRCODE = '23514';
    END IF;
    IF NEW.state = 'completed' AND NOT EXISTS(SELECT 1 FROM im_v2.message_forward_export_receipts WHERE export_id = NEW.export_id) THEN
        RAISE EXCEPTION 'forward delivery completion requires source receipt' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER message_forward_delivery_jobs_immutable BEFORE UPDATE OR DELETE ON im_v2.message_forward_delivery_jobs
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_forward_delivery_job_mutation();

-- An inbox receipt is independent of mutable message projections. No source
-- message/room FK crosses the physical owner boundary.
CREATE TABLE im_v2.message_forward_inbox (
    export_id uuid PRIMARY KEY,
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    source_message_id uuid NOT NULL,
    target_room_id uuid NOT NULL,
    target_client_message_id uuid NOT NULL,
    payload bytea NOT NULL CHECK (octet_length(payload) BETWEEN 1 AND 1048576),
    payload_digest bytea NOT NULL CHECK (octet_length(payload_digest) = 32),
    state text NOT NULL CHECK (state IN ('pending', 'accepted', 'completed', 'rejected')),
    result_message_id uuid,
    result_room_sequence bigint,
    error_code text,
    created_at timestamptz NOT NULL,
    accepted_at timestamptz,
    completed_at timestamptz,
    CONSTRAINT message_forward_inbox_pair_key UNIQUE (actor_user_id, operation_id, source_message_id, target_room_id),
    CONSTRAINT message_forward_inbox_client_key UNIQUE (actor_user_id, target_client_message_id),
    CONSTRAINT message_forward_inbox_outcome_check CHECK (
        (state = 'pending' AND result_message_id IS NULL AND result_room_sequence IS NULL AND error_code IS NULL AND accepted_at IS NULL AND completed_at IS NULL)
        OR (state IN ('accepted', 'completed') AND result_message_id IS NOT NULL AND result_room_sequence IS NOT NULL AND result_room_sequence > 0 AND error_code IS NULL AND accepted_at IS NOT NULL AND ((state = 'completed') = (completed_at IS NOT NULL)))
        OR (state = 'rejected' AND result_message_id IS NULL AND result_room_sequence IS NULL AND error_code IS NOT NULL AND length(error_code) BETWEEN 1 AND 64 AND accepted_at IS NULL AND completed_at IS NOT NULL)
    )
);
CREATE INDEX message_forward_inbox_pending_idx ON im_v2.message_forward_inbox (target_room_id, created_at, export_id) WHERE state IN ('pending', 'accepted');
CREATE FUNCTION im_v2.reject_forward_inbox_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'forward inbox receipt cannot be deleted' USING ERRCODE = '23514';
    END IF;
    IF ROW(NEW.export_id, NEW.actor_user_id, NEW.operation_id, NEW.source_message_id, NEW.target_room_id, NEW.target_client_message_id, NEW.payload, NEW.payload_digest, NEW.created_at)
       IS DISTINCT FROM ROW(OLD.export_id, OLD.actor_user_id, OLD.operation_id, OLD.source_message_id, OLD.target_room_id, OLD.target_client_message_id, OLD.payload, OLD.payload_digest, OLD.created_at)
       OR (OLD.state IN ('completed', 'rejected') AND NEW IS DISTINCT FROM OLD)
       OR (OLD.state = 'pending' AND NEW.state NOT IN ('pending', 'accepted', 'rejected'))
       OR (OLD.state = 'accepted' AND (
            NEW.state NOT IN ('accepted', 'completed')
            OR ROW(NEW.result_message_id, NEW.result_room_sequence, NEW.accepted_at, NEW.error_code)
               IS DISTINCT FROM ROW(OLD.result_message_id, OLD.result_room_sequence, OLD.accepted_at, OLD.error_code))) THEN
        RAISE EXCEPTION 'forward inbox identity and terminal outcome are immutable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER message_forward_inbox_immutable BEFORE UPDATE OR DELETE ON im_v2.message_forward_inbox
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_forward_inbox_mutation();
CREATE TABLE im_v2.message_forward_inbox_media (
    export_id uuid NOT NULL REFERENCES im_v2.message_forward_inbox(export_id) ON DELETE RESTRICT,
    ordinal integer NOT NULL CHECK (ordinal BETWEEN 0 AND 9),
    source_media_id uuid NOT NULL,
    target_media_id uuid UNIQUE CHECK (target_media_id IS NULL OR target_media_id <> source_media_id),
    object_digest bytea,
    state text NOT NULL CHECK (state IN ('pending', 'ready')),
    PRIMARY KEY (export_id, ordinal),
    UNIQUE (export_id, source_media_id),
    CONSTRAINT message_forward_inbox_media_ready_check CHECK (
        (state = 'pending' AND target_media_id IS NULL AND object_digest IS NULL)
        OR (state = 'ready' AND target_media_id IS NOT NULL AND object_digest IS NOT NULL AND octet_length(object_digest) = 32)
    )
);
CREATE FUNCTION im_v2.reject_forward_inbox_media_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'forward inbox media identity cannot be deleted' USING ERRCODE = '23514';
    END IF;
    IF ROW(NEW.export_id, NEW.ordinal, NEW.source_media_id) IS DISTINCT FROM ROW(OLD.export_id, OLD.ordinal, OLD.source_media_id)
       OR (OLD.state = 'ready' AND NEW IS DISTINCT FROM OLD) THEN
        RAISE EXCEPTION 'forward inbox media identity and ready mapping are immutable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER message_forward_inbox_media_immutable BEFORE UPDATE OR DELETE ON im_v2.message_forward_inbox_media
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_forward_inbox_media_mutation();

CREATE TABLE im_v2.message_forward_media_imports (
    export_id uuid NOT NULL,
    ordinal integer NOT NULL CHECK (ordinal BETWEEN 0 AND 9),
    target_media_id uuid NOT NULL UNIQUE,
    target_upload_session_id uuid NOT NULL UNIQUE,
    state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'claimed', 'paused', 'ready', 'failed')),
    copied_digest bytea,
    copied_at timestamptz,
    claim_token uuid,
    lease_expires_at timestamptz,
    next_attempt_at timestamptz,
    retry_count bigint NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    created_at timestamptz NOT NULL,
    completed_at timestamptz,
    PRIMARY KEY (export_id, ordinal),
    FOREIGN KEY (export_id, ordinal) REFERENCES im_v2.message_forward_inbox_media(export_id, ordinal) ON DELETE RESTRICT,
    CONSTRAINT message_forward_media_imports_shape_check CHECK (
        ((state = 'claimed') = (claim_token IS NOT NULL)) AND ((state = 'claimed') = (lease_expires_at IS NOT NULL))
        AND ((state IN ('ready', 'failed')) = (completed_at IS NOT NULL))
        AND ((copied_digest IS NOT NULL) = (copied_at IS NOT NULL))
        AND (copied_digest IS NULL OR octet_length(copied_digest) = 32)
        AND (state <> 'ready' OR copied_digest IS NOT NULL)
        AND (next_attempt_at IS NULL OR state = 'pending')
    )
);
CREATE INDEX message_forward_media_imports_work_idx ON im_v2.message_forward_media_imports (state, next_attempt_at, lease_expires_at, created_at) WHERE state IN ('pending', 'claimed');
CREATE FUNCTION im_v2.reject_forward_media_import_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'forward media import identity cannot be deleted' USING ERRCODE = '23514';
    END IF;
    IF ROW(NEW.export_id, NEW.ordinal, NEW.target_media_id, NEW.target_upload_session_id, NEW.created_at)
       IS DISTINCT FROM ROW(OLD.export_id, OLD.ordinal, OLD.target_media_id, OLD.target_upload_session_id, OLD.created_at)
       OR (OLD.copied_digest IS NOT NULL AND ROW(NEW.copied_digest, NEW.copied_at) IS DISTINCT FROM ROW(OLD.copied_digest, OLD.copied_at))
       OR (OLD.state IN ('ready', 'failed') AND NEW IS DISTINCT FROM OLD)
       OR (OLD.state = 'pending' AND NEW.state NOT IN ('pending', 'claimed'))
       OR (OLD.state = 'paused' AND NEW.state NOT IN ('paused', 'pending')) THEN
        RAISE EXCEPTION 'forward media object, copied digest and terminal outcome are immutable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER message_forward_media_imports_immutable BEFORE UPDATE OR DELETE ON im_v2.message_forward_media_imports
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_forward_media_import_mutation();

CREATE TABLE im_v2.message_forward_operations (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    source_message_id uuid NOT NULL,
    target_room_id uuid NOT NULL,
    target_client_message_id uuid NOT NULL,
    -- NULL is retained only for pre-v8 operations whose source version is
    -- unknown. Successful results still replay; pending ones fail closed.
    source_content_revision bigint CHECK (source_content_revision > 0),
    source_room_id uuid,
    result_message_id uuid,
    created_at timestamp with time zone NOT NULL
);

CREATE FUNCTION im_v2.reject_forward_operation_identity_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF ROW(NEW.actor_user_id, NEW.operation_id, NEW.source_message_id,
           NEW.target_room_id, NEW.target_client_message_id, NEW.source_content_revision, NEW.source_room_id, NEW.created_at)
       IS DISTINCT FROM
       ROW(OLD.actor_user_id, OLD.operation_id, OLD.source_message_id,
           OLD.target_room_id, OLD.target_client_message_id, OLD.source_content_revision, OLD.source_room_id, OLD.created_at)
       OR (OLD.result_message_id IS NOT NULL AND NEW.result_message_id IS DISTINCT FROM OLD.result_message_id) THEN
        RAISE EXCEPTION 'forward operation identity and completed result are immutable'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER message_forward_operations_identity_immutable
    BEFORE UPDATE ON im_v2.message_forward_operations FOR EACH ROW
    EXECUTE FUNCTION im_v2.reject_forward_operation_identity_mutation();

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

CREATE UNIQUE INDEX room_events_message_edit_revision_idx
    ON im_v2.room_events
    (room_id, lower(payload->>'message_id'), (payload->>'message_revision'))
    WHERE event_type = 'message.edited';


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
    -- Most messages retain a separate immutable room event.  The hot plain
    -- direct-room path is different: the message row itself is its immutable
    -- accepted event, identified by `accepted_event_id`.  Keeping the mode
    -- explicit lets readers safely combine both generations during rollout.
    accepted_event_id uuid,
    accepted_event_storage text DEFAULT 'room_event'::text NOT NULL,
    accepted_membership_revision bigint,
    CONSTRAINT messages_accepted_event_storage_check CHECK (((accepted_event_storage = 'room_event'::text) AND (accepted_event_id IS NULL) AND (accepted_membership_revision IS NULL)) OR ((accepted_event_storage = 'message_row'::text) AND (accepted_event_id IS NOT NULL) AND (accepted_membership_revision >= 0))),
    CONSTRAINT messages_message_row_sequences_match CHECK (((accepted_event_storage <> 'message_row'::text) OR (room_sequence = timeline_sequence))),
    CONSTRAINT messages_check CHECK ((((withdrawn_at IS NULL) AND (withdrawn_by_user_id IS NULL)) OR ((withdrawn_at IS NOT NULL) AND (withdrawn_by_user_id IS NOT NULL)))),
    CONSTRAINT messages_content_revision_check CHECK ((content_revision > 0)),
    CONSTRAINT messages_rich_entities_array CHECK ((jsonb_typeof(rich_entities) = 'array'::text)),
    CONSTRAINT messages_room_sequence_check CHECK ((room_sequence > 0)),
    CONSTRAINT messages_timeline_sequence_positive CHECK ((timeline_sequence > 0))
);

-- A send's result outlives its editable/deletable content. Deliberately no
-- message/room foreign key or cascading delete: content retention must not
-- make an acknowledged operation eligible for acceptance a second time.
CREATE TABLE im_v2.message_send_completions (
    room_id uuid NOT NULL,
    sender_user_id uuid NOT NULL,
    client_message_id uuid NOT NULL,
    fingerprint_version smallint NOT NULL CHECK (fingerprint_version IN (1, 2)),
    request_fingerprint bytea NOT NULL CHECK (octet_length(request_fingerprint) = 32),
    message_id uuid NOT NULL,
    event_id uuid NOT NULL,
    room_sequence bigint NOT NULL CHECK (room_sequence > 0),
    timeline_sequence bigint NOT NULL CHECK (timeline_sequence > 0),
    accepted_membership_revision bigint NOT NULL CHECK (accepted_membership_revision >= 0),
    delivery_authority text NOT NULL CHECK (delivery_authority IN ('personal', 'room_log')),
    group_delivery_mode text CHECK (group_delivery_mode IN ('standard_fanout', 'large_group_hybrid')),
    direct_recipient_user_id uuid,
    created_at timestamp with time zone NOT NULL,
    PRIMARY KEY (room_id, sender_user_id, client_message_id)
);

CREATE FUNCTION im_v2.reject_message_send_completion_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW IS DISTINCT FROM OLD THEN
        RAISE EXCEPTION 'send completion identity and result are immutable'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER message_send_completions_immutable
    BEFORE UPDATE ON im_v2.message_send_completions
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_message_send_completion_mutation();

-- Accepted room-log events may reference this immutable snapshot after a
-- message is revised. The trigger below captures the prior revision inside
-- the same transaction as the mutation, so historical event pulls never
-- observe a later message body.
CREATE TABLE im_v2.message_content_versions (
    message_id uuid NOT NULL,
    message_revision bigint NOT NULL,
    text_body text NOT NULL,
    rich_entities jsonb NOT NULL,
    archived_at timestamp with time zone NOT NULL,
    CONSTRAINT message_content_versions_message_revision_check CHECK ((message_revision > 0)),
    CONSTRAINT message_content_versions_rich_entities_array CHECK ((jsonb_typeof(rich_entities) = 'array'::text))
);

CREATE FUNCTION im_v2.snapshot_message_content_before_revision_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (NEW.text_body IS DISTINCT FROM OLD.text_body
        OR NEW.rich_entities IS DISTINCT FROM OLD.rich_entities)
       AND NEW.content_revision = OLD.content_revision THEN
        RAISE EXCEPTION 'message content updates must advance content_revision'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.content_revision <> OLD.content_revision THEN
        INSERT INTO im_v2.message_content_versions
            (message_id, message_revision, text_body, rich_entities, archived_at)
        VALUES
            (OLD.message_id, OLD.content_revision, OLD.text_body, OLD.rich_entities, now())
        ON CONFLICT (message_id, message_revision) DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER messages_snapshot_content_before_revision_change
    BEFORE UPDATE OF text_body, rich_entities, content_revision ON im_v2.messages
    FOR EACH ROW EXECUTE FUNCTION im_v2.snapshot_message_content_before_revision_change();

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

CREATE TABLE im_v2.push_device_intents (
    device_id uuid PRIMARY KEY,
    session_epoch bigint NOT NULL CHECK (session_epoch > 0),
    session_claim_id uuid NOT NULL,
    intent_revision bigint NOT NULL CHECK (intent_revision >= 0),
    intent_digest bytea,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT push_device_intents_digest_check CHECK (
        (intent_revision = 0 AND intent_digest IS NULL)
        OR (intent_revision > 0 AND intent_digest IS NOT NULL AND octet_length(intent_digest) = 32)
    )
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
    owner_epoch bigint DEFAULT 0 NOT NULL CHECK (owner_epoch >= 0),
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

-- Physical room-store routing is control-plane metadata. The canonical room,
-- membership and message rows live only in the selected owner store; these
-- records contain no endpoint and are never sent to clients.
CREATE TABLE im_v2.room_owner_routes (
    room_id uuid NOT NULL,
    room_shard_id text NOT NULL,
    route_epoch bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT room_owner_routes_pkey PRIMARY KEY (room_id),
    CONSTRAINT room_owner_routes_room_shard_id_check CHECK ((length(btrim(room_shard_id)) > 0)),
    CONSTRAINT room_owner_routes_route_epoch_check CHECK ((route_epoch >= 0))
);

CREATE TABLE im_v2.direct_room_owner_routes (
    lower_user_id uuid NOT NULL,
    higher_user_id uuid NOT NULL,
    room_id uuid NOT NULL,
    room_shard_id text NOT NULL,
    route_epoch bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT direct_room_owner_routes_pkey PRIMARY KEY (lower_user_id, higher_user_id),
    CONSTRAINT direct_room_owner_routes_room_id_key UNIQUE (room_id),
    CONSTRAINT direct_room_owner_routes_order_check CHECK ((lower_user_id::text < higher_user_id::text)),
    CONSTRAINT direct_room_owner_routes_room_shard_id_check CHECK ((length(btrim(room_shard_id)) > 0)),
    CONSTRAINT direct_room_owner_routes_route_epoch_check CHECK ((route_epoch >= 0))
);

-- A group has no existing room route while it is being created. This
-- control-plane intent fixes its owner and generated identifiers before any
-- owner-database transaction starts, allowing retries to finish an
-- owner-committed/control-not-finalized saga without re-hashing the request.
CREATE TABLE im_v2.group_room_creation_intents (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    room_id uuid NOT NULL,
    event_id uuid NOT NULL,
    plan_id uuid NOT NULL,
    room_shard_id text NOT NULL,
    route_epoch bigint DEFAULT 0 NOT NULL,
    request_fingerprint bytea NOT NULL,
    audience_member_count integer NOT NULL,
    state text DEFAULT 'prepared'::text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT group_room_creation_intents_pkey PRIMARY KEY (actor_user_id, operation_id),
    CONSTRAINT group_room_creation_intents_room_id_key UNIQUE (room_id),
    CONSTRAINT group_room_creation_intents_event_id_key UNIQUE (event_id),
    CONSTRAINT group_room_creation_intents_plan_id_key UNIQUE (plan_id),
    CONSTRAINT group_room_creation_intents_room_shard_id_check CHECK ((length(btrim(room_shard_id)) > 0)),
    CONSTRAINT group_room_creation_intents_route_epoch_check CHECK ((route_epoch >= 0)),
    CONSTRAINT group_room_creation_intents_request_fingerprint_check CHECK ((octet_length(request_fingerprint) = 32)),
    CONSTRAINT group_room_creation_intents_audience_member_count_check CHECK (((audience_member_count >= 1) AND (audience_member_count <= 100000))),
    CONSTRAINT group_room_creation_intents_state_check CHECK ((state = ANY (ARRAY['prepared'::text, 'committed'::text])))
);

-- The control transaction validates this immutable audience against global
-- account state before owner work. Persisting the exact set (instead of only
-- trusting a later client retry) lets a crashed coordinator resume the same
-- cross-database creation without weakening member eligibility.
CREATE TABLE im_v2.group_room_creation_intent_members (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    user_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT group_room_creation_intent_members_pkey PRIMARY KEY (actor_user_id, operation_id, user_id),
    CONSTRAINT group_room_creation_intent_members_intent_fkey
        FOREIGN KEY (actor_user_id, operation_id)
        REFERENCES im_v2.group_room_creation_intents(actor_user_id, operation_id)
        ON DELETE CASCADE
);

-- Owner-side staged audience transfer ledger. Each bounded, sorted page is
-- immutable and digest-fenced; finalization requires a contiguous page range
-- whose declared and materialized member counts equal the control intent.
CREATE TABLE im_v2.group_room_creation_intent_pages (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    page_number integer NOT NULL,
    member_count integer NOT NULL,
    page_digest bytea NOT NULL,
    is_final boolean NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT group_room_creation_intent_pages_pkey PRIMARY KEY (actor_user_id, operation_id, page_number),
    CONSTRAINT group_room_creation_intent_pages_intent_fkey
        FOREIGN KEY (actor_user_id, operation_id)
        REFERENCES im_v2.group_room_creation_intents(actor_user_id, operation_id)
        ON DELETE CASCADE,
    CONSTRAINT group_room_creation_intent_pages_page_number_check CHECK ((page_number >= 0)),
    CONSTRAINT group_room_creation_intent_pages_member_count_check CHECK (((member_count >= 1) AND (member_count <= 512))),
    CONSTRAINT group_room_creation_intent_pages_page_digest_check CHECK ((octet_length(page_digest) = 32))
);

CREATE UNIQUE INDEX group_room_creation_intent_pages_final_key
    ON im_v2.group_room_creation_intent_pages (actor_user_id, operation_id)
    WHERE is_final;

CREATE TABLE im_v2.schema_contract (
    schema_id text DEFAULT 'im-v2-current-30'::text NOT NULL,
    CONSTRAINT schema_contract_schema_id_check CHECK ((schema_id = 'im-v2-current-30'::text))
);

-- Readiness verification requires one canonical contract row. A DEFAULT only
-- applies when callers insert; it does not populate a freshly initialized
-- table, so seed it as part of the authoritative schema bootstrap.
INSERT INTO im_v2.schema_contract (schema_id) VALUES ('im-v2-current-30');

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

CREATE TABLE im_v2.user_projection_ready (
    user_id uuid NOT NULL,
    available_at timestamp with time zone NOT NULL,
    enqueued_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
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

ALTER TABLE ONLY im_v2.device_refresh_token_history
    ADD CONSTRAINT device_refresh_token_history_pkey PRIMARY KEY (device_id, family_generation);

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
    ADD CONSTRAINT direct_message_denials_pkey PRIMARY KEY (room_id, sender_user_id, client_message_id);

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

ALTER TABLE ONLY im_v2.group_invite_links
    ADD CONSTRAINT group_invite_links_pkey PRIMARY KEY (invite_id);

ALTER TABLE ONLY im_v2.group_invite_links
    ADD CONSTRAINT group_invite_links_token_digest_key UNIQUE (token_digest);

ALTER TABLE ONLY im_v2.group_invite_links
    ADD CONSTRAINT group_invite_links_created_by_user_id_creation_operation_key UNIQUE (created_by_user_id, creation_operation_id);

ALTER TABLE ONLY im_v2.group_invite_links
    ADD CONSTRAINT group_invite_links_invite_room_key UNIQUE (invite_id, room_id);

ALTER TABLE ONLY im_v2.group_join_requests
    ADD CONSTRAINT group_join_requests_pkey PRIMARY KEY (request_id);

ALTER TABLE ONLY im_v2.group_join_requests
    ADD CONSTRAINT group_join_requests_applicant_user_id_submission_operation_key UNIQUE (applicant_user_id, submission_operation_id);

ALTER TABLE ONLY im_v2.group_join_requests
    ADD CONSTRAINT group_join_requests_invite_id_applicant_user_id_key UNIQUE (invite_id, applicant_user_id);

ALTER TABLE ONLY im_v2.group_join_requests
    ADD CONSTRAINT group_join_requests_reviewer_decision_key UNIQUE (decided_by_user_id, decision_operation_id);

ALTER TABLE ONLY im_v2.media_download_grants
    ADD CONSTRAINT media_download_grants_pkey PRIMARY KEY (download_session_id);

ALTER TABLE ONLY im_v2.media_objects
    ADD CONSTRAINT media_objects_pkey PRIMARY KEY (media_id);

ALTER TABLE ONLY im_v2.media_objects
    ADD CONSTRAINT media_objects_upload_session_id_key UNIQUE (upload_session_id);

ALTER TABLE ONLY im_v2.message_forward_media_imports
    ADD CONSTRAINT message_forward_media_imports_target_media_id_fkey FOREIGN KEY (target_media_id) REFERENCES im_v2.media_objects(media_id) ON DELETE RESTRICT;

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

ALTER TABLE ONLY im_v2.message_content_versions
    ADD CONSTRAINT message_content_versions_pkey PRIMARY KEY (message_id, message_revision);

ALTER TABLE ONLY im_v2.messages
    ADD CONSTRAINT messages_room_timeline_sequence_key UNIQUE (room_id, timeline_sequence);

ALTER TABLE ONLY im_v2.messages
    ADD CONSTRAINT messages_room_sender_client_key UNIQUE (room_id, sender_user_id, client_message_id);

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

ALTER TABLE ONLY im_v2.user_direct_send_policy_versions
    ADD CONSTRAINT user_direct_send_policy_versions_pkey PRIMARY KEY (user_id);

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

ALTER TABLE ONLY im_v2.user_projection_ready
    ADD CONSTRAINT user_projection_ready_pkey PRIMARY KEY (user_id);

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

CREATE UNIQUE INDEX device_refresh_token_history_device_hmac_idx ON im_v2.device_refresh_token_history USING btree (device_id, refresh_hmac);

CREATE INDEX device_refresh_token_history_expiry_idx ON im_v2.device_refresh_token_history USING btree (expires_at, device_id, family_generation);

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

CREATE INDEX fanout_deliveries_fresh_direct_user_microbatch_claim_idx ON im_v2.fanout_deliveries USING btree (target_shard_bucket, mod((hashtextextended((target_user_id)::text, (0)::bigint) & '9223372036854775807'::bigint), (8)::bigint), target_user_id, source_event_id, projection_kind) WHERE (fresh_direct_eligible AND (state = 'pending'::text) AND (claim_token IS NULL) AND (next_attempt_at IS NULL) AND (lease_expires_at IS NULL) AND (paused_at IS NULL) AND (retry_count = 0));

CREATE INDEX fanout_deliveries_fresh_generic_target_lane_claim_idx ON im_v2.fanout_deliveries USING btree (target_shard_bucket, mod((hashtextextended((target_user_id)::text, (0)::bigint) & '9223372036854775807'::bigint), (8)::bigint), source_event_id, target_user_id, projection_kind) WHERE ((NOT fresh_direct_eligible) AND (state = 'pending'::text) AND (next_attempt_at IS NULL) AND (lease_expires_at IS NULL));

CREATE INDEX fanout_deliveries_retry_due_claim_idx ON im_v2.fanout_deliveries USING btree (target_shard_bucket, next_attempt_at, source_event_id, target_user_id, projection_kind) WHERE ((state = 'pending'::text) AND (next_attempt_at IS NOT NULL) AND (lease_expires_at IS NULL));

CREATE INDEX fanout_deliveries_terminal_source_idx ON im_v2.fanout_deliveries USING btree (source_event_id, target_user_id, projection_kind) WHERE (state = 'terminal'::text);

CREATE INDEX fanout_plans_pending_idx ON im_v2.fanout_plans USING btree (state, created_at) WHERE (state <> 'terminal'::text);

CREATE INDEX fanout_plans_terminal_cleanup_idx ON im_v2.fanout_plans USING btree (terminal_at, source_event_id) WHERE (state = 'terminal'::text);

CREATE INDEX fanout_sync_payloads_message_state_idx ON im_v2.fanout_sync_payloads USING btree (message_state_id) WHERE (message_state_id IS NOT NULL);

CREATE INDEX group_announcement_operations_cleanup_idx ON im_v2.group_announcement_operations USING btree (created_at);

CREATE INDEX group_invite_links_room_active_idx ON im_v2.group_invite_links USING btree (room_id, created_at DESC, invite_id DESC) WHERE (state = 'active'::text);

CREATE INDEX group_join_requests_room_pending_idx ON im_v2.group_join_requests USING btree (room_id, created_at, request_id) WHERE (state = ANY (ARRAY['pending'::text, 'approving'::text]));

CREATE INDEX group_join_requests_applicant_pending_idx ON im_v2.group_join_requests USING btree (applicant_user_id, created_at) WHERE (state = ANY (ARRAY['pending'::text, 'approving'::text]));

CREATE INDEX group_join_requests_invite_approving_idx ON im_v2.group_join_requests USING btree (invite_id) WHERE (state = 'approving'::text);

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

CREATE INDEX user_projection_ready_claim_idx ON im_v2.user_projection_ready USING btree (available_at, enqueued_at, user_id);

CREATE UNIQUE INDEX user_projection_versions_current_idx ON im_v2.user_projection_versions USING btree (user_id, projection_kind, entity_key) WHERE (valid_to_sequence IS NULL);

CREATE INDEX user_projection_versions_current_room_idx ON im_v2.user_projection_versions USING btree (user_id, scope_room_id) WHERE ((valid_to_sequence IS NULL) AND (scope_room_id IS NOT NULL));

CREATE INDEX user_projection_versions_gc_idx ON im_v2.user_projection_versions USING btree (valid_to_sequence, user_id) WHERE (valid_to_sequence IS NOT NULL);

CREATE INDEX user_projection_versions_message_backfill_idx ON im_v2.user_projection_versions USING btree (user_id, entity_key, valid_from_sequence) WHERE ((projection_kind = 'message'::text) AND (message_state_id IS NULL) AND (payload IS NOT NULL));

CREATE INDEX user_projection_versions_message_inline_idx ON im_v2.user_projection_versions USING btree (user_id, entity_key, valid_from_sequence) WHERE ((projection_kind = 'message'::text) AND (payload IS NOT NULL));

CREATE INDEX user_projection_versions_message_state_idx ON im_v2.user_projection_versions USING btree (message_state_id) WHERE (message_state_id IS NOT NULL);

CREATE INDEX user_relationship_operations_cleanup_idx ON im_v2.user_relationship_operations USING btree (updated_at);

CREATE INDEX user_room_preference_operations_cleanup_idx ON im_v2.user_room_preference_operations USING btree (updated_at);

CREATE INDEX user_room_preferences_visible_idx ON im_v2.user_room_preferences USING btree (user_id, archived_at, pinned_at DESC, updated_at DESC);

CREATE INDEX user_shard_migrations_retention_claim_idx ON im_v2.user_shard_migrations USING btree (phase, retention_until, retention_claim_expires_at) WHERE (phase = 'retention'::text);

CREATE INDEX user_shard_route_operations_user_idx ON im_v2.user_shard_route_operations USING btree (user_id, created_at DESC);

CREATE INDEX user_sync_log_compaction_age_idx ON im_v2.user_sync_log USING btree (user_id, created_at, user_sync_sequence);

CREATE INDEX user_sync_log_direct_projection_room_idx ON im_v2.user_sync_log USING btree (user_id, projection_kind, ((payload ->> 'room_id'::text))) WHERE ((projection_kind = ANY (ARRAY['direct_room_profile'::text, 'direct_sending_capability'::text])) AND (payload IS NOT NULL));

CREATE UNIQUE INDEX user_sync_log_nonfanout_identity_idx ON im_v2.user_sync_log USING btree (user_id, source_event_id, projection_kind) WHERE (projection_kind <> ALL (ARRAY['message'::text, 'membership'::text, 'moderation'::text, 'room'::text]));

CREATE INDEX user_sync_retention_claim_idx ON im_v2.user_sync_retention USING btree (updated_at, user_id);

CREATE TRIGGER fanout_deliveries_fresh_direct_batch_validate AFTER INSERT ON im_v2.fanout_deliveries REFERENCING NEW TABLE AS inserted_fanout_deliveries FOR EACH STATEMENT EXECUTE FUNCTION im_v2.validate_fresh_direct_delivery_batch();

CREATE TRIGGER fanout_deliveries_fresh_direct_immutable BEFORE UPDATE OF source_event_id, target_user_id, projection_kind, completion_unit_id, fresh_direct_eligible ON im_v2.fanout_deliveries FOR EACH ROW EXECUTE FUNCTION im_v2.reject_fresh_direct_delivery_identity_mutation();

CREATE TRIGGER fanout_plans_identity_immutable BEFORE UPDATE OF source_event_id, target_rule ON im_v2.fanout_plans FOR EACH ROW EXECUTE FUNCTION im_v2.reject_fanout_plan_identity_mutation();

CREATE TRIGGER room_events_enqueue_hybrid_group_wake AFTER INSERT ON im_v2.room_events REFERENCING NEW TABLE AS inserted_room_events FOR EACH STATEMENT EXECUTE FUNCTION im_v2.enqueue_hybrid_group_event_wake();

CREATE TRIGGER messages_enqueue_hybrid_group_wake AFTER INSERT ON im_v2.messages REFERENCING NEW TABLE AS inserted_messages FOR EACH STATEMENT EXECUTE FUNCTION im_v2.enqueue_hybrid_group_message_wake();

CREATE TRIGGER room_events_immutable BEFORE DELETE OR UPDATE ON im_v2.room_events FOR EACH ROW EXECUTE FUNCTION im_v2.reject_room_event_mutation();

CREATE TRIGGER room_admission_windows_follow_shard_lease BEFORE UPDATE OF shard_lease_id, shard_lease_generation ON im_v2.room_admission FOR EACH ROW WHEN ((NEW.shard_lease_id IS DISTINCT FROM OLD.shard_lease_id) OR (NEW.shard_lease_generation IS DISTINCT FROM OLD.shard_lease_generation)) EXECUTE FUNCTION im_v2.reset_room_admission_windows_on_shard_lease_change();

CREATE TRIGGER rooms_delivery_mode_immutable BEFORE UPDATE OF delivery_mode ON im_v2.rooms FOR EACH ROW EXECUTE FUNCTION im_v2.reject_room_delivery_mode_mutation();

CREATE TRIGGER user_sync_log_projection_effect_v4 AFTER INSERT ON im_v2.user_sync_log REFERENCING NEW TABLE AS inserted_user_sync_rows FOR EACH STATEMENT EXECUTE FUNCTION im_v2.capture_user_projection_effect_v4();

CREATE TRIGGER user_sync_log_snapshot_v7_projection AFTER INSERT ON im_v2.user_sync_log REFERENCING NEW TABLE AS inserted_user_sync_rows FOR EACH STATEMENT EXECUTE FUNCTION im_v2.enqueue_user_projection_v7();

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

ALTER TABLE ONLY im_v2.device_refresh_token_history
    ADD CONSTRAINT device_refresh_token_history_user_id_device_id_fkey FOREIGN KEY (user_id, device_id) REFERENCES im_v2.auth_devices(user_id, device_id) ON DELETE RESTRICT;

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

ALTER TABLE ONLY im_v2.group_role_policies
    ADD CONSTRAINT group_role_policies_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

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

ALTER TABLE ONLY im_v2.group_invite_links
    ADD CONSTRAINT group_invite_links_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.group_rooms(room_id) ON DELETE CASCADE;

ALTER TABLE ONLY im_v2.group_join_requests
    ADD CONSTRAINT group_join_requests_invite_room_fkey FOREIGN KEY (invite_id, room_id) REFERENCES im_v2.group_invite_links(invite_id, room_id) ON DELETE CASCADE;

ALTER TABLE ONLY im_v2.group_join_requests
    ADD CONSTRAINT group_join_requests_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.group_rooms(room_id) ON DELETE CASCADE;

ALTER TABLE ONLY im_v2.media_download_grants
    ADD CONSTRAINT media_download_grants_media_id_fkey FOREIGN KEY (media_id) REFERENCES im_v2.media_objects(media_id);

ALTER TABLE im_v2.media_download_grants
    ADD COLUMN message_room_id uuid,
    ADD COLUMN message_id uuid,
    ADD COLUMN owner_shard_id text,
    ADD COLUMN owner_epoch bigint,
    ADD CONSTRAINT media_download_grants_scope_check CHECK (
        (message_room_id IS NULL AND message_id IS NULL AND owner_shard_id IS NULL AND owner_epoch IS NULL)
        OR (message_room_id IS NOT NULL AND message_id IS NOT NULL AND owner_shard_id IS NOT NULL
            AND length(btrim(owner_shard_id)) > 0 AND owner_epoch IS NOT NULL AND owner_epoch >= 0)
    );
CREATE FUNCTION im_v2.reject_media_download_grant_identity_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF ROW(NEW.download_session_id, NEW.media_id, NEW.user_id, NEW.device_id, NEW.expires_at, NEW.created_at,
           NEW.message_room_id, NEW.message_id, NEW.owner_shard_id, NEW.owner_epoch)
       IS DISTINCT FROM ROW(OLD.download_session_id, OLD.media_id, OLD.user_id, OLD.device_id, OLD.expires_at, OLD.created_at,
           OLD.message_room_id, OLD.message_id, OLD.owner_shard_id, OLD.owner_epoch)
       OR (OLD.state = 'consumed' AND NEW IS DISTINCT FROM OLD) THEN
        RAISE EXCEPTION 'media download grant identity is immutable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER media_download_grants_identity BEFORE UPDATE ON im_v2.media_download_grants
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_media_download_grant_identity_mutation();


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

-- Forward attribution may name a message in another physical owner. Its
-- authorization is the source transaction/export, not a local message FK.

ALTER TABLE ONLY im_v2.messages
    ADD CONSTRAINT messages_reply_to_message_id_fkey FOREIGN KEY (reply_to_message_id) REFERENCES im_v2.messages(message_id);

ALTER TABLE ONLY im_v2.messages
    ADD CONSTRAINT messages_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id);

ALTER TABLE ONLY im_v2.message_content_versions
    ADD CONSTRAINT message_content_versions_message_id_fkey FOREIGN KEY (message_id) REFERENCES im_v2.messages(message_id) ON DELETE RESTRICT;

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

ALTER TABLE im_v2.push_device_intents ADD CONSTRAINT push_device_intents_device_id_fkey FOREIGN KEY (device_id) REFERENCES im_v2.auth_devices(device_id) ON DELETE RESTRICT;

CREATE TABLE im_v2.group_invite_directory (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    invite_id uuid NOT NULL,
    room_id uuid NOT NULL,
    token_digest bytea NOT NULL,
    requested_lifetime_seconds bigint NOT NULL,
    maximum_approved_uses bigint NOT NULL,
    created_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    state text NOT NULL,
    ready_at timestamptz,
    CONSTRAINT group_invite_directory_pkey PRIMARY KEY (actor_user_id, operation_id),
    CONSTRAINT group_invite_directory_token_key UNIQUE (token_digest),
    CONSTRAINT group_invite_directory_invite_key UNIQUE (invite_id),
    CONSTRAINT group_invite_directory_digest_check CHECK (octet_length(token_digest) = 32),
    CONSTRAINT group_invite_directory_lifetime_check CHECK (requested_lifetime_seconds > 0),
    CONSTRAINT group_invite_directory_uses_check CHECK (maximum_approved_uses > 0),
    CONSTRAINT group_invite_directory_expiry_check CHECK (expires_at > created_at),
    CONSTRAINT group_invite_directory_state_check CHECK (state IN ('prepared', 'ready')),
    CONSTRAINT group_invite_directory_ready_check CHECK ((state = 'ready') = (ready_at IS NOT NULL))
);

CREATE FUNCTION im_v2.reject_group_invite_directory_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'invite directory bindings cannot be deleted';
    END IF;
    IF (to_jsonb(NEW) - 'state' - 'ready_at') IS DISTINCT FROM (to_jsonb(OLD) - 'state' - 'ready_at')
       OR OLD.state = 'ready'
       OR NEW.state <> 'ready' THEN
        RAISE EXCEPTION 'invite directory permits only prepared to ready';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER group_invite_directory_immutable BEFORE UPDATE OR DELETE ON im_v2.group_invite_directory
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_group_invite_directory_mutation();

CREATE TABLE im_v2.group_invite_creation_recovery (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    state text NOT NULL,
    attempt_count bigint NOT NULL,
    next_attempt_at timestamptz NOT NULL,
    claim_token uuid,
    lease_expires_at timestamptz,
    last_error_code text,
    updated_at timestamptz NOT NULL,
    completed_at timestamptz,
    CONSTRAINT group_invite_creation_recovery_pkey PRIMARY KEY (actor_user_id, operation_id),
    CONSTRAINT group_invite_creation_recovery_intent_fkey FOREIGN KEY (actor_user_id, operation_id)
        REFERENCES im_v2.group_invite_directory(actor_user_id, operation_id) ON DELETE RESTRICT,
    CONSTRAINT group_invite_creation_recovery_state_check CHECK (state IN ('pending','claimed','completed','paused')),
    CONSTRAINT group_invite_creation_recovery_attempt_check CHECK (attempt_count >= 0 AND attempt_count <= 1000),
    CONSTRAINT group_invite_creation_recovery_claim_check CHECK ((state = 'claimed') = (claim_token IS NOT NULL)),
    CONSTRAINT group_invite_creation_recovery_lease_check CHECK ((state = 'claimed') = (lease_expires_at IS NOT NULL)),
    CONSTRAINT group_invite_creation_recovery_completed_check CHECK ((state = 'completed') = (completed_at IS NOT NULL)),
    CONSTRAINT group_invite_creation_recovery_paused_check CHECK (state <> 'paused' OR last_error_code IS NOT NULL),
    CONSTRAINT group_invite_creation_recovery_error_check CHECK (last_error_code IN ('dependency_unavailable','owner_changed','rate_limited','permission_denied','creation_expired','conflicting_evidence'))
);
CREATE INDEX group_invite_creation_recovery_pending_idx ON im_v2.group_invite_creation_recovery
    (next_attempt_at, actor_user_id, operation_id) WHERE state = 'pending';
CREATE INDEX group_invite_creation_recovery_lease_idx ON im_v2.group_invite_creation_recovery
    (lease_expires_at, actor_user_id, operation_id) WHERE state = 'claimed';

CREATE TABLE im_v2.group_invite_directory_import_audit (
    operation_id uuid PRIMARY KEY,
    operator_principal text NOT NULL,
    shard_id text NOT NULL,
    owner_epoch bigint NOT NULL,
    room_id uuid NOT NULL,
    after_invite_id uuid,
    page_size bigint NOT NULL,
    reason_code text NOT NULL,
    requested_at timestamptz NOT NULL,
    outcome text NOT NULL,
    source_snapshot jsonb NOT NULL,
    source_digest bytea NOT NULL,
    source_count bigint NOT NULL,
    inserted_count bigint NOT NULL,
    published_count bigint NOT NULL,
    unchanged_count bigint NOT NULL,
    next_cursor uuid,
    conflicting_invite_ids uuid[] NOT NULL,
    CONSTRAINT group_invite_import_principal_check CHECK (operator_principal ~ '^[A-Za-z0-9_.:-]{1,128}$'),
    CONSTRAINT group_invite_import_shard_check CHECK (octet_length(shard_id) BETWEEN 1 AND 128 AND shard_id = btrim(shard_id)),
    CONSTRAINT group_invite_import_epoch_check CHECK (owner_epoch >= 0),
    CONSTRAINT group_invite_import_page_check CHECK (page_size BETWEEN 1 AND 100),
    CONSTRAINT group_invite_import_reason_check CHECK (reason_code IN ('dependency_recovered','data_repaired','false_positive')),
    CONSTRAINT group_invite_import_outcome_check CHECK (outcome IN ('applied','conflict')),
    CONSTRAINT group_invite_import_snapshot_check CHECK (jsonb_typeof(source_snapshot) = 'array' AND jsonb_array_length(source_snapshot) = source_count AND source_count BETWEEN 0 AND page_size),
    CONSTRAINT group_invite_import_digest_check CHECK (source_digest = sha256(convert_to(source_snapshot::text, 'UTF8'))),
    CONSTRAINT group_invite_import_counts_check CHECK (
        inserted_count >= 0 AND published_count >= 0 AND unchanged_count >= 0
        AND ((outcome = 'applied' AND inserted_count + published_count + unchanged_count = source_count AND cardinality(conflicting_invite_ids) = 0)
          OR (outcome = 'conflict' AND inserted_count = 0 AND published_count = 0 AND unchanged_count = 0 AND cardinality(conflicting_invite_ids) BETWEEN 1 AND source_count))),
    CONSTRAINT group_invite_import_cursor_check CHECK (next_cursor IS NULL OR (source_count = page_size AND next_cursor = (source_snapshot->-1->>'invite_id')::uuid))
);
CREATE FUNCTION im_v2.reject_group_invite_import_audit_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'invite directory import audit is immutable';
END;
$$;
CREATE TRIGGER group_invite_import_audit_immutable BEFORE UPDATE OR DELETE ON im_v2.group_invite_directory_import_audit
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_group_invite_import_audit_mutation();
CREATE INDEX group_invite_links_import_page_idx ON im_v2.group_invite_links (room_id, invite_id);

CREATE TABLE im_v2.device_revocation_capabilities (
    device_id uuid PRIMARY KEY,
    user_id uuid NOT NULL,
    credential_digest text NOT NULL UNIQUE,
    session_created_at timestamptz NOT NULL,
    session_expires_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    CONSTRAINT device_revocation_capability_device FOREIGN KEY (user_id, device_id)
        REFERENCES im_v2.auth_devices (user_id, device_id) ON DELETE CASCADE,
    CONSTRAINT device_revocation_capability_digest CHECK (credential_digest ~ '^[0-9a-f]{64}$'),
    CONSTRAINT device_revocation_capability_expiry CHECK (
        isfinite(session_created_at) AND isfinite(session_expires_at) AND isfinite(expires_at)
        AND session_expires_at > session_created_at
        AND expires_at = session_expires_at + interval '10 minutes')
);

COMMIT;

CREATE TABLE im_v2.device_registration_cancellations (
    request_digest text PRIMARY KEY,
    device_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    issue_before timestamptz NOT NULL,
    created_at timestamptz NOT NULL,
    cancelled_at timestamptz,
    user_id uuid,
    session_created_at timestamptz,
    session_expires_at timestamptz,
    CONSTRAINT registration_cancellation_digest CHECK (request_digest ~ '^[0-9a-f]{64}$'),
    CONSTRAINT registration_cancellation_times CHECK (
        isfinite(created_at) AND isfinite(issue_before) AND issue_before > created_at
        AND issue_before <= created_at + interval '1 day'
        AND (cancelled_at IS NULL OR isfinite(cancelled_at))),
    CONSTRAINT registration_cancellation_binding CHECK (
        (user_id IS NULL AND session_created_at IS NULL AND session_expires_at IS NULL AND cancelled_at IS NOT NULL)
        OR (user_id IS NOT NULL AND session_created_at IS NOT NULL AND session_expires_at IS NOT NULL
            AND isfinite(session_created_at) AND isfinite(session_expires_at) AND session_expires_at > session_created_at)),
    CONSTRAINT registration_cancellation_device FOREIGN KEY (user_id, device_id)
        REFERENCES im_v2.auth_devices (user_id, device_id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX registration_cancellation_issued_device_idx ON im_v2.device_registration_cancellations (device_id) WHERE user_id IS NOT NULL;
CREATE INDEX registration_cancellation_pending_expiry_idx ON im_v2.device_registration_cancellations (issue_before) WHERE user_id IS NULL;

CREATE TABLE im_v2.legacy_device_registration_cancellations (
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    cancelled_at timestamptz NOT NULL,
    CONSTRAINT legacy_registration_cancellation_pkey PRIMARY KEY (user_id, device_id),
    CONSTRAINT legacy_registration_cancellation_operation UNIQUE (user_id, operation_id),
    CONSTRAINT legacy_registration_cancellation_time CHECK (isfinite(cancelled_at))
);
