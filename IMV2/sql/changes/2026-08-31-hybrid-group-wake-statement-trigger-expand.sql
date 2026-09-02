-- Coalesce Hybrid-group wake work once per room and INSERT statement.
--
-- The outbox is a metadata-only availability hint whose authoritative value
-- is the room high-watermark. Incrementing its lease-fencing revision for
-- every row in one atomic INSERT adds no visibility guarantee: the relay
-- cannot observe any member of that statement before commit. A transition
-- table preserves the maximum committed sequence while avoiding one UPSERT
-- and one set of index/WAL mutations per event.
--
-- Replacing the trigger takes a brief SHARE ROW EXCLUSIVE lock on
-- `room_events`. Apply this migration before deploying the matching canonical
-- schema to new nodes; application binaries require no coordinated cutover.
BEGIN;

DROP TRIGGER IF EXISTS room_events_enqueue_hybrid_group_wake
    ON im_v2.room_events;

CREATE OR REPLACE FUNCTION im_v2.enqueue_hybrid_group_event_wake()
RETURNS trigger
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
        );
    RETURN NULL;
END;
$$;

CREATE TRIGGER room_events_enqueue_hybrid_group_wake
    AFTER INSERT ON im_v2.room_events
    REFERENCING NEW TABLE AS inserted_room_events
    FOR EACH STATEMENT
    EXECUTE FUNCTION im_v2.enqueue_hybrid_group_event_wake();

COMMIT;
