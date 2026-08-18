-- Keep sync-log insertion independent from the snapshot projector transaction.
-- Existing checkpoint and wake rows already carry all durable state needed to
-- resume work, so conflict updates only create heap/WAL churn and contend with
-- the projector's row locks.
BEGIN;

CREATE FUNCTION im_v2.enqueue_user_projection_v6() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO im_v2.user_projection_checkpoints
        (user_id, projected_sequence, updated_at)
    SELECT user_id, 0, min(created_at)
    FROM inserted_user_sync_rows
    GROUP BY user_id
    ON CONFLICT (user_id) DO NOTHING;

    INSERT INTO im_v2.user_projection_ready
        (user_id, available_at, enqueued_at, updated_at)
    SELECT inserted.user_id, min(inserted.created_at),
           min(inserted.created_at), min(inserted.created_at)
    FROM inserted_user_sync_rows AS inserted
    JOIN im_v2.user_projection_checkpoints AS checkpoint
      ON checkpoint.user_id = inserted.user_id
     AND checkpoint.state = 'ready'
    GROUP BY inserted.user_id
    ON CONFLICT (user_id) DO NOTHING;

    INSERT INTO im_v2.user_sync_retention
        (user_id, compacted_through_sequence, updated_at)
    SELECT user_id, 0, min(created_at)
    FROM inserted_user_sync_rows
    GROUP BY user_id
    ON CONFLICT (user_id) DO NOTHING;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS user_sync_log_snapshot_v5_projection ON im_v2.user_sync_log;
DROP TRIGGER IF EXISTS user_sync_log_snapshot_v6_projection ON im_v2.user_sync_log;
CREATE TRIGGER user_sync_log_snapshot_v6_projection
    AFTER INSERT ON im_v2.user_sync_log
    REFERENCING NEW TABLE AS inserted_user_sync_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION im_v2.enqueue_user_projection_v6();

DROP FUNCTION IF EXISTS im_v2.enqueue_user_projection_v5();
DROP FUNCTION IF EXISTS im_v2.enqueue_user_projection_v4();

COMMIT;
