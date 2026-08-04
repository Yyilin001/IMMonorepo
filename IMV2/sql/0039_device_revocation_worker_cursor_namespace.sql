-- Move the device-revocation cursor out of the temporary `-v1` namespace.
--
-- The worker closes a live stream before it advances its cursor, so replaying
-- an event during a rolling deployment is harmless.  Keep the retired rows
-- for one release window: they are useful rollback state, while the new
-- namespace becomes the only one read or advanced by current binaries.
INSERT INTO im_v2.gateway_worker_cursors (
    worker_name,
    node_id,
    last_event_id,
    updated_at
)
SELECT
    'device-revocation',
    node_id,
    last_event_id,
    updated_at
FROM im_v2.gateway_worker_cursors
WHERE worker_name = 'device-revocation-v1'
ON CONFLICT (worker_name, node_id) DO UPDATE
SET last_event_id = GREATEST(
        im_v2.gateway_worker_cursors.last_event_id,
        EXCLUDED.last_event_id
    ),
    updated_at = GREATEST(
        im_v2.gateway_worker_cursors.updated_at,
        EXCLUDED.updated_at
    );
