\set ON_ERROR_STOP on

-- Online expand phase for an existing im-v2-current-1 database. Apply this
-- independently to the control database and every physical user-shard store.
-- Do not start current-2 binaries until the complete script succeeds.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

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
    payload jsonb NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT message_projection_states_pkey PRIMARY KEY (state_id),
    CONSTRAINT message_projection_states_message_revision_key
        UNIQUE (message_id, message_revision, variant_key),
    CONSTRAINT message_projection_states_state_event_key
        UNIQUE (state_event_id, variant_key),
    CONSTRAINT message_projection_states_state_room_key
        UNIQUE (state_id, room_id),
    CONSTRAINT message_projection_states_message_revision_check
        CHECK (message_revision > 0),
    CONSTRAINT message_projection_states_payload_check
        CHECK (payload->>'event_type' = 'message.accepted'),
    CONSTRAINT message_projection_states_payload_message_check
        CHECK (lower(payload->>'message_id') = message_id::text),
    CONSTRAINT message_projection_states_payload_revision_check
        CHECK ((payload->>'message_revision')::bigint = message_revision),
    CONSTRAINT message_projection_states_payload_room_check
        CHECK (lower(payload->>'room_id') = room_id::text),
    CONSTRAINT message_projection_states_payload_schema_check
        CHECK (payload_schema_version = 1),
    CONSTRAINT message_projection_states_payload_withdrawn_check
        CHECK (COALESCE((payload->>'is_withdrawn')::boolean, FALSE) = is_withdrawn),
    CONSTRAINT message_projection_states_variant_key_check
        CHECK (variant_key >= 0)
);

ALTER TABLE im_v2.fanout_sync_payloads
    ADD COLUMN message_state_id uuid;
ALTER TABLE im_v2.user_projection_versions
    ADD COLUMN message_state_id uuid;
ALTER TABLE im_v2.user_projection_versions
    ALTER COLUMN payload DROP NOT NULL;
ALTER TABLE im_v2.user_projection_versions
    DROP CONSTRAINT user_projection_versions_check1;
ALTER TABLE im_v2.user_projection_versions
    ADD CONSTRAINT user_projection_versions_check1 CHECK (
        scope_room_id IS NULL
        OR (payload IS NOT NULL AND lower(payload->>'room_id') = scope_room_id::text)
        OR (projection_kind = 'message' AND message_state_id IS NOT NULL)
    ) NOT VALID;
ALTER TABLE im_v2.user_projection_versions
    ADD CONSTRAINT user_projection_versions_payload_storage_check CHECK (
        payload IS NOT NULL
        OR (projection_kind = 'message' AND message_state_id IS NOT NULL)
    ) NOT VALID;
ALTER TABLE im_v2.fanout_sync_payloads
    ADD CONSTRAINT fanout_sync_payloads_message_state_id_fkey
    FOREIGN KEY (message_state_id)
    REFERENCES im_v2.message_projection_states(state_id)
    ON DELETE RESTRICT NOT VALID;
ALTER TABLE im_v2.user_projection_versions
    ADD CONSTRAINT user_projection_versions_message_state_room_fkey
    FOREIGN KEY (message_state_id, scope_room_id)
    REFERENCES im_v2.message_projection_states(state_id, room_id)
    ON DELETE RESTRICT NOT VALID;
COMMIT;

-- CONCURRENTLY keeps normal reads/writes available while the two large-table
-- indexes are built. If this phase is interrupted, rerun the individual
-- failed CREATE INDEX after dropping an invalid index of the same name.
CREATE INDEX CONCURRENTLY message_projection_states_gc_idx
    ON im_v2.message_projection_states (created_at, state_id);
CREATE INDEX CONCURRENTLY fanout_sync_payloads_message_state_idx
    ON im_v2.fanout_sync_payloads (message_state_id)
    WHERE message_state_id IS NOT NULL;
CREATE INDEX CONCURRENTLY user_projection_versions_message_state_idx
    ON im_v2.user_projection_versions (message_state_id)
    WHERE message_state_id IS NOT NULL;
CREATE INDEX CONCURRENTLY user_projection_versions_message_backfill_idx
    ON im_v2.user_projection_versions (user_id, entity_key, valid_from_sequence)
    WHERE projection_kind = 'message'
      AND message_state_id IS NULL
      AND payload IS NOT NULL;
CREATE INDEX CONCURRENTLY user_projection_versions_message_inline_idx
    ON im_v2.user_projection_versions (user_id, entity_key, valid_from_sequence)
    WHERE projection_kind = 'message' AND payload IS NOT NULL;

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '0';
ALTER TABLE im_v2.user_projection_versions
    VALIDATE CONSTRAINT user_projection_versions_check1;
ALTER TABLE im_v2.user_projection_versions
    VALIDATE CONSTRAINT user_projection_versions_payload_storage_check;
ALTER TABLE im_v2.fanout_sync_payloads
    VALIDATE CONSTRAINT fanout_sync_payloads_message_state_id_fkey;
ALTER TABLE im_v2.user_projection_versions
    VALIDATE CONSTRAINT user_projection_versions_message_state_room_fkey;

ALTER TABLE im_v2.schema_contract
    DROP CONSTRAINT schema_contract_schema_id_check;
UPDATE im_v2.schema_contract
SET schema_id = 'im-v2-current-2'
WHERE schema_id = 'im-v2-current-1';
ALTER TABLE im_v2.schema_contract
    ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-2';
ALTER TABLE im_v2.schema_contract
    ADD CONSTRAINT schema_contract_schema_id_check
        CHECK (schema_id = 'im-v2-current-2');
COMMIT;
