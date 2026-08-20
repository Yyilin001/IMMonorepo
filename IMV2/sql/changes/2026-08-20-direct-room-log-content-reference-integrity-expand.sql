BEGIN;

-- Existing deployments may already have applied the original reference
-- storage expansion. Keep this as a separate, idempotent expansion so a
-- mutable body can never diverge from the immutable revision referenced by a
-- compact room event.
CREATE OR REPLACE FUNCTION im_v2.snapshot_message_content_before_revision_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF (NEW.text_body IS DISTINCT FROM OLD.text_body
        OR NEW.rich_entities IS DISTINCT FROM OLD.rich_entities)
       AND NEW.content_revision = OLD.content_revision THEN
        RAISE EXCEPTION 'message content updates must advance content_revision'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.content_revision <> OLD.content_revision THEN
        INSERT INTO im_v2.message_content_versions
            (message_id, message_revision, text_body, rich_entities, archived_at)
        VALUES
            (OLD.message_id, OLD.content_revision, OLD.text_body, OLD.rich_entities, now())
        ON CONFLICT (message_id, message_revision) DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS messages_snapshot_content_before_revision_change
    ON im_v2.messages;
CREATE TRIGGER messages_snapshot_content_before_revision_change
    BEFORE UPDATE OF text_body, rich_entities, content_revision ON im_v2.messages
    FOR EACH ROW EXECUTE FUNCTION im_v2.snapshot_message_content_before_revision_change();

COMMIT;
