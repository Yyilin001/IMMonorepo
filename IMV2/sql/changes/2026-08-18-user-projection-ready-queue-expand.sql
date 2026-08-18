-- Replace repeated checkpoint/sequence scans with one coalescing durable wake
-- row per user. The old checkpoint indexes remain during the expand phase so
-- an older binary can safely run until the new worker is deployed everywhere.
BEGIN;

CREATE TABLE IF NOT EXISTS im_v2.user_projection_ready (
    user_id uuid PRIMARY KEY,
    available_at timestamp with time zone NOT NULL,
    enqueued_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);

CREATE INDEX IF NOT EXISTS user_projection_ready_claim_idx
    ON im_v2.user_projection_ready (available_at, enqueued_at, user_id);

CREATE FUNCTION im_v2.enqueue_user_projection_v5() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO im_v2.user_projection_checkpoints
        (user_id, projected_sequence, updated_at)
    SELECT user_id, 0, min(created_at)
    FROM inserted_user_sync_rows
    GROUP BY user_id
    ON CONFLICT (user_id) DO UPDATE SET updated_at = LEAST(
        im_v2.user_projection_checkpoints.updated_at,
        EXCLUDED.updated_at
    )
    WHERE im_v2.user_projection_checkpoints.updated_at > EXCLUDED.updated_at;

    INSERT INTO im_v2.user_projection_ready
        (user_id, available_at, enqueued_at, updated_at)
    SELECT inserted.user_id, min(inserted.created_at),
           min(inserted.created_at), min(inserted.created_at)
    FROM inserted_user_sync_rows AS inserted
    JOIN im_v2.user_projection_checkpoints AS checkpoint
      ON checkpoint.user_id = inserted.user_id
     AND checkpoint.state = 'ready'
    GROUP BY inserted.user_id
    ON CONFLICT (user_id) DO UPDATE
    SET available_at = LEAST(
            im_v2.user_projection_ready.available_at,
            EXCLUDED.available_at
        ),
        enqueued_at = LEAST(
            im_v2.user_projection_ready.enqueued_at,
            EXCLUDED.enqueued_at
        ),
        updated_at = GREATEST(
            im_v2.user_projection_ready.updated_at,
            EXCLUDED.updated_at
        );

    INSERT INTO im_v2.user_sync_retention
        (user_id, compacted_through_sequence, updated_at)
    SELECT user_id, 0, min(created_at)
    FROM inserted_user_sync_rows
    GROUP BY user_id
    ON CONFLICT (user_id) DO NOTHING;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS user_sync_log_snapshot_v4_projection ON im_v2.user_sync_log;
DROP TRIGGER IF EXISTS user_sync_log_snapshot_v5_projection ON im_v2.user_sync_log;
CREATE TRIGGER user_sync_log_snapshot_v5_projection
    AFTER INSERT ON im_v2.user_sync_log
    REFERENCING NEW TABLE AS inserted_user_sync_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION im_v2.enqueue_user_projection_v5();

INSERT INTO im_v2.user_projection_ready
    (user_id, available_at, enqueued_at, updated_at)
SELECT checkpoint.user_id, COALESCE(checkpoint.next_attempt_at, now()),
       checkpoint.updated_at, now()
FROM im_v2.user_projection_checkpoints AS checkpoint
JOIN im_v2.user_sync_sequences AS sequence USING (user_id)
WHERE checkpoint.state = 'ready'
  AND checkpoint.projected_sequence < sequence.next_sequence
ON CONFLICT (user_id) DO UPDATE
SET available_at = LEAST(
        im_v2.user_projection_ready.available_at,
        EXCLUDED.available_at
    ),
    enqueued_at = LEAST(
        im_v2.user_projection_ready.enqueued_at,
        EXCLUDED.enqueued_at
    ),
    updated_at = EXCLUDED.updated_at;

COMMIT;
