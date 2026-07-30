-- Store an immutable fan-out body once per physical user shard.  Existing
-- records keep the conservative inline representation; only new fan-out
-- writes use the explicit shared representation.
CREATE TABLE IF NOT EXISTS im_v2.fanout_sync_payloads (
    source_event_id UUID NOT NULL,
    projection_kind TEXT NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (source_event_id, projection_kind)
);

ALTER TABLE im_v2.user_sync_log
    ALTER COLUMN payload DROP NOT NULL;

ALTER TABLE im_v2.user_sync_log
    ADD COLUMN IF NOT EXISTS payload_storage TEXT NOT NULL DEFAULT 'inline';

ALTER TABLE im_v2.user_sync_log
    DROP CONSTRAINT IF EXISTS user_sync_log_payload_storage_check;

ALTER TABLE im_v2.user_sync_log
    ADD CONSTRAINT user_sync_log_payload_storage_check
    CHECK (
        (payload_storage = 'inline' AND payload IS NOT NULL)
        OR (payload_storage = 'fanout_shared' AND payload IS NULL)
    );
