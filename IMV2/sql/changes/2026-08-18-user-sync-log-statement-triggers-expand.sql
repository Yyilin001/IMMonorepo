-- Replace per-row projection side effects with one set-based pass per INSERT.
-- This takes a brief lock while triggers are replaced; run it before deploying
-- binaries whose hot path depends on the statement-level write profile.
BEGIN;

CREATE FUNCTION im_v2.capture_user_projection_effect_v4() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO im_v2.user_projection_effects
        (user_id, source_event_id, projection_kind,
         user_sync_sequence, payload, created_at)
    SELECT user_id, source_event_id, projection_kind,
           user_sync_sequence, payload, created_at
    FROM inserted_user_sync_rows
    WHERE payload_storage = 'inline'
      AND projection_kind NOT IN ('message', 'membership', 'moderation', 'room')
    ON CONFLICT (user_id, source_event_id, projection_kind) DO NOTHING;

    IF EXISTS (
        SELECT 1
        FROM inserted_user_sync_rows AS inserted
        JOIN im_v2.user_projection_effects AS effect
          USING (user_id, source_event_id, projection_kind)
        WHERE inserted.payload_storage = 'inline'
          AND inserted.projection_kind NOT IN
              ('message', 'membership', 'moderation', 'room')
          AND ROW(effect.user_sync_sequence, effect.payload, effect.created_at)
              IS DISTINCT FROM
              ROW(inserted.user_sync_sequence, inserted.payload, inserted.created_at)
    ) THEN
        RAISE EXCEPTION 'conflicting immutable user projection effect';
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION im_v2.enqueue_user_projection_v4() RETURNS trigger
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

    INSERT INTO im_v2.user_sync_retention
        (user_id, compacted_through_sequence, updated_at)
    SELECT user_id, 0, min(created_at)
    FROM inserted_user_sync_rows
    GROUP BY user_id
    ON CONFLICT (user_id) DO NOTHING;
    RETURN NULL;
END;
$$;

DROP TRIGGER user_sync_log_projection_effect_v3 ON im_v2.user_sync_log;
DROP TRIGGER user_sync_log_snapshot_v3_projection ON im_v2.user_sync_log;

CREATE TRIGGER user_sync_log_projection_effect_v4
    AFTER INSERT ON im_v2.user_sync_log
    REFERENCING NEW TABLE AS inserted_user_sync_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION im_v2.capture_user_projection_effect_v4();

CREATE TRIGGER user_sync_log_snapshot_v4_projection
    AFTER INSERT ON im_v2.user_sync_log
    REFERENCING NEW TABLE AS inserted_user_sync_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION im_v2.enqueue_user_projection_v4();

DROP FUNCTION im_v2.capture_user_projection_effect_v3();
DROP FUNCTION im_v2.enqueue_user_projection_v3();

COMMIT;
