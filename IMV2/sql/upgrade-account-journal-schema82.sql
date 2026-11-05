-- Offline schema transition. Stop all application writers before applying.
-- No runtime schema81 compatibility. Preserve account/message history.
BEGIN;
DO $$ BEGIN
 IF (SELECT schema_id FROM im_v2.schema_contract) <> 'im-v2-current-81' THEN
  RAISE EXCEPTION 'schema81 required';
 END IF;
END $$;
ALTER TABLE im_v2.user_projection_ready ADD COLUMN revision bigint NOT NULL DEFAULT 1 CHECK(revision>0);
ALTER TABLE im_v2.user_sync_sequences DROP CONSTRAINT user_sync_sequences_next_sequence_check;
ALTER TABLE im_v2.user_sync_sequences ADD CONSTRAINT user_sync_sequences_next_sequence_check CHECK(next_sequence>=0);
DROP TRIGGER user_sync_log_snapshot_v7_projection ON im_v2.user_sync_log;
CREATE FUNCTION im_v2.enqueue_user_projection_v8() RETURNS trigger
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

    -- Writers only touch this short scheduling signal. Consumers hold their
    -- checkpoint, never this row, while folding snapshots. An unconditional
    -- conflict update prevents a concurrent completion/delete from losing work.
    WITH users AS MATERIALIZED (
        SELECT user_id, min(created_at) AS created_at
        FROM inserted_user_sync_rows GROUP BY user_id
    )
    INSERT INTO im_v2.user_projection_ready
        (user_id, available_at, enqueued_at, updated_at)
    SELECT user_id, created_at, created_at, created_at FROM users
    ON CONFLICT (user_id) DO UPDATE
    SET revision = im_v2.user_projection_ready.revision + 1,
        available_at = LEAST(im_v2.user_projection_ready.available_at, EXCLUDED.available_at),
        updated_at = GREATEST(im_v2.user_projection_ready.updated_at, EXCLUDED.updated_at);

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
CREATE TRIGGER user_sync_log_snapshot_v8_projection AFTER INSERT ON im_v2.user_sync_log
 REFERENCING NEW TABLE AS inserted_user_sync_rows FOR EACH STATEMENT EXECUTE FUNCTION im_v2.enqueue_user_projection_v8();
DROP FUNCTION im_v2.enqueue_user_projection_v7();
ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-82';
UPDATE im_v2.schema_contract SET schema_id='im-v2-current-82';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK(schema_id='im-v2-current-82');
COMMIT;
