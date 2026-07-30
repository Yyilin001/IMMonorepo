-- Hybrid-group foreground wakes are intentionally coalesced by room.  The
-- durable room event log remains authoritative; this table only makes an
-- already-committed waterline available to a best-effort broker relay.
CREATE TABLE im_v2.group_event_wake_outbox (
    room_id UUID PRIMARY KEY REFERENCES im_v2.rooms(room_id),
    target_room_sequence BIGINT NOT NULL CHECK (target_room_sequence > 0),
    revision BIGINT NOT NULL CHECK (revision > 0),
    state TEXT NOT NULL CHECK (state IN ('pending', 'leased')),
    lease_token UUID NULL,
    lease_expires_at TIMESTAMPTZ NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    next_attempt_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    CHECK (
        (state = 'pending' AND lease_token IS NULL AND lease_expires_at IS NULL)
        OR (state = 'leased' AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)
    )
);

CREATE INDEX group_event_wake_outbox_claim_idx
    ON im_v2.group_event_wake_outbox (next_attempt_at, updated_at)
    WHERE state = 'pending';

CREATE OR REPLACE FUNCTION im_v2.enqueue_hybrid_group_event_wake()
RETURNS trigger
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

CREATE TRIGGER room_events_enqueue_hybrid_group_wake
AFTER INSERT ON im_v2.room_events
FOR EACH ROW EXECUTE FUNCTION im_v2.enqueue_hybrid_group_event_wake();
