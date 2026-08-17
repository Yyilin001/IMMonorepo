\set ON_ERROR_STOP on

-- Final audit gate. A row-level CHECK cannot join room_events, so the
-- accepted-message-only invariant is enforced here without incorrectly
-- forcing edit/withdrawal deltas to discard their distinct payloads.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM im_v2.fanout_sync_payloads AS shared
        JOIN im_v2.room_events AS event
          ON event.event_id = shared.source_event_id
        LEFT JOIN im_v2.message_projection_states AS state
          ON state.state_id = shared.message_state_id
        WHERE event.event_type = 'message.accepted'
          AND shared.projection_kind = 'message'
          AND (
              shared.payload IS NOT NULL
              OR state.state_id IS NULL
              OR state.payload <> event.payload
          )
    ) THEN
        RAISE EXCEPTION 'accepted-message fan-out payload reference audit failed';
    END IF;
END
$$;
