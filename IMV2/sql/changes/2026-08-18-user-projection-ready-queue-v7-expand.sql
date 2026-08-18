-- Existing checkpoint and retention rows are permanent per-user facts. A
-- blind INSERT ... ON CONFLICT for every Sync Log statement can still wait on
-- a projector that is updating the checkpoint, even though it will ultimately
-- do nothing. Pre-filter current rows while retaining the conflict fence for
-- concurrent first-ever batches.
BEGIN;

CREATE FUNCTION im_v2.enqueue_user_projection_v7() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Checkpoint and retention rows live for the lifetime of a user. Avoid an
    -- INSERT conflict attempt for every later Sync Log batch: it can wait on
    -- the projector's update lock even though DO NOTHING would win. The final
    -- conflict fence remains necessary for two first-ever batches racing.
    WITH users AS MATERIALIZED (
        SELECT user_id, min(created_at) AS created_at
        FROM inserted_user_sync_rows
        GROUP BY user_id
    )
    INSERT INTO im_v2.user_projection_checkpoints
        (user_id, projected_sequence, updated_at)
    SELECT users.user_id, 0, users.created_at
    FROM users
    WHERE NOT EXISTS (
        SELECT 1 FROM im_v2.user_projection_checkpoints AS checkpoint
        WHERE checkpoint.user_id = users.user_id
    )
    ON CONFLICT (user_id) DO NOTHING;

    WITH users AS MATERIALIZED (
        SELECT user_id, min(created_at) AS created_at
        FROM inserted_user_sync_rows
        GROUP BY user_id
    )
    INSERT INTO im_v2.user_projection_ready
        (user_id, available_at, enqueued_at, updated_at)
    SELECT users.user_id, users.created_at,
           users.created_at, users.created_at
    FROM users
    JOIN im_v2.user_projection_checkpoints AS checkpoint
      ON checkpoint.user_id = users.user_id
     AND checkpoint.state = 'ready'
    WHERE NOT EXISTS (
        SELECT 1 FROM im_v2.user_projection_ready AS ready
        WHERE ready.user_id = users.user_id
    )
    ON CONFLICT (user_id) DO NOTHING;

    WITH users AS MATERIALIZED (
        SELECT user_id, min(created_at) AS created_at
        FROM inserted_user_sync_rows
        GROUP BY user_id
    )
    INSERT INTO im_v2.user_sync_retention
        (user_id, compacted_through_sequence, updated_at)
    SELECT users.user_id, 0, users.created_at
    FROM users
    WHERE NOT EXISTS (
        SELECT 1 FROM im_v2.user_sync_retention AS retention
        WHERE retention.user_id = users.user_id
    )
    ON CONFLICT (user_id) DO NOTHING;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS user_sync_log_snapshot_v6_projection ON im_v2.user_sync_log;
DROP TRIGGER IF EXISTS user_sync_log_snapshot_v7_projection ON im_v2.user_sync_log;
CREATE TRIGGER user_sync_log_snapshot_v7_projection
    AFTER INSERT ON im_v2.user_sync_log
    REFERENCING NEW TABLE AS inserted_user_sync_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION im_v2.enqueue_user_projection_v7();

DROP FUNCTION IF EXISTS im_v2.enqueue_user_projection_v6();

COMMIT;
