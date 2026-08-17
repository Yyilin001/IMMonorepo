\set ON_ERROR_STOP on

-- The steady-state projector orders ready checkpoints by updated_at/user_id.
-- The older retry-oriented index starts with next_attempt_at and cannot serve
-- that order when healthy rows use NULL next_attempt_at. Build this additive
-- index online on the control database and every physical user-shard store.
CREATE INDEX CONCURRENTLY IF NOT EXISTS user_projection_checkpoints_ready_order_idx
    ON im_v2.user_projection_checkpoints (updated_at, user_id)
    WHERE state = 'ready';
