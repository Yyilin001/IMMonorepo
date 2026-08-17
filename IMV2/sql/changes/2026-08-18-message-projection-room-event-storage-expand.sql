-- Expand shared message-state storage so an accepted revision can reuse the
-- immutable room-event body on a co-located control/user store. Existing and
-- remote-shard rows remain inline until an explicit bounded compaction pass.

-- A room-event-backed state is safe only while its source body is immutable.
-- Enforce the append-only contract in PostgreSQL rather than relying on every
-- future application or maintenance path to remember it.
CREATE FUNCTION im_v2.reject_room_event_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION 'room events are append-only';
END;
$$;

CREATE TRIGGER room_events_immutable
    BEFORE DELETE OR UPDATE ON im_v2.room_events
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_room_event_mutation();

ALTER TABLE im_v2.message_projection_states
    ADD COLUMN IF NOT EXISTS payload_storage text DEFAULT 'inline'::text NOT NULL;

ALTER TABLE im_v2.message_projection_states
    ALTER COLUMN payload DROP NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'im_v2.message_projection_states'::regclass
          AND conname = 'message_projection_states_payload_storage_check'
    ) THEN
        ALTER TABLE im_v2.message_projection_states
            ADD CONSTRAINT message_projection_states_payload_storage_check
            CHECK (
                (payload_storage = 'inline' AND payload IS NOT NULL)
                OR (
                    payload_storage = 'room_event'
                    AND payload IS NULL
                    AND message_revision = 1
                    AND variant_key = 0
                    AND state_event_id IS NOT NULL
                    AND origin_event_id = state_event_id
                    AND NOT is_withdrawn
                )
            ) NOT VALID;
    END IF;
END
$$;

ALTER TABLE im_v2.message_projection_states
    VALIDATE CONSTRAINT message_projection_states_payload_storage_check;

CREATE OR REPLACE VIEW im_v2.message_projection_state_values AS
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
FROM im_v2.message_projection_states AS state
LEFT JOIN im_v2.room_events AS event
  ON state.payload_storage = 'room_event'
 AND event.event_id = state.state_event_id
 AND event.room_id = state.room_id
 AND event.event_type = 'message.accepted'
 AND lower(event.payload->>'message_id') = state.message_id::text
 AND lower(event.payload->>'room_id') = state.room_id::text
 AND (event.payload->>'message_revision')::bigint = state.message_revision
WHERE state.payload_storage = 'inline'
   OR event.event_id IS NOT NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS
    message_projection_states_inline_accepted_idx
    ON im_v2.message_projection_states (state_event_id, state_id)
    WHERE payload_storage = 'inline'
      AND message_revision = 1
      AND variant_key = 0
      AND state_event_id IS NOT NULL;
