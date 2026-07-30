-- Fan-out delivery is fenced by consumer_inbox before appending user_sync_log.
-- The full semantic unique constraint therefore duplicates write work for all
-- fan-out rows, while non-fan-out projections still require it for retries.
ALTER TABLE im_v2.user_sync_log
    DROP CONSTRAINT IF EXISTS user_sync_log_user_id_source_event_id_projection_kind_key;

CREATE UNIQUE INDEX IF NOT EXISTS user_sync_log_nonfanout_identity_idx
    ON im_v2.user_sync_log (user_id, source_event_id, projection_kind)
    WHERE projection_kind NOT IN ('message', 'membership', 'moderation', 'room');
