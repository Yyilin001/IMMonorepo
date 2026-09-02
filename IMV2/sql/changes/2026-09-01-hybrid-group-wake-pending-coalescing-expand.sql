-- Stop rewriting one hot wake-outbox row for every Hybrid-group append.
--
-- A pending row is already a durable promise that the relay will visit the
-- room. The matching application claim reads the authoritative
-- `rooms.room_sequence` in a second READ COMMITTED statement after acquiring
-- the lease, so a pending row does not need its stored target or revision
-- advanced by every commit.
--
-- A leased row remains different: a new commit replaces the lease, advances
-- its fencing revision, and leaves the row pending. The old publisher can no
-- longer delete it with its stale token/revision.
BEGIN;

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
        )
    WHERE im_v2.group_event_wake_outbox.state = 'leased';
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION im_v2.enqueue_hybrid_group_message_wake()
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

COMMIT;
