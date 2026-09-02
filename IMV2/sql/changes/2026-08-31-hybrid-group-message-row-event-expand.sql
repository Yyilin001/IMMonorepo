-- Expand the existing message-row accepted-event contract to compact hybrid
-- group messages. Readers already merge `messages` and legacy `room_events`;
-- this migration adds only the transactional, statement-coalesced wake source
-- required before the compact writer can be enabled.

BEGIN;

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
        );
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS messages_enqueue_hybrid_group_wake
    ON im_v2.messages;

CREATE TRIGGER messages_enqueue_hybrid_group_wake
    AFTER INSERT ON im_v2.messages
    REFERENCING NEW TABLE AS inserted_messages
    FOR EACH STATEMENT
    EXECUTE FUNCTION im_v2.enqueue_hybrid_group_message_wake();

COMMIT;
