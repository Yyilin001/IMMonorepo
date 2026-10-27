-- Read-only deployment admission for the new required resource_descriptor.
-- Run after schema admission and before enabling the current client/server.
-- This rejects incompatible persisted data; it never repairs old payloads.
-- Other payload validation remains the responsibility of the typed decoders.
WITH payloads AS (
    SELECT payload FROM im_v2.room_events WHERE event_type = 'message.accepted'
    UNION ALL
    SELECT payload FROM im_v2.message_projection_state_values
    UNION ALL
    SELECT payload FROM im_v2.user_sync_log WHERE projection_kind = 'message'
), shapes AS (
    SELECT payload,
           CASE WHEN jsonb_typeof(payload->'media_ids') = 'array'
                THEN payload->'media_ids' ELSE '[]'::jsonb END AS media_ids,
           CASE WHEN jsonb_typeof(payload->'media_presentations') = 'array'
                THEN payload->'media_presentations' ELSE '[]'::jsonb END AS presentations
    FROM payloads
)
SELECT NOT EXISTS (
    SELECT 1 FROM shapes
    WHERE (jsonb_typeof(payload->'media_ids') NOT IN ('array', 'null'))
       OR (jsonb_typeof(payload->'media_presentations') NOT IN ('array', 'null'))
       OR jsonb_array_length(media_ids) <> jsonb_array_length(presentations)
       OR EXISTS (
           SELECT 1 FROM jsonb_array_elements(presentations) AS item
           WHERE jsonb_typeof(item->'resource_descriptor') IS DISTINCT FROM 'object'
       )
) AS resource_payload_contract_ready;
